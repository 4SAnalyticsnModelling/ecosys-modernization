//! `reaction_try` declarations: network.
//!
//! Split out of `reaction_try.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const diagnostic_control = @import("reaction_diagnostic_control.zig");
const chemistry = @import("chemistry_state.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const reaction_span = @import("reaction_search_span.zig");
const __parent = @import("reaction_solver.zig");
const group_acceptance = @import("reaction_try_acceptance.zig");
const group_aliases = @import("reaction_try_aliases.zig");
const reaction_solver_numerics = @import("reaction_solver_numerics.zig");
const reaction_solver_numerics2 = @import("reaction_solver_numerics2.zig");

pub fn meaningfulNewtonMeritDecrease(
    current_norm: f64,
    candidate_norm: f64,
) bool {
    const representation_floor =
        64.0 * std.math.floatEps(f64) * @max(1.0, @abs(current_norm));
    return std.math.isFinite(candidate_norm) and
        current_norm - candidate_norm > representation_floor;
}

pub fn currentSignClippedNativeExtent(
    rate: f64,
    extent_scale: f64,
    normalized_lower: f64,
    normalized_upper: f64,
) f64 {
    if (!std.math.isFinite(rate) or
        !std.math.isFinite(extent_scale) or
        !std.math.isFinite(normalized_lower) or
        !std.math.isFinite(normalized_upper) or
        rate == 0 or
        extent_scale <= 0)
    {
        return 0;
    }
    const lower = normalized_lower * extent_scale;
    const upper = normalized_upper * extent_scale;
    if (!std.math.isFinite(lower) or
        !std.math.isFinite(upper) or
        lower > upper)
    {
        return 0;
    }
    return if (rate < 0)
        std.math.clamp(rate, lower, @min(0, upper))
    else
        std.math.clamp(rate, @max(0, lower), upper);
}

pub const NormalizedExtentBounds = struct {
    lower: f64,
    upper: f64,
};

pub fn reactionRateBranch(rate: f64) i8 {
    return if (rate < 0) -1 else if (rate > 0) 1 else 0;
}

pub fn primaryCurrentFaceBounds(
    rate: f64,
    physical_lower: f64,
    physical_upper: f64,
) NormalizedExtentBounds {
    return switch (reactionRateBranch(rate)) {
        -1 => .{ .lower = physical_lower, .upper = @min(0, physical_upper) },
        0 => .{ .lower = 0, .upper = 0 },
        1 => .{ .lower = @max(0, physical_lower), .upper = physical_upper },
        else => unreachable,
    };
}

pub fn complementarityFaceBounds(
    branch: i8,
    physical_lower: f64,
    physical_upper: f64,
) NormalizedExtentBounds {
    return switch (branch) {
        -1 => .{ .lower = physical_lower, .upper = @min(0, physical_upper) },
        0 => .{ .lower = 0, .upper = 0 },
        1 => .{ .lower = @max(0, physical_lower), .upper = physical_upper },
        else => unreachable,
    };
}

pub const DerivativeSideAvailability = struct {
    negative: bool,
    positive: bool,
};

pub fn physicalDerivativeSidesAvailable(
    physical_lower: f64,
    physical_upper: f64,
) DerivativeSideAvailability {
    return .{
        .negative = physical_lower < 0,
        .positive = physical_upper > 0,
    };
}

fn derivativeColumnFiniteAndNonzero(
    matrix: []const f64,
    row_count: usize,
    column_count: usize,
    column: usize,
) bool {
    var maximum_norm: f64 = 0;
    for (0..row_count) |row| {
        const derivative = matrix[row * column_count + column];
        if (!std.math.isFinite(derivative)) return false;
        maximum_norm = @max(maximum_norm, @abs(derivative));
    }
    return maximum_norm > 0;
}

/// Removes derivative-empty columns before the bounded QR solve. Kept source
/// indices are supplied in `reaction_span_pivots[0..kept_count]`; the existing
/// projected matrix is scratch storage, so compaction performs no allocation.
pub fn compactReactionSpanColumns(
    workspace: *group_aliases.Workspace,
    row_count: usize,
    old_count: usize,
    kept_count: usize,
) void {
    std.debug.assert(kept_count <= old_count);
    for (workspace.reaction_span_pivots[0..kept_count], 0..) |source, target| {
        std.debug.assert(source < old_count);
        workspace.reaction_span_active_reactions[target] =
            workspace.reaction_span_active_reactions[source];
        workspace.reaction_span_extent_scales[target] =
            workspace.reaction_span_extent_scales[source];
        workspace.reaction_span_lower_bounds[target] =
            workspace.reaction_span_lower_bounds[source];
        workspace.reaction_span_upper_bounds[target] =
            workspace.reaction_span_upper_bounds[source];
        workspace.reaction_span_original_lower_bounds[target] =
            workspace.reaction_span_original_lower_bounds[source];
        workspace.reaction_span_original_upper_bounds[target] =
            workspace.reaction_span_original_upper_bounds[source];
        workspace.reaction_span_branch_states[target] =
            workspace.reaction_span_branch_states[source];
    }
    const compacted = workspace.reaction_span_projected_jacobian[0 .. row_count * kept_count];
    for (0..row_count) |row| {
        for (workspace.reaction_span_pivots[0..kept_count], 0..) |source, target| {
            compacted[row * kept_count + target] =
                workspace.reaction_span_jacobian[row * old_count + source];
        }
    }
    @memcpy(
        workspace.reaction_span_jacobian[0 .. row_count * kept_count],
        compacted,
    );
    workspace.reaction_span_active_count = kept_count;
}

/// A successfully evaluated current-side semismooth column is the primary
/// Newton column. The legacy wider one-sided column is retained only when the
/// branch-safe shared probe cannot produce a finite, nonzero column.
pub fn primaryCurrentSideDerivativeValue(
    legacy_fallback: f64,
    current_side_derivative: f64,
    current_side_probe_succeeded: bool,
) f64 {
    return if (current_side_probe_succeeded)
        current_side_derivative
    else
        legacy_fallback;
}

fn evaluateLegacyPrimaryDerivativeColumn(
    inputs: group_aliases.ComplementaritySearchInputs,
    workspace: *group_aliases.Workspace,
    column: usize,
    direction: i8,
    output_jacobian: []f64,
) !bool {
    const available_normalized = if (direction < 0)
        -workspace.reaction_span_lower_bounds[column] /
            inputs.options.maximum_newton_fraction
    else
        workspace.reaction_span_upper_bounds[column] /
            inputs.options.maximum_newton_fraction;
    const normalized_probe_magnitude = @min(
        std.math.cbrt(std.math.floatEps(f64)),
        0.125 * available_normalized,
    );
    if (!std.math.isFinite(normalized_probe_magnitude) or
        normalized_probe_magnitude <= 64 * std.math.floatEps(f64))
    {
        return false;
    }
    const normalized_probe =
        @as(f64, @floatFromInt(direction)) * normalized_probe_magnitude;
    var probe_transformations =
        reaction_span.zeroTransformations(inputs.parameters);
    try reaction_span.addReactionExtent(
        &probe_transformations,
        workspace.reaction_span_active_reactions[column],
        normalized_probe * workspace.reaction_span_extent_scales[column],
        inputs.current_transformations,
        inputs.parameters,
    );
    group_aliases.transformedVector(
        inputs.scratch,
        inputs.current,
        probe_transformations,
        inputs.monovalent_activity_coefficient,
        inputs.parameters.water_activity_product_mol2_per_m6,
        1,
        inputs.probe_state,
    ) catch return false;
    group_aliases.evaluateGlobalResidualAt(
        inputs.scratch,
        inputs.probe_state,
        inputs.parameters,
        inputs.probe_residual,
    ) catch return false;
    var column_norm: f64 = 0;
    for (0..inputs.current.len) |row| {
        const scale = group_aliases.residualScale(
            inputs.current[row],
            row,
            inputs.options,
        );
        const active_weight = group_aliases.reactionSpanRowWeight(
            inputs.global_residual[row] / scale,
            inputs.current_norm,
        );
        const derivative =
            reaction_solver_numerics.scaledResidualDifference(inputs.current[row], inputs.global_residual[row], inputs.probe_state[row], inputs.probe_residual[row], row, inputs.options) / normalized_probe * active_weight;
        if (!std.math.isFinite(derivative)) return false;
        output_jacobian[row * inputs.column_count + column] = derivative;
        column_norm = @max(column_norm, @abs(derivative));
    }
    return column_norm > 0;
}

pub const coordinate_newton_backtracking_trials: u8 = 32;

pub fn coordinateNewtonBacktrackingFraction(
    initial_fraction: f64,
    trial: u8,
) f64 {
    var fraction = initial_fraction;
    for (0..trial) |_| fraction *= 0.5;
    return fraction;
}

test "incremental Newton backtracking is bit-exact" {
    const initial_fractions = [_]f64{
        1,
        0.73125,
        std.math.floatMin(f64),
        std.math.floatTrueMin(f64) * 16,
    };
    for (initial_fractions) |initial_fraction| {
        var incremental = initial_fraction;
        for (0..coordinate_newton_backtracking_trials) |trial| {
            try std.testing.expectEqual(
                @as(u64, @bitCast(coordinateNewtonBacktrackingFraction(
                    initial_fraction,
                    @intCast(trial),
                ))),
                @as(u64, @bitCast(incremental)),
            );
            incremental *= 0.5;
        }
    }
}

test "normalized residual secant differentiates state-dependent scale" {
    const options: group_aliases.Options = .{
        .absolute_tolerance_mol_per_m3 = 1,
        .absolute_tolerance_mol_per_megagram = 1,
        .relative_tolerance = 0.1,
    };
    const normalized_probe = 0.5;
    const derivative = normalizedResidualSecant(
        1,
        2,
        2,
        2,
        0,
        options,
        normalized_probe,
    ) orelse return error.MissingNormalizedResidualSecant;
    const expected = (2.0 / 1.2 - 2.0 / 1.1) / normalized_probe;
    try std.testing.expectApproxEqRel(expected, derivative, 8e-15);
    // A frozen current-state denominator would incorrectly report zero.
    try std.testing.expect(@abs(derivative) > 0);
}

test "uniform combined secant slope uses candidate-state scaling" {
    const options: group_aliases.Options = .{
        .absolute_tolerance_mol_per_m3 = 1,
        .absolute_tolerance_mol_per_megagram = 1,
        .relative_tolerance = 0.1,
    };
    const current = [_]f64{ 1, 2 };
    const residual = [_]f64{ 2, 4 };
    const probe_state = [_]f64{ 2, 4 };
    const probe_residual = [_]f64{ 2, 4 };
    const fraction = 0.5;
    var actual_direction: [2]f64 = undefined;
    for (0..actual_direction.len) |row|
        actual_direction[row] = normalizedResidualSecant(
            current[row],
            residual[row],
            probe_state[row],
            probe_residual[row],
            row,
            options,
            fraction,
        ) orelse return error.MissingNormalizedResidualSecant;
    const slope = uniformRmsDirectionalDerivative(
        &current,
        &residual,
        &actual_direction,
        options,
    ) orelse return error.MissingNormalizedResidualSecant;
    const q0 = [_]f64{ 2.0 / 1.1, 4.0 / 1.2 };
    const expected_merit = @sqrt((q0[0] * q0[0] +
        q0[1] * q0[1]) / 2.0);
    const expected_slope = (q0[0] * actual_direction[0] +
        q0[1] * actual_direction[1]) / (2.0 * expected_merit);
    try std.testing.expectApproxEqRel(expected_slope, slope, 8e-15);
    try std.testing.expect(slope < 0);
}

test "least-change ternary correction matches combined direction and isolates sides" {
    var selected = [_]f64{ 1, 0, 0, 1 };
    const negative = [_]f64{ -2, -3, -4, -5 };
    const positive = [_]f64{ 2, 3, 4, 5 };
    const negative_before = negative;
    const positive_before = positive;
    const solution = [_]f64{ 1, 2 };
    const actual = [_]f64{ 5, 7 };
    try std.testing.expectEqual(
        TernaryDirectionalCorrectionStatus.corrected,
        applyTernaryDirectionalJacobianCorrection(
            &selected,
            &solution,
            &actual,
            2,
            2,
        ),
    );
    for (0..2) |row| {
        var realized: f64 = 0;
        for (solution, 0..) |extent, column|
            realized += selected[row * 2 + column] * extent;
        try std.testing.expectApproxEqRel(actual[row], realized, 8e-15);
    }
    try std.testing.expectEqualSlices(f64, &negative_before, &negative);
    try std.testing.expectEqualSlices(f64, &positive_before, &positive);
}

test "exact ternary directional Jacobian needs no correction" {
    var selected = [_]f64{ 2, 3 };
    const before = selected;
    const solution = [_]f64{ 1, 2 };
    const actual = [_]f64{8};
    try std.testing.expectEqual(
        TernaryDirectionalCorrectionStatus.not_meaningful,
        applyTernaryDirectionalJacobianCorrection(
            &selected,
            &solution,
            &actual,
            1,
            2,
        ),
    );
    try std.testing.expectEqualSlices(f64, &before, &selected);
}

test "ternary correction requires a changed re-solve and non-descent fails closed" {
    const previous = [_]f64{ 1, 2 };
    const stagnant = previous;
    const changed = [_]f64{ 1.000001, 2 };
    try std.testing.expect(!ternarySolutionsMeaningfullyDifferent(
        &previous,
        &stagnant,
    ));
    try std.testing.expect(ternarySolutionsMeaningfullyDifferent(
        &previous,
        &changed,
    ));

    const options: group_aliases.Options = .{
        .absolute_tolerance_mol_per_m3 = 1,
        .absolute_tolerance_mol_per_megagram = 1,
        .relative_tolerance = 0,
    };
    const current = [_]f64{1};
    const residual = [_]f64{1};
    const non_descent = [_]f64{1};
    const slope = uniformRmsDirectionalDerivative(
        &current,
        &residual,
        &non_descent,
        options,
    ) orelse return error.MissingNormalizedResidualSecant;
    try std.testing.expect(slope >= 0);
    var exact_jacobian = [_]f64{1};
    const solution = [_]f64{1};
    try std.testing.expectEqual(
        TernaryDirectionalCorrectionStatus.not_meaningful,
        applyTernaryDirectionalJacobianCorrection(
            &exact_jacobian,
            &solution,
            &non_descent,
            1,
            1,
        ),
    );
}

pub fn clampedScalarCoordinateNewtonExtent(
    numerator: f64,
    denominator: f64,
    lower: f64,
    upper: f64,
) f64 {
    if (!std.math.isFinite(numerator) or
        !std.math.isFinite(denominator) or denominator == 0 or
        !std.math.isFinite(lower) or !std.math.isFinite(upper) or
        lower > upper)
    {
        return 0;
    }
    return std.math.clamp(numerator / denominator, lower, upper);
}

/// Exact merit wins; an exact tie is deterministic in source reaction order.
/// Once a candidate satisfies the owning equilibrium tolerance there is no
/// scientific value in minimizing its already-acceptable residual further.
pub fn coordinateNewtonPricePrecedes(
    candidate_norm: f64,
    candidate_reaction: usize,
    best_norm: f64,
    best_reaction: usize,
) bool {
    if (!std.math.isFinite(candidate_norm)) return false;
    if (candidate_norm < best_norm) return true;
    return candidate_norm == best_norm and
        candidate_reaction < best_reaction;
}

const CoordinateNewtonPrice = struct {
    norm: f64 = std.math.inf(f64),
    reaction: usize = std.math.maxInt(usize),
    fraction: f64 = 0,
    normalized_extent: f64 = 0,
};

const CoordinateNewtonDirection = struct {
    column: usize,
    reaction: usize,
    side: i8,
    least_squares_extent: f64,
    limiting_extent: f64,
    predicted_score: f64,
};

/// Coordinate search order is derived only from the current exact Jacobian.
/// Lower predicted residual wins, then the translated source reaction and
/// one-sided face provide stable ties. This keeps the solve reproducible
/// without retaining history in a worker workspace.
pub fn predictedCoordinateDirectionPrecedes(
    left_score: f64,
    left_reaction: usize,
    left_side: i8,
    right_score: f64,
    right_reaction: usize,
    right_side: i8,
) bool {
    if (!std.math.isFinite(left_score)) return false;
    if (!std.math.isFinite(right_score)) return true;
    if (left_score != right_score) return left_score < right_score;
    if (left_reaction != right_reaction) return left_reaction < right_reaction;
    return left_side < right_side;
}

const CoordinateNewtonDirectionOrder = struct {
    fn lessThan(_: void, left: CoordinateNewtonDirection, right: CoordinateNewtonDirection) bool {
        return predictedCoordinateDirectionPrecedes(
            left.predicted_score,
            left.reaction,
            left.side,
            right.predicted_score,
            right.reaction,
            right.side,
        );
    }
};

const CoordinateNewtonRateOrder = struct {
    rates: []const f64,

    fn lessThan(context: CoordinateNewtonRateOrder, left: usize, right: usize) bool {
        const left_rate = @abs(context.rates[left]);
        const right_rate = @abs(context.rates[right]);
        if (left_rate != right_rate) return left_rate > right_rate;
        return left < right;
    }
};

test "coordinate Newton prediction order is merit first and source stable" {
    try std.testing.expect(predictedCoordinateDirectionPrecedes(
        0.25,
        30,
        1,
        0.5,
        0,
        -1,
    ));
    try std.testing.expect(predictedCoordinateDirectionPrecedes(
        0.5,
        4,
        1,
        0.5,
        5,
        -1,
    ));
    try std.testing.expect(predictedCoordinateDirectionPrecedes(
        0.5,
        4,
        -1,
        0.5,
        4,
        1,
    ));
    try std.testing.expect(!predictedCoordinateDirectionPrecedes(
        std.math.nan(f64),
        0,
        -1,
        0.5,
        1,
        1,
    ));
}

pub const two_axis_newton_top_column_count: usize = 8;
pub const two_axis_newton_max_face_pairs: usize = 112;
pub const active_row_newton_backtracking_trials: usize = 32;
pub const reduced_block_newton_max_column_count: usize = 8;
/// An active-row candidate has already been assembled from conservative
/// reaction extents, projected onto water equilibrium, checked for finite
/// nonnegative inventories, and globally residual-priced before reaching this
/// gate.  A scaled norm at or below one is the same acceptance criterion used
/// by the owning equilibrium loop; searching tens of thousands of additional
/// face pairs can only choose a numerically smaller already-acceptable state.
pub fn activeRowCandidateAcceptable(candidate_norm: f64) bool {
    return std.math.isFinite(candidate_norm) and candidate_norm <= 1;
}

pub const active_row_newton_stagnation_patience: usize = 35;

/// Recovery patience uses a relative square-root-epsilon floor so numerical
/// noise cannot reset the counter indefinitely. The best finite state is still
/// retained even when an improvement is smaller than this progress floor.
pub fn activeRowSearchMateriallyImproves(
    previous_best_norm: f64,
    best_norm: f64,
) bool {
    if (!std.math.isFinite(best_norm) or best_norm < 0) return false;
    if (!std.math.isFinite(previous_best_norm)) return true;
    const progress_floor = std.math.sqrt(std.math.floatEps(f64)) *
        @max(1.0, previous_best_norm);
    return previous_best_norm - best_norm > progress_floor;
}

const ActiveRowPair = struct {
    left: usize,
    right: usize,
    left_side: i8,
    right_side: i8,
};

fn activeRowPairKey(pair: ActiveRowPair) usize {
    var key = pair.left * reaction_span.reaction_count + pair.right;
    key = key * 2 + @as(usize, if (pair.left_side > 0) 1 else 0);
    return key * 2 + @as(usize, if (pair.right_side > 0) 1 else 0);
}

fn activeRowPairFromKey(key_value: usize) ActiveRowPair {
    var key = key_value;
    const right_side: i8 = if (key % 2 == 0) -1 else 1;
    key /= 2;
    const left_side: i8 = if (key % 2 == 0) -1 else 1;
    key /= 2;
    return .{
        .left = key / reaction_span.reaction_count,
        .right = key % reaction_span.reaction_count,
        .left_side = left_side,
        .right_side = right_side,
    };
}

const ActiveRowPairOrderContext = struct {
    keys: []const usize,
    predicted_scores: []const f64,

    fn lessThan(context: ActiveRowPairOrderContext, left: usize, right: usize) bool {
        const left_score = context.predicted_scores[left];
        const right_score = context.predicted_scores[right];
        if (left_score != right_score) return left_score < right_score;
        return context.keys[left] < context.keys[right];
    }
};

pub fn activeRowNewtonWorstCaseProbeCount(active_count: usize) usize {
    if (active_count < 2) return 2 * active_count;
    const face_pairs = 4 * active_count * (active_count - 1) / 2;
    return 2 * active_count +
        active_row_newton_backtracking_trials * face_pairs;
}

const TwoAxisNewtonPrice = struct {
    norm: f64 = std.math.inf(f64),
    reaction_a: usize = std.math.maxInt(usize),
    reaction_b: usize = std.math.maxInt(usize),
    side_a: i8 = 0,
    side_b: i8 = 0,
    fraction: f64 = 0,
    normalized_extent_a: f64 = 0,
    normalized_extent_b: f64 = 0,
};

const ReducedBlockFace = struct {
    column: usize = std.math.maxInt(usize),
    reaction: usize = std.math.maxInt(usize),
    side: i8 = 0,
    score: f64 = -std.math.inf(f64),
};

fn reducedBlockFacePrecedes(candidate: ReducedBlockFace, ranked: ReducedBlockFace) bool {
    if (!std.math.isFinite(candidate.score)) return false;
    if (candidate.score != ranked.score) return candidate.score > ranked.score;
    if (candidate.reaction != ranked.reaction)
        return candidate.reaction < ranked.reaction;
    return candidate.side < ranked.side;
}

pub const ActiveRowFaceProjection = struct {
    rows: [2]f64,
    self_dot: f64,
    rhs_dot: f64,
};

pub fn activeRowFaceProjection(
    jacobian: []const f64,
    active_count: usize,
    column: usize,
    active_rows: [2]usize,
    row_weights: [2]f64,
    row_rhs: [2]f64,
) ActiveRowFaceProjection {
    const rows = [2]f64{
        jacobian[active_rows[0] * active_count + column] / row_weights[0],
        jacobian[active_rows[1] * active_count + column] / row_weights[1],
    };
    return .{
        .rows = rows,
        .self_dot = rows[0] * rows[0] + rows[1] * rows[1],
        .rhs_dot = rows[0] * row_rhs[0] + rows[1] * row_rhs[1],
    };
}

/// Higher normalized reaction-span leverage wins; exact ties retain source
/// reaction order.
pub fn twoAxisNewtonColumnRankPrecedes(
    candidate_score: f64,
    candidate_reaction: usize,
    ranked_score: f64,
    ranked_reaction: usize,
) bool {
    if (!std.math.isFinite(candidate_score)) return false;
    if (candidate_score > ranked_score) return true;
    return candidate_score == ranked_score and
        candidate_reaction < ranked_reaction;
}

/// Exact merit wins. Equal merits are ordered by the canonical source-axis
/// pair and then by the deterministic negative-before-positive face order.
pub fn twoAxisNewtonPricePrecedes(
    candidate_norm: f64,
    candidate_reaction_a: usize,
    candidate_reaction_b: usize,
    candidate_side_a: i8,
    candidate_side_b: i8,
    best_norm: f64,
    best_reaction_a: usize,
    best_reaction_b: usize,
    best_side_a: i8,
    best_side_b: i8,
) bool {
    if (!std.math.isFinite(candidate_norm)) return false;
    if (candidate_norm != best_norm) return candidate_norm < best_norm;
    if (candidate_reaction_a != best_reaction_a)
        return candidate_reaction_a < best_reaction_a;
    if (candidate_reaction_b != best_reaction_b)
        return candidate_reaction_b < best_reaction_b;
    if (candidate_side_a != best_side_a)
        return candidate_side_a < best_side_a;
    return candidate_side_b < best_side_b;
}

/// Exact bounded solution of a two-column weighted least-squares normal
/// system. The four box corners and each edge optimum are included, so a
/// singular free solution cannot hide a valid bounded Newton direction.
pub fn boundedTwoAxisLeastSquares(
    a11: f64,
    a12: f64,
    a22: f64,
    b1: f64,
    b2: f64,
    lower1: f64,
    upper1: f64,
    lower2: f64,
    upper2: f64,
) [2]f64 {
    if (!std.math.isFinite(a11) or !std.math.isFinite(a12) or
        !std.math.isFinite(a22) or !std.math.isFinite(b1) or
        !std.math.isFinite(b2) or !std.math.isFinite(lower1) or
        !std.math.isFinite(upper1) or !std.math.isFinite(lower2) or
        !std.math.isFinite(upper2) or lower1 > upper1 or lower2 > upper2)
    {
        return .{ 0, 0 };
    }
    var candidates: [9][2]f64 = undefined;
    var count: usize = 0;
    const determinant = a11 * a22 - a12 * a12;
    if (std.math.isFinite(determinant) and determinant != 0) {
        candidates[count] = .{
            (b1 * a22 - b2 * a12) / determinant,
            (a11 * b2 - a12 * b1) / determinant,
        };
        count += 1;
    }
    for ([_]f64{ lower1, upper1 }) |x| {
        candidates[count] = .{ x, if (a22 != 0)
            std.math.clamp((b2 - a12 * x) / a22, lower2, upper2)
        else
            0 };
        count += 1;
    }
    for ([_]f64{ lower2, upper2 }) |y| {
        candidates[count] = .{ if (a11 != 0)
            std.math.clamp((b1 - a12 * y) / a11, lower1, upper1)
        else
            0, y };
        count += 1;
    }
    for ([_]f64{ lower1, upper1 }) |x| {
        for ([_]f64{ lower2, upper2 }) |y| {
            candidates[count] = .{ x, y };
            count += 1;
        }
    }
    var best = [2]f64{ 0, 0 };
    var best_objective = std.math.inf(f64);
    for (candidates[0..count]) |candidate| {
        if (candidate[0] < lower1 or candidate[0] > upper1 or
            candidate[1] < lower2 or candidate[1] > upper2) continue;
        const objective = a11 * candidate[0] * candidate[0] +
            2 * a12 * candidate[0] * candidate[1] +
            a22 * candidate[1] * candidate[1] -
            2 * b1 * candidate[0] - 2 * b2 * candidate[1];
        if (objective < best_objective) {
            best_objective = objective;
            best = candidate;
        }
    }
    return best;
}

pub fn topTwoScaledResidualRows(
    current: []const f64,
    residual: []const f64,
    options: group_aliases.Options,
) ?[2]usize {
    if (current.len != residual.len or current.len < 2) return null;
    var rows = [_]usize{std.math.maxInt(usize)} ** 2;
    var magnitudes = [_]f64{-std.math.inf(f64)} ** 2;
    for (current, residual, 0..) |value, change, row| {
        const magnitude = @abs(
            change / group_aliases.residualScale(value, row, options),
        );
        if (!std.math.isFinite(magnitude)) continue;
        if (magnitude > magnitudes[0]) {
            magnitudes[1] = magnitudes[0];
            rows[1] = rows[0];
            magnitudes[0] = magnitude;
            rows[0] = row;
        } else if (magnitude > magnitudes[1]) {
            magnitudes[1] = magnitude;
            rows[1] = row;
        }
    }
    if (rows[1] == std.math.maxInt(usize)) return null;
    // Magnitude chooses the active two-equation set; it must not also reorder
    // that set. The 2xN least-squares system is row-permutation invariant in
    // exact arithmetic, while a stable packed/source order avoids changing
    // floating accumulation and line-search trajectories when scaling changes.
    // This also follows SOLUTE.f:822 onward, whose fixed MRXN iteration visits
    // reaction-state equations in source order.
    if (rows[0] > rows[1]) std.mem.swap(usize, &rows[0], &rows[1]);
    return rows;
}

fn priceScalarCoordinateNewtonDirection(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    priced_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    reaction: usize,
    normalized_extent: f64,
    native_extent_scale: f64,
    backtracking_trials: u8,
    best: *CoordinateNewtonPrice,
) !bool {
    if (normalized_extent == 0 or backtracking_trials == 0) return false;
    std.debug.assert(backtracking_trials <= coordinate_newton_backtracking_trials);
    var transformations = reaction_span.zeroTransformations(parameters);
    try reaction_span.addReactionExtent(
        &transformations,
        reaction,
        normalized_extent * native_extent_scale,
        current_transformations,
        parameters,
    );
    _ = group_aliases.transformedVectorAdmissible(
        scratch,
        current,
        transformations,
        parameters,
        1,
        candidate_state,
    ) catch return false;
    const initial_fraction = group_aliases.phosphateTrustRegionFraction(
        current,
        candidate_state,
        options,
        parameters.phosphate_kinetics.substrate_limit_fraction,
    );
    var valid = false;
    var fraction = initial_fraction;
    for (0..backtracking_trials) |_| {
        defer fraction *= 0.5;
        const candidate_norm = group_aliases.evaluateCandidateResidualAtFraction(
            scratch,
            current,
            candidate_state,
            priced_state,
            residual_work,
            parameters,
            options,
            fraction,
        ) catch continue;
        valid = true;
        if (coordinateNewtonPricePrecedes(
            candidate_norm,
            reaction,
            best.norm,
            best.reaction,
        )) {
            best.* = .{
                .norm = candidate_norm,
                .reaction = reaction,
                .fraction = fraction,
                .normalized_extent = normalized_extent,
            };
            @memcpy(workspace.reaction_span_best_state, priced_state);
            @memcpy(workspace.reaction_span_best_residual, residual_work);
            if (activeRowCandidateAcceptable(candidate_norm)) return true;
        }
    }
    return valid;
}

fn priceGaponSwapNewtonDirection(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    candidate_state: []f64,
    priced_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    first_local_column: usize,
    second_local_column: usize,
    normalized_extent: f64,
    native_extent_scale: f64,
    best: *CoordinateNewtonPrice,
) !void {
    if (normalized_extent == 0) return;
    var transformations = reaction_span.zeroTransformations(parameters);
    try reaction_span.addGaponSwapExtent(
        &transformations,
        first_local_column,
        second_local_column,
        normalized_extent * native_extent_scale,
        parameters.fractions,
    );
    _ = group_aliases.transformedVectorAdmissible(
        scratch,
        current,
        transformations,
        parameters,
        1,
        candidate_state,
    ) catch return;
    const initial_fraction = group_aliases.phosphateTrustRegionFraction(
        current,
        candidate_state,
        options,
        parameters.phosphate_kinetics.substrate_limit_fraction,
    );
    var fraction = initial_fraction;
    for (0..coordinate_newton_backtracking_trials) |_| {
        defer fraction *= 0.5;
        const candidate_norm = group_aliases.evaluateCandidateResidualAtFraction(
            scratch,
            current,
            candidate_state,
            priced_state,
            residual_work,
            parameters,
            options,
            fraction,
        ) catch continue;
        const reaction_key = reaction_span.gapon_reaction_offset +
            first_local_column;
        if (!coordinateNewtonPricePrecedes(
            candidate_norm,
            reaction_key,
            best.norm,
            best.reaction,
        )) continue;
        best.* = .{
            .norm = candidate_norm,
            .reaction = reaction_key,
            .fraction = fraction,
            .normalized_extent = normalized_extent,
        };
        @memcpy(workspace.reaction_span_best_state, priced_state);
        @memcpy(workspace.reaction_span_best_residual, residual_work);
        if (activeRowCandidateAcceptable(candidate_norm)) return;
    }
}

const GaponSwapBounds = struct {
    lower: f64,
    upper: f64,
};

fn gaponSwapBounds(
    first_aqueous: f64,
    first_exchange: f64,
    first_ratio: f64,
    first_valence: f64,
    second_aqueous: f64,
    second_exchange: f64,
    second_ratio: f64,
    second_valence: f64,
) ?GaponSwapBounds {
    const values = [_]f64{
        first_aqueous,
        first_exchange,
        first_ratio,
        first_valence,
        second_aqueous,
        second_exchange,
        second_ratio,
        second_valence,
    };
    for (values) |value| if (!std.math.isFinite(value) or value < 0)
        return null;
    if (first_ratio == 0 or second_ratio == 0 or
        first_valence == 0 or second_valence == 0) return null;
    const second_per_first = first_valence / second_valence;
    return .{
        // Negative first extent desorbs the first ion and adsorbs the second.
        .lower = -@min(
            first_exchange,
            second_aqueous / (second_ratio * second_per_first),
        ),
        // Positive first extent adsorbs the first ion and desorbs the second.
        .upper = @min(
            first_aqueous / first_ratio,
            second_exchange / second_per_first,
        ),
    };
}

fn gaponBasisAqueousInventory(state: *const chemistry.State, local: usize) ?f64 {
    return switch (local) {
        0 => state.aqueous[0].ammonium_non_band,
        1 => state.aqueous[0].ammonium_band,
        2 => state.aqueous[0].hydrogen,
        3 => state.aqueous[0].aluminum,
        4 => state.aqueous[0].iron,
        5 => state.aqueous[0].magnesium,
        6 => state.aqueous[0].sodium,
        7 => state.aqueous[0].potassium,
        else => null,
    };
}

fn gaponBasisExchangeInventory(state: *const chemistry.State, local: usize) ?f64 {
    const exchange = state.cation_exchange_mol_per_megagram[0];
    return switch (local) {
        0 => exchange.ammonium_non_band,
        1 => exchange.ammonium_band,
        2 => exchange.hydrogen,
        3 => exchange.aluminum,
        4 => exchange.iron,
        5 => exchange.magnesium,
        6 => exchange.sodium,
        7 => exchange.potassium,
        else => null,
    };
}

fn gaponBasisOwnerRatio(
    parameters: chemistry.ReactionParameters,
    local: usize,
) ?f64 {
    return switch (local) {
        0 => parameters.cation_exchange_water_ratios
            .ammonium_non_band_megagrams_per_m3,
        1 => parameters.cation_exchange_water_ratios
            .ammonium_band_megagrams_per_m3,
        2...7 => parameters.cation_exchange_water_ratios.shared_megagrams_per_m3,
        else => null,
    };
}

fn priceTwoAxisNewtonDirection(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    priced_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    column_a: usize,
    column_b: usize,
    side_a: i8,
    side_b: i8,
    normalized_extent_a: f64,
    normalized_extent_b: f64,
    best: *TwoAxisNewtonPrice,
) !void {
    if (normalized_extent_a == 0 and normalized_extent_b == 0) return;
    const reaction_a = workspace.reaction_span_active_reactions[column_a];
    const reaction_b = workspace.reaction_span_active_reactions[column_b];
    var transformations = reaction_span.zeroTransformations(parameters);
    if (normalized_extent_a != 0) try reaction_span.addReactionExtent(
        &transformations,
        reaction_a,
        normalized_extent_a * workspace.reaction_span_extent_scales[column_a],
        current_transformations,
        parameters,
    );
    if (normalized_extent_b != 0) try reaction_span.addReactionExtent(
        &transformations,
        reaction_b,
        normalized_extent_b * workspace.reaction_span_extent_scales[column_b],
        current_transformations,
        parameters,
    );
    _ = group_aliases.transformedVectorAdmissible(
        scratch,
        current,
        transformations,
        parameters,
        1,
        candidate_state,
    ) catch return;
    const initial_fraction = group_aliases.phosphateTrustRegionFraction(
        current,
        candidate_state,
        options,
        parameters.phosphate_kinetics.substrate_limit_fraction,
    );
    const swap = reaction_b < reaction_a;
    const ordered_reaction_a = if (swap) reaction_b else reaction_a;
    const ordered_reaction_b = if (swap) reaction_a else reaction_b;
    const ordered_side_a = if (swap) side_b else side_a;
    const ordered_side_b = if (swap) side_a else side_b;
    const ordered_extent_a = if (swap)
        normalized_extent_b
    else
        normalized_extent_a;
    const ordered_extent_b = if (swap)
        normalized_extent_a
    else
        normalized_extent_b;
    var fraction = initial_fraction;
    for (0..coordinate_newton_backtracking_trials) |_| {
        defer fraction *= 0.5;
        const candidate_norm = group_aliases.evaluateCandidateResidualAtFraction(
            scratch,
            current,
            candidate_state,
            priced_state,
            residual_work,
            parameters,
            options,
            fraction,
        ) catch continue;
        if (!twoAxisNewtonPricePrecedes(
            candidate_norm,
            ordered_reaction_a,
            ordered_reaction_b,
            ordered_side_a,
            ordered_side_b,
            best.norm,
            best.reaction_a,
            best.reaction_b,
            best.side_a,
            best.side_b,
        )) continue;
        best.* = .{
            .norm = candidate_norm,
            .reaction_a = ordered_reaction_a,
            .reaction_b = ordered_reaction_b,
            .side_a = ordered_side_a,
            .side_b = ordered_side_b,
            .fraction = fraction,
            .normalized_extent_a = ordered_extent_a,
            .normalized_extent_b = ordered_extent_b,
        };
        @memcpy(workspace.reaction_span_best_state, priced_state);
        @memcpy(workspace.reaction_span_best_residual, residual_work);
    }
}

pub const active_boundary_surface_axis_limit: usize = 5;
pub const active_boundary_surface_combination_limit: usize = 15;

pub const ActiveBoundaryRecoveryKind = enum {
    none,
    newton,
    anderson,
};

pub const ActiveBoundaryRecoveryFilter = enum {
    any,
    newton,
    anderson,
};

pub fn activeBoundarySurfaceNativeExtent(
    rate: f64,
    negative_native_extent: f64,
    positive_native_extent: f64,
) f64 {
    if (!std.math.isFinite(rate) or rate == 0 or
        !std.math.isFinite(negative_native_extent) or
        !std.math.isFinite(positive_native_extent) or
        negative_native_extent < 0 or positive_native_extent < 0)
        return 0;
    return if (rate < 0)
        -negative_native_extent
    else
        positive_native_extent;
}

const ActiveBoundaryCompositePrice = struct {
    norm: f64 = std.math.inf(f64),
    fraction: f64 = 0,
};

fn priceActiveBoundaryComposite(
    scratch: *chemistry.State,
    current: []const f64,
    target: []const f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    priced_state: []f64,
    priced_residual: []f64,
) !ActiveBoundaryCompositePrice {
    const initial_fraction = group_aliases.phosphateTrustRegionFraction(
        current,
        target,
        options,
        parameters.phosphate_kinetics.substrate_limit_fraction,
    );
    const component_count = comptime chemistry.State.packedComponentCount();
    var candidate_state: [component_count]f64 = undefined;
    var candidate_residual: [component_count]f64 = undefined;
    var best = ActiveBoundaryCompositePrice{};
    var fraction = initial_fraction;
    for (0..coordinate_newton_backtracking_trials) |_| {
        defer fraction *= 0.5;
        const norm = group_aliases.evaluateCandidateResidualAtFraction(
            scratch,
            current,
            target,
            &candidate_state,
            &candidate_residual,
            parameters,
            options,
            fraction,
        ) catch continue;
        if (norm >= best.norm) continue;
        best = .{ .norm = norm, .fraction = fraction };
        @memcpy(priced_state, &candidate_state);
        @memcpy(priced_residual, &candidate_residual);
    }
    return best;
}

fn retainActiveBoundaryComposite(
    candidate: ActiveBoundaryCompositePrice,
    kind: ActiveBoundaryRecoveryKind,
    candidate_state: []const f64,
    candidate_residual: []const f64,
    best: *ActiveBoundaryCompositePrice,
    best_kind: *ActiveBoundaryRecoveryKind,
    best_state: []f64,
    best_residual: []f64,
) void {
    // Singles, then source-ordered pairs, and Newton before Anderson define
    // the deterministic tie order. Exact ties retain the earlier candidate.
    if (!std.math.isFinite(candidate.norm) or candidate.norm >= best.norm)
        return;
    best.* = candidate;
    best_kind.* = kind;
    @memcpy(best_state, candidate_state);
    @memcpy(best_residual, candidate_residual);
}

/// Continues a conservative Newton trajectory from a private inventory-face
/// state. The published candidate is always re-priced from `current`; neither
/// the boundary state nor any intermediate relinearization can escape if the
/// complete exact residual does not improve.
fn tryInventoryBoundaryContinuationFromState(
    workspace: *group_aliases.Workspace,
    current: []const f64,
    initial_boundary_state: []const f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
) !bool {
    const component_count = comptime chemistry.State.packedComponentCount();
    if (initial_boundary_state.len != component_count) return false;
    var boundary_state: [component_count]f64 = undefined;
    @memcpy(&boundary_state, initial_boundary_state);
    var recovery_transformations = group_aliases.evaluateAt(
        &workspace.scratch,
        &boundary_state,
        parameters,
    ) catch return false;
    var boundary_residual: [component_count]f64 = undefined;
    _ = group_aliases.transformedVectorAdmissible(
        &workspace.scratch,
        &boundary_state,
        recovery_transformations,
        parameters,
        1,
        &boundary_residual,
    ) catch return false;
    for (&boundary_residual, boundary_state) |*change, value|
        change.* -= value;
    var recovery_norm = group_aliases.scaledNorm(
        &boundary_state,
        &boundary_residual,
        options,
    ) catch return false;

    var recovered_state: [component_count]f64 = undefined;
    var recovered_residual: [component_count]f64 = undefined;
    var best_composite_state: [component_count]f64 = undefined;
    var best_composite_residual: [component_count]f64 = undefined;
    var best_composite_norm = std.math.inf(f64);
    for (0..4) |_| {
        if (!try tryActiveRowNewtonCandidate(
            workspace,
            &workspace.scratch,
            &boundary_state,
            &boundary_residual,
            recovery_transformations,
            workspace.candidate_state,
            &recovered_state,
            &recovered_residual,
            parameters,
            options,
            recovery_norm,
        )) break;
        @memcpy(&boundary_state, &recovered_state);
        @memcpy(&boundary_residual, &recovered_residual);
        recovery_norm = try group_aliases.scaledNorm(
            &boundary_state,
            &boundary_residual,
            options,
        );
        const price = try priceActiveBoundaryComposite(
            &workspace.scratch,
            current,
            &boundary_state,
            parameters,
            options,
            accepted_state,
            residual_work,
        );
        if (price.norm < best_composite_norm) {
            best_composite_norm = price.norm;
            @memcpy(&best_composite_state, accepted_state);
            @memcpy(&best_composite_residual, residual_work);
        }
        if (best_composite_norm <= 1) break;
        recovery_transformations = group_aliases.evaluateAt(
            &workspace.scratch,
            &boundary_state,
            parameters,
        ) catch break;
    }
    if (!meaningfulNewtonMeritDecrease(current_norm, best_composite_norm))
        return false;
    @memcpy(accepted_state, &best_composite_state);
    @memcpy(residual_work, &best_composite_residual);
    return true;
}

/// Newton face pivot at the first inventory boundary reached by the complete
/// conservative reaction map. The boundary is a private linearization point;
/// only a finite, admissible strict-merit-decrease composite from `current`
/// can be returned.
pub fn tryGlobalInventoryBoundaryRecoveryCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    current_transformations: chemistry.CellTransformations,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
) !bool {
    diagnostic_control.recordStrategyCall(.global_inventory_boundary_recovery);
    var diagnostic_strategy_scope = diagnostic_control.enterStrategy(.global_inventory_boundary_recovery);
    defer diagnostic_strategy_scope.deinit();
    const component_count = comptime chemistry.State.packedComponentCount();
    var boundary_state: [component_count]f64 = undefined;
    const boundary_fraction = group_aliases.transformedVectorAdmissible(
        scratch,
        current,
        current_transformations,
        parameters,
        1,
        &boundary_state,
    ) catch return false;
    if (boundary_fraction >= 1) return false;

    return tryInventoryBoundaryContinuationFromState(
        workspace,
        current,
        &boundary_state,
        accepted_state,
        residual_work,
        parameters,
        options,
        current_norm,
    );
}

fn evaluateActiveBoundarySurfaceCombination(
    workspace: *group_aliases.Workspace,
    current: []const f64,
    current_transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    reactions: []const usize,
    native_extents: []const f64,
    first_axis: usize,
    second_axis: ?usize,
    recovery_filter: ActiveBoundaryRecoveryFilter,
    recovered_constructed: *usize,
    recovered_valid: *usize,
    best: *ActiveBoundaryCompositePrice,
    best_kind: *ActiveBoundaryRecoveryKind,
    best_state: []f64,
    best_residual: []f64,
) !void {
    const component_count = comptime chemistry.State.packedComponentCount();
    var boundary_transformations = reaction_span.zeroTransformations(parameters);
    try reaction_span.addReactionExtent(
        &boundary_transformations,
        reactions[first_axis],
        native_extents[first_axis],
        current_transformations,
        parameters,
    );
    if (second_axis) |axis| try reaction_span.addReactionExtent(
        &boundary_transformations,
        reactions[axis],
        native_extents[axis],
        current_transformations,
        parameters,
    );

    var boundary_state: [component_count]f64 = undefined;
    _ = group_aliases.transformedVectorAdmissible(
        &workspace.scratch,
        current,
        boundary_transformations,
        parameters,
        1,
        &boundary_state,
    ) catch return;
    const boundary_changes = group_aliases.evaluateAt(
        &workspace.scratch,
        &boundary_state,
        parameters,
    ) catch return;
    var boundary_defect: [component_count]f64 = undefined;
    _ = group_aliases.transformedVectorAdmissible(
        &workspace.scratch,
        &boundary_state,
        boundary_changes,
        parameters,
        1,
        &boundary_defect,
    ) catch return;
    for (&boundary_defect, boundary_state) |*change, value|
        change.* -= value;
    const boundary_norm = group_aliases.scaledNorm(
        &boundary_state,
        &boundary_defect,
        options,
    ) catch return;
    var newton_target: [component_count]f64 = undefined;
    var newton_target_residual: [component_count]f64 = undefined;
    if (recovery_filter != .anderson and
        try tryFullNetworkReactionCandidate(
            workspace,
            &workspace.scratch,
            &boundary_state,
            &boundary_defect,
            boundary_changes,
            workspace.candidate_state,
            &newton_target,
            &newton_target_residual,
            parameters,
            options,
            boundary_norm,
            null,
            null,
        ))
    {
        recovered_constructed.* += 1;
        var priced_state: [component_count]f64 = undefined;
        var priced_residual: [component_count]f64 = undefined;
        const price = try priceActiveBoundaryComposite(
            &workspace.scratch,
            current,
            &newton_target,
            parameters,
            options,
            &priced_state,
            &priced_residual,
        );
        if (std.math.isFinite(price.norm)) recovered_valid.* += 1;
        retainActiveBoundaryComposite(
            price,
            .newton,
            &priced_state,
            &priced_residual,
            best,
            best_kind,
            best_state,
            best_residual,
        );
    }

    // The source-map point is a seed only. Only a genuine Anderson affine
    // candidate, globally damped from the private boundary, can become the
    // composite target priced from `current`.
    if (recovery_filter == .newton) return;

    const refreshed_changes = group_aliases.evaluateAt(
        &workspace.scratch,
        &boundary_state,
        parameters,
    ) catch return;
    var seed_state: [component_count]f64 = undefined;
    _ = group_aliases.transformedVectorAdmissible(
        &workspace.scratch,
        &boundary_state,
        refreshed_changes,
        parameters,
        options.picard_relaxation,
        &seed_state,
    ) catch return;
    var seed_defect: [component_count]f64 = undefined;
    group_aliases.evaluateGlobalResidualAt(
        &workspace.scratch,
        &seed_state,
        parameters,
        &seed_defect,
    ) catch return;
    var anderson_target: [component_count]f64 = undefined;
    if (!reaction_solver_numerics.scaledAndersonDepthOneCandidate(
        &boundary_state,
        &boundary_defect,
        &seed_state,
        &seed_defect,
        options,
        &anderson_target,
    )) return;
    var boundary_recovered: [component_count]f64 = undefined;
    var boundary_recovered_residual: [component_count]f64 = undefined;
    if (!try group_acceptance.tryAcceptAndersonCandidate(
        &workspace.scratch,
        &boundary_state,
        &anderson_target,
        &boundary_recovered,
        &boundary_recovered_residual,
        parameters,
        options,
        boundary_norm,
    )) return;
    var priced_state: [component_count]f64 = undefined;
    var priced_residual: [component_count]f64 = undefined;
    const price = try priceActiveBoundaryComposite(
        &workspace.scratch,
        current,
        &boundary_recovered,
        parameters,
        options,
        &priced_state,
        &priced_residual,
    );
    retainActiveBoundaryComposite(
        price,
        .anderson,
        &priced_state,
        &priced_residual,
        best,
        best_kind,
        best_state,
        best_residual,
    );
}

/// Last-resort active-set lookahead for the five finite phosphate surface
/// axes. The boundary and its Picard seed are private construction points;
/// only one recovered Newton/Anderson composite can be returned, after exact
/// global pricing and the same meaningful-decrease gate as every Newton path.
pub fn tryActiveBoundarySurfaceRecoveryCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    current_transformations: chemistry.CellTransformations,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
    recovery_kind: *ActiveBoundaryRecoveryKind,
) !bool {
    return tryActiveBoundarySurfaceRecoveryCandidateFiltered(
        workspace,
        scratch,
        current,
        current_transformations,
        accepted_state,
        residual_work,
        parameters,
        options,
        current_norm,
        .any,
        recovery_kind,
    );
}

pub fn tryActiveBoundarySurfaceRecoveryCandidateFiltered(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    current_transformations: chemistry.CellTransformations,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
    recovery_filter: ActiveBoundaryRecoveryFilter,
    recovery_kind: *ActiveBoundaryRecoveryKind,
) !bool {
    diagnostic_control.recordStrategyCall(.active_boundary_surface_recovery);
    var diagnostic_strategy_scope = diagnostic_control.enterStrategy(.active_boundary_surface_recovery);
    defer diagnostic_strategy_scope.deinit();
    recovery_kind.* = .none;
    _ = try group_aliases.evaluateAt(scratch, current, parameters);
    try reaction_span.evaluateRates(
        scratch,
        0,
        parameters,
        workspace.reaction_span_rates,
    );
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    var reactions = [_]usize{0} ** active_boundary_surface_axis_limit;
    var native_extents = [_]f64{0} ** active_boundary_surface_axis_limit;
    var axis_count: usize = 0;
    for (workspace.reaction_span_rates, 0..) |rate, reaction| {
        if (axis_count == active_boundary_surface_axis_limit) break;
        if (!std.math.isFinite(rate)) return error.NonFiniteSoluteReactionRate;
        if (rate == 0) continue;
        const identity = reaction_span.reactionIdentity(reaction) orelse continue;
        if (identity.domain != .non_band_phosphate_surface and
            identity.domain != .band_phosphate_surface) continue;
        const bounds_evaluations_before = diagnostic_control.evaluationCounts();
        const bounds = try group_aliases.reactionSpanExtentBounds(
            scratch,
            current,
            reaction,
            current_transformations,
            parameters,
            @abs(rate),
            coefficients.monovalent_activity_coefficient,
            workspace.candidate_state,
        );
        diagnostic_control.recordReactionSpanBoundsSite(
            .active_boundary_surface,
            bounds_evaluations_before,
        );
        const native_extent = activeBoundarySurfaceNativeExtent(
            rate,
            bounds.negative_native_extent,
            bounds.positive_native_extent,
        );
        if (native_extent == 0) continue;
        reactions[axis_count] = reaction;
        native_extents[axis_count] = native_extent;
        axis_count += 1;
    }
    if (axis_count == 0) return false;
    std.debug.assert(axis_count + axis_count * (axis_count - 1) / 2 <=
        active_boundary_surface_combination_limit);

    const component_count = comptime chemistry.State.packedComponentCount();
    var best = ActiveBoundaryCompositePrice{};
    var best_kind: ActiveBoundaryRecoveryKind = .none;
    var best_state: [component_count]f64 = undefined;
    var best_residual: [component_count]f64 = undefined;
    var recovered_constructed: usize = 0;
    var recovered_valid: usize = 0;
    for (0..axis_count) |axis| try evaluateActiveBoundarySurfaceCombination(
        workspace,
        current,
        current_transformations,
        parameters,
        options,
        reactions[0..axis_count],
        native_extents[0..axis_count],
        axis,
        null,
        recovery_filter,
        &recovered_constructed,
        &recovered_valid,
        &best,
        &best_kind,
        &best_state,
        &best_residual,
    );
    for (0..axis_count) |first| {
        for (first + 1..axis_count) |second| try evaluateActiveBoundarySurfaceCombination(
            workspace,
            current,
            current_transformations,
            parameters,
            options,
            reactions[0..axis_count],
            native_extents[0..axis_count],
            first,
            second,
            recovery_filter,
            &recovered_constructed,
            &recovered_valid,
            &best,
            &best_kind,
            &best_state,
            &best_residual,
        );
    }
    if (!meaningfulNewtonMeritDecrease(current_norm, best.norm)) return false;
    @memcpy(accepted_state, &best_state);
    @memcpy(residual_work, &best_residual);
    recovery_kind.* = best_kind;
    return true;
}

fn tryBoundedTwoAxisNewtonCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
    limiting_row: usize,
    active_count: usize,
    negative_valid: []const bool,
    positive_valid: []const bool,
) !bool {
    var top_columns =
        [_]usize{std.math.maxInt(usize)} ** two_axis_newton_top_column_count;
    var top_scores =
        [_]f64{-std.math.inf(f64)} ** two_axis_newton_top_column_count;
    var top_count: usize = 0;
    for (0..active_count) |column| {
        var score: f64 = 0;
        for ([_]i8{ -1, 1 }) |side| {
            if ((side < 0 and !negative_valid[column]) or
                (side > 0 and !positive_valid[column])) continue;
            const jacobian = if (side < 0)
                workspace.reaction_span_negative_jacobian
            else
                workspace.reaction_span_positive_jacobian;
            var gradient: f64 = 0;
            for (workspace.reaction_span_rhs[0..current.len], 0..) |rhs, row|
                gradient += jacobian[row * active_count + column] * rhs;
            const limiter_leverage = @abs(
                jacobian[limiting_row * active_count + column] *
                    workspace.reaction_span_rhs[limiting_row],
            );
            score = @max(score, @max(@abs(gradient), limiter_leverage));
        }
        const reaction = workspace.reaction_span_active_reactions[column];
        var insertion = top_count;
        for (0..top_count) |rank| {
            const ranked_reaction =
                workspace.reaction_span_active_reactions[top_columns[rank]];
            if (twoAxisNewtonColumnRankPrecedes(
                score,
                reaction,
                top_scores[rank],
                ranked_reaction,
            )) {
                insertion = rank;
                break;
            }
        }
        if (insertion == two_axis_newton_top_column_count) continue;
        if (top_count < two_axis_newton_top_column_count) top_count += 1;
        var shift = top_count - 1;
        while (shift > insertion) : (shift -= 1) {
            top_scores[shift] = top_scores[shift - 1];
            top_columns[shift] = top_columns[shift - 1];
        }
        top_scores[insertion] = score;
        top_columns[insertion] = column;
    }
    if (top_count < 2) return false;

    var best = TwoAxisNewtonPrice{};
    var priced_face_pairs: usize = 0;
    for (0..top_count) |left_rank| {
        for (left_rank + 1..top_count) |right_rank| {
            const left = top_columns[left_rank];
            const right = top_columns[right_rank];
            for ([_]i8{ -1, 1 }) |left_side| {
                if ((left_side < 0 and !negative_valid[left]) or
                    (left_side > 0 and !positive_valid[left])) continue;
                for ([_]i8{ -1, 1 }) |right_side| {
                    if ((right_side < 0 and !negative_valid[right]) or
                        (right_side > 0 and !positive_valid[right])) continue;
                    priced_face_pairs += 1;
                    std.debug.assert(
                        priced_face_pairs <= two_axis_newton_max_face_pairs,
                    );
                    const left_jacobian = if (left_side < 0)
                        workspace.reaction_span_negative_jacobian
                    else
                        workspace.reaction_span_positive_jacobian;
                    const right_jacobian = if (right_side < 0)
                        workspace.reaction_span_negative_jacobian
                    else
                        workspace.reaction_span_positive_jacobian;
                    var a11: f64 = 0;
                    var a12: f64 = 0;
                    var a22: f64 = 0;
                    var b1: f64 = 0;
                    var b2: f64 = 0;
                    for (workspace.reaction_span_rhs[0..current.len], 0..) |rhs, row| {
                        const j1 = left_jacobian[row * active_count + left];
                        const j2 = right_jacobian[row * active_count + right];
                        a11 += j1 * j1;
                        a12 += j1 * j2;
                        a22 += j2 * j2;
                        b1 += j1 * rhs;
                        b2 += j2 * rhs;
                    }
                    const lower1 = if (left_side < 0)
                        workspace.reaction_span_original_lower_bounds[left]
                    else
                        0;
                    const upper1 = if (left_side > 0)
                        workspace.reaction_span_original_upper_bounds[left]
                    else
                        0;
                    const lower2 = if (right_side < 0)
                        workspace.reaction_span_original_lower_bounds[right]
                    else
                        0;
                    const upper2 = if (right_side > 0)
                        workspace.reaction_span_original_upper_bounds[right]
                    else
                        0;
                    const extents = boundedTwoAxisLeastSquares(
                        a11,
                        a12,
                        a22,
                        b1,
                        b2,
                        lower1,
                        upper1,
                        lower2,
                        upper2,
                    );
                    try priceTwoAxisNewtonDirection(
                        workspace,
                        scratch,
                        current,
                        current_transformations,
                        candidate_state,
                        accepted_state,
                        residual_work,
                        parameters,
                        options,
                        left,
                        right,
                        left_side,
                        right_side,
                        extents[0],
                        extents[1],
                        &best,
                    );
                }
            }
        }
    }
    if (!meaningfulNewtonMeritDecrease(current_norm, best.norm)) return false;
    @memcpy(accepted_state, workspace.reaction_span_best_state);
    @memcpy(residual_work, workspace.reaction_span_best_residual);
    return true;
}

/// Deterministic reduced-space bounded Newton recovery.  The complete
/// reaction-span solve can be rank deficient while a pairwise active-row solve
/// is too small to represent a coupled equilibrium block.  Rank one physical
/// face per reaction by its normalized full-residual leverage, solve the best
/// small block against every residual row, and publish it only after exact
/// conservative reconstruction and the existing global backtracking test.
noinline fn tryReducedBlockNewtonCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    monovalent_activity_coefficient: f64,
    active_count: usize,
    negative_valid: []const bool,
    positive_valid: []const bool,
    best: *TwoAxisNewtonPrice,
    best_target: []f64,
) !bool {
    const current_rms_merit = try group_acceptance.scaledRmsNorm(
        current,
        global_residual,
        options,
    );
    var ranked = [_]ReducedBlockFace{.{}} **
        reduced_block_newton_max_column_count;
    var ranked_count: usize = 0;
    for (0..active_count) |column| {
        var selected = ReducedBlockFace{};
        for ([_]i8{ -1, 1 }) |side| {
            if ((side < 0 and !negative_valid[column]) or
                (side > 0 and !positive_valid[column])) continue;
            const jacobian = if (side < 0)
                workspace.reaction_span_negative_jacobian
            else
                workspace.reaction_span_positive_jacobian;
            var rhs_dot: f64 = 0;
            var self_dot: f64 = 0;
            for (workspace.reaction_span_rhs[0..current.len], 0..) |rhs, row| {
                const derivative = jacobian[row * active_count + column];
                rhs_dot += derivative * rhs;
                self_dot += derivative * derivative;
            }
            if (!std.math.isFinite(rhs_dot) or
                !std.math.isFinite(self_dot) or self_dot <= 0) continue;
            const directional_rhs_dot = if (side < 0) -rhs_dot else rhs_dot;
            if (directional_rhs_dot <= 0) continue;
            const face = ReducedBlockFace{
                .column = column,
                .reaction = workspace.reaction_span_active_reactions[column],
                .side = side,
                .score = directional_rhs_dot / @sqrt(self_dot),
            };
            if (reducedBlockFacePrecedes(face, selected)) selected = face;
        }
        if (!std.math.isFinite(selected.score)) continue;
        var insertion = ranked_count;
        for (ranked[0..ranked_count], 0..) |face, rank| {
            if (reducedBlockFacePrecedes(selected, face)) {
                insertion = rank;
                break;
            }
        }
        if (insertion == reduced_block_newton_max_column_count) continue;
        if (ranked_count < reduced_block_newton_max_column_count)
            ranked_count += 1;
        var shift = ranked_count - 1;
        while (shift > insertion) : (shift -= 1)
            ranked[shift] = ranked[shift - 1];
        ranked[insertion] = selected;
    }
    if (ranked_count < 3) return false;

    var reactions: [reduced_block_newton_max_column_count]usize = undefined;
    var scales: [reduced_block_newton_max_column_count]f64 = undefined;
    var lower_bounds: [reduced_block_newton_max_column_count]f64 = undefined;
    var upper_bounds: [reduced_block_newton_max_column_count]f64 = undefined;
    for (ranked[0..ranked_count], 0..) |face, packed_column| {
        reactions[packed_column] = face.reaction;
        scales[packed_column] =
            workspace.reaction_span_extent_scales[face.column];
        lower_bounds[packed_column] = if (face.side < 0)
            workspace.reaction_span_original_lower_bounds[face.column]
        else
            0;
        upper_bounds[packed_column] = if (face.side > 0)
            workspace.reaction_span_original_upper_bounds[face.column]
        else
            0;
    }
    const previous_rank_permission =
        workspace.reaction_span_allow_truncated_qr;
    const previous_last_rank = workspace.reaction_span_last_rank;
    const previous_used_truncated_qr =
        workspace.reaction_span_used_truncated_qr;
    workspace.reaction_span_allow_truncated_qr = false;
    defer {
        workspace.reaction_span_allow_truncated_qr = previous_rank_permission;
        workspace.reaction_span_last_rank = previous_last_rank;
        workspace.reaction_span_used_truncated_qr = previous_used_truncated_qr;
        @memcpy(
            workspace.reaction_span_lower_bounds[0..active_count],
            workspace.reaction_span_original_lower_bounds[0..active_count],
        );
        @memcpy(
            workspace.reaction_span_upper_bounds[0..active_count],
            workspace.reaction_span_original_upper_bounds[0..active_count],
        );
    }
    var found = false;
    var block_count: usize = 3;
    block_loop: while (block_count <= ranked_count) : (block_count += 1) {
        @memcpy(
            workspace.reaction_span_lower_bounds[0..block_count],
            lower_bounds[0..block_count],
        );
        @memcpy(
            workspace.reaction_span_upper_bounds[0..block_count],
            upper_bounds[0..block_count],
        );
        for (ranked[0..block_count], 0..) |face, packed_column| {
            const source = if (face.side < 0)
                workspace.reaction_span_negative_jacobian
            else
                workspace.reaction_span_positive_jacobian;
            for (0..current.len) |row|
                workspace.reaction_span_jacobian[row * block_count + packed_column] =
                    source[row * active_count + face.column];
        }
        if (!group_aliases.solveBoundedReactionSpan(
            workspace,
            current.len,
            block_count,
        )) continue;

        var transformations = reaction_span.zeroTransformations(parameters);
        var nonzero = false;
        for (workspace.reaction_span_solution[0..block_count], 0..) |
            normalized_extent,
            column,
        | {
            if (!std.math.isFinite(normalized_extent))
                continue :block_loop;
            if (normalized_extent == 0) continue;
            reaction_span.addReactionExtent(
                &transformations,
                reactions[column],
                normalized_extent * scales[column],
                current_transformations,
                parameters,
            ) catch continue :block_loop;
            nonzero = true;
        }
        if (!nonzero) continue;
        _ = reaction_solver_numerics.transformedVectorAdmissibleWithMonovalentActivityCoefficient(
            scratch,
            current,
            transformations,
            parameters,
            monovalent_activity_coefficient,
            1,
            candidate_state,
        ) catch continue;

        var fraction: f64 = 1;
        for (0..active_row_newton_backtracking_trials) |_| {
            defer fraction *= 0.5;
            const candidate_norm = group_aliases.evaluateCandidateResidualAtFraction(
                scratch,
                current,
                candidate_state,
                accepted_state,
                residual_work,
                parameters,
                options,
                fraction,
            ) catch continue;
            const candidate_rms_merit = try group_acceptance.scaledRmsNorm(
                accepted_state,
                residual_work,
                options,
            );
            if (!group_acceptance.rmsArmijoDecrease(
                current_rms_merit,
                candidate_rms_merit,
                fraction,
            )) continue;
            if (!std.math.isFinite(candidate_norm) or candidate_norm >= best.norm)
                continue;
            found = true;
            best.norm = candidate_norm;
            best.reaction_a = reactions[0];
            best.reaction_b = reactions[1];
            best.side_a = ranked[0].side;
            best.side_b = ranked[1].side;
            best.fraction = fraction;
            @memcpy(workspace.reaction_span_best_state, accepted_state);
            @memcpy(workspace.reaction_span_best_residual, residual_work);
            @memcpy(best_target, candidate_state);
        }
    }
    return found;
}

/// Bounded semismooth Newton recovery on the two coordinates that define the
/// current scaled L-infinity merit. This is invoked only after every ordinary
/// Newton family has failed. It rebuilds the carrier at `current`, evaluates
/// both physical one-sided faces, exhaustively prices every distinct face
/// pair, and returns at most one globally meaningful conservative candidate.
pub fn tryActiveRowNewtonCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
) !bool {
    diagnostic_control.recordStrategyCall(.active_row_newton);
    var diagnostic_strategy_scope = diagnostic_control.enterStrategy(.active_row_newton);
    defer diagnostic_strategy_scope.deinit();
    return tryActiveRowNewtonCandidateImpl(
        workspace,
        scratch,
        current,
        global_residual,
        current_transformations,
        candidate_state,
        accepted_state,
        residual_work,
        parameters,
        options,
        current_norm,
        true,
    );
}

const maximum_ternary_correction_faces: usize = 8;

const CorrectionFace = enum(u2) {
    negative,
    pinned_zero,
    positive,
};

fn ternaryCorrectionFace(pattern: usize, face_index: usize) CorrectionFace {
    var divisor: usize = 1;
    for (0..face_index) |_| divisor *= 3;
    return @enumFromInt((pattern / divisor) % 3);
}

fn ternaryCorrectionPatternCount(face_count: usize) usize {
    std.debug.assert(face_count <= maximum_ternary_correction_faces);
    var count: usize = 1;
    for (0..face_count) |_| count *= 3;
    return count;
}

fn patternHasPinnedCorrectionFace(pattern: usize, face_count: usize) bool {
    for (0..face_count) |face_index| {
        if (ternaryCorrectionFace(pattern, face_index) == .pinned_zero)
            return true;
    }
    return false;
}

/// A correction pinned at the nonsmooth origin is a valid active face only
/// when neither adjacent one-sided linearization supplies a descent direction.
/// `negative_gradient` multiplies a negative displacement and
/// `positive_gradient` a positive displacement.
pub fn pinnedZeroCorrectionFaceKktSatisfied(
    negative_gradient: f64,
    positive_gradient: f64,
    gradient_scale: f64,
) bool {
    if (!std.math.isFinite(negative_gradient) or
        !std.math.isFinite(positive_gradient) or
        !std.math.isFinite(gradient_scale) or
        gradient_scale <= 0)
    {
        return false;
    }
    const tolerance = @sqrt(std.math.floatEps(f64)) * gradient_scale;
    return negative_gradient <= tolerance and
        positive_gradient >= -tolerance;
}

fn compactDenseReactionColumns(
    matrix: []f64,
    scratch: []f64,
    row_count: usize,
    old_count: usize,
    kept_sources: []const usize,
) void {
    const kept_count = kept_sources.len;
    for (0..row_count) |row| {
        for (kept_sources, 0..) |source, target| {
            scratch[row * kept_count + target] =
                matrix[row * old_count + source];
        }
    }
    @memcpy(matrix[0 .. row_count * kept_count], scratch[0 .. row_count * kept_count]);
}

/// Ternary discovery is intentionally allowed to use a rank-revealing
/// representative. `solveBoundedReactionSpan` returns true only after its
/// complete bounded-system KKT gates (including the projected recovery for a
/// truncated QR point). Keep that permission local so no later solver family
/// inherits a different rank policy on either success or failure.
fn ternaryRankRepresentativeCertified(
    workspace: *group_aliases.Workspace,
    row_count: usize,
    column_count: usize,
) bool {
    return !workspace.reaction_span_used_truncated_qr or
        __parent.reactionSpanProjectedKktSatisfied(
            workspace,
            row_count,
            column_count,
        );
}

fn solveTernaryBoundedReactionSpan(
    workspace: *group_aliases.Workspace,
    row_count: usize,
    column_count: usize,
) bool {
    const previous_rank_permission =
        workspace.reaction_span_allow_truncated_qr;
    workspace.reaction_span_allow_truncated_qr = true;
    defer workspace.reaction_span_allow_truncated_qr =
        previous_rank_permission;
    if (!group_aliases.solveBoundedReactionSpan(
        workspace,
        row_count,
        column_count,
    )) return false;
    return ternaryRankRepresentativeCertified(
        workspace,
        row_count,
        column_count,
    );
}

/// Produces a deterministic bounded rank-revealing representative solely for
/// choosing correction faces when the convex bounded solver cannot certify a
/// base point numerically. This vector is never transformed, priced, or
/// published. Every pattern selected from it is subsequently rebuilt and must
/// pass the complete bounded/KKT and exact nonlinear acceptance path.
fn buildTernaryDiscoveryRepresentative(
    workspace: *group_aliases.Workspace,
    row_count: usize,
    column_count: usize,
) bool {
    if (column_count == 0 or
        column_count > reaction_span.reaction_count or
        row_count < column_count)
    {
        return false;
    }
    const matrix =
        workspace.reaction_span_jacobian[0 .. row_count * column_count];
    const projected =
        workspace.reaction_span_projected_jacobian[0 .. row_count * column_count];
    @memcpy(projected, matrix);
    @memcpy(
        workspace.reaction_span_projected_rhs[0..row_count],
        workspace.reaction_span_rhs[0..row_count],
    );
    for (0..column_count) |column| {
        const norm = group_aliases.matrixColumnNorm(
            matrix,
            row_count,
            column_count,
            column,
            0,
        );
        if (!std.math.isFinite(norm) or norm == 0) return false;
        for (0..row_count) |row|
            projected[row * column_count + column] /= norm;
    }
    if (!__parent.solvePivotedHouseholder(
        projected,
        workspace.reaction_span_projected_rhs[0..row_count],
        workspace.reaction_span_residual[0..column_count],
        workspace.reaction_span_pivots[0..column_count],
        workspace.reaction_span_probe_residual[0..column_count],
        row_count,
        column_count,
        &workspace.reaction_span_last_rank,
        null,
    )) return false;
    for (workspace.reaction_span_solution[0..column_count], 0..) |
        *extent,
        column,
    | {
        const lower = workspace.reaction_span_lower_bounds[column];
        const upper = workspace.reaction_span_upper_bounds[column];
        const norm = group_aliases.matrixColumnNorm(
            matrix,
            row_count,
            column_count,
            column,
            0,
        );
        const unbounded = workspace.reaction_span_residual[column] / norm;
        if (!std.math.isFinite(lower) or
            !std.math.isFinite(upper) or
            lower > upper or
            !std.math.isFinite(unbounded))
        {
            return false;
        }
        extent.* = std.math.clamp(unbounded, lower, upper);
    }
    return workspace.reaction_span_last_rank > 0;
}

fn preparePinnedCorrectionLinearResidual(
    workspace: *group_aliases.Workspace,
    selected_jacobian: []const f64,
    row_count: usize,
    column_count: usize,
) ?f64 {
    var residual_norm_squared: f64 = 0;
    for (0..row_count) |row| {
        var linear_residual = -workspace.reaction_span_rhs[row];
        for (workspace.reaction_span_solution[0..column_count], 0..) |
            extent,
            column,
        | {
            linear_residual +=
                selected_jacobian[row * column_count + column] * extent;
        }
        if (!std.math.isFinite(linear_residual)) return null;
        workspace.reaction_span_projected_rhs[row] = linear_residual;
        residual_norm_squared += linear_residual * linear_residual;
    }
    if (!std.math.isFinite(residual_norm_squared)) return null;
    return @sqrt(residual_norm_squared);
}

pub fn pinnedCorrectionColumnKktSatisfied(
    workspace: *const group_aliases.Workspace,
    negative_jacobian: []const f64,
    positive_jacobian: []const f64,
    row_count: usize,
    column_count: usize,
    column: usize,
    residual_norm: f64,
) bool {
    const violation = pinnedCorrectionColumnNormalizedViolation(workspace, negative_jacobian, positive_jacobian, row_count, column_count, column, residual_norm);
    return std.math.isFinite(violation) and violation <= @sqrt(std.math.floatEps(f64));
}

pub fn pinnedCorrectionColumnNormalizedViolation(
    workspace: *const group_aliases.Workspace,
    negative_jacobian: []const f64,
    positive_jacobian: []const f64,
    row_count: usize,
    column_count: usize,
    column: usize,
    residual_norm: f64,
) f64 {
    const gradients = correctionFaceNormalizedGradients(workspace, negative_jacobian, positive_jacobian, row_count, column_count, column, residual_norm);
    if (!std.math.isFinite(gradients.negative) or !std.math.isFinite(gradients.positive)) return std.math.inf(f64);
    return @max(0, gradients.negative, -gradients.positive);
}

/// Normalize each one-sided column before multiplying by the residual.
/// A small derivative must not vanish behind an absolute gradient floor or
/// the opposite side's larger derivative. Zero columns have zero gradient.
fn correctionFaceNormalizedGradients(
    workspace: *const group_aliases.Workspace,
    negative_jacobian: []const f64,
    positive_jacobian: []const f64,
    row_count: usize,
    column_count: usize,
    column: usize,
    residual_norm: f64,
) struct { negative: f64, positive: f64 } {
    const linear_solve = @import("reaction_solve.zig");
    const residual = workspace.reaction_span_projected_rhs[0..row_count];
    return .{
        .negative = linear_solve.normalizedKktGradient(negative_jacobian, residual, column_count, column, residual_norm),
        .positive = linear_solve.normalizedKktGradient(positive_jacobian, residual, column_count, column, residual_norm),
    };
}
fn captureTernaryAmbiguousAxisDiagnostic(
    diagnostic: ?*group_aliases.IterationDiagnostic,
    workspace: *const group_aliases.Workspace,
    column: usize,
    discovery_extent: f64,
    discovery_branch: i8,
    source: group_aliases.TernaryAmbiguousAxisSource,
    normalized_pinned_kkt_violation: f64,
) void {
    const entry = diagnostic orelse return;
    if (entry.ternary_correction_axis_diagnostic_count ==
        entry.ternary_correction_axis_diagnostics.len) return;
    const reaction = workspace.reaction_span_active_reactions[column];
    const current_rate = workspace.reaction_span_rates[reaction];
    const target =
        &entry.ternary_correction_axis_diagnostics[
            entry.ternary_correction_axis_diagnostic_count
        ];
    target.* = .{
        .compact_column = column,
        .reaction_index = reaction,
        .discovery_extent = discovery_extent,
        .current_rate = current_rate,
        .extent_significance_ratio = @import("reaction_solver_reaction_span.zig").reactionSpanExtentSignificanceRatio(workspace, column, discovery_extent),
        .normalized_pinned_kkt_violation = normalized_pinned_kkt_violation,
        .discovery_branch = discovery_branch,
        .current_branch = reactionRateBranch(current_rate),
        .source = source,
    };
    entry.ternary_correction_axis_diagnostic_count += 1;
}

/// Projected KKT deliberately skips zero-width bounds. Ternary publication
/// therefore supplies the missing nonsmooth certificate for every column
/// whose final bounds pin it at zero, including implicit base pins.
fn pinnedCorrectionFacesKktSatisfied(
    workspace: *group_aliases.Workspace,
    negative_jacobian: []const f64,
    positive_jacobian: []const f64,
    selected_jacobian: []const f64,
    row_count: usize,
    column_count: usize,
) bool {
    const residual_norm = preparePinnedCorrectionLinearResidual(
        workspace,
        selected_jacobian,
        row_count,
        column_count,
    ) orelse return false;
    for (0..column_count) |column| {
        if (workspace.reaction_span_lower_bounds[column] != 0 or
            workspace.reaction_span_upper_bounds[column] != 0)
        {
            continue;
        }
        if (!pinnedCorrectionColumnKktSatisfied(
            workspace,
            negative_jacobian,
            positive_jacobian,
            row_count,
            column_count,
            column,
            residual_norm,
        )) return false;
    }
    return true;
}

/// A rank-dropped zero-rate axis initially appears as an implicit base pin.
/// Promote any such pin that fails its two-sided KKT certificate so ternary
/// enumeration can choose either adjacent face. The same eight-axis ceiling
/// applies; exceeding it fails closed before any candidate can be published.
const BasePinPromotionStatus = enum {
    complete,
    invalid_residual,
    too_many,
};

fn normalizedResidualSecant(
    current_state: f64,
    current_residual: f64,
    probe_state: f64,
    probe_residual: f64,
    packed_component: usize,
    options: group_aliases.Options,
    normalized_probe: f64,
) ?f64 {
    if (!std.math.isFinite(normalized_probe) or normalized_probe == 0)
        return null;
    const current_scale = group_aliases.residualScale(
        current_state,
        packed_component,
        options,
    );
    const probe_scale = group_aliases.residualScale(
        probe_state,
        packed_component,
        options,
    );
    const derivative = (probe_residual / probe_scale -
        current_residual / current_scale) / normalized_probe;
    return if (std.math.isFinite(derivative)) derivative else null;
}

/// Scoped derivative of the exact normalized residual q=r/scale(state) used
/// by the bounded ternary recovery's RMS objective and KKT certificate.
fn evaluateTernaryNormalizedDerivativeColumn(
    inputs: group_aliases.ComplementaritySearchInputs,
    workspace: *const group_aliases.Workspace,
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
        return error.NoAdmissibleComplementarityProbe;
    const normalized_probe =
        @as(f64, @floatFromInt(direction)) * probe_magnitude;
    var transformations = reaction_span.zeroTransformations(inputs.parameters);
    try reaction_span.addReactionExtent(
        &transformations,
        workspace.reaction_span_active_reactions[column],
        normalized_probe * workspace.reaction_span_extent_scales[column],
        inputs.current_transformations,
        inputs.parameters,
    );
    try group_aliases.transformedVector(
        inputs.scratch,
        inputs.current,
        transformations,
        inputs.monovalent_activity_coefficient,
        inputs.parameters.water_activity_product_mol2_per_m6,
        1,
        inputs.probe_state,
    );
    try group_aliases.evaluateGlobalResidualAt(
        inputs.scratch,
        inputs.probe_state,
        inputs.parameters,
        inputs.probe_residual,
    );
    for (0..inputs.current.len) |row| {
        output_jacobian[row * inputs.column_count + column] =
            normalizedResidualSecant(
                inputs.current[row],
                inputs.global_residual[row],
                inputs.probe_state[row],
                inputs.probe_residual[row],
                row,
                inputs.options,
                normalized_probe,
            ) orelse return error.NonFiniteSoluteReactionResidual;
    }
}

fn uniformRmsDirectionalDerivative(
    current: []const f64,
    global_residual: []const f64,
    normalized_direction: []const f64,
    options: group_aliases.Options,
) ?f64 {
    if (current.len == 0 or current.len != global_residual.len or
        current.len != normalized_direction.len) return null;
    var sum_squares: f64 = 0;
    var directional_dot: f64 = 0;
    for (global_residual, current, normalized_direction, 0..) |
        residual,
        state_value,
        direction,
        row,
    | {
        const normalized_residual = residual /
            group_aliases.residualScale(state_value, row, options);
        if (!std.math.isFinite(normalized_residual) or
            !std.math.isFinite(direction)) return null;
        sum_squares += normalized_residual * normalized_residual;
        directional_dot += normalized_residual * direction;
    }
    const count = @as(f64, @floatFromInt(current.len));
    const merit = @sqrt(sum_squares / count);
    if (!std.math.isFinite(merit) or merit <= 0 or
        !std.math.isFinite(directional_dot)) return null;
    const derivative = directional_dot / (count * merit);
    return if (std.math.isFinite(derivative)) derivative else null;
}

const TernaryDirectionalCorrectionStatus = enum {
    invalid,
    not_meaningful,
    corrected,
};

/// Enforce the observed complete-direction secant with the least Frobenius-
/// norm rank-one change. The selected matrix is pattern-local: immutable
/// negative/positive side columns rebuild it before the next pattern.
fn applyTernaryDirectionalJacobianCorrection(
    selected_jacobian: []f64,
    solution: []const f64,
    actual_direction: []const f64,
    row_count: usize,
    column_count: usize,
) TernaryDirectionalCorrectionStatus {
    if (solution.len != column_count or
        actual_direction.len != row_count or
        selected_jacobian.len != row_count * column_count)
    {
        return .invalid;
    }
    var solution_norm_squared: f64 = 0;
    for (solution) |extent|
        solution_norm_squared += extent * extent;
    if (!std.math.isFinite(solution_norm_squared) or
        solution_norm_squared <= std.math.floatEps(f64))
    {
        return .invalid;
    }

    var meaningful = false;
    for (actual_direction, 0..) |actual, row| {
        if (!std.math.isFinite(actual)) return .invalid;
        var predicted: f64 = 0;
        for (solution, 0..) |extent, column|
            predicted += selected_jacobian[
                row * column_count + column
            ] * extent;
        const difference = actual - predicted;
        const derivative_scale = @max(
            1.0,
            @max(@abs(actual), @abs(predicted)),
        );
        if (!std.math.isFinite(predicted) or
            !std.math.isFinite(difference) or
            !std.math.isFinite(derivative_scale)) return .invalid;
        if (@abs(difference) >
            64 * std.math.floatEps(f64) * derivative_scale)
            meaningful = true;
    }
    if (!meaningful) return .not_meaningful;

    for (actual_direction, 0..) |actual, row| {
        var predicted: f64 = 0;
        for (solution, 0..) |extent, column|
            predicted += selected_jacobian[
                row * column_count + column
            ] * extent;
        const difference = actual - predicted;
        for (solution, 0..) |extent, column| {
            if (extent == 0) continue;
            const index = row * column_count + column;
            const corrected = selected_jacobian[index] +
                difference * extent / solution_norm_squared;
            if (!std.math.isFinite(corrected)) return .invalid;
            selected_jacobian[index] = corrected;
        }
    }
    return .corrected;
}

fn ternarySolutionsMeaningfullyDifferent(
    previous: []const f64,
    current: []const f64,
) bool {
    if (previous.len != current.len) return false;
    for (previous, current) |old, new| {
        if (!std.math.isFinite(old) or !std.math.isFinite(new)) return false;
        const scale = @max(1.0, @max(@abs(old), @abs(new)));
        if (@abs(new - old) > 64 * std.math.floatEps(f64) * scale)
            return true;
    }
    return false;
}

fn evaluateTernaryUniformCombinedDirection(
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    probe_residual: []f64,
    actual_direction: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    requested_fraction: f64,
) !f64 {
    const realized_fraction = try group_aliases.transformedVectorAdmissible(
        scratch,
        current,
        transformations,
        parameters,
        requested_fraction,
        candidate_state,
    );
    if (!std.math.isFinite(realized_fraction) or
        realized_fraction <= 64 * std.math.floatEps(f64))
        return error.NoAdmissibleComplementarityProbe;
    try group_aliases.evaluateGlobalResidualAt(
        scratch,
        candidate_state,
        parameters,
        probe_residual,
    );
    if (actual_direction.len != current.len or
        global_residual.len != current.len or
        candidate_state.len != current.len or
        probe_residual.len != current.len)
        return error.NonFiniteSoluteReactionResidual;
    for (0..current.len) |row|
        actual_direction[row] = normalizedResidualSecant(
            current[row],
            global_residual[row],
            candidate_state[row],
            probe_residual[row],
            row,
            options,
            realized_fraction,
        ) orelse return error.NonFiniteSoluteReactionResidual;
    return uniformRmsDirectionalDerivative(
        current,
        global_residual,
        actual_direction,
        options,
    ) orelse error.NonFiniteSoluteReactionResidual;
}

fn appendUncertifiedBasePins(
    workspace: *group_aliases.Workspace,
    negative_jacobian: []const f64,
    positive_jacobian: []const f64,
    selected_jacobian: []const f64,
    row_count: usize,
    column_count: usize,
    base_faces: []const i8,
    ambiguous_columns: *[maximum_ternary_correction_faces]usize,
    ambiguous_count: *usize,
    diagnostic: ?*group_aliases.IterationDiagnostic,
) BasePinPromotionStatus {
    const residual_norm = preparePinnedCorrectionLinearResidual(
        workspace,
        selected_jacobian,
        row_count,
        column_count,
    ) orelse return .invalid_residual;
    var required_count = ambiguous_count.*;
    var overflowed = false;
    for (base_faces[0..column_count], 0..) |face, column| {
        if (face != 0) continue;
        if (pinnedCorrectionColumnKktSatisfied(
            workspace,
            negative_jacobian,
            positive_jacobian,
            row_count,
            column_count,
            column,
            residual_norm,
        )) continue;
        if (diagnostic != null) captureTernaryAmbiguousAxisDiagnostic(
            diagnostic,
            workspace,
            column,
            workspace.reaction_span_solution[column],
            0,
            .failed_implicit_pin_kkt,
            pinnedCorrectionColumnNormalizedViolation(
                workspace,
                negative_jacobian,
                positive_jacobian,
                row_count,
                column_count,
                column,
                residual_norm,
            ),
        );
        var already_ambiguous = false;
        for (ambiguous_columns.*[0..ambiguous_count.*]) |existing|
            if (existing == column) {
                already_ambiguous = true;
                break;
            };
        if (already_ambiguous) continue;
        if (ambiguous_count.* == maximum_ternary_correction_faces) {
            required_count += 1;
            overflowed = true;
            continue;
        }
        var insertion = ambiguous_count.*;
        while (insertion > 0 and
            ambiguous_columns.*[insertion - 1] > column)
        {
            ambiguous_columns.*[insertion] =
                ambiguous_columns.*[insertion - 1];
            insertion -= 1;
        }
        ambiguous_columns.*[insertion] = column;
        ambiguous_count.* += 1;
        required_count += 1;
    }
    if (overflowed) {
        // Report the complete required topology while failing closed. The
        // bounded column array is never indexed by this overflow count.
        ambiguous_count.* = required_count;
        return .too_many;
    }
    return .complete;
}

/// Terminal semismooth Newton recovery for a small correction-side active set.
/// Binary negative/positive face recovery runs earlier. This bounded ternary
/// search adds the missing kink face where an ambiguous correction is held at
/// exactly zero and certified against both one-sided gradients. Every trial is
/// a conservative reaction ledger and only exact RMS-Armijo publication with
/// the maximum-norm growth safeguard may escape this function.
pub fn tryTernaryCorrectionFaceNewtonCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
    diagnostic: ?*group_aliases.IterationDiagnostic,
) !bool {
    diagnostic_control.recordStrategyCall(.ternary_correction_face);
    var diagnostic_strategy_scope = diagnostic_control.enterStrategy(.ternary_correction_face);
    defer diagnostic_strategy_scope.deinit();
    if (diagnostic) |entry| {
        entry.ternary_correction_status = .initializing;
        entry.ternary_correction_initialized_axes = 0;
        entry.ternary_correction_kept_axes = 0;
        entry.ternary_correction_base_certified = false;
        entry.ternary_correction_discovery_rank = 0;
        entry.ternary_correction_ambiguous_axes = 0;
        entry.ternary_correction_axis_diagnostic_count = 0;
        entry.ternary_correction_pattern_count = 0;
        entry.ternary_correction_patterns_considered = 0;
        entry.ternary_correction_patterns_solved = 0;
        entry.ternary_correction_patterns_kkt = 0;
        entry.ternary_correction_patterns_nonzero = 0;
        entry.ternary_correction_patterns_admissible = 0;
        entry.ternary_correction_armijo_attempts = 0;
        entry.ternary_correction_armijo_accepted = 0;
    }
    _ = try group_aliases.evaluateAt(scratch, current, parameters);
    try reaction_span.evaluateRates(
        scratch,
        0,
        parameters,
        workspace.reaction_span_rates,
    );
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    var column_count = try initializeFullNetworkReactionAxes(
        workspace,
        scratch,
        current,
        current_transformations,
        candidate_state,
        parameters,
        options,
        coefficients.monovalent_activity_coefficient,
    );
    if (diagnostic) |entry|
        entry.ternary_correction_initialized_axes = column_count;
    if (column_count == 0) {
        if (diagnostic) |entry|
            entry.ternary_correction_status = .no_initialized_axes;
        return false;
    }

    const old_column_count = column_count;
    const matrix_count = current.len * old_column_count;
    const selected_jacobian = workspace.reaction_span_jacobian[0..matrix_count];
    const negative_jacobian = workspace.reaction_span_negative_jacobian[0..matrix_count];
    const positive_jacobian = workspace.reaction_span_positive_jacobian[0..matrix_count];
    @memset(selected_jacobian, 0);
    @memset(negative_jacobian, 0);
    @memset(positive_jacobian, 0);
    @memcpy(
        workspace.reaction_span_lower_bounds[0..old_column_count],
        workspace.reaction_span_original_lower_bounds[0..old_column_count],
    );
    @memcpy(
        workspace.reaction_span_upper_bounds[0..old_column_count],
        workspace.reaction_span_original_upper_bounds[0..old_column_count],
    );
    for (global_residual, current, 0..) |value, state_value, row| {
        const scale = group_aliases.residualScale(state_value, row, options);
        workspace.reaction_span_rhs[row] = -(value / scale);
    }
    const inputs = group_aliases.ComplementaritySearchInputs{
        .scratch = scratch,
        .current = current,
        .global_residual = global_residual,
        .probe_state = candidate_state,
        .probe_residual = residual_work,
        .current_transformations = current_transformations,
        .parameters = parameters,
        .options = options,
        .current_norm = current_norm,
        .monovalent_activity_coefficient = coefficients.monovalent_activity_coefficient,
        .column_count = old_column_count,
    };
    var kept_count: usize = 0;
    for (0..old_column_count) |column| {
        const available = physicalDerivativeSidesAvailable(
            workspace.reaction_span_original_lower_bounds[column],
            workspace.reaction_span_original_upper_bounds[column],
        );
        var negative_valid = false;
        if (available.negative) {
            if (evaluateTernaryNormalizedDerivativeColumn(
                inputs,
                workspace,
                column,
                -1,
                negative_jacobian,
            )) |_| {
                negative_valid = derivativeColumnFiniteAndNonzero(
                    negative_jacobian,
                    current.len,
                    old_column_count,
                    column,
                );
            } else |_| {}
        }
        var positive_valid = false;
        if (available.positive) {
            if (evaluateTernaryNormalizedDerivativeColumn(
                inputs,
                workspace,
                column,
                1,
                positive_jacobian,
            )) |_| {
                positive_valid = derivativeColumnFiniteAndNonzero(
                    positive_jacobian,
                    current.len,
                    old_column_count,
                    column,
                );
            } else |_| {}
        }
        if (!negative_valid and !positive_valid) continue;
        for (0..current.len) |row| {
            const index = row * old_column_count + column;
            if (!negative_valid)
                negative_jacobian[index] = positive_jacobian[index];
            if (!positive_valid)
                positive_jacobian[index] = negative_jacobian[index];
            selected_jacobian[index] = group_aliases.complementarityColumnDerivative(
                workspace.reaction_span_branch_states[column],
                negative_jacobian[index],
                positive_jacobian[index],
            );
        }
        workspace.reaction_span_pivots[kept_count] = column;
        kept_count += 1;
    }
    if (diagnostic) |entry|
        entry.ternary_correction_kept_axes = kept_count;
    if (kept_count == 0) {
        if (diagnostic) |entry|
            entry.ternary_correction_status = .no_derivative_axes;
        return false;
    }
    if (kept_count < old_column_count) {
        const kept_sources = workspace.reaction_span_pivots[0..kept_count];
        compactDenseReactionColumns(
            negative_jacobian,
            workspace.reaction_span_projected_jacobian,
            current.len,
            old_column_count,
            kept_sources,
        );
        compactDenseReactionColumns(
            positive_jacobian,
            workspace.reaction_span_projected_jacobian,
            current.len,
            old_column_count,
            kept_sources,
        );
        compactReactionSpanColumns(
            workspace,
            current.len,
            old_column_count,
            kept_count,
        );
        column_count = kept_count;
    }

    const compact_matrix_count = current.len * column_count;
    const selected = workspace.reaction_span_jacobian[0..compact_matrix_count];
    const negative = workspace.reaction_span_negative_jacobian[0..compact_matrix_count];
    const positive = workspace.reaction_span_positive_jacobian[0..compact_matrix_count];
    @memcpy(
        workspace.reaction_span_lower_bounds[0..column_count],
        workspace.reaction_span_original_lower_bounds[0..column_count],
    );
    @memcpy(
        workspace.reaction_span_upper_bounds[0..column_count],
        workspace.reaction_span_original_upper_bounds[0..column_count],
    );
    const base_certified = solveTernaryBoundedReactionSpan(
        workspace,
        current.len,
        column_count,
    );
    if (diagnostic) |entry|
        entry.ternary_correction_base_certified = base_certified;
    if (!base_certified and !buildTernaryDiscoveryRepresentative(
        workspace,
        current.len,
        column_count,
    )) {
        if (diagnostic) |entry|
            entry.ternary_correction_status = .base_solve_failed;
        return false;
    }
    if (diagnostic) |entry|
        entry.ternary_correction_discovery_rank =
            workspace.reaction_span_last_rank;

    var base_faces = [_]i8{0} ** reaction_span.reaction_count;
    var ambiguous_columns: [maximum_ternary_correction_faces]usize = undefined;
    var ambiguous_count: usize = 0;
    for (workspace.reaction_span_solution[0..column_count], 0..) |
        solution,
        column,
    | {
        const reaction = workspace.reaction_span_active_reactions[column];
        const current_branch = reactionRateBranch(
            workspace.reaction_span_rates[reaction],
        );
        const solution_branch: i8 = if (group_aliases.reactionSpanExtentIsSignificant(
            workspace,
            column,
            solution,
        )) if (solution < 0) -1 else 1 else current_branch;
        base_faces[column] = solution_branch;
        if (solution_branch == current_branch and current_branch != 0)
            continue;
        if (!group_aliases.reactionSpanExtentIsSignificant(
            workspace,
            column,
            solution,
        )) continue;
        if (diagnostic != null) captureTernaryAmbiguousAxisDiagnostic(
            diagnostic,
            workspace,
            column,
            solution,
            solution_branch,
            .sign_mismatch,
            0,
        );
        if (ambiguous_count == maximum_ternary_correction_faces) {
            if (diagnostic) |entry| {
                entry.ternary_correction_ambiguous_axes = ambiguous_count + 1;
                entry.ternary_correction_status = .too_many_ambiguous_axes;
            }
            return false;
        }
        ambiguous_columns[ambiguous_count] = column;
        ambiguous_count += 1;
    }
    // Match the linear residual to the discovery representative before
    // testing implicit zero-rate pins. Columns promoted here join the same
    // stable source-order ternary enumeration as sign-mismatched axes.
    for (0..column_count) |column| {
        const branch = base_faces[column];
        for (0..current.len) |row| {
            const index = row * column_count + column;
            selected[index] = group_aliases.complementarityColumnDerivative(
                branch,
                negative[index],
                positive[index],
            );
        }
    }
    const base_pin_promotion = appendUncertifiedBasePins(
        workspace,
        negative,
        positive,
        selected,
        current.len,
        column_count,
        base_faces[0..column_count],
        &ambiguous_columns,
        &ambiguous_count,
        diagnostic,
    );
    switch (base_pin_promotion) {
        .complete => {},
        .invalid_residual => {
            if (diagnostic) |entry|
                entry.ternary_correction_status = .base_solve_failed;
            return false;
        },
        .too_many => {
            if (diagnostic) |entry| {
                entry.ternary_correction_ambiguous_axes =
                    ambiguous_count;
                entry.ternary_correction_status = .too_many_ambiguous_axes;
            }
            return false;
        },
    }
    if (diagnostic) |entry|
        entry.ternary_correction_ambiguous_axes = ambiguous_count;
    if (ambiguous_count == 0) {
        if (diagnostic) |entry|
            entry.ternary_correction_status = .no_ambiguous_axes;
        return false;
    }

    const pattern_count = ternaryCorrectionPatternCount(ambiguous_count);
    if (diagnostic) |entry|
        entry.ternary_correction_pattern_count = pattern_count;
    // Try binary correction faces first, then faces with explicit zero pins.
    // The earlier branch enumerator has a stricter L-infinity acceptance path,
    // so its rejection does not prove that exact RMS-Armijo rejects the same
    // binary correction. Each of the at most 3^8 patterns is still tried once.
    for ([_]bool{ false, true }) |pinned_pass| {
        for (0..pattern_count) |pattern| {
            if (patternHasPinnedCorrectionFace(pattern, ambiguous_count) !=
                pinned_pass) continue;
            if (diagnostic) |entry|
                entry.ternary_correction_patterns_considered += 1;
            for (0..column_count) |column| {
                var face: CorrectionFace = switch (base_faces[column]) {
                    -1 => .negative,
                    0 => .pinned_zero,
                    1 => .positive,
                    else => unreachable,
                };
                for (ambiguous_columns[0..ambiguous_count], 0..) |
                    ambiguous,
                    face_index,
                | {
                    if (column == ambiguous) {
                        face = ternaryCorrectionFace(pattern, face_index);
                        break;
                    }
                }
                const branch: i8 = switch (face) {
                    .negative => -1,
                    .pinned_zero => 0,
                    .positive => 1,
                };
                const bounds = complementarityFaceBounds(
                    branch,
                    workspace.reaction_span_original_lower_bounds[column],
                    workspace.reaction_span_original_upper_bounds[column],
                );
                workspace.reaction_span_lower_bounds[column] = bounds.lower;
                workspace.reaction_span_upper_bounds[column] = bounds.upper;
                for (0..current.len) |row| {
                    const index = row * column_count + column;
                    selected[index] = group_aliases.complementarityColumnDerivative(
                        branch,
                        negative[index],
                        positive[index],
                    );
                }
            }
            const maximum_directional_corrections: u8 = 2;
            var correction_count: u8 = 0;
            var previous_solution: [reaction_span.reaction_count]f64 = undefined;
            var require_solution_change = false;
            var counted_solved = false;
            var counted_kkt = false;
            var counted_nonzero = false;
            var counted_admissible = false;
            pattern_refinement: while (true) {
                if (!solveTernaryBoundedReactionSpan(
                    workspace,
                    current.len,
                    column_count,
                )) break :pattern_refinement;
                if (require_solution_change and
                    !ternarySolutionsMeaningfullyDifferent(
                        previous_solution[0..column_count],
                        workspace.reaction_span_solution[0..column_count],
                    )) break :pattern_refinement;
                require_solution_change = false;
                if (!counted_solved) {
                    if (diagnostic) |entry|
                        entry.ternary_correction_patterns_solved += 1;
                    counted_solved = true;
                }
                if (!pinnedCorrectionFacesKktSatisfied(
                    workspace,
                    negative,
                    positive,
                    selected,
                    current.len,
                    column_count,
                )) break :pattern_refinement;
                if (!counted_kkt) {
                    if (diagnostic) |entry|
                        entry.ternary_correction_patterns_kkt += 1;
                    counted_kkt = true;
                }

                var transformations = reaction_span.zeroTransformations(parameters);
                var has_nonzero_extent = false;
                for (workspace.reaction_span_solution[0..column_count], 0..) |
                    normalized_extent,
                    column,
                | {
                    if (!std.math.isFinite(normalized_extent))
                        return error.NonFiniteSoluteReactionExtent;
                    if (normalized_extent == 0) continue;
                    try reaction_span.addReactionExtent(
                        &transformations,
                        workspace.reaction_span_active_reactions[column],
                        normalized_extent * workspace.reaction_span_extent_scales[column],
                        current_transformations,
                        parameters,
                    );
                    has_nonzero_extent = true;
                }
                if (!has_nonzero_extent) break :pattern_refinement;
                if (!counted_nonzero) {
                    if (diagnostic) |entry|
                        entry.ternary_correction_patterns_nonzero += 1;
                    counted_nonzero = true;
                }
                const admissible_fraction = group_aliases.transformedVectorAdmissible(
                    scratch,
                    current,
                    transformations,
                    parameters,
                    1,
                    candidate_state,
                ) catch break :pattern_refinement;
                if (!counted_admissible) {
                    if (diagnostic) |entry|
                        entry.ternary_correction_patterns_admissible += 1;
                    counted_admissible = true;
                }
                const directional_fraction = @min(
                    admissible_fraction,
                    std.math.cbrt(std.math.floatEps(f64)),
                );
                const actual_direction =
                    workspace.reaction_span_projected_rhs[0..current.len];
                const actual_slope = evaluateTernaryUniformCombinedDirection(
                    scratch,
                    current,
                    global_residual,
                    transformations,
                    candidate_state,
                    residual_work,
                    actual_direction,
                    parameters,
                    options,
                    directional_fraction,
                ) catch break :pattern_refinement;
                if (actual_slope < 0) {
                    if (diagnostic) |entry|
                        entry.ternary_correction_armijo_attempts += 1;
                    var accepted_fraction: f64 = 0;
                    if (try group_acceptance.tryAcceptReactionExtentSlopeAwareLineSearch(
                        scratch,
                        current,
                        transformations,
                        admissible_fraction,
                        candidate_state,
                        accepted_state,
                        residual_work,
                        parameters,
                        options,
                        global_residual,
                        current_norm,
                        actual_slope,
                        &accepted_fraction,
                    )) {
                        if (diagnostic) |entry| {
                            entry.ternary_correction_armijo_accepted += 1;
                            entry.ternary_correction_status = .accepted;
                        }
                        return true;
                    }
                }
                if (correction_count == maximum_directional_corrections)
                    break :pattern_refinement;
                @memcpy(
                    previous_solution[0..column_count],
                    workspace.reaction_span_solution[0..column_count],
                );
                switch (applyTernaryDirectionalJacobianCorrection(
                    selected,
                    workspace.reaction_span_solution[0..column_count],
                    actual_direction,
                    current.len,
                    column_count,
                )) {
                    .invalid, .not_meaningful => break :pattern_refinement,
                    .corrected => {
                        correction_count += 1;
                        require_solution_change = true;
                        continue :pattern_refinement;
                    },
                }
            }
        }
    }
    if (diagnostic) |entry|
        entry.ternary_correction_status = .patterns_exhausted;
    return false;
}

fn tryActiveRowNewtonCandidateImpl(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
    allow_terminal_diagnostic: bool,
) !bool {
    _ = try group_aliases.evaluateAt(scratch, current, parameters);
    try reaction_span.evaluateRates(
        scratch,
        0,
        parameters,
        workspace.reaction_span_rates,
    );
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    var active_count: usize = 0;
    for (workspace.reaction_span_rates, 0..) |rate, reaction| {
        if (!std.math.isFinite(rate))
            return error.NonFiniteSoluteReactionRate;
        if (rate == 0) continue;
        const bounds_evaluations_before = diagnostic_control.evaluationCounts();
        const bounds = try group_aliases.reactionSpanExtentBounds(
            scratch,
            current,
            reaction,
            current_transformations,
            parameters,
            @abs(rate),
            coefficients.monovalent_activity_coefficient,
            candidate_state,
        );
        diagnostic_control.recordReactionSpanBoundsSite(
            .active_row_newton,
            bounds_evaluations_before,
        );
        const extent_scale = @max(
            bounds.negative_native_extent,
            bounds.positive_native_extent,
        );
        if (!std.math.isFinite(extent_scale) or extent_scale <= 0) continue;
        workspace.reaction_span_active_reactions[active_count] = reaction;
        workspace.reaction_span_extent_scales[active_count] = extent_scale;
        const physical_lower = -options.maximum_newton_fraction *
            bounds.negative_native_extent / extent_scale;
        const physical_upper = options.maximum_newton_fraction *
            bounds.positive_native_extent / extent_scale;
        workspace.reaction_span_original_lower_bounds[active_count] =
            physical_lower;
        workspace.reaction_span_original_upper_bounds[active_count] =
            physical_upper;
        workspace.reaction_span_lower_bounds[active_count] = physical_lower;
        workspace.reaction_span_upper_bounds[active_count] = physical_upper;
        active_count += 1;
    }
    workspace.reaction_span_active_count = active_count;
    if (active_count < 2) return false;
    const active_rows = topTwoScaledResidualRows(
        current,
        global_residual,
        options,
    ) orelse return false;
    for (global_residual, current, 0..) |value, state_value, row| {
        const scale = group_aliases.residualScale(state_value, row, options);
        const scaled_residual = value / scale;
        workspace.reaction_span_rhs[row] = -scaled_residual *
            group_aliases.reactionSpanRowWeight(
                scaled_residual,
                current_norm,
            );
    }
    var row_rhs: [2]f64 = undefined;
    var row_weights: [2]f64 = undefined;
    for (active_rows, 0..) |row, index| {
        const scaled_residual = global_residual[row] /
            group_aliases.residualScale(current[row], row, options);
        row_rhs[index] = -scaled_residual;
        row_weights[index] = group_aliases.reactionSpanRowWeight(
            scaled_residual,
            current_norm,
        );
        if (!std.math.isFinite(row_weights[index]) or
            row_weights[index] <= 0) return false;
    }
    const inputs = group_aliases.ComplementaritySearchInputs{
        .scratch = scratch,
        .current = current,
        .global_residual = global_residual,
        .probe_state = candidate_state,
        .probe_residual = residual_work,
        .current_transformations = current_transformations,
        .parameters = parameters,
        .options = options,
        .current_norm = current_norm,
        .monovalent_activity_coefficient = coefficients.monovalent_activity_coefficient,
        .column_count = active_count,
    };
    var negative_valid = [_]bool{false} ** reaction_span.reaction_count;
    var positive_valid = [_]bool{false} ** reaction_span.reaction_count;
    var negative_projection: [reaction_span.reaction_count]ActiveRowFaceProjection = undefined;
    var positive_projection: [reaction_span.reaction_count]ActiveRowFaceProjection = undefined;
    var derivative_probes: usize = 0;
    for (0..active_count) |column| {
        for ([_]i8{ -1, 1 }) |side| {
            const physically_available = if (side < 0)
                workspace.reaction_span_original_lower_bounds[column] < 0
            else
                workspace.reaction_span_original_upper_bounds[column] > 0;
            if (!physically_available) continue;
            derivative_probes += 1;
            @memcpy(
                workspace.reaction_span_lower_bounds[0..active_count],
                workspace.reaction_span_original_lower_bounds[0..active_count],
            );
            @memcpy(
                workspace.reaction_span_upper_bounds[0..active_count],
                workspace.reaction_span_original_upper_bounds[0..active_count],
            );
            const derivative = if (side < 0)
                workspace.reaction_span_negative_jacobian[0 .. current.len * active_count]
            else
                workspace.reaction_span_positive_jacobian[0 .. current.len * active_count];
            group_aliases.evaluateReactionSpanDerivativeColumn(
                inputs,
                workspace,
                column,
                side,
                derivative,
            ) catch continue;
            const projection = activeRowFaceProjection(
                derivative,
                active_count,
                column,
                active_rows,
                row_weights,
                row_rhs,
            );
            if (side < 0) {
                negative_valid[column] = true;
                negative_projection[column] = projection;
            } else {
                positive_valid[column] = true;
                positive_projection[column] = projection;
            }
        }
    }

    const component_count = comptime chemistry.State.packedComponentCount();
    var best = TwoAxisNewtonPrice{};
    var best_target: [component_count]f64 = undefined;
    var pair_count: usize = 0;
    // Assemble every physically available face pair, but rank it using only
    // the already-computed two-row Newton model. Exact global residual
    // evaluations are several orders of magnitude more expensive, so the
    // cheap model determines probe order while never determining acceptance.
    for (0..active_count) |left| {
        for (left + 1..active_count) |right| {
            for ([_]i8{ -1, 1 }) |left_side| {
                if ((left_side < 0 and !negative_valid[left]) or
                    (left_side > 0 and !positive_valid[left])) continue;
                for ([_]i8{ -1, 1 }) |right_side| {
                    if ((right_side < 0 and !negative_valid[right]) or
                        (right_side > 0 and !positive_valid[right])) continue;
                    const left_projection = if (left_side < 0)
                        negative_projection[left]
                    else
                        positive_projection[left];
                    const right_projection = if (right_side < 0)
                        negative_projection[right]
                    else
                        positive_projection[right];
                    const lower_left = if (left_side < 0)
                        workspace.reaction_span_original_lower_bounds[left]
                    else
                        0;
                    const upper_left = if (left_side > 0)
                        workspace.reaction_span_original_upper_bounds[left]
                    else
                        0;
                    const lower_right = if (right_side < 0)
                        workspace.reaction_span_original_lower_bounds[right]
                    else
                        0;
                    const upper_right = if (right_side > 0)
                        workspace.reaction_span_original_upper_bounds[right]
                    else
                        0;
                    const extents = boundedTwoAxisLeastSquares(
                        left_projection.self_dot,
                        left_projection.rows[0] * right_projection.rows[0] +
                            left_projection.rows[1] * right_projection.rows[1],
                        right_projection.self_dot,
                        left_projection.rhs_dot,
                        right_projection.rhs_dot,
                        lower_left,
                        upper_left,
                        lower_right,
                        upper_right,
                    );
                    if (extents[0] == 0 and extents[1] == 0) continue;
                    const predicted_residual_0 = row_rhs[0] -
                        extents[0] * left_projection.rows[0] -
                        extents[1] * right_projection.rows[0];
                    const predicted_residual_1 = row_rhs[1] -
                        extents[0] * left_projection.rows[1] -
                        extents[1] * right_projection.rows[1];
                    const predicted_score = @max(
                        @abs(predicted_residual_0),
                        @abs(predicted_residual_1),
                    );
                    if (!std.math.isFinite(predicted_score)) continue;
                    std.debug.assert(
                        pair_count < workspace.reaction_span_active_row_pair_keys.len,
                    );
                    workspace.reaction_span_active_row_pair_keys[pair_count] =
                        activeRowPairKey(.{
                            .left = left,
                            .right = right,
                            .left_side = left_side,
                            .right_side = right_side,
                        });
                    workspace.reaction_span_active_row_pair_order[pair_count] =
                        pair_count;
                    workspace.reaction_span_active_row_pair_predicted_scores[pair_count] =
                        predicted_score;
                    pair_count += 1;
                }
            }
        }
    }
    if (pair_count == 0) return false;
    const pair_keys = workspace.reaction_span_active_row_pair_keys[0..pair_count];
    const pair_order = workspace.reaction_span_active_row_pair_order[0..pair_count];
    const predicted_scores =
        workspace.reaction_span_active_row_pair_predicted_scores[0..pair_count];
    std.sort.pdq(
        usize,
        pair_order,
        ActiveRowPairOrderContext{
            .keys = pair_keys,
            .predicted_scores = predicted_scores,
        },
        ActiveRowPairOrderContext.lessThan,
    );

    const nonzero_directions = pair_count;
    var valid_directions: usize = 0;
    var consecutive_stagnant_directions: usize = 0;
    ordered_pairs: for (pair_order) |pair_index| {
        const pair = activeRowPairFromKey(pair_keys[pair_index]);
        const left = pair.left;
        const right = pair.right;
        const left_side = pair.left_side;
        const right_side = pair.right_side;
        face_pair: {
            const left_projection = if (left_side < 0)
                negative_projection[left]
            else
                positive_projection[left];
            const right_projection = if (right_side < 0)
                negative_projection[right]
            else
                positive_projection[right];
            const lower_left = if (left_side < 0)
                workspace.reaction_span_original_lower_bounds[left]
            else
                0;
            const upper_left = if (left_side > 0)
                workspace.reaction_span_original_upper_bounds[left]
            else
                0;
            const lower_right = if (right_side < 0)
                workspace.reaction_span_original_lower_bounds[right]
            else
                0;
            const upper_right = if (right_side > 0)
                workspace.reaction_span_original_upper_bounds[right]
            else
                0;
            const extents = boundedTwoAxisLeastSquares(
                left_projection.self_dot,
                left_projection.rows[0] * right_projection.rows[0] +
                    left_projection.rows[1] * right_projection.rows[1],
                right_projection.self_dot,
                left_projection.rhs_dot,
                right_projection.rhs_dot,
                lower_left,
                upper_left,
                lower_right,
                upper_right,
            );
            if (extents[0] == 0 and extents[1] == 0) continue;
            const reaction_left =
                workspace.reaction_span_active_reactions[left];
            const reaction_right =
                workspace.reaction_span_active_reactions[right];
            var transformations = reaction_span.zeroTransformations(parameters);
            if (extents[0] != 0) reaction_span.addReactionExtent(
                &transformations,
                reaction_left,
                extents[0] *
                    workspace.reaction_span_extent_scales[left],
                current_transformations,
                parameters,
            ) catch break :face_pair;
            if (extents[1] != 0) reaction_span.addReactionExtent(
                &transformations,
                reaction_right,
                extents[1] *
                    workspace.reaction_span_extent_scales[right],
                current_transformations,
                parameters,
            ) catch break :face_pair;
            _ = reaction_solver_numerics.transformedVectorAdmissibleWithMonovalentActivityCoefficient(
                scratch,
                current,
                transformations,
                parameters,
                coefficients.monovalent_activity_coefficient,
                1,
                candidate_state,
            ) catch break :face_pair;
            valid_directions += 1;
            const previous_best_norm = best.norm;
            var fraction: f64 = 1;
            for (0..active_row_newton_backtracking_trials) |_| {
                defer fraction *= 0.5;
                const candidate_norm = group_aliases.evaluateCandidateResidualAtFraction(
                    scratch,
                    current,
                    candidate_state,
                    accepted_state,
                    residual_work,
                    parameters,
                    options,
                    fraction,
                ) catch continue;
                const price_precedes = twoAxisNewtonPricePrecedes(
                    candidate_norm,
                    reaction_left,
                    reaction_right,
                    left_side,
                    right_side,
                    best.norm,
                    best.reaction_a,
                    best.reaction_b,
                    best.side_a,
                    best.side_b,
                );
                if (price_precedes) {
                    best = .{
                        .norm = candidate_norm,
                        .reaction_a = reaction_left,
                        .reaction_b = reaction_right,
                        .side_a = left_side,
                        .side_b = right_side,
                        .fraction = fraction,
                        .normalized_extent_a = extents[0],
                        .normalized_extent_b = extents[1],
                    };
                    @memcpy(
                        workspace.reaction_span_best_state,
                        accepted_state,
                    );
                    @memcpy(
                        workspace.reaction_span_best_residual,
                        residual_work,
                    );
                    @memcpy(&best_target, candidate_state);
                    // Physical-acceptance early stop: all
                    // conservation, positivity, finite-value, and Kw
                    // projection gates above have passed, and the
                    // owning nonlinear solve would accept this exact
                    // state on its next check.
                    if (activeRowCandidateAcceptable(candidate_norm)) {
                        @memcpy(
                            accepted_state,
                            workspace.reaction_span_best_state,
                        );
                        @memcpy(
                            residual_work,
                            workspace.reaction_span_best_residual,
                        );
                        return true;
                    }
                }
            }
            if (activeRowSearchMateriallyImproves(
                previous_best_norm,
                best.norm,
            )) {
                consecutive_stagnant_directions = 0;
            } else {
                consecutive_stagnant_directions += 1;
            }
            // A meaningful, exactly priced physical state is already
            // available. After the ranked search has failed to improve
            // it materially for the configured patience, publish that
            // best state instead of burning the remaining quadratic
            // retry cascade. If no meaningful state exists, continue
            // through the complete search unchanged.
            if (consecutive_stagnant_directions >=
                active_row_newton_stagnation_patience and
                meaningfulNewtonMeritDecrease(current_norm, best.norm))
            {
                break :ordered_pairs;
            }
        }
    }
    // Metal hydrolysis, carbonate protonation, CO2, and the metal-pair
    // reservoirs form one acid/base-conserved mineral block.  When aqueous
    // AlOH2 and CaCO3 are simultaneously limiting, a two-reaction face cannot
    // in general move that block without stranding a third coupled equation.
    // Keep the higher-dimensional recovery scoped to that measured topology;
    // other active-row families retain their established trajectory.
    const metal_carbonate_ridge =
        active_rows[0] ==
        reaction_solver_numerics2.aqueousPackedIndex("aluminum_hydroxide_2") and
        active_rows[1] ==
            reaction_solver_numerics2.aqueousPackedIndex("calcium_carbonate");
    if (metal_carbonate_ridge)
        _ = try tryReducedBlockNewtonCandidate(
            workspace,
            scratch,
            current,
            global_residual,
            current_transformations,
            candidate_state,
            accepted_state,
            residual_work,
            parameters,
            options,
            coefficients.monovalent_activity_coefficient,
            active_count,
            &negative_valid,
            &positive_valid,
            &best,
            &best_target,
        );
    if (allow_terminal_diagnostic and
        std.math.isFinite(best.norm) and
        !meaningfulNewtonMeritDecrease(current_norm, best.norm))
    {
        var scan_norm = best.norm;
        var scan_fraction = best.fraction;
        var scan_state: [component_count]f64 = undefined;
        var scan_residual: [component_count]f64 = undefined;
        @memcpy(&scan_state, workspace.reaction_span_best_state);
        @memcpy(&scan_residual, workspace.reaction_span_best_residual);
        const lower = 0.5 * best.fraction;
        const upper = 2.0 * best.fraction;
        for (1..16) |panel| {
            const fraction = lower + (upper - lower) *
                @as(f64, @floatFromInt(panel)) / 16.0;
            const norm = group_aliases.evaluateCandidateResidualAtFraction(
                scratch,
                current,
                &best_target,
                candidate_state,
                residual_work,
                parameters,
                options,
                fraction,
            ) catch continue;
            if (norm >= scan_norm) continue;
            scan_norm = norm;
            scan_fraction = fraction;
            @memcpy(&scan_state, candidate_state);
            @memcpy(&scan_residual, residual_work);
        }
        const limiter = group_aliases.largestScaledResidualIndex(
            &scan_state,
            &scan_residual,
            options,
        );
        var followup_found = false;
        var followup_norm = std.math.inf(f64);
        if (scan_norm < current_norm and
            !meaningfulNewtonMeritDecrease(current_norm, scan_norm))
        {
            const followup_transformations = group_aliases.evaluateAt(
                scratch,
                &scan_state,
                parameters,
            ) catch null;
            if (followup_transformations) |changes| {
                followup_found = try tryActiveRowNewtonCandidateImpl(
                    workspace,
                    scratch,
                    &scan_state,
                    &scan_residual,
                    changes,
                    candidate_state,
                    accepted_state,
                    residual_work,
                    parameters,
                    options,
                    current_norm,
                    false,
                );
                if (followup_found) {
                    followup_norm = try group_aliases.scaledNorm(
                        accepted_state,
                        residual_work,
                        options,
                    );
                }
            }
        }
        if (diagnostic_control.isEnabled()) std.log.debug(
            "SOLUTE active-row terminal refinement: constructed={d} valid={d} derivative_probes={d} scan_norm={e} scan_fraction={e} limiter={d} followup_found={any} followup_norm={e}",
            .{ nonzero_directions, valid_directions, derivative_probes, scan_norm, scan_fraction, limiter, followup_found, followup_norm },
        );
        if (followup_found and
            meaningfulNewtonMeritDecrease(current_norm, followup_norm))
        {
            best.norm = followup_norm;
            @memcpy(workspace.reaction_span_best_state, accepted_state);
            @memcpy(workspace.reaction_span_best_residual, residual_work);
        } else {
            best.norm = scan_norm;
            @memcpy(workspace.reaction_span_best_state, &scan_state);
            @memcpy(workspace.reaction_span_best_residual, &scan_residual);
        }
    }
    if (!meaningfulNewtonMeritDecrease(current_norm, best.norm)) return false;
    @memcpy(accepted_state, workspace.reaction_span_best_state);
    @memcpy(residual_work, workspace.reaction_span_best_residual);
    return true;
}

/// Prices only the trust-region head of rate-ranked scalar Newton directions.
/// Every trial still constructs a conservative bounded extent and evaluates
/// the exact global residual. Failure to reach the owning tolerance merely
/// falls through to the complete Jacobian-ranked coordinate search.
fn tryRateRankedCoordinateNewtonAcceptance(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
    monovalent_activity_coefficient: f64,
) !bool {
    var rate_order: [reaction_span.reaction_count]usize = undefined;
    var rate_count: usize = 0;
    for (workspace.reaction_span_rates, 0..) |rate, reaction| {
        if (rate == 0) continue;
        rate_order[rate_count] = reaction;
        rate_count += 1;
    }
    std.sort.pdq(
        usize,
        rate_order[0..rate_count],
        CoordinateNewtonRateOrder{ .rates = workspace.reaction_span_rates },
        CoordinateNewtonRateOrder.lessThan,
    );
    for (global_residual, current, 0..) |value, state_value, row| {
        const scale = group_aliases.residualScale(state_value, row, options);
        const active_weight = group_aliases.reactionSpanRowWeight(
            value / scale,
            current_norm,
        );
        workspace.reaction_span_rhs[row] =
            -(value / scale) * active_weight;
    }
    const limiting_row = group_aliases.largestScaledResidualIndex(
        current,
        global_residual,
        options,
    );
    const inputs = group_aliases.ComplementaritySearchInputs{
        .scratch = scratch,
        .current = current,
        .global_residual = global_residual,
        .probe_state = candidate_state,
        .probe_residual = residual_work,
        .current_transformations = current_transformations,
        .parameters = parameters,
        .options = options,
        .current_norm = current_norm,
        .monovalent_activity_coefficient = monovalent_activity_coefficient,
        .column_count = 1,
    };
    var best = CoordinateNewtonPrice{};
    for (rate_order[0..rate_count]) |reaction| {
        const bounds_evaluations_before = diagnostic_control.evaluationCounts();
        const bounds = try group_aliases.reactionSpanExtentBounds(
            scratch,
            current,
            reaction,
            current_transformations,
            parameters,
            @abs(workspace.reaction_span_rates[reaction]),
            monovalent_activity_coefficient,
            candidate_state,
        );
        diagnostic_control.recordReactionSpanBoundsSite(
            .analytic_coordinate_newton,
            bounds_evaluations_before,
        );
        const extent_scale = @max(
            bounds.negative_native_extent,
            bounds.positive_native_extent,
        );
        if (!std.math.isFinite(extent_scale) or extent_scale <= 0) continue;
        const physical_lower = -options.maximum_newton_fraction *
            bounds.negative_native_extent / extent_scale;
        const physical_upper = options.maximum_newton_fraction *
            bounds.positive_native_extent / extent_scale;
        workspace.reaction_span_active_reactions[0] = reaction;
        workspace.reaction_span_extent_scales[0] = extent_scale;
        workspace.reaction_span_lower_bounds[0] = physical_lower;
        workspace.reaction_span_upper_bounds[0] = physical_upper;

        var directions: [2]CoordinateNewtonDirection = undefined;
        var direction_count: usize = 0;
        for ([_]i8{ -1, 1 }) |side| {
            if ((side < 0 and physical_lower >= 0) or
                (side > 0 and physical_upper <= 0)) continue;
            const derivative = if (side < 0)
                workspace.reaction_span_negative_jacobian[0..current.len]
            else
                workspace.reaction_span_positive_jacobian[0..current.len];
            group_aliases.evaluateReactionSpanDerivativeColumn(
                inputs,
                workspace,
                0,
                side,
                derivative,
            ) catch continue;
            var numerator: f64 = 0;
            var denominator: f64 = 0;
            for (workspace.reaction_span_rhs[0..current.len], 0..) |rhs, row| {
                const value = derivative[row];
                if (!std.math.isFinite(value)) {
                    denominator = 0;
                    break;
                }
                numerator += value * rhs;
                denominator += value * value;
            }
            const lower = if (side < 0) physical_lower else 0;
            const upper = if (side < 0) 0 else physical_upper;
            const least_squares_extent = clampedScalarCoordinateNewtonExtent(
                numerator,
                denominator,
                lower,
                upper,
            );
            const limiting_extent = clampedScalarCoordinateNewtonExtent(
                workspace.reaction_span_rhs[limiting_row],
                derivative[limiting_row],
                lower,
                upper,
            );
            if (least_squares_extent == 0 and limiting_extent == 0) continue;
            var least_squares_score: f64 = 0;
            var limiting_score: f64 = 0;
            for (workspace.reaction_span_rhs[0..current.len], 0..) |rhs, row| {
                least_squares_score = @max(
                    least_squares_score,
                    @abs(rhs - derivative[row] * least_squares_extent),
                );
                limiting_score = @max(
                    limiting_score,
                    @abs(rhs - derivative[row] * limiting_extent),
                );
            }
            const predicted_score = @min(least_squares_score, limiting_score);
            if (!std.math.isFinite(predicted_score)) continue;
            directions[direction_count] = .{
                .column = 0,
                .reaction = reaction,
                .side = side,
                .least_squares_extent = least_squares_extent,
                .limiting_extent = limiting_extent,
                .predicted_score = predicted_score,
            };
            direction_count += 1;
        }
        std.sort.pdq(
            CoordinateNewtonDirection,
            directions[0..direction_count],
            {},
            CoordinateNewtonDirectionOrder.lessThan,
        );
        for (directions[0..direction_count]) |direction| {
            _ = try priceScalarCoordinateNewtonDirection(
                workspace,
                scratch,
                current,
                current_transformations,
                candidate_state,
                accepted_state,
                residual_work,
                parameters,
                options,
                reaction,
                direction.least_squares_extent,
                extent_scale,
                1,
                &best,
            );
            if (activeRowCandidateAcceptable(best.norm)) {
                @memcpy(accepted_state, workspace.reaction_span_best_state);
                @memcpy(residual_work, workspace.reaction_span_best_residual);
                return true;
            }
            if (direction.limiting_extent == direction.least_squares_extent)
                continue;
            _ = try priceScalarCoordinateNewtonDirection(
                workspace,
                scratch,
                current,
                current_transformations,
                candidate_state,
                accepted_state,
                residual_work,
                parameters,
                options,
                reaction,
                direction.limiting_extent,
                extent_scale,
                1,
                &best,
            );
            if (activeRowCandidateAcceptable(best.norm)) {
                @memcpy(accepted_state, workspace.reaction_span_best_state);
                @memcpy(residual_work, workspace.reaction_span_best_residual);
                return true;
            }
        }
    }
    return false;
}

/// The rate-ranked head is only a shortcut before the complete coordinate
/// search. Owners may cap it for deliberately hard entry states where a
/// corpus trace proves that scanning every rate merely duplicates the full
/// search which follows.
pub fn shouldTryRateRankedCoordinateNewtonHead(
    options: group_aliases.Options,
    current_norm: f64,
) bool {
    return std.math.isFinite(current_norm) and current_norm <=
        options.rate_ranked_coordinate_head_maximum_norm;
}

/// On-demand coordinate Newton recovery. Both physical one-sided columns of
/// active source reactions are solved as scalar weighted least-squares Newton
/// systems, clamped to their conservative half-boxes, and exactly globally
/// priced. A deterministic rate-ranked, single-trial scan can stop at the
/// first physically admissible state whose global residual satisfies the
/// owning solver tolerance; otherwise the complete fixed-backtracking,
/// Jacobian-ranked reaction search remains available.
/// No raw Picard state is publishable.
pub fn tryAnalyticCoordinateNewtonCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
) !bool {
    diagnostic_control.recordStrategyCall(.analytic_coordinate_newton);
    var diagnostic_strategy_scope = diagnostic_control.enterStrategy(.analytic_coordinate_newton);
    defer diagnostic_strategy_scope.deinit();
    _ = try group_aliases.evaluateAt(scratch, current, parameters);
    try reaction_span.evaluateRates(
        scratch,
        0,
        parameters,
        workspace.reaction_span_rates,
    );
    for (workspace.reaction_span_rates) |rate|
        if (!std.math.isFinite(rate))
            return error.NonFiniteSoluteReactionRate;
    const coefficients =
        try scratch.activityCoefficients(0, parameters.fractions);
    if (shouldTryRateRankedCoordinateNewtonHead(options, current_norm) and
        try tryRateRankedCoordinateNewtonAcceptance(
            workspace,
            scratch,
            current,
            global_residual,
            current_transformations,
            candidate_state,
            accepted_state,
            residual_work,
            parameters,
            options,
            current_norm,
            coefficients.monovalent_activity_coefficient,
        )) return true;
    var active_count: usize = 0;
    for (workspace.reaction_span_rates, 0..) |rate, reaction| {
        if (rate == 0) continue;
        const bounds_evaluations_before = diagnostic_control.evaluationCounts();
        const bounds = try group_aliases.reactionSpanExtentBounds(
            scratch,
            current,
            reaction,
            current_transformations,
            parameters,
            @abs(rate),
            coefficients.monovalent_activity_coefficient,
            candidate_state,
        );
        diagnostic_control.recordReactionSpanBoundsSite(
            .analytic_coordinate_newton,
            bounds_evaluations_before,
        );
        const extent_scale = @max(
            bounds.negative_native_extent,
            bounds.positive_native_extent,
        );
        if (!std.math.isFinite(extent_scale) or extent_scale <= 0) continue;
        workspace.reaction_span_active_reactions[active_count] = reaction;
        workspace.reaction_span_extent_scales[active_count] = extent_scale;
        workspace.reaction_span_original_lower_bounds[active_count] =
            -options.maximum_newton_fraction *
            bounds.negative_native_extent / extent_scale;
        workspace.reaction_span_original_upper_bounds[active_count] =
            options.maximum_newton_fraction *
            bounds.positive_native_extent / extent_scale;
        workspace.reaction_span_lower_bounds[active_count] =
            workspace.reaction_span_original_lower_bounds[active_count];
        workspace.reaction_span_upper_bounds[active_count] =
            workspace.reaction_span_original_upper_bounds[active_count];
        active_count += 1;
    }
    if (active_count == 0) return false;
    workspace.reaction_span_active_count = active_count;
    for (global_residual, current, 0..) |value, state_value, row| {
        const scale = group_aliases.residualScale(state_value, row, options);
        const active_weight = group_aliases.reactionSpanRowWeight(
            value / scale,
            current_norm,
        );
        workspace.reaction_span_rhs[row] =
            -(value / scale) * active_weight;
    }
    const limiting_row = group_aliases.largestScaledResidualIndex(
        current,
        global_residual,
        options,
    );
    const inputs = group_aliases.ComplementaritySearchInputs{
        .scratch = scratch,
        .current = current,
        .global_residual = global_residual,
        .probe_state = candidate_state,
        .probe_residual = residual_work,
        .current_transformations = current_transformations,
        .parameters = parameters,
        .options = options,
        .current_norm = current_norm,
        .monovalent_activity_coefficient = coefficients.monovalent_activity_coefficient,
        .column_count = active_count,
    };
    var best = CoordinateNewtonPrice{};
    var negative_valid =
        [_]bool{false} ** reaction_span.reaction_count;
    var positive_valid =
        [_]bool{false} ** reaction_span.reaction_count;
    var directions: [2 * reaction_span.reaction_count]CoordinateNewtonDirection = undefined;
    var direction_count: usize = 0;
    for (0..active_count) |column| {
        const reaction = workspace.reaction_span_active_reactions[column];
        const physical_lower =
            workspace.reaction_span_original_lower_bounds[column];
        const physical_upper =
            workspace.reaction_span_original_upper_bounds[column];
        for ([_]i8{ -1, 1 }) |side| {
            if ((side < 0 and physical_lower >= 0) or
                (side > 0 and physical_upper <= 0)) continue;
            const derivative = if (side < 0)
                workspace.reaction_span_negative_jacobian[0 .. current.len * active_count]
            else
                workspace.reaction_span_positive_jacobian[0 .. current.len * active_count];
            group_aliases.evaluateReactionSpanDerivativeColumn(
                inputs,
                workspace,
                column,
                side,
                derivative,
            ) catch continue;
            if (side < 0)
                negative_valid[column] = true
            else
                positive_valid[column] = true;
            var numerator: f64 = 0;
            var denominator: f64 = 0;
            for (workspace.reaction_span_rhs[0..current.len], 0..) |rhs, row| {
                const value = derivative[row * active_count + column];
                if (!std.math.isFinite(value)) {
                    denominator = 0;
                    break;
                }
                numerator += value * rhs;
                denominator += value * value;
            }
            const lower = if (side < 0) physical_lower else 0;
            const upper = if (side < 0) 0 else physical_upper;
            const least_squares_extent = clampedScalarCoordinateNewtonExtent(
                numerator,
                denominator,
                lower,
                upper,
            );
            const limiting_derivative =
                derivative[limiting_row * active_count + column];
            const limiting_extent = clampedScalarCoordinateNewtonExtent(
                workspace.reaction_span_rhs[limiting_row],
                limiting_derivative,
                lower,
                upper,
            );
            if (least_squares_extent == 0 and limiting_extent == 0) continue;
            var least_squares_score: f64 = 0;
            var limiting_score: f64 = 0;
            for (workspace.reaction_span_rhs[0..current.len], 0..) |rhs, row| {
                const value = derivative[row * active_count + column];
                least_squares_score = @max(
                    least_squares_score,
                    @abs(rhs - value * least_squares_extent),
                );
                limiting_score = @max(
                    limiting_score,
                    @abs(rhs - value * limiting_extent),
                );
            }
            const predicted_score = @min(
                least_squares_score,
                limiting_score,
            );
            if (!std.math.isFinite(predicted_score)) continue;
            std.debug.assert(direction_count < directions.len);
            directions[direction_count] = .{
                .column = column,
                .reaction = reaction,
                .side = side,
                .least_squares_extent = least_squares_extent,
                .limiting_extent = limiting_extent,
                .predicted_score = predicted_score,
            };
            direction_count += 1;
        }
    }
    std.sort.pdq(
        CoordinateNewtonDirection,
        directions[0..direction_count],
        {},
        CoordinateNewtonDirectionOrder.lessThan,
    );
    for (directions[0..direction_count]) |direction| {
        const extent_scale =
            workspace.reaction_span_extent_scales[direction.column];
        _ = try priceScalarCoordinateNewtonDirection(
            workspace,
            scratch,
            current,
            current_transformations,
            candidate_state,
            accepted_state,
            residual_work,
            parameters,
            options,
            direction.reaction,
            direction.least_squares_extent,
            extent_scale,
            coordinate_newton_backtracking_trials,
            &best,
        );
        if (activeRowCandidateAcceptable(best.norm)) {
            @memcpy(accepted_state, workspace.reaction_span_best_state);
            @memcpy(residual_work, workspace.reaction_span_best_residual);
            return true;
        }
        if (direction.limiting_extent != direction.least_squares_extent) {
            _ = try priceScalarCoordinateNewtonDirection(
                workspace,
                scratch,
                current,
                current_transformations,
                candidate_state,
                accepted_state,
                residual_work,
                parameters,
                options,
                direction.reaction,
                direction.limiting_extent,
                extent_scale,
                coordinate_newton_backtracking_trials,
                &best,
            );
            if (activeRowCandidateAcceptable(best.norm)) {
                @memcpy(accepted_state, workspace.reaction_span_best_state);
                @memcpy(residual_work, workspace.reaction_span_best_residual);
                return true;
            }
        }
    }
    // A calcium-reference basis is full rank in the interior, but an
    // individual column can be inadmissible when calcium is pinned even
    // though a paired non-Ca exchange with zero net calcium is admissible.
    // Price those active-face Newton coordinates explicitly. They remain
    // conservative reaction-span steps and receive the same exact global
    // line search as every other coordinate Newton candidate.
    try scratch.unpackCell(0, current);
    var gapon_aqueous: [reaction_span.gapon_reaction_count]f64 = undefined;
    var gapon_exchange: [reaction_span.gapon_reaction_count]f64 = undefined;
    var gapon_ratio: [reaction_span.gapon_reaction_count]f64 = undefined;
    var gapon_valence: [reaction_span.gapon_reaction_count]f64 = undefined;
    for (0..reaction_span.gapon_reaction_count) |local| {
        gapon_aqueous[local] = gaponBasisAqueousInventory(scratch, local) orelse
            unreachable;
        gapon_exchange[local] = gaponBasisExchangeInventory(scratch, local) orelse
            unreachable;
        gapon_ratio[local] = gaponBasisOwnerRatio(parameters, local) orelse
            unreachable;
        gapon_valence[local] = reaction_span.gaponBasisSiteChargeWeight(
            local,
            parameters.fractions,
        ) orelse
            unreachable;
    }
    const component_count = comptime chemistry.State.packedComponentCount();
    var swap_derivative: [component_count]f64 = undefined;
    const active_rows = topTwoScaledResidualRows(
        current,
        global_residual,
        options,
    );
    for (0..reaction_span.gapon_reaction_count) |first| {
        if (workspace.reaction_span_rates[
            reaction_span.gapon_reaction_offset + first
        ] == 0 or gapon_ratio[first] == 0) continue;
        for (first + 1..reaction_span.gapon_reaction_count) |second| {
            if (workspace.reaction_span_rates[
                reaction_span.gapon_reaction_offset + second
            ] == 0 or gapon_ratio[second] == 0) continue;
            const native_bounds = gaponSwapBounds(
                gapon_aqueous[first],
                gapon_exchange[first],
                gapon_ratio[first],
                gapon_valence[first],
                gapon_aqueous[second],
                gapon_exchange[second],
                gapon_ratio[second],
                gapon_valence[second],
            ) orelse continue;
            const native_extent_scale = @max(
                -native_bounds.lower,
                native_bounds.upper,
            );
            if (!std.math.isFinite(native_extent_scale) or
                native_extent_scale <= 0) continue;
            const normalized_lower = options.maximum_newton_fraction *
                native_bounds.lower / native_extent_scale;
            const normalized_upper = options.maximum_newton_fraction *
                native_bounds.upper / native_extent_scale;
            for ([_]i8{ -1, 1 }) |side| {
                const available = if (side < 0)
                    -normalized_lower
                else
                    normalized_upper;
                if (available <= 0) continue;
                const probe_magnitude = @min(
                    @sqrt(std.math.floatEps(f64)),
                    0.125 * available,
                );
                if (!std.math.isFinite(probe_magnitude) or
                    probe_magnitude <= 64 * std.math.floatEps(f64)) continue;
                const normalized_probe =
                    @as(f64, @floatFromInt(side)) * probe_magnitude;
                var probe_transformations =
                    reaction_span.zeroTransformations(parameters);
                try reaction_span.addGaponSwapExtent(
                    &probe_transformations,
                    first,
                    second,
                    normalized_probe * native_extent_scale,
                    parameters.fractions,
                );
                _ = group_aliases.transformedVectorAdmissible(
                    scratch,
                    current,
                    probe_transformations,
                    parameters,
                    1,
                    candidate_state,
                ) catch continue;
                group_aliases.evaluateGlobalResidualAt(
                    scratch,
                    candidate_state,
                    parameters,
                    residual_work,
                ) catch continue;
                var numerator: f64 = 0;
                var denominator: f64 = 0;
                for (0..current.len) |row| {
                    const scale = group_aliases.residualScale(
                        current[row],
                        row,
                        options,
                    );
                    const active_weight = group_aliases.reactionSpanRowWeight(
                        global_residual[row] / scale,
                        current_norm,
                    );
                    const derivative =
                        reaction_solver_numerics.scaledResidualDifference(current[row], global_residual[row], candidate_state[row], residual_work[row], row, options) / normalized_probe * active_weight;
                    if (!std.math.isFinite(derivative)) {
                        denominator = 0;
                        break;
                    }
                    swap_derivative[row] = derivative;
                    numerator += derivative * workspace.reaction_span_rhs[row];
                    denominator += derivative * derivative;
                }
                const lower = if (side < 0) normalized_lower else 0;
                const upper = if (side < 0) 0 else normalized_upper;
                const least_squares_extent =
                    clampedScalarCoordinateNewtonExtent(
                        numerator,
                        denominator,
                        lower,
                        upper,
                    );
                const limiting_extent = clampedScalarCoordinateNewtonExtent(
                    workspace.reaction_span_rhs[limiting_row],
                    swap_derivative[limiting_row],
                    lower,
                    upper,
                );
                const active_extent = if (active_rows) |rows|
                    clampedScalarCoordinateNewtonExtent(
                        swap_derivative[rows[0]] *
                            workspace.reaction_span_rhs[rows[0]] +
                            swap_derivative[rows[1]] *
                                workspace.reaction_span_rhs[rows[1]],
                        swap_derivative[rows[0]] * swap_derivative[rows[0]] +
                            swap_derivative[rows[1]] * swap_derivative[rows[1]],
                        lower,
                        upper,
                    )
                else
                    0;
                try priceGaponSwapNewtonDirection(
                    workspace,
                    scratch,
                    current,
                    candidate_state,
                    accepted_state,
                    residual_work,
                    parameters,
                    options,
                    first,
                    second,
                    least_squares_extent,
                    native_extent_scale,
                    &best,
                );
                if (activeRowCandidateAcceptable(best.norm)) {
                    @memcpy(accepted_state, workspace.reaction_span_best_state);
                    @memcpy(residual_work, workspace.reaction_span_best_residual);
                    return true;
                }
                if (limiting_extent != least_squares_extent) try priceGaponSwapNewtonDirection(
                    workspace,
                    scratch,
                    current,
                    candidate_state,
                    accepted_state,
                    residual_work,
                    parameters,
                    options,
                    first,
                    second,
                    limiting_extent,
                    native_extent_scale,
                    &best,
                );
                if (activeRowCandidateAcceptable(best.norm)) {
                    @memcpy(accepted_state, workspace.reaction_span_best_state);
                    @memcpy(residual_work, workspace.reaction_span_best_residual);
                    return true;
                }
                if (active_extent != least_squares_extent and
                    active_extent != limiting_extent) try priceGaponSwapNewtonDirection(
                    workspace,
                    scratch,
                    current,
                    candidate_state,
                    accepted_state,
                    residual_work,
                    parameters,
                    options,
                    first,
                    second,
                    active_extent,
                    native_extent_scale,
                    &best,
                );
                if (activeRowCandidateAcceptable(best.norm)) {
                    @memcpy(accepted_state, workspace.reaction_span_best_state);
                    @memcpy(residual_work, workspace.reaction_span_best_residual);
                    return true;
                }
            }
        }
    }
    if (meaningfulNewtonMeritDecrease(current_norm, best.norm)) {
        @memcpy(accepted_state, workspace.reaction_span_best_state);
        @memcpy(residual_work, workspace.reaction_span_best_residual);
        return true;
    }
    return tryBoundedTwoAxisNewtonCandidate(
        workspace,
        scratch,
        current,
        current_transformations,
        candidate_state,
        accepted_state,
        residual_work,
        parameters,
        options,
        current_norm,
        limiting_row,
        active_count,
        &negative_valid,
        &positive_valid,
    );
}

/// Rebuild an accelerated coordinate through its conservative reaction ledger.
/// Extrapolating separately rounded H/OH concentrations can magnify an ULP in
/// their difference into a charge leak, even for a charge-neutral coordinate.
pub fn conservativeCoordinateAndersonTarget(
    scratch: *chemistry.State,
    current: []const f64,
    reference: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    reaction: usize,
    seed_extent: f64,
    mixing: f64,
    output: []f64,
) !bool {
    const extent = (1 - mixing) * seed_extent;
    if (!std.math.isFinite(extent) or extent == 0 or extent == seed_extent) return false;
    var transformations = reaction_span.zeroTransformations(parameters);
    try reaction_span.addReactionExtent(&transformations, reaction, extent, reference, parameters);
    _ = group_aliases.transformedVectorAdmissible(scratch, current, transformations, parameters, 1, output) catch return false;
    return true;
}

/// Last-resort source-order coordinate recovery. Each trial uses exactly one
/// current-state native clipped reaction rate on its current kinetic side as
/// a Picard seed. The seed is never publishable: only a genuine depth-one
/// Anderson candidate formed from the current and seeded fixed-point defects
/// is globally backtracked and exactly priced.
pub fn tryCurrentSignCoordinateAndersonCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    current_transformations: chemistry.CellTransformations,
    seed_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
) !bool {
    diagnostic_control.recordStrategyCall(.current_sign_coordinate_anderson);
    var diagnostic_strategy_scope = diagnostic_control.enterStrategy(.current_sign_coordinate_anderson);
    defer diagnostic_strategy_scope.deinit();
    // This fallback runs after boundary and complementarity candidates, both
    // of which legitimately reuse the reaction-span workspace for private
    // states. Rebuild the complete carrier at `current`; consuming whichever
    // metadata the preceding generator left behind can select the wrong
    // reaction, rate sign, extent scale, or inventory box.
    _ = try group_aliases.evaluateAt(scratch, current, parameters);
    try reaction_span.evaluateRates(
        scratch,
        0,
        parameters,
        workspace.reaction_span_rates,
    );
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    var column_count: usize = 0;
    for (workspace.reaction_span_rates, 0..) |rate, reaction| {
        if (!std.math.isFinite(rate))
            return error.NonFiniteSoluteReactionRate;
        if (rate == 0) continue;
        const bounds_evaluations_before = diagnostic_control.evaluationCounts();
        const bounds = try group_aliases.reactionSpanExtentBounds(
            scratch,
            current,
            reaction,
            current_transformations,
            parameters,
            @abs(rate),
            coefficients.monovalent_activity_coefficient,
            seed_state,
        );
        diagnostic_control.recordReactionSpanBoundsSite(
            .current_sign_coordinate_anderson,
            bounds_evaluations_before,
        );
        const extent_scale = @max(
            bounds.negative_native_extent,
            bounds.positive_native_extent,
        );
        if (!std.math.isFinite(extent_scale) or extent_scale <= 0) continue;
        workspace.reaction_span_active_reactions[column_count] = reaction;
        workspace.reaction_span_extent_scales[column_count] = extent_scale;
        const physical_lower = -options.maximum_newton_fraction *
            bounds.negative_native_extent / extent_scale;
        const physical_upper = options.maximum_newton_fraction *
            bounds.positive_native_extent / extent_scale;
        workspace.reaction_span_original_lower_bounds[column_count] =
            physical_lower;
        workspace.reaction_span_original_upper_bounds[column_count] =
            physical_upper;
        workspace.reaction_span_lower_bounds[column_count] = physical_lower;
        workspace.reaction_span_upper_bounds[column_count] = physical_upper;
        column_count += 1;
    }
    workspace.reaction_span_active_count = column_count;
    if (column_count == 0) return false;
    var best_norm = current_norm;
    var found = false;
    for (0..column_count) |column| {
        const reaction = workspace.reaction_span_active_reactions[column];
        const rate = workspace.reaction_span_rates[reaction];
        const extent_scale = workspace.reaction_span_extent_scales[column];
        if (!std.math.isFinite(rate) or
            !std.math.isFinite(extent_scale) or
            rate == 0 or
            extent_scale <= 0)
        {
            continue;
        }
        const native_extent = currentSignClippedNativeExtent(
            rate,
            extent_scale,
            workspace.reaction_span_lower_bounds[column],
            workspace.reaction_span_upper_bounds[column],
        );
        if (native_extent == 0) continue;

        var transformations = reaction_span.zeroTransformations(parameters);
        try reaction_span.addReactionExtent(
            &transformations,
            reaction,
            native_extent,
            current_transformations,
            parameters,
        );
        const seed_fraction = group_aliases.transformedVectorAdmissible(
            scratch,
            current,
            transformations,
            parameters,
            1,
            seed_state,
        ) catch continue;
        group_aliases.evaluateGlobalResidualAt(
            scratch,
            seed_state,
            parameters,
            residual_work,
        ) catch continue;
        const mixing = reaction_solver_numerics.scaledAndersonDepthOneMixing(
            current,
            global_residual,
            residual_work,
            options,
        ) orelse continue;
        if (!try conservativeCoordinateAndersonTarget(
            scratch,
            current,
            current_transformations,
            parameters,
            reaction,
            native_extent * seed_fraction,
            mixing,
            workspace.complementarity_candidate_state,
        )) continue;
        if (std.mem.eql(
            f64,
            seed_state,
            workspace.complementarity_candidate_state,
        )) continue;
        if (!try group_acceptance.tryAcceptAndersonCandidate(
            scratch,
            current,
            workspace.complementarity_candidate_state,
            accepted_state,
            residual_work,
            parameters,
            options,
            current_norm,
        )) continue;
        const candidate_norm = try group_aliases.scaledNorm(
            accepted_state,
            residual_work,
            options,
        );
        if (!meaningfulNewtonMeritDecrease(current_norm, candidate_norm) or
            candidate_norm >= best_norm)
        {
            continue;
        }
        best_norm = candidate_norm;
        found = true;
        @memcpy(workspace.reaction_span_best_state, accepted_state);
        @memcpy(workspace.reaction_span_best_residual, residual_work);
    }
    if (!found or !meaningfulNewtonMeritDecrease(current_norm, best_norm))
        return false;
    @memcpy(accepted_state, workspace.reaction_span_best_state);
    @memcpy(residual_work, workspace.reaction_span_best_residual);
    return true;
}

/// Normalizes the current reaction direction without discarding its opposite
/// physical bound or hiding a small, representable donor behind a larger one.
pub fn currentSideExtentScale(rate: f64, negative: f64, positive: f64) f64 {
    const widest = @max(negative, positive);
    const current_side = if (rate < 0) negative else if (rate > 0) positive else widest;
    // Both native bounds are retained below. Scaling by the opposite donor
    // can shrink a real current-side direction below the probe resolution.
    // Keep the widest scale only when no current side exists or its inverse
    // would make the opposite normalized bound non-finite.
    if (current_side > 0 and std.math.isFinite(widest / current_side)) return current_side;
    return widest;
}

/// Publishes every structurally enabled reaction axis with a nonempty local
/// inventory box. A zero current rate remains an active complementarity face;
/// only runtime/source-disabled reactions are absent. The caller owns rate
/// evaluation so this helper is also usable by focused active-set tests.
pub fn initializeFullNetworkReactionAxes(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    monovalent_activity_coefficient: f64,
) !usize {
    var active_count: usize = 0;
    for (workspace.reaction_span_rates, 0..) |rate, reaction| {
        if (!std.math.isFinite(rate))
            return error.NonFiniteSoluteReactionRate;
        if (!reaction_span.reactionStructurallyEnabled(parameters, reaction)) {
            if (rate != 0)
                return error.StructurallyDisabledSoluteReactionRate;
            continue;
        }
        if (rate == 0 and !options.include_zero_rate_full_network_axes)
            continue;
        const bounds_evaluations_before = diagnostic_control.evaluationCounts();
        const bounds = try group_aliases.reactionSpanExtentBounds(
            scratch,
            current,
            reaction,
            current_transformations,
            parameters,
            @abs(rate),
            monovalent_activity_coefficient,
            candidate_state,
        );
        diagnostic_control.recordReactionSpanBoundsSite(
            .full_network_axes,
            bounds_evaluations_before,
        );
        const extent_scale = currentSideExtentScale(
            rate,
            bounds.negative_native_extent,
            bounds.positive_native_extent,
        );
        if (!std.math.isFinite(extent_scale) or extent_scale <= 0) continue;
        workspace.reaction_span_active_reactions[active_count] =
            reaction;
        workspace.reaction_span_extent_scales[active_count] =
            extent_scale;
        const physical_lower =
            -options.maximum_newton_fraction *
            bounds.negative_native_extent / extent_scale;
        const physical_upper =
            options.maximum_newton_fraction *
            bounds.positive_native_extent / extent_scale;
        workspace.reaction_span_original_lower_bounds[active_count] =
            physical_lower;
        workspace.reaction_span_original_upper_bounds[active_count] =
            physical_upper;
        const primary_bounds = primaryCurrentFaceBounds(
            rate,
            physical_lower,
            physical_upper,
        );
        workspace.reaction_span_lower_bounds[active_count] =
            primary_bounds.lower;
        workspace.reaction_span_upper_bounds[active_count] =
            primary_bounds.upper;
        workspace.reaction_span_branch_states[active_count] =
            reactionRateBranch(rate);
        active_count += 1;
    }

    workspace.reaction_span_active_count = active_count;
    return active_count;
}

/// Rank-revealing semismooth Newton step in the complete conservative
/// equilibrium-reaction span. Native extents are normalized by their local
/// inventory boxes before QR so mol/m3 and mol/Mg axes can share one
/// numerically meaningful system.
pub fn tryFullNetworkReactionCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
    diagnostic: ?*group_aliases.IterationDiagnostic,
    trace: ?*group_aliases.SolverTrace,
) !bool {
    diagnostic_control.recordStrategyCall(.full_network_newton);
    var diagnostic_strategy_scope = diagnostic_control.enterStrategy(.full_network_newton);
    defer diagnostic_strategy_scope.deinit();
    workspace.reaction_span_last_predicted_norm = std.math.inf(f64);
    if (diagnostic) |entry|
        entry.full_network_status = .not_attempted;
    // Newton is linearized at `current`: select its active reaction sides,
    // activity coefficients, inventory scales, and one-sided columns from
    // that same state. The former prospective-map selection could flip a
    // stiff reaction (notably hydroxyapatite) before probing a direction that
    // was still applied about `current`, mixing two different generalized
    // Jacobians. A direction that genuinely crosses a branch remains owned by
    // the two-sided complementarity recovery below.
    _ = try group_aliases.evaluateAt(scratch, current, parameters);
    try reaction_span.evaluateRates(
        scratch,
        0,
        parameters,
        workspace.reaction_span_rates,
    );
    const coefficients =
        try scratch.activityCoefficients(0, parameters.fractions);
    var active_count = try initializeFullNetworkReactionAxes(
        workspace,
        scratch,
        current,
        current_transformations,
        candidate_state,
        parameters,
        options,
        coefficients.monovalent_activity_coefficient,
    );

    if (diagnostic) |entry|
        entry.full_network_active_columns = active_count;
    if (active_count == 0) {
        if (diagnostic) |entry|
            entry.full_network_status = .no_active_reactions;
        return false;
    }

    const jacobian =
        workspace.reaction_span_jacobian[0 .. current.len * active_count];
    @memset(jacobian, 0);
    for (global_residual, current, 0..) |value, state_value, row| {
        const scale = group_aliases.residualScale(state_value, row, options);
        const active_weight = group_aliases.reactionSpanRowWeight(
            value / scale,
            current_norm,
        );
        workspace.reaction_span_rhs[row] =
            -(value / scale) * active_weight;
    }

    var populated_columns: usize = 0;
    const primary_inputs = group_aliases.ComplementaritySearchInputs{
        .scratch = scratch,
        .current = current,
        .global_residual = global_residual,
        .probe_state = candidate_state,
        .probe_residual = residual_work,
        .current_transformations = current_transformations,
        .parameters = parameters,
        .options = options,
        .current_norm = current_norm,
        .monovalent_activity_coefficient = coefficients.monovalent_activity_coefficient,
        .column_count = active_count,
    };
    for (0..active_count) |column| {
        const reaction =
            workspace.reaction_span_active_reactions[column];
        const rate = workspace.reaction_span_rates[reaction];
        var column_populated = false;
        if (rate == 0) {
            // The zero-rate face has no privileged kinetic side. Probe the
            // complete physical box, publish the Clarke column, then restore
            // the fixed primary box so only complementarity may choose a side.
            workspace.reaction_span_lower_bounds[column] =
                workspace.reaction_span_original_lower_bounds[column];
            workspace.reaction_span_upper_bounds[column] =
                workspace.reaction_span_original_upper_bounds[column];
            defer {
                workspace.reaction_span_lower_bounds[column] = 0;
                workspace.reaction_span_upper_bounds[column] = 0;
            }
            const negative_jacobian = workspace.reaction_span_negative_jacobian[0 .. current.len * active_count];
            const positive_jacobian = workspace.reaction_span_positive_jacobian[0 .. current.len * active_count];
            const available = physicalDerivativeSidesAvailable(
                workspace.reaction_span_original_lower_bounds[column],
                workspace.reaction_span_original_upper_bounds[column],
            );
            var negative_valid = false;
            if (available.negative) {
                if (group_aliases.evaluateReactionSpanDerivativeColumn(
                    primary_inputs,
                    workspace,
                    column,
                    -1,
                    negative_jacobian,
                )) |_| {
                    negative_valid = derivativeColumnFiniteAndNonzero(
                        negative_jacobian,
                        current.len,
                        active_count,
                        column,
                    );
                } else |_| {}
            }
            var positive_valid = false;
            if (available.positive) {
                if (group_aliases.evaluateReactionSpanDerivativeColumn(
                    primary_inputs,
                    workspace,
                    column,
                    1,
                    positive_jacobian,
                )) |_| {
                    positive_valid = derivativeColumnFiniteAndNonzero(
                        positive_jacobian,
                        current.len,
                        active_count,
                        column,
                    );
                } else |_| {}
            }
            if (negative_valid or positive_valid) {
                for (0..current.len) |row| {
                    const index = row * active_count + column;
                    jacobian[index] = if (negative_valid and positive_valid)
                        group_aliases.complementarityColumnDerivative(
                            0,
                            negative_jacobian[index],
                            positive_jacobian[index],
                        )
                    else if (negative_valid)
                        negative_jacobian[index]
                    else
                        positive_jacobian[index];
                }
                // A zero Clarke average can still have two real one-sided
                // derivatives, so it is not a derivative-empty axis.
                column_populated = true;
            }
        } else {
            const direction = reactionRateBranch(rate);
            const current_side_jacobian = if (direction < 0)
                workspace.reaction_span_negative_jacobian[0 .. current.len * active_count]
            else
                workspace.reaction_span_positive_jacobian[0 .. current.len * active_count];
            var current_side_probe_succeeded = false;
            if (group_aliases.evaluateReactionSpanDerivativeColumn(
                primary_inputs,
                workspace,
                column,
                direction,
                current_side_jacobian,
            )) |_| {
                current_side_probe_succeeded = derivativeColumnFiniteAndNonzero(
                    current_side_jacobian,
                    current.len,
                    active_count,
                    column,
                );
            } else |_| {}

            if (current_side_probe_succeeded) {
                for (0..current.len) |row| {
                    const index = row * active_count + column;
                    jacobian[index] = primaryCurrentSideDerivativeValue(
                        jacobian[index],
                        current_side_jacobian[index],
                        true,
                    );
                }
            } else if (!try evaluateLegacyPrimaryDerivativeColumn(
                primary_inputs,
                workspace,
                column,
                direction,
                jacobian,
            )) {
                const opposite_direction = -direction;
                const opposite_side_jacobian = if (opposite_direction < 0)
                    workspace.reaction_span_negative_jacobian[0 .. current.len * active_count]
                else
                    workspace.reaction_span_positive_jacobian[0 .. current.len * active_count];
                var opposite_probe_succeeded = false;
                if (group_aliases.evaluateReactionSpanDerivativeColumn(
                    primary_inputs,
                    workspace,
                    column,
                    opposite_direction,
                    opposite_side_jacobian,
                )) |_| {
                    opposite_probe_succeeded = derivativeColumnFiniteAndNonzero(
                        opposite_side_jacobian,
                        current.len,
                        active_count,
                        column,
                    );
                } else |_| {}
                if (opposite_probe_succeeded) {
                    for (0..current.len) |row| {
                        const index = row * active_count + column;
                        jacobian[index] = opposite_side_jacobian[index];
                    }
                } else if (!try evaluateLegacyPrimaryDerivativeColumn(
                    primary_inputs,
                    workspace,
                    column,
                    opposite_direction,
                    jacobian,
                )) {
                    continue;
                }
            }
            column_populated = derivativeColumnFiniteAndNonzero(
                jacobian,
                current.len,
                active_count,
                column,
            );
        }
        if (column_populated) {
            workspace.reaction_span_pivots[populated_columns] = column;
            populated_columns += 1;
        }
    }
    if (diagnostic) |entry|
        entry.full_network_populated_columns = populated_columns;
    if (populated_columns == 0) {
        compactReactionSpanColumns(
            workspace,
            current.len,
            active_count,
            0,
        );
        if (diagnostic) |entry|
            entry.full_network_status = .no_jacobian_columns;
        return false;
    }
    if (populated_columns < active_count) {
        compactReactionSpanColumns(
            workspace,
            current.len,
            active_count,
            populated_columns,
        );
        active_count = populated_columns;
    }
    if (!group_aliases.solveBoundedReactionSpan(workspace, current.len, active_count)) {
        if (diagnostic) |entry| {
            entry.full_network_status = .bounded_solve_failed;
            entry.full_network_rank = workspace.reaction_span_last_rank;
        }
        return false;
    }
    if (diagnostic) |entry|
        entry.full_network_rank = workspace.reaction_span_last_rank;
    var candidate_transformations =
        reaction_span.zeroTransformations(parameters);
    var has_nonzero_extent = false;
    for (
        workspace.reaction_span_solution[0..active_count],
        0..,
    ) |normalized_extent, column| {
        if (!std.math.isFinite(normalized_extent))
            return error.NonFiniteSoluteReactionExtent;
        if (normalized_extent == 0) continue;
        try reaction_span.addReactionExtent(
            &candidate_transformations,
            workspace.reaction_span_active_reactions[column],
            normalized_extent *
                workspace.reaction_span_extent_scales[column],
            current_transformations,
            parameters,
        );
        has_nonzero_extent = true;
    }
    if (!has_nonzero_extent) {
        if (diagnostic) |entry|
            entry.full_network_status = .zero_extent;
        return false;
    }

    const inventory_fraction = group_aliases.transformedVectorAdmissible(
        scratch,
        current,
        candidate_transformations,
        parameters,
        1,
        candidate_state,
    ) catch {
        if (diagnostic) |entry|
            entry.full_network_status = .inventory_projection_failed;
        return false;
    };
    if (diagnostic) |entry|
        entry.full_network_inventory_fraction = inventory_fraction;
    var touches_inventory_face = inventory_fraction < 1;
    if (!touches_inventory_face and options.maximum_newton_fraction == 1) {
        for (
            workspace.reaction_span_solution[0..active_count],
            workspace.reaction_span_original_lower_bounds[0..active_count],
            workspace.reaction_span_original_upper_bounds[0..active_count],
        ) |extent, lower, upper| {
            if ((lower < 0 and extent == lower) or
                (upper > 0 and extent == upper))
            {
                touches_inventory_face = true;
                break;
            }
        }
    }
    const component_count = comptime chemistry.State.packedComponentCount();
    var inventory_face_state: [component_count]f64 = undefined;
    if (touches_inventory_face)
        @memcpy(&inventory_face_state, candidate_state);
    const predicted_norm = group_aliases.reactionSpanPredictedNorm(
        workspace,
        current,
        global_residual,
        options,
        current_norm,
        active_count,
        inventory_fraction,
    );
    workspace.reaction_span_last_predicted_norm = predicted_norm;
    if (diagnostic) |entry|
        entry.full_network_predicted_maximum_scaled_residual =
            predicted_norm;
    // The line search rewrites `candidate_state` at every backtrack. Preserve
    // the original inventory-limited target only when a trace may need to
    // diagnose rejection; otherwise production retains zero copy overhead.
    const capture_rejected_direction = if (trace) |solver_trace|
        !solver_trace.full_network_comparison_valid
    else
        false;
    if (capture_rejected_direction)
        @memcpy(workspace.complementarity_candidate_state, candidate_state);
    // The nonsmooth maximum norm is diagnostic here, not a globalization
    // merit. A finite bounded Newton direction must reach exact RMS Armijo
    // pricing so it can cross an L-infinity ridge safely.
    var accepted_line_fraction: f64 = 0;
    const accepted = try group_acceptance.tryAcceptReactionExtentLineSearch(
        scratch,
        current,
        candidate_transformations,
        inventory_fraction,
        candidate_state,
        accepted_state,
        residual_work,
        parameters,
        options,
        global_residual,
        current_norm,
        &accepted_line_fraction,
    );
    if (!accepted) {
        if (trace) |solver_trace| {
            if (capture_rejected_direction) {
                group_aliases.captureFullNetworkDirectionalComparison(
                    solver_trace,
                    workspace,
                    scratch,
                    current,
                    global_residual,
                    workspace.complementarity_candidate_state,
                    accepted_state,
                    residual_work,
                    parameters,
                    options,
                    current_norm,
                    active_count,
                    inventory_fraction,
                    current_transformations,
                    coefficients.monovalent_activity_coefficient,
                    diagnostic,
                );
            }
        }
        if (touches_inventory_face and
            try tryInventoryBoundaryContinuationFromState(
                workspace,
                current,
                &inventory_face_state,
                accepted_state,
                residual_work,
                parameters,
                options,
                current_norm,
            ))
        {
            if (diagnostic) |entry|
                entry.full_network_status = .accepted;
            return true;
        }
        if (diagnostic) |entry|
            entry.full_network_status = .actual_merit_rejected;
        return false;
    }
    const accepted_norm =
        try group_aliases.scaledNorm(accepted_state, residual_work, options);
    // `accepted_line_fraction` is the absolute extent fraction applied by the
    // line search (it already includes inventory damping). Model agreement
    // must price that exact extent rather than damping it a second time.
    workspace.reaction_span_last_predicted_norm =
        group_aliases.reactionSpanPredictedNorm(
            workspace,
            current,
            global_residual,
            options,
            current_norm,
            active_count,
            accepted_line_fraction,
        );
    if (diagnostic) |entry|
        entry.full_network_status = .accepted;
    _ = accepted_norm;
    return true;
}

/// Fallback after every retained candidate has failed. Negative, zero, and
/// positive extent faces are solved together; zero uses a Clarke derivative.
/// The caller still accepts only a finite, admissible strict merit decrease.
pub fn tryRetainedComplementarityCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
    realized_sides_only: bool,
) !bool {
    diagnostic_control.recordStrategyCall(.retained_complementarity);
    var diagnostic_strategy_scope = diagnostic_control.enterStrategy(.retained_complementarity);
    defer diagnostic_strategy_scope.deinit();
    const column_count = workspace.reaction_span_active_count;
    if (column_count == 0) return false;
    try scratch.unpackCell(0, current);
    const coefficients =
        try scratch.activityCoefficients(0, parameters.fractions);
    return tryFullNetworkComplementarityCandidate(
        workspace,
        scratch,
        current,
        global_residual,
        current_transformations,
        candidate_state,
        accepted_state,
        residual_work,
        parameters,
        options,
        current_norm,
        coefficients.monovalent_activity_coefficient,
        column_count,
        realized_sides_only,
    );
}

pub fn tryFullNetworkComplementarityCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
    monovalent_activity_coefficient: f64,
    column_count: usize,
    realized_sides_only: bool,
) !bool {
    const row_count = current.len;
    const matrix_count = row_count * column_count;
    const selected_jacobian =
        workspace.reaction_span_jacobian[0..matrix_count];
    const negative_jacobian =
        workspace.reaction_span_negative_jacobian[0..matrix_count];
    const positive_jacobian =
        workspace.reaction_span_positive_jacobian[0..matrix_count];
    defer {
        @memcpy(
            workspace.reaction_span_lower_bounds[0..column_count],
            workspace.reaction_span_original_lower_bounds[0..column_count],
        );
        @memcpy(
            workspace.reaction_span_upper_bounds[0..column_count],
            workspace.reaction_span_original_upper_bounds[0..column_count],
        );
        for (0..column_count) |column| {
            const reaction =
                workspace.reaction_span_active_reactions[column];
            const branch = reactionRateBranch(
                workspace.reaction_span_rates[reaction],
            );
            for (0..row_count) |row| {
                const index = row * column_count + column;
                selected_jacobian[index] =
                    group_aliases.complementarityColumnDerivative(
                        branch,
                        negative_jacobian[index],
                        positive_jacobian[index],
                    );
            }
        }
    }

    const inputs = group_aliases.ComplementaritySearchInputs{
        .scratch = scratch,
        .current = current,
        .global_residual = global_residual,
        .probe_state = candidate_state,
        .probe_residual = residual_work,
        .current_transformations = current_transformations,
        .parameters = parameters,
        .options = options,
        .current_norm = current_norm,
        .monovalent_activity_coefficient = monovalent_activity_coefficient,
        .column_count = column_count,
    };
    // Primary publication uses only its current-rate half-axis. Restore the
    // separately retained physical box before probing complementarity so both
    // physically available one-sided Jacobians are actually evaluated. The
    // primary column remains the fallback only when a side is unavailable or
    // its transactional derivative probe fails.
    @memcpy(
        workspace.reaction_span_lower_bounds[0..column_count],
        workspace.reaction_span_original_lower_bounds[0..column_count],
    );
    @memcpy(
        workspace.reaction_span_upper_bounds[0..column_count],
        workspace.reaction_span_original_upper_bounds[0..column_count],
    );
    for (0..column_count) |column| {
        const reaction =
            workspace.reaction_span_active_reactions[column];
        const branch = reactionRateBranch(workspace.reaction_span_rates[reaction]);
        for (0..row_count) |row| {
            const value =
                selected_jacobian[row * column_count + column];
            negative_jacobian[row * column_count + column] = value;
            positive_jacobian[row * column_count + column] = value;
        }
        const available = physicalDerivativeSidesAvailable(
            workspace.reaction_span_original_lower_bounds[column],
            workspace.reaction_span_original_upper_bounds[column],
        );
        if (available.negative) {
            group_aliases.evaluateReactionSpanDerivativeColumn(
                inputs,
                workspace,
                column,
                -1,
                negative_jacobian,
            ) catch {};
        }
        if (available.positive) {
            group_aliases.evaluateReactionSpanDerivativeColumn(
                inputs,
                workspace,
                column,
                1,
                positive_jacobian,
            ) catch {};
        }
        for (0..row_count) |row| {
            const index = row * column_count + column;
            selected_jacobian[index] =
                group_aliases.complementarityColumnDerivative(
                    branch,
                    negative_jacobian[index],
                    positive_jacobian[index],
                );
        }
        workspace.reaction_span_branch_states[column] = branch;
    }
    // Discovery is deliberately unrestricted by the primary current-face
    // publication box. It may expose an opposite correction, but that vector
    // is never publishable: realized-side enumeration must rebuild it with
    // the opposite one-sided Jacobian and verify candidate-state rates.
    if (group_aliases.solveBoundedReactionSpan(
        workspace,
        row_count,
        column_count,
    )) {
        if (try tryRealizedSideComplementarityCandidate(
            workspace,
            scratch,
            current,
            current_transformations,
            candidate_state,
            accepted_state,
            residual_work,
            parameters,
            options,
            current_norm,
            negative_jacobian,
            positive_jacobian,
            selected_jacobian,
            column_count,
        )) return true;
    }
    if (realized_sides_only) return false;
    var branch_iteration: usize = 0;
    while (branch_iteration < 16 * column_count) : (branch_iteration += 1) {
        for (0..column_count) |column| {
            const branch =
                workspace.reaction_span_branch_states[column];
            const lower =
                workspace.reaction_span_original_lower_bounds[column];
            const upper =
                workspace.reaction_span_original_upper_bounds[column];
            workspace.reaction_span_lower_bounds[column] = switch (branch) {
                -1 => lower,
                0, 1 => @max(0, lower),
                else => unreachable,
            };
            workspace.reaction_span_upper_bounds[column] = switch (branch) {
                -1, 0 => @min(0, upper),
                1 => upper,
                else => unreachable,
            };
            for (0..row_count) |row| {
                const index = row * column_count + column;
                selected_jacobian[index] =
                    group_aliases.complementarityColumnDerivative(
                        branch,
                        negative_jacobian[index],
                        positive_jacobian[index],
                    );
            }
        }
        if (!group_aliases.solveProjectedReactionSpanLeastSquares(
            workspace,
            row_count,
            column_count,
        )) return false;

        for (0..row_count) |row| {
            var linear_residual =
                -workspace.reaction_span_rhs[row];
            for (
                workspace.reaction_span_solution[0..column_count],
                0..,
            ) |extent, column| {
                linear_residual +=
                    selected_jacobian[
                        row * column_count + column
                    ] * extent;
            }
            workspace.reaction_span_projected_rhs[row] =
                linear_residual;
        }
        const residual_norm = group_aliases.maximumMagnitude(
            workspace.reaction_span_projected_rhs[0..row_count],
        );
        var changed = false;
        for (
            workspace.reaction_span_solution[0..column_count],
            0..,
        ) |extent, column| {
            if (group_aliases.reactionSpanExtentIsSignificant(
                workspace,
                column,
                extent,
            )) {
                // Correction sign is not kinetic branch identity. The exact
                // transformed state and residual globalization below own
                // publication; a nonzero coordinate retains its chosen
                // correction-side derivative for this semismooth step.
                continue;
            }
            const gradients = correctionFaceNormalizedGradients(workspace, negative_jacobian, positive_jacobian, row_count, column_count, column, residual_norm);
            if (!std.math.isFinite(gradients.negative) or !std.math.isFinite(gradients.positive)) return false;
            const negative_available =
                workspace.reaction_span_original_lower_bounds[column] < 0;
            const positive_available =
                workspace.reaction_span_original_upper_bounds[column] > 0;
            const tolerance = @sqrt(std.math.floatEps(f64));
            const negative_violation =
                if (negative_available and gradients.negative > tolerance)
                    gradients.negative
                else
                    0;
            const positive_violation =
                if (positive_available and gradients.positive < -tolerance)
                    -gradients.positive
                else
                    0;
            const next_branch: i8 =
                if (negative_violation == 0 and
                positive_violation == 0)
                    0
                else if (negative_violation > positive_violation)
                    -1
                else
                    1;
            if (next_branch !=
                workspace.reaction_span_branch_states[column])
            {
                workspace.reaction_span_branch_states[column] =
                    next_branch;
                changed = true;
            }
        }
        if (changed) continue;

        var candidate_transformations =
            reaction_span.zeroTransformations(parameters);
        var has_nonzero_extent = false;
        for (
            workspace.reaction_span_solution[0..column_count],
            0..,
        ) |normalized_extent, column| {
            if (!std.math.isFinite(normalized_extent))
                return error.NonFiniteSoluteReactionExtent;
            if (normalized_extent == 0) continue;
            try reaction_span.addReactionExtent(
                &candidate_transformations,
                workspace.reaction_span_active_reactions[column],
                normalized_extent *
                    workspace.reaction_span_extent_scales[column],
                current_transformations,
                parameters,
            );
            has_nonzero_extent = true;
        }
        if (!has_nonzero_extent) return false;
        const inventory_fraction = group_aliases.transformedVectorAdmissible(
            scratch,
            current,
            candidate_transformations,
            parameters,
            1,
            candidate_state,
        ) catch return false;
        // Predicted L-infinity reduction is diagnostic only. The exact RMS
        // Armijo line search owns globalization and may safely cross a ridge
        // while its separate maximum-component safeguard remains satisfied.
        const step_fraction = inventory_fraction;
        _ = group_aliases.transformedVectorAdmissible(
            scratch,
            current,
            candidate_transformations,
            parameters,
            step_fraction,
            candidate_state,
        ) catch return false;
        var accepted_line_fraction: f64 = 0;
        const extent_accepted = try group_acceptance.tryAcceptReactionExtentLineSearch(
            scratch,
            current,
            candidate_transformations,
            step_fraction,
            candidate_state,
            accepted_state,
            residual_work,
            parameters,
            options,
            global_residual,
            current_norm,
            &accepted_line_fraction,
        );
        if (extent_accepted) {
            const accepted_norm = try group_aliases.scaledNorm(
                accepted_state,
                residual_work,
                options,
            );
            const current_merit = try group_acceptance.scaledRmsNorm(
                current,
                global_residual,
                options,
            );
            const accepted_merit = try group_acceptance.scaledRmsNorm(
                accepted_state,
                residual_work,
                options,
            );
            if (group_acceptance.newtonCandidateAcceptable(
                current_norm,
                current_merit,
                accepted_norm,
                accepted_merit,
            )) {
                return true;
            }
        }
        const exact_accepted = group_acceptance.tryAcceptExactReactionExtentCandidate(
            scratch,
            candidate_state,
            accepted_state,
            residual_work,
            parameters,
            options,
            current_norm,
        ) catch false;
        if (exact_accepted) {
            const accepted_norm = try group_aliases.scaledNorm(
                accepted_state,
                residual_work,
                options,
            );
            if (meaningfulNewtonMeritDecrease(
                current_norm,
                accepted_norm,
            )) {
                return true;
            }
        }
        const anderson_accepted = try group_acceptance.tryAcceptAndersonCandidate(
            scratch,
            current,
            candidate_state,
            accepted_state,
            residual_work,
            parameters,
            options,
            current_norm,
        );
        if (anderson_accepted) {
            const accepted_norm = try group_aliases.scaledNorm(
                accepted_state,
                residual_work,
                options,
            );
            if (meaningfulNewtonMeritDecrease(
                current_norm,
                accepted_norm,
            )) {
                return true;
            }
        }
        if (group_aliases.refineComplementarityDirectionalJacobian(
            workspace,
            inputs,
            candidate_transformations,
            negative_jacobian,
            positive_jacobian,
            selected_jacobian,
            candidate_state,
            residual_work,
        )) continue;
        return false;
    }
    return false;
}

/// Enumerate the small set of reaction faces whose first Newton correction
/// points across the current active side. A face is consistent only when the
/// reaction rate re-evaluated at the globally line-searched candidate has
/// that sign; the correction extent's sign alone does not prove a kinetic
/// branch crossing because extents are applied on top of the complete
/// current transformation ledger.
fn tryRealizedSideComplementarityCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    current_transformations: chemistry.CellTransformations,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
    negative_jacobian: []const f64,
    positive_jacobian: []const f64,
    selected_jacobian: []f64,
    column_count: usize,
) !bool {
    const maximum_enumerated_faces = 8;
    var ambiguous_columns: [maximum_enumerated_faces]usize = undefined;
    var ambiguous_base_branches: [maximum_enumerated_faces]i8 = undefined;
    var ambiguous_count: usize = 0;
    var has_zero_rate_face = false;
    for (
        workspace.reaction_span_solution[0..column_count],
        0..,
    ) |solution, column| {
        if (!group_aliases.reactionSpanExtentIsSignificant(
            workspace,
            column,
            solution,
        )) continue;
        const reaction = workspace.reaction_span_active_reactions[column];
        const rate = workspace.reaction_span_rates[reaction];
        const current_branch = reactionRateBranch(rate);
        if (current_branch != 0 and
            (solution < 0) == (current_branch < 0)) continue;
        if (ambiguous_count == maximum_enumerated_faces) return false;
        ambiguous_columns[ambiguous_count] = column;
        ambiguous_base_branches[ambiguous_count] = if (current_branch == 0)
            if (solution < 0) -1 else 1
        else
            current_branch;
        has_zero_rate_face = has_zero_rate_face or current_branch == 0;
        ambiguous_count += 1;
    }
    if (ambiguous_count == 0) return false;

    var best_norm = current_norm;
    const combination_count = @as(usize, 1) << @intCast(ambiguous_count);
    // Mask zero is already priced for ordinary current-side axes. A zero-rate
    // Clarke direction has not priced either realized one-sided branch, so it
    // must also rebuild and price its mask-zero side.
    const first_mask: usize = if (has_zero_rate_face) 0 else 1;
    for (first_mask..combination_count) |mask| {
        for (0..column_count) |column| {
            const reaction =
                workspace.reaction_span_active_reactions[column];
            var branch = reactionRateBranch(
                workspace.reaction_span_rates[reaction],
            );
            for (ambiguous_columns[0..ambiguous_count], 0..) |ambiguous, bit| {
                if (column != ambiguous) continue;
                branch = ambiguous_base_branches[bit];
                if (mask & (@as(usize, 1) << @intCast(bit)) != 0)
                    branch = -branch;
                break;
            }
            const bounds = complementarityFaceBounds(
                branch,
                workspace.reaction_span_original_lower_bounds[column],
                workspace.reaction_span_original_upper_bounds[column],
            );
            workspace.reaction_span_lower_bounds[column] = bounds.lower;
            workspace.reaction_span_upper_bounds[column] = bounds.upper;
            for (0..current.len) |row| {
                const index = row * column_count + column;
                selected_jacobian[index] =
                    group_aliases.complementarityColumnDerivative(
                        branch,
                        negative_jacobian[index],
                        positive_jacobian[index],
                    );
            }
        }
        if (!group_aliases.solveBoundedReactionSpan(
            workspace,
            current.len,
            column_count,
        )) continue;

        var transformations = reaction_span.zeroTransformations(parameters);
        var has_nonzero_extent = false;
        for (
            workspace.reaction_span_solution[0..column_count],
            0..,
        ) |normalized_extent, column| {
            if (!std.math.isFinite(normalized_extent))
                return error.NonFiniteSoluteReactionExtent;
            if (normalized_extent == 0) continue;
            try reaction_span.addReactionExtent(
                &transformations,
                workspace.reaction_span_active_reactions[column],
                normalized_extent *
                    workspace.reaction_span_extent_scales[column],
                current_transformations,
                parameters,
            );
            has_nonzero_extent = true;
        }
        if (!has_nonzero_extent) continue;
        _ = group_aliases.transformedVectorAdmissible(
            scratch,
            current,
            transformations,
            parameters,
            1,
            candidate_state,
        ) catch continue;
        if (!try group_acceptance.tryAcceptAndersonCandidate(
            scratch,
            current,
            candidate_state,
            workspace.complementarity_candidate_state,
            residual_work,
            parameters,
            options,
            current_norm,
        )) continue;
        const candidate_norm = try group_aliases.scaledNorm(
            workspace.complementarity_candidate_state,
            residual_work,
            options,
        );
        if (candidate_norm >= best_norm) continue;

        try reaction_span.evaluateRates(
            scratch,
            0,
            parameters,
            workspace.reaction_span_probe_residual,
        );
        var side_consistent = true;
        for (ambiguous_columns[0..ambiguous_count], 0..) |column, bit| {
            const reaction =
                workspace.reaction_span_active_reactions[column];
            const realized_rate =
                workspace.reaction_span_probe_residual[reaction];
            if (!std.math.isFinite(realized_rate))
                return error.NonFiniteSoluteReactionRate;
            if (realized_rate == 0) continue;
            var expected_branch = ambiguous_base_branches[bit];
            if (mask & (@as(usize, 1) << @intCast(bit)) != 0)
                expected_branch = -expected_branch;
            if ((realized_rate < 0) != (expected_branch < 0))
                side_consistent = false;
        }
        if (!side_consistent) continue;
        best_norm = candidate_norm;
        @memcpy(
            workspace.reaction_span_best_state,
            workspace.complementarity_candidate_state,
        );
        @memcpy(workspace.reaction_span_best_residual, residual_work);
        // Physical-acceptance stop: `candidate_norm <= 1` is the exact
        // convergence threshold `solveEquilibriumWithWorkspace`'s own main
        // loop uses to accept a state outright (see its `current_norm <= 1`
        // check). Once one of up to `combination_count` (<=256) sign
        // combinations already reaches that same bar, continuing to
        // enumerate the remaining combinations only to see whether a
        // marginally smaller norm exists is exactly the residual-chasing
        // this solver never does anywhere else -- it would be spending
        // hard-bounded nonlinear work to refine an already-accepted answer,
        // not to resolve genuine remaining ambiguity. A combination that has
        // NOT yet reached this bar still runs the full search unchanged, so
        // genuinely ambiguous/unresolved states are not affected.
        if (candidate_norm <= 1) break;
    }
    if (!meaningfulNewtonMeritDecrease(current_norm, best_norm)) return false;
    @memcpy(accepted_state, workspace.reaction_span_best_state);
    @memcpy(residual_work, workspace.reaction_span_best_residual);
    return true;
}

test "zero-rate magnesium exchange axis remains on the complementarity face" {
    const aqueous_network = @import("aqueous_network.zig");
    const phosphate_network = @import("phosphate_network.zig");
    const cation_exchange = @import("cation_exchange.zig");
    const geochemistry = @import("geochemistry_network.zig");
    const aqueous_rates = @import("aqueous_reaction_rates.zig");
    const geochemistry_rates = @import("geochemistry_reaction_rates.zig");

    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = reaction_solver_numerics2.filled(
        aqueous_network.State,
        1,
    );
    state.aqueous[0].magnesium = 0;
    state.non_band_phosphate[0] = std.mem.zeroes(phosphate_network.State);
    state.band_phosphate[0] = std.mem.zeroes(phosphate_network.State);
    state.cation_exchange_mol_per_megagram[0] =
        std.mem.zeroes(cation_exchange.Cations);
    state.cation_exchange_mol_per_megagram[0].calcium = 4;
    state.cation_exchange_mol_per_megagram[0].magnesium = 1;
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 0;
    state.geochemistry_solids[0] = std.mem.zeroes(geochemistry.SolidState);
    state.water_mol_per_m3[0] = 100;

    var parameters = std.mem.zeroes(chemistry.ReactionParameters);
    parameters.fractions = .{
        .ammonium_non_band = 0.8,
        .ammonium_band = 0.2,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
        .phosphate_non_band = 0,
        .phosphate_band = 0,
    };
    parameters.cation_exchange_capacity_mol_charge_per_megagram = 10;
    parameters.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = 1,
        .ammonium_non_band_megagrams_per_m3 = 0,
        .ammonium_band_megagrams_per_m3 = 0,
    };
    parameters.aqueous_constants = reaction_solver_numerics2.filled(
        aqueous_rates.EquilibriumConstants,
        1,
    );
    parameters.phosphate_minerals = null;
    parameters.cation_exchange_parameters = .{
        .selectivity = reaction_solver_numerics2.filled(
            cation_exchange.Selectivity,
            1,
        ),
        .substrate_limit_fraction = 0.2,
        .maximum_adsorption_mol_charge_per_m3_step = 0.1,
    };
    parameters.geochemistry_products = reaction_solver_numerics2.filled(
        geochemistry_rates.SolubilityProducts,
        1,
    );
    parameters.geochemistry_kinetics
        .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1;
    parameters.water_activity_product_mol2_per_m6 = 1;
    parameters.negligible_water_ion_concentration_mol_per_m3 = 1e-32;

    const count = comptime chemistry.State.packedComponentCount();
    var current: [count]f64 = undefined;
    try state.packCell(0, &current);
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    try scratch.unpackCell(0, &current);
    const coefficients = try scratch.activityCoefficients(
        0,
        parameters.fractions,
    );
    var workspace = try group_aliases.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    try reaction_span.evaluateRates(
        &scratch,
        0,
        parameters,
        workspace.reaction_span_rates,
    );
    const magnesium_reaction = reaction_span.gapon_reaction_offset + 5;
    try std.testing.expectEqual(
        @as(f64, 0),
        workspace.reaction_span_rates[magnesium_reaction],
    );
    var candidate: [count]f64 = undefined;
    const active_count = try initializeFullNetworkReactionAxes(
        &workspace,
        &scratch,
        &current,
        reaction_span.zeroTransformations(parameters),
        &candidate,
        parameters,
        .{},
        coefficients.monovalent_activity_coefficient,
    );
    var magnesium_column: ?usize = null;
    for (workspace.reaction_span_active_reactions[0..active_count], 0..) |reaction, column| {
        if (reaction == magnesium_reaction) magnesium_column = column;
    }
    const column = magnesium_column orelse
        return error.MissingZeroRateMagnesiumComplementarityAxis;
    try std.testing.expectEqual(@as(i8, 0), workspace.reaction_span_branch_states[column]);
    try std.testing.expectEqual(@as(f64, 0), workspace.reaction_span_lower_bounds[column]);
    try std.testing.expectEqual(@as(f64, 0), workspace.reaction_span_upper_bounds[column]);
    try std.testing.expect(
        workspace.reaction_span_original_lower_bounds[column] < 0 or
            workspace.reaction_span_original_upper_bounds[column] > 0,
    );
}

test "reaction-span compaction removes derivative-empty axes and preserves metadata" {
    var workspace = try group_aliases.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const old_count: usize = 3;
    const kept_count: usize = 2;
    const row_count: usize = 2;
    workspace.reaction_span_active_reactions[0] = 10;
    workspace.reaction_span_active_reactions[1] = 11;
    workspace.reaction_span_active_reactions[2] = 12;
    workspace.reaction_span_extent_scales[0] = 1;
    workspace.reaction_span_extent_scales[1] = 2;
    workspace.reaction_span_extent_scales[2] = 3;
    workspace.reaction_span_branch_states[0] = -1;
    workspace.reaction_span_branch_states[1] = 1;
    workspace.reaction_span_branch_states[2] = 0;
    workspace.reaction_span_lower_bounds[0] = -1;
    workspace.reaction_span_lower_bounds[1] = -2;
    workspace.reaction_span_lower_bounds[2] = 0;
    workspace.reaction_span_upper_bounds[0] = 0;
    workspace.reaction_span_upper_bounds[1] = 2;
    workspace.reaction_span_upper_bounds[2] = 0;
    @memcpy(
        workspace.reaction_span_original_lower_bounds[0..old_count],
        workspace.reaction_span_lower_bounds[0..old_count],
    );
    @memcpy(
        workspace.reaction_span_original_upper_bounds[0..old_count],
        workspace.reaction_span_upper_bounds[0..old_count],
    );
    @memcpy(
        workspace.reaction_span_jacobian[0 .. row_count * old_count],
        &[_]f64{ 10, 11, 12, 20, 21, 22 },
    );
    workspace.reaction_span_pivots[0] = 0;
    workspace.reaction_span_pivots[1] = 2;

    compactReactionSpanColumns(
        &workspace,
        row_count,
        old_count,
        kept_count,
    );
    try std.testing.expectEqual(@as(usize, 2), workspace.reaction_span_active_count);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 10, 12 },
        workspace.reaction_span_active_reactions[0..kept_count],
    );
    try std.testing.expectEqualSlices(
        i8,
        &.{ -1, 0 },
        workspace.reaction_span_branch_states[0..kept_count],
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 10, 12, 20, 22 },
        workspace.reaction_span_jacobian[0 .. row_count * kept_count],
    );
}

test "captured five-face topology deterministically represents three pinned corrections" {
    try std.testing.expectEqual(
        @as(usize, 243),
        ternaryCorrectionPatternCount(5),
    );
    // Captured source order: bicarbonate uses +, AlPO4/HAp/protonated-site
    // remain on the kink, and HPO4 surface exchange uses -.
    const captured_pattern: usize = 41;
    const expected = [_]CorrectionFace{
        .positive,
        .pinned_zero,
        .pinned_zero,
        .pinned_zero,
        .negative,
    };
    var pinned_count: usize = 0;
    for (expected, 0..) |face, face_index| {
        try std.testing.expectEqual(
            face,
            ternaryCorrectionFace(captured_pattern, face_index),
        );
        if (face == .pinned_zero) pinned_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), pinned_count);
    try std.testing.expect(patternHasPinnedCorrectionFace(captured_pattern, 5));
    try std.testing.expect(!patternHasPinnedCorrectionFace(0, 5));
}

test "eight-face ternary topology exhaustively covers its bounded pattern space" {
    const pattern_count = ternaryCorrectionPatternCount(8);
    try std.testing.expectEqual(@as(usize, 6561), pattern_count);
    var seen = [_]bool{false} ** 6561;
    var pinned_pattern_count: usize = 0;
    for (0..pattern_count) |pattern| {
        var encoded: usize = 0;
        var place: usize = 1;
        for (0..8) |face_index| {
            encoded += @intFromEnum(
                ternaryCorrectionFace(pattern, face_index),
            ) * place;
            place *= 3;
        }
        try std.testing.expectEqual(pattern, encoded);
        try std.testing.expect(!seen[encoded]);
        seen[encoded] = true;
        if (patternHasPinnedCorrectionFace(pattern, 8))
            pinned_pattern_count += 1;
    }
    for (seen) |visited| try std.testing.expect(visited);
    try std.testing.expectEqual(@as(usize, 6561 - 256), pinned_pattern_count);
}

test "pinned correction face requires both one-sided KKT inequalities" {
    try std.testing.expect(pinnedZeroCorrectionFaceKktSatisfied(
        -0.25,
        0.5,
        1,
    ));
    try std.testing.expect(!pinnedZeroCorrectionFaceKktSatisfied(
        0.25,
        0.5,
        1,
    ));
    try std.testing.expect(!pinnedZeroCorrectionFaceKktSatisfied(
        -0.25,
        -0.5,
        1,
    ));
    try std.testing.expect(!pinnedZeroCorrectionFaceKktSatisfied(
        std.math.nan(f64),
        0.5,
        1,
    ));
}

test "implicit zero-rate pin is promoted and cannot bypass two-sided KKT" {
    var workspace = try group_aliases.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const row_count: usize = 2;
    const column_count: usize = 2;
    const selected = workspace.reaction_span_jacobian[0 .. row_count * column_count];
    const negative = workspace.reaction_span_negative_jacobian[0 .. row_count * column_count];
    const positive = workspace.reaction_span_positive_jacobian[0 .. row_count * column_count];
    @memcpy(selected, &[_]f64{ 1, 0, 0, 0 });
    @memcpy(negative, &[_]f64{ 1, 1, 0, 0 });
    @memcpy(positive, &[_]f64{ 1, -1, 0, 0 });
    @memcpy(workspace.reaction_span_rhs[0..row_count], &[_]f64{ 0, 0 });
    @memcpy(workspace.reaction_span_solution[0..column_count], &[_]f64{ 1, 0 });
    @memcpy(
        workspace.reaction_span_lower_bounds[0..column_count],
        &[_]f64{ 0, 0 },
    );
    @memcpy(
        workspace.reaction_span_upper_bounds[0..column_count],
        &[_]f64{ 2, 0 },
    );
    const base_faces = [_]i8{ 1, 0 };
    var ambiguous_columns: [maximum_ternary_correction_faces]usize = undefined;
    ambiguous_columns[0] = 0;
    var ambiguous_count: usize = 1;

    try std.testing.expectEqual(
        BasePinPromotionStatus.complete,
        appendUncertifiedBasePins(
            &workspace,
            negative,
            positive,
            selected,
            row_count,
            column_count,
            &base_faces,
            &ambiguous_columns,
            &ambiguous_count,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), ambiguous_count);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 1 },
        ambiguous_columns[0..ambiguous_count],
    );
    try std.testing.expect(!pinnedCorrectionFacesKktSatisfied(
        &workspace,
        negative,
        positive,
        selected,
        row_count,
        column_count,
    ));

    negative[1] = -1;
    positive[1] = 1;
    ambiguous_count = 1;
    try std.testing.expectEqual(
        BasePinPromotionStatus.complete,
        appendUncertifiedBasePins(
            &workspace,
            negative,
            positive,
            selected,
            row_count,
            column_count,
            &base_faces,
            &ambiguous_columns,
            &ambiguous_count,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), ambiguous_count);
    try std.testing.expect(pinnedCorrectionFacesKktSatisfied(
        &workspace,
        negative,
        positive,
        selected,
        row_count,
        column_count,
    ));
}

test "implicit pin promotion accepts eight axes and reports complete overflow" {
    var workspace = try group_aliases.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const row_count: usize = 1;
    const column_count: usize = 9;
    const selected =
        workspace.reaction_span_jacobian[0 .. row_count * column_count];
    const negative =
        workspace.reaction_span_negative_jacobian[0 .. row_count * column_count];
    const positive =
        workspace.reaction_span_positive_jacobian[0 .. row_count * column_count];
    @memset(selected, 0);
    @memset(negative, -1);
    @memset(positive, 1);
    @memset(workspace.reaction_span_solution[0..column_count], 0);
    workspace.reaction_span_rhs[0] = 1;
    const base_faces = [_]i8{0} ** column_count;
    var ambiguous_columns: [maximum_ternary_correction_faces]usize = undefined;
    var ambiguous_count: usize = 0;

    try std.testing.expectEqual(
        BasePinPromotionStatus.complete,
        appendUncertifiedBasePins(
            &workspace,
            negative[0..maximum_ternary_correction_faces],
            positive[0..maximum_ternary_correction_faces],
            selected[0..maximum_ternary_correction_faces],
            row_count,
            maximum_ternary_correction_faces,
            base_faces[0..maximum_ternary_correction_faces],
            &ambiguous_columns,
            &ambiguous_count,
            null,
        ),
    );
    try std.testing.expectEqual(
        maximum_ternary_correction_faces,
        ambiguous_count,
    );
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 1, 2, 3, 4, 5, 6, 7 },
        ambiguous_columns[0..ambiguous_count],
    );

    ambiguous_count = 0;
    try std.testing.expectEqual(
        BasePinPromotionStatus.too_many,
        appendUncertifiedBasePins(
            &workspace,
            negative,
            positive,
            selected,
            row_count,
            column_count,
            &base_faces,
            &ambiguous_columns,
            &ambiguous_count,
            null,
        ),
    );
    try std.testing.expectEqual(
        column_count,
        ambiguous_count,
    );
}

test "ternary ambiguous diagnostic capture is stable and fixed capacity" {
    var workspace = try group_aliases.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var diagnostic: group_aliases.IterationDiagnostic = .{
        .closure_index = 0,
        .iteration = 0,
        .limiting_component_index = 0,
        .limiting_state_value = 0,
        .limiting_residual = 0,
        .current_maximum_scaled_residual = 1,
    };
    const capacity = diagnostic.ternary_correction_axis_diagnostics.len;
    for (0..capacity + 2) |diagnostic_index| {
        const column = capacity + 1 - diagnostic_index;
        workspace.reaction_span_active_reactions[column] = column;
        workspace.reaction_span_rates[column] =
            if (diagnostic_index % 2 == 0) -1 else 1;
        workspace.reaction_span_lower_bounds[column] = -2;
        workspace.reaction_span_upper_bounds[column] = 2;
        captureTernaryAmbiguousAxisDiagnostic(
            &diagnostic,
            &workspace,
            column,
            @floatFromInt(diagnostic_index + 1),
            1,
            if (diagnostic_index % 2 == 0)
                .sign_mismatch
            else
                .failed_implicit_pin_kkt,
            @floatFromInt(diagnostic_index),
        );
    }
    try std.testing.expectEqual(
        capacity,
        diagnostic.ternary_correction_axis_diagnostic_count,
    );
    for (
        diagnostic.ternary_correction_axis_diagnostics[0..capacity],
        0..,
    ) |axis, diagnostic_index| {
        try std.testing.expectEqual(
            capacity + 1 - diagnostic_index,
            axis.compact_column,
        );
        try std.testing.expectEqual(
            axis.compact_column,
            axis.reaction_index,
        );
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(diagnostic_index + 1)),
            axis.discovery_extent,
        );
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(diagnostic_index)),
            axis.normalized_pinned_kkt_violation,
        );
    }
}

test "ternary rank policy is scoped around KKT-certified deficient spans" {
    var workspace = try group_aliases.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const row_count: usize = 3;
    const column_count: usize = 3;
    @memcpy(
        workspace.reaction_span_jacobian[0 .. row_count * column_count],
        &[_]f64{
            1, 0, 1,
            0, 1, 1,
            0, 0, 0,
        },
    );
    @memcpy(workspace.reaction_span_rhs[0..row_count], &[_]f64{ 2, 2, 0 });
    @memcpy(
        workspace.reaction_span_lower_bounds[0..column_count],
        &[_]f64{ 0, 0, 0 },
    );
    @memcpy(
        workspace.reaction_span_upper_bounds[0..column_count],
        &[_]f64{ 1, 1, 0.5 },
    );

    workspace.reaction_span_allow_truncated_qr = false;
    try std.testing.expect(solveTernaryBoundedReactionSpan(
        &workspace,
        row_count,
        column_count,
    ));
    try std.testing.expect(!workspace.reaction_span_allow_truncated_qr);
    try std.testing.expect(workspace.reaction_span_last_rank < column_count);
    try std.testing.expect(__parent.reactionSpanProjectedKktSatisfied(
        &workspace,
        row_count,
        column_count,
    ));

    @memset(workspace.reaction_span_solution[0..column_count], 0);
    workspace.reaction_span_used_truncated_qr = true;
    try std.testing.expect(!ternaryRankRepresentativeCertified(
        &workspace,
        row_count,
        column_count,
    ));
    try std.testing.expect(!__parent.reactionSpanProjectedKktSatisfied(
        &workspace,
        row_count,
        column_count,
    ));

    workspace.reaction_span_allow_truncated_qr = true;
    workspace.reaction_span_jacobian[0] = std.math.nan(f64);
    try std.testing.expect(!solveTernaryBoundedReactionSpan(
        &workspace,
        row_count,
        column_count,
    ));
    try std.testing.expect(workspace.reaction_span_allow_truncated_qr);
}

test "rank-revealing discovery remains deterministic within six-axis capacity" {
    var workspace = try group_aliases.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const row_count: usize = 6;
    const column_count: usize = 6;
    @memcpy(
        workspace.reaction_span_jacobian[0 .. row_count * column_count],
        &[_]f64{
            1, 0, 0, 0, 0, 0.5,
            0, 1, 0, 0, 0, 0,
            0, 0, 1, 0, 0, 0,
            0, 0, 0, 1, 0, 0,
            0, 0, 0, 0, 1, 0,
            0, 0, 0, 0, 0, 0,
        },
    );
    @memcpy(
        workspace.reaction_span_rhs[0..row_count],
        &[_]f64{ 1, -1, 1, -1, 1, 0 },
    );
    @memset(workspace.reaction_span_lower_bounds[0..column_count], -2);
    @memset(workspace.reaction_span_upper_bounds[0..column_count], 2);

    try std.testing.expect(buildTernaryDiscoveryRepresentative(
        &workspace,
        row_count,
        column_count,
    ));
    try std.testing.expectEqual(
        @as(usize, 5),
        workspace.reaction_span_last_rank,
    );
    const first = workspace.reaction_span_solution[0..column_count];
    var first_bits: [column_count]u64 = undefined;
    for (first, &first_bits) |extent, *bits| {
        try std.testing.expect(extent >= -2 and extent <= 2);
        bits.* = @bitCast(extent);
    }
    const current_branches = [_]i8{ -1, 1, -1, 1, -1, 0 };
    var ambiguous_count: usize = 0;
    for (first, current_branches) |extent, current_branch| {
        const branch: i8 = if (extent < 0) -1 else if (extent > 0) 1 else 0;
        if (branch != current_branch and branch != 0)
            ambiguous_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), ambiguous_count);
    try std.testing.expect(ambiguous_count <= maximum_ternary_correction_faces);

    try std.testing.expect(buildTernaryDiscoveryRepresentative(
        &workspace,
        row_count,
        column_count,
    ));
    for (workspace.reaction_span_solution[0..column_count], first_bits) |
        extent,
        bits,
    | try std.testing.expectEqual(bits, @as(u64, @bitCast(extent)));
}
