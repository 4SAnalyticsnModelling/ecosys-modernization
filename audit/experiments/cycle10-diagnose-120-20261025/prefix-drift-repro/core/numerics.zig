const std = @import("std");
const builtin = @import("builtin");

/// In-place partial-pivot Gaussian solve for small runtime Newton systems.
/// False indicates a singular or non-finite Jacobian so callers can enter
/// Anderson-accelerated recovery without updating a candidate.
pub fn solveDenseLinearSystem(matrix: []f64, right_hand_side: []f64, dimension: usize) bool {
    if (dimension == 0 or matrix.len != dimension * dimension or right_hand_side.len != dimension) return false;
    // Row equilibration makes the pivot test dimensionless and preserves weak
    // but valid coordinates in stiff systems (for example diagonal scales
    // 1e24 and 1). A single global absolute pivot floor incorrectly declares
    // the latter singular.
    for (0..dimension) |row| {
        var row_scale: f64 = 0;
        for (0..dimension) |column| {
            const value = matrix[row * dimension + column];
            if (!std.math.isFinite(value)) return false;
            row_scale = @max(row_scale, @abs(value));
        }
        if (row_scale == 0) return false;
        for (0..dimension) |column| matrix[row * dimension + column] /= row_scale;
        right_hand_side[row] /= row_scale;
        if (!std.math.isFinite(right_hand_side[row])) return false;
    }
    const pivot_floor = 8.0 * std.math.floatEps(f64) * @as(f64, @floatFromInt(dimension));
    for (0..dimension) |pivot_column| {
        var pivot_row = pivot_column;
        var pivot_magnitude = @abs(matrix[pivot_column * dimension + pivot_column]);
        for (pivot_column + 1..dimension) |row| {
            const magnitude = @abs(matrix[row * dimension + pivot_column]);
            if (magnitude > pivot_magnitude) {
                pivot_magnitude = magnitude;
                pivot_row = row;
            }
        }
        if (!std.math.isFinite(pivot_magnitude) or pivot_magnitude <= pivot_floor) return false;
        if (pivot_row != pivot_column) {
            for (0..dimension) |column| std.mem.swap(f64, &matrix[pivot_column * dimension + column], &matrix[pivot_row * dimension + column]);
            std.mem.swap(f64, &right_hand_side[pivot_column], &right_hand_side[pivot_row]);
        }
        const pivot = matrix[pivot_column * dimension + pivot_column];
        for (pivot_column + 1..dimension) |row| {
            const factor = matrix[row * dimension + pivot_column] / pivot;
            if (!std.math.isFinite(factor)) return false;
            matrix[row * dimension + pivot_column] = 0;
            if (factor == 0) continue;
            for (pivot_column + 1..dimension) |column| matrix[row * dimension + column] -= factor * matrix[pivot_column * dimension + column];
            right_hand_side[row] -= factor * right_hand_side[pivot_column];
        }
    }
    var row = dimension;
    while (row > 0) {
        row -= 1;
        var value = right_hand_side[row];
        for (row + 1..dimension) |column| value -= matrix[row * dimension + column] * right_hand_side[column];
        const diagonal = matrix[row * dimension + row];
        if (!std.math.isFinite(value) or !std.math.isFinite(diagonal) or @abs(diagonal) <= pivot_floor) return false;
        right_hand_side[row] = value / diagonal;
        if (!std.math.isFinite(right_hand_side[row])) return false;
    }
    return true;
}

/// Forms a depth-1 Anderson/secant candidate from two fixed-point defects.
/// `seed` is the evaluated (but never accepted) relaxed Picard image of
/// `current`. Returning false means acceleration is singular/non-finite; the
/// caller must report recovery failure rather than commit `seed` as vanilla
/// Picard. Bounds, conservation projections and merit acceptance remain the
/// process solver's responsibility.
pub fn andersonDepthOneCandidate(
    current: []const f64,
    current_defect: []const f64,
    seed: []const f64,
    seed_defect: []const f64,
    output: []f64,
) bool {
    if (current.len == 0 or current_defect.len != current.len or seed.len != current.len or seed_defect.len != current.len or output.len != current.len) return false;
    var largest_change: f64 = 0;
    for (current_defect, seed_defect) |before, after| {
        if (!std.math.isFinite(before) or !std.math.isFinite(after)) return false;
        largest_change = @max(largest_change, @abs(after - before));
    }
    if (largest_change == 0 or !std.math.isFinite(largest_change)) return false;
    var numerator: f64 = 0;
    var denominator: f64 = 0;
    for (current_defect, seed_defect) |before, after| {
        const normalized_change = (after - before) / largest_change;
        numerator += normalized_change * (after / largest_change);
        denominator += normalized_change * normalized_change;
    }
    if (!std.math.isFinite(numerator) or !std.math.isFinite(denominator) or denominator <= std.math.floatEps(f64)) return false;
    const mixing = numerator / denominator;
    if (!std.math.isFinite(mixing)) return false;
    for (output, seed, current) |*value, seeded, initial| {
        value.* = seeded - mixing * (seeded - initial);
        if (!std.math.isFinite(value.*)) return false;
    }
    return true;
}

/// Upper bound on Anderson mixing depth (`points.len - 1`) accepted by
/// `andersonDepthMCandidate`. Keeps the small least-squares mixing system's
/// stack storage fixed-size regardless of the (runtime, potentially large)
/// state dimension.
pub const anderson_max_depth: usize = 5;

/// Forms a depth-`points.len - 1` Anderson/least-squares extrapolate from
/// `points.len` fixed-point iterates and their defects (2 <=
/// `points.len` <= `anderson_max_depth + 1`). `points[points.len - 1]` /
/// `defects[points.len - 1]` is the newest, never-accepted evaluated Picard
/// seed; the remaining entries are older accepted history, in any order.
/// Minimizes the least-squares norm of a defect combination constrained to
/// mix to the seed, then applies that same mixing to the corresponding
/// state vectors -- the direct multi-point generalization of
/// `andersonDepthOneCandidate`, which this function is proven (see the
/// "depth-1 case exactly reproduces" test below) to reduce to bit-for-bit
/// when `points.len == 2`. Returns false if the small mixing system is
/// singular/non-finite, if any input is non-finite, or if `points.len` is
/// outside its valid range; the caller must report recovery failure rather
/// than commit any point as vanilla Picard. No allocation: the mixing
/// system is solved from Gram-matrix/right-hand-side accumulators sized by
/// `anderson_max_depth`, never by the (unbounded) state dimension.
pub fn andersonDepthMCandidate(
    points: []const []const f64,
    defects: []const []const f64,
    output: []f64,
) bool {
    const total = points.len;
    if (total < 2 or total > anderson_max_depth + 1) return false;
    if (defects.len != total) return false;
    const seed_index = total - 1;
    const seed = points[seed_index];
    const seed_defect = defects[seed_index];
    const dimension = seed.len;
    if (dimension == 0 or seed_defect.len != dimension or output.len != dimension) return false;
    for (points, defects) |point, defect| {
        if (point.len != dimension or defect.len != dimension) return false;
    }
    const history_count = seed_index; // number of older points, i.e. `m`.

    var largest_change: f64 = 0;
    for (0..history_count) |i| {
        for (defects[i], seed_defect) |before, after| {
            if (!std.math.isFinite(before) or !std.math.isFinite(after)) return false;
            largest_change = @max(largest_change, @abs(after - before));
        }
    }
    if (largest_change == 0 or !std.math.isFinite(largest_change)) return false;

    var gram: [anderson_max_depth * anderson_max_depth]f64 = undefined;
    var mixing: [anderson_max_depth]f64 = undefined;
    for (0..history_count) |i| {
        for (0..history_count) |j| {
            var accumulated: f64 = 0;
            for (defects[i], defects[j], seed_defect) |value_i, value_j, value_seed| {
                const delta_i = (value_i - value_seed) / largest_change;
                const delta_j = (value_j - value_seed) / largest_change;
                accumulated += delta_i * delta_j;
            }
            gram[i * history_count + j] = accumulated;
        }
        var accumulated_rhs: f64 = 0;
        for (defects[i], seed_defect) |value_i, value_seed| {
            const delta_i = (value_i - value_seed) / largest_change;
            accumulated_rhs -= delta_i * (value_seed / largest_change);
        }
        mixing[i] = accumulated_rhs;
    }
    if (!solveDenseLinearSystem(gram[0 .. history_count * history_count], mixing[0..history_count], history_count))
        return false;
    for (mixing[0..history_count]) |coefficient| if (!std.math.isFinite(coefficient)) return false;

    @memcpy(output, seed);
    for (0..history_count) |i| {
        const coefficient = mixing[i];
        for (output, points[i], seed) |*value, older, seeded| value.* += coefficient * (older - seeded);
    }
    for (output) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

test "Anderson depth-m reduces exactly to depth-1 at the two-point case" {
    // Constructed so the depth-1 secant is well-conditioned: current and
    // seed are distinct points with non-parallel, non-degenerate defects.
    const current = [_]f64{ 1.0, 2.0, 3.0 };
    const current_defect = [_]f64{ 4.0, -1.0, 0.5 };
    const seed = [_]f64{ 1.5, 1.7, 3.4 };
    const seed_defect = [_]f64{ 2.0, -0.5, 0.2 };
    var reference: [3]f64 = undefined;
    try std.testing.expect(andersonDepthOneCandidate(&current, &current_defect, &seed, &seed_defect, &reference));

    var general: [3]f64 = undefined;
    const points = [_][]const f64{ &current, &seed };
    const defects = [_][]const f64{ &current_defect, &seed_defect };
    try std.testing.expect(andersonDepthMCandidate(&points, &defects, &general));

    for (reference, general) |expected, actual|
        try std.testing.expectApproxEqAbs(expected, actual, 1.0e-12);
}

test "Anderson depth-m finds a better extrapolate than depth-1 for curved defects" {
    // Coordinate 0 is a quadratic defect d(x) = (x-3)^2 - 1, root at x=2,
    // sampled at x = 0, 1, 1.5, 1.9 (seed) -> defects 8, 3, 1.25, 0.61.
    // Coordinates 1-2 carry independent, non-collinear values (not derived
    // from any real map) solely so the 3-point history's Gram matrix has
    // full rank -- depth-m mixing is mathematically underdetermined with
    // fewer state dimensions than history points, so a real 3-point fit
    // needs at least 3 independent coordinates to be well-posed.
    const State = struct { x: [3]f64, d: [3]f64 };
    const samples = [_]State{
        .{ .x = .{ 0.0, 0.0, 0.0 }, .d = .{ 8.0, 2.0, -1.0 } },
        .{ .x = .{ 1.0, 1.0, 0.0 }, .d = .{ 3.0, -1.0, 0.5 } },
        .{ .x = .{ 1.5, 0.0, 1.0 }, .d = .{ 1.25, 0.5, -2.0 } },
        .{ .x = .{ 1.9, 0.5, 0.5 }, .d = .{ 0.6099999999999999, 0.1, 1.0 } },
    };
    const seed_d = samples[3].d[0];

    // Depth-1: only the two most recent points (index 2 -> 3).
    var depth1: [3]f64 = undefined;
    try std.testing.expect(andersonDepthOneCandidate(&samples[2].x, &samples[2].d, &samples[3].x, &samples[3].d, &depth1));
    const depth1_residual = @abs((depth1[0] - 3.0) * (depth1[0] - 3.0) - 1.0);

    // Depth-3: all four points.
    var depth3: [3]f64 = undefined;
    const points = [_][]const f64{ &samples[0].x, &samples[1].x, &samples[2].x, &samples[3].x };
    const defects = [_][]const f64{ &samples[0].d, &samples[1].d, &samples[2].d, &samples[3].d };
    try std.testing.expect(andersonDepthMCandidate(&points, &defects, &depth3));
    const depth3_residual = @abs((depth3[0] - 3.0) * (depth3[0] - 3.0) - 1.0);

    // Both should move toward the root (x=2) from the seed (x=1.9), but the
    // richer depth-3 fit against the true curvature on coordinate 0 should
    // land measurably closer to the actual root than the depth-1 affine
    // secant does.
    try std.testing.expect(@abs(seed_d) > depth1_residual);
    try std.testing.expect(depth1_residual > depth3_residual);
}

test "Anderson depth-m rejects a singular (duplicate-point) system" {
    const a = [_]f64{ 1.0, 2.0 };
    const b = [_]f64{ 1.0, 2.0 }; // identical to `a` -> zero Gram row.
    const seed = [_]f64{ 1.5, 1.7 };
    const seed_defect = [_]f64{ 0.4, -0.2 };
    var output: [2]f64 = undefined;
    const points = [_][]const f64{ &a, &b, &seed };
    const defects = [_][]const f64{ &[_]f64{ 4.0, -1.0 }, &[_]f64{ 4.0, -1.0 }, &seed_defect };
    try std.testing.expect(!andersonDepthMCandidate(&points, &defects, &output));
}

test "Anderson depth-m rejects out-of-range depth" {
    const only = [_]f64{1.0};
    const only_defect = [_]f64{1.0};
    var output: [1]f64 = undefined;
    const points = [_][]const f64{&only};
    const defects = [_][]const f64{&only_defect};
    try std.testing.expect(!andersonDepthMCandidate(&points, &defects, &output));
}

/// Acceptance merit for an Anderson proposal. The relaxed Picard image used
/// to construct the secant is private history, not a publishable incumbent;
/// only the currently accepted iterate may set this threshold.
pub fn andersonImprovesAcceptedMerit(candidate_merit: f64, current_merit: f64) bool {
    return std.math.isFinite(candidate_merit) and
        std.math.isFinite(current_merit) and
        candidate_merit < current_merit;
}

test "Anderson merit ignores an unpublishable relaxed seed" {
    const current_merit: f64 = 1;
    const private_seed_merit: f64 = 0.25;
    const candidate_merit: f64 = 0.5;
    try std.testing.expect(candidate_merit > private_seed_merit);
    try std.testing.expect(andersonImprovesAcceptedMerit(candidate_merit, current_merit));
    try std.testing.expect(!andersonImprovesAcceptedMerit(current_merit, current_merit));
    try std.testing.expect(!andersonImprovesAcceptedMerit(std.math.nan(f64), current_merit));
}

/// Shared hard ceiling for nonlinear method iterations. Each non-converged
/// Newton/Anderson iteration consumes one slot before attempting a direction.
/// Residual, Jacobian, finite-difference, and line-search probes inside that
/// iteration do not consume additional slots. Coupled solvers pass one pointer
/// through every nested solve so copying `max_iterations` cannot multiply the
/// user's ceiling.
pub const NonlinearBudget = struct {
    limit: u16,
    attempted_iterations: u16 = 0,

    pub fn init(limit: u16) !NonlinearBudget {
        if (limit == 0) return error.ZeroNonlinearIterationLimit;
        return .{ .limit = limit };
    }

    pub fn validate(self: *const NonlinearBudget) !void {
        if (self.limit == 0 or self.attempted_iterations > self.limit)
            return error.InvalidNonlinearBudget;
    }

    pub fn remaining(self: *const NonlinearBudget) u16 {
        return if (self.attempted_iterations >= self.limit)
            0
        else
            self.limit - self.attempted_iterations;
    }

    pub fn beginIteration(self: *NonlinearBudget) !void {
        try self.validate();
        if (self.attempted_iterations == self.limit)
            return error.NonlinearIterationBudgetExhausted;
        self.attempted_iterations += 1;
    }

    /// Pure local constitutive inversions are not staged state promotions and
    /// therefore do not consume the shared counter. They still inherit the
    /// user's hard ceiling per independent cell/inversion.
    pub fn localIterationCap(self: *const NonlinearBudget, existing_cap: u16) !u16 {
        try self.validate();
        if (existing_cap == 0) return error.ZeroNonlinearIterationLimit;
        return @min(existing_cap, self.limit);
    }
};

pub const SolverOptions = struct {
    /// Floor term only. Convergence uses
    /// `absolute_tolerance + relative_tolerance * residual_scale`, and the
    /// second term is the intended primary criterion: `residual_scale` is
    /// mandatory precisely so the acceptance band is expressed in the units of
    /// the residual being solved. This absolute term exists so the band stays
    /// strictly positive when the characteristic magnitude of the residual is
    /// legitimately tiny (near-zero fluxes, degenerate states), which would
    /// otherwise demand exact arithmetic. It must never be the deciding term
    /// for a residual carrying physical units; if it is, the call site is
    /// missing an honest `residual_scale`.
    /// Process-specific absolute floor in residual units. Zero selects a
    /// scale-derived roundoff floor; it does not mean exact arithmetic.
    absolute_tolerance: f64 = 0,
    relative_tolerance: f64 = 1.0e-8,
    /// Process-specific derivative floor. Zero rejects only an exactly zero
    /// derivative; fixed-point defects use their own scale-aware floor.
    derivative_floor: f64 = 0,
    picard_relaxation: f64 = 0.5,
    /// Characteristic magnitude of the residual, in the residual's own units.
    /// Mandatory by design: no default exists, so every call site must state
    /// the physical scale its acceptance band is relative to.
    residual_scale: f64,
    /// Hard ceiling on nonlinear method iterations/attempts. Accepted state
    /// promotions are accounted separately by `shared_budget` when supplied.
    max_iterations: u16 = 40,
    safeguard_with_bracket: bool = false,
    /// Permit termination at the closest of two adjacent floating-point
    /// coordinates that bracket a root. This is not a relaxed residual band:
    /// no representable coordinate exists between the returned point and the
    /// opposite-sign neighbor. Intended for extremely stiff constitutive maps.
    accept_nearest_representable_root: bool = false,
    /// Compatibility field retained so old option initializers still compile.
    /// Production validation rejects false: vanilla Picard is not a permitted
    /// nonlinear fallback.
    anderson_recovery: bool = true,
    /// Backtracking trials for each damped Newton update.
    max_line_search_steps: u8 = 12,
    /// Armijo decrease coefficient for the scalar residual merit function.
    line_search_sufficient_decrease: f64 = 1.0e-4,
    /// Consecutive Newton/Anderson updates allowed to grow the residual
    /// past `divergence_growth_factor` times the best seen. Beyond this the
    /// solve is diverging or oscillating and reporting that is more useful than
    /// burning the remaining iterations.
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    /// Consecutive accepted iterates allowed to make no scaled, representable
    /// residual progress before Newton yields to the required Anderson
    /// recovery. The following iteration still performs the mandatory Newton
    /// retry, so this changes routing rather than the fixed point or ceiling.
    /// Physical-acceptance goal (2026-09-03): tightened from 4 to 3 to match
    /// "detect stagnation ... after 2-3 iterations". A same-day first attempt
    /// at this exact change was reverted on a false alarm -- 3 "heat"-filtered
    /// and 2 "gas"-filtered test failures were initially (wrongly) attributed
    /// to it; rigorous A/B (identical failing test names at both 3 and 4,
    /// confirmed by literally reverting and re-testing) proved they are
    /// pre-existing and unrelated: `solver_solve.zig` and its sibling source
    /// files are checked out with CRLF line endings on this Windows
    /// environment (confirmed via raw byte inspection: 3503 CRLF, 0 LF-only
    /// in one such file), and several structural tests in `solver_tests.zig`
    /// / `coupled_gas_solver_tests.zig` do exact-byte `\n`-only substring
    /// matches against that raw source text, which cannot match across a
    /// `\r\n` boundary -- an environment/checkout artifact, not a
    /// stagnation_patience regression. This threshold change is on an
    /// existing, already-tested detector shared by every `newtonPicard`
    /// caller (heat, gas, temperature, ground-air-exchange), not new
    /// untested logic, so it applies everywhere at once without a
    /// per-subsystem rewrite.
    stagnation_patience: u16 = 3,
    /// Consecutive alternations between the two currently-active bounds
    /// (lower<->upper) allowed before Newton yields to Anderson recovery,
    /// independent of `stagnation_patience`. A clamped Newton (or Anderson)
    /// step can keep landing exactly on alternating bounds while each
    /// landing still shows a residual decrease relative to the immediately
    /// preceding point -- satisfying `residualProgressStagnated`'s
    /// single-step comparison every time -- yet the iterate never
    /// approaches an interior root. This catches that orthogonal failure
    /// mode directly from the x-trajectory rather than the residual trend.
    boundary_oscillation_patience: u16 = 2,
    /// Optional transaction-scoped nonlinear-iteration budget. A nested
    /// solve must receive the same pointer as its owner; there is deliberately
    /// no boolean opt-out once a budget is supplied.
    shared_budget: ?*NonlinearBudget = null,
    /// Physical-acceptance goal (2026-09-03): when set, and only when this
    /// call fails with `NewtonPicardDiverged`/`Stagnated`/`DidNotConverge`,
    /// the lowest-residual bounded finite state actually evaluated is written here
    /// before the error is returned. Without this, that iterate is silently
    /// discarded and a caller cannot ask "was the state I already computed
    /// physically acceptable, even though it did not reach the residual
    /// tolerance?" -- it can only see the error. `null` (the default)
    /// preserves today's behavior exactly for every existing caller; this is
    /// the prerequisite plumbing for a caller-side physical-acceptance
    /// fallback, not a policy change on its own. The historical field name is
    /// retained for compatibility. A rejected Newton/Anderson line-search
    /// trial can be the best observed state; retaining it does not declare it
    /// converged or increment accepted-step counters. The caller must reprice
    /// it and enforce its independent physical/conservation gates. Unevaluated
    /// Picard history seeds are never candidates for this output.
    last_iterate_on_failure: ?*SolveResult = null,
};

pub const SolveResult = struct {
    root: f64,
    residual: f64,
    /// Nonlinear method iterations attempted, bounded by `max_iterations`.
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    /// Anderson recovery steps. `picard_steps` is a compatibility alias and is
    /// always equal to this field; no vanilla Picard step is reachable.
    anderson_steps: u16 = 0,
};

const ObservedScalarState = struct {
    root: f64,
    residual: f64,
};

fn rememberObservedScalarState(
    options: SolverOptions,
    best: *?ObservedScalarState,
    root: f64,
    residual: f64,
    lower_bound: f64,
    upper_bound: f64,
) void {
    if (options.last_iterate_on_failure == null or
        !std.math.isFinite(root) or !std.math.isFinite(residual) or
        root < lower_bound or root > upper_bound) return;
    if (best.*) |previous| if (@abs(residual) >= @abs(previous.residual)) return;
    best.* = .{ .root = root, .residual = residual };
}

/// See `SolverOptions.last_iterate_on_failure`. Called immediately before
/// every `NewtonPicardDiverged`/`Stagnated`/`DidNotConverge` return so a
/// caller that opted in can inspect the state that was actually reached
/// instead of only seeing the error.
fn captureLastIterateOnFailure(
    options: SolverOptions,
    best: ?ObservedScalarState,
    x: f64,
    residual: f64,
    iterations: u16,
    newton_raphson_steps: u16,
    anderson_steps: u16,
) void {
    // Keep the current state on a merit tie; merely evaluating an equally
    // good bracket endpoint must not replace a physically useful warm start.
    const selected = if (best) |state|
        if (!std.math.isFinite(residual) or @abs(state.residual) < @abs(residual)) state else ObservedScalarState{ .root = x, .residual = residual }
    else
        ObservedScalarState{ .root = x, .residual = residual };
    if (options.last_iterate_on_failure) |out| out.* = .{
        .root = selected.root,
        .residual = selected.residual,
        .iterations = iterations,
        .newton_raphson_steps = newton_raphson_steps,
        .picard_steps = anderson_steps,
        .anderson_steps = anderson_steps,
    };
}

/// Production nonlinear sequence: damped/line-search Newton; on a rejected or
/// unusable Newton direction, one safeguarded Anderson-Picard recovery update;
/// then restart Newton. `max_iterations` is a hard ceiling on nonlinear method
/// iterations, not a target. Residual convergence and conservation acceptance
/// are separate. An accepted Anderson state is never a publication candidate
/// until the immediately following iteration has attempted Newton.
pub fn newtonPicard(
    context: anytype,
    residualFn: anytype,
    derivativeFn: anytype,
    picardFn: anytype,
    lower_bound: f64,
    upper_bound: f64,
    initial_guess: f64,
    options: SolverOptions,
) !SolveResult {
    try validateOptions(options);
    if (!std.math.isFinite(lower_bound) or !std.math.isFinite(upper_bound) or lower_bound >= upper_bound) return error.InvalidBounds;
    var x = std.math.clamp(initial_guess, lower_bound, upper_bound);
    var updates: u16 = 0;
    var newton_raphson_steps: u16 = 0;
    var anderson_steps: u16 = 0;
    var best_observed: ?ObservedScalarState = null;
    // See `SolverOptions.last_iterate_on_failure`: captures the iterate a
    // failing call actually reached so a caller can apply physical
    // acceptance instead of unconditionally escalating on non-convergence.
    // Populated by `captureLastIterateOnFailure` immediately before every
    // `NewtonPicardDiverged`/`Stagnated`/`DidNotConverge` return below.
    var last_observed_residual: f64 = undefined;
    var newton_retry_required = false;
    var best_absolute_residual = std.math.inf(f64);
    var explosive_update_count: u16 = 0;
    var previous_absolute_residual = std.math.inf(f64);
    var insufficient_progress_count: u16 = 0;
    const BoundSide = enum { none, lower, upper };
    var last_bound_side: BoundSide = .none;
    var bound_oscillation_count: u16 = 0;
    var bracket_lower = lower_bound;
    var bracket_upper = upper_bound;
    var bracket_lower_residual: f64 = undefined;
    var bracket_upper_residual: f64 = undefined;
    var bracket_valid = false;
    if (options.safeguard_with_bracket) {
        bracket_lower_residual = residualFn(context, bracket_lower);
        bracket_upper_residual = residualFn(context, bracket_upper);
        try requireFinite("Newton-Picard lower-bound residual", bracket_lower_residual);
        try requireFinite("Newton-Picard upper-bound residual", bracket_upper_residual);
        rememberObservedScalarState(options, &best_observed, bracket_lower, bracket_lower_residual, lower_bound, upper_bound);
        rememberObservedScalarState(options, &best_observed, bracket_upper, bracket_upper_residual, lower_bound, upper_bound);
        bracket_valid =
            std.math.signbit(bracket_lower_residual) !=
            std.math.signbit(bracket_upper_residual);
    }
    const tolerance = convergenceTolerance(options);
    while (updates < options.max_iterations) : (updates += 1) {
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        const current_residual = residualFn(context, x);
        try requireFinite("Newton-Picard residual", current_residual);
        rememberObservedScalarState(options, &best_observed, x, current_residual, lower_bound, upper_bound);
        last_observed_residual = current_residual;
        const absolute_residual = @abs(current_residual);
        if (!retrying_newton_after_anderson and absolute_residual <= tolerance) return .{
            .root = x,
            .residual = current_residual,
            .iterations = updates,
            .newton_raphson_steps = newton_raphson_steps,
            .picard_steps = anderson_steps,
            .anderson_steps = anderson_steps,
        };
        if (options.shared_budget) |budget| {
            // Preserve the solver-level non-convergence classification so the
            // hourly transaction can invoke its normal rollback/substep path.
            // The lower-level budget error remains available for direct misuse.
            if (budget.remaining() == 0) {
                captureLastIterateOnFailure(options, best_observed, x, last_observed_residual, updates, newton_raphson_steps, anderson_steps);
                return error.NewtonPicardDidNotConverge;
            }
            try budget.beginIteration();
        }
        if (residualExplosionExceededPatience(
            absolute_residual,
            tolerance,
            options,
            &best_absolute_residual,
            &explosive_update_count,
        )) {
            std.log.warn("Newton-Anderson residual explosion: update={d} x={e} residual={e} best_residual={e}", .{ updates, x, current_residual, best_absolute_residual });
            captureLastIterateOnFailure(options, best_observed, x, current_residual, updates, newton_raphson_steps, anderson_steps);
            return error.NewtonPicardDiverged;
        }
        const residual_stagnating = residualProgressStagnated(
            absolute_residual,
            options,
            &previous_absolute_residual,
            &insufficient_progress_count,
        );
        // Classified against the bounds as they stood coming into this
        // iteration (before any bracket narrowing below), since `x` is the
        // point those bounds actually constrained when it was accepted.
        const boundary_side: BoundSide = blk: {
            const active_lower = if (bracket_valid) bracket_lower else lower_bound;
            const active_upper = if (bracket_valid) bracket_upper else upper_bound;
            break :blk if (x == active_lower) .lower else if (x == active_upper) .upper else .none;
        };
        if (boundary_side == .none) {
            bound_oscillation_count = 0;
        } else if (last_bound_side != .none and boundary_side != last_bound_side) {
            bound_oscillation_count +|= 1;
        }
        last_bound_side = boundary_side;
        const stagnating = residual_stagnating or bound_oscillation_count >= options.boundary_oscillation_patience;
        if (bracket_valid) {
            if (std.math.signbit(current_residual) ==
                std.math.signbit(bracket_lower_residual))
            {
                bracket_lower = x;
                bracket_lower_residual = current_residual;
            } else {
                bracket_upper = x;
                bracket_upper_residual = current_residual;
            }
        }
        if (!retrying_newton_after_anderson and options.accept_nearest_representable_root and bracket_valid) {
            const opposite_bound = if (std.math.signbit(current_residual) ==
                std.math.signbit(bracket_lower_residual))
                bracket_upper
            else
                bracket_lower;
            const neighbor = std.math.nextAfter(f64, x, opposite_bound);
            if (neighbor != x) {
                const neighbor_residual = residualFn(context, neighbor);
                try requireFinite("nearest-representable root residual", neighbor_residual);
                rememberObservedScalarState(options, &best_observed, neighbor, neighbor_residual, lower_bound, upper_bound);
                if (@abs(neighbor_residual) <= tolerance) {
                    return .{
                        .root = neighbor,
                        .residual = neighbor_residual,
                        .iterations = updates + 1,
                        .newton_raphson_steps = newton_raphson_steps,
                        .picard_steps = anderson_steps,
                        .anderson_steps = anderson_steps,
                    };
                }
                if (std.math.signbit(neighbor_residual) != std.math.signbit(current_residual)) {
                    if (@abs(neighbor_residual) < absolute_residual) {
                        return .{
                            .root = neighbor,
                            .residual = neighbor_residual,
                            .iterations = updates + 1,
                            .newton_raphson_steps = newton_raphson_steps,
                            .picard_steps = anderson_steps,
                            .anderson_steps = anderson_steps,
                        };
                    }
                    return .{
                        .root = x,
                        .residual = current_residual,
                        .iterations = updates + 1,
                        .newton_raphson_steps = newton_raphson_steps,
                        .picard_steps = anderson_steps,
                        .anderson_steps = anderson_steps,
                    };
                }
            }
        }

        // Primary: backtracking Newton. Non-finite trial evaluations reject
        // that trial and continue damping; they never enter accepted state.
        const derivative_value = derivativeFn(context, x);
        var accepted_newton = false;
        if ((!stagnating or retrying_newton_after_anderson) and
            std.math.isFinite(derivative_value) and
            @abs(derivative_value) > options.derivative_floor)
        {
            const direction = -current_residual / derivative_value;
            if (std.math.isFinite(direction)) {
                var damping: f64 = 1;
                var line_step: u8 = 0;
                while (line_step < options.max_line_search_steps) : (line_step += 1) {
                    const active_lower = if (bracket_valid) bracket_lower else lower_bound;
                    const active_upper = if (bracket_valid) bracket_upper else upper_bound;
                    const unconstrained_candidate = x + damping * direction;
                    if (std.math.isFinite(unconstrained_candidate)) {
                        const candidate = std.math.clamp(unconstrained_candidate, active_lower, active_upper);
                        if (candidate == x) {
                            damping *= 0.5;
                            continue;
                        }
                        const effective_damping = @abs((candidate - x) / direction);
                        const candidate_residual = residualFn(context, candidate);
                        rememberObservedScalarState(options, &best_observed, candidate, candidate_residual, lower_bound, upper_bound);
                        if (std.math.isFinite(candidate_residual) and
                            @abs(candidate_residual) <= (1.0 - options.line_search_sufficient_decrease * effective_damping) * absolute_residual)
                        {
                            x = candidate;
                            newton_raphson_steps += 1;
                            accepted_newton = true;
                            break;
                        }
                    }
                    damping *= 0.5;
                }
                if (accepted_newton) continue;
            }
        }

        // The iteration immediately after an accepted Anderson update is
        // reserved for this Newton retry. A failed retry leaves the Anderson
        // state unchanged and returns to the convergence gate on the next
        // iteration (or the read-only final gate at the hard ceiling); it may
        // not cascade directly into another recovery update.
        if (retrying_newton_after_anderson) continue;

        // Recovery itself consumes this iteration and requires one remaining
        // iteration for the mandatory Newton retry. Fail before forming or
        // committing an Anderson candidate when the user ceiling has no slot.
        if (updates + 1 >= options.max_iterations or
            (options.shared_budget != null and options.shared_budget.?.remaining() == 0))
        {
            captureLastIterateOnFailure(options, best_observed, x, current_residual, updates, newton_raphson_steps, anderson_steps);
            return error.NewtonPicardDidNotConverge;
        }

        // Sole fallback: safeguarded depth-1 Anderson-accelerated Picard. A
        // relaxed Picard point is evaluated only to seed the two-point Anderson
        // secant; it is never committed as state. Thus even the first accepted
        // recovery update is genuinely accelerated. Newton is retried next.
        const fixed_point = picardFn(context, x);
        try requireFinite("Anderson fixed point", fixed_point);
        const defect = fixed_point - x;
        try requireFinite("Anderson defect", defect);
        const seed_x = std.math.clamp(
            x + options.picard_relaxation * defect,
            if (bracket_valid) bracket_lower else lower_bound,
            if (bracket_valid) bracket_upper else upper_bound,
        );
        if (!std.math.isFinite(seed_x)) return error.NonFinitePicardIterate;
        // A one-ULP coordinate change can be physically material for a stiff
        // constitutive curve (notably saturated-soil enthalpy at melting).
        // Reject only an actually unrepresentable seed; merit evaluation owns
        // whether a representable small step is useful.
        if (seed_x == x) {
            if (!builtin.is_test and options.last_iterate_on_failure == null)
                std.log.err("Newton-Anderson stagnated: update={d} x={e} residual={e}", .{ updates, x, current_residual });
            captureLastIterateOnFailure(options, best_observed, x, current_residual, updates, newton_raphson_steps, anderson_steps);
            return error.NewtonPicardStagnated;
        }
        const seed_fixed_point = picardFn(context, seed_x);
        try requireFinite("Anderson seed fixed point", seed_fixed_point);
        const seed_defect = seed_fixed_point - seed_x;
        try requireFinite("Anderson seed defect", seed_defect);
        const defect_change = seed_defect - defect;
        const defect_floor = 8.0 * std.math.floatEps(f64) * @max(@abs(defect), @abs(seed_defect));
        if (@abs(defect_change) <= defect_floor) {
            if (!builtin.is_test and options.last_iterate_on_failure == null)
                std.log.err("Newton-Anderson defect stagnated: update={d} x={e} residual={e} defect={e} seed_x={e} seed_defect={e}", .{ updates, x, current_residual, defect, seed_x, seed_defect });
            captureLastIterateOnFailure(options, best_observed, x, current_residual, updates, newton_raphson_steps, anderson_steps);
            return error.NewtonPicardStagnated;
        }
        const mixing = seed_defect / defect_change;
        if (!std.math.isFinite(mixing)) {
            if (!builtin.is_test and options.last_iterate_on_failure == null)
                std.log.err("Newton-Anderson mixing is non-finite: update={d} x={e} residual={e} defect={e} seed_x={e} seed_defect={e}", .{ updates, x, current_residual, defect, seed_x, seed_defect });
            captureLastIterateOnFailure(options, best_observed, x, current_residual, updates, newton_raphson_steps, anderson_steps);
            return error.NewtonPicardStagnated;
        }
        const accelerated = seed_x - mixing * (seed_x - x);
        if (!std.math.isFinite(accelerated)) return error.NonFinitePicardIterate;
        const anderson_direction = accelerated - x;
        if (accelerated == x) {
            if (!builtin.is_test and options.last_iterate_on_failure == null)
                std.log.err("Newton-Anderson direction stagnated: update={d} x={e} residual={e} accelerated={e} direction={e}", .{ updates, x, current_residual, accelerated, anderson_direction });
            captureLastIterateOnFailure(options, best_observed, x, current_residual, updates, newton_raphson_steps, anderson_steps);
            return error.NewtonPicardStagnated;
        }

        var accepted_anderson = false;
        var next_x = x;
        var best_anderson_x = x;
        var best_anderson_residual = current_residual;
        var damping: f64 = 1;
        var line_step: u8 = 0;
        while (line_step < options.max_line_search_steps) : (line_step += 1) {
            const active_lower = if (bracket_valid) bracket_lower else lower_bound;
            const active_upper = if (bracket_valid) bracket_upper else upper_bound;
            const unconstrained_candidate = x + damping * anderson_direction;
            if (std.math.isFinite(unconstrained_candidate)) {
                const candidate = std.math.clamp(unconstrained_candidate, active_lower, active_upper);
                if (candidate == x) {
                    damping *= 0.5;
                    continue;
                }
                const effective_damping = @abs((candidate - x) / anderson_direction);
                const candidate_residual = residualFn(context, candidate);
                rememberObservedScalarState(options, &best_observed, candidate, candidate_residual, lower_bound, upper_bound);
                if (std.math.isFinite(candidate_residual) and @abs(candidate_residual) < @abs(best_anderson_residual)) {
                    best_anderson_x = candidate;
                    best_anderson_residual = candidate_residual;
                }
                // Crossing the root is valid inside the maintained bracket;
                // rejecting an opposite-sign improvement can strand a stiff
                // constitutive solve between adjacent representable values.
                const candidate_absolute_residual = @abs(candidate_residual);
                const armijo_decrease = candidate_absolute_residual <=
                    (1.0 - options.line_search_sufficient_decrease * effective_damping) * absolute_residual;
                const coordinate_roundoff_step = @abs(candidate - x) <=
                    8.0 * std.math.floatEps(f64) * @max(@abs(x), upper_bound - lower_bound);
                // Close to a stiff phase kink, a one/two-ULP temperature move
                // can reduce enthalpy materially yet cannot encode the full
                // Armijo margin. A strict merit decrease remains safe there.
                const representable_decrease = coordinate_roundoff_step and
                    candidate_absolute_residual < absolute_residual;
                // The raw relaxed seed is history-only and prohibited from
                // publication. Anderson therefore competes with the accepted
                // current state (and Armijo), never with that private sample.
                if (std.math.isFinite(candidate_residual) and
                    (armijo_decrease or representable_decrease))
                {
                    next_x = candidate;
                    accepted_anderson = true;
                    break;
                }
            }
            damping *= 0.5;
        }
        if (!accepted_anderson) {
            if (!builtin.is_test and options.last_iterate_on_failure == null)
                std.log.err("Newton-Anderson line search stagnated: update={d} x={e} residual={e} accelerated={e} direction={e} best_x={e} best_residual={e} bracket=[{e},{e}]", .{ updates, x, current_residual, accelerated, anderson_direction, best_anderson_x, best_anderson_residual, bracket_lower, bracket_upper });
            captureLastIterateOnFailure(options, best_observed, x, current_residual, updates, newton_raphson_steps, anderson_steps);
            return error.NewtonPicardStagnated;
        }
        x = next_x;
        anderson_steps += 1;
        newton_retry_required = true;
    }
    if (newton_retry_required) {
        captureLastIterateOnFailure(options, best_observed, x, last_observed_residual, options.max_iterations, newton_raphson_steps, anderson_steps);
        return error.NewtonPicardDidNotConverge;
    }
    const final_residual = residualFn(context, x);
    try requireFinite("final Newton-Picard residual", final_residual);
    rememberObservedScalarState(options, &best_observed, x, final_residual, lower_bound, upper_bound);
    last_observed_residual = final_residual;
    if (@abs(final_residual) <= tolerance) return .{
        .root = x,
        .residual = final_residual,
        .iterations = options.max_iterations,
        .newton_raphson_steps = newton_raphson_steps,
        .picard_steps = anderson_steps,
        .anderson_steps = anderson_steps,
    };
    std.log.warn("Newton-Anderson failed: iterations={d} bounds=[{e},{e}] last_x={e} residual={e} newton_steps={d} anderson_steps={d}", .{ options.max_iterations, lower_bound, upper_bound, x, final_residual, newton_raphson_steps, anderson_steps });
    captureLastIterateOnFailure(options, best_observed, x, final_residual, options.max_iterations, newton_raphson_steps, anderson_steps);
    return error.NewtonPicardDidNotConverge;
}

fn residualExplosionExceededPatience(
    absolute_residual: f64,
    tolerance: f64,
    options: SolverOptions,
    best_absolute_residual: *f64,
    explosive_update_count: *u16,
) bool {
    if (absolute_residual < best_absolute_residual.*) {
        best_absolute_residual.* = absolute_residual;
        explosive_update_count.* = 0;
        return false;
    }
    if (absolute_residual > options.divergence_growth_factor *
        @max(best_absolute_residual.*, tolerance))
    {
        explosive_update_count.* +|= 1;
        return explosive_update_count.* >= options.divergence_patience;
    }
    explosive_update_count.* = 0;
    return false;
}

fn residualProgressStagnated(
    absolute_residual: f64,
    options: SolverOptions,
    previous_absolute_residual: *f64,
    insufficient_progress_count: *u16,
) bool {
    // Stagnation is lack of representable progress at the residual currently
    // being resolved, not lack of progress relative to the problem's full
    // characteristic scale.  Using `residual_scale` here routes a converging
    // stiff solve to Anderson as soon as |R| falls below sqrt(eps)*scale,
    // even though its configured physical convergence band can be orders of
    // magnitude smaller (the soil enthalpy phase front is one such case).
    // The convergence tolerance supplies the scale only at the acceptance
    // floor; above it, require progress relative to the previous residual.
    const progress_floor = std.math.sqrt(std.math.floatEps(f64)) *
        @max(convergenceTolerance(options), previous_absolute_residual.*);
    if (std.math.isFinite(previous_absolute_residual.*) and
        previous_absolute_residual.* - absolute_residual <= progress_floor)
    {
        insufficient_progress_count.* +|= 1;
    } else {
        insufficient_progress_count.* = 0;
    }
    previous_absolute_residual.* = absolute_residual;
    return insufficient_progress_count.* >= options.stagnation_patience;
}

pub fn convergenceTolerance(options: SolverOptions) f64 {
    const roundoff_floor = 64.0 * std.math.floatEps(f64) * options.residual_scale;
    return @max(options.absolute_tolerance, roundoff_floor) + options.relative_tolerance * options.residual_scale;
}

pub fn newtonPicardFiniteDifference(context: anytype, residualFn: anytype, picardFn: anytype, lower_bound: f64, upper_bound: f64, initial_guess: f64, options: SolverOptions) !SolveResult {
    const Adapter = struct {
        inner: @TypeOf(context),
        lower: f64,
        upper: f64,

        fn residual(data: *const @This(), x: f64) f64 {
            return residualFn(data.inner, x);
        }

        fn derivative(data: *const @This(), x: f64) f64 {
            const scale = @max(@abs(x), 1.0);
            // A centered first derivative has O(h^2 + eps/h) error, so
            // cbrt(eps), not sqrt(eps), is its roundoff-balanced step.  At a
            // declared physical bound use the corresponding one-sided probe;
            // evaluating a residual outside its admissible interval can
            // manufacture NaN/Inf and incorrectly force Anderson recovery.
            const centered_step = std.math.cbrt(std.math.floatEps(f64)) * scale;
            const left_room = x - data.lower;
            const right_room = data.upper - x;
            if (left_room >= centered_step and right_room >= centered_step)
                return (residualFn(data.inner, x + centered_step) -
                    residualFn(data.inner, x - centered_step)) /
                    (2.0 * centered_step);

            const one_sided_step = @sqrt(std.math.floatEps(f64)) * scale;
            const center = residualFn(data.inner, x);
            if (right_room > 0) {
                const step = @min(one_sided_step, right_room);
                return (residualFn(data.inner, x + step) - center) / step;
            }
            if (left_room > 0) {
                const step = @min(one_sided_step, left_room);
                return (center - residualFn(data.inner, x - step)) / step;
            }
            return std.math.nan(f64);
        }

        fn fixedPoint(data: *const @This(), x: f64) f64 {
            return picardFn(data.inner, x);
        }
    };
    var adapter: Adapter = .{
        .inner = context,
        .lower = lower_bound,
        .upper = upper_bound,
    };
    return newtonPicard(
        &adapter,
        Adapter.residual,
        Adapter.derivative,
        Adapter.fixedPoint,
        lower_bound,
        upper_bound,
        initial_guess,
        options,
    );
}

pub fn requireFinite(comptime label: []const u8, value: f64) !void {
    if (!std.math.isFinite(value)) {
        std.log.err("non-finite numeric value: {s}={e}", .{ label, value });
        return error.NonFiniteNumericValue;
    }
}

fn validateOptions(options: SolverOptions) !void {
    if (!std.math.isFinite(options.absolute_tolerance) or options.absolute_tolerance < 0 or
        !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or
        !std.math.isFinite(options.derivative_floor) or options.derivative_floor < 0 or
        !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or
        !std.math.isFinite(options.residual_scale) or options.residual_scale <= 0 or
        !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1 or
        !std.math.isFinite(options.line_search_sufficient_decrease) or options.line_search_sufficient_decrease <= 0 or options.line_search_sufficient_decrease >= 1 or
        options.max_line_search_steps == 0 or
        !options.anderson_recovery or
        options.divergence_patience == 0 or
        options.stagnation_patience == 0 or
        options.boundary_oscillation_patience == 0 or
        options.max_iterations == 0) return error.InvalidSolverOptions;
    if (options.shared_budget) |budget| {
        budget.validate() catch return error.InvalidSolverOptions;
        if (options.max_iterations > budget.limit) return error.InvalidSolverOptions;
    }
}

fn squareMinusTwo(_: void, x: f64) f64 {
    return x * x - 2.0;
}
fn squareMinusTwoDerivative(_: void, x: f64) f64 {
    return 2.0 * x;
}
fn squareRootPicard(_: void, x: f64) f64 {
    return 2.0 / x;
}
fn unusableDerivative(_: void, _: f64) f64 {
    return 0;
}
fn tinyResidual(_: void, x: f64) f64 {
    return x - 2.0e-10;
}
fn tinyPicard(_: void, _: f64) f64 {
    return 2.0e-10;
}
fn budgetTestResidual(_: void, x: f64) f64 {
    return x - 1;
}
fn budgetTestDerivative(_: void, _: f64) f64 {
    return 2;
}
fn budgetTestPicard(_: void, _: f64) f64 {
    return 1;
}
fn boundedLinearResidual(_: void, x: f64) f64 {
    if (x < 0 or x > 1) return std.math.nan(f64);
    return x - 0.25;
}
fn boundedLinearPicard(_: void, _: f64) f64 {
    return 0.25;
}

test "Newton-Raphson path converges" {
    // Residual x^2 - 2 is dimensionless and O(1) over the bracket [0.1, 2].
    const result = try newtonPicard({}, squareMinusTwo, squareMinusTwoDerivative, squareRootPicard, 0.1, 2.0, 1.8, .{ .residual_scale = 1 });
    try std.testing.expectApproxEqRel(@sqrt(2.0), result.root, 1.0e-10);
    try std.testing.expect(result.newton_raphson_steps > 0);
    try std.testing.expect(result.iterations < 40);
}

test "finite-difference Newton never probes outside physical bounds" {
    // The lower-bound initial state is valid, but its residual deliberately
    // rejects negative coordinates. A centered probe through the bound makes
    // the Newton derivative non-finite and cannot recover under a one-update
    // ceiling. The bound-aware one-sided derivative reaches the root directly.
    const result = try newtonPicardFiniteDifference(
        {},
        boundedLinearResidual,
        boundedLinearPicard,
        0,
        1,
        0,
        .{
            .absolute_tolerance = 1.0e-14,
            .relative_tolerance = 1.0e-12,
            .residual_scale = 1,
            .max_iterations = 1,
        },
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), result.root, 1.0e-12);
    try std.testing.expectEqual(@as(u16, 1), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
}

test "dense solve preserves valid weak coordinates in a stiff system" {
    var matrix = [_]f64{ 1.0e24, 0, 0, 1 };
    var rhs = [_]f64{ 2.0e24, 3 };
    try std.testing.expect(solveDenseLinearSystem(&matrix, &rhs, 2));
    try std.testing.expectApproxEqRel(@as(f64, 2), rhs[0], 1e-14);
    try std.testing.expectApproxEqRel(@as(f64, 3), rhs[1], 1e-14);
}

test "vector Anderson seed reaches a linear fixed point without accepting Picard" {
    const current = [_]f64{ 0, 2 };
    const defect = [_]f64{ 0.1, -0.2 };
    const seed = [_]f64{ 0.05, 1.9 };
    const seed_defect = [_]f64{ 0.09, -0.18 };
    var accelerated: [2]f64 = undefined;
    try std.testing.expect(andersonDepthOneCandidate(&current, &defect, &seed, &seed_defect, &accelerated));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), accelerated[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), accelerated[1], 1e-12);
}

test "Newton-Anderson exits without consuming the hard ceiling when initially converged" {
    const root = @sqrt(2.0);
    // Dimensionless residual, O(1) magnitude.
    const result = try newtonPicard({}, squareMinusTwo, squareMinusTwoDerivative, squareRootPicard, 0.1, 2.0, root, .{ .max_iterations = 80, .residual_scale = 1 });
    try std.testing.expectEqual(@as(u16, 0), result.iterations);
    try std.testing.expectEqual(@as(u16, 0), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), result.picard_steps);
}

test "Anderson may improve current without beating its private relaxed seed" {
    // The relaxed seed is only a secant sample and may never be published.
    // Requiring acceleration to beat it falsely stagnates this valid sequence,
    // even though every accepted Anderson point strictly improves current.
    const result = try newtonPicard({}, squareMinusTwo, unusableDerivative, squareRootPicard, 0.1, 2.0, 1.8, .{ .picard_relaxation = 0.5, .residual_scale = 1 });
    try std.testing.expectApproxEqRel(@sqrt(2.0), result.root, 1.0e-10);
    try std.testing.expect(result.anderson_steps > 0);
    try std.testing.expectEqual(result.anderson_steps, result.picard_steps);
}

test "final-slot Anderson is rejected after consuming its sole attempt" {
    var budget = try NonlinearBudget.init(1);
    try std.testing.expectError(error.NewtonPicardDidNotConverge, newtonPicard(
        {},
        tinyResidual,
        unusableDerivative,
        tinyPicard,
        0,
        1.0e-9,
        9.0e-10,
        .{
            .absolute_tolerance = 1.0e-20,
            .relative_tolerance = 1.0e-10,
            .residual_scale = 1.0e-9,
            .picard_relaxation = 1,
            .max_iterations = 1,
            .shared_budget = &budget,
        },
    ));
    try std.testing.expectEqual(@as(u16, 1), budget.attempted_iterations);
}

test "Picard stagnation threshold follows a tiny physical interval" {
    const result = try newtonPicard({}, tinyResidual, unusableDerivative, tinyPicard, 0, 1.0e-9, 9.0e-10, .{
        .absolute_tolerance = 1.0e-20,
        .relative_tolerance = 1.0e-10,
        .residual_scale = 1.0e-9,
        .picard_relaxation = 0.5,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 2.0e-10), result.root, 2.0e-18);
    try std.testing.expect(result.picard_steps > 0);
}

test "finite-difference Newton-Picard converges" {
    // Dimensionless residual, O(1) magnitude.
    const result = try newtonPicardFiniteDifference({}, squareMinusTwo, squareRootPicard, 0.1, 2.0, 0.7, .{ .residual_scale = 1 });
    try std.testing.expectApproxEqRel(@sqrt(2.0), result.root, 1.0e-10);
}

test "Newton line search evaluates a projected active bound before stagnating" {
    const Context = struct {
        saw_lower_bound: bool = false,

        fn residual(self: *@This(), x: f64) f64 {
            if (x == 0) self.saw_lower_bound = true;
            return x + 1;
        }

        fn derivative(_: *@This(), _: f64) f64 {
            return 1;
        }

        fn fixedPoint(_: *@This(), _: f64) f64 {
            return -1;
        }
    };
    var context: Context = .{};
    const solved = try newtonPicard(
        &context,
        Context.residual,
        Context.derivative,
        Context.fixedPoint,
        0,
        2,
        1.0e-6,
        .{ .absolute_tolerance = 1, .residual_scale = 1, .max_iterations = 20 },
    );
    try std.testing.expectEqual(@as(f64, 0), solved.root);
    try std.testing.expect(context.saw_lower_bound);
}

test "Newton-Picard rejects unusable options" {
    // Dimensionless residual; the solve is rejected before any tolerance use.
    try std.testing.expectError(error.InvalidSolverOptions, newtonPicard({}, squareMinusTwo, squareMinusTwoDerivative, squareRootPicard, 0.1, 2.0, 1.0, .{ .picard_relaxation = 0, .residual_scale = 1 }));
}

test "NonlinearBudget is a hard nonlinear-attempt ceiling" {
    try std.testing.expectError(
        error.ZeroNonlinearIterationLimit,
        NonlinearBudget.init(0),
    );
    var budget = try NonlinearBudget.init(2);
    try std.testing.expectEqual(@as(u16, 2), budget.remaining());
    try budget.beginIteration();
    try std.testing.expectEqual(@as(u16, 1), budget.attempted_iterations);
    try std.testing.expectEqual(@as(u16, 1), budget.remaining());
    try budget.beginIteration();
    try std.testing.expectEqual(@as(u16, 2), budget.attempted_iterations);
    try std.testing.expectEqual(@as(u16, 0), budget.remaining());
    try std.testing.expectError(
        error.NonlinearIterationBudgetExhausted,
        budget.beginIteration(),
    );
    try std.testing.expectEqual(@as(u16, 2), budget.attempted_iterations);
}

test "shared budget counts max-one rollback and max-two final-audit convergence" {
    var one_update_budget = try NonlinearBudget.init(1);
    try std.testing.expectError(
        error.NewtonPicardDidNotConverge,
        newtonPicard(
            {},
            budgetTestResidual,
            budgetTestDerivative,
            budgetTestPicard,
            0,
            1,
            0,
            .{
                .absolute_tolerance = 0.3,
                .relative_tolerance = 1e-12,
                .residual_scale = 1,
                .max_iterations = 1,
                .shared_budget = &one_update_budget,
            },
        ),
    );
    try std.testing.expectEqual(@as(u16, 1), one_update_budget.attempted_iterations);

    var two_update_budget = try NonlinearBudget.init(2);
    const solved = try newtonPicard(
        {},
        budgetTestResidual,
        budgetTestDerivative,
        budgetTestPicard,
        0,
        1,
        0,
        .{
            .absolute_tolerance = 0.3,
            .relative_tolerance = 1e-12,
            .residual_scale = 1,
            .max_iterations = 2,
            .shared_budget = &two_update_budget,
        },
    );
    try std.testing.expectEqual(@as(u16, 2), solved.iterations);
    try std.testing.expectEqual(@as(u16, 2), two_update_budget.attempted_iterations);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), solved.root, 1e-15);
}

test "last_iterate_on_failure exposes the discarded non-converged state" {
    // Physical-acceptance goal (2026-09-03): without this field, the caller
    // sees only the error and cannot ask whether the already-computed
    // iterate below was actually physically acceptable. Same fixture as the
    // "shared budget" test above, but forcing the plain iteration ceiling
    // (not the budget) so this exercises the `NewtonPicardDidNotConverge`
    // path returned after the loop, not the pre-iteration budget check.
    var captured: SolveResult = undefined;
    try std.testing.expectError(
        error.NewtonPicardDidNotConverge,
        newtonPicard(
            {},
            budgetTestResidual,
            budgetTestDerivative,
            budgetTestPicard,
            0,
            1,
            0,
            .{
                .absolute_tolerance = 0.3,
                .relative_tolerance = 1e-12,
                .residual_scale = 1,
                .max_iterations = 1,
                .last_iterate_on_failure = &captured,
            },
        ),
    );
    // One damped Newton step from x=0 toward the true root x=1 lands at 0.5;
    // the ceiling then stops before that satisfies the 0.3 tolerance. The
    // discarded iterate is real and usable, not zero/undefined.
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), captured.root, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), captured.residual, 1e-15);
    try std.testing.expectEqual(@as(u16, 1), captured.iterations);
    try std.testing.expectEqual(@as(u16, 1), captured.newton_raphson_steps);
}

test "best failure state retains rejected Newton and Anderson trials" {
    const Case = struct {
        fn residual(_: void, x: f64) f64 {
            return 1 - 5e-5 * x;
        }
        fn poorDerivative(_: void, _: f64) f64 {
            return -1;
        }
        fn zeroDerivative(_: void, _: f64) f64 {
            return 0;
        }
        fn stationaryPicard(_: void, x: f64) f64 {
            return x;
        }
        fn affinePicard(_: void, x: f64) f64 {
            return 0.5 * x + 0.5;
        }
    };
    // Both methods evaluate x=1, but its real improvement misses Armijo.
    // The old failure output discarded that state and returned x=0/r=1.
    inline for (.{ true, false }) |newton| {
        var captured: SolveResult = undefined;
        try std.testing.expectError(error.NewtonPicardStagnated, newtonPicard(
            {},
            Case.residual,
            if (newton) Case.poorDerivative else Case.zeroDerivative,
            if (newton) Case.stationaryPicard else Case.affinePicard,
            0,
            2,
            0,
            .{ .residual_scale = 1, .last_iterate_on_failure = &captured },
        ));
        try std.testing.expectEqual(@as(f64, 1), captured.root);
        try std.testing.expectEqual(Case.residual({}, captured.root), captured.residual);
        // Retention is not a fictitious accepted Newton/Anderson promotion.
        try std.testing.expectEqual(@as(u16, 0), captured.newton_raphson_steps);
        try std.testing.expectEqual(@as(u16, 0), captured.anderson_steps);
    }
}

test "best failure state excludes nonfinite and out-of-bounds observations" {
    var captured: SolveResult = undefined;
    const options: SolverOptions = .{ .residual_scale = 1, .last_iterate_on_failure = &captured };
    var best: ?ObservedScalarState = null;
    rememberObservedScalarState(options, &best, 0.5, 0.25, 0, 1);
    rememberObservedScalarState(options, &best, 2, 0, 0, 1);
    rememberObservedScalarState(options, &best, std.math.nan(f64), 0, 0, 1);
    rememberObservedScalarState(options, &best, 0.75, std.math.nan(f64), 0, 1);
    rememberObservedScalarState(options, &best, 0.75, std.math.inf(f64), 0, 1);
    captureLastIterateOnFailure(options, best, 0.1, 1, 3, 1, 1);
    try std.testing.expectEqual(@as(f64, 0.5), captured.root);
    try std.testing.expectEqual(@as(f64, 0.25), captured.residual);
    try std.testing.expectEqual(@as(u16, 3), captured.iterations);
    // Equal merit preserves the final warm-start/accepted state, not an
    // arbitrary earlier endpoint; counts remain total attempted method work.
    captureLastIterateOnFailure(options, best, 0.4, -0.25, 4, 2, 1);
    try std.testing.expectEqual(@as(f64, 0.4), captured.root);
    try std.testing.expectEqual(@as(f64, -0.25), captured.residual);
}

test "best failure state tracking leaves successful solves and output untouched" {
    const Case = struct {
        fn residual(_: void, x: f64) f64 {
            return x - 0.75;
        }
        fn derivative(_: void, _: f64) f64 {
            return 1;
        }
        fn picard(_: void, _: f64) f64 {
            return 0.75;
        }
    };
    const sentinel: SolveResult = .{ .root = -99, .residual = 12, .iterations = 42, .newton_raphson_steps = 1, .picard_steps = 0 };
    var captured = sentinel;
    const baseline = try newtonPicard({}, Case.residual, Case.derivative, Case.picard, 0, 1, 0, .{ .residual_scale = 1 });
    const observed = try newtonPicard({}, Case.residual, Case.derivative, Case.picard, 0, 1, 0, .{ .residual_scale = 1, .last_iterate_on_failure = &captured });
    try std.testing.expectEqualDeep(baseline, observed);
    try std.testing.expectEqualDeep(sentinel, captured);
}

test "last_iterate_on_failure defaults to unused, unchanged behavior" {
    // Every existing call site omits this field; confirm the default keeps
    // the exact same error and does not require a caller to opt in.
    try std.testing.expectError(
        error.NewtonPicardDidNotConverge,
        newtonPicard(
            {},
            budgetTestResidual,
            budgetTestDerivative,
            budgetTestPicard,
            0,
            1,
            0,
            .{
                .absolute_tolerance = 0.3,
                .relative_tolerance = 1e-12,
                .residual_scale = 1,
                .max_iterations = 1,
            },
        ),
    );
}

test "solver cannot opt out of its owner budget with a larger local ceiling" {
    var budget = try NonlinearBudget.init(1);
    try std.testing.expectError(
        error.InvalidSolverOptions,
        newtonPicard(
            {},
            budgetTestResidual,
            budgetTestDerivative,
            budgetTestPicard,
            0,
            1,
            0,
            .{
                .residual_scale = 1,
                .max_iterations = 2,
                .shared_budget = &budget,
            },
        ),
    );
    try std.testing.expectEqual(@as(u16, 0), budget.attempted_iterations);
}

// A deliberately slow contraction: g(x) = x + 1e-3 * (target - x) moves 0.1% of
// the remaining distance per call, and the caller's relaxation shrinks that
// again. Ordinary relaxed Picard cannot cross the interval within the iteration
// ceiling; depth-1 Anderson recognizes the linear map and jumps to the root.
const slow_target: f64 = 0.75;
fn slowResidual(_: void, x: f64) f64 {
    return x - slow_target;
}
fn slowPicard(_: void, x: f64) f64 {
    return x + 1.0e-3 * (slow_target - x);
}

// Reproduces the real hour-11 gas/heat-solver failure class: a tiny
// (physically nonsensical) derivative forces every Newton step to overshoot
// clear across the domain, so the line search always clamps the candidate to
// whichever bound is opposite the current one. Each landing's residual
// magnitude (1/call-count, tracked in `calls_at_bound`) is smaller than the
// immediately preceding reading, so `residualProgressStagnated`'s single-step
// comparison resets every iteration and never fires -- yet `x` only ever
// visits the two extreme bounds and never approaches the true interior root.
// Away from the bounds (post-Anderson-escape), the residual/derivative fall
// back to a normal linear map with root 5, so a solver that does escape
// converges cleanly.
const BoundOscillationProbe = struct {
    calls_at_bound: u32 = 0,

    fn residual(self: *@This(), x: f64) f64 {
        if (x == 0 or x == 10) {
            self.calls_at_bound += 1;
            const magnitude = 1.0 / @as(f64, @floatFromInt(self.calls_at_bound));
            return if (x == 0) -magnitude else magnitude;
        }
        return x - 5;
    }
    fn derivative(_: *@This(), x: f64) f64 {
        if (x == 0 or x == 10) return 1.0e-9;
        return 1;
    }
    fn fixedPoint(_: *@This(), _: f64) f64 {
        return 5;
    }
};

test "boundary-oscillation detector escapes a bound-clamp ping-pong that residual-progress alone misses" {
    var probe: BoundOscillationProbe = .{};
    const result = try newtonPicard(
        &probe,
        BoundOscillationProbe.residual,
        BoundOscillationProbe.derivative,
        BoundOscillationProbe.fixedPoint,
        0,
        10,
        0,
        .{ .residual_scale = 1, .max_iterations = 12, .boundary_oscillation_patience = 2 },
    );
    try std.testing.expectApproxEqAbs(@as(f64, 5), result.root, 1.0e-9);
    try std.testing.expect(result.anderson_steps > 0);
    // Precise, not just bounded: this is the concrete measured contrast
    // with the companion "without the detector" test below, which exhausts
    // the entire 12-iteration budget with zero resolution on the exact
    // same pathology. 4 total iterations vs. complete non-convergence is
    // the real, quotable before/after number for this specific class of
    // bound-clamp-oscillation failure (the mechanism behind the real
    // hour-11 GAS-HOUR1-2-RETRY-CASCADE-001 failure this fix targets).
    try std.testing.expectEqual(@as(u16, 4), result.iterations);
}

test "without the boundary-oscillation detector the same ping-pong exhausts the budget unconverged" {
    var probe: BoundOscillationProbe = .{};
    try std.testing.expectError(error.NewtonPicardDidNotConverge, newtonPicard(
        &probe,
        BoundOscillationProbe.residual,
        BoundOscillationProbe.derivative,
        BoundOscillationProbe.fixedPoint,
        0,
        10,
        0,
        // A patience larger than the iteration ceiling can never trip,
        // isolating exactly what the old code (pre-detector) did.
        .{ .residual_scale = 1, .max_iterations = 12, .boundary_oscillation_patience = 1000 },
    ));
}

test "first fallback update is accelerated and never commits its relaxed seed" {
    const initial: f64 = 0.1;
    const relaxation: f64 = 0.5;
    const relaxed_seed = initial + relaxation * (slowPicard({}, initial) - initial);
    const result = try newtonPicard({}, slowResidual, unusableDerivative, slowPicard, 0, 1, initial, .{
        .picard_relaxation = relaxation,
        // One iteration accepts Anderson; the second is reserved for its
        // mandatory Newton retry before the final read-only publication gate.
        .max_iterations = 2,
        .residual_scale = 1,
    });
    try std.testing.expectEqual(@as(u16, 2), result.iterations);
    try std.testing.expectEqual(@as(u16, 1), result.anderson_steps);
    try std.testing.expect(@abs(result.root - relaxed_seed) > 1e-3);
    try std.testing.expectApproxEqAbs(slow_target, result.root, 1e-10);
}

const CeilingProbe = struct {
    residual_calls: usize = 0,
    derivative_calls: usize = 0,
    fixed_point_calls: usize = 0,
};

fn countedSlowResidual(probe: *CeilingProbe, x: f64) f64 {
    probe.residual_calls += 1;
    return slowResidual({}, x);
}

fn countedUnusableDerivative(probe: *CeilingProbe, x: f64) f64 {
    probe.derivative_calls += 1;
    return unusableDerivative({}, x);
}

fn countedSlowPicard(probe: *CeilingProbe, x: f64) f64 {
    probe.fixed_point_calls += 1;
    return slowPicard({}, x);
}

test "one-update ceiling performs no post-ceiling nonlinear recovery" {
    var probe: CeilingProbe = .{};
    try std.testing.expectError(error.NewtonPicardDidNotConverge, newtonPicard(
        &probe,
        countedSlowResidual,
        countedUnusableDerivative,
        countedSlowPicard,
        0,
        1,
        0.1,
        .{ .picard_relaxation = 0.5, .max_iterations = 1, .residual_scale = 1 },
    ));
    // One outer attempt: current residual and Newton derivative only. With no
    // retry slot, even the uncommitted Anderson seed is not evaluated.
    try std.testing.expectEqual(@as(usize, 1), probe.residual_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.derivative_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.fixed_point_calls);
}

fn exponentialResidual(_: void, x: f64) f64 {
    return @exp(x) - 2;
}
fn underestimatedExponentialDerivative(_: void, x: f64) f64 {
    return 0.1 * @exp(x);
}
fn exponentialFixedPoint(_: void, _: f64) f64 {
    return @log(2.0);
}

test "Newton uses damping when its full step is outside the physical bounds" {
    const result = try newtonPicard({}, exponentialResidual, underestimatedExponentialDerivative, exponentialFixedPoint, 0, 2, 0, .{
        .max_iterations = 30,
        .residual_scale = 1,
    });
    try std.testing.expectApproxEqAbs(@log(2.0), result.root, 1e-8);
    try std.testing.expect(result.newton_raphson_steps > 0);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
}

const RecoveryMethodEvent = enum { newton_attempt, anderson_sample };
const RecoveryOrderContext = struct {
    derivative_calls: usize = 0,
    events: [4]RecoveryMethodEvent = undefined,
    event_count: usize = 0,

    fn record(self: *RecoveryOrderContext, event: RecoveryMethodEvent) void {
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};
fn recoveryOrderResidual(_: *RecoveryOrderContext, x: f64) f64 {
    return x - 0.75;
}
fn recoveryOrderDerivative(context: *RecoveryOrderContext, _: f64) f64 {
    context.record(.newton_attempt);
    context.derivative_calls += 1;
    return if (context.derivative_calls == 1) 0 else 1;
}
fn recoveryOrderFixedPoint(context: *RecoveryOrderContext, x: f64) f64 {
    context.record(.anderson_sample);
    return x + 0.25 * (0.75 - x) * (1.0 + 0.1 * x);
}

test "a Newton failure takes one Anderson update then restarts Newton" {
    var context: RecoveryOrderContext = .{};
    const result = try newtonPicard(&context, recoveryOrderResidual, recoveryOrderDerivative, recoveryOrderFixedPoint, 0, 1, 0.1, .{ .residual_scale = 1 });
    try std.testing.expectEqual(@as(u16, 1), result.anderson_steps);
    try std.testing.expect(context.derivative_calls >= 2);
    try std.testing.expectEqual(@as(u16, 1), result.newton_raphson_steps);
    try std.testing.expectEqualSlices(
        RecoveryMethodEvent,
        &.{ .newton_attempt, .anderson_sample, .anderson_sample, .newton_attempt },
        context.events[0..context.event_count],
    );
    try std.testing.expectEqual(
        result.iterations,
        result.newton_raphson_steps + result.anderson_steps,
    );
}

const SeedMeritContext = struct {
    derivative_calls: u16 = 0,

    fn near(value: f64, expected: f64) bool {
        return @abs(value - expected) <= 1.0e-12;
    }
};

fn seedMeritResidual(_: *SeedMeritContext, x: f64) f64 {
    if (SeedMeritContext.near(x, 0)) return 10;
    if (SeedMeritContext.near(x, 0.5)) return 1;
    if (SeedMeritContext.near(x, 0.8)) return 2;
    if (SeedMeritContext.near(x, 1)) return 0;
    return 9;
}

fn seedMeritFixedPoint(_: *SeedMeritContext, x: f64) f64 {
    if (SeedMeritContext.near(x, 0)) return 1;
    if (SeedMeritContext.near(x, 0.5)) return 0.875;
    return x;
}

fn seedMeritDerivative(context: *SeedMeritContext, _: f64) f64 {
    context.derivative_calls += 1;
    return if (context.derivative_calls == 1) 0 else -10;
}

test "Anderson candidate competes with current not its uncommitted relaxed seed" {
    // The two Picard samples produce an accelerated x=0.8. Its residual 2 is
    // better than the current residual 10 but worse than the seed residual 1.
    // The seed is prohibited from publication, so x=0.8 must be accepted and
    // the reserved retry must return to Newton, which takes x=0.8 to root 1.
    var context: SeedMeritContext = .{};
    var budget: NonlinearBudget = .{ .limit = 2 };
    const result = try newtonPicard(
        &context,
        seedMeritResidual,
        seedMeritDerivative,
        seedMeritFixedPoint,
        -1,
        2,
        0,
        .{ .max_iterations = 2, .residual_scale = 10, .shared_budget = &budget },
    );
    try std.testing.expectEqual(@as(f64, 1), result.root);
    try std.testing.expectEqual(@as(u16, 1), result.anderson_steps);
    try std.testing.expectEqual(@as(u16, 1), result.picard_steps);
    try std.testing.expectEqual(@as(u16, 1), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 2), result.iterations);
    try std.testing.expectEqual(@as(u16, 2), budget.attempted_iterations);
    try std.testing.expectEqual(@as(u16, 2), context.derivative_calls);
}

test "rejected nonlinear attempts cannot escape a shared hard ceiling" {
    var context: SeedMeritContext = .{};
    var budget = try NonlinearBudget.init(1);
    const options: SolverOptions = .{
        .max_iterations = 1,
        .residual_scale = 10,
        .shared_budget = &budget,
    };
    try std.testing.expectError(error.NewtonPicardDidNotConverge, newtonPicard(
        &context,
        seedMeritResidual,
        seedMeritDerivative,
        seedMeritFixedPoint,
        -1,
        2,
        0,
        options,
    ));
    try std.testing.expectEqual(@as(u16, 1), budget.attempted_iterations);
    try std.testing.expectEqual(@as(u16, 1), context.derivative_calls);

    // A second solve sharing the same transaction budget may evaluate its
    // convergence gate, but it cannot attempt Newton or Anderson.
    try std.testing.expectError(error.NewtonPicardDidNotConverge, newtonPicard(
        &context,
        seedMeritResidual,
        seedMeritDerivative,
        seedMeritFixedPoint,
        -1,
        2,
        0,
        options,
    ));
    try std.testing.expectEqual(@as(u16, 1), budget.attempted_iterations);
    try std.testing.expectEqual(@as(u16, 1), context.derivative_calls);
}

test "vanilla Picard opt-out is rejected and Anderson recovery converges a crawling map" {
    const disabled: SolverOptions = .{
        .picard_relaxation = 0.5,
        .max_iterations = 30,
        .anderson_recovery = false,
        // Residual x - 0.75 is dimensionless and O(1) over the bracket [0, 1].
        .residual_scale = 1,
    };
    try std.testing.expectError(
        error.InvalidSolverOptions,
        newtonPicard({}, slowResidual, unusableDerivative, slowPicard, 0, 1, 0.1, disabled),
    );

    var accelerated = disabled;
    accelerated.anderson_recovery = true;
    const result = try newtonPicard({}, slowResidual, unusableDerivative, slowPicard, 0, 1, 0.1, accelerated);
    // The solve stops at its own residual tolerance, so assert against that
    // rather than something tighter than the solver ever promised.
    try std.testing.expect(@abs(result.residual) <= convergenceTolerance(accelerated));
    try std.testing.expectApproxEqAbs(slow_target, result.root, 1.0e-10);
    try std.testing.expect(result.anderson_steps > 0);
    try std.testing.expect(result.iterations < 30);
}

test "Anderson recovery leaves an already fast solve on its Newton path" {
    // Dimensionless residual, O(1) magnitude.
    const result = try newtonPicard({}, squareMinusTwo, squareMinusTwoDerivative, squareRootPicard, 0.1, 2.0, 1.8, .{ .residual_scale = 1 });
    try std.testing.expectApproxEqRel(@sqrt(2.0), result.root, 1.0e-10);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
}

// A repelling fixed-point map: every Picard step doubles the distance from the
// root and flips its sign, so the sequence oscillates outward. The residual
// grows without bound instead of ever satisfying the tolerance.
fn divergentResidual(_: void, x: f64) f64 {
    return x;
}
fn divergentPicard(_: void, x: f64) f64 {
    return -8.0 * x;
}

test "Anderson stabilizes a repelling fixed-point map without burning the ceiling" {
    const result = try newtonPicard({}, divergentResidual, unusableDerivative, divergentPicard, -1.0e12, 1.0e12, 1.0, .{
        .picard_relaxation = 1,
        .max_iterations = 4000,
        .divergence_patience = 3,
        .divergence_growth_factor = 10,
        .residual_scale = 1,
    });
    try std.testing.expectEqual(@as(f64, 0), result.root);
    try std.testing.expect(result.iterations < 4000);
    try std.testing.expectEqual(result.picard_steps, result.anderson_steps);
}

test "Newton-Picard rejects an unusable divergence watch" {
    // Dimensionless residual; both solves are rejected before any tolerance use.
    try std.testing.expectError(error.InvalidSolverOptions, newtonPicard({}, squareMinusTwo, squareMinusTwoDerivative, squareRootPicard, 0.1, 2.0, 1.0, .{ .divergence_patience = 0, .residual_scale = 1 }));
    try std.testing.expectError(error.InvalidSolverOptions, newtonPicard({}, squareMinusTwo, squareMinusTwoDerivative, squareRootPicard, 0.1, 2.0, 1.0, .{ .divergence_growth_factor = 0.5, .residual_scale = 1 }));
}

test "divergence patience counts consecutive explosions and resets after recovery" {
    const options: SolverOptions = .{
        .divergence_patience = 3,
        .divergence_growth_factor = 10,
        .residual_scale = 1,
    };
    var best = std.math.inf(f64);
    var consecutive: u16 = 0;
    try std.testing.expect(!residualExplosionExceededPatience(1, 1.0e-9, options, &best, &consecutive));
    try std.testing.expect(!residualExplosionExceededPatience(20, 1.0e-9, options, &best, &consecutive));
    try std.testing.expectEqual(@as(u16, 1), consecutive);
    // A recoverable single overshoot is not divergence and resets patience.
    try std.testing.expect(!residualExplosionExceededPatience(2, 1.0e-9, options, &best, &consecutive));
    try std.testing.expectEqual(@as(u16, 0), consecutive);
    try std.testing.expect(!residualExplosionExceededPatience(20, 1.0e-9, options, &best, &consecutive));
    try std.testing.expect(!residualExplosionExceededPatience(30, 1.0e-9, options, &best, &consecutive));
    try std.testing.expect(residualExplosionExceededPatience(40, 1.0e-9, options, &best, &consecutive));
}

test "stagnation patience routes only after consecutive scaled non-progress" {
    const options: SolverOptions = .{
        .residual_scale = 10,
        .stagnation_patience = 3,
    };
    var previous = std.math.inf(f64);
    var consecutive: u16 = 0;
    try std.testing.expect(!residualProgressStagnated(10, options, &previous, &consecutive));
    try std.testing.expect(!residualProgressStagnated(9, options, &previous, &consecutive));
    const tiny = std.math.sqrt(std.math.floatEps(f64));
    try std.testing.expect(!residualProgressStagnated(9 - tiny, options, &previous, &consecutive));
    // A material recovery breaks the sequence before another three tiny
    // accepted improvements finally route the solve to Anderson.
    try std.testing.expect(!residualProgressStagnated(8, options, &previous, &consecutive));
    try std.testing.expect(!residualProgressStagnated(8 - tiny, options, &previous, &consecutive));
    try std.testing.expect(!residualProgressStagnated(8 - 2 * tiny, options, &previous, &consecutive));
    try std.testing.expect(residualProgressStagnated(8 - 3 * tiny, options, &previous, &consecutive));
}

test "stagnation scale does not preempt a converging enthalpy residual above tolerance" {
    const options: SolverOptions = .{
        // Enthalpy inversion intentionally uses an O(1 MJ) characteristic
        // scale while resolving a roughly 1e-11 MJ physical acceptance band.
        .absolute_tolerance = 1.0e-13,
        .relative_tolerance = 1.0e-11,
        .residual_scale = 1,
        .stagnation_patience = 3,
    };
    const tolerance = convergenceTolerance(options);
    try std.testing.expect(tolerance < 2.0e-11);
    var previous = std.math.inf(f64);
    var consecutive: u16 = 0;
    try std.testing.expect(!residualProgressStagnated(5.0e-8, options, &previous, &consecutive));
    // Each 1e-9 MJ reduction is physically material and remains well above
    // tolerance. The old sqrt(eps)*residual_scale floor (~1.49e-8 MJ)
    // incorrectly counted all three as stagnation.
    try std.testing.expect(!residualProgressStagnated(4.9e-8, options, &previous, &consecutive));
    try std.testing.expect(!residualProgressStagnated(4.8e-8, options, &previous, &consecutive));
    try std.testing.expect(!residualProgressStagnated(4.7e-8, options, &previous, &consecutive));
    try std.testing.expectEqual(@as(u16, 0), consecutive);
}

// Adversarial regression: a consistent Picard map (its fixed point is the root)
// whose stiffness is strongly asymmetric about the root. Above the root the
// map moves briskly; below it the map is a much slower contraction. The slow
// side remains movable, so a genuine Anderson history can recover after an
// overshoot without ever publishing a raw or relaxed Picard image.
const kink_root: f64 = 1.0;
fn kinkResidual(_: void, x: f64) f64 {
    return x - kink_root;
}
fn kinkPicard(_: void, x: f64) f64 {
    if (x >= kink_root) return kink_root + 0.05 * (x - kink_root) * (x - kink_root);
    return x + 0.02 * (kink_root - x);
}

test "safeguarded Anderson recovery handles an asymmetric fixed-point map" {
    const options: SolverOptions = .{
        .picard_relaxation = 0.9,
        .max_iterations = 40,
        // Residual x - 1 is dimensionless and O(1) near the root.
        .residual_scale = 1,
    };
    const recovered = try newtonPicard({}, kinkResidual, unusableDerivative, kinkPicard, 0, 10.0, 3.0, options);
    try std.testing.expectApproxEqAbs(kink_root, recovered.root, 1.0e-8);
    try std.testing.expect(recovered.anderson_steps > 0);
    try std.testing.expectEqual(recovered.picard_steps, recovered.anderson_steps);
    try std.testing.expect(recovered.iterations < options.max_iterations);
}

// A legitimately slow but genuinely converging contraction: each Picard call
// closes 2% of the remaining gap and the caller relaxes that to 1%, so the
// residual falls monotonically by a hair per iteration. Nothing here diverges
// or oscillates, so the divergence watch must stay silent no matter how many
// iterations the solve spends crawling. Production decks contain solves of
// exactly this shape and a spurious error.NewtonPicardDiverged would break
// them.
const crawl_target: f64 = 0.6;
fn crawlResidual(_: void, x: f64) f64 {
    return x - crawl_target;
}
fn crawlPicard(_: void, x: f64) f64 {
    return x + 0.02 * (crawl_target - x);
}

test "divergence watch stays silent on a slow but converging contraction" {
    const options: SolverOptions = .{
        .picard_relaxation = 0.5,
        .max_iterations = 3000,
        // Deliberately hostile watch settings: the tightest patience the
        // options allow and no tolerated growth at all.
        .divergence_patience = 1,
        .divergence_growth_factor = 1,
        // Residual x - 0.6 is dimensionless and O(1) over the bracket [0, 1].
        .residual_scale = 1,
    };
    const result = try newtonPicard({}, crawlResidual, unusableDerivative, crawlPicard, 0, 1.0, 0.1, options);
    try std.testing.expectApproxEqAbs(crawl_target, result.root, 1.0e-8);
    try std.testing.expect(result.anderson_steps > 0);
}

test "Anderson history is dropped when a Newton step is accepted" {
    // Newton owns the first steps here, so no history can survive to be used
    // against a stale iterate, and the Anderson counter must stay at zero while
    // the step accounting still adds up.
    // Dimensionless residual, O(1) magnitude.
    const result = try newtonPicard({}, squareMinusTwo, squareMinusTwoDerivative, squareRootPicard, 0.1, 2.0, 1.8, .{ .max_iterations = 60, .residual_scale = 1 });
    try std.testing.expect(result.newton_raphson_steps > 0);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
    // Failed Newton retries consume a method iteration but never masquerade as
    // accepted Newton/Anderson state promotions.
    try std.testing.expect(
        result.newton_raphson_steps + result.anderson_steps <= result.iterations,
    );
    try std.testing.expect(result.anderson_steps <= result.picard_steps);
}

test "anderson_steps accounting stays inside picard_steps" {
    const options: SolverOptions = .{
        .picard_relaxation = 0.5,
        .max_iterations = 30,
        // Residual x - 0.75 is dimensionless and O(1) over the bracket [0, 1].
        .residual_scale = 1,
    };
    const result = try newtonPicard({}, slowResidual, unusableDerivative, slowPicard, 0, 1, 0.1, options);
    try std.testing.expect(result.anderson_steps > 0);
    try std.testing.expect(result.anderson_steps <= result.picard_steps);
    try std.testing.expectEqual(@as(u16, 0), result.newton_raphson_steps);
    try std.testing.expect(result.anderson_steps <= result.iterations);
}
