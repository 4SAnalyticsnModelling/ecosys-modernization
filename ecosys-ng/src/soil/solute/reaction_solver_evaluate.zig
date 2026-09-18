//! `reaction_solver` declarations: evaluate.
//!
//! Split out of `reaction_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const aqueous_network = @import("aqueous_network.zig");
const phosphate_network = @import("phosphate_network.zig");
const cation_exchange = @import("cation_exchange.zig");
const geochemistry = @import("geochemistry_network.zig");
const aqueous_rates = @import("aqueous_reaction_rates.zig");
const phosphate_rates = @import("phosphate_reaction_rates.zig");
const geochemistry_rates = @import("geochemistry_reaction_rates.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const reaction_span = @import("reaction_search_span.zig");
const group_complementarity = @import("reaction_solver_complementarity.zig");
const group_diagnostics = @import("reaction_solver_diagnostics.zig");
const group_numerics = @import("reaction_solver_numerics.zig");
const group_numerics2 = @import("reaction_solver_numerics2.zig");
const group_phosphate = @import("reaction_solver_phosphate.zig");
const group_reaction_span = @import("reaction_solver_reaction_span.zig");
const group_solve = @import("reaction_solver_solve.zig");
const group_types = @import("reaction_solver_types.zig");
const diagnostic_control = @import("reaction_diagnostic_control.zig");

/// Evaluates the first equilibrium-closure residual without mutating the live
/// cell. `output` follows `State.packCell` ordering and native field units.
pub fn evaluateCellResidual(
    allocator: std.mem.Allocator,
    state: *const chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    options: group_types.Options,
    output: []f64,
) !f64 {
    try group_solve.validateOptions(options);
    if (cell_index >= state.cell_count)
        return error.ChemistryCellIndexOutOfBounds;
    if (output.len != chemistry.State.packedComponentCount())
        return error.ChemistryVectorSizeMismatch;
    var workspace = try group_types.Workspace.init(allocator);
    defer workspace.deinit();
    try state.packCell(cell_index, workspace.current);
    try evaluateGlobalResidualAt(
        &workspace.scratch,
        workspace.current,
        group_solve.equilibriumClosureParameters(parameters),
        output,
    );
    return group_numerics.scaledNorm(workspace.current, output, options);
}

pub fn captureFullNetworkDirectionalComparison(
    trace: *group_types.SolverTrace,
    workspace: *group_types.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    target: []const f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_types.Options,
    current_norm: f64,
    column_count: usize,
    inventory_fraction: f64,
    current_transformations: chemistry.CellTransformations,
    monovalent_activity_coefficient: f64,
    diagnostic: ?*group_diagnostics.IterationDiagnostic,
) void {
    const first_fraction = group_phosphate.phosphateTrustRegionFraction(
        current,
        target,
        options,
        parameters.phosphate_kinetics.substrate_limit_fraction,
    );
    const first_norm = evaluateCandidateResidualAtFraction(
        scratch,
        current,
        target,
        accepted_state,
        residual_work,
        parameters,
        options,
        first_fraction,
    ) catch std.math.inf(f64);
    const directional_fraction = @min(
        first_fraction,
        std.math.cbrt(std.math.floatEps(f64)),
    );
    _ = evaluateCandidateResidualAtFraction(
        scratch,
        current,
        target,
        accepted_state,
        residual_work,
        parameters,
        options,
        directional_fraction,
    ) catch return;

    @memset(trace.full_network_current_rates, std.math.nan(f64));
    _ = evaluateAt(scratch, current, parameters) catch {};
    reaction_span.evaluateRates(
        scratch,
        0,
        parameters,
        trace.full_network_current_rates,
    ) catch {};
    @memset(trace.full_network_directional_rates, std.math.nan(f64));
    _ = evaluateAt(scratch, accepted_state, parameters) catch {};
    reaction_span.evaluateRates(
        scratch,
        0,
        parameters,
        trace.full_network_directional_rates,
    ) catch {};

    @memcpy(trace.full_network_base_residual, global_residual);
    @memcpy(trace.full_network_realized_residual, residual_work);
    for (global_residual, current, 0..) |value, state_value, row| {
        const scale = group_numerics.residualScale(state_value, row, options);
        const normalized_residual = value / scale;
        const weight =
            group_reaction_span.reactionSpanRowWeight(normalized_residual, current_norm);
        var predicted_weighted = normalized_residual * weight;
        for (
            workspace.reaction_span_solution[0..column_count],
            0..,
        ) |extent, column| {
            predicted_weighted +=
                workspace.reaction_span_jacobian[
                    row * column_count + column
                ] * extent * inventory_fraction * directional_fraction;
        }
        trace.full_network_predicted_residual[row] =
            predicted_weighted / weight * scale;
    }
    const limiting_component_index = if (diagnostic) |entry|
        entry.limiting_component_index
    else
        group_numerics.largestScaledResidualIndex(current, global_residual, options);
    const limiting_scale =
        group_numerics.residualScale(current[limiting_component_index], limiting_component_index, options);
    const limiting_normalized_residual =
        global_residual[limiting_component_index] / limiting_scale;
    const limiting_weight = group_reaction_span.reactionSpanRowWeight(
        limiting_normalized_residual,
        current_norm,
    );
    const side_derivative_inputs = group_reaction_span.ReactionSideDerivativeInputs{
        .scratch = scratch,
        .current = current,
        .global_residual = global_residual,
        .probe_state = accepted_state,
        .probe_residual = residual_work,
        .current_transformations = current_transformations,
        .parameters = parameters,
        .options = options,
        .monovalent_activity_coefficient = monovalent_activity_coefficient,
        .limiting_component_index = limiting_component_index,
    };
    for (0..column_count) |column| {
        const reaction =
            workspace.reaction_span_active_reactions[column];
        trace.full_network_reactions[column] = .{
            .reaction_index = reaction,
            .selection_rate = workspace.reaction_span_rates[reaction],
            .current_rate = trace.full_network_current_rates[reaction],
            .directional_rate = trace.full_network_directional_rates[reaction],
            .native_extent_scale = workspace.reaction_span_extent_scales[column],
            .normalized_lower_bound = workspace.reaction_span_lower_bounds[column],
            .normalized_upper_bound = workspace.reaction_span_upper_bounds[column],
            .normalized_solution = workspace.reaction_span_solution[column],
            .limiting_normalized_residual_derivative = workspace.reaction_span_jacobian[
                limiting_component_index * column_count + column
            ] / limiting_weight,
            .solution_side_limiting_normalized_residual_derivative = group_reaction_span.reactionSpanSolutionSideLimitingDerivative(
                side_derivative_inputs,
                reaction,
                workspace.reaction_span_extent_scales[column],
                workspace.reaction_span_lower_bounds[column],
                workspace.reaction_span_upper_bounds[column],
                workspace.reaction_span_solution[column],
            ) catch std.math.nan(f64),
        };
    }
    group_complementarity.searchReactionSpanComplementarity(
        trace,
        workspace,
        scratch,
        current,
        global_residual,
        current_transformations,
        accepted_state,
        residual_work,
        parameters,
        options,
        current_norm,
        monovalent_activity_coefficient,
        column_count,
    ) catch {};
    trace.full_network_comparison_valid = true;
    trace.full_network_limiting_component_index =
        limiting_component_index;
    trace.full_network_reaction_count = column_count;
    trace.full_network_directional_fraction = directional_fraction;
    trace.full_network_comparison_inventory_fraction =
        inventory_fraction;
    trace.full_network_first_trial_fraction = first_fraction;
    trace.full_network_first_trial_maximum_scaled_residual = first_norm;
    if (diagnostic) |entry| {
        trace.full_network_comparison_closure = entry.closure_index;
        trace.full_network_comparison_iteration = entry.iteration;
    }
}

pub fn evaluateGlobalResidualAt(
    scratch: *chemistry.State,
    vector: []const f64,
    parameters: chemistry.ReactionParameters,
    output: []f64,
) !void {
    const carrier = try evaluateAtLoaded(scratch, vector, parameters);
    _ = try evaluateLoadedReactionBalance(scratch, carrier, parameters, output);
}

/// One full-network evaluation together with the activity coefficient that
/// produced it.
///
/// The coefficient is carried rather than recomputed because
/// `evaluateLoadedAtWithMonovalentActivityCoefficient` OVERWRITES
/// `scratch.aqueous[0].hydrogen/hydroxide` with the projected pair. Any
/// coefficient derived from `scratch` afterwards is computed at a different
/// state than the one the projection used, and re-projecting the pair with it
/// leaves `sqrt(Kw) * (1/g2 - 1/g1)` behind -- a residual no iteration can
/// remove. That was `SOLUTE-DUAL-ACTIVITY-COEFFICIENT-MERIT-FLOOR-001`,
/// measured at 0.0171 mol m-3 on a fixture whose true residual is zero.
///
/// This type exists so the compiler refuses the mistake: pricing the balance
/// now REQUIRES the coefficient that projected the carrier, so no call site can
/// silently derive a second one.
pub const LoadedCarrier = struct {
    transformations: chemistry.CellTransformations,
    monovalent_activity_coefficient: f64,
};

/// Prices transformations returned by evaluateAt while its projected carrier
/// is still loaded. Reuses that exact evaluation without recomputing rates --
/// including its activity coefficient, which is what makes "that exact
/// evaluation" true rather than merely intended.
pub fn evaluateLoadedReactionBalance(
    scratch: *const chemistry.State,
    carrier: LoadedCarrier,
    parameters: chemistry.ReactionParameters,
    output: []f64,
) !chemistry.ReactionWaterBalance {
    var profile_scope = diagnostic_control.beginPhase(.full_network_residual);
    defer profile_scope.end();
    const water = try scratch.undampedReactionBalanceWithWater(0, carrier.transformations, carrier.monovalent_activity_coefficient, parameters.water_activity_product_mol2_per_m6, output);
    output[output.len - 1] = water.net_water_change_mol_per_m3;
    return water;
}

/// Independent terminal safeguard. The line-search fraction is a feasibility
/// device, not evidence that the underlying chemical balance has closed.
/// RH2O and the dependent RHHX extent are priced together for net water;
/// their separate source owners remain unchanged.
pub fn requirePhysicalReactionBalance(
    scratch: *chemistry.State,
    vector: []const f64,
    parameters: chemistry.ReactionParameters,
    options: group_types.Options,
    output: []f64,
) !f64 {
    const carrier = try evaluateAtLoaded(scratch, vector, parameters);
    const water = try evaluateLoadedReactionBalance(scratch, carrier, parameters, output);
    _ = options; // Numerical search precision cannot change chemical acceptance.
    const quality = try @import("reaction_physical_quality.zig").measure(scratch, parameters, output, .{});
    const norm = quality.maximum;
    if (norm <= 1) return norm;
    const index = quality.component;
    if (diagnostic_control.isEnabled()) std.log.warn(
        "SOLUTE rejected chemical quality: component={d} state={e} undamped_net_balance={e} quality_ratio={e} source_water={e} projected_water={e}",
        .{ index, vector[index], output[index], norm, water.source_solvent_change_mol_per_m3, water.projected_water_pair_extent_mol_per_m3 },
    );
    return error.SoluteReactionPhysicalBalanceFailure;
}

/// Preserve exact accepted/trial endpoints: from + (to - from) can erase a
/// small positive ion when the donor and endpoint span many exponents.
fn interpolateTrialState(from: f64, to: f64, fraction: f64) f64 {
    if (fraction == 0) return from;
    if (fraction == 1) return to;
    return from + fraction * (to - from);
}

test "chemical trial interpolation preserves positive full-step endpoints" {
    const tiny: f64 = 1e-40;
    try std.testing.expectEqual(@as(f64, 0), 1 + (tiny - 1));
    try std.testing.expectEqual(tiny, interpolateTrialState(1, tiny, 1));
    try std.testing.expectEqual(@as(f64, 1), interpolateTrialState(1, tiny, 0));
    try std.testing.expectEqual(tiny, interpolateTrialState(tiny, 1, 0));
    try std.testing.expectEqual(@as(f64, 1), interpolateTrialState(tiny, 1, 1));
    try std.testing.expectEqual(@as(f64, 0.75), interpolateTrialState(1, 0, 0.25));
}

pub fn evaluateCandidateResidualAtFraction(
    scratch: *chemistry.State,
    current: []const f64,
    target: []const f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_types.Options,
    fraction: f64,
) !f64 {
    for (accepted_state, current, target) |*value, from, to|
        value.* = interpolateTrialState(from, to, fraction);
    try restoreInterpolatedInorganicCarbon(scratch, current, accepted_state);
    try restoreInterpolatedPhosphorus(
        scratch,
        current,
        accepted_state,
        parameters,
    );
    try scratch.unpackCell(0, accepted_state);
    const coefficients =
        try scratch.activityCoefficients(0, parameters.fractions);
    const water = try water_equilibrium.projectProvisional(
        scratch.aqueous[0].hydrogen,
        scratch.aqueous[0].hydroxide,
        coefficients.monovalent_activity_coefficient,
        parameters.water_activity_product_mol2_per_m6,
    );
    scratch.aqueous[0].hydrogen =
        water.hydrogen_concentration_mol_per_m3;
    scratch.aqueous[0].hydroxide =
        water.hydroxide_concentration_mol_per_m3;
    try scratch.packCell(0, accepted_state);
    const projected_coefficients =
        try scratch.activityCoefficients(0, parameters.fractions);
    const changes = try evaluateLoadedAtWithMonovalentActivityCoefficient(
        scratch,
        parameters,
        projected_coefficients.monovalent_activity_coefficient,
    );
    const water_balance = try scratch.undampedReactionBalanceWithWater(0, changes, projected_coefficients.monovalent_activity_coefficient, parameters.water_activity_product_mol2_per_m6, residual_work);
    residual_work[residual_work.len - 1] = water_balance.net_water_change_mol_per_m3;
    return group_numerics.scaledNorm(accepted_state, residual_work, options);
}

/// Component-wise line-search interpolation is mathematically conservative,
/// but repeated binary64 subtract/multiply/add publication can accumulate a
/// small carbon census drift across many accepted Newton steps. Restore that
/// roundoff in dissolved CO2 before exact residual pricing. This changes no
/// reaction extent or total carbon and fails instead of clipping if the
/// correction would make its carrier negative.
pub fn restoreInterpolatedInorganicCarbon(
    scratch: *chemistry.State,
    current: []const f64,
    interpolated: []f64,
) !void {
    try scratch.unpackCell(0, current);
    const conserved = group_numerics2.inorganicCarbonMolPerM3(scratch, 0);
    try scratch.unpackCell(0, interpolated);
    var correction = conserved -
        group_numerics2.inorganicCarbonMolPerM3(scratch, 0);
    inline for (0..2) |_| {
        const corrected = scratch.aqueous[0].carbon_dioxide + correction;
        if (!std.math.isFinite(corrected))
            return error.NonFiniteSoluteReactionState;
        if (corrected < 0) return error.NegativeSoluteReactionRoundoff;
        scratch.aqueous[0].carbon_dioxide = corrected;
        correction = conserved -
            group_numerics2.inorganicCarbonMolPerM3(scratch, 0);
    }
    try scratch.packCell(0, interpolated);
}

fn totalPhosphorusMolPerM3(
    state: *const chemistry.State,
    parameters: chemistry.ReactionParameters,
) !f64 {
    const non_band = try phosphate_network.phosphorusInventory(
        state.non_band_phosphate[0],
        parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
    );
    const band = try phosphate_network.phosphorusInventory(
        state.band_phosphate[0],
        parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
    );
    const result = parameters.fractions.phosphate_non_band * non_band +
        parameters.fractions.phosphate_band * band;
    if (!std.math.isFinite(result) or result < 0)
        return error.NonFiniteSoluteReactionState;
    return result;
}

const PhosphorusCorrectionOwner = struct {
    concentration: *f64,
    zone_fraction: f64,
};

fn largestDissolvedPhosphorusOwner(
    state: *chemistry.State,
    parameters: chemistry.ReactionParameters,
) ?PhosphorusCorrectionOwner {
    var result: ?PhosphorusCorrectionOwner = null;
    var largest_weighted_concentration: f64 = -1;
    inline for (.{
        .{ &state.non_band_phosphate[0], parameters.fractions.phosphate_non_band },
        .{ &state.band_phosphate[0], parameters.fractions.phosphate_band },
    }) |entry| {
        const zone = entry[0];
        const fraction = entry[1];
        if (fraction > 0) {
            inline for (.{
                &zone.dissolved_po4_mol_p_per_m3,
                &zone.dissolved_hpo4_mol_p_per_m3,
                &zone.dissolved_h2po4_mol_p_per_m3,
                &zone.dissolved_h3po4_mol_p_per_m3,
            }) |candidate| {
                const weighted_concentration = fraction * candidate.*;
                if (weighted_concentration > largest_weighted_concentration) {
                    largest_weighted_concentration = weighted_concentration;
                    result = .{
                        .concentration = candidate,
                        .zone_fraction = fraction,
                    };
                }
            }
        }
    }
    return result;
}

/// Projects component-wise Newton/Anderson interpolation back onto its exact
/// phosphorus invariant before residual pricing. The correction is owned by
/// the largest unpaired dissolved phosphate pool, so it cannot manufacture a
/// surface-site or metal-pair transfer. Every reaction-map endpoint is already
/// checked by `phosphate_network.state_updateRealized`; this projection only
/// removes affine binary64 cancellation between those conservative endpoints.
pub fn restoreInterpolatedPhosphorus(
    scratch: *chemistry.State,
    current: []const f64,
    interpolated: []f64,
    parameters: chemistry.ReactionParameters,
) !void {
    try scratch.unpackCell(0, current);
    const conserved = try totalPhosphorusMolPerM3(scratch, parameters);
    try scratch.unpackCell(0, interpolated);
    const owner = largestDissolvedPhosphorusOwner(scratch, parameters) orelse {
        if (try totalPhosphorusMolPerM3(scratch, parameters) != conserved)
            return error.NonConservativePhosphateInventoryUpdate;
        return;
    };
    inline for (0..4) |_| {
        const correction = conserved -
            try totalPhosphorusMolPerM3(scratch, parameters);
        if (correction == 0) break;
        const corrected = owner.concentration.* +
            correction / owner.zone_fraction;
        if (!std.math.isFinite(corrected))
            return error.NonFiniteSoluteReactionState;
        if (corrected < 0) return error.NegativeSoluteReactionRoundoff;
        if (corrected == owner.concentration.*) break;
        owner.concentration.* = corrected;
    }
    try scratch.packCell(0, interpolated);
}

/// Evaluates at `vector` and reports the coefficient the projection used, so
/// the balance can be priced with the same one. See `LoadedCarrier`.
pub fn evaluateAtLoaded(scratch: *chemistry.State, vector: []const f64, parameters: chemistry.ReactionParameters) !LoadedCarrier {
    try scratch.unpackCell(0, vector);
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    return .{
        .transformations = try evaluateLoadedAtWithMonovalentActivityCoefficient(
            scratch,
            parameters,
            coefficients.monovalent_activity_coefficient,
        ),
        .monovalent_activity_coefficient = coefficients.monovalent_activity_coefficient,
    };
}

/// For callers that need only the transformations. Anything that also prices a
/// reaction balance must use `evaluateAtLoaded` and keep the pair together.
pub fn evaluateAt(scratch: *chemistry.State, vector: []const f64, parameters: chemistry.ReactionParameters) !chemistry.CellTransformations {
    return (try evaluateAtLoaded(scratch, vector, parameters)).transformations;
}

/// Evaluates a carrier already loaded into `scratch` using the activity
/// coefficient calculated from that exact carrier. Callers retain all water
/// projection and chemistry evaluation ordering while avoiding a second
/// unpack/classification of the same packed state.
pub fn evaluateLoadedAtWithMonovalentActivityCoefficient(scratch: *chemistry.State, parameters: chemistry.ReactionParameters, monovalent_activity_coefficient: f64) !chemistry.CellTransformations {
    diagnostic_control.recordFullNetworkEvaluation();
    var profile_scope = diagnostic_control.beginPhase(.full_network_residual);
    defer profile_scope.end();
    const water = try water_equilibrium.solve(.{
        .hydrogen_concentration_mol_per_m3 = scratch.aqueous[0].hydrogen,
        .hydroxide_concentration_mol_per_m3 = scratch.aqueous[0].hydroxide,
        .monovalent_activity_coefficient = monovalent_activity_coefficient,
        .water_activity_product_mol2_per_m6 = parameters.water_activity_product_mol2_per_m6,
        .negligible_concentration_mol_per_m3 = parameters.negligible_water_ion_concentration_mol_per_m3,
    });
    scratch.aqueous[0].hydrogen = water.hydrogen_concentration_mol_per_m3;
    scratch.aqueous[0].hydroxide = water.hydroxide_concentration_mol_per_m3;
    return scratch.evaluateCell(0, parameters);
}
