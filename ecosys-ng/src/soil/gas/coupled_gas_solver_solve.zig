//! `coupled_gas_solver` declarations: solve.
//!
//! Split out of `coupled_gas_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const gas = @import("transport.zig");
const atmosphere = @import("atmosphere_exchange.zig");
const numerics = @import("../../core/numerics.zig");
const group_diagnostics = @import("coupled_gas_solver_diagnostics.zig");
const group_directions = @import("coupled_gas_solver_directions.zig");
const group_misc = @import("coupled_gas_solver_misc.zig");
const group_newton_steps = @import("coupled_gas_solver_newton_steps.zig");
const group_residual = @import("coupled_gas_solver_residual.zig");
const group_validation = @import("coupled_gas_solver_validation.zig");

/// Forms a depth-`history.len + 1` Anderson extrapolate from the accepted
/// iterate history (oldest first) plus the fresh evaluated Picard seed, then
/// backtracks that extrapolate toward the seed just enough to remain inside
/// the nonnegative inventory domain. The seed itself is never returned: a
/// candidate indistinguishable from the seed is rejected, preserving the
/// production invariant that vanilla Picard cannot be committed.
///
/// `history`/`history_defects` hold at most `numerics.anderson_max_depth`
/// older accepted (state, defect) pairs; with zero history this reduces
/// exactly to the original depth-1 secant.
fn nonnegativeDampedAndersonCandidate(
    history: []const []f64,
    history_defects: []const []f64,
    seed: []const f64,
    seed_defect: []const f64,
    output: []f64,
) bool {
    var points_buffer: [numerics.anderson_max_depth + 1][]const f64 = undefined;
    var defects_buffer: [numerics.anderson_max_depth + 1][]const f64 = undefined;
    if (history.len > numerics.anderson_max_depth or history_defects.len != history.len) return false;
    @memcpy(points_buffer[0..history.len], history);
    @memcpy(defects_buffer[0..history.len], history_defects);
    points_buffer[history.len] = seed;
    defects_buffer[history.len] = seed_defect;
    if (!numerics.andersonDepthMCandidate(
        points_buffer[0 .. history.len + 1],
        defects_buffer[0 .. history.len + 1],
        output,
    )) return false;
    var damping: f64 = 1;
    for (seed, output) |seeded, accelerated| {
        if (!std.math.isFinite(seeded) or seeded < 0 or !std.math.isFinite(accelerated)) return false;
        if (accelerated < 0) {
            if (seeded <= 0) return false;
            const admissible = seeded / (seeded - accelerated);
            if (!std.math.isFinite(admissible) or admissible <= 0) return false;
            damping = @min(damping, 0.5 * admissible);
        }
    }
    if (damping < 1) {
        for (output, seed) |*accelerated, seeded|
            accelerated.* = seeded + damping * (accelerated.* - seeded);
    }
    var differs_from_seed = false;
    for (output, seed) |accelerated, seeded| {
        if (!std.math.isFinite(accelerated) or accelerated < 0) return false;
        if (accelerated != seeded) differs_from_seed = true;
    }
    return differs_from_seed;
}

/// Appends `(state, defect)` to a fixed-capacity FIFO ring buffer of the last
/// `depth` accepted Anderson-attempt iterates (oldest first), evicting the
/// oldest entry once full. `states`/`defects` are pre-allocated,
/// `unknown_count`-sized scratch slots owned by the caller.
fn pushAndersonHistory(
    states: [][]f64,
    defects: [][]f64,
    len: *usize,
    depth: usize,
    state: []const f64,
    defect: []const f64,
) void {
    if (len.* < depth) {
        @memcpy(states[len.*], state);
        @memcpy(defects[len.*], defect);
        len.* += 1;
        return;
    }
    var slot: usize = 0;
    while (slot + 1 < depth) : (slot += 1) {
        @memcpy(states[slot], states[slot + 1]);
        @memcpy(defects[slot], defects[slot + 1]);
    }
    @memcpy(states[depth - 1], state);
    @memcpy(defects[depth - 1], defect);
}

const SolverEvent = enum { publication_reject, newton_attempt, anderson_attempt };

const SolverTrace = struct {
    events: [16]SolverEvent = undefined,
    len: usize = 0,
    iterations_entered: u16 = 0,
    invalid_publication_rejections: u16 = 0,
    rejected_iterate_norm: ?f64 = null,
    rejected_publication_norm: ?f64 = null,
    force_speculative_iteration: ?u16 = null,
    reject_speculative_anderson: bool = false,
    speculative_anderson_attempts: u16 = 0,
    next_slot_newton_retries: u16 = 0,
    speculative_anderson_iteration: ?u16 = null,
    next_slot_newton_retry_iteration: ?u16 = null,

    fn append(self: *SolverTrace, event: SolverEvent) void {
        if (self.len < self.events.len) {
            self.events[self.len] = event;
            self.len += 1;
        }
    }
};

const slow_newton_progress_window_updates: u16 = 4;
const slow_newton_progress_history_length: usize =
    slow_newton_progress_window_updates + 1;
const slow_newton_recovery_reserve: u16 = 7;

fn rememberNewtonNorm(
    history: *[slow_newton_progress_history_length]f64,
    count: *u8,
    norm: f64,
) void {
    if (count.* < history.len) {
        history[@intCast(count.*)] = norm;
        count.* += 1;
        return;
    }
    std.mem.copyForwards(f64, history[0 .. history.len - 1], history[1..]);
    history[history.len - 1] = norm;
}

/// A bounded, unitless contraction forecast. It never changes the nonlinear
/// merit or its acceptance gate: it only asks whether the observed accepted-
/// Newton trajectory can reach `norm <= 1` before the hard ceiling while an
/// Anderson update and its mandatory Newton retry still fit.
fn slowNewtonProgressNeedsRecovery(
    window_start_norm: f64,
    current_norm: f64,
    observed_newton_updates: u16,
    remaining_updates: u16,
) bool {
    if (observed_newton_updates < slow_newton_progress_window_updates or
        remaining_updates < 2 or
        !std.math.isFinite(window_start_norm) or
        !std.math.isFinite(current_norm) or
        window_start_norm <= 0 or
        current_norm <= 1)
        return false;
    if (current_norm >= window_start_norm) return true;

    const observed_log_contraction =
        @log(window_start_norm) - @log(current_norm);
    if (!std.math.isFinite(observed_log_contraction) or
        observed_log_contraction <= 0)
        return true;
    const mean_log_contraction = observed_log_contraction /
        @as(f64, @floatFromInt(observed_newton_updates));
    const forecast_log_norm = @log(current_norm) - mean_log_contraction *
        @as(f64, @floatFromInt(remaining_updates));
    return !std.math.isFinite(forecast_log_norm) or forecast_log_norm > 0;
}

/// A decrease smaller than floating-point resolution on the tolerance-scaled
/// residual is not usable nonlinear progress. Requiring four consecutive
/// near-no-op publications avoids classifying one rounded line-search step as
/// stagnation while still stopping a crawling fixed-point sequence early.
fn hasMeaningfulScaledProgress(previous_norm: f64, current_norm: f64) bool {
    if (!std.math.isFinite(previous_norm) or !std.math.isFinite(current_norm)) return false;
    const progress_floor = @sqrt(std.math.floatEps(f64)) * @max(1, previous_norm);
    return previous_norm - current_norm > progress_floor;
}

/// Updates the generic stagnation watch without preempting the mandatory
/// Newton inspection of an accepted Anderson state. Divergence and invalid
/// residual checks remain earlier fail-fast gates; only repeated slow progress
/// is deferred for this one policy-required retry.
fn coupledGasSlowProgressExceededPatience(
    previous_norm: f64,
    current_norm: f64,
    retrying_newton_after_anderson: bool,
    slow_progress_count: *u8,
) bool {
    if (hasMeaningfulScaledProgress(previous_norm, current_norm)) {
        slow_progress_count.* = 0;
        return false;
    }
    slow_progress_count.* +|= 1;
    return slow_progress_count.* >= 4 and !retrying_newton_after_anderson;
}

fn coupledResidualExplosionExceededPatience(
    scaled_residual: f64,
    options: group_misc.Options,
    best_scaled_residual: *f64,
    explosive_update_count: *u16,
) bool {
    if (scaled_residual < best_scaled_residual.*) {
        best_scaled_residual.* = scaled_residual;
        explosive_update_count.* = 0;
        return false;
    }
    if (scaled_residual > options.divergence_growth_factor *
        @max(best_scaled_residual.*, 1))
    {
        explosive_update_count.* +|= 1;
        return explosive_update_count.* >= options.divergence_patience;
    }
    explosive_update_count.* = 0;
    return false;
}

/// Returns the nonlinear residual of the exact conservative state that would
/// be published, `F(current)`.  Convergence of `current` alone is insufficient:
/// the scale denominator and the nonlinear map are both evaluated at the
/// published state, so `F(current)` can fail tolerance even when `current`
/// passes it.  The caller retains `assembled_target` unchanged for exact flux
/// ledger capture after this read-only verification succeeds.  An inadmissible
/// image of the publication candidate is a rejected, unpublished nonlinear
/// trial, not an invalid authoritative state; `null` tells the caller to keep
/// iterating from its unchanged current iterate.
fn conservativePublicationNorm(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    inputs: group_misc.Inputs,
    transport_iteration_fraction: f64,
    assembled_target: []const f64,
    publication_candidate: []f64,
    publication_target: []f64,
    publication_residual: []f64,
    options: group_misc.Options,
    iteration: u16,
    force_invalid_for_test: bool,
) !?f64 {
    @memcpy(publication_candidate, assembled_target);
    const probe_result: anyerror!void = if (force_invalid_for_test) forced: {
        @memcpy(publication_target, publication_candidate);
        publication_target[0] = -1;
        break :forced error.InvalidCoupledGasCandidate;
    } else group_residual.residualAt(
        allocator,
        scratch,
        base,
        publication_candidate,
        inputs,
        transport_iteration_fraction,
        publication_target,
        publication_residual,
    );
    probe_result catch |err| switch (err) {
        error.InvalidCoupledGasCandidate => {
            const inventory_count = publication_candidate.len / 3;
            for (publication_target, 0..) |mapped, index| {
                if (std.math.isFinite(mapped) and mapped >= 0) continue;
                const component = index % inventory_count;
                if (options.emit_failure_diagnostics) std.log.warn(
                    "coupled gas solver rejected invalid publication image: iteration={d} phase={d} cell={d} species={d} candidate_g={e} mapped_g={e}",
                    .{ iteration, index / inventory_count, component / gas.species_count, component % gas.species_count, publication_candidate[index], mapped },
                );
                return null;
            }
            if (options.emit_failure_diagnostics)
                std.log.warn("coupled gas solver rejected invalid publication image: iteration={d} coordinate=unavailable", .{iteration});
            return null;
        },
        else => return err,
    };
    return @as(?f64, try group_diagnostics.scaledNorm(
        publication_candidate,
        publication_residual,
        options,
    ));
}

const physically_conserved_publication_scaled_ceiling: f64 = 1.25;

fn acceptsConservativePublication(verified_norm: f64, options: group_misc.Options) bool {
    return std.math.isFinite(verified_norm) and
        (verified_norm <= 1 or
            (options.accept_physically_conserved_ceiling and
                verified_norm <= physically_conserved_publication_scaled_ceiling));
}

test "conservative publication physical ceiling is explicit and bounded" {
    try std.testing.expect(acceptsConservativePublication(1, .{ .max_iterations = 1 }));
    try std.testing.expect(!acceptsConservativePublication(1.01, .{ .max_iterations = 1 }));
    try std.testing.expect(acceptsConservativePublication(1.01, .{
        .max_iterations = 1,
        .accept_physically_conserved_ceiling = true,
    }));
    try std.testing.expect(acceptsConservativePublication(1.25, .{
        .max_iterations = 1,
        .accept_physically_conserved_ceiling = true,
    }));
    try std.testing.expect(!acceptsConservativePublication(1.2500001, .{
        .max_iterations = 1,
        .accept_physically_conserved_ceiling = true,
    }));
}

/// Solves spatial diffusion, pressure displacement, atmospheric exchange,
/// gas-water equilibration (including band NH3), and bubbling as one nonlinear
/// system. No full model process is rerun during these iterations.
pub fn solve(allocator: std.mem.Allocator, state: *gas.State, inputs: group_misc.Inputs, options: group_misc.Options) !group_misc.Result {
    return solveControlled(allocator, state, inputs, options, 0, 0, null);
}

/// Internal test seam used only to prove the recovery ordering. Production
/// always passes zero, so no caller can disable or bypass a Newton attempt.
fn solveControlled(
    allocator: std.mem.Allocator,
    state: *gas.State,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    forced_initial_newton_failures: u16,
    forced_invalid_publication_probes: u16,
    trace: ?*SolverTrace,
) !group_misc.Result {
    try group_validation.validate(state, inputs, options);
    const inventory_count = state.gaseous_mass_g.len;
    const unknown_count = try std.math.mul(usize, inventory_count, 3);
    const base = try allocator.alloc(f64, unknown_count);
    defer allocator.free(base);
    group_residual.copyStateToVector(state, base);
    const current = try allocator.dupe(f64, base);
    defer allocator.free(current);
    const residual = try allocator.alloc(f64, unknown_count);
    defer allocator.free(residual);
    const probe = try allocator.alloc(f64, unknown_count);
    defer allocator.free(probe);
    const probe_residual = try allocator.alloc(f64, unknown_count);
    defer allocator.free(probe_residual);
    const candidate = try allocator.alloc(f64, unknown_count);
    defer allocator.free(candidate);
    const candidate_residual = try allocator.alloc(f64, unknown_count);
    defer allocator.free(candidate_residual);
    const previous = try allocator.alloc(f64, unknown_count);
    defer allocator.free(previous);
    const previous_residual = try allocator.alloc(f64, unknown_count);
    defer allocator.free(previous_residual);
    // Depth-3 Anderson history: the outer solve's own trajectory of accepted
    // iterates at each Anderson-attempt moment, entirely separate from
    // `previous`/`previous_residual` (single-slot bookkeeping consumed
    // elsewhere). anderson_history_depth stays within
    // numerics.anderson_max_depth so nonnegativeDampedAndersonCandidate's
    // combined history+seed point count never exceeds andersonDepthMCandidate's
    // ceiling.
    const anderson_history_depth: usize = 3;
    var anderson_history_states: [anderson_history_depth][]f64 = undefined;
    var anderson_history_defects: [anderson_history_depth][]f64 = undefined;
    for (0..anderson_history_depth) |slot| {
        anderson_history_states[slot] = try allocator.alloc(f64, unknown_count);
        anderson_history_defects[slot] = try allocator.alloc(f64, unknown_count);
    }
    defer for (0..anderson_history_depth) |slot| {
        allocator.free(anderson_history_states[slot]);
        allocator.free(anderson_history_defects[slot]);
    };
    var anderson_history_len: usize = 0;
    const target = try allocator.alloc(f64, unknown_count);
    defer allocator.free(target);
    var scratch = try gas.State.init(allocator, state.cell_count);
    defer scratch.deinit();
    @memcpy(scratch.air_volume_m3, state.air_volume_m3);
    @memcpy(scratch.temperature_k, state.temperature_k);
    @memcpy(scratch.water_vapor_mol, state.water_vapor_mol);
    var dense_full_newton_workspace: ?group_directions.DenseFullNewtonWorkspace = null;
    defer if (dense_full_newton_workspace) |*workspace| workspace.deinit();
    var krylov_newton_workspace = try group_directions.KrylovNewtonWorkspace.init(
        allocator,
        unknown_count,
        options.krylov_restart_max,
    );
    defer krylov_newton_workspace.deinit();

    var newton_steps: u16 = 0;
    var anderson_steps: u16 = 0;
    var iteration: u16 = 0;
    var initial_maximum_scaled_residual: f64 = 0;
    var last_scaled_residual: f64 = std.math.inf(f64);
    var previous_iteration_norm: ?f64 = null;
    var slow_progress_count: u8 = 0;
    var best_divergence_watch_norm = std.math.inf(f64);
    var explosive_update_count: u16 = 0;
    var invalid_publication_probes_remaining = forced_invalid_publication_probes;
    var slow_newton_norm_history: [slow_newton_progress_history_length]f64 = undefined;
    var slow_newton_norm_count: u8 = 0;
    var slow_newton_last_recorded_step: u16 = 0;
    var slow_progress_recovery_pending = false;
    var rejected_speculative_recovery_step: ?u16 = null;
    var speculative_newton_replay = false;
    // A conservative image may be published only after the current iterate
    // has followed the prescribed Newton -> Anderson -> Newton policy.  This
    // bit describes the current state, not merely the cumulative counter: a
    // failed Newton retry still satisfies the retry requirement for the
    // unchanged Anderson state.
    var current_has_newton_attempt = false;
    var newton_retry_required = false;
    const residual_fraction = options.transport_iteration_fraction;
    while (iteration < options.max_iterations) : (iteration += 1) {
        const replaying_speculative_newton = speculative_newton_replay;
        speculative_newton_replay = false;
        if (replaying_speculative_newton) {
            if (trace) |events|
                events.next_slot_newton_retry_iteration = iteration + 1;
        }
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        var publication_rejected_this_iteration = false;
        var rejected_publication_seed_available = false;
        if (trace) |events| events.iterations_entered += 1;
        try group_residual.residualAt(allocator, &scratch, base, current, inputs, residual_fraction, target, residual);
        var norm = try group_diagnostics.scaledNorm(current, residual, options);
        if (iteration == 0) initial_maximum_scaled_residual = norm;
        last_scaled_residual = norm;
        // Only accepted Newton promotions extend this contraction history.
        // Anderson states become a fresh baseline, and probe-only speculative
        // recovery never masquerades as a counted nonlinear update.
        const accepted_newton_since_forecast = slow_newton_norm_count != 0 and
            newton_steps != slow_newton_last_recorded_step;
        if (accepted_newton_since_forecast) {
            slow_progress_recovery_pending = false;
            rejected_speculative_recovery_step = null;
        }
        if (slow_newton_norm_count == 0 or accepted_newton_since_forecast) {
            rememberNewtonNorm(
                &slow_newton_norm_history,
                &slow_newton_norm_count,
                norm,
            );
            slow_newton_last_recorded_step = newton_steps;
        }
        if (coupledResidualExplosionExceededPatience(
            norm,
            options,
            &best_divergence_watch_norm,
            &explosive_update_count,
        )) {
            if (options.emit_failure_diagnostics) std.log.warn(
                "coupled gas solver residual explosion: iteration={d} scaled_residual={e} best_scaled_residual={e} growth_factor={e} patience={d}",
                .{ iteration + 1, norm, best_divergence_watch_norm, options.divergence_growth_factor, options.divergence_patience },
            );
            return error.CoupledGasSolverDiverged;
        }
        if (!retrying_newton_after_anderson and norm <= 1) {
            const force_invalid_publication = invalid_publication_probes_remaining > 0;
            if (force_invalid_publication) invalid_publication_probes_remaining -= 1;
            const publication_norm = try conservativePublicationNorm(
                allocator,
                &scratch,
                base,
                inputs,
                residual_fraction,
                target,
                candidate,
                probe,
                candidate_residual,
                options,
                iteration + 1,
                force_invalid_publication,
            );
            if (publication_norm) |verified_norm| {
                const final_slot_physical_ceiling =
                    iteration + 1 >= options.max_iterations and
                    acceptsConservativePublication(verified_norm, options);
                if (verified_norm <= 1 or final_slot_physical_ceiling) {
                    // Publish the exact conservative F(current), not the
                    // approximate Newton iterate. Capture ledgers only after that
                    // exact candidate has independently passed nonlinear tolerance.
                    // On the final counted slot only, the caller may explicitly
                    // permit the same bounded physical-conservation ceiling used
                    // by the read-only post-loop audit. Reuse this already-audited
                    // image instead of discarding it before that audit is reachable.
                    if (group_residual.capturesFluxLedgers(inputs))
                        try group_residual.residualAtCapturing(
                            allocator,
                            &scratch,
                            base,
                            current,
                            inputs,
                            residual_fraction,
                            target,
                            residual,
                            true,
                        );
                    group_residual.copyVectorToState(candidate, state);
                    if (verified_norm > 1) std.log.debug(
                        "coupled gas solver accepted final-slot physically conserved publication: iterate_scaled_residual={e} publication_scaled_residual={e} ceiling={e}",
                        .{ norm, verified_norm, physically_conserved_publication_scaled_ceiling },
                    );
                    return .{ .iterations = iteration + 1, .newton_raphson_steps = newton_steps, .picard_steps = anderson_steps, .anderson_steps = anderson_steps, .initial_maximum_scaled_residual = initial_maximum_scaled_residual, .maximum_scaled_residual = verified_norm, .dense_full_jacobian_assemblies = if (dense_full_newton_workspace) |workspace| workspace.assemblies else 0, .krylov_direction_calls = krylov_newton_workspace.direction_calls, .krylov_iterations = krylov_newton_workspace.iterations };
                }
                // F(current) is a valid conservative state but is not a
                // converged state.  Preserve this exact map/defect pair as an
                // Anderson seed.  Continuing to count Newton descent of the
                // already-passing current residual optimizes the wrong merit
                // and caused the production 100-Newton/0-Anderson ceiling.
                publication_rejected_this_iteration = true;
                rejected_publication_seed_available = true;
                std.log.debug("gas solver publication rejected: iteration={d} current_norm={e} publication_norm={e}", .{ iteration + 1, norm, verified_norm });
                if (trace) |events| {
                    events.rejected_iterate_norm = norm;
                    events.rejected_publication_norm = verified_norm;
                }
            } else {
                publication_rejected_this_iteration = true;
                if (trace) |events| events.invalid_publication_rejections += 1;
            }
            if (trace) |events| events.append(.publication_reject);
        }
        var progress_requires_anderson = false;
        if (!replaying_speculative_newton) {
            if (previous_iteration_norm) |previous_norm| {
                progress_requires_anderson =
                    coupledGasSlowProgressExceededPatience(
                        previous_norm,
                        norm,
                        retrying_newton_after_anderson,
                        &slow_progress_count,
                    );
            }
            previous_iteration_norm = norm;
        }
        const remaining_updates = options.max_iterations - iteration;
        const test_forces_speculative_recovery = if (trace) |events|
            events.force_speculative_iteration == iteration
        else
            false;
        if (!retrying_newton_after_anderson and
            !replaying_speculative_newton and
            !slow_progress_recovery_pending and
            rejected_speculative_recovery_step != newton_steps and
            remaining_updates >= 2 and
            (test_forces_speculative_recovery or
                (remaining_updates <= slow_newton_recovery_reserve and
                    slow_newton_norm_count ==
                        slow_newton_progress_history_length and
                    slowNewtonProgressNeedsRecovery(
                        slow_newton_norm_history[0],
                        slow_newton_norm_history[
                            slow_newton_progress_history_length - 1
                        ],
                        slow_newton_progress_window_updates,
                        remaining_updates,
                    ))))
        {
            slow_progress_recovery_pending = true;
        }
        const slow_progress_requires_anderson =
            slow_progress_recovery_pending;
        // Release a zero-inventory complementarity bound with the assembled
        // conservative target before forming a numerical Jacobian there.
        // At x=0 a positive source is physical, but a projected finite-
        // difference Newton column can be singular and waste NPH*NPG.
        var limiting_index = try group_diagnostics.worstResidualIndex(current, residual, options);
        var depleted_pair_norm =
            try group_diagnostics.scaledCoordinateResidual(
                current[limiting_index],
                residual[limiting_index],
                options,
                limiting_index,
                inventory_count,
            );
        for (0..inventory_count) |gas_index| {
            const dissolved_index = inventory_count + gas_index;
            if (group_diagnostics.isScaleDepletedGas(base[gas_index], base[dissolved_index], group_misc.absoluteToleranceForCoordinate(options, gas_index, inventory_count), options) and
                current[dissolved_index] > 0)
            {
                const coordinate_norm =
                    try group_diagnostics.scaledCoordinateResidual(current[gas_index], residual[gas_index], options, gas_index, inventory_count);
                if (coordinate_norm > depleted_pair_norm) {
                    depleted_pair_norm = coordinate_norm;
                    limiting_index = gas_index;
                }
            }
        }
        var released_bound_count: usize = 0;
        for (current, residual, target) |value, difference, assembled| {
            if (group_diagnostics.isNumericallyAtNonnegativeBound(value, assembled) and
                difference > 0)
            {
                released_bound_count += 1;
            }
        }
        // Bound-release Anderson recovery is deliberately deferred to the
        // sole solve-level fallback after every Newton family below fails.
        const publication_requires_anderson = publication_rejected_this_iteration and
            current_has_newton_attempt and !retrying_newton_after_anderson and
            !replaying_speculative_newton;
        const use_rejected_publication_seed = publication_requires_anderson and
            rejected_publication_seed_available;
        const speculative_recovery = slow_progress_requires_anderson and
            !progress_requires_anderson and
            !publication_requires_anderson;
        const replayable_publication_recovery = publication_requires_anderson and
            rejected_publication_seed_available and
            !progress_requires_anderson;
        newton_attempts: {
            if (publication_requires_anderson or progress_requires_anderson or
                slow_progress_requires_anderson)
                break :newton_attempts;
            if (trace) |events| events.append(.newton_attempt);
            if (iteration < forced_initial_newton_failures)
                break :newton_attempts;
            // Species equations are separable, but pressure displacement couples
            // their cell coordinates. Resolve a depleted gas/dissolved pair with
            // a damped 2x2 Newton step before the global solve, never with a
            // scalar bracket: a bracket serializes the coupled system and can
            // consume the complete NPH*NPG budget while all other phases move.
            const limiting_phase_for_pair = limiting_index / inventory_count;
            const limiting_gas_index = limiting_index % inventory_count;
            const limiting_dissolved_index = inventory_count + limiting_gas_index;
            const limiting_pair_is_depleted = group_diagnostics.isScaleDepletedGas(
                base[limiting_gas_index],
                base[limiting_dissolved_index],
                group_misc.absoluteToleranceForCoordinate(options, limiting_gas_index, inventory_count),
                options,
            );
            const phase_coupled_pair = limiting_phase_for_pair < 2 and
                limiting_pair_is_depleted and
                current[limiting_dissolved_index] > 0;
            var target_was_overwritten = false;
            if (residual[limiting_index] != 0 and
                (phase_coupled_pair or released_bound_count == 1 or iteration == 0))
            {
                const limiting_phase = limiting_index / inventory_count;
                if (limiting_phase < 2) {
                    const gas_index = limiting_index % inventory_count;
                    const dissolved_index = inventory_count + gas_index;
                    const pair_total_g = target[gas_index] + target[dissolved_index];
                    const pair_is_depleted =
                        group_diagnostics.isScaleDepletedGas(base[gas_index], base[dissolved_index], group_misc.absoluteToleranceForCoordinate(options, gas_index, inventory_count), options);
                    if (pair_is_depleted and
                        current[dissolved_index] > 0 and
                        std.math.isFinite(pair_total_g) and pair_total_g > 0)
                    {
                        // The conservative transport target itself changes with
                        // the trial mixture. Follow that physical map for the
                        // depleted limiting pair before forming its local Newton
                        // block; prioritizing this coordinate prevents a later
                        // dense step from undoing its active-set release.
                        const current_pair_norm = @max(
                            try group_diagnostics.scaledCoordinateResidual(current[gas_index], residual[gas_index], options, gas_index, inventory_count),
                            try group_diagnostics.scaledCoordinateResidual(current[dissolved_index], residual[dissolved_index], options, dissolved_index, inventory_count),
                        );
                        // Use a roundoff-scale absolute floor: dry-cell gas inventories can
                        // be near zero while pressure displacement has gram-scale sensitivity.
                        const gas_probe = std.math.cbrt(std.math.floatEps(f64)) *
                            @max(
                                group_misc.absoluteToleranceForCoordinate(options, gas_index, inventory_count),
                                @max(
                                    @abs(current[gas_index]),
                                    @abs(target[gas_index]),
                                ),
                            );
                        const dissolved_probe = std.math.cbrt(std.math.floatEps(f64)) *
                            @max(
                                group_misc.absoluteToleranceForCoordinate(options, dissolved_index, inventory_count),
                                @max(
                                    @abs(current[dissolved_index]),
                                    @abs(target[dissolved_index]),
                                ),
                            );
                        @memcpy(probe, current);
                        probe[gas_index] += gas_probe;
                        target_was_overwritten = true;
                        if (group_residual.residualAt(allocator, &scratch, base, probe, inputs, residual_fraction, target, probe_residual)) |_| {
                            const j00 = (probe_residual[gas_index] - residual[gas_index]) / gas_probe;
                            const j10 = (probe_residual[dissolved_index] - residual[dissolved_index]) / gas_probe;
                            @memcpy(probe, current);
                            probe[dissolved_index] += dissolved_probe;
                            if (group_residual.residualAt(allocator, &scratch, base, probe, inputs, residual_fraction, target, candidate_residual)) |_| {
                                const j01 = (candidate_residual[gas_index] - residual[gas_index]) / dissolved_probe;
                                const j11 = (candidate_residual[dissolved_index] - residual[dissolved_index]) / dissolved_probe;
                                const determinant = j00 * j11 - j01 * j10;
                                if (std.math.isFinite(determinant) and @abs(determinant) > std.math.floatEps(f64)) {
                                    const gas_direction = (-residual[gas_index] * j11 + j01 * residual[dissolved_index]) / determinant;
                                    const dissolved_direction = (j10 * residual[gas_index] - j00 * residual[dissolved_index]) / determinant;
                                    var pair_fraction: f64 = 1;
                                    var pair_line_search: u8 = 0;
                                    var accepted_pair_newton = false;
                                    while (pair_line_search < 24) : (pair_line_search += 1) {
                                        @memcpy(candidate, current);
                                        candidate[gas_index] = current[gas_index] + pair_fraction * gas_direction;
                                        candidate[dissolved_index] = current[dissolved_index] + pair_fraction * dissolved_direction;
                                        if (candidate[gas_index] < 0 or candidate[dissolved_index] < 0) {
                                            pair_fraction *= 0.5;
                                            continue;
                                        }
                                        if (group_residual.residualAt(allocator, &scratch, base, candidate, inputs, residual_fraction, target, candidate_residual)) |_| {
                                            const candidate_pair_norm = @max(
                                                try group_diagnostics.scaledCoordinateResidual(candidate[gas_index], candidate_residual[gas_index], options, gas_index, inventory_count),
                                                try group_diagnostics.scaledCoordinateResidual(candidate[dissolved_index], candidate_residual[dissolved_index], options, dissolved_index, inventory_count),
                                            );
                                            const candidate_global_norm = try group_diagnostics.scaledNorm(candidate, candidate_residual, options);
                                            if (candidate_pair_norm < current_pair_norm and
                                                candidate_global_norm < norm)
                                            {
                                                @memcpy(previous, current);
                                                @memcpy(previous_residual, residual);
                                                @memcpy(current, candidate);
                                                current_has_newton_attempt = true;
                                                newton_steps += 1;
                                                accepted_pair_newton = true;
                                                std.log.debug("gas solver branch: iteration={d} branch={s} norm_before={e}", .{ iteration + 1, "pair_newton_2x2", norm });
                                                break;
                                            }
                                        } else |_| {}
                                        pair_fraction *= 0.5;
                                    }
                                    if (accepted_pair_newton) {
                                        continue;
                                    }
                                }
                            } else |_| {}
                        } else |_| {}
                    }
                }
            }
            // Active phase-pair bounds are resolved only by the damped 2x2
            // Newton line search above. Bracketing/bisection would serialize the
            // coupled solve and starve the primary dense Newton path of the hard
            // iteration budget.
            var accepted_newton = false;
            // Pair probes share `target` scratch. Reassemble F(current) only
            // when that path actually ran; the loop-entry residual and target
            // are otherwise still the exact current pair.
            if (target_was_overwritten) {
                try group_residual.residualAt(
                    allocator,
                    &scratch,
                    base,
                    current,
                    inputs,
                    residual_fraction,
                    target,
                    residual,
                );
                norm = try group_diagnostics.scaledNorm(current, residual, options);
                target_was_overwritten = false;
            }
            // Every transport and phase-exchange equation is species-separable.
            // After the first global Anderson recovery, solve the species that
            // controls the infinity norm directly. Waiting for a late "tail"
            // wastes the NPH*NPG budget on unrelated CO2/O2 blocks and can make
            // otherwise convergent NPG-local solves exhaust their hourly ceiling.
            const active_species: ?usize = if (iteration >= 1 or released_bound_count > 1)
                try group_diagnostics.worstResidualSpecies(current, residual, options, inventory_count)
            else
                null;
            // Resolve the convergence-controlling donor clamp before a
            // species-wide Picard update can report progress in unrelated cells
            // and skip this conservative face coordinate.
            if (iteration >= 1 and
                try group_newton_steps.conservativeMultiSpeciesFaceNewtonStep(
                    allocator,
                    &scratch,
                    base,
                    current,
                    residual,
                    inputs,
                    residual_fraction,
                    target,
                    probe,
                    probe_residual,
                    candidate,
                    candidate_residual,
                    previous,
                    previous_residual,
                    options,
                    norm,
                    &target_was_overwritten,
                ))
            {
                current_has_newton_attempt = true;
                newton_steps += 1;
                std.log.debug("gas solver branch: iteration={d} branch={s} norm_before={e}", .{ iteration + 1, "multi_species_face_newton", norm });
                continue;
            }
            // Restore F(current) after rejected multi-species probes before the
            // scalar face safeguard inspects its active-set target.
            if (target_was_overwritten)
                try group_residual.residualAt(
                    allocator,
                    &scratch,
                    base,
                    current,
                    inputs,
                    residual_fraction,
                    target,
                    residual,
                );
            target_was_overwritten = false;
            if (iteration >= 1 and try group_newton_steps.conservativeFaceNewtonStep(
                allocator,
                &scratch,
                base,
                current,
                residual,
                inputs,
                residual_fraction,
                target,
                probe,
                probe_residual,
                candidate,
                candidate_residual,
                previous,
                previous_residual,
                options,
                norm,
                &target_was_overwritten,
            )) {
                current_has_newton_attempt = true;
                newton_steps += 1;
                std.log.debug("gas solver branch: iteration={d} branch={s} norm_before={e}", .{ iteration + 1, "conservative_face_newton", norm });
                continue;
            }
            // Conservative-face probes also evaluate F(candidate). Reassemble
            // F(current) before testing a zero-inventory active set; otherwise a
            // rejected face probe can hide its positive assembled target and
            // spend the remaining ceiling on no-op retries.
            if (target_was_overwritten) {
                try group_residual.residualAt(
                    allocator,
                    &scratch,
                    base,
                    current,
                    inputs,
                    residual_fraction,
                    target,
                    residual,
                );
                norm = try group_diagnostics.scaledNorm(current, residual, options);
            }
            target_was_overwritten = false;
            if (try group_newton_steps.activeSetGasNewtonStep(
                allocator,
                &scratch,
                base,
                current,
                residual,
                inputs,
                residual_fraction,
                target,
                probe,
                probe_residual,
                candidate,
                candidate_residual,
                previous,
                previous_residual,
                options,
                norm,
                &target_was_overwritten,
            )) {
                current_has_newton_attempt = true;
                newton_steps += 1;
                std.log.debug("gas solver branch: iteration={d} branch={s} norm_before={e}", .{ iteration + 1, "active_set_newton", norm });
                continue;
            }
            // Both conservative and active-set Newton probes overwrite `target`.
            // Reassemble F(current) before its coupled dense line search.
            if (target_was_overwritten) {
                try group_residual.residualAt(
                    allocator,
                    &scratch,
                    base,
                    current,
                    inputs,
                    residual_fraction,
                    target,
                    residual,
                );
                norm = try group_diagnostics.scaledNorm(current, residual, options);
            }
            {
                var iteration_options = options;
                iteration_options.transport_iteration_fraction = residual_fraction;
                const species_block_dimension = try std.math.mul(usize, scratch.cell_count, 3);
                // For a small complete system, the full Jacobian costs the same
                // number of residual probes as seven separately assembled
                // species blocks and additionally captures pressure displacement
                // cross derivatives. Large systems retain bounded species/Krylov
                // storage.
                // Pressure displacement couples species even though molecular
                // diffusion and phase exchange are species-local. Small
                // systems use the complete dense Jacobian immediately. At a
                // half-hour or longer, the strongly coupled pressure/phase
                // displacement also needs that robust path immediately: a
                // cheaper Krylov attempt can otherwise consume the whole
                // nonlinear budget and force needless temporal refinement.
                // Quarter-hours and smaller use the row/column-scaled coupled
                // Krylov direction, with 36 terminal slots reserved for the
                // complete dense path if matrix-free progress stalls.
                const use_full_dense = unknown_count <= 128 or
                    (unknown_count <= 256 and
                        (residual_fraction > 0.25 or iteration >= 64));
                const use_full_krylov = !use_full_dense and
                    unknown_count <= 4096;
                const unconverged_species_count =
                    try group_diagnostics.unconvergedSpeciesCount(
                        current,
                        residual,
                        options,
                        inventory_count,
                    );
                const direction_species = if (use_full_krylov)
                    null
                else
                    active_species;
                const use_single_species_block =
                    direction_species != null and
                    unconverged_species_count == 1;
                const use_all_species_blocks =
                    !use_single_species_block and
                    !use_full_dense and
                    !use_full_krylov and
                    species_block_dimension <= 256;
                const use_dense_full_direction =
                    !use_single_species_block and use_full_dense;
                @memset(probe, 0);
                var has_direction = if (use_single_species_block)
                    try group_directions.denseSpeciesNewtonDirection(
                        allocator,
                        &scratch,
                        base,
                        current,
                        residual,
                        inputs,
                        iteration_options,
                        target,
                        candidate_residual,
                        candidate,
                        probe,
                        direction_species.?,
                    )
                else if (use_dense_full_direction) dense_full: {
                    if (dense_full_newton_workspace == null)
                        dense_full_newton_workspace = try group_directions.DenseFullNewtonWorkspace.init(allocator, unknown_count);
                    break :dense_full try group_directions.denseFullNewtonDirectionWithWorkspace(allocator, &scratch, base, current, residual, inputs, iteration_options, target, candidate_residual, candidate, probe, &dense_full_newton_workspace.?);
                } else if (use_all_species_blocks)
                    try group_directions.denseAllSpeciesNewtonDirection(allocator, &scratch, base, current, residual, inputs, iteration_options, target, candidate_residual, candidate, probe)
                else if (direction_species) |species|
                    (try group_directions.denseSpeciesNewtonDirection(allocator, &scratch, base, current, residual, inputs, iteration_options, target, candidate_residual, candidate, probe, species)) or
                        try group_directions.krylovNewtonDirectionWithWorkspace(allocator, &scratch, base, current, residual, inputs, iteration_options, target, probe_residual, probe, direction_species, &krylov_newton_workspace)
                else
                    try group_directions.krylovNewtonDirectionWithWorkspace(allocator, &scratch, base, current, residual, inputs, iteration_options, target, probe_residual, probe, direction_species, &krylov_newton_workspace);
                if (has_direction and use_all_species_blocks) has_direction = try group_directions.filterIndependentSpeciesDirections(
                    allocator,
                    &scratch,
                    base,
                    current,
                    residual,
                    inputs,
                    iteration_options,
                    target,
                    candidate_residual,
                    candidate,
                    probe,
                );
                if (has_direction) {
                    var line_fraction: f64 = 1;
                    var line_search: u8 = 0;
                    while (line_search < 20) : (line_search += 1) {
                        var valid_line = true;
                        for (current, probe, candidate) |value, direction, *next| {
                            next.* = value + line_fraction * direction;
                            if (!std.math.isFinite(next.*) or next.* < 0) {
                                valid_line = false;
                                break;
                            }
                        }
                        if (valid_line) {
                            if (group_residual.residualAt(allocator, &scratch, base, candidate, inputs, residual_fraction, target, candidate_residual)) |_| {
                                // The termination test is an infinity norm. Using
                                // an L2-only merit function can accept steps that
                                // reduce large gas blocks while leaving a small
                                // species (commonly N2O) above tolerance for the
                                // entire NPH*NPG budget.
                                const candidate_norm = try group_diagnostics.scaledNorm(
                                    candidate,
                                    candidate_residual,
                                    options,
                                );
                                const improves = if (use_all_species_blocks or use_full_dense)
                                    // Dense block Newton is already protected by
                                    // positivity projection and line search. Keep
                                    // strong globalization away from the root,
                                    // but accept strict progress once the residual
                                    // is within twice the requested tolerance.
                                    candidate_norm < group_diagnostics.newtonAcceptanceTarget(norm)
                                else if (direction_species != null)
                                    try group_diagnostics.speciesBlockMeritImproves(current, residual, candidate, candidate_residual, options, inventory_count, direction_species.?, norm)
                                else
                                    candidate_norm < norm;
                                if (improves) {
                                    @memcpy(previous, current);
                                    @memcpy(previous_residual, residual);
                                    @memcpy(current, candidate);
                                    current_has_newton_attempt = true;
                                    newton_steps += 1;
                                    accepted_newton = true;
                                    std.log.debug("gas solver branch: iteration={d} branch={s} norm_before={e}", .{ iteration + 1, "dense_newton_linesearch", norm });
                                    break;
                                }
                            } else |_| {}
                        }
                        line_fraction *= 0.5;
                    }
                }
            }
            if (accepted_newton) {
                continue;
            }
            if (active_species) |species| {
                @memset(probe, 0);
                var species_options = options;
                species_options.transport_iteration_fraction = residual_fraction;
                const has_species_newton_direction = try group_directions.denseSpeciesNewtonDirection(allocator, &scratch, base, current, residual, inputs, species_options, target, candidate_residual, candidate, probe, species);
                if (has_species_newton_direction) {
                    var newton_fraction: f64 = 1;
                    var newton_search: u8 = 0;
                    while (newton_search < 20) : (newton_search += 1) {
                        var valid_species_newton = true;
                        for (current, probe, candidate) |value, direction, *next| {
                            next.* = value + newton_fraction * direction;
                            if (!std.math.isFinite(next.*) or next.* < 0) valid_species_newton = false;
                        }
                        if (!valid_species_newton) {
                            newton_fraction *= 0.5;
                            continue;
                        }
                        if (group_residual.residualAt(allocator, &scratch, base, candidate, inputs, residual_fraction, target, candidate_residual)) |_| {
                            const current_species_norm = try group_diagnostics.scaledSpeciesNorm(current, residual, options, inventory_count, species);
                            const candidate_species_norm = try group_diagnostics.scaledSpeciesNorm(candidate, candidate_residual, options, inventory_count, species);
                            if (candidate_species_norm < group_diagnostics.newtonAcceptanceTarget(current_species_norm) and try group_diagnostics.speciesBlockMeritImproves(current, residual, candidate, candidate_residual, options, inventory_count, species, norm)) {
                                @memcpy(previous, current);
                                @memcpy(previous_residual, residual);
                                @memcpy(current, candidate);
                                current_has_newton_attempt = true;
                                newton_steps += 1;
                                accepted_newton = true;
                                std.log.debug("gas solver branch: iteration={d} branch={s} norm_before={e}", .{ iteration + 1, "species_newton", norm });
                                break;
                            }
                        } else |_| {}
                        newton_fraction *= 0.5;
                    }
                }
                if (accepted_newton) {
                    continue;
                }
            }
            // A phase bound can make the full species Jacobian singular even
            // though the one coordinate controlling the infinity norm remains
            // locally smooth. Polish that coordinate with a scalar Newton step
            // before falling back to global mixing. This stays inside the same
            // NPH*NPG iteration budget and never relaxes the requested tolerance.
            if (try group_newton_steps.coordinateNewtonStep(allocator, &scratch, base, current, residual, inputs, residual_fraction, target, probe, probe_residual, candidate, candidate_residual, previous, previous_residual, options, norm)) {
                current_has_newton_attempt = true;
                newton_steps += 1;
                accepted_newton = true;
                std.log.debug("gas solver branch: iteration={d} branch={s} norm_before={e}", .{ iteration + 1, "coordinate_newton", norm });
            }
            if (accepted_newton) {
                continue;
            }
            if (group_residual.addDirection(current, residual, options.directional_probe_fraction, probe)) |_| {
                if (group_residual.residualAt(allocator, &scratch, base, probe, inputs, residual_fraction, target, probe_residual)) |_| {
                    var valid_candidate = true;
                    for (current, residual, probe_residual, candidate) |value, difference, sampled_difference, *next| {
                        if (@abs(difference) <= std.math.floatEps(f64)) {
                            next.* = value;
                            continue;
                        }
                        const derivative = (sampled_difference - difference) /
                            (options.directional_probe_fraction * difference);
                        if (!std.math.isFinite(derivative) or derivative >= 0) {
                            valid_candidate = false;
                            break;
                        }
                        const raw_fraction = -1.0 / derivative;
                        const fraction = std.math.clamp(raw_fraction, options.minimum_newton_fraction, options.maximum_newton_fraction);
                        next.* = value + fraction * difference;
                        if (!std.math.isFinite(next.*) or next.* < 0) {
                            valid_candidate = false;
                            break;
                        }
                    }
                    if (valid_candidate) {
                        if (group_residual.residualAt(allocator, &scratch, base, candidate, inputs, residual_fraction, target, candidate_residual)) |_| {
                            if (try group_diagnostics.scaledNorm(candidate, candidate_residual, options) < norm) {
                                @memcpy(previous, current);
                                @memcpy(previous_residual, residual);
                                @memcpy(current, candidate);
                                current_has_newton_attempt = true;
                                newton_steps += 1;
                                accepted_newton = true;
                                std.log.debug("gas solver branch: iteration={d} branch={s} norm_before={e}", .{ iteration + 1, "directional_probe", norm });
                            }
                        } else |_| {}
                    }
                } else |_| {}
            } else |_| {}
            if (accepted_newton) {
                continue;
            }
        }
        if (retrying_newton_after_anderson) {
            current_has_newton_attempt = true;
            continue;
        }
        // Every Newton family has now failed at the unchanged iterate. Restore
        // its exact map before constructing the sole fallback tier: genuine
        // Anderson acceleration of one or more uncommitted Picard seeds.
        const force_speculative_rejection = (speculative_recovery or replayable_publication_recovery) and
            if (trace) |events| events.reject_speculative_anderson else false;
        try group_residual.residualAt(
            allocator,
            &scratch,
            base,
            current,
            inputs,
            residual_fraction,
            target,
            residual,
        );
        norm = try group_diagnostics.scaledNorm(current, residual, options);
        if (iteration + 1 >= options.max_iterations) {
            if (!builtin.is_test) std.log.warn(
                "TEMP_DIAGNOSTIC coupled-gas final slot reached before Anderson: iteration={d} scaled_residual={e} newton_steps={d} anderson_steps={d} transport_iteration_fraction={e}",
                .{ iteration + 1, norm, newton_steps, anderson_steps, options.transport_iteration_fraction },
            );
            return error.CoupledGasSolverDidNotConverge;
        }
        if (trace) |events| {
            events.append(.anderson_attempt);
            if (speculative_recovery or replayable_publication_recovery) {
                events.speculative_anderson_attempts +|= 1;
                events.speculative_anderson_iteration = iteration + 1;
            }
        }
        if (use_rejected_publication_seed) {
            pushAndersonHistory(
                anderson_history_states[0..],
                anderson_history_defects[0..],
                &anderson_history_len,
                anderson_history_depth,
                current,
                residual,
            );
            if (nonnegativeDampedAndersonCandidate(
                anderson_history_states[0..anderson_history_len],
                anderson_history_defects[0..anderson_history_len],
                candidate,
                candidate_residual,
                probe,
            )) {
                if (group_residual.residualAt(
                    allocator,
                    &scratch,
                    base,
                    probe,
                    inputs,
                    residual_fraction,
                    target,
                    probe_residual,
                )) |_| {
                    const probe_norm = try group_diagnostics.scaledNorm(
                        probe,
                        probe_residual,
                        options,
                    );
                    if (!force_speculative_rejection and
                        numerics.andersonImprovesAcceptedMerit(probe_norm, norm))
                    {
                        @memcpy(previous, current);
                        @memcpy(previous_residual, residual);
                        @memcpy(current, probe);
                        current_has_newton_attempt = false;
                        newton_retry_required = true;
                        anderson_steps += 1;
                        slow_newton_norm_count = 0;
                        slow_progress_recovery_pending = false;
                        rejected_speculative_recovery_step = null;
                        continue;
                    }
                } else |_| {}
            }
            // The exact image exposed the failed publication branch but its
            // secant may be singular.  Continue to the ordinary damped
            // Anderson seed; never commit the conservative image directly.
            try group_residual.residualAt(
                allocator,
                &scratch,
                base,
                current,
                inputs,
                residual_fraction,
                target,
                residual,
            );
            norm = try group_diagnostics.scaledNorm(current, residual, options);
        }
        var unresolved_bound_count: usize = 0;
        @memcpy(candidate, current);
        for (current, residual, target, candidate) |value, difference, assembled, *next| {
            if (group_diagnostics.isNumericallyAtNonnegativeBound(value, assembled) and
                difference > 0)
            {
                next.* = assembled;
                unresolved_bound_count += 1;
            }
        }
        if (unresolved_bound_count > 1) {
            if (group_residual.residualAt(
                allocator,
                &scratch,
                base,
                candidate,
                inputs,
                residual_fraction,
                target,
                candidate_residual,
            )) |_| {
                pushAndersonHistory(
                    anderson_history_states[0..],
                    anderson_history_defects[0..],
                    &anderson_history_len,
                    anderson_history_depth,
                    current,
                    residual,
                );
                if (nonnegativeDampedAndersonCandidate(
                    anderson_history_states[0..anderson_history_len],
                    anderson_history_defects[0..anderson_history_len],
                    candidate,
                    candidate_residual,
                    probe,
                )) {
                    if (group_residual.residualAt(
                        allocator,
                        &scratch,
                        base,
                        probe,
                        inputs,
                        residual_fraction,
                        target,
                        probe_residual,
                    )) |_| {
                        const probe_norm = try group_diagnostics.scaledNorm(
                            probe,
                            probe_residual,
                            options,
                        );
                        if (!force_speculative_rejection and
                            std.math.isFinite(probe_norm) and probe_norm < norm)
                        {
                            @memcpy(previous, current);
                            @memcpy(previous_residual, residual);
                            @memcpy(current, probe);
                            current_has_newton_attempt = false;
                            newton_retry_required = true;
                            anderson_steps += 1;
                            slow_newton_norm_count = 0;
                            slow_progress_recovery_pending = false;
                            rejected_speculative_recovery_step = null;
                            std.log.debug(
                                "gas solver branch: iteration={d} branch={s} norm_before={e}",
                                .{ iteration + 1, "bound_set_anderson", norm },
                            );
                            continue;
                        }
                    } else |_| {}
                }
            } else |_| {}
            // Rejected bound-set probes overwrite `target`; restore F(current)
            // before the ordinary same-iteration Anderson seed below.
            try group_residual.residualAt(
                allocator,
                &scratch,
                base,
                current,
                inputs,
                residual_fraction,
                target,
                residual,
            );
            norm = try group_diagnostics.scaledNorm(current, residual, options);
        }
        // Sole tail fallback: relaxed map is evaluated only as an Anderson
        // seed. If the secant is singular or fails the same merit function,
        // report stagnation instead of committing a vanilla Picard step.
        const accepted_tail_anderson = anderson_tail: {
            group_residual.addDirection(
                current,
                residual,
                options.picard_relaxation,
                candidate,
            ) catch break :anderson_tail false;
            group_residual.residualAt(
                allocator,
                &scratch,
                base,
                candidate,
                inputs,
                residual_fraction,
                target,
                candidate_residual,
            ) catch break :anderson_tail false;
            pushAndersonHistory(
                anderson_history_states[0..],
                anderson_history_defects[0..],
                &anderson_history_len,
                anderson_history_depth,
                current,
                residual,
            );
            if (!nonnegativeDampedAndersonCandidate(
                anderson_history_states[0..anderson_history_len],
                anderson_history_defects[0..anderson_history_len],
                candidate,
                candidate_residual,
                probe,
            )) break :anderson_tail false;
            for (probe) |value|
                if (!std.math.isFinite(value) or value < 0)
                    break :anderson_tail false;
            // An Anderson extrapolation is a trial until admissibility and the
            // residual merit check both pass. Never surface a rejected trial as
            // a physical-state error from the production solve.
            group_residual.residualAt(
                allocator,
                &scratch,
                base,
                probe,
                inputs,
                residual_fraction,
                target,
                probe_residual,
            ) catch break :anderson_tail false;
            if (force_speculative_rejection or
                !numerics.andersonImprovesAcceptedMerit(
                    try group_diagnostics.scaledNorm(
                        probe,
                        probe_residual,
                        options,
                    ),
                    norm,
                ) or
                group_diagnostics.vectorsEqual(current, probe))
                break :anderson_tail false;
            break :anderson_tail true;
        };
        if (!accepted_tail_anderson) {
            if (speculative_recovery or replayable_publication_recovery) {
                // A contraction forecast merely prices recovery; it does not
                // prove Newton failure. All probes are private, so retry Newton
                // in the next counted outer slot and suppress repricing until a
                // newly accepted Newton state invalidates the forecast. The
                // final-slot guard above reserves that retry without exceeding
                // the user-provided hard ceiling.
                slow_progress_recovery_pending = false;
                rejected_speculative_recovery_step = newton_steps;
                if (trace) |events| events.next_slot_newton_retries +|= 1;
                speculative_newton_replay = true;
                continue;
            }
            if (options.emit_failure_diagnostics)
                std.log.warn("coupled gas solver stagnated: iteration={d} scaled_residual={e} newton_steps={d} anderson_steps={d} unknowns={d}", .{ iteration + 1, norm, newton_steps, anderson_steps, unknown_count });
            return error.CoupledGasSolverStagnated;
        }
        @memcpy(previous, current);
        @memcpy(previous_residual, residual);
        @memcpy(current, probe);
        current_has_newton_attempt = false;
        newton_retry_required = true;
        anderson_steps += 1;
        slow_newton_norm_count = 0;
        slow_progress_recovery_pending = false;
        rejected_speculative_recovery_step = null;
        std.log.debug("gas solver branch: iteration={d} branch={s} norm_before={e}", .{ iteration + 1, "anderson_tail", norm });
    }
    if (newton_retry_required) {
        if (!builtin.is_test) std.log.warn(
            "TEMP_DIAGNOSTIC coupled-gas ceiling ended before mandatory Newton retry: max_iterations={d} scaled_residual={e} newton_steps={d} anderson_steps={d} transport_iteration_fraction={e}",
            .{ options.max_iterations, last_scaled_residual, newton_steps, anderson_steps, options.transport_iteration_fraction },
        );
        return error.CoupledGasSolverDidNotConverge;
    }
    // Refresh diagnostics for the final accepted iterate; the loop's residual
    // otherwise describes the state before its last Newton/Picard update.
    try group_residual.residualAt(allocator, &scratch, base, current, inputs, residual_fraction, target, residual);
    last_scaled_residual = try group_diagnostics.scaledNorm(current, residual, options);
    // Do not release another complementarity bound here. If the outer loop
    // consumed the hard ceiling, any state-changing "final closure" would be
    // an uncounted nonlinear update. The final residual audit is read-only;
    // a remaining bound must fail and be retried by a transactional substep.
    // No state-changing polish is permitted after the outer loop consumes
    // the user ceiling. A remaining active-set defect fails atomically and is
    // eligible only for a scientifically scaled transactional substep retry.
    if (last_scaled_residual <= 1) {
        const force_invalid_publication = invalid_publication_probes_remaining > 0;
        if (force_invalid_publication) invalid_publication_probes_remaining -= 1;
        const publication_norm = try conservativePublicationNorm(
            allocator,
            &scratch,
            base,
            inputs,
            residual_fraction,
            target,
            candidate,
            probe,
            candidate_residual,
            options,
            options.max_iterations,
            force_invalid_publication,
        );
        if (publication_norm) |verified_norm| {
            if (acceptsConservativePublication(verified_norm, options)) {
                if (group_residual.capturesFluxLedgers(inputs)) try group_residual.residualAtCapturing(allocator, &scratch, base, current, inputs, residual_fraction, target, residual, true);
                group_residual.copyVectorToState(candidate, state);
                if (verified_norm > 1) std.log.debug(
                    "coupled gas solver accepted physically conserved publication: iterate_scaled_residual={e} publication_scaled_residual={e} ceiling={e}",
                    .{ last_scaled_residual, verified_norm, physically_conserved_publication_scaled_ceiling },
                );
                return .{ .iterations = options.max_iterations, .newton_raphson_steps = newton_steps, .picard_steps = anderson_steps, .anderson_steps = anderson_steps, .initial_maximum_scaled_residual = initial_maximum_scaled_residual, .maximum_scaled_residual = verified_norm, .dense_full_jacobian_assemblies = if (dense_full_newton_workspace) |workspace| workspace.assemblies else 0, .krylov_direction_calls = krylov_newton_workspace.direction_calls, .krylov_iterations = krylov_newton_workspace.iterations };
            }
            if (options.emit_failure_diagnostics) std.log.warn(
                "coupled gas solver rejected conservative publication: iterate_scaled_residual={e} publication_scaled_residual={e} physical_ceiling_enabled={}",
                .{ last_scaled_residual, verified_norm, options.accept_physically_conserved_ceiling },
            );
        }
        if (publication_norm == null) {
            if (trace) |events| events.invalid_publication_rejections += 1;
        }
    }
    if (options.emit_failure_diagnostics) {
        var worst_index: usize = 0;
        var worst_scaled: f64 = 0;
        for (current, residual, 0..) |value, difference, index| {
            const scaled = @abs(difference) / (group_misc.absoluteToleranceForCoordinate(options, index, inventory_count) + options.relative_tolerance * @abs(value));
            if (scaled > worst_scaled) {
                worst_scaled = scaled;
                worst_index = index;
            }
        }
        const phase = worst_index / inventory_count;
        const component = worst_index % inventory_count;
        const cell = component / gas.species_count;
        const species = component % gas.species_count;
        std.log.warn("coupled gas solver exhausted runtime ceiling: max_iterations={d} scaled_residual={e} newton_steps={d} anderson_steps={d} phase={d} cell={d} species={d} mass_g={e} residual_g={e} air_volume_m3={e}", .{ options.max_iterations, last_scaled_residual, newton_steps, anderson_steps, phase, cell, species, current[worst_index], residual[worst_index], state.air_volume_m3[cell] });
        for (0..gas.species_count) |diagnostic_species| {
            std.log.warn(
                "coupled gas failure species norm: species={d} scaled_residual={e}",
                .{
                    diagnostic_species,
                    try group_diagnostics.scaledSpeciesNorm(
                        current,
                        residual,
                        options,
                        inventory_count,
                        diagnostic_species,
                    ),
                },
            );
        }
        for (0..3) |diagnostic_phase| {
            const index = diagnostic_phase * inventory_count + component;
            std.log.warn("coupled gas failure phase state: phase={d} base_g={e} iterate_g={e} target_g={e} residual_g={e}", .{ diagnostic_phase, base[index], current[index], target[index], residual[index] });
        }
        for (inputs.faces, 0..) |face, face_index| {
            if (face.first_cell != cell and face.second_cell != cell) continue;
            const first_component = face.first_cell * gas.species_count + species;
            const second_component = face.second_cell * gas.species_count + species;
            std.log.warn("coupled gas failure face: face={d} first_cell={d} second_cell={d} conductance_m3={e} first_g={e} second_g={e}", .{
                face_index,
                face.first_cell,
                face.second_cell,
                inputs.face_conductance_m3_per_step[face_index * gas.species_count + species],
                current[first_component],
                current[second_component],
            });
        }
    }
    return error.CoupledGasSolverDidNotConverge;
}

test "recovery orders Newton then Anderson then immediate Newton retry" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.air_volume_m3, 1);
    @memset(state.temperature_k, 300);
    state.gaseous_mass_g[0] = 2;
    state.dissolved_mass_g[0] = 1;

    const inventory_count = 2 * gas.species_count;
    const conductance = [_]f64{0.01} ** gas.species_count;
    const water = [_]f64{ 1, 1 };
    const no_band_water = [_]f64{ 0, 0 };
    const solubility = [_]f64{1} ** inventory_count;
    const exchange = [_]f64{0.1} ** inventory_count;
    const no_exchange = [_]f64{0} ** inventory_count;
    const no_bubbling = [_]bool{ false, false };
    var trace: SolverTrace = .{};

    const result = try solveControlled(
        std.testing.allocator,
        &state,
        .{
            .faces = &[_]gas.Face{.{ .first_cell = 0, .second_cell = 1 }},
            .face_conductance_m3_per_step = &conductance,
            .atmospheric_boundaries = &.{},
            .water_volume_m3 = &water,
            .band_water_volume_m3 = &no_band_water,
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &exchange,
            .band_gas_water_exchange_rate_per_step = &no_exchange,
            .bubbling_enabled = &no_bubbling,
        },
        .{ .max_iterations = 80 },
        1,
        0,
        &trace,
    );
    try std.testing.expect(trace.len >= 3);
    try std.testing.expectEqual(@as(usize, result.iterations), trace.len);
    try std.testing.expectEqual(SolverEvent.newton_attempt, trace.events[0]);
    try std.testing.expectEqual(SolverEvent.anderson_attempt, trace.events[1]);
    try std.testing.expectEqual(SolverEvent.newton_attempt, trace.events[2]);
    try std.testing.expectEqual(@as(u16, 1), result.anderson_steps);
    // A final conservative publication correction can need another Newton
    // update. It must not change the mandatory Newton/Anderson/Newton order.
    for (trace.events[3..trace.len]) |event|
        try std.testing.expectEqual(SolverEvent.newton_attempt, event);
    // Exclude the deliberately failed first Newton and the Anderson attempt.
    try std.testing.expectEqual(trace.len - 2, @as(usize, result.newton_raphson_steps));
    try std.testing.expectEqual(result.anderson_steps, result.picard_steps);
    try std.testing.expect(result.newton_raphson_steps + result.anderson_steps <= result.iterations);
}

test "coupled gas divergence watch requires consecutive residual explosions" {
    const options: group_misc.Options = .{
        .max_iterations = 8,
        .divergence_patience = 3,
        .divergence_growth_factor = 10,
    };
    var best = std.math.inf(f64);
    var consecutive: u16 = 0;
    try std.testing.expect(!coupledResidualExplosionExceededPatience(2, options, &best, &consecutive));
    try std.testing.expect(!coupledResidualExplosionExceededPatience(30, options, &best, &consecutive));
    try std.testing.expectEqual(@as(u16, 1), consecutive);
    try std.testing.expect(!coupledResidualExplosionExceededPatience(3, options, &best, &consecutive));
    try std.testing.expectEqual(@as(u16, 0), consecutive);
    try std.testing.expect(!coupledResidualExplosionExceededPatience(30, options, &best, &consecutive));
    try std.testing.expect(!coupledResidualExplosionExceededPatience(40, options, &best, &consecutive));
    try std.testing.expect(coupledResidualExplosionExceededPatience(50, options, &best, &consecutive));
}

test "published conservative target independently satisfies nonlinear tolerance" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.air_volume_m3[0] = 1;
    state.temperature_k[0] = 300;
    state.gaseous_mass_g[0] = 1000;

    const inventory_count = gas.species_count;
    const unknown_count = 3 * inventory_count;
    var base: [unknown_count]f64 = undefined;
    group_residual.copyStateToVector(&state, &base);

    const boundary = atmosphere.Boundary{
        .cell_index = 0,
        .aerodynamic_conductance_m3_per_step = 0,
        .interior_conductance_m3_per_step = [_]f64{0} ** gas.species_count,
        .atmospheric_concentration_g_per_m3 = [_]f64{0} ** gas.species_count,
    };
    const water = [_]f64{0};
    const solubility = [_]f64{1} ** inventory_count;
    const no_exchange = [_]f64{0} ** inventory_count;
    const no_bubbling = [_]bool{false};
    var atmospheric_ledger = [_]f64{0} ** inventory_count;
    const inputs: group_misc.Inputs = .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &.{boundary},
        .water_volume_m3 = &water,
        .band_water_volume_m3 = &water,
        .mass_solubility_ratio = &solubility,
        .gas_water_exchange_rate_per_step = &no_exchange,
        .band_gas_water_exchange_rate_per_step = &no_exchange,
        .bubbling_enabled = &no_bubbling,
        .atmospheric_flux_g_by_component = &atmospheric_ledger,
    };
    const options: group_misc.Options = .{
        .absolute_tolerance_g_by_species = @splat(1e-12),
        // At the initial 1000 g iterate the pressure-map defect is scaled
        // below one. Its conservative image is about 488 g, where the exact
        // same absolute defect has a smaller relative denominator and exceeds
        // one. Publishing solely from the iterate check therefore violated
        // the declared nonlinear tolerance.
        .relative_tolerance = 0.75,
        .max_iterations = 8,
    };

    var trace: SolverTrace = .{};
    const result = try solveControlled(
        std.testing.allocator,
        &state,
        inputs,
        options,
        0,
        0,
        &trace,
    );
    try std.testing.expect(result.iterations > 1);
    // The counter records the one accepted Newton promotion after the initial
    // conservative-publication rejection.
    try std.testing.expectEqual(@as(u16, 1), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
    try std.testing.expectEqual(result.anderson_steps, result.picard_steps);
    try std.testing.expect(result.newton_raphson_steps + result.anderson_steps <= options.max_iterations);
    try std.testing.expect(trace.rejected_iterate_norm.? <= 1);
    try std.testing.expect(trace.rejected_publication_norm.? > 1);
    try std.testing.expectEqualSlices(
        SolverEvent,
        &.{
            .publication_reject,
            .newton_attempt,
        },
        trace.events[0..trace.len],
    );

    var published: [unknown_count]f64 = undefined;
    group_residual.copyStateToVector(&state, &published);
    try std.testing.expectApproxEqAbs(
        published[0] - base[0],
        atmospheric_ledger[0],
        16 * std.math.floatEps(f64) * @max(1, @abs(base[0])),
    );
    var scratch = try gas.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    scratch.air_volume_m3[0] = state.air_volume_m3[0];
    scratch.temperature_k[0] = state.temperature_k[0];
    scratch.water_vapor_mol[0] = state.water_vapor_mol[0];
    var target: [unknown_count]f64 = undefined;
    var residual: [unknown_count]f64 = undefined;
    try group_residual.residualAt(
        std.testing.allocator,
        &scratch,
        &base,
        &published,
        inputs,
        options.transport_iteration_fraction,
        &target,
        &residual,
    );
    const published_norm = try group_diagnostics.scaledNorm(
        &published,
        &residual,
        options,
    );
    try std.testing.expect(published_norm <= 1);
    try std.testing.expectApproxEqAbs(
        published_norm,
        result.maximum_scaled_residual,
        16 * std.math.floatEps(f64),
    );
}

test "final counted slot may publish within explicit physical ceiling" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.air_volume_m3[0] = 1;
    state.temperature_k[0] = 300;
    state.gaseous_mass_g[0] = 1000;

    const inventory_count = gas.species_count;
    const boundary = atmosphere.Boundary{
        .cell_index = 0,
        .aerodynamic_conductance_m3_per_step = 0,
        .interior_conductance_m3_per_step = [_]f64{0} ** gas.species_count,
        .atmospheric_concentration_g_per_m3 = [_]f64{0} ** gas.species_count,
    };
    const water = [_]f64{0};
    const solubility = [_]f64{1} ** inventory_count;
    const no_exchange = [_]f64{0} ** inventory_count;
    const no_bubbling = [_]bool{false};
    const inputs: group_misc.Inputs = .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &.{boundary},
        .water_volume_m3 = &water,
        .band_water_volume_m3 = &water,
        .mass_solubility_ratio = &solubility,
        .gas_water_exchange_rate_per_step = &no_exchange,
        .band_gas_water_exchange_rate_per_step = &no_exchange,
        .bubbling_enabled = &no_bubbling,
    };
    const options: group_misc.Options = .{
        .absolute_tolerance_g_by_species = @splat(1e-12),
        .relative_tolerance = 0.9,
        .max_iterations = 1,
        .accept_physically_conserved_ceiling = true,
    };

    const result = try solve(std.testing.allocator, &state, inputs, options);
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    try std.testing.expectEqual(@as(u16, 0), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
    try std.testing.expect(result.maximum_scaled_residual > 1);
    try std.testing.expect(result.maximum_scaled_residual <= physically_conserved_publication_scaled_ceiling);
}

test "invalid publication image is an atomic counted rejection" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.air_volume_m3[0] = 1;
    state.temperature_k[0] = 300;
    state.gaseous_mass_g[0] = 1;

    const inventory_count = gas.species_count;
    var before_gaseous: [inventory_count]f64 = undefined;
    var before_dissolved: [inventory_count]f64 = undefined;
    var before_band: [inventory_count]f64 = undefined;
    @memcpy(&before_gaseous, state.gaseous_mass_g);
    @memcpy(&before_dissolved, state.dissolved_mass_g);
    @memcpy(&before_band, state.band_dissolved_mass_g);
    var atmospheric_ledger = [_]f64{0} ** inventory_count;
    var inputs = group_validation.validationTestInputs();
    inputs.atmospheric_flux_g_by_component = &atmospheric_ledger;
    var trace: SolverTrace = .{};

    // The fixed point is already exact. Force its otherwise-valid publication
    // probe through the same InvalidCoupledGasCandidate catch used by a real
    // inadmissible F(F(current)) image. The rejected probe must neither publish
    // state nor capture flux ledgers. It consumes the sole outer iteration;
    // with no counted slot available for Anderson plus its mandatory Newton
    // retry, no Anderson method attempt may begin.
    try std.testing.expectError(
        error.CoupledGasSolverDidNotConverge,
        solveControlled(
            std.testing.allocator,
            &state,
            inputs,
            .{ .max_iterations = 1 },
            0,
            1,
            &trace,
        ),
    );
    try std.testing.expectEqual(@as(u16, 1), trace.iterations_entered);
    try std.testing.expectEqual(@as(u16, 1), trace.invalid_publication_rejections);
    try std.testing.expectEqual(@as(usize, 2), trace.len);
    try std.testing.expectEqual(SolverEvent.publication_reject, trace.events[0]);
    try std.testing.expectEqual(SolverEvent.newton_attempt, trace.events[1]);
    try std.testing.expectEqual(@as(u16, 0), trace.speculative_anderson_attempts);
    try std.testing.expectEqual(@as(?u16, null), trace.next_slot_newton_retry_iteration);
    try std.testing.expectEqualSlices(f64, &before_gaseous, state.gaseous_mass_g);
    try std.testing.expectEqualSlices(f64, &before_dissolved, state.dissolved_mass_g);
    try std.testing.expectEqualSlices(f64, &before_band, state.band_dissolved_mass_g);
    for (atmospheric_ledger) |entry| try std.testing.expectEqual(@as(f64, 0), entry);
}

test "deterministic no-op Anderson fallback is rejected" {
    var current = [_]f64{0};
    var current_defect = [_]f64{1};
    const seed = [_]f64{0.5};
    const unchanged_defect = [_]f64{1};
    var output = [_]f64{0};
    const history_states = [_][]f64{&current};
    const history_defects = [_][]f64{&current_defect};
    try std.testing.expect(!nonnegativeDampedAndersonCandidate(
        &history_states,
        &history_defects,
        &seed,
        &unchanged_defect,
        &output,
    ));
}

test "zero-history Anderson fallback reduces to the depth-1 secant" {
    var current = [_]f64{0};
    var current_defect = [_]f64{1};
    const seed = [_]f64{0.5};
    const seed_defect = [_]f64{2};
    var output = [_]f64{0};
    const history_states = [_][]f64{&current};
    const history_defects = [_][]f64{&current_defect};
    var single_secant_output = [_]f64{0};
    try std.testing.expect(nonnegativeDampedAndersonCandidate(
        &history_states,
        &history_defects,
        &seed,
        &seed_defect,
        &output,
    ) == numerics.andersonDepthOneCandidate(
        &current,
        &current_defect,
        &seed,
        &seed_defect,
        &single_secant_output,
    ));
}

test "scaled progress watch distinguishes resolved descent from numerical crawling" {
    try std.testing.expect(hasMeaningfulScaledProgress(10, 9));
    try std.testing.expect(!hasMeaningfulScaledProgress(10, 10 - 16 * std.math.floatEps(f64)));
    try std.testing.expect(!hasMeaningfulScaledProgress(std.math.inf(f64), 1));
}

test "slow progress cannot preempt mandatory post-Anderson Newton retry" {
    var slow_progress_count: u8 = 3;
    try std.testing.expect(!coupledGasSlowProgressExceededPatience(
        10,
        10,
        true,
        &slow_progress_count,
    ));
    try std.testing.expectEqual(@as(u8, 4), slow_progress_count);

    // Once that retry has been attempted, another unchanged ordinary iterate
    // is eligible for the normal early-stagnation stop.
    try std.testing.expect(coupledGasSlowProgressExceededPatience(
        10,
        10,
        false,
        &slow_progress_count,
    ));
    try std.testing.expectEqual(@as(u8, 5), slow_progress_count);

    // A productive retry clears the accumulated watch on its next residual.
    try std.testing.expect(!coupledGasSlowProgressExceededPatience(
        10,
        9,
        false,
        &slow_progress_count,
    ));
    try std.testing.expectEqual(@as(u8, 0), slow_progress_count);
}

test "scaled coupled-gas Newton forecast is bounded and ceiling safe" {
    // Four accepted Newton updates reduced the scaled merit by only ten
    // percent. At that measured logarithmic contraction neither eighty nor
    // three remaining slots can reach the unchanged acceptance gate at one.
    // The scheduling owner separately bounds when it spends an Anderson slot.
    try std.testing.expect(slowNewtonProgressNeedsRecovery(
        1000,
        900,
        4,
        80,
    ));
    try std.testing.expect(slowNewtonProgressNeedsRecovery(
        1000,
        900,
        4,
        3,
    ));
    // A rapidly contracting trajectory is left with Newton, and no recovery is
    // requested when its mandatory retry cannot fit inside the hard ceiling.
    try std.testing.expect(!slowNewtonProgressNeedsRecovery(
        1.0e6,
        100,
        4,
        3,
    ));
    try std.testing.expect(!slowNewtonProgressNeedsRecovery(
        1000,
        900,
        4,
        1,
    ));
    try std.testing.expect(!slowNewtonProgressNeedsRecovery(
        1000,
        900,
        3,
        3,
    ));
    try std.testing.expect(!slowNewtonProgressNeedsRecovery(
        1000,
        1,
        4,
        3,
    ));
}

test "rejected speculative Anderson retries Newton in the next counted slot" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.air_volume_m3, 1);
    @memset(state.temperature_k, 300);
    state.gaseous_mass_g[0] = 2;
    state.dissolved_mass_g[0] = 1;

    const inventory_count = 2 * gas.species_count;
    const conductance = [_]f64{0.01} ** gas.species_count;
    const water = [_]f64{ 1, 1 };
    const no_band_water = [_]f64{ 0, 0 };
    const solubility = [_]f64{1} ** inventory_count;
    const exchange = [_]f64{0.1} ** inventory_count;
    const no_exchange = [_]f64{0} ** inventory_count;
    const no_bubbling = [_]bool{ false, false };
    const total_before = state.gaseous_mass_g[0] + state.dissolved_mass_g[0];
    var trace: SolverTrace = .{
        .force_speculative_iteration = 0,
        .reject_speculative_anderson = true,
    };

    const result = try solveControlled(
        std.testing.allocator,
        &state,
        .{
            .faces = &[_]gas.Face{.{ .first_cell = 0, .second_cell = 1 }},
            .face_conductance_m3_per_step = &conductance,
            .atmospheric_boundaries = &.{},
            .water_volume_m3 = &water,
            .band_water_volume_m3 = &no_band_water,
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &exchange,
            .band_gas_water_exchange_rate_per_step = &no_exchange,
            .bubbling_enabled = &no_bubbling,
        },
        .{ .max_iterations = 80 },
        0,
        0,
        &trace,
    );
    try std.testing.expect(trace.speculative_anderson_attempts > 0);
    try std.testing.expectEqual(
        trace.speculative_anderson_attempts,
        trace.next_slot_newton_retries,
    );
    try std.testing.expect(trace.len >= 2);
    try std.testing.expectEqual(SolverEvent.anderson_attempt, trace.events[0]);
    try std.testing.expectEqual(SolverEvent.newton_attempt, trace.events[1]);
    try std.testing.expectEqual(
        trace.speculative_anderson_iteration.? + 1,
        trace.next_slot_newton_retry_iteration.?,
    );
    try std.testing.expect(result.newton_raphson_steps > 0);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
    try std.testing.expect(result.iterations < 80);
    try std.testing.expect(result.newton_raphson_steps + result.anderson_steps <= result.iterations);
    try std.testing.expect(result.iterations <= 80);
    // Every entered nonlinear slot is counted against the user's hard ceiling,
    // including a slot whose speculative Anderson direction is rejected.
    try std.testing.expectEqual(@as(u16, @intCast(result.iterations)), trace.iterations_entered);
    try std.testing.expectApproxEqAbs(
        total_before,
        state.gaseous_mass_g[0] + state.dissolved_mass_g[0] +
            state.gaseous_mass_g[gas.species_count] +
            state.dissolved_mass_g[gas.species_count],
        64 * std.math.floatEps(f64) * total_before,
    );
}
