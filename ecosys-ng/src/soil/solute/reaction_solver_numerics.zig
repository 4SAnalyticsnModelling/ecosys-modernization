//! `reaction_solver` declarations: numerics.
//!
//! Split out of `reaction_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const chemistry = @import("chemistry_state.zig");
const aqueous_network = @import("aqueous_network.zig");
const phosphate_network = @import("phosphate_network.zig");
const cation_exchange = @import("cation_exchange.zig");
const geochemistry = @import("geochemistry_network.zig");
const aqueous_rates = @import("aqueous_reaction_rates.zig");
const phosphate_rates = @import("phosphate_reaction_rates.zig");
const geochemistry_rates = @import("geochemistry_reaction_rates.zig");
const reaction_span = @import("reaction_search_span.zig");
const group_evaluate = @import("reaction_solver_evaluate.zig");
const group_numerics2 = @import("reaction_solver_numerics2.zig");
const group_types = @import("reaction_solver_types.zig");
const diagnostic_control = @import("reaction_diagnostic_control.zig");

pub fn validateAqueousMolarity(
    state: *const chemistry.State,
    cell_index: usize,
) !void {
    const water_mol_per_m3 = state.water_mol_per_m3[cell_index];
    if (!std.math.isFinite(water_mol_per_m3) or water_mol_per_m3 <= 0)
        return error.InvalidChemistryWaterState;
    inline for (
        @typeInfo(aqueous_network.State).@"struct".fields,
        0..,
    ) |field, component_index| {
        const concentration = @field(state.aqueous[cell_index], field.name);
        if (!std.math.isFinite(concentration) or concentration < 0)
            return error.NonFiniteSoluteReactionState;
        if (concentration > water_mol_per_m3) {
            if (diagnostic_control.isEnabled()) std.log.warn(
                "SOLUTE aqueous concentration exceeds water molarity: cell={d} packed_component={d} name=aqueous.{s} concentration_mol_per_m3={e} water_mol_per_m3={e}",
                .{
                    cell_index,
                    component_index,
                    field.name,
                    concentration,
                    water_mol_per_m3,
                },
            );
            return error.SoluteConcentrationExceedsWaterMolarity;
        }
    }
}

pub fn largestScaledResidualIndex(
    current: []const f64,
    residual: []const f64,
    options: group_types.Options,
) usize {
    var limiting_index: usize = 0;
    var limiting_scaled_residual: f64 = 0;
    for (current, residual, 0..) |value, change, index| {
        const scaled_residual = @abs(change) / residualScale(value, index, options);
        if (scaled_residual > limiting_scaled_residual) {
            limiting_scaled_residual = scaled_residual;
            limiting_index = index;
        }
    }
    return limiting_index;
}

pub fn matrixColumnNorm(
    matrix: []const f64,
    row_count: usize,
    column_count: usize,
    column: usize,
    first_row: usize,
) f64 {
    var scale: f64 = 0;
    var sum_squares: f64 = 1;
    for (first_row..row_count) |row| {
        const magnitude = @abs(matrix[row * column_count + column]);
        if (magnitude == 0) continue;
        if (scale < magnitude) {
            const ratio = scale / magnitude;
            sum_squares = 1 + sum_squares * ratio * ratio;
            scale = magnitude;
        } else {
            const ratio = magnitude / scale;
            sum_squares += ratio * ratio;
        }
    }
    return if (scale == 0) 0 else scale * @sqrt(sum_squares);
}

pub fn transformedVector(scratch: *chemistry.State, current: []const f64, transformations: chemistry.CellTransformations, monovalent_activity_coefficient: f64, water_activity_product_mol2_per_m6: f64, fraction: f64, output: []f64) !void {
    diagnostic_control.recordReactionSpanEvaluation();
    var profile_scope = diagnostic_control.beginPhase(.transformed_vector);
    defer profile_scope.end();
    try scratch.unpackCell(0, current);
    _ = try scratch.state_updateCellProjectedWater(
        0,
        group_numerics2.scaled(transformations, fraction),
        monovalent_activity_coefficient,
        water_activity_product_mol2_per_m6,
    );
    try scratch.packCell(0, output);
    // A negative conserved coordinate cannot be normalized away: zeroing it
    // manufactures exactly the discarded deficit. Reject the candidate and
    // let the line search/Anderson recovery select a feasible state instead.
    for (output, 0..) |*value, index| {
        if (!std.math.isFinite(value.*))
            return error.NonFiniteSoluteReactionState;
        if (value.* < 0)
            return error.NegativeSoluteReactionRoundoff;
        if ((index == 4 or index == 5) and value.* == 0)
            return error.InvalidSoluteReactionRoundoff;
    }
}

/// Finds the largest fraction no greater than the requested fraction that
/// preserves every nonnegative chemistry inventory. Individual source
/// reactions are substrate limited, but several simultaneous reactions can
/// draw from the same ion; this is the conservative line search for their
/// assembled direction.
pub fn transformedVectorAdmissible(scratch: *chemistry.State, current: []const f64, transformations: chemistry.CellTransformations, parameters: chemistry.ReactionParameters, requested_fraction: f64, output: []f64) !f64 {
    try scratch.unpackCell(0, current);
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    return transformedVectorAdmissibleWithMonovalentActivityCoefficient(
        scratch,
        current,
        transformations,
        parameters,
        coefficients.monovalent_activity_coefficient,
        requested_fraction,
        output,
    );
}

/// Reports the aqueous complementarity case in which every positive real
/// fraction remains inadmissible because the actual assembled aqueous donor
/// is already exactly zero. Other storage domains retain their established
/// backtracking semantics because their zero-face projection can affect the
/// coupled solver trajectory.
fn exactZeroAqueousDonorBlocksPositiveFraction(
    scratch: *chemistry.State,
    transformations: chemistry.CellTransformations,
    fraction: f64,
    err: anyerror,
) !bool {
    if (err != error.NegativeAqueousState) return false;
    const rejection = try scratch.diagnoseFirstNegativeProjectedAqueous(
        0,
        group_numerics2.scaled(transformations, fraction),
    );
    return if (rejection) |detail|
        detail.current_value_mol_per_m3 == 0 and
            detail.applied_change_mol_per_m3 < 0
    else
        false;
}

/// The caller has already evaluated the exact immutable `current` state and
/// retained its activity coefficient. This avoids repeating Debye-Huckel
/// classification and transcendental work for every candidate assembled from
/// that same state; candidate interpolation and admissibility ordering remain
/// identical to `transformedVectorAdmissible`.
pub fn transformedVectorAdmissibleWithMonovalentActivityCoefficient(scratch: *chemistry.State, current: []const f64, transformations: chemistry.CellTransformations, parameters: chemistry.ReactionParameters, monovalent_activity_coefficient: f64, requested_fraction: f64, output: []f64) !f64 {
    // Reject an invalid accepted anchor before entering the fraction search.
    // Any negative-state error caught below is therefore caused by the trial
    // transformation and can genuinely be resolved by reducing its fraction.
    try scratch.unpackCell(0, current);
    var fraction = requested_fraction;
    var rejected_fraction: ?f64 = null;
    var last_rejection: ?anyerror = null;
    var last_raw_negative_owner: ?RawNegativeOwner = null;
    var logical_attempts: u16 = 0;
    var projection_attempts: u64 = 0;
    while (logical_attempts < group_numerics2.maximum_admissibility_backtracks) {
        projection_attempts +|= 1;
        transformedVector(
            scratch,
            current,
            transformations,
            monovalent_activity_coefficient,
            parameters.water_activity_product_mol2_per_m6,
            fraction,
            output,
        ) catch |err| {
            if (!isFractionResolvableAdmissibilityError(err)) return err;
            logical_attempts += 1;
            if (try exactZeroAqueousDonorBlocksPositiveFraction(
                scratch,
                transformations,
                fraction,
                err,
            )) {
                try transformedVector(
                    scratch,
                    current,
                    transformations,
                    monovalent_activity_coefficient,
                    parameters.water_activity_product_mol2_per_m6,
                    0,
                    output,
                );
                diagnostic_control.recordAdmissibilityBacktrackDepth(
                    projection_attempts,
                );
                return 0;
            }
            last_rejection = err;
            rejected_fraction = fraction;

            var next_fraction = fraction * 0.5;
            last_raw_negative_owner = rawNegativeOwnerForRejection(
                scratch,
                transformations,
                fraction,
                err,
            );
            if (last_raw_negative_owner) |owner| {
                // Each skipped source fraction is still accounted for in the
                // 1,075-step scientific search bound.  It is omitted from the
                // expensive atomic replay only while this exact stored owner
                // alone proves the candidate negative.  The first fraction
                // which might be feasible is always replayed in full, so the
                // accepted fraction and all rounding/branch semantics match
                // the original linear search.
                while (logical_attempts < group_numerics2.maximum_admissibility_backtracks) {
                    const scaled_change = owner.raw_change * next_fraction;
                    if (!(scaled_change < 0 and
                        owner.current_value < -scaled_change)) break;
                    rejected_fraction = next_fraction;
                    logical_attempts += 1;
                    next_fraction *= 0.5;
                }
            }
            fraction = next_fraction;
            continue;
        };
        break;
    }
    if (logical_attempts == group_numerics2.maximum_admissibility_backtracks) {
        const rejection = last_rejection orelse
            return error.NoAdmissibleSoluteReactionStep;
        diagnostic_control.recordAdmissibilityBacktrackDepth(projection_attempts);
        try logNoAdmissibleAqueousFraction(
            scratch,
            current,
            transformations,
            rejected_fraction orelse fraction,
            rejection,
        );
        return rejection;
    }
    var upper = rejected_fraction orelse {
        diagnostic_control.recordAdmissibilityBacktrackDepth(projection_attempts);
        return fraction;
    };
    var lower = fraction;
    // A raw owner proves an affine negative inventory before any nonlinear
    // reconciliation. Its algebraic zero is therefore a useful *probe*, not
    // an accepted shortcut: evaluate it through the complete transactional
    // transformation and use the result only to tighten the already-proven
    // [admissible, inadmissible] bracket. The unchanged ordered-f64 bisection
    // below still establishes the exact immediate-successor boundary.
    if (last_raw_negative_owner) |owner| {
        const owner_boundary = owner.current_value / -owner.raw_change;
        if (std.math.isFinite(owner_boundary) and
            owner_boundary > lower and owner_boundary < upper)
        {
            projection_attempts +|= 1;
            const owner_boundary_admissible = admissible: {
                transformedVector(
                    scratch,
                    current,
                    transformations,
                    monovalent_activity_coefficient,
                    parameters.water_activity_product_mol2_per_m6,
                    owner_boundary,
                    output,
                ) catch |err| {
                    if (!isFractionResolvableAdmissibilityError(err)) return err;
                    break :admissible false;
                };
                break :admissible true;
            };
            if (owner_boundary_admissible) {
                lower = owner_boundary;
                const successor = std.math.nextAfter(
                    f64,
                    owner_boundary,
                    std.math.inf(f64),
                );
                if (successor < upper) {
                    projection_attempts +|= 1;
                    const successor_admissible = admissible: {
                        transformedVector(
                            scratch,
                            current,
                            transformations,
                            monovalent_activity_coefficient,
                            parameters.water_activity_product_mol2_per_m6,
                            successor,
                            output,
                        ) catch |err| {
                            if (!isFractionResolvableAdmissibilityError(err))
                                return err;
                            break :admissible false;
                        };
                        break :admissible true;
                    };
                    if (successor_admissible)
                        lower = successor
                    else
                        upper = successor;
                }
            } else {
                upper = owner_boundary;
                const predecessor = std.math.nextAfter(
                    f64,
                    owner_boundary,
                    0,
                );
                if (predecessor > lower) {
                    projection_attempts +|= 1;
                    const predecessor_admissible = admissible: {
                        transformedVector(
                            scratch,
                            current,
                            transformations,
                            monovalent_activity_coefficient,
                            parameters.water_activity_product_mol2_per_m6,
                            predecessor,
                            output,
                        ) catch |err| {
                            if (!isFractionResolvableAdmissibilityError(err))
                                return err;
                            break :admissible false;
                        };
                        break :admissible true;
                    };
                    if (predecessor_admissible)
                        lower = predecessor
                    else
                        upper = predecessor;
                }
            }
        }
    }
    while (group_numerics2.admissibilityFractionMidpoint(lower, upper)) |middle| {
        projection_attempts +|= 1;
        transformedVector(
            scratch,
            current,
            transformations,
            monovalent_activity_coefficient,
            parameters.water_activity_product_mol2_per_m6,
            middle,
            output,
        ) catch |err| {
            if (!isFractionResolvableAdmissibilityError(err)) return err;
            upper = middle;
            continue;
        };
        lower = middle;
    }
    // Land on the greatest representable admissible fraction. Its immediate
    // f64 successor is inadmissible, so no tolerance-sized interior gap can
    // keep a limiting inventory spuriously active. The source AMAX1/AMIN1
    // bounds permit exact exhaustion. H+ and OH- are projected onto Kw
    // separately and therefore cannot be exhausted by this boundary.
    try transformedVector(
        scratch,
        current,
        transformations,
        monovalent_activity_coefficient,
        parameters.water_activity_product_mol2_per_m6,
        lower,
        output,
    );
    diagnostic_control.recordAdmissibilityBacktrackDepth(projection_attempts);
    return lower;
}

const RawNegativeOwner = struct {
    current_value: f64,
    raw_change: f64,
};

fn rawNegativeStructOwner(
    comptime StateType: type,
    current_state: StateType,
    raw_transformations: anytype,
    fraction: f64,
) ?RawNegativeOwner {
    inline for (@typeInfo(StateType).@"struct".fields) |field| {
        const current_value = @field(current_state, field.name);
        const raw_change = @field(raw_transformations, field.name);
        const scaled_change = raw_change * fraction;
        if (scaled_change < 0 and current_value < -scaled_change)
            return .{ .current_value = current_value, .raw_change = raw_change };
    }
    return null;
}

fn rawNegativeOwnerForRejection(
    scratch: *chemistry.State,
    transformations: chemistry.CellTransformations,
    fraction: f64,
    rejection: anyerror,
) ?RawNegativeOwner {
    return switch (rejection) {
        error.NegativePhosphateNetworkState => blk: {
            break :blk rawNegativeStructOwner(
                phosphate_network.State,
                scratch.non_band_phosphate[0],
                transformations.non_band_phosphate,
                fraction,
            ) orelse rawNegativeStructOwner(
                phosphate_network.State,
                scratch.band_phosphate[0],
                transformations.band_phosphate,
                fraction,
            );
        },
        error.NegativeCationExchangeState => rawNegativeStructOwner(
            cation_exchange.Cations,
            scratch.cation_exchange_mol_per_megagram[0],
            transformations.cation_adsorption_mol_per_megagram,
            fraction,
        ),
        error.NegativeGeochemistrySolidState => rawNegativeStructOwner(
            geochemistry.SolidState,
            scratch.geochemistry_solids[0],
            transformations.geochemistry,
            fraction,
        ),
        error.NegativeCarboxylExchangeState => blk: {
            const current_value =
                scratch.carboxyl_bound_hydrogen_mol_per_megagram[0];
            const raw_change =
                transformations.carboxyl_hydrogen_change_mol_per_megagram;
            const scaled_change = raw_change * fraction;
            break :blk if (scaled_change < 0 and current_value < -scaled_change)
                .{ .current_value = current_value, .raw_change = raw_change }
            else
                null;
        },
        else => null,
    };
}

fn logNoAdmissibleAqueousFraction(
    scratch: *chemistry.State,
    current: []const f64,
    transformations: chemistry.CellTransformations,
    attempted_fraction: f64,
    rejection: anyerror,
) !void {
    if (!diagnostic_control.isEnabled() or builtin.is_test or
        rejection != error.NegativeAqueousState) return;
    try scratch.unpackCell(0, current);
    const changes = try chemistry.State.assembledAqueousChanges(
        transformations,
        scratch.cation_exchange_mol_per_megagram[0],
    );
    const aqueous = scratch.aqueous[0];
    inline for (
        @typeInfo(aqueous_network.State).@"struct".fields,
        0..,
    ) |field, index| {
        const value = @field(aqueous, field.name);
        const change = @field(changes, field.name);
        if (change < 0 and value + attempted_fraction * change < 0)
            std.log.err(
                "SOLUTE no admissible reaction fraction: aqueous_index={d} name={s} value={e} raw_change={e} attempted_fraction={e}",
                .{ index, field.name, value, change, attempted_fraction },
            );
    }
}

/// Only trial states made negative by the proposed reaction direction define
/// a fraction-dependent admissibility boundary. Conservation, dimensions,
/// parameters, NaN/Inf, projection, and arithmetic failures must propagate;
/// backtracking through them would hide a defect as a smaller valid step.
fn isFractionResolvableAdmissibilityError(err: anyerror) bool {
    return switch (err) {
        error.NegativeAqueousState,
        error.NegativePhosphateNetworkState,
        error.NegativeCationExchangeState,
        error.NegativeGeochemistrySolidState,
        error.NegativeCarboxylExchangeState,
        error.NegativeChemistryWaterState,
        error.NegativeSoluteReactionRoundoff,
        => true,
        else => false,
    };
}

pub fn scaledNorm(state: []const f64, residual: []const f64, options: group_types.Options) !f64 {
    var maximum: f64 = 0;
    for (state, residual, 0..) |value, change, index| {
        if (!std.math.isFinite(value) or value < 0 or !std.math.isFinite(change)) return error.NonFiniteSoluteReactionState;
        maximum = @max(
            maximum,
            @abs(change) / residualScale(value, index, options),
        );
    }
    return maximum;
}

pub fn residualScale(value: f64, packed_component: usize, options: group_types.Options) f64 {
    const reference = if (options.search_reference_concentrations) |references| references[packed_component] else @abs(value);
    return options.absoluteToleranceForPackedComponent(packed_component) +
        options.relative_tolerance * reference;
}

/// Difference of the dimensionless residual actually scored by line search.
/// When relative scaling depends on concentration, differencing the raw
/// defect at a frozen scale omits the denominator's derivative.
pub fn scaledResidualDifference(current_value: f64, current_residual: f64, probe_value: f64, probe_residual: f64, packed_component: usize, options: group_types.Options) f64 {
    return probe_residual / residualScale(probe_value, packed_component, options) -
        current_residual / residualScale(current_value, packed_component, options);
}

/// Forms the reaction solver's depth-one Anderson candidate in the same
/// scaled coordinates used by its convergence and merit tests. The packed
/// vector mixes mol/m3 and mol/Mg; fitting a raw Euclidean secant makes the
/// result depend on the chosen unit representation. Scales are fixed at the
/// accepted anchor so the affine candidate remains one well-defined secant.
pub fn scaledAndersonDepthOneCandidate(
    anchor_state: []const f64,
    anchor_defect: []const f64,
    seed_state: []const f64,
    seed_defect: []const f64,
    options: group_types.Options,
    output: []f64,
) bool {
    if (anchor_state.len == 0 or
        anchor_defect.len != anchor_state.len or
        seed_state.len != anchor_state.len or
        seed_defect.len != anchor_state.len or
        output.len != anchor_state.len)
        return false;

    const mixing = scaledAndersonDepthOneMixing(anchor_state, anchor_defect, seed_defect, options) orelse return false;
    for (output, seed_state, anchor_state) |*value, seed, anchor| {
        value.* = seed - mixing * (seed - anchor);
        if (!std.math.isFinite(value.*)) return false;
    }
    return true;
}

/// Shared scaled secant coefficient. Conservative coordinate callers apply
/// this coefficient to the native extent rather than to rounded concentrations.
pub fn scaledAndersonDepthOneMixing(
    anchor_state: []const f64,
    anchor_defect: []const f64,
    seed_defect: []const f64,
    options: group_types.Options,
) ?f64 {
    if (anchor_state.len == 0 or anchor_defect.len != anchor_state.len or
        seed_defect.len != anchor_state.len) return null;

    var largest_scaled_change: f64 = 0;
    for (anchor_state, anchor_defect, seed_defect, 0..) |state_value, before, after, index| {
        const scale = residualScale(state_value, index, options);
        if (!std.math.isFinite(state_value) or
            !std.math.isFinite(before) or
            !std.math.isFinite(after) or
            !std.math.isFinite(scale) or
            scale <= 0)
            return null;
        largest_scaled_change = @max(
            largest_scaled_change,
            @abs((after - before) / scale),
        );
    }
    if (largest_scaled_change == 0 or !std.math.isFinite(largest_scaled_change))
        return null;

    var numerator: f64 = 0;
    var denominator: f64 = 0;
    for (anchor_state, anchor_defect, seed_defect, 0..) |state_value, before, after, index| {
        const scale = residualScale(state_value, index, options);
        const normalized_change =
            ((after - before) / scale) / largest_scaled_change;
        const normalized_after = (after / scale) / largest_scaled_change;
        numerator += normalized_change * normalized_after;
        denominator += normalized_change * normalized_change;
    }
    if (!std.math.isFinite(numerator) or
        !std.math.isFinite(denominator) or
        denominator <= std.math.floatEps(f64))
        return null;
    const mixing = numerator / denominator;
    return if (std.math.isFinite(mixing)) mixing else null;
}

pub fn maximumDifference(a: []const f64, b: []const f64) f64 {
    var maximum: f64 = 0;
    for (a, b) |left, right| maximum = @max(maximum, @abs(left - right));
    return maximum;
}

pub fn maximumMagnitude(values: []const f64) f64 {
    var maximum: f64 = 0;
    for (values) |value| maximum = @max(maximum, @abs(value));
    return maximum;
}

test "reaction Anderson mixing is invariant to packed component units" {
    const component_count = comptime chemistry.State.packedComponentCount();
    var mol_per_megagram_index: usize = 0;
    while (mol_per_megagram_index < component_count and
        !chemistry.State.packedComponentIsMolPerMegagram(mol_per_megagram_index))
        mol_per_megagram_index += 1;
    try std.testing.expect(mol_per_megagram_index < component_count);
    const mol_per_m3_index: usize = 0;
    try std.testing.expect(!chemistry.State.packedComponentIsMolPerMegagram(mol_per_m3_index));

    var anchor_state = [_]f64{0} ** component_count;
    var anchor_defect = [_]f64{0} ** component_count;
    var seed_state = [_]f64{0} ** component_count;
    var seed_defect = [_]f64{0} ** component_count;
    var candidate = [_]f64{0} ** component_count;
    anchor_defect[mol_per_m3_index] = 2;
    seed_defect[mol_per_m3_index] = 1;
    seed_state[mol_per_m3_index] = 1;
    anchor_defect[mol_per_megagram_index] = 2.0e6;
    seed_defect[mol_per_megagram_index] = 0;
    seed_state[mol_per_megagram_index] = 1;
    const options: group_types.Options = .{
        .absolute_tolerance_mol_per_m3 = 1,
        .absolute_tolerance_mol_per_megagram = 1.0e6,
        .relative_tolerance = 0,
    };
    try std.testing.expect(scaledAndersonDepthOneCandidate(
        &anchor_state,
        &anchor_defect,
        &seed_state,
        &seed_defect,
        options,
        &candidate,
    ));
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), candidate[mol_per_m3_index], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), candidate[mol_per_megagram_index], 1e-14);

    // A different representation of the mol/Mg coordinate has the same
    // dimensionless secant and therefore the same accepted target.
    anchor_defect[mol_per_megagram_index] *= 1.0e3;
    seed_defect[mol_per_megagram_index] *= 1.0e3;
    const rescaled_options = optionsWithMolPerMegagramTolerance(options, 1.0e9);
    try std.testing.expect(scaledAndersonDepthOneCandidate(
        &anchor_state,
        &anchor_defect,
        &seed_state,
        &seed_defect,
        rescaled_options,
        &candidate,
    ));
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), candidate[mol_per_m3_index], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), candidate[mol_per_megagram_index], 1e-14);
}

test "reaction solver has no raw mixed-unit Anderson fit" {
    const solve_source = @embedFile("reaction_solve.zig");
    const network_source = @embedFile("reaction_try_network.zig");
    try std.testing.expect(std.mem.indexOf(
        u8,
        solve_source,
        "numerics.andersonDepthOneCandidate(",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        network_source,
        "numerics.andersonDepthOneCandidate(",
    ) == null);
}

test "reaction admissibility backtracks only fraction-resolvable negative states" {
    inline for (.{
        error.NegativeAqueousState,
        error.NegativePhosphateNetworkState,
        error.NegativeCationExchangeState,
        error.NegativeGeochemistrySolidState,
        error.NegativeCarboxylExchangeState,
        error.NegativeChemistryWaterState,
        error.NegativeSoluteReactionRoundoff,
    }) |err| try std.testing.expect(isFractionResolvableAdmissibilityError(err));
    inline for (.{
        error.NonConservativePhosphateInventoryUpdate,
        error.NonConservativePhosphateSiteUpdate,
        error.NonFinitePhosphateNetworkState,
        error.InvalidPhosphateNetworkDensity,
        error.NonFiniteWaterEquilibriumSolution,
        error.InvalidWaterEquilibriumSolution,
        error.NonFiniteSoluteReactionState,
        error.InvalidSoluteReactionRoundoff,
    }) |err| try std.testing.expect(!isFractionResolvableAdmissibilityError(err));
}

fn optionsWithMolPerMegagramTolerance(
    options: group_types.Options,
    tolerance: f64,
) group_types.Options {
    var result = options;
    result.absolute_tolerance_mol_per_megagram = tolerance;
    return result;
}
