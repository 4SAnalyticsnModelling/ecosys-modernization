//! Thread-local control for SOLUTE diagnostic emission.
//!
//! This module owns no scientific state. Suppression is scoped to the calling
//! thread so parallel cell solves cannot silence coordinator diagnostics or
//! diagnostics from another worker.

const std = @import("std");
const builtin = @import("builtin");

/// The fine-grained counters below sit on the innermost reaction-evaluation
/// paths and can execute millions of times for one cell solve. Keep them for
/// tests and diagnostic builds, but compile them out of the production
/// ReleaseFast binary. They do not participate in solver state or acceptance.
pub const runtime_profiling_enabled = builtin.is_test or builtin.mode != .ReleaseFast;

threadlocal var enabled = true;

pub fn isEnabled() bool {
    return enabled;
}

// ---------------------------------------------------------------------------
// TEMPORARY exclusive phase profiler (2026-09-10 runtime-cost investigation).
//
// The two evaluation counters below only observe `transformedVector` and the
// full-network residual. Neither sees the LOCAL candidate targets
// (`reaction_surface_minerals.Context.evaluate`,
// `reaction_surface_charge`), which run a 26-coordinate central-difference
// Jacobian (52 target evaluations per local Newton iteration) on every outer
// iteration. Attribution of the measured per-hour cost therefore needs an
// independent, exclusive wall-clock split.
//
// `phase_profiling_enabled` is `false` in every shipped build, so all of this
// compiles away. It is flipped only for a measurement build, exactly like the
// rejected `runtime_profiling_enabled = true` patch must NOT be.
//
// Timing uses the x86-64 timestamp counter rather than a clock syscall: at
// roughly 10 cycles per read it perturbs a ~1 us leaf far less than
// `QueryPerformanceCounter`. Only ratios and one externally measured total are
// reported, so an unspecified TSC frequency is not a correctness problem.
// ---------------------------------------------------------------------------
pub const phase_profiling_enabled = false;

pub const Phase = enum {
    solve_root,
    local_mineral_candidate,
    local_mineral_target,
    local_mineral_dense_solve,
    local_charge_candidate,
    surface_charge_target,
    exchange_equilibrium,
    activity_coefficients,
    physical_quality,
    full_network_residual,
    transformed_vector,
    full_network_candidate,
    retained_complementarity,
    coordinate_newton,
    active_row_newton,
    ternary_correction_face,
    coordinate_anderson,
    phosphate_extent,
    boundary_recovery,
    newton_line_search,
    anderson_acceptance,
    inventory_ledger,
};

const phase_count = @typeInfo(Phase).@"enum".fields.len;
threadlocal var phase_cycles: [phase_count]u64 = @splat(0);
threadlocal var phase_calls: [phase_count]u64 = @splat(0);
threadlocal var solve_total_cycles: u64 = 0;

pub inline fn tick() u64 {
    if (!phase_profiling_enabled) return 0;
    if (builtin.cpu.arch != .x86_64) return 0;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | @as(u64, low);
}

// Exclusive self-time accounting. Entering a nested phase first charges the
// enclosing phase for the cycles it has spent so far, so a leaf's cost is
// never also attributed to its caller and the reported percentages sum to at
// most 100.
threadlocal var phase_stack: [32]Phase = @splat(.local_mineral_candidate);
threadlocal var phase_stack_start: [32]u64 = @splat(0);
threadlocal var phase_depth: usize = 0;

pub const PhaseScope = struct {
    active: bool,

    pub inline fn end(self: *PhaseScope) void {
        if (!phase_profiling_enabled or !self.active) return;
        self.active = false;
        const now = tick();
        const top = phase_depth - 1;
        phase_cycles[@intFromEnum(phase_stack[top])] +|=
            now -| phase_stack_start[top];
        phase_depth = top;
        if (phase_depth > 0) phase_stack_start[phase_depth - 1] = now;
    }
};

pub inline fn beginPhase(phase: Phase) PhaseScope {
    if (!phase_profiling_enabled) return .{ .active = false };
    if (phase_depth >= phase_stack.len) return .{ .active = false };
    const now = tick();
    if (phase_depth > 0) {
        const top = phase_depth - 1;
        phase_cycles[@intFromEnum(phase_stack[top])] +|=
            now -| phase_stack_start[top];
    }
    phase_stack[phase_depth] = phase;
    phase_stack_start[phase_depth] = now;
    phase_depth += 1;
    phase_calls[@intFromEnum(phase)] +|= 1;
    return .{ .active = true };
}

pub fn resetPhaseProfile() void {
    if (!phase_profiling_enabled) return;
    phase_cycles = @splat(0);
    phase_calls = @splat(0);
    solve_total_cycles = 0;
    phase_depth = 0;
}

pub fn recordSolveTotalCycles(start: u64) void {
    if (!phase_profiling_enabled) return;
    solve_total_cycles +|= tick() -| start;
}

pub fn reportPhaseProfile(cell_index: usize) void {
    if (!phase_profiling_enabled) return;
    var attributed: u64 = 0;
    for (phase_cycles) |value| attributed +|= value;
    const total: f64 = @floatFromInt(@max(1, solve_total_cycles));
    std.log.err(
        "TEMPPROF_SOLUTE_PHASE_PROFILE cell={d} total_cycles={d} attributed_cycles={d} unattributed_percent={d:.2}",
        .{
            cell_index,
            solve_total_cycles,
            attributed,
            100 * (total - @as(f64, @floatFromInt(attributed))) / total,
        },
    );
    inline for (@typeInfo(Phase).@"enum".fields) |field| {
        const index = field.value;
        std.log.err(
            "TEMPPROF_SOLUTE_PHASE phase={s} calls={d} cycles={d} percent={d:.2} cycles_per_call={d}",
            .{
                field.name,
                phase_calls[index],
                phase_cycles[index],
                100 * @as(f64, @floatFromInt(phase_cycles[index])) / total,
                if (phase_calls[index] == 0) 0 else phase_cycles[index] / phase_calls[index],
            },
        );
    }
}

// Runtime-cost investigation counters (physical-acceptance goal, 2026-09-03):
// cheap call-count proxies for the two primitives every candidate-generation
// strategy in `reaction_solve.zig` ultimately funnels through, so a single
// per-layer cell solve's cost can be attributed without threading `Io`
// timing through the whole reaction-network call graph. Not scientific
// state; read/reset only from diagnostic call sites.
threadlocal var full_network_evaluation_count: u64 = 0;
threadlocal var reaction_span_evaluation_count: u64 = 0;
threadlocal var active_strategy: ?Strategy = null;
threadlocal var strategy_full_network_evaluation_counts: [@typeInfo(Strategy).@"enum".fields.len]u64 = @splat(0);
threadlocal var strategy_reaction_span_evaluation_counts: [@typeInfo(Strategy).@"enum".fields.len]u64 = @splat(0);

pub fn recordFullNetworkEvaluation() void {
    if (!runtime_profiling_enabled) return;
    full_network_evaluation_count +|= 1;
    if (active_strategy) |strategy|
        strategy_full_network_evaluation_counts[@intFromEnum(strategy)] +|= 1;
}

pub fn recordReactionSpanEvaluation() void {
    if (!runtime_profiling_enabled) return;
    reaction_span_evaluation_count +|= 1;
    if (active_strategy) |strategy|
        strategy_reaction_span_evaluation_counts[@intFromEnum(strategy)] +|= 1;
}

pub const EvaluationCounts = struct {
    full_network: u64,
    reaction_span: u64,
};

pub fn resetEvaluationCounts() void {
    if (!runtime_profiling_enabled) return;
    full_network_evaluation_count = 0;
    reaction_span_evaluation_count = 0;
    strategy_full_network_evaluation_counts = @splat(0);
    strategy_reaction_span_evaluation_counts = @splat(0);
}

pub fn evaluationCounts() EvaluationCounts {
    return .{ .full_network = full_network_evaluation_count, .reaction_span = reaction_span_evaluation_count };
}

/// Attributes the expensive, state-dependent reaction-extent bounds search
/// to its production caller.  Aggregate evaluation totals showed that this
/// search dominates STARTE, but the five strategies invoke it with different
/// states and frequencies; a caller tag is required before any safe caching
/// or pruning decision can be made.
pub const ReactionSpanBoundsSite = enum {
    active_boundary_surface,
    active_row_newton,
    analytic_coordinate_newton,
    current_sign_coordinate_anderson,
    full_network_axes,
};

pub const ReactionSpanBoundsSiteStats = struct {
    calls: u64,
    full_network_evaluations: u64,
    reaction_span_evaluations: u64,
};

threadlocal var reaction_span_bounds_site_calls: [@typeInfo(ReactionSpanBoundsSite).@"enum".fields.len]u64 = @splat(0);
threadlocal var reaction_span_bounds_site_full_network_evaluations: [@typeInfo(ReactionSpanBoundsSite).@"enum".fields.len]u64 = @splat(0);
threadlocal var reaction_span_bounds_site_reaction_span_evaluations: [@typeInfo(ReactionSpanBoundsSite).@"enum".fields.len]u64 = @splat(0);

pub fn resetReactionSpanBoundsSiteStats() void {
    reaction_span_bounds_site_calls = @splat(0);
    reaction_span_bounds_site_full_network_evaluations = @splat(0);
    reaction_span_bounds_site_reaction_span_evaluations = @splat(0);
}

pub fn recordReactionSpanBoundsSite(
    site: ReactionSpanBoundsSite,
    before: EvaluationCounts,
) void {
    if (!runtime_profiling_enabled) return;
    const index = @intFromEnum(site);
    reaction_span_bounds_site_calls[index] +|= 1;
    reaction_span_bounds_site_full_network_evaluations[index] +|=
        full_network_evaluation_count -| before.full_network;
    reaction_span_bounds_site_reaction_span_evaluations[index] +|=
        reaction_span_evaluation_count -| before.reaction_span;
}

pub fn reactionSpanBoundsSiteStats(
    site: ReactionSpanBoundsSite,
) ReactionSpanBoundsSiteStats {
    const index = @intFromEnum(site);
    return .{
        .calls = reaction_span_bounds_site_calls[index],
        .full_network_evaluations = reaction_span_bounds_site_full_network_evaluations[index],
        .reaction_span_evaluations = reaction_span_bounds_site_reaction_span_evaluations[index],
    };
}

/// Per-candidate-strategy call counts, added specifically to localize which
/// strategy in `reaction_solve.zig`'s per-iteration multi-strategy search
/// generates the (already confirmed, ~55x `full_network_evaluations`)
/// `reaction_span_evaluations` volume -- deliberately counting CALLS, not
/// evaluations, at each strategy's own function entry, since inserting
/// evaluation-count snapshots deep inside the dense, label-block-controlled
/// iteration loop in `reaction_solve.zig` risks being skipped by an early
/// `break` or misplaced relative to brace nesting. Combined with the
/// existing evaluation counters above (read at the same reset points), a
/// strategy called few times whose total still correlates with a huge
/// `reaction_span_evaluations` jump is the one doing the internal bisection.
pub const Strategy = enum {
    full_network_newton,
    retained_complementarity,
    analytic_coordinate_newton,
    phosphate_extent,
    global_inventory_boundary_recovery,
    active_boundary_surface_recovery,
    active_row_newton,
    ternary_correction_face,
    current_sign_coordinate_anderson,
};
threadlocal var strategy_call_counts: [@typeInfo(Strategy).@"enum".fields.len]u64 = @splat(0);

pub fn recordStrategyCall(strategy: Strategy) void {
    if (!runtime_profiling_enabled) return;
    strategy_call_counts[@intFromEnum(strategy)] +|= 1;
}

pub const StrategyScope = struct {
    previous: ?Strategy,
    active: bool = true,

    pub fn deinit(self: *StrategyScope) void {
        if (!self.active) return;
        active_strategy = self.previous;
        self.active = false;
    }
};

/// Marks evaluation work performed exclusively by one candidate strategy.
/// Nested recovery strategies temporarily replace the tag and restore their
/// parent on return, avoiding the double-counting that made earlier aggregate
/// call-tree estimates ambiguous.
pub fn enterStrategy(strategy: Strategy) StrategyScope {
    if (!runtime_profiling_enabled)
        return .{ .previous = null, .active = false };
    const previous = active_strategy;
    active_strategy = strategy;
    return .{ .previous = previous };
}

pub fn strategyEvaluationCounts(strategy: Strategy) EvaluationCounts {
    const index = @intFromEnum(strategy);
    return .{
        .full_network = strategy_full_network_evaluation_counts[index],
        .reaction_span = strategy_reaction_span_evaluation_counts[index],
    };
}

pub fn resetStrategyCallCounts() void {
    strategy_call_counts = @splat(0);
}

pub fn strategyCallCount(strategy: Strategy) u64 {
    return strategy_call_counts[@intFromEnum(strategy)];
}

/// Accepted nonlinear iterate families.  This deliberately mirrors the
/// solver's private `CandidateKind` without importing it: importing the public
/// solver types here would create a cycle through `reaction_solve.zig`.
pub const SelectedCandidate = enum {
    surface_mineral_newton,
    surface_charge_newton,
    converged,
    full_network_newton,
    inventory_boundary_newton,
    phosphate_extent_newton,
    anderson_depth_two,
    anderson_depth_one,
    directional_newton,
    coordinate_newton,
    coordinate_anderson,
};

threadlocal var selected_candidate_counts: [@typeInfo(SelectedCandidate).@"enum".fields.len]u64 = @splat(0);

pub fn resetSelectedCandidateCounts() void {
    selected_candidate_counts = @splat(0);
}

pub fn recordSelectedCandidate(candidate: SelectedCandidate) void {
    if (!runtime_profiling_enabled) return;
    selected_candidate_counts[@intFromEnum(candidate)] +|= 1;
}

pub fn selectedCandidateCount(candidate: SelectedCandidate) u64 {
    return selected_candidate_counts[@intFromEnum(candidate)];
}

// Tracks how deep `transformedVectorAdmissibleWithMonovalentActivityCoefficient`'s
// own backtracking loop (bounded at `maximum_admissibility_backtracks=1075`
// in `reaction_solver_numerics2.zig`) actually runs in production, since
// that bound -- not any of the reaction-span bisection paths -- is the one
// remaining unverified hypothesis for the ~15-20x gap between traced-code
// worst case and the measured `reaction_span_evaluations` total.
threadlocal var admissibility_backtrack_calls: u64 = 0;
threadlocal var admissibility_backtrack_total_attempts: u64 = 0;
threadlocal var admissibility_backtrack_max_attempts: u64 = 0;

pub fn recordAdmissibilityBacktrackDepth(attempts: u64) void {
    if (!runtime_profiling_enabled) return;
    admissibility_backtrack_calls +|= 1;
    admissibility_backtrack_total_attempts +|= attempts;
    if (attempts > admissibility_backtrack_max_attempts)
        admissibility_backtrack_max_attempts = attempts;
}

pub const AdmissibilityBacktrackStats = struct {
    calls: u64,
    total_attempts: u64,
    max_attempts: u64,
};

pub fn resetAdmissibilityBacktrackStats() void {
    admissibility_backtrack_calls = 0;
    admissibility_backtrack_total_attempts = 0;
    admissibility_backtrack_max_attempts = 0;
}

pub fn admissibilityBacktrackStats() AdmissibilityBacktrackStats {
    return .{
        .calls = admissibility_backtrack_calls,
        .total_attempts = admissibility_backtrack_total_attempts,
        .max_attempts = admissibility_backtrack_max_attempts,
    };
}

pub const SuppressionGuard = struct {
    previous: bool,
    active: bool = true,

    pub fn restore(self: *SuppressionGuard) void {
        if (!self.active) return;
        enabled = self.previous;
        self.active = false;
    }

    pub fn deinit(self: *SuppressionGuard) void {
        self.restore();
    }
};

pub fn suppress() SuppressionGuard {
    const previous = enabled;
    enabled = false;
    return .{ .previous = previous };
}

test "solute diagnostics default enabled and nested suppression restores exactly" {
    try std.testing.expect(isEnabled());
    var outer = suppress();
    try std.testing.expect(!isEnabled());
    var inner = suppress();
    try std.testing.expect(!isEnabled());
    inner.restore();
    try std.testing.expect(!isEnabled());
    outer.restore();
    try std.testing.expect(isEnabled());
    // Restore is deliberately idempotent so cleanup cannot overwrite a later
    // scope's state after an explicit early restoration.
    outer.restore();
    try std.testing.expect(isEnabled());
}

test "solute diagnostic suppression is isolated between threads" {
    var suppressed_ready: std.atomic.Value(bool) = .init(false);
    var release_suppressed: std.atomic.Value(bool) = .init(false);
    var suppressed_observed = true;
    var suppressed_restored = false;
    var observer_observed = false;

    const Worker = struct {
        fn suppressed(
            ready: *std.atomic.Value(bool),
            release: *std.atomic.Value(bool),
            observed: *bool,
            restored: *bool,
        ) void {
            var guard = suppress();
            observed.* = isEnabled();
            ready.store(true, .release);
            while (!release.load(.acquire)) std.Thread.yield() catch {};
            guard.restore();
            restored.* = isEnabled();
        }

        fn observer(
            ready: *std.atomic.Value(bool),
            observed: *bool,
        ) void {
            while (!ready.load(.acquire)) std.Thread.yield() catch {};
            observed.* = isEnabled();
        }
    };

    const suppressing_thread = try std.Thread.spawn(.{}, Worker.suppressed, .{
        &suppressed_ready,
        &release_suppressed,
        &suppressed_observed,
        &suppressed_restored,
    });
    const observing_thread = try std.Thread.spawn(.{}, Worker.observer, .{
        &suppressed_ready,
        &observer_observed,
    });
    observing_thread.join();
    release_suppressed.store(true, .release);
    suppressing_thread.join();

    try std.testing.expect(!suppressed_observed);
    try std.testing.expect(suppressed_restored);
    try std.testing.expect(observer_observed);
    try std.testing.expect(isEnabled());
}
