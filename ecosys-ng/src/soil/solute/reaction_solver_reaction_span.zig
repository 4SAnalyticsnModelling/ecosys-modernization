//! `reaction_solver` declarations: reaction span.
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
const group_evaluate = @import("reaction_solver_evaluate.zig");
const group_numerics = @import("reaction_solver_numerics.zig");
const group_numerics2 = @import("reaction_solver_numerics2.zig");
const group_solve = @import("reaction_solver_solve.zig");
const group_types = @import("reaction_solver_types.zig");

const ReactionSpanExtentBounds = struct {
    negative_native_extent: f64,
    positive_native_extent: f64,
};

pub fn reactionSpanRowWeight(
    normalized_residual: f64,
    current_norm: f64,
) f64 {
    return @max(
        std.math.cbrt(std.math.floatEps(f64)),
        @abs(normalized_residual) / current_norm,
    );
}

pub fn reactionSpanPredictedNorm(
    workspace: *const group_types.Workspace,
    current: []const f64,
    global_residual: []const f64,
    options: group_types.Options,
    current_norm: f64,
    column_count: usize,
    step_fraction: f64,
) f64 {
    var predicted_norm: f64 = 0;
    for (global_residual, current, 0..) |value, state_value, row| {
        const scale = group_numerics.residualScale(state_value, row, options);
        const normalized_residual = value / scale;
        const weight =
            reactionSpanRowWeight(normalized_residual, current_norm);
        var predicted_weighted = normalized_residual * weight;
        for (
            workspace.reaction_span_solution[0..column_count],
            0..,
        ) |extent, column| {
            predicted_weighted +=
                workspace.reaction_span_jacobian[
                    row * column_count + column
                ] * extent * step_fraction;
        }
        predicted_norm = @max(
            predicted_norm,
            @abs(predicted_weighted / weight),
        );
    }
    return predicted_norm;
}

pub fn evaluateReactionSpanDerivativeColumn(
    inputs: group_complementarity.ComplementaritySearchInputs,
    workspace: *const group_types.Workspace,
    column: usize,
    direction: i8,
    output_jacobian: []f64,
) !void {
    const available_normalized = if (direction < 0)
        -workspace.reaction_span_lower_bounds[column] /
            inputs.options.maximum_newton_fraction
    else
        workspace.reaction_span_upper_bounds[column] /
            inputs.options.maximum_newton_fraction;
    const probe_magnitude = @min(
        @sqrt(std.math.floatEps(f64)),
        0.125 * available_normalized,
    );
    if (!std.math.isFinite(probe_magnitude) or
        probe_magnitude <= 64 * std.math.floatEps(f64))
    {
        return error.NoAdmissibleComplementarityProbe;
    }
    const normalized_probe =
        @as(f64, @floatFromInt(direction)) * probe_magnitude;
    var transformations =
        reaction_span.zeroTransformations(inputs.parameters);
    try reaction_span.addReactionExtent(
        &transformations,
        workspace.reaction_span_active_reactions[column],
        normalized_probe *
            workspace.reaction_span_extent_scales[column],
        inputs.current_transformations,
        inputs.parameters,
    );
    try group_numerics.transformedVector(
        inputs.scratch,
        inputs.current,
        transformations,
        inputs.monovalent_activity_coefficient,
        inputs.parameters.water_activity_product_mol2_per_m6,
        1,
        inputs.probe_state,
    );
    try group_evaluate.evaluateGlobalResidualAt(
        inputs.scratch,
        inputs.probe_state,
        inputs.parameters,
        inputs.probe_residual,
    );
    for (0..inputs.current.len) |row| {
        const scale = group_numerics.residualScale(
            inputs.current[row],
            row,
            inputs.options,
        );
        const active_weight = reactionSpanRowWeight(
            inputs.global_residual[row] / scale,
            inputs.current_norm,
        );
        output_jacobian[
            row * inputs.column_count + column
        ] = group_numerics.scaledResidualDifference(inputs.current[row], inputs.global_residual[row], inputs.probe_state[row], inputs.probe_residual[row], row, inputs.options) / normalized_probe * active_weight;
    }
}

pub fn reactionSpanDerivativeSideMismatchCount(
    workspace: *const group_types.Workspace,
    column_count: usize,
    ambiguous_columns: []const usize,
    opposite_mask: u64,
    mismatch_columns: ?[]usize,
) usize {
    var mismatch_count: usize = 0;
    for (
        workspace.reaction_span_solution[0..column_count],
        0..,
    ) |solution, column| {
        if (!reactionSpanExtentIsSignificant(
            workspace,
            column,
            solution,
        )) continue;
        const reaction =
            workspace.reaction_span_active_reactions[column];
        const selected_rate =
            workspace.reaction_span_rates[reaction];
        var direction: i8 = if (selected_rate < 0) -1 else 1;
        for (ambiguous_columns, 0..) |ambiguous_column, bit| {
            if (column != ambiguous_column) continue;
            if (opposite_mask &
                (@as(u64, 1) << @intCast(bit)) != 0)
            {
                direction = -direction;
            }
            break;
        }
        if ((solution < 0) != (direction < 0)) {
            if (mismatch_columns) |columns|
                columns[mismatch_count] = column;
            mismatch_count += 1;
        }
    }
    return mismatch_count;
}

pub fn reactionSpanExtentIsSignificant(
    workspace: *const group_types.Workspace,
    column: usize,
    solution: f64,
) bool {
    return reactionSpanExtentSignificanceRatio(workspace, column, solution) > 1;
}

/// Measure a correction against the inventory it spends. A large reverse
/// reservoir cannot make a substantial trace-donor correction disappear.
/// Divide first to preserve this decision under coordinate unit changes.
pub fn reactionSpanExtentSignificanceRatio(
    workspace: *const group_types.Workspace,
    column: usize,
    solution: f64,
) f64 {
    if (solution == 0) return 0;
    const donor_bound = @abs(if (solution < 0)
        workspace.reaction_span_lower_bounds[column]
    else
        workspace.reaction_span_upper_bounds[column]);
    if (donor_bound == 0) return std.math.inf(f64);
    return (@abs(solution) / donor_bound) / (64 * std.math.floatEps(f64));
}

pub const ReactionSideDerivativeInputs = struct {
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    probe_state: []f64,
    probe_residual: []f64,
    current_transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    options: group_types.Options,
    monovalent_activity_coefficient: f64,
    limiting_component_index: usize,
};

pub fn reactionSpanSolutionSideLimitingDerivative(
    inputs: ReactionSideDerivativeInputs,
    reaction: usize,
    extent_scale: f64,
    normalized_lower_bound: f64,
    normalized_upper_bound: f64,
    normalized_solution: f64,
) !f64 {
    if (normalized_solution == 0)
        return std.math.nan(f64);
    const available_normalized = if (normalized_solution < 0)
        -normalized_lower_bound / inputs.options.maximum_newton_fraction
    else
        normalized_upper_bound / inputs.options.maximum_newton_fraction;
    const probe_magnitude = @min(
        std.math.cbrt(std.math.floatEps(f64)),
        0.125 * available_normalized,
    );
    if (!std.math.isFinite(probe_magnitude) or
        probe_magnitude <= 64 * std.math.floatEps(f64))
    {
        return std.math.nan(f64);
    }
    const normalized_probe =
        if (normalized_solution < 0)
            -probe_magnitude
        else
            probe_magnitude;
    var transformations =
        reaction_span.zeroTransformations(inputs.parameters);
    try reaction_span.addReactionExtent(
        &transformations,
        reaction,
        normalized_probe * extent_scale,
        inputs.current_transformations,
        inputs.parameters,
    );
    try group_numerics.transformedVector(
        inputs.scratch,
        inputs.current,
        transformations,
        inputs.monovalent_activity_coefficient,
        inputs.parameters.water_activity_product_mol2_per_m6,
        1,
        inputs.probe_state,
    );
    try group_evaluate.evaluateGlobalResidualAt(
        inputs.scratch,
        inputs.probe_state,
        inputs.parameters,
        inputs.probe_residual,
    );
    const row = inputs.limiting_component_index;
    return group_numerics.scaledResidualDifference(inputs.current[row], inputs.global_residual[row], inputs.probe_state[row], inputs.probe_residual[row], row, inputs.options) / normalized_probe;
}

pub fn reactionSpanExtentBounds(
    scratch: *chemistry.State,
    current: []const f64,
    reaction: usize,
    current_transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    rate_magnitude: f64,
    monovalent_activity_coefficient: f64,
    output: []f64,
) !ReactionSpanExtentBounds {
    if (reaction == reaction_span.carboxyl_reaction_index) {
        const carboxyl_index =
            @typeInfo(aqueous_network.State).@"struct".fields.len +
            2 * @typeInfo(phosphate_network.State).@"struct".fields.len +
            @typeInfo(cation_exchange.Cations).@"struct".fields.len;
        return .{
            .negative_native_extent = current[carboxyl_index],
            .positive_native_extent = @max(
                0,
                parameters.total_carboxyl_sites_mol_per_megagram -
                    current[carboxyl_index],
            ),
        };
    }
    // Validate the immutable anchor and all reaction-specific metadata before
    // treating a failed nonzero trial as an inventory face. This keeps an
    // invalid parameter, binding, or current state from being hidden as a
    // zero-width physical box.
    try evaluateReactionSpanExtent(
        scratch,
        current,
        reaction,
        0,
        current_transformations,
        parameters,
        monovalent_activity_coefficient,
        output,
    );
    return .{
        .negative_native_extent = try maximumReactionSpanExtent(
            scratch,
            current,
            reaction,
            -1,
            current_transformations,
            parameters,
            rate_magnitude,
            monovalent_activity_coefficient,
            output,
        ),
        .positive_native_extent = try maximumReactionSpanExtent(
            scratch,
            current,
            reaction,
            1,
            current_transformations,
            parameters,
            rate_magnitude,
            monovalent_activity_coefficient,
            output,
        ),
    };
}

/// Numerically computes the affine zero-crossing magnitude for the 38
/// reactions confirmed pure linear-add + hard-reject (aqueous, gapon,
/// equilibrium-mineral; see `docs/discrepancy_register.md`'s
/// `PERF-REACTION-SPAN-CLOSED-FORM-001`). Evaluates the (already-correct)
/// `evaluateReactionSpanExtent` at exactly two points -- the validated
/// zero anchor and one small trial step -- to get the exact slope of the
/// affine map, then solves for the magnitude at which the first
/// currently-decreasing component would reach exactly zero. Returns
/// `null` (never a wrong answer) whenever the two mandatory verification
/// checks below don't both hold, so the caller can fall back to the
/// existing bracket-expansion+bisection search unchanged.
fn closedFormReactionSpanExtentMagnitude(
    scratch: *chemistry.State,
    current: []const f64,
    reaction: usize,
    direction: f64,
    current_transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    trial: f64,
    monovalent_activity_coefficient: f64,
    output: []f64,
) !?f64 {
    const count = comptime chemistry.State.packedComponentCount();
    var f0: [count]f64 = undefined;
    var f1: [count]f64 = undefined;
    // The zero anchor is already validated admissible by the caller
    // (`reactionSpanExtentBounds`'s own leading check) -- a failure here
    // would be a configuration/indexing error, not an inventory face, so
    // let it propagate rather than silently falling back.
    try evaluateReactionSpanExtent(
        scratch,
        current,
        reaction,
        0,
        current_transformations,
        parameters,
        monovalent_activity_coefficient,
        &f0,
    );
    evaluateReactionSpanExtent(
        scratch,
        current,
        reaction,
        direction * trial,
        current_transformations,
        parameters,
        monovalent_activity_coefficient,
        &f1,
    ) catch |err| {
        if (reactionSpanExtentInadmissibility(err)) return null;
        return err;
    };
    var candidate = std.math.inf(f64);
    for (f0, f1) |before, after| {
        const slope = (after - before) / trial;
        if (slope >= 0) continue;
        const limit = before / -slope;
        if (limit < candidate) candidate = limit;
    }
    if (!std.math.isFinite(candidate) or candidate < 0) return null;
    // The affine estimate is provably close to the true zero-crossing (the
    // linearization is exact to floating-point precision within this trial
    // step), but a single division essentially never lands bit-for-bit on
    // the exact 1-ULP admissibility boundary the reference bisection
    // converges to -- demanding that impossible precision from raw algebra
    // made the mandatory verification fail almost always in practice (see
    // `PERF-REACTION-SPAN-CLOSED-FORM-001`'s "92.4%% closed-form
    // verification failure" finding). Refine the estimate with a short
    // local search that reuses the bisection's own exact-boundary contract
    // instead.
    const seed_admissible = try reactionSpanExtentAdmissible(
        scratch,
        current,
        reaction,
        direction * candidate,
        current_transformations,
        parameters,
        monovalent_activity_coefficient,
        output,
    );
    return refineClosedFormExtentToExactBoundary(
        scratch,
        current,
        reaction,
        direction,
        current_transformations,
        parameters,
        monovalent_activity_coefficient,
        output,
        candidate,
        seed_admissible,
    );
}

/// Advances a non-negative finite `x` outward by exactly `ulps` representable
/// steps in O(1) via direct IEEE-754 bit-pattern arithmetic. This exists
/// specifically to AVOID the bug that caused `PERF-REACTION-SPAN-CLOSED-FORM-001`'s
/// reverted `ad9a1dc` regression: that version's bracket-expansion walked
/// `step_ulps` one representable step at a time (`while (i < step_ulps) ...
/// nextAfter(...)`), so each doubling round cost O(step_ulps) instead of
/// O(1) -- making the total bracket search cost proportional to the ULP
/// distance to the true boundary rather than to the small, fixed number of
/// doublings, which is exactly what turned a bounded-looking loop into an
/// 18x-and-still-climbing regression on real data. Bit-pattern ordering for
/// non-negative finite doubles matches numeric ordering exactly, so adding
/// to the bit pattern is equivalent to (but O(1) instead of O(n) relative
/// to) chaining `std.math.nextAfter` `ulps` times. Returns `null` if the
/// result would not be finite (`ulps` walked past the largest representable
/// value), so the caller can fall back to the bounded full bisection.
fn advanceUlps(x: f64, ulps: u64) ?f64 {
    std.debug.assert(x >= 0 and std.math.isFinite(x));
    const bits: u64 = @bitCast(x);
    const advanced = std.math.add(u64, bits, ulps) catch return null;
    const result: f64 = @bitCast(advanced);
    if (!std.math.isFinite(result)) return null;
    return result;
}

/// Locally refines an affine estimate that is already within a small number
/// of ULPs of the true zero-crossing to the exact 1-ULP boundary the
/// reference bisection defines as its answer. Walks outward in doubling
/// ULP-count steps (not doubling VALUE, since the seed is already close) to
/// bracket the boundary, then bisects with the same bit-adjacency stopping
/// rule as `bisectionReactionSpanExtent`. Each doubling step is an O(1)
/// `advanceUlps` jump, not a loop, so the whole 64-doubling budget is O(64)
/// regardless of how many ULPs away the true boundary turns out to be --
/// see `advanceUlps`'s doc comment for why that distinction is the entire
/// fix for the previously-reverted regression. Returns `null` to fall back
/// to the trusted full bisection if that budget is exhausted, which should
/// not happen in practice but must never be allowed to ship an unverified
/// answer.
fn refineClosedFormExtentToExactBoundary(
    scratch: *chemistry.State,
    current: []const f64,
    reaction: usize,
    direction: f64,
    current_transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    monovalent_activity_coefficient: f64,
    output: []f64,
    seed: f64,
    seed_admissible: bool,
) !?f64 {
    var lower: f64 = undefined;
    var upper: ?f64 = null;
    if (seed_admissible) {
        lower = seed;
    } else {
        upper = seed;
        lower = 0;
    }
    if (upper == null) {
        var step_ulps: u64 = 1;
        var expansion: u8 = 0;
        while (expansion < 64) : (expansion += 1) {
            const next = advanceUlps(lower, step_ulps) orelse return null;
            if (next == lower) return null;
            if (!try reactionSpanExtentAdmissible(
                scratch,
                current,
                reaction,
                direction * next,
                current_transformations,
                parameters,
                monovalent_activity_coefficient,
                output,
            )) {
                upper = next;
                break;
            }
            lower = next;
            step_ulps *|= 2;
        }
    }
    var high = upper orelse return null;
    while (group_numerics2.admissibilityFractionMidpoint(lower, high)) |middle| {
        if (try reactionSpanExtentAdmissible(
            scratch,
            current,
            reaction,
            direction * middle,
            current_transformations,
            parameters,
            monovalent_activity_coefficient,
            output,
        )) {
            lower = middle;
        } else {
            high = middle;
        }
    }
    return lower;
}

/// Locates the inventory face for one native conservative extent using the
/// same atomic state transaction as production. This intentionally treats
/// H+/OH- as dependent Kw coordinates; `group_numerics.transformedVector` projects them
/// exactly and all remaining negative inventories reject the trial.
///
/// Tries the closed-form affine shortcut first for the 38 confirmed-eligible
/// reactions (`PERF-REACTION-SPAN-CLOSED-FORM-001`); any reaction it declines
/// to answer (ineligible, or either mandatory verification check failed)
/// falls through unchanged to the bracket-expansion+bisection search.
fn maximumReactionSpanExtent(
    scratch: *chemistry.State,
    current: []const f64,
    reaction: usize,
    direction: f64,
    current_transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    rate_magnitude: f64,
    monovalent_activity_coefficient: f64,
    output: []f64,
) !f64 {
    const trial = @max(
        rate_magnitude,
        64 * std.math.floatEps(f64),
    );
    if (reaction_span.reactionSpanExtentIsClosedFormEligible(reaction)) {
        if (try closedFormReactionSpanExtentMagnitude(
            scratch,
            current,
            reaction,
            direction,
            current_transformations,
            parameters,
            trial,
            monovalent_activity_coefficient,
            output,
        )) |magnitude| return magnitude;
    }
    return bisectionReactionSpanExtent(
        scratch,
        current,
        reaction,
        direction,
        current_transformations,
        parameters,
        trial,
        monovalent_activity_coefficient,
        output,
    );
}

/// The original bracket-expansion+bisection search, unchanged, kept
/// independently callable so it remains the fallback path AND a trusted
/// reference implementation for equivalence testing against the closed-form
/// shortcut above.
fn bisectionReactionSpanExtent(
    scratch: *chemistry.State,
    current: []const f64,
    reaction: usize,
    direction: f64,
    current_transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    trial: f64,
    monovalent_activity_coefficient: f64,
    output: []f64,
) !f64 {
    var upper: ?f64 = null;
    var lower: f64 = 0;
    if (!try reactionSpanExtentAdmissible(
        scratch,
        current,
        reaction,
        direction * trial,
        current_transformations,
        parameters,
        monovalent_activity_coefficient,
        output,
    )) {
        // Zero is the validated admissible anchor. Searching this complete
        // ordered-f64 bracket is both faster and more complete than repeatedly
        // halving: a physical face may be the minimum subnormal.
        upper = trial;
    } else {
        lower = trial;
    }

    if (upper == null) {
        var expansion: u8 = 0;
        while (expansion < 48) : (expansion += 1) {
            const next = lower * 2;
            if (!std.math.isFinite(next)) break;
            if (!try reactionSpanExtentAdmissible(
                scratch,
                current,
                reaction,
                direction * next,
                current_transformations,
                parameters,
                monovalent_activity_coefficient,
                output,
            )) {
                upper = next;
                break;
            }
            lower = next;
        }
    }

    // The ordinary rate-seeded, factor-of-two bracket above remains the fast
    // path. If its performance-only expansion budget is exhausted, finish the
    // same exact search against the largest finite extent instead of silently
    // returning an arbitrary interior point.
    var high = upper orelse std.math.floatMax(f64);
    if (upper == null) {
        if (lower == high or try reactionSpanExtentAdmissible(
            scratch,
            current,
            reaction,
            direction * high,
            current_transformations,
            parameters,
            monovalent_activity_coefficient,
            output,
        )) return high;
    }
    while (group_numerics2.admissibilityFractionMidpoint(lower, high)) |middle| {
        if (try reactionSpanExtentAdmissible(
            scratch,
            current,
            reaction,
            direction * middle,
            current_transformations,
            parameters,
            monovalent_activity_coefficient,
            output,
        )) {
            lower = middle;
        } else {
            high = middle;
        }
    }
    return lower;
}

fn reactionSpanExtentAdmissible(
    scratch: *chemistry.State,
    current: []const f64,
    reaction: usize,
    native_extent: f64,
    current_transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    monovalent_activity_coefficient: f64,
    output: []f64,
) !bool {
    evaluateReactionSpanExtent(
        scratch,
        current,
        reaction,
        native_extent,
        current_transformations,
        parameters,
        monovalent_activity_coefficient,
        output,
    ) catch |err| {
        if (reactionSpanExtentInadmissibility(err)) return false;
        return err;
    };
    return true;
}

fn evaluateReactionSpanExtent(
    scratch: *chemistry.State,
    current: []const f64,
    reaction: usize,
    native_extent: f64,
    current_transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    monovalent_activity_coefficient: f64,
    output: []f64,
) !void {
    var transformations = reaction_span.zeroTransformations(parameters);
    try reaction_span.addReactionExtent(
        &transformations,
        reaction,
        native_extent,
        current_transformations,
        parameters,
    );
    try group_numerics.transformedVector(
        scratch,
        current,
        transformations,
        monovalent_activity_coefficient,
        parameters.water_activity_product_mol2_per_m6,
        1,
        output,
    );
}

/// The zero-extent anchor is evaluated without this conversion first. After
/// that succeeds, these errors specifically mean that the finite nonzero
/// extent crossed a nonnegative-inventory or representable-state boundary.
/// All configuration, indexing, conservation, and binding errors propagate.
fn reactionSpanExtentInadmissibility(err: anyerror) bool {
    return switch (err) {
        error.NegativeAqueousState,
        error.NegativePhosphateNetworkState,
        error.NegativeCationExchangeState,
        error.NegativeGeochemistrySolidState,
        error.NegativeCarboxylExchangeState,
        error.NegativeChemistryWaterState,
        error.NegativeSoluteReactionRoundoff,
        error.NonConservativePhosphateSiteUpdate,
        error.NonConservativePhosphateInventoryUpdate,
        error.NonFiniteAqueousReactionFlux,
        error.NonFiniteAqueousTransformation,
        error.NonFiniteAqueousState,
        error.NonFiniteCationExchangeTransformation,
        error.NonFinitePhosphateNetworkFlux,
        error.NonFinitePhosphateNetworkTransformation,
        error.NonFinitePhosphateNetworkState,
        error.NonFiniteGeochemistryTransformation,
        error.NonFiniteGeochemistrySolidState,
        error.NonFiniteMineralExtent,
        error.NonFiniteSoluteReactionTransformation,
        error.NonFiniteCarboxylExchangeState,
        error.NonFiniteChemistryWaterState,
        error.NonFiniteWaterEquilibriumInput,
        error.NonFiniteWaterEquilibriumSolution,
        error.NonFiniteSoluteReactionState,
        => true,
        else => false,
    };
}
pub const solveBoundedReactionSpan = group_solve.__solve.solveBoundedReactionSpan;
pub const solveProjectedReactionSpanLeastSquares = group_solve.__solve.solveProjectedReactionSpanLeastSquares;
pub const reactionSpanProjectedKktSatisfied = group_solve.__solve.reactionSpanProjectedKktSatisfied;

/// Test-only access to the closed-form shortcut and the trusted bisection
/// reference implementation, for `PERF-REACTION-SPAN-CLOSED-FORM-001`'s
/// mandatory equivalence testing. Not used by any production call site.
pub const testOnlyClosedFormReactionSpanExtentMagnitude = closedFormReactionSpanExtentMagnitude;
pub const testOnlyBisectionReactionSpanExtent = bisectionReactionSpanExtent;
pub const testOnlyAdvanceUlps = advanceUlps;
