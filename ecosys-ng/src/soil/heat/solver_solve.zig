//! `solver` declarations: solve.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const grid_module = @import("../../state/grid.zig");
const heat = @import("flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const numerics = @import("../../core/numerics.zig");
const boundary_topology_module = @import("../profile/boundary_topology.zig");
const water_boundary = @import("../water/boundary.zig");
const enthalpy = @import("../water/enthalpy_balance.zig");
const retention = @import("../water/retention.zig");
const group_boundary = @import("solver_boundary.zig");
const group_enthalpy = @import("solver_enthalpy.zig");
const group_misc = @import("solver_misc.zig");
const group_residual = @import("solver_residual.zig");
const group_types = @import("solver_types.zig");
const group_validation = @import("solver_validation.zig");

/// Coordinates tied to the largest independent MJ merit entry form the
/// analytic diagonal active set. A narrow relative band avoids publishing a
/// broad Picard-like correction while still treating roundoff-level ties as
/// one limiting set.
const megajoule_active_set_max_line_search_steps: u8 = 8;

fn stageAdmissibleDirectionProbe(
    current: []const f64,
    direction: []const f64,
    initial_fraction: f64,
    output: []f64,
    maximum_attempts: u8,
) ?f64 {
    var fraction = initial_fraction;
    var attempt: u8 = 0;
    while (attempt < maximum_attempts) : (attempt += 1) {
        group_residual.addDirection(current, direction, fraction, output) catch {
            fraction *= 0.5;
            continue;
        };
        return fraction;
    }
    return null;
}

fn debugPrintIterationResidual(
    _: ?*anyopaque,
    iteration: u16,
    current: []const f64,
    residual: []const f64,
    norm: f64,
) void {
    for (current, residual, 0..) |temperature_k, defect_k, cell|
        std.debug.print(
            "DIAGNOSTIC_TRACE iteration={d} cell={d} temperature_k={e} residual_k={e} norm={e}\n",
            .{ iteration, cell, temperature_k, defect_k, norm },
        );
}

fn debugPrintPricedDirection(
    _: ?*anyopaque,
    direction: []const f64,
    accepted_fraction: ?f64,
    best_norm: f64,
) void {
    for (direction, 0..) |delta, cell|
        std.debug.print(
            "DIAGNOSTIC_TRACE priced_direction cell={d} delta={e}\n",
            .{ cell, delta },
        );
    if (accepted_fraction) |fraction|
        std.debug.print(
            "DIAGNOSTIC_TRACE priced_direction accepted fraction={e} best_norm={e}\n",
            .{ fraction, best_norm },
        )
    else
        std.debug.print(
            "DIAGNOSTIC_TRACE priced_direction rejected best_norm={e}\n",
            .{best_norm},
        );
}

fn debugPrintIceFractionConsistencyCheck(
    _: ?*anyopaque,
    cell: usize,
    properties_fraction_sum: f64,
    coupling_fraction_sum: f64,
) void {
    const delta = properties_fraction_sum - coupling_fraction_sum;
    std.debug.print(
        "DIAGNOSTIC_TRACE ice_fraction_consistency cell={d} properties_sum={e} coupling_sum={e} delta={e}{s}\n",
        .{
            cell,
            properties_fraction_sum,
            coupling_fraction_sum,
            delta,
            if (@abs(delta) > 1e-9) " WARNING: inconsistent baseline fractions" else "",
        },
    );
}

fn debugPrintTransitionProximity(
    _: ?*anyopaque,
    cell: usize,
    temperature_k: f64,
    transition_k: f64,
    kink_radius_k: f64,
    near_domain_transition: bool,
) void {
    const distance_k = @abs(temperature_k - transition_k);
    std.debug.print(
        "DIAGNOSTIC_TRACE transition_proximity cell={d} temperature_k={e} transition_k={e} distance_k={e} kink_radius_k={e} near_domain_transition={} distance_over_radius={e}\n",
        .{
            cell,
            temperature_k,
            transition_k,
            distance_k,
            kink_radius_k,
            near_domain_transition,
            distance_k / kink_radius_k,
        },
    );
}

/// Ready-to-use `DiagnosticTrace` backed by plain `std.debug.print`. Pass
/// `&group_solve.debug_print_trace` as `Options.diagnostic_trace` to enable
/// full per-iteration/per-priced-direction/per-cell-consistency tracing
/// without writing any new instrumentation code.
pub const debug_print_trace: group_types.DiagnosticTrace = .{
    .on_iteration_residual = debugPrintIterationResidual,
    .on_priced_direction = debugPrintPricedDirection,
    .on_ice_fraction_consistency_check = debugPrintIceFractionConsistencyCheck,
    .on_transition_proximity = debugPrintTransitionProximity,
};

/// Anderson history over consistently evaluated fixed-point pairs
/// `(T, g(T)-T)`. In enthalpy-coupled recovery, `g` is the exact per-cell
/// inversion of the simultaneous-face target; the K-equivalent residual is
/// deliberately not substituted for that map defect.
/// `soil/water/solver_solve.zig` keeps the same depth-2-then-depth-1 history for
/// its own vector system; this solver cannot share that helper because it lives
/// in the water group, so the two-slot shift is duplicated here.
fn rememberIteration(
    current: []const f64,
    residual: []const f64,
    previous_state: []f64,
    previous_residual: []f64,
    previous_previous_state: []f64,
    previous_previous_residual: []f64,
    history_count: *u8,
) void {
    if (history_count.* > 0) {
        @memcpy(previous_previous_state, previous_state);
        @memcpy(previous_previous_residual, previous_residual);
    }
    @memcpy(previous_state, current);
    @memcpy(previous_residual, residual);
    history_count.* = @min(@as(u8, 2), history_count.* + 1);
}

const slow_newton_progress_window_updates: u16 = 4;
const slow_newton_progress_history_length: usize = slow_newton_progress_window_updates + 1;
// A conservative full-endpoint audit may discover and publish one Newton-class
// endpoint correction. Keep four slots available for that audit/promotion,
// speculative Anderson, and Anderson's mandatory Newton retry. Once endpoint
// discovery is already complete, only the last two slots are required.
const slow_newton_recovery_reserve: u16 = 4;

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

/// Returns true only when a bounded history of scaled nonlinear merits predicts
/// that the accepted Newton trajectory cannot reach the existing `norm <= 1`
/// gate within the remaining NPH updates. The logarithmic contraction is
/// normalized per accepted Newton update, so this decision is independent of
/// the raw units and magnitudes that formed the scaled merit. It changes only
/// recovery routing: neither the merit nor either acceptance tolerance moves.
pub fn slowNewtonProgressNeedsRecovery(
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

    const observed_log_contraction = @log(window_start_norm) - @log(current_norm);
    if (!std.math.isFinite(observed_log_contraction) or observed_log_contraction <= 0)
        return true;
    const mean_log_contraction = observed_log_contraction /
        @as(f64, @floatFromInt(observed_newton_updates));
    const forecast_log_norm = @log(current_norm) - mean_log_contraction *
        @as(f64, @floatFromInt(remaining_updates));
    return !std.math.isFinite(forecast_log_norm) or forecast_log_norm > 0;
}

/// Full nonlinear descent merit with an independent conservation coordinate.
/// Rejected states use energy-defect ranking, not the trial-dependent relative
/// acceptance denominator; the accepted set (merit <= 1) is unchanged.
fn conservationAwareNorm(
    properties: group_types.Properties,
    base: []const f64,
    state: []const f64,
    residual: []const f64,
    scaled_enthalpy: []const f64,
    enthalpy_coupled: bool,
    options: group_types.Options,
) !f64 {
    return @max(
        try group_residual.scaledNorm(
            state,
            residual,
            scaled_enthalpy,
            enthalpy_coupled,
            options,
        ),
        try group_residual.conservationDescentNorm(
            properties,
            base,
            state,
            residual,
            null,
        ),
    );
}

fn logWorstConservationComponent(
    reason: []const u8,
    properties: group_types.Properties,
    base: []const f64,
    state: []const f64,
    residual: []const f64,
) void {
    if (builtin.is_test) return;
    const maybe_component = group_residual.worstConservationComponent(
        properties,
        base,
        state,
        residual,
    ) catch |err| {
        std.log.err(
            "soil heat conservation diagnostic unavailable: reason={s} error={s}",
            .{ reason, @errorName(err) },
        );
        return;
    };
    if (maybe_component) |component| {
        std.log.err(
            "soil heat worst conservation component: reason={s} cell={d} scaled_norm={e} defect_mj={e} tolerance_mj={e} residual_k={e} derivative_mj_per_k={e} base_temperature_k={e} trial_temperature_k={e} transport_capacity_mj_per_k={e} dry_capacity_mj_per_k={e} coupling_liquid_m3={e} coupling_ice_equivalent_m3={e} parameters_total_water_equivalent_m3={e} parameters_porous_medium_volume_m3={e} capacity_ratio={e} non_phase_heat_mj={e} cell_heat_source_mj={e}",
            .{ reason, component.cell, component.scaled_norm, component.enthalpy_defect_megajoules, component.tolerance_megajoules, component.residual_k, component.derivative_megajoules_per_k, component.base_temperature_k, component.trial_temperature_k, component.transport_heat_capacity_megajoules_per_k, component.dry_solid_heat_capacity_megajoules_per_k, component.coupling_liquid_water_m3, component.coupling_ice_water_equivalent_m3, component.parameters_total_water_equivalent_m3, component.parameters_porous_medium_volume_m3, component.transport_heat_capacity_megajoules_per_k / component.derivative_megajoules_per_k, component.non_phase_heat_megajoules, component.cell_heat_source_megajoules },
        );
        std.log.err(
            "soil heat worst conservation terms: reason={s} cell={d} base_enthalpy_mj={e} trial_enthalpy_mj={e} target_enthalpy_mj={e} non_phase_heat_mj={e} delta_storage_mj={e} interval_activity_mj={e} arithmetic_roundoff_mj={e} temperature_representability_mj={e}",
            .{ reason, component.cell, component.actual_base_enthalpy_megajoules, component.trial_enthalpy_megajoules, component.target_enthalpy_megajoules, component.non_phase_heat_megajoules, component.delta_storage_megajoules, component.interval_activity_megajoules, component.arithmetic_roundoff_megajoules, component.temperature_representability_megajoules },
        );
    }
}

fn logWorstConservationAdjacentProbe(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    current: []const f64,
    target: []f64,
    residual: []f64,
    scaled_enthalpy: []f64,
    adjacent_state: []f64,
    adjacent_residual: []f64,
    adjacent_scaled_enthalpy: []f64,
    trial_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    options: group_types.Options,
    represented_endpoints: ?[]const f64,
) void {
    group_residual.residualAt(
        faces,
        properties,
        water_fluxes,
        base,
        current,
        target,
        residual,
        scaled_enthalpy,
        trial_flux,
        phase_buffers,
        options,
    ) catch return;
    const current_component = if (represented_endpoints) |endpoints| component: {
        @memset(adjacent_residual, 0);
        break :component (group_residual.worstUnresolvedConservationComponent(
            properties,
            base,
            current,
            residual,
            endpoints,
            adjacent_residual,
        ) catch return) orelse return;
    } else (group_residual.worstConservationComponent(
        properties,
        base,
        current,
        residual,
    ) catch return) orelse return;
    const cell = current_component.cell;
    const current_scaled_enthalpy = scaled_enthalpy[cell];
    @memcpy(adjacent_state, current);
    adjacent_state[cell] = std.math.nextAfter(
        f64,
        current[cell],
        if (current_scaled_enthalpy > 0)
            std.math.inf(f64)
        else
            -std.math.inf(f64),
    );
    group_residual.residualAt(
        faces,
        properties,
        water_fluxes,
        base,
        adjacent_state,
        target,
        adjacent_residual,
        adjacent_scaled_enthalpy,
        trial_flux,
        phase_buffers,
        options,
    ) catch return;
    // Select this same cell in the adjacent state. The raw worst component
    // may be an already-proven endpoint in another layer and would pair the
    // wrong defect with the selected temperature in this diagnostic.
    @memset(scaled_enthalpy, 0);
    @memset(target, 1);
    target[cell] = 0;
    const adjacent_component = (group_residual.worstUnresolvedConservationComponent(
        properties,
        base,
        adjacent_state,
        adjacent_residual,
        scaled_enthalpy,
        target,
    ) catch return) orelse return;
    std.log.err(
        "soil heat adjacent conservation probe: endpoint_aware={} cell={d} current_temperature_k={e} adjacent_temperature_k={e} current_residual_k={e} adjacent_residual_k={e} current_scaled_enthalpy={e} adjacent_scaled_enthalpy={e} current_defect_mj={e} adjacent_defect_mj={e} current_conservation_norm={e} adjacent_conservation_norm={e}",
        .{
            represented_endpoints != null,
            cell,
            current[cell],
            adjacent_state[cell],
            residual[cell],
            adjacent_residual[cell],
            current_scaled_enthalpy,
            adjacent_scaled_enthalpy[cell],
            current_component.enthalpy_defect_megajoules,
            adjacent_component.enthalpy_defect_megajoules,
            current_component.scaled_norm,
            adjacent_component.scaled_norm,
        },
    );
    // This failure-only probe shares the solver staging buffers. Restore the
    // reported current state so any following diagnostic sees matching
    // temperatures, residuals, fluxes, and phase candidates.
    group_residual.residualAt(
        faces,
        properties,
        water_fluxes,
        base,
        current,
        target,
        residual,
        scaled_enthalpy,
        trial_flux,
        phase_buffers,
        options,
    ) catch {};
}

/// Failure-only evidence for distinguishing a bad Newton direction from a
/// candidate-dependent conservation scaling barrier. The analytic
/// constitutive correction is evaluated once without publishing it; normal
/// candidate pricing and accepted-state arithmetic are untouched.
fn logDirectConstitutiveRecoveryProbe(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    current: []const f64,
    target: []f64,
    residual: []f64,
    scaled_enthalpy: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    candidate_scaled_enthalpy: []f64,
    trial_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    options: group_types.Options,
) void {
    group_residual.residualAt(
        faces,
        properties,
        water_fluxes,
        base,
        current,
        target,
        residual,
        scaled_enthalpy,
        trial_flux,
        phase_buffers,
        options,
    ) catch return;
    const current_component = (group_residual.worstConservationComponent(
        properties,
        base,
        current,
        residual,
    ) catch return) orelse return;
    const current_nonlinear_norm = group_residual.scaledNorm(
        current,
        residual,
        scaled_enthalpy,
        properties.enthalpy_coupling != null,
        options,
    ) catch return;

    for (current, residual, candidate) |temperature_k, difference_k, *next|
        next.* = temperature_k + difference_k;
    group_residual.residualAt(
        faces,
        properties,
        water_fluxes,
        base,
        candidate,
        target,
        candidate_residual,
        candidate_scaled_enthalpy,
        trial_flux,
        phase_buffers,
        options,
    ) catch return;
    const candidate_nonlinear_norm = group_residual.scaledNorm(
        candidate,
        candidate_residual,
        candidate_scaled_enthalpy,
        properties.enthalpy_coupling != null,
        options,
    ) catch return;
    const candidate_conservation_norm = group_residual.conservationScaledNorm(
        properties,
        base,
        candidate,
        candidate_residual,
    ) catch return;
    const candidate_full_norm = conservationAwareNorm(
        properties,
        base,
        candidate,
        candidate_residual,
        candidate_scaled_enthalpy,
        properties.enthalpy_coupling != null,
        options,
    ) catch return;
    std.log.err(
        "soil heat direct constitutive recovery probe: cell={d} current_temperature_k={e} candidate_temperature_k={e} current_nonlinear_norm={e} candidate_nonlinear_norm={e} current_conservation_norm={e} candidate_conservation_norm={e} candidate_full_norm={e}",
        .{
            current_component.cell,
            current[current_component.cell],
            candidate[current_component.cell],
            current_nonlinear_norm,
            candidate_nonlinear_norm,
            current_component.scaled_norm,
            candidate_conservation_norm,
            candidate_full_norm,
        },
    );
}

/// Prices an Anderson proposal on the same fully recomputed, globally scaled
/// residual used by Newton. Backtracking probes are not state promotions; the
/// caller publishes at most the best candidate after every Anderson depth has
/// been considered.
fn priceAndersonDirection(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    current: []const f64,
    proposed: []const f64,
    target: []f64,
    best_candidate: []f64,
    best_norm: *f64,
    trial_state: []f64,
    trial_residual: []f64,
    scratch: []f64,
    trial_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    options: group_types.Options,
) !bool {
    var improved = false;
    var fraction: f64 = 1;
    var line_search: u8 = 0;
    while (line_search < 8) : (line_search += 1) {
        var admissible = true;
        for (current, proposed, trial_state) |value, accelerated, *trial| {
            trial.* = value + fraction * (accelerated - value);
            if (!group_validation.isPhysicalTemperatureK(trial.*)) {
                admissible = false;
                break;
            }
        }
        if (admissible) {
            if (group_residual.residualAt(
                faces,
                properties,
                water_fluxes,
                base,
                trial_state,
                target,
                trial_residual,
                scratch,
                trial_flux,
                phase_buffers,
                options,
            )) |_| {
                const norm = try conservationAwareNorm(
                    properties,
                    base,
                    trial_state,
                    trial_residual,
                    scratch,
                    properties.enthalpy_coupling != null,
                    options,
                );
                if (norm < best_norm.*) {
                    @memcpy(best_candidate, trial_state);
                    best_norm.* = norm;
                    improved = true;
                }
            } else |_| {}
        }
        fraction *= 0.5;
    }
    return improved;
}

const PricedNewtonDirection = struct {
    fraction: f64,
    full_step_improved: bool,
    endpoint_proof_valid: bool = false,
};

/// REAL-DECK-HOUR-11-FATAL-STAGNATION-001 (2026-09-04): rejects a finite but
/// physically absurd soil temperature before it can be committed and poison
/// downstream solves. A real production run reached ~125.5 K in a top soil
/// layer through this dense solver's commit path -- `validateFinite` alone
/// does not catch this, since the value is finite. Every sibling scalar
/// solver (`ground_air_exchange.zig`, `surface/temperature_solver.zig`,
/// `enthalpy_balance.zig`) already enforces this same [173.15, 373.15] K
/// domain via `numerics.newtonPicard`'s bracket; this is the equivalent gate
/// for this solver's own dense multi-layer commit.
pub fn validateSoilTemperaturePhysicalDomain(temperature_k: []const f64) !void {
    return group_validation.validateSoilTemperaturePhysicalDomain(temperature_k);
}

/// Commits an accepted nonlinear state as one externally visible transaction.
/// Every fallible check is completed against the staged temperature, phase,
/// boundary ledger, and face flux before the first caller-owned slice changes.
fn commitAcceptedState(
    grid: *grid_module.GridState,
    properties: group_types.Properties,
    accepted_temperature_k: []const f64,
    phase_buffers: group_misc.PhaseBuffers,
    staged_heat_flux_megajoules: []const f64,
    heat_flux_megajoules: []f64,
) !group_boundary.BoundaryHeat {
    // Validate the still-accepted state first as a guard against committing on
    // top of unrelated corruption. `residualAt` has already validated the
    // staged temperatures; phase preflight validates every prospective water
    // and derived-air owner without publishing any of them.
    try grid.validateFinite();
    // REAL-DECK-HOUR-11-FATAL-STAGNATION-001 (2026-09-04): `validateFinite`
    // rejects NaN/Inf but not a finite, physically absurd temperature. A
    // real production run accepted a top-layer soil_temperature_k of
    // ~125.5 K (colder than any terrestrial surface condition) through this
    // exact commit path with no bound check, which then poisoned the
    // downstream surface energy balance (its own solver correctly rejected
    // that subsurface input, but only after the damage was already
    // committed here). Every sibling scalar solver in this codebase
    // (ground_air_exchange.zig, surface/temperature_solver.zig,
    // enthalpy_balance.zig) already enforces this same [173.15, 373.15] K
    // domain via `numerics.newtonPicard`'s bracket; this dense multi-layer
    // solver had no equivalent. This tightens validation only -- any
    // temperature a normal converged solve would ever produce is already
    // far inside this band, so no previously-accepted state is affected.
    try validateSoilTemperaturePhysicalDomain(accepted_temperature_k);
    if (properties.enthalpy_coupling != null)
        try group_residual.validateMatrixPhaseUpdate(grid, phase_buffers);
    const boundary_heat = try group_boundary.acceptedBoundaryHeat(
        properties,
        accepted_temperature_k,
        phase_buffers,
    );

    @memcpy(grid.soil_temperature_k, accepted_temperature_k);
    if (properties.enthalpy_coupling != null)
        group_residual.publishValidatedMatrixPhaseUpdate(grid, phase_buffers);
    @memcpy(heat_flux_megajoules, staged_heat_flux_megajoules);
    return boundary_heat;
}

/// Re-proves adjacent-f64 enthalpy endpoints after the last permitted update.
/// This audit never promotes the neighboring state. Either member of a proven
/// adjacent bracket is a valid representation of the real-valued root when
/// that current member satisfies the unchanged represented merit; deterministic
/// lower-merit selection remains a state-promotion rule, not an extra
/// convergence requirement.
pub fn probeOnlyFinalRepresentableNorm(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    current: []const f64,
    target: []f64,
    current_residual: []f64,
    current_scaled_enthalpy: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    candidate_scaled_enthalpy: []f64,
    checked: []f64,
    proven_mask: []f64,
    trial_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    options: group_types.Options,
    probe_count: *u32,
) !f64 {
    if (properties.enthalpy_coupling == null)
        return conservationAwareNorm(
            properties,
            base,
            current,
            current_residual,
            current_scaled_enthalpy,
            false,
            options,
        );

    @memset(checked, 0);
    @memset(proven_mask, 0);
    var representable_norm = try conservationAwareNorm(
        properties,
        base,
        current,
        current_residual,
        current_scaled_enthalpy,
        true,
        options,
    );
    // No endpoint probe has touched the shared phase/flux staging buffers, so
    // raw convergence can return immediately without re-evaluating the same
    // full residual a second time.
    if (representable_norm <= 1) return representable_norm;
    var checks: usize = 0;
    while (representable_norm > 1 and checks < current.len) : (checks += 1) {
        var limiting_cell: usize = 0;
        var limiting_coordinate: f64 = 1;
        var found = false;
        for (current_scaled_enthalpy, checked, 0..) |scaled_enthalpy, was_checked, cell| {
            if (was_checked != 0) continue;
            const coordinate = @abs(scaled_enthalpy);
            if (coordinate > limiting_coordinate) {
                limiting_coordinate = coordinate;
                limiting_cell = cell;
                found = true;
            }
        }
        if (try group_residual.worstUnresolvedConservationComponent(
            properties,
            base,
            current,
            current_residual,
            proven_mask,
            checked,
        )) |component| {
            if (component.scaled_norm > limiting_coordinate) {
                limiting_coordinate = component.scaled_norm;
                limiting_cell = component.cell;
                found = true;
            }
        }
        if (!found) break;
        checked[limiting_cell] = 1;

        @memcpy(candidate, current);
        candidate[limiting_cell] = std.math.nextAfter(
            f64,
            current[limiting_cell],
            if (current_scaled_enthalpy[limiting_cell] > 0)
                std.math.inf(f64)
            else
                -std.math.inf(f64),
        );
        if (candidate[limiting_cell] == current[limiting_cell]) continue;
        probe_count.* += 1;
        group_residual.residualAt(
            faces,
            properties,
            water_fluxes,
            base,
            candidate,
            target,
            candidate_residual,
            candidate_scaled_enthalpy,
            trial_flux,
            phase_buffers,
            options,
        ) catch continue;
        const candidate_coordinate = candidate_scaled_enthalpy[limiting_cell];
        const brackets_root = candidate_coordinate == 0 or
            std.math.signbit(candidate_coordinate) !=
                std.math.signbit(current_scaled_enthalpy[limiting_cell]);
        if (!brackets_root) continue;

        // Price both adjacent states under the same represented system: the
        // active sub-ULP MJ coordinate and every earlier proven endpoint are
        // masked, while K and all smooth/coupled MJ coordinates remain live.
        proven_mask[limiting_cell] = 1;
        for (proven_mask, candidate_scaled_enthalpy) |recognized, *scaled_enthalpy| {
            if (recognized != 0) scaled_enthalpy.* = 0;
        }
        @memcpy(candidate_scaled_enthalpy, current_scaled_enthalpy);
        for (proven_mask, candidate_scaled_enthalpy) |recognized, *scaled_enthalpy| {
            if (recognized != 0) scaled_enthalpy.* = 0;
        }
        const current_norm = try conservationAwareMaskedEndpointNorm(
            properties,
            base,
            current,
            current_residual,
            candidate_scaled_enthalpy,
            proven_mask,
            options,
        );
        // Endpoint ranking chooses which state to publish while an update is
        // still available. At the exhausted-loop audit the current state is
        // immutable, and the exact sign bracket plus its one-ULP energy width
        // is the certificate. Rejecting a current norm already <= 1 merely
        // because the adjacent state is lower (or wins the deterministic tie)
        // would turn state selection into an unrequested zero-tolerance gate.
        representable_norm = current_norm;
    }

    // Probes share phase and flux staging buffers; restore the current state
    // before the caller performs its atomic accepted-state preflight.
    try group_residual.residualAt(
        faces,
        properties,
        water_fluxes,
        base,
        current,
        target,
        current_residual,
        current_scaled_enthalpy,
        trial_flux,
        phase_buffers,
        options,
    );
    @memcpy(candidate_scaled_enthalpy, current_scaled_enthalpy);
    for (proven_mask, candidate_scaled_enthalpy) |recognized, *scaled_enthalpy| {
        if (recognized != 0) scaled_enthalpy.* = 0;
    }
    return conservationAwareMaskedEndpointNorm(
        properties,
        base,
        current,
        current_residual,
        candidate_scaled_enthalpy,
        proven_mask,
        options,
    );
}

/// Full-system merit for an endpoint state after removing only MJ coordinates
/// already proven unrepresentable between adjacent f64 temperatures. The K
/// gate and every unmasked smooth/coupled MJ coordinate remain active; the
/// conservation gate gains only that proven one-ULP constitutive energy width.
pub fn representedEndpointNorm(
    temperature_k: []const f64,
    residual_k: []const f64,
    scaled_enthalpy: []const f64,
    recognized_endpoints: []const f64,
    masked_scaled_enthalpy: []f64,
    options: group_types.Options,
) !f64 {
    if (temperature_k.len != residual_k.len or
        temperature_k.len != scaled_enthalpy.len or
        temperature_k.len != recognized_endpoints.len or
        temperature_k.len != masked_scaled_enthalpy.len)
        return error.SoilHeatEndpointMeritDimensionMismatch;
    @memcpy(masked_scaled_enthalpy, scaled_enthalpy);
    for (recognized_endpoints, masked_scaled_enthalpy) |recognized, *coordinate| {
        if (recognized != 0) coordinate.* = 0;
    }
    return group_residual.scaledNorm(
        temperature_k,
        residual_k,
        masked_scaled_enthalpy,
        true,
        options,
    );
}

pub fn conservationAwareRepresentedEndpointNorm(
    properties: group_types.Properties,
    base: []const f64,
    temperature_k: []const f64,
    residual_k: []const f64,
    scaled_enthalpy: []const f64,
    recognized_endpoints: []const f64,
    masked_scaled_enthalpy: []f64,
    options: group_types.Options,
) !f64 {
    return @max(
        try representedEndpointNorm(
            temperature_k,
            residual_k,
            scaled_enthalpy,
            recognized_endpoints,
            masked_scaled_enthalpy,
            options,
        ),
        try group_residual.conservationDescentNorm(
            properties,
            base,
            temperature_k,
            residual_k,
            recognized_endpoints,
        ),
    );
}

fn conservationAwareMaskedEndpointNorm(
    properties: group_types.Properties,
    base: []const f64,
    temperature_k: []const f64,
    residual_k: []const f64,
    masked_scaled_enthalpy: []const f64,
    represented_endpoints: []const f64,
    options: group_types.Options,
) !f64 {
    return @max(
        try group_residual.scaledNorm(
            temperature_k,
            residual_k,
            masked_scaled_enthalpy,
            true,
            options,
        ),
        try group_residual.conservationDescentNorm(
            properties,
            base,
            temperature_k,
            residual_k,
            represented_endpoints,
        ),
    );
}

/// Deterministic endpoint selection shared by discovery, repricing, and the
/// exhausted-loop audit. Equal represented merit selects the lower
/// temperature, matching the established lower/upper relocation policy.
pub fn preferAlternativeRepresentedEndpoint(
    current_norm: f64,
    current_temperature_k: f64,
    alternative_norm: f64,
    alternative_temperature_k: f64,
) bool {
    return alternative_norm < current_norm or
        (alternative_norm == current_norm and
            alternative_temperature_k < current_temperature_k);
}

/// A phase root is representably complete only at an exact evaluated root or
/// between adjacent f64 temperatures. A bounded real-valued bisection may
/// exhaust its probe budget while many representable temperatures remain.
pub fn isExactOrAdjacentEndpointBracket(
    lower_temperature_k: f64,
    upper_temperature_k: f64,
) bool {
    return lower_temperature_k == upper_temperature_k or
        std.math.nextAfter(
            f64,
            lower_temperature_k,
            std.math.inf(f64),
        ) == upper_temperature_k;
}

const CellEnthalpyTransitions = struct {
    matrix_temperature_k: f64,
    secondary_temperature_k: ?f64,

    fn fromParameters(parameters: enthalpy.Parameters) CellEnthalpyTransitions {
        return .{
            .matrix_temperature_k = enthalpy.depressedMeltingTemperatureK(
                parameters,
                parameters.unfrozen_pressure_head_m,
            ),
            .secondary_temperature_k = if (parameters.secondary_domain) |secondary|
                enthalpy.depressedMeltingTemperatureK(
                    parameters,
                    secondary.unfrozen_pressure_head_m,
                )
            else
                null,
        };
    }

    fn nearestDistanceK(self: CellEnthalpyTransitions, temperature_k: f64) f64 {
        var distance_k = @abs(temperature_k - self.matrix_temperature_k);
        if (self.secondary_temperature_k) |secondary_temperature_k|
            distance_k = @min(
                distance_k,
                @abs(temperature_k - secondary_temperature_k),
            );
        return distance_k;
    }

    fn distanceInDirectionK(
        self: CellEnthalpyTransitions,
        temperature_k: f64,
        direction: f64,
    ) f64 {
        var distance_k = std.math.inf(f64);
        if (direction > 0 and temperature_k < self.matrix_temperature_k)
            distance_k = self.matrix_temperature_k - temperature_k
        else if (direction < 0 and temperature_k > self.matrix_temperature_k)
            distance_k = temperature_k - self.matrix_temperature_k;
        if (self.secondary_temperature_k) |secondary_temperature_k| {
            if (direction > 0 and temperature_k < secondary_temperature_k)
                distance_k = @min(
                    distance_k,
                    secondary_temperature_k - temperature_k,
                )
            else if (direction < 0 and temperature_k > secondary_temperature_k)
                distance_k = @min(
                    distance_k,
                    temperature_k - secondary_temperature_k,
                );
        }
        return distance_k;
    }

    fn firstCrossedTemperatureK(
        self: CellEnthalpyTransitions,
        temperature_k: f64,
        predicted_temperature_k: f64,
    ) ?f64 {
        if (!std.math.isFinite(predicted_temperature_k) or
            predicted_temperature_k <= 0 or
            predicted_temperature_k == temperature_k)
            return null;

        var crossed_temperature_k: ?f64 = null;
        if (predicted_temperature_k > temperature_k) {
            if (temperature_k < self.matrix_temperature_k and
                self.matrix_temperature_k <= predicted_temperature_k)
                crossed_temperature_k = self.matrix_temperature_k;
            if (self.secondary_temperature_k) |secondary_temperature_k| {
                if (temperature_k < secondary_temperature_k and
                    secondary_temperature_k <= predicted_temperature_k and
                    (crossed_temperature_k == null or
                        secondary_temperature_k < crossed_temperature_k.?))
                    crossed_temperature_k = secondary_temperature_k;
            }
        } else {
            if (predicted_temperature_k < self.matrix_temperature_k and
                self.matrix_temperature_k <= temperature_k)
                crossed_temperature_k = self.matrix_temperature_k;
            if (self.secondary_temperature_k) |secondary_temperature_k| {
                if (predicted_temperature_k < secondary_temperature_k and
                    secondary_temperature_k <= temperature_k and
                    (crossed_temperature_k == null or
                        secondary_temperature_k > crossed_temperature_k.?))
                    crossed_temperature_k = secondary_temperature_k;
            }
        }
        return crossed_temperature_k;
    }
};

/// Re-establishes every proven adjacent-f64 enthalpy bracket after a Newton
/// candidate changes neighbouring temperatures. Both endpoints are evaluated
/// through the complete coupled residual; only then is that unrepresentable MJ
/// coordinate masked and the lower global merit endpoint retained. The caller
/// owns promotion, so this helper mutates only its candidate/work buffers.
pub fn repriceAdjacentEnthalpyEndpoints(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    candidate: []f64,
    recognized_endpoints: []const f64,
    target: []f64,
    candidate_residual: []f64,
    scratch: []f64,
    endpoint_state: []f64,
    endpoint_residual: []f64,
    saved_scaled_enthalpy: []f64,
    proven_mask: []f64,
    trial_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    options: group_types.Options,
    probe_count: *u32,
) !?f64 {
    var endpoint_count: usize = 0;
    for (recognized_endpoints) |recognized| {
        if (recognized != 0) endpoint_count += 1;
    }
    if (endpoint_count == 0) return null;

    // Common case: the neighbour-changing Newton proposal leaves every
    // endpoint at the same adjacent-f64 bracket. Prove all brackets and price
    // every alternative against the same settled candidate before invoking
    // the predictor/bisection relocation path. This costs O(k) residuals for
    // k endpoints instead of repeating a full residual at every sequential
    // substep and sweep.
    probe_count.* += 1;
    group_residual.residualAt(
        faces,
        properties,
        water_fluxes,
        base,
        candidate,
        target,
        candidate_residual,
        saved_scaled_enthalpy,
        trial_flux,
        phase_buffers,
        options,
    ) catch return null;
    var settled_proof_valid = true;
    var probed_alternative = false;
    for (recognized_endpoints, 0..) |recognized, cell| {
        if (recognized == 0) continue;
        const current_enthalpy = saved_scaled_enthalpy[cell];
        if (current_enthalpy == 0) continue;
        @memcpy(endpoint_state, candidate);
        endpoint_state[cell] = std.math.nextAfter(
            f64,
            candidate[cell],
            if (current_enthalpy > 0)
                std.math.inf(f64)
            else
                -std.math.inf(f64),
        );
        if (endpoint_state[cell] == candidate[cell]) {
            settled_proof_valid = false;
            break;
        }
        probe_count.* += 1;
        probed_alternative = true;
        group_residual.residualAt(
            faces,
            properties,
            water_fluxes,
            base,
            endpoint_state,
            target,
            endpoint_residual,
            scratch,
            trial_flux,
            phase_buffers,
            options,
        ) catch {
            settled_proof_valid = false;
            break;
        };
        const adjacent_enthalpy = scratch[cell];
        if (adjacent_enthalpy != 0 and
            std.math.signbit(adjacent_enthalpy) ==
                std.math.signbit(current_enthalpy))
        {
            settled_proof_valid = false;
            break;
        }

        // Mask every recognized endpoint while pricing this pair. The
        // comparison retains the K gate and every smooth/coupled residual
        // affected by the switch, but no unrepresentable raw MJ coordinate.
        const current_norm = try conservationAwareRepresentedEndpointNorm(
            properties,
            base,
            candidate,
            candidate_residual,
            saved_scaled_enthalpy,
            recognized_endpoints,
            proven_mask,
            options,
        );
        const alternative_norm = try conservationAwareRepresentedEndpointNorm(
            properties,
            base,
            endpoint_state,
            endpoint_residual,
            scratch,
            recognized_endpoints,
            proven_mask,
            options,
        );
        if (preferAlternativeRepresentedEndpoint(
            current_norm,
            candidate[cell],
            alternative_norm,
            endpoint_state[cell],
        )) {
            settled_proof_valid = false;
            break;
        }
    }
    if (settled_proof_valid) {
        if (probed_alternative) {
            probe_count.* += 1;
            try group_residual.residualAt(
                faces,
                properties,
                water_fluxes,
                base,
                candidate,
                target,
                candidate_residual,
                scratch,
                trial_flux,
                phase_buffers,
                options,
            );
            @memcpy(saved_scaled_enthalpy, scratch);
        }
        for (recognized_endpoints, proven_mask, saved_scaled_enthalpy) |recognized, *proven, *scaled_enthalpy| {
            proven.* = if (recognized != 0) 1 else 0;
            if (recognized != 0) scaled_enthalpy.* = 0;
        }
        return @as(?f64, try conservationAwareMaskedEndpointNorm(
            properties,
            base,
            candidate,
            candidate_residual,
            saved_scaled_enthalpy,
            proven_mask,
            options,
        ));
    }

    // A neighbour-changing Newton proposal can move an endpoint root by many
    // ULPs. Re-project every recognized coordinate with its analytic K-defect
    // predictor, then narrow an actual signed-MJ bracket to adjacent f64s.
    // Gauss-Seidel sweeps are repeated because relocating a later coordinate
    // can move an earlier coupled root. No result is publishable until a final
    // simultaneous full-residual pass re-proves every discrete endpoint.
    const maximum_sweeps = 2 * endpoint_count + 2;
    var sweep: usize = 0;
    while (sweep < maximum_sweeps) : (sweep += 1) {
        var sweep_changed = false;
        @memset(proven_mask, 0);

        for (recognized_endpoints, 0..) |recognized, cell| {
            if (recognized == 0) continue;
            const starting_temperature_k = candidate[cell];

            probe_count.* += 1;
            group_residual.residualAt(
                faces,
                properties,
                water_fluxes,
                base,
                candidate,
                target,
                candidate_residual,
                scratch,
                trial_flux,
                phase_buffers,
                options,
            ) catch return null;
            var endpoint_a_temperature_k = candidate[cell];
            var endpoint_a_enthalpy = scratch[cell];
            if (endpoint_a_enthalpy == 0) {
                proven_mask[cell] = 1;
                continue;
            }

            var endpoint_b_temperature_k =
                endpoint_a_temperature_k + candidate_residual[cell];
            if (!std.math.isFinite(endpoint_b_temperature_k) or
                endpoint_b_temperature_k <= 0 or
                endpoint_b_temperature_k == endpoint_a_temperature_k)
            {
                endpoint_b_temperature_k = std.math.nextAfter(
                    f64,
                    endpoint_a_temperature_k,
                    if (endpoint_a_enthalpy > 0)
                        std.math.inf(f64)
                    else
                        -std.math.inf(f64),
                );
            }
            if (endpoint_b_temperature_k == endpoint_a_temperature_k)
                return null;

            var endpoint_b_enthalpy: f64 = undefined;
            var predictor_attempt: u8 = 0;
            while (predictor_attempt < 12) : (predictor_attempt += 1) {
                @memcpy(endpoint_state, candidate);
                endpoint_state[cell] = endpoint_b_temperature_k;
                probe_count.* += 1;
                group_residual.residualAt(
                    faces,
                    properties,
                    water_fluxes,
                    base,
                    endpoint_state,
                    target,
                    endpoint_residual,
                    scratch,
                    trial_flux,
                    phase_buffers,
                    options,
                ) catch return null;
                endpoint_b_enthalpy = scratch[cell];
                if (endpoint_b_enthalpy == 0 or
                    std.math.signbit(endpoint_b_enthalpy) !=
                        std.math.signbit(endpoint_a_enthalpy))
                    break;

                endpoint_a_temperature_k = endpoint_b_temperature_k;
                endpoint_a_enthalpy = endpoint_b_enthalpy;
                var next_temperature_k =
                    endpoint_b_temperature_k + endpoint_residual[cell];
                if (!std.math.isFinite(next_temperature_k) or
                    next_temperature_k <= 0 or
                    next_temperature_k == endpoint_b_temperature_k)
                {
                    next_temperature_k = std.math.nextAfter(
                        f64,
                        endpoint_b_temperature_k,
                        if (endpoint_b_enthalpy > 0)
                            std.math.inf(f64)
                        else
                            -std.math.inf(f64),
                    );
                }
                if (next_temperature_k == endpoint_b_temperature_k)
                    return null;
                endpoint_b_temperature_k = next_temperature_k;
            }
            if (endpoint_b_enthalpy == 0) {
                @memcpy(candidate, endpoint_state);
                @memcpy(candidate_residual, endpoint_residual);
                sweep_changed = sweep_changed or
                    candidate[cell] != starting_temperature_k;
                proven_mask[cell] = 1;
                continue;
            }
            if (std.math.signbit(endpoint_b_enthalpy) ==
                std.math.signbit(endpoint_a_enthalpy)) return null;

            var lower_temperature_k: f64 = undefined;
            var upper_temperature_k: f64 = undefined;
            var lower_enthalpy_positive: bool = undefined;
            if (endpoint_a_temperature_k < endpoint_b_temperature_k) {
                lower_temperature_k = endpoint_a_temperature_k;
                upper_temperature_k = endpoint_b_temperature_k;
                lower_enthalpy_positive = !std.math.signbit(endpoint_a_enthalpy);
            } else {
                lower_temperature_k = endpoint_b_temperature_k;
                upper_temperature_k = endpoint_a_temperature_k;
                lower_enthalpy_positive = !std.math.signbit(endpoint_b_enthalpy);
            }

            // The predictor supplies a physical bracket; bisection terminates
            // on representational adjacency, not an arbitrary tolerance.
            var bisection_step: u8 = 0;
            while (bisection_step < 64 and
                std.math.nextAfter(
                    f64,
                    lower_temperature_k,
                    std.math.inf(f64),
                ) != upper_temperature_k) : (bisection_step += 1)
            {
                const midpoint_temperature_k = lower_temperature_k +
                    0.5 * (upper_temperature_k - lower_temperature_k);
                if (midpoint_temperature_k == lower_temperature_k or
                    midpoint_temperature_k == upper_temperature_k)
                    break;
                @memcpy(endpoint_state, candidate);
                endpoint_state[cell] = midpoint_temperature_k;
                probe_count.* += 1;
                group_residual.residualAt(
                    faces,
                    properties,
                    water_fluxes,
                    base,
                    endpoint_state,
                    target,
                    endpoint_residual,
                    scratch,
                    trial_flux,
                    phase_buffers,
                    options,
                ) catch return null;
                const midpoint_enthalpy = scratch[cell];
                if (midpoint_enthalpy == 0) {
                    lower_temperature_k = midpoint_temperature_k;
                    upper_temperature_k = midpoint_temperature_k;
                    break;
                }
                if ((!std.math.signbit(midpoint_enthalpy)) ==
                    lower_enthalpy_positive)
                    lower_temperature_k = midpoint_temperature_k
                else
                    upper_temperature_k = midpoint_temperature_k;
            }

            // Never certify a bracket merely because the bounded probe loop
            // ended. Remaining representable temperatures mean the MJ root
            // is still movable and ordinary recovery must continue.
            if (!isExactOrAdjacentEndpointBracket(
                lower_temperature_k,
                upper_temperature_k,
            )) return null;

            candidate[cell] = lower_temperature_k;
            probe_count.* += 1;
            group_residual.residualAt(
                faces,
                properties,
                water_fluxes,
                base,
                candidate,
                target,
                candidate_residual,
                saved_scaled_enthalpy,
                trial_flux,
                phase_buffers,
                options,
            ) catch return null;
            if (lower_temperature_k == upper_temperature_k) {
                @memcpy(scratch, saved_scaled_enthalpy);
                sweep_changed = sweep_changed or
                    candidate[cell] != starting_temperature_k;
                proven_mask[cell] = 1;
                continue;
            }

            @memcpy(endpoint_state, candidate);
            endpoint_state[cell] = upper_temperature_k;
            probe_count.* += 1;
            group_residual.residualAt(
                faces,
                properties,
                water_fluxes,
                base,
                endpoint_state,
                target,
                endpoint_residual,
                scratch,
                trial_flux,
                phase_buffers,
                options,
            ) catch return null;
            if (saved_scaled_enthalpy[cell] != 0 and scratch[cell] != 0 and
                std.math.signbit(saved_scaled_enthalpy[cell]) ==
                    std.math.signbit(scratch[cell])) return null;

            for (recognized_endpoints, saved_scaled_enthalpy, scratch) |endpoint, *lower_scaled, *upper_scaled| {
                if (endpoint != 0) {
                    lower_scaled.* = 0;
                    upper_scaled.* = 0;
                }
            }
            const lower_norm = try conservationAwareMaskedEndpointNorm(
                properties,
                base,
                candidate,
                candidate_residual,
                saved_scaled_enthalpy,
                recognized_endpoints,
                options,
            );
            const upper_norm = try conservationAwareMaskedEndpointNorm(
                properties,
                base,
                endpoint_state,
                endpoint_residual,
                scratch,
                recognized_endpoints,
                options,
            );
            if (preferAlternativeRepresentedEndpoint(
                lower_norm,
                lower_temperature_k,
                upper_norm,
                upper_temperature_k,
            )) {
                @memcpy(candidate, endpoint_state);
                @memcpy(candidate_residual, endpoint_residual);
            } else {
                @memcpy(scratch, saved_scaled_enthalpy);
            }
            sweep_changed = sweep_changed or
                candidate[cell] != starting_temperature_k;
            proven_mask[cell] = 1;
        }

        // With one endpoint, the selected lower-merit state and its adjacent
        // alternative were evaluated against identical neighbour coordinates
        // immediately above. That pair is already the simultaneous settled
        // certificate; repeating selected/adjacent/selected residuals cannot
        // add information and dominated the freezing-column hot path.
        if (endpoint_count == 1) {
            for (recognized_endpoints, proven_mask, scratch) |recognized, *proven, *scaled_enthalpy| {
                proven.* = if (recognized != 0) 1 else 0;
                if (recognized != 0) scaled_enthalpy.* = 0;
            }
            return @as(?f64, try conservationAwareMaskedEndpointNorm(
                properties,
                base,
                candidate,
                candidate_residual,
                scratch,
                proven_mask,
                options,
            ));
        }

        // Simultaneous atomic proof: every endpoint is checked against the
        // same candidate, after all sequential relocations in this sweep.
        probe_count.* += 1;
        group_residual.residualAt(
            faces,
            properties,
            water_fluxes,
            base,
            candidate,
            target,
            candidate_residual,
            saved_scaled_enthalpy,
            trial_flux,
            phase_buffers,
            options,
        ) catch return null;
        @memset(proven_mask, 0);
        var simultaneously_proven = true;
        for (recognized_endpoints, 0..) |recognized, cell| {
            if (recognized == 0) continue;
            const current_enthalpy = saved_scaled_enthalpy[cell];
            if (current_enthalpy == 0) {
                proven_mask[cell] = 1;
                continue;
            }
            @memcpy(endpoint_state, candidate);
            endpoint_state[cell] = std.math.nextAfter(
                f64,
                candidate[cell],
                if (current_enthalpy > 0)
                    std.math.inf(f64)
                else
                    -std.math.inf(f64),
            );
            if (endpoint_state[cell] == candidate[cell]) {
                simultaneously_proven = false;
                break;
            }
            probe_count.* += 1;
            group_residual.residualAt(
                faces,
                properties,
                water_fluxes,
                base,
                endpoint_state,
                target,
                endpoint_residual,
                scratch,
                trial_flux,
                phase_buffers,
                options,
            ) catch return null;
            const adjacent_enthalpy = scratch[cell];
            if (adjacent_enthalpy != 0 and
                std.math.signbit(adjacent_enthalpy) ==
                    std.math.signbit(current_enthalpy))
            {
                simultaneously_proven = false;
                break;
            }
            const settled_current_norm = try conservationAwareRepresentedEndpointNorm(
                properties,
                base,
                candidate,
                candidate_residual,
                saved_scaled_enthalpy,
                recognized_endpoints,
                proven_mask,
                options,
            );
            const settled_alternative_norm = try conservationAwareRepresentedEndpointNorm(
                properties,
                base,
                endpoint_state,
                endpoint_residual,
                scratch,
                recognized_endpoints,
                proven_mask,
                options,
            );
            if (preferAlternativeRepresentedEndpoint(
                settled_current_norm,
                candidate[cell],
                settled_alternative_norm,
                endpoint_state[cell],
            )) {
                @memcpy(candidate, endpoint_state);
                @memcpy(candidate_residual, endpoint_residual);
                sweep_changed = true;
                simultaneously_proven = false;
                break;
            }
            proven_mask[cell] = 1;
        }
        if (simultaneously_proven) {
            probe_count.* += 1;
            group_residual.residualAt(
                faces,
                properties,
                water_fluxes,
                base,
                candidate,
                target,
                candidate_residual,
                scratch,
                trial_flux,
                phase_buffers,
                options,
            ) catch return null;
            for (recognized_endpoints, proven_mask, scratch) |recognized, *proven, *scaled_enthalpy| {
                proven.* = if (recognized != 0) 1 else 0;
                if (recognized != 0) scaled_enthalpy.* = 0;
            }
            return try conservationAwareMaskedEndpointNorm(
                properties,
                base,
                candidate,
                candidate_residual,
                scratch,
                proven_mask,
                options,
            );
        }
        if (!sweep_changed and sweep + 1 >= maximum_sweeps) return null;
    }
    return null;
}

fn priceRepresentableNewtonDirection(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    current: []const f64,
    direction: []const f64,
    recognized_endpoints: []const f64,
    target: []f64,
    best_candidate: []f64,
    best_norm: *f64,
    trial_state: []f64,
    trial_residual: []f64,
    scratch: []f64,
    endpoint_state: []f64,
    endpoint_residual: []f64,
    saved_scaled_enthalpy: []f64,
    proven_mask: []f64,
    best_proven_mask: []f64,
    trial_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    options: group_types.Options,
    max_line_search_steps: u8,
    probe_count: *u32,
) !?PricedNewtonDirection {
    var accepted: ?PricedNewtonDirection = null;
    var fraction: f64 = 1;
    var line_search: u8 = 0;
    while (line_search < max_line_search_steps) : (line_search += 1) {
        var admissible = true;
        for (current, direction, trial_state) |value, delta, *trial| {
            trial.* = value + fraction * delta;
            if (!group_validation.isPhysicalTemperatureK(trial.*)) {
                admissible = false;
                break;
            }
        }
        if (admissible) {
            if (try repriceAdjacentEnthalpyEndpoints(
                faces,
                properties,
                water_fluxes,
                base,
                trial_state,
                recognized_endpoints,
                target,
                trial_residual,
                scratch,
                endpoint_state,
                endpoint_residual,
                saved_scaled_enthalpy,
                proven_mask,
                trial_flux,
                phase_buffers,
                options,
                probe_count,
            )) |norm| {
                if (norm < best_norm.*) {
                    best_norm.* = norm;
                    @memcpy(best_candidate, trial_state);
                    @memcpy(best_proven_mask, proven_mask);
                    accepted = .{
                        .fraction = fraction,
                        .full_step_improved = if (accepted) |priced|
                            priced.full_step_improved
                        else
                            line_search == 0,
                        .endpoint_proof_valid = true,
                    };
                }
            }
        }
        fraction *= 0.5;
    }
    if (options.diagnostic_trace) |trace| if (trace.on_priced_direction) |callback|
        callback(trace.context, direction, if (accepted) |priced| priced.fraction else null, best_norm.*);
    return accepted;
}

fn priceNewtonDirection(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    current: []const f64,
    direction: []const f64,
    target: []f64,
    best_candidate: []f64,
    best_norm: *f64,
    trial_state: []f64,
    trial_residual: []f64,
    scratch: []f64,
    trial_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    options: group_types.Options,
    max_line_search_steps: u8,
    probe_count: *u32,
) !?PricedNewtonDirection {
    var accepted: ?PricedNewtonDirection = null;
    var fraction: f64 = 1;
    var line_search: u8 = 0;
    while (line_search < max_line_search_steps) : (line_search += 1) {
        var admissible = true;
        for (current, direction, trial_state) |value, delta, *trial| {
            trial.* = value + fraction * delta;
            if (!group_validation.isPhysicalTemperatureK(trial.*)) {
                admissible = false;
                break;
            }
        }
        if (admissible) {
            probe_count.* += 1;
            if (group_residual.residualAt(
                faces,
                properties,
                water_fluxes,
                base,
                trial_state,
                target,
                trial_residual,
                scratch,
                trial_flux,
                phase_buffers,
                options,
            )) |_| {
                const norm = try conservationAwareNorm(
                    properties,
                    base,
                    trial_state,
                    trial_residual,
                    scratch,
                    properties.enthalpy_coupling != null,
                    options,
                );
                if (norm < best_norm.*) {
                    best_norm.* = norm;
                    @memcpy(best_candidate, trial_state);
                    accepted = .{
                        .fraction = fraction,
                        .full_step_improved = if (accepted) |priced|
                            priced.full_step_improved
                        else
                            line_search == 0,
                    };
                }
            } else |_| {}
        }
        fraction *= 0.5;
    }
    if (options.diagnostic_trace) |trace| if (trace.on_priced_direction) |callback|
        callback(trace.context, direction, if (accepted) |priced| priced.fraction else null, best_norm.*);
    return accepted;
}

/// Last-resort globalization for a constitutive Newton direction after the
/// ordinary conservation-aware Newton and Anderson paths both reject every
/// candidate. This prices only progress toward the nonlinear energy root; it
/// is eligible solely for an intermediate update, never for final acceptance.
/// The caller separately proves that the trial storage excursion is on the
/// opposite side of the base state from the expected heat forcing, which is
/// the candidate-dependent relative-conservation barrier this fallback is
/// designed to cross.
fn priceNonlinearNewtonDirection(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    current: []const f64,
    direction: []const f64,
    target: []f64,
    best_candidate: []f64,
    best_nonlinear_norm: *f64,
    trial_state: []f64,
    trial_residual: []f64,
    scratch: []f64,
    trial_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    options: group_types.Options,
    max_line_search_steps: u8,
    probe_count: *u32,
) !?PricedNewtonDirection {
    var accepted: ?PricedNewtonDirection = null;
    var fraction: f64 = 1;
    var line_search: u8 = 0;
    while (line_search < max_line_search_steps) : (line_search += 1) {
        var admissible = true;
        for (current, direction, trial_state) |value, delta, *trial| {
            trial.* = value + fraction * delta;
            if (!group_validation.isPhysicalTemperatureK(trial.*)) {
                admissible = false;
                break;
            }
        }
        if (admissible) {
            probe_count.* += 1;
            if (group_residual.residualAt(
                faces,
                properties,
                water_fluxes,
                base,
                trial_state,
                target,
                trial_residual,
                scratch,
                trial_flux,
                phase_buffers,
                options,
            )) |_| {
                const nonlinear_norm = try group_residual.scaledNorm(
                    trial_state,
                    trial_residual,
                    scratch,
                    properties.enthalpy_coupling != null,
                    options,
                );
                if (nonlinear_norm < best_nonlinear_norm.*) {
                    best_nonlinear_norm.* = nonlinear_norm;
                    @memcpy(best_candidate, trial_state);
                    accepted = .{
                        .fraction = fraction,
                        .full_step_improved = if (accepted) |priced|
                            priced.full_step_improved
                        else
                            line_search == 0,
                    };
                }
            } else |_| {}
        }
        fraction *= 0.5;
    }
    return accepted;
}

/// Globalizes the two largest signed-energy coordinates independently after
/// the ordinary scalar line search rejects a valid topology-Newton direction.
/// A single fraction can stall on a phase-front minimax ridge even though two
/// independently damped coordinates have a strict full-merit descent. Every
/// pair is evaluated from the same current state; probes are never published.
fn priceTwoCoordinateNewtonDirection(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    current: []const f64,
    signed_scaled_enthalpy: []const f64,
    direction: []const f64,
    target: []f64,
    best_candidate: []f64,
    best_norm: *f64,
    trial_state: []f64,
    trial_residual: []f64,
    scratch: []f64,
    trial_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    options: group_types.Options,
    max_line_search_steps: u8,
    probe_count: *u32,
) !bool {
    if (current.len < 2 or
        signed_scaled_enthalpy.len != current.len or
        direction.len != current.len)
        return false;

    var first_cell: ?usize = null;
    var second_cell: ?usize = null;
    var first_magnitude: f64 = 0;
    var second_magnitude: f64 = 0;
    for (signed_scaled_enthalpy, direction, 0..) |scaled_defect, delta, cell| {
        const magnitude = @abs(scaled_defect);
        if (!std.math.isFinite(magnitude) or
            !std.math.isFinite(delta) or delta == 0)
            continue;
        if (first_cell == null or magnitude > first_magnitude) {
            second_cell = first_cell;
            second_magnitude = first_magnitude;
            first_cell = cell;
            first_magnitude = magnitude;
        } else if (second_cell == null or magnitude > second_magnitude) {
            second_cell = cell;
            second_magnitude = magnitude;
        }
    }
    const cell_0 = first_cell orelse return false;
    const cell_1 = second_cell orelse return false;

    // Keep this failure-path rescue strictly bounded even if a caller raises
    // the ordinary scalar line-search budget. Its work grows quadratically.
    const coordinate_search_steps = @min(max_line_search_steps, 8);
    var improved = false;
    var fraction_0: f64 = 1;
    var search_0: u8 = 0;
    while (search_0 < coordinate_search_steps) : (search_0 += 1) {
        var fraction_1: f64 = 1;
        var search_1: u8 = 0;
        while (search_1 < coordinate_search_steps) : (search_1 += 1) {
            @memcpy(trial_state, current);
            trial_state[cell_0] += fraction_0 * direction[cell_0];
            trial_state[cell_1] += fraction_1 * direction[cell_1];
            if (group_validation.isPhysicalTemperatureK(trial_state[cell_0]) and
                group_validation.isPhysicalTemperatureK(trial_state[cell_1]))
            {
                probe_count.* += 1;
                if (group_residual.residualAt(
                    faces,
                    properties,
                    water_fluxes,
                    base,
                    trial_state,
                    target,
                    trial_residual,
                    scratch,
                    trial_flux,
                    phase_buffers,
                    options,
                )) |_| {
                    const norm = try conservationAwareNorm(
                        properties,
                        base,
                        trial_state,
                        trial_residual,
                        scratch,
                        properties.enthalpy_coupling != null,
                        options,
                    );
                    if (norm < best_norm.*) {
                        best_norm.* = norm;
                        @memcpy(best_candidate, trial_state);
                        improved = true;
                    }
                } else |_| {}
            }
            fraction_1 *= 0.5;
        }
        fraction_0 *= 0.5;
    }
    return improved;
}

const DenseSignedEnthalpyNewtonContext = struct {
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    current: []const f64,
    signed_scaled_enthalpy: []const f64,
    target: []f64,
    jacobian: []f64,
    direction: []f64,
    probe_state: []f64,
    positive_scaled_enthalpy: []f64,
    best_candidate: []f64,
    trial_state: []f64,
    trial_residual: []f64,
    scratch: []f64,
    trial_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    options: group_types.Options,
    current_norm: f64,
    probe_count: *u32,
};

/// Forms Newton's direction from the governing signed scaled-enthalpy
/// equation for bounded connected systems whose face graph is not necessarily
/// a sequential column. The candidate is still globalized and accepted by the
/// complete nonlinear-plus-conservation merit in `priceNewtonDirection`.
/// Keeping this quadratic work out of `solveWithWorkspace` also prevents the
/// dense finite-difference control flow from inflating its ReleaseFast IR.
noinline fn tryDenseSignedEnthalpyNewton(
    context: DenseSignedEnthalpyNewtonContext,
) !?PricedNewtonDirection {
    const count = context.current.len;
    if (count == 0 or
        context.signed_scaled_enthalpy.len != count or
        context.jacobian.len != count * count or
        context.direction.len != count)
        return null;

    for (0..count) |column| {
        const perturbation = std.math.cbrt(std.math.floatEps(f64)) *
            @max(1.0, @abs(context.current[column]));
        @memcpy(context.probe_state, context.current);
        context.probe_state[column] += perturbation;
        context.probe_count.* += 1;
        group_residual.residualAt(
            context.faces,
            context.properties,
            context.water_fluxes,
            context.base,
            context.probe_state,
            context.target,
            context.trial_residual,
            context.scratch,
            context.trial_flux,
            context.phase_buffers,
            context.options,
        ) catch return null;
        @memcpy(context.positive_scaled_enthalpy, context.scratch);

        @memcpy(context.probe_state, context.current);
        context.probe_state[column] -= perturbation;
        if (!group_validation.isPhysicalTemperatureK(context.probe_state[column])) {
            for (0..count) |row| {
                context.jacobian[row * count + column] =
                    (context.positive_scaled_enthalpy[row] -
                        context.signed_scaled_enthalpy[row]) / perturbation;
            }
        } else {
            context.probe_count.* += 1;
            group_residual.residualAt(
                context.faces,
                context.properties,
                context.water_fluxes,
                context.base,
                context.probe_state,
                context.target,
                context.trial_residual,
                context.scratch,
                context.trial_flux,
                context.phase_buffers,
                context.options,
            ) catch return null;
            for (0..count) |row| {
                context.jacobian[row * count + column] =
                    (context.positive_scaled_enthalpy[row] -
                        context.scratch[row]) / (2 * perturbation);
            }
        }
    }

    for (context.signed_scaled_enthalpy, context.direction) |value, *right_hand_side|
        right_hand_side.* = -value;
    if (!numerics.solveDenseLinearSystem(context.jacobian, context.direction, count))
        return null;

    var best_norm = context.current_norm;
    return priceNewtonDirection(
        context.faces,
        context.properties,
        context.water_fluxes,
        context.base,
        context.current,
        context.direction,
        context.target,
        context.best_candidate,
        &best_norm,
        context.trial_state,
        context.trial_residual,
        context.scratch,
        context.trial_flux,
        context.phase_buffers,
        context.options,
        context.options.directional_newton_max_line_search_steps,
        context.probe_count,
    );
}

fn isSequentialPathTopology(
    cell_count: usize,
    faces: []const group_types.Face,
    link_marks: []f64,
) bool {
    if (link_marks.len != cell_count or faces.len + 1 != cell_count)
        return cell_count == 1 and faces.len == 0;
    @memset(link_marks, 0);
    for (faces) |face| {
        const lower = @min(face.source_cell, face.destination_cell);
        const upper = @max(face.source_cell, face.destination_cell);
        if (upper != lower + 1 or upper >= cell_count) return false;
        link_marks[upper] += 1;
    }
    for (link_marks[1..]) |count| if (count != 1) return false;
    return true;
}

/// Replaces only proven adjacent-f64 endpoint rows with identity constraints.
/// The mask is deliberately independent of the signed MJ defect: every smooth
/// cell normally has a nonzero enthalpy residual while Newton is active, and
/// treating that residual as a mask freezes the entire coupled system.
pub fn constrainRepresentableEndpointRows(
    endpoint_mask: []const f64,
    lower: []f64,
    diagonal: []f64,
    upper: []f64,
    right_hand_side: []f64,
) bool {
    if (endpoint_mask.len != diagonal.len or
        lower.len != diagonal.len or
        upper.len != diagonal.len or
        right_hand_side.len != diagonal.len)
        return false;
    for (endpoint_mask, 0..) |endpoint, cell| {
        if (endpoint == 0) continue;
        lower[cell] = 0;
        diagonal[cell] = 1;
        upper[cell] = 0;
        right_hand_side[cell] = 0;
    }
    return true;
}

/// Builds the analytic diagonal Newton correction for Appendix C's smooth
/// constitutive energy equation. `residual` is already
/// `(H_target - H(T)) / (dH/dT)`, hence it is exactly `-F/F'` for
/// `F(T) = H(T) - H_target`, not a Picard relaxation. Coordinates at the
/// latent kink are excluded and remain owned by adjacent-f64 active-set logic.
pub fn constitutiveEnergyNewtonDirection(
    properties: group_types.Properties,
    current: []const f64,
    residual: []const f64,
    direction: []f64,
) !bool {
    if (current.len != residual.len or current.len != direction.len)
        return false;
    var has_smooth_coordinate = false;
    for (current, residual, direction, 0..) |temperature_k, temperature_defect_k, *delta_k, cell| {
        delta_k.* = 0;
        const kink_radius_k = std.math.sqrt(std.math.floatEps(f64)) *
            @max(1.0, @abs(temperature_k));
        if (properties.enthalpy_coupling) |coupling| {
            const parameters = try group_enthalpy.enthalpyParameters(
                properties,
                coupling,
                cell,
            );
            if (CellEnthalpyTransitions.fromParameters(parameters)
                .nearestDistanceK(temperature_k) <= kink_radius_k)
                continue;
        }
        if (!std.math.isFinite(temperature_defect_k) or temperature_defect_k == 0)
            continue;
        delta_k.* = temperature_defect_k;
        has_smooth_coordinate = true;
    }
    return has_smooth_coordinate;
}

fn phasePartitionDiffersBeyondRoundoff(
    coupling: group_misc.EnthalpyCoupling,
    parameters: enthalpy.Parameters,
    equilibrium: enthalpy.State,
    cell: usize,
) bool {
    var mismatch_m3 =
        @abs(coupling.matrix_liquid_water_m3[cell] - equilibrium.liquid_water_m3) +
        @abs(coupling.matrix_ice_water_equivalent_m3[cell] - equilibrium.ice_water_equivalent_m3);
    var total_water_equivalent_m3 = parameters.total_water_equivalent_m3;
    var porous_medium_volume_m3 = parameters.porous_medium_volume_m3;
    if (parameters.secondary_domain) |secondary| {
        mismatch_m3 +=
            @abs(coupling.macropore_liquid_water_m3[cell] - equilibrium.secondary_liquid_water_m3) +
            @abs(coupling.macropore_ice_water_equivalent_m3[cell] - equilibrium.secondary_ice_water_equivalent_m3);
        total_water_equivalent_m3 += secondary.total_water_equivalent_m3;
        porous_medium_volume_m3 += secondary.porous_medium_volume_m3;
    }
    const extensive_scale_m3 = @max(
        total_water_equivalent_m3,
        porous_medium_volume_m3,
    );
    return std.math.isFinite(mismatch_m3) and
        mismatch_m3 > 256.0 * std.math.floatEps(f64) * extensive_scale_m3;
}

fn phaseTransitionExactInversionDirection(
    properties: group_types.Properties,
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    signed_scaled_enthalpy: []const f64,
    direction: []f64,
) !bool {
    if (base.len != current.len or
        current.len != residual.len or
        current.len != signed_scaled_enthalpy.len or
        current.len != direction.len)
        return false;
    const coupling = properties.enthalpy_coupling orelse return false;
    @memset(direction, 0);
    var selected_cell: ?usize = null;
    var selected_coordinate: f64 = 0;
    for (current, residual, signed_scaled_enthalpy, 0..) |temperature_k, temperature_defect_k, scaled_enthalpy, cell| {
        if (!std.math.isFinite(scaled_enthalpy) or
            scaled_enthalpy >= 0 or
            !std.math.isFinite(temperature_defect_k) or
            temperature_defect_k >= 0 or
            temperature_k != base[cell] or
            !group_validation.isPhysicalTemperatureK(temperature_k))
            continue;
        const parameters = try group_enthalpy.enthalpyParameters(
            properties,
            coupling,
            cell,
        );
        const transitions = CellEnthalpyTransitions.fromParameters(parameters);
        const at_secondary_transition = if (transitions.secondary_temperature_k) |secondary_temperature_k|
            temperature_k == secondary_temperature_k
        else
            false;
        if (temperature_k != transitions.matrix_temperature_k and
            !at_secondary_transition)
            continue;
        const equilibrium = try enthalpy.stateAtTemperature(
            parameters,
            temperature_k,
        );
        if (!phasePartitionDiffersBeyondRoundoff(
            coupling,
            parameters,
            equilibrium,
            cell,
        )) continue;
        const coordinate = @abs(scaled_enthalpy);
        if (selected_cell == null or coordinate > selected_coordinate) {
            selected_cell = cell;
            selected_coordinate = coordinate;
        }
    }
    const cell = selected_cell orelse return false;
    const parameters = try group_enthalpy.enthalpyParameters(
        properties,
        coupling,
        cell,
    );
    const current_state = try enthalpy.stateAtTemperature(
        parameters,
        current[cell],
    );
    const derivative_megajoules_per_k =
        try enthalpy.enthalpyDerivativeMjPerK(
            parameters,
            current[cell],
            current_state,
        );
    const target_enthalpy_megajoules = current_state.enthalpy_megajoules +
        residual[cell] * derivative_megajoules_per_k;
    var inversion_options = coupling.solver_options;
    const inversion_iteration_cap = @min(
        inversion_options.max_iterations,
        inversion_options.local_iteration_limit,
    );
    if (inversion_iteration_cap == 0 or
        inversion_options.relative_enthalpy_tolerance <= 0)
        return false;
    inversion_options.max_iterations = inversion_iteration_cap;
    inversion_options.local_iteration_limit = inversion_iteration_cap;
    inversion_options.initial_temperature_k = current[cell];
    const solved = enthalpy.temperatureFromEnthalpy(
        parameters,
        target_enthalpy_megajoules,
        inversion_options,
    ) catch return false;
    const delta_k = solved.state.temperature_k - current[cell];
    if (!std.math.isFinite(delta_k) or delta_k >= 0) return false;
    direction[cell] = delta_k;
    return true;
}

/// Builds `-F/F'` only on smooth, representably movable coordinates whose
/// signed enthalpy defect is in the limiting MJ active set. The K-equivalent
/// residual is already the analytic constitutive Newton correction. A
/// sub-ULP correction is deliberately left at zero so the next iteration's
/// adjacent-f64 representability proof remains its sole owner.
pub fn mjActiveSetNewtonDirection(
    properties: group_types.Properties,
    current: []const f64,
    residual: []const f64,
    scaled_enthalpy_defect: []const f64,
    direction: []f64,
) !bool {
    if (current.len != residual.len or
        current.len != scaled_enthalpy_defect.len or
        current.len != direction.len)
        return false;

    var maximum_enthalpy_coordinate: f64 = 0;
    for (scaled_enthalpy_defect) |defect| {
        if (!std.math.isFinite(defect)) return false;
        maximum_enthalpy_coordinate = @max(
            maximum_enthalpy_coordinate,
            @abs(defect),
        );
    }
    if (maximum_enthalpy_coordinate <= 1) {
        @memset(direction, 0);
        return false;
    }

    // Admit every coordinate that is unconverged IN ITS OWN RIGHT. The scaled
    // defect is already normalized so that `<= 1` means converged (see the
    // `maximum_enthalpy_coordinate <= 1` early return above), so this is the
    // coordinate's own tolerance, not a tolerance relative to its neighbours.
    //
    // This replaced a relative cutoff of 0.99 x maximum_enthalpy_coordinate,
    // which admitted only coordinates within one percent of the single largest defect. On a coupled soil column that
    // degenerates into a max-defect-only method, and the deep layers -- whose
    // defects are orders of magnitude smaller than the surface layers' -- were
    // never admitted and so never solved. Measured on
    // `ottawa_day74_heat_failure_20260910.json`: 15 of 20 iterations went to
    // this path, every one of them confined to cells 1-6, while cells 7-11 sat
    // untouched at a byte-identical temperature and residual until a single
    // late full-width enthalpy-topology step moved cell 10 and cut its residual
    // from 1.5906e-3 to 2.5390e-7 in one step. Solving only the worst
    // coordinate cannot converge a system whose coordinates are coupled.
    var has_representable_smooth_coordinate = false;
    for (current, residual, scaled_enthalpy_defect, direction, 0..) |temperature_k, temperature_defect_k, enthalpy_defect, *delta_k, cell| {
        delta_k.* = 0;
        if (@abs(enthalpy_defect) <= 1) continue;
        const kink_radius_k = std.math.sqrt(std.math.floatEps(f64)) *
            @max(1.0, @abs(temperature_k));
        if (properties.enthalpy_coupling) |coupling| {
            const parameters = try group_enthalpy.enthalpyParameters(
                properties,
                coupling,
                cell,
            );
            if (CellEnthalpyTransitions.fromParameters(parameters)
                .nearestDistanceK(temperature_k) <= kink_radius_k)
                continue;
        }
        if (!std.math.isFinite(temperature_defect_k) or temperature_defect_k == 0)
            continue;
        const proposed_temperature_k = temperature_k + temperature_defect_k;
        if (!std.math.isFinite(proposed_temperature_k) or
            proposed_temperature_k <= 0 or
            proposed_temperature_k == temperature_k)
            continue;
        delta_k.* = temperature_defect_k;
        has_representable_smooth_coordinate = true;
    }
    return has_representable_smooth_coordinate;
}

/// In-place Thomas solve after row equilibration. The topology-local heat
/// Jacobian is diagonally dominant for the implicit conduction balance; a
/// failed pivot simply rejects this Newton direction and leaves Anderson as
/// the sole recovery path.
fn solveTridiagonal(
    lower: []f64,
    diagonal: []f64,
    upper: []f64,
    right_hand_side: []f64,
) bool {
    const count = diagonal.len;
    if (count == 0 or lower.len != count or upper.len != count or right_hand_side.len != count) return false;
    const pivot_floor = 64.0 * std.math.floatEps(f64);
    for (0..count) |row| {
        const scale = @max(
            @abs(diagonal[row]),
            @max(@abs(lower[row]), @abs(upper[row])),
        );
        if (!std.math.isFinite(scale) or scale == 0 or
            !std.math.isFinite(right_hand_side[row])) return false;
        lower[row] /= scale;
        diagonal[row] /= scale;
        upper[row] /= scale;
        right_hand_side[row] /= scale;
    }
    for (1..count) |row| {
        const pivot = diagonal[row - 1];
        if (!std.math.isFinite(pivot) or @abs(pivot) <= pivot_floor) return false;
        const multiplier = lower[row] / pivot;
        diagonal[row] -= multiplier * upper[row - 1];
        right_hand_side[row] -= multiplier * right_hand_side[row - 1];
    }
    const last_pivot = diagonal[count - 1];
    if (!std.math.isFinite(last_pivot) or @abs(last_pivot) <= pivot_floor) return false;
    right_hand_side[count - 1] /= last_pivot;
    var row = count - 1;
    while (row > 0) {
        row -= 1;
        const pivot = diagonal[row];
        if (!std.math.isFinite(pivot) or @abs(pivot) <= pivot_floor) return false;
        right_hand_side[row] =
            (right_hand_side[row] - upper[row] * right_hand_side[row + 1]) /
            pivot;
        if (!std.math.isFinite(right_hand_side[row])) return false;
    }
    return std.math.isFinite(right_hand_side[count - 1]);
}

/// The recovery/watch knobs are validated here rather than in
/// `solver_validation.zig` only because this group owns them; the error name is
/// the file's existing one so callers keep a single option-fault vocabulary.
/// A patience of zero would fire on the first non-improving iteration and a
/// growth factor below one would fire on an improving one, so neither can be
/// accepted: a detector that a nonsense value silently disables (or turns into
/// a spurious failure) is worse than no detector.
fn validateRecoveryOptions(options: group_types.Options) !void {
    if (options.divergence_patience == 0 or
        !std.math.isFinite(options.divergence_growth_factor) or
        options.divergence_growth_factor < 1 or
        options.maximum_newton_fraction > 1 or
        (!builtin.is_test and options.recovery_routing_test_control != null))
        return error.InvalidSoilHeatSolverOptions;
    if (builtin.is_test) {
        if (options.recovery_routing_test_control) |control| {
            if (control.force_speculative_iteration == 0)
                return error.InvalidSoilHeatSolverOptions;
        }
    }
}

/// Solves the nonlinear WATSUB temperature balance over arbitrary runtime
/// faces. State and HFLWM-equivalent output remain unchanged on failure.
pub fn solve(allocator: std.mem.Allocator, grid: *grid_module.GridState, faces: []const group_types.Face, properties: group_types.Properties, water_fluxes: group_types.WaterHeatFluxes, heat_flux_megajoules: []f64, options: group_types.Options) !group_types.Result {
    var workspace = try group_types.Workspace.init(
        allocator,
        grid.layer_count,
        faces.len,
        options.dense_newton_max_components,
    );
    defer workspace.deinit();
    return solveWithWorkspace(
        &workspace,
        grid,
        faces,
        properties,
        water_fluxes,
        heat_flux_megajoules,
        options,
    );
}

pub fn solveWithWorkspace(
    workspace: *group_types.Workspace,
    grid: *grid_module.GridState,
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    heat_flux_megajoules: []f64,
    options: group_types.Options,
) !group_types.Result {
    try group_validation.validateInputs(grid, faces, properties, water_fluxes, heat_flux_megajoules, options);
    try validateRecoveryOptions(options);
    if (workspace.enthalpy_evaluation_cache) |*cache| cache.reset();
    const count = grid.layer_count;
    const use_dense_newton = count <= options.dense_newton_max_components;
    const required_jacobian_count =
        if (use_dense_newton)
            try std.math.mul(usize, count, count)
        else
            0;
    if (workspace.cell_count != count or
        workspace.face_count != faces.len or
        workspace.jacobian.len < required_jacobian_count)
        return error.SoilHeatWorkspaceDimensionMismatch;
    const base = workspace.base;
    const current = workspace.current;
    const best_state = workspace.best_state;
    const residual = workspace.residual;
    const target = workspace.target;
    const scratch = workspace.scratch;
    const trial_flux = workspace.trial_flux;
    const probe = workspace.probe;
    const probe_residual = workspace.probe_residual;
    const candidate = workspace.candidate;
    const candidate_residual = workspace.candidate_residual;
    const previous_state = workspace.previous_state;
    const previous_residual = workspace.previous_residual;
    const previous_previous_state = workspace.previous_previous_state;
    const previous_previous_residual = workspace.previous_previous_residual;
    const accelerated = workspace.accelerated;
    const accelerated_residual = workspace.accelerated_residual;
    const enthalpy_endpoint_mask = workspace.enthalpy_endpoint_mask;
    const accepted_endpoint_proof_mask = workspace.accepted_endpoint_proof_mask;
    const accepted_conservation_representability_megajoules =
        workspace.accepted_conservation_representability_megajoules;
    const topology_lower = workspace.topology_lower;
    const topology_diagonal = workspace.topology_diagonal;
    const topology_upper = workspace.topology_upper;
    const jacobian = workspace.jacobian[0..required_jacobian_count];
    const newton_delta = workspace.newton_delta;
    @memset(accepted_conservation_representability_megajoules, 0);
    @memcpy(base, grid.soil_temperature_k);
    @memcpy(current, base);
    @memcpy(best_state, base);
    const phase_buffers: group_misc.PhaseBuffers = .{
        .evaluation_cache = if (workspace.enthalpy_evaluation_cache) |*cache| cache else null,
        .matrix_liquid_m3 = workspace.matrix_liquid_m3,
        .matrix_ice_m3 = workspace.matrix_ice_m3,
        .macropore_liquid_m3 = workspace.macropore_liquid_m3,
        .macropore_ice_m3 = workspace.macropore_ice_m3,
        .macropore_enabled = if (properties.enthalpy_coupling) |coupling|
            coupling.macropore_mualem_van_genuchten.len != 0
        else
            false,
        // Inert when `enthalpy_coupling` is null: `state_updateMatrixPhase`
        // (the only reader) is called only when coupling is present.
        .ice_density_megagrams_per_m3 = if (properties.enthalpy_coupling) |coupling|
            coupling.ice_density_megagrams_per_m3
        else
            1,
    };
    if (options.diagnostic_trace) |trace| if (trace.on_ice_fraction_consistency_check) |callback| {
        if (properties.enthalpy_coupling) |coupling| {
            for (0..count) |cell| {
                const properties_fraction_sum =
                    properties.liquid_water_fraction[cell] + properties.ice_fraction[cell];
                const coupling_fraction_sum =
                    (coupling.matrix_liquid_water_m3[cell] + coupling.matrix_ice_water_equivalent_m3[cell]) /
                    coupling.porous_medium_volume_m3[cell];
                callback(trace.context, cell, properties_fraction_sum, coupling_fraction_sum);
            }
        }
    };
    // Keep quadratic storage away from large/out-of-core grids. Modest
    // connected systems use the full numerical Jacobian; larger systems retain
    // the O(n) directional Newton/Picard path below.
    var newton_steps: u16 = 0;
    var topology_newton_steps: u16 = 0;
    var topology_newton_probes: u32 = 0;
    var enthalpy_topology_newton_steps: u16 = 0;
    var enthalpy_topology_newton_probes: u32 = 0;
    var enthalpy_dense_newton_steps: u16 = 0;
    var enthalpy_dense_newton_probes: u32 = 0;
    var megajoule_active_set_newton_steps: u16 = 0;
    var megajoule_active_set_newton_probes: u32 = 0;
    var directional_newton_probes: u32 = 0;
    var enthalpy_representability_probes: u32 = 0;
    var phase_transition_newton_steps: u16 = 0;
    var enthalpy_repriced_neighbor_steps: u16 = 0;
    var constitutive_energy_newton_steps: u16 = 0;
    var constitutive_energy_newton_probes: u32 = 0;
    var damped_directional_newton_steps: u16 = 0;
    var picard_steps: u16 = 0;
    var anderson_steps: u16 = 0;
    // Anderson history over the Picard map, and the divergence/oscillation
    // watch. Both are per-solve state, so a retry starts clean.
    var history_count: u8 = 0;
    var best_norm = std.math.inf(f64);
    var best_state_valid = false;
    var non_improving_steps: u16 = 0;
    var previous_norm = std.math.inf(f64);
    var insufficient_progress_steps: u16 = 0;
    var slow_newton_norm_history: [slow_newton_progress_history_length]f64 = undefined;
    var slow_newton_norm_count: u8 = 0;
    var slow_newton_last_recorded_step: u16 = 0;
    var slow_progress_recovery_pending = false;
    var rejected_speculative_recovery_step: ?u16 = null;
    var newton_retry_required = false;
    var force_full_endpoint_scan = false;
    // Valid only for the exact state accepted at the end of the current loop
    // slot. Entering another iteration invalidates it before any new probe or
    // promotion; only a simultaneous repricing proof may set it again.
    var accepted_state_endpoint_proof_valid = false;
    var accepted_state_endpoint_proof_norm = std.math.inf(f64);
    var iteration: u16 = 0;
    var speculative_newton_replay = false;
    var final_norm: f64 = std.math.inf(f64);
    const TerminalReason = enum { iteration_limit, stagnated, diverged };
    var terminal_reason: TerminalReason = .iteration_limit;
    var terminal_iterations = options.max_iterations;
    var restore_best_before_final_audit = false;
    while (iteration < options.max_iterations) : (iteration += 1) {
        const replaying_speculative_newton = speculative_newton_replay;
        speculative_newton_replay = false;
        if (builtin.is_test) {
            if (options.recovery_routing_test_control) |control| {
                control.iterations_entered +|= 1;
                if (replaying_speculative_newton)
                    control.next_slot_newton_iteration = iteration + 1;
            }
        }
        accepted_state_endpoint_proof_valid = false;
        accepted_state_endpoint_proof_norm = std.math.inf(f64);
        @memset(accepted_endpoint_proof_mask, 0);
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        var endpoint_discovery_optimization_skipped = false;
        var has_representable_endpoints = false;
        @memset(enthalpy_endpoint_mask, 0);
        try group_residual.residualAt(faces, properties, water_fluxes, base, current, target, residual, scratch, trial_flux, phase_buffers, options);
        var norm = try conservationAwareNorm(properties, base, current, residual, scratch, properties.enthalpy_coupling != null, options);
        if (options.diagnostic_trace) |trace| if (trace.on_iteration_residual) |callback|
            callback(trace.context, iteration, current, residual, norm);
        // Record state merits only after an accepted Newton update. Endpoint
        // audits and Anderson probes do not masquerade as Newton progress.
        const accepted_newton_since_forecast = slow_newton_norm_count != 0 and
            newton_steps != slow_newton_last_recorded_step;
        if (accepted_newton_since_forecast) {
            // An endpoint/topology/directional Newton promotion changes both
            // the state and its observed contraction. Never reuse a forecast
            // priced against the pre-promotion state.
            const invalidated_forecast = slow_progress_recovery_pending or
                rejected_speculative_recovery_step != null;
            slow_progress_recovery_pending = false;
            rejected_speculative_recovery_step = null;
            if (builtin.is_test and invalidated_forecast) {
                if (options.recovery_routing_test_control) |control|
                    control.invalidated_forecasts +|= 1;
            }
        }
        if (slow_newton_norm_count == 0 or accepted_newton_since_forecast) {
            rememberNewtonNorm(
                &slow_newton_norm_history,
                &slow_newton_norm_count,
                norm,
            );
            slow_newton_last_recorded_step = newton_steps;
        }
        var energy_merit_dominates = false;
        if (properties.enthalpy_coupling != null) {
            var maximum_k_coordinate: f64 = 0;
            var maximum_megajoule_coordinate: f64 = 0;
            for (current, residual, scratch) |temperature_k, difference_k, scaled_enthalpy| {
                maximum_k_coordinate = @max(
                    maximum_k_coordinate,
                    @abs(difference_k) /
                        (options.absolute_tolerance_k +
                            options.relative_tolerance * @abs(temperature_k)),
                );
                maximum_megajoule_coordinate = @max(
                    maximum_megajoule_coordinate,
                    @abs(scaled_enthalpy),
                );
            }
            const conservation_energy_coordinate = try group_residual.conservationScaledNorm(
                properties,
                base,
                current,
                residual,
            );
            energy_merit_dominates = @max(
                maximum_megajoule_coordinate,
                conservation_energy_coordinate,
            ) > maximum_k_coordinate;
        }
        // The saturated enthalpy curve can cross its exact root between two
        // adjacent f64 temperatures. Prove that condition on the fully coupled
        // merit before treating an otherwise unsatisfied MJ gate as complete.
        // Every adjacent-coordinate check is a read-only probe; only choosing
        // the better neighbor promotes state and consumes one Newton update.
        if (norm > 1 and properties.enthalpy_coupling != null) {
            @memcpy(accelerated_residual, scratch);
            var representable_norm = norm;
            var committed_neighbor = false;
            // Discovery is an audit of every unresolved MJ coordinate, not
            // only the current maximum. A smooth but still-large constitutive
            // defect does not bracket across one temperature ULP; it must be
            // skipped so lower-ranked discrete endpoints can still be proven
            // and held while Newton resolves the smooth coordinate.
            @memset(topology_upper, 0);
            const allow_transition_optimized_scan =
                !force_full_endpoint_scan and
                iteration + 1 < options.max_iterations;
            var representability_checks: usize = 0;
            while (representability_checks < count) : (representability_checks += 1) {
                @memcpy(scratch, accelerated_residual);
                for (enthalpy_endpoint_mask, scratch) |recognized, *scaled_enthalpy| {
                    if (recognized != 0) scaled_enthalpy.* = 0;
                }
                representable_norm = try conservationAwareMaskedEndpointNorm(
                    properties,
                    base,
                    current,
                    residual,
                    scratch,
                    enthalpy_endpoint_mask,
                    options,
                );
                if (representable_norm <= 1) break;

                var limiting_cell: usize = 0;
                var limiting_enthalpy_coordinate: f64 = 1;
                var found_unchecked_enthalpy_coordinate = false;
                for (current, residual, accelerated_residual, enthalpy_endpoint_mask, topology_upper, 0..) |temperature_k, temperature_defect_k, scaled_enthalpy, recognized, checked, cell| {
                    if (recognized != 0 or checked != 0) continue;
                    const enthalpy_coordinate = @abs(scaled_enthalpy);
                    if (enthalpy_coordinate <= 1) continue;
                    // The analytic K defect is the smooth constitutive Newton
                    // predictor. Away from the phase kink, a distinct
                    // representable prediction belongs to ordinary Newton;
                    // near the kink the actual signed-MJ adjacent probe remains
                    // authoritative even when the tangent predicts a move.
                    const predicted_temperature_k =
                        temperature_k + temperature_defect_k;
                    if (allow_transition_optimized_scan and
                        std.math.isFinite(predicted_temperature_k) and
                        predicted_temperature_k > 0 and
                        predicted_temperature_k != temperature_k)
                    {
                        const parameters = try group_enthalpy.enthalpyParameters(
                            properties,
                            properties.enthalpy_coupling.?,
                            cell,
                        );
                        const transitions =
                            CellEnthalpyTransitions.fromParameters(parameters);
                        const matrix_transition_k =
                            transitions.matrix_temperature_k;
                        const matrix_kink_radius = 2 *
                            std.math.sqrt(std.math.floatEps(f64)) *
                            @max(1.0, @abs(matrix_transition_k));
                        var near_domain_transition =
                            transitions.firstCrossedTemperatureK(
                                temperature_k,
                                predicted_temperature_k,
                            ) != null or
                            @abs(temperature_k - matrix_transition_k) <=
                                matrix_kink_radius;
                        if (options.diagnostic_trace) |trace| if (trace.on_transition_proximity) |callback|
                            callback(trace.context, cell, temperature_k, matrix_transition_k, matrix_kink_radius, near_domain_transition);
                        if (parameters.secondary_domain) |secondary| {
                            _ = secondary;
                            const secondary_transition_k =
                                transitions.secondary_temperature_k.?;
                            const secondary_kink_radius = 2 *
                                std.math.sqrt(std.math.floatEps(f64)) *
                                @max(1.0, @abs(secondary_transition_k));
                            near_domain_transition = near_domain_transition or
                                @abs(temperature_k - secondary_transition_k) <=
                                    secondary_kink_radius;
                        }
                        // The ULP-scale radius above only catches cells within
                        // floating-point rounding of the exact transition
                        // temperature. A cell can sit measurably outside that
                        // radius yet still have a steep retention curve near
                        // residual saturation, giving it a large apparent heat
                        // capacity (enthalpyDerivativeMjPerK) -- the smooth
                        // Newton predictor is untrustworthy there too. Widen
                        // the gate with a magnitude-based test: trigger
                        // discovery whenever the derivative is at least double
                        // the cell's own ordinary (phase-change-free) sensible
                        // heat capacity, i.e. the latent contribution alone is
                        // at least as large as the sensible contribution.
                        if (!near_domain_transition) {
                            const trial_state = try enthalpy.stateAtTemperature(
                                parameters,
                                temperature_k,
                            );
                            const trial_derivative_megajoules_per_k =
                                try enthalpy.enthalpyDerivativeMjPerK(
                                    parameters,
                                    temperature_k,
                                    trial_state,
                                );
                            near_domain_transition = trial_derivative_megajoules_per_k >=
                                2 * trial_state.sensible_heat_capacity_megajoules_per_k;
                        }
                        if (!near_domain_transition) {
                            topology_upper[cell] = 1;
                            endpoint_discovery_optimization_skipped = true;
                            continue;
                        }
                    }
                    if (enthalpy_coordinate > limiting_enthalpy_coordinate) {
                        limiting_cell = cell;
                        limiting_enthalpy_coordinate = enthalpy_coordinate;
                        found_unchecked_enthalpy_coordinate = true;
                    }
                }
                if (try group_residual.worstUnresolvedConservationComponent(
                    properties,
                    base,
                    current,
                    residual,
                    enthalpy_endpoint_mask,
                    topology_upper,
                )) |component| {
                    if (component.scaled_norm > limiting_enthalpy_coordinate) {
                        limiting_cell = component.cell;
                        limiting_enthalpy_coordinate = component.scaled_norm;
                        found_unchecked_enthalpy_coordinate = true;
                    }
                }
                if (!found_unchecked_enthalpy_coordinate) break;
                topology_upper[limiting_cell] = 1;

                // The analytic K correction can cross a known Dall'Amico
                // transition while the current temperature is still many
                // representable values away. Ordinary line-search halving then
                // approaches the phase front geometrically and can exhaust the
                // external substep schedule. Probe the transition's exact
                // adjacent-f64 pair directly. A signed-MJ bracket can prove a
                // represented endpoint; otherwise, the destination-side phase
                // boundary is only an intermediate active-set Newton state and
                // must strictly reduce the unchanged full coupled merit.
                known_transition_probe: {
                    const parameters = try group_enthalpy.enthalpyParameters(
                        properties,
                        properties.enthalpy_coupling.?,
                        limiting_cell,
                    );
                    const transitions =
                        CellEnthalpyTransitions.fromParameters(parameters);
                    const predicted_temperature_k =
                        current[limiting_cell] + residual[limiting_cell];
                    const transition_temperature_k =
                        transitions.firstCrossedTemperatureK(
                            current[limiting_cell],
                            predicted_temperature_k,
                        ) orelse break :known_transition_probe;
                    const lower_transition_temperature_k = std.math.nextAfter(
                        f64,
                        transition_temperature_k,
                        -std.math.inf(f64),
                    );
                    if (!group_validation.isPhysicalTemperatureK(lower_transition_temperature_k) or
                        !group_validation.isPhysicalTemperatureK(transition_temperature_k) or
                        lower_transition_temperature_k == transition_temperature_k or
                        current[limiting_cell] == lower_transition_temperature_k or
                        current[limiting_cell] == transition_temperature_k)
                        break :known_transition_probe;

                    @memcpy(probe, current);
                    probe[limiting_cell] = lower_transition_temperature_k;
                    enthalpy_representability_probes += 1;
                    group_residual.residualAt(
                        faces,
                        properties,
                        water_fluxes,
                        base,
                        probe,
                        target,
                        probe_residual,
                        scratch,
                        trial_flux,
                        phase_buffers,
                        options,
                    ) catch break :known_transition_probe;
                    @memcpy(topology_diagonal, scratch);

                    @memcpy(candidate, current);
                    candidate[limiting_cell] = transition_temperature_k;
                    enthalpy_representability_probes += 1;
                    group_residual.residualAt(
                        faces,
                        properties,
                        water_fluxes,
                        base,
                        candidate,
                        target,
                        candidate_residual,
                        scratch,
                        trial_flux,
                        phase_buffers,
                        options,
                    ) catch break :known_transition_probe;
                    const lower_enthalpy_coordinate =
                        topology_diagonal[limiting_cell];
                    const upper_enthalpy_coordinate = scratch[limiting_cell];
                    const brackets_enthalpy_root =
                        lower_enthalpy_coordinate == 0 or
                        upper_enthalpy_coordinate == 0 or
                        std.math.signbit(lower_enthalpy_coordinate) !=
                            std.math.signbit(upper_enthalpy_coordinate);
                    var had_previous_endpoint = false;
                    for (enthalpy_endpoint_mask) |recognized| {
                        if (recognized != 0) {
                            had_previous_endpoint = true;
                            break;
                        }
                    }
                    if (!brackets_enthalpy_root) {
                        const lower_transition_norm =
                            try conservationAwareRepresentedEndpointNorm(
                                properties,
                                base,
                                probe,
                                probe_residual,
                                topology_diagonal,
                                enthalpy_endpoint_mask,
                                topology_lower,
                                options,
                            );
                        const upper_transition_norm =
                            try conservationAwareRepresentedEndpointNorm(
                                properties,
                                base,
                                candidate,
                                candidate_residual,
                                scratch,
                                enthalpy_endpoint_mask,
                                topology_lower,
                                options,
                            );
                        const select_upper = if (upper_transition_norm !=
                            lower_transition_norm)
                            upper_transition_norm < lower_transition_norm
                        else
                            predicted_temperature_k > current[limiting_cell];
                        const selected_norm = if (select_upper)
                            upper_transition_norm
                        else
                            lower_transition_norm;
                        if (selected_norm >= representable_norm)
                            break :known_transition_probe;
                        @memcpy(current, if (select_upper) candidate else probe);
                        newton_steps += 1;
                        phase_transition_newton_steps += 1;
                        committed_neighbor = true;
                        break :known_transition_probe;
                    }
                    enthalpy_endpoint_mask[limiting_cell] = 1;
                    const lower_represented_norm =
                        try conservationAwareRepresentedEndpointNorm(
                            properties,
                            base,
                            probe,
                            probe_residual,
                            topology_diagonal,
                            enthalpy_endpoint_mask,
                            topology_lower,
                            options,
                        );
                    const upper_represented_norm =
                        try conservationAwareRepresentedEndpointNorm(
                            properties,
                            base,
                            candidate,
                            candidate_residual,
                            scratch,
                            enthalpy_endpoint_mask,
                            topology_lower,
                            options,
                        );
                    const select_upper = preferAlternativeRepresentedEndpoint(
                        lower_represented_norm,
                        lower_transition_temperature_k,
                        upper_represented_norm,
                        transition_temperature_k,
                    );
                    const selected_norm = if (select_upper)
                        upper_represented_norm
                    else
                        lower_represented_norm;
                    if (selected_norm >= representable_norm) {
                        enthalpy_endpoint_mask[limiting_cell] = 0;
                        break :known_transition_probe;
                    }
                    if (!had_previous_endpoint and
                        iteration + 1 == options.max_iterations and
                        selected_norm <= 1)
                    {
                        accepted_state_endpoint_proof_valid = true;
                        accepted_state_endpoint_proof_norm = selected_norm;
                        @memcpy(
                            accepted_endpoint_proof_mask,
                            enthalpy_endpoint_mask,
                        );
                    }
                    @memcpy(current, if (select_upper) candidate else probe);
                    newton_steps += 1;
                    phase_transition_newton_steps += 1;
                    committed_neighbor = true;
                }
                if (committed_neighbor) break;

                @memcpy(candidate, current);
                candidate[limiting_cell] = std.math.nextAfter(
                    f64,
                    current[limiting_cell],
                    if (accelerated_residual[limiting_cell] > 0)
                        std.math.inf(f64)
                    else
                        -std.math.inf(f64),
                );
                if (candidate[limiting_cell] == current[limiting_cell]) continue;
                enthalpy_representability_probes += 1;
                group_residual.residualAt(
                    faces,
                    properties,
                    water_fluxes,
                    base,
                    candidate,
                    target,
                    candidate_residual,
                    scratch,
                    trial_flux,
                    phase_buffers,
                    options,
                ) catch continue;
                const candidate_enthalpy_coordinate = scratch[limiting_cell];
                const brackets_enthalpy_root =
                    candidate_enthalpy_coordinate == 0 or
                    std.math.signbit(candidate_enthalpy_coordinate) !=
                        std.math.signbit(accelerated_residual[limiting_cell]);
                if (!brackets_enthalpy_root) continue;
                var had_previous_endpoint = false;
                for (enthalpy_endpoint_mask) |recognized| {
                    if (recognized != 0) {
                        had_previous_endpoint = true;
                        break;
                    }
                }
                enthalpy_endpoint_mask[limiting_cell] = 1;
                const current_represented_norm = try conservationAwareRepresentedEndpointNorm(
                    properties,
                    base,
                    current,
                    residual,
                    accelerated_residual,
                    enthalpy_endpoint_mask,
                    topology_lower,
                    options,
                );
                const candidate_represented_norm = try conservationAwareRepresentedEndpointNorm(
                    properties,
                    base,
                    candidate,
                    candidate_residual,
                    scratch,
                    enthalpy_endpoint_mask,
                    topology_lower,
                    options,
                );
                if (preferAlternativeRepresentedEndpoint(
                    current_represented_norm,
                    current[limiting_cell],
                    candidate_represented_norm,
                    candidate[limiting_cell],
                )) {
                    // If this was the only endpoint and masking the accepted
                    // adjacent state closes every remaining coordinate, the
                    // already-evaluated full candidate is a complete final
                    // proof. Any earlier endpoint would be coupled to this
                    // state change and therefore forbids carrying its proof.
                    if (!had_previous_endpoint and
                        iteration + 1 == options.max_iterations and
                        candidate_represented_norm <= 1)
                    {
                        accepted_state_endpoint_proof_valid = true;
                        accepted_state_endpoint_proof_norm =
                            candidate_represented_norm;
                        @memcpy(
                            accepted_endpoint_proof_mask,
                            enthalpy_endpoint_mask,
                        );
                    }
                    if (properties.enthalpy_coupling == null)
                        rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
                    @memcpy(current, candidate);
                    newton_steps += 1;
                    committed_neighbor = true;
                    break;
                }
                // Current is the lower full-merit endpoint of an adjacent-f64
                // bracket, so this MJ coordinate is representably complete.
                representable_norm = current_represented_norm;
            }
            if (!committed_neighbor) {
                @memcpy(scratch, accelerated_residual);
                for (enthalpy_endpoint_mask, scratch) |recognized, *scaled_enthalpy| {
                    if (recognized != 0) scaled_enthalpy.* = 0;
                }
                representable_norm = try conservationAwareMaskedEndpointNorm(
                    properties,
                    base,
                    current,
                    residual,
                    scratch,
                    enthalpy_endpoint_mask,
                    options,
                );
            }
            // If another, achievable coordinate still limits convergence,
            // keep each proven adjacent-f64 coordinate fixed while a
            // component-secant Newton step resolves the coupled remainder.
            // Its neighbours must remain free: their face fluxes are part of
            // the same nonlinear system. Instead, re-prove every adjacent
            // bracket after each candidate changes those neighbours, price
            // both endpoints with a full residual evaluation, and retain only
            // the lower globally scaled merit endpoint. A rejected probe never
            // changes `current` or the grid's accepted phase state.
            if (!committed_neighbor and representable_norm > 1) {
                @memcpy(topology_upper, enthalpy_endpoint_mask);
                var has_recognized_endpoint = false;
                var has_free_coordinate = false;
                @memset(newton_delta, 0);
                for (residual, topology_upper, newton_delta) |difference, frozen, *probe_direction| {
                    if (frozen != 0) {
                        has_recognized_endpoint = true;
                        continue;
                    }
                    probe_direction.* = difference;
                    has_free_coordinate = has_free_coordinate or difference != 0;
                }
                const maybe_probe_fraction = if (has_recognized_endpoint and
                    has_free_coordinate)
                    stageAdmissibleDirectionProbe(
                        current,
                        newton_delta,
                        options.directional_probe_fraction,
                        probe,
                        options.directional_newton_max_line_search_steps,
                    )
                else
                    null;
                if (maybe_probe_fraction) |probe_fraction| {
                    directional_newton_probes += 1;
                    if (group_residual.residualAt(
                        faces,
                        properties,
                        water_fluxes,
                        base,
                        probe,
                        target,
                        probe_residual,
                        scratch,
                        trial_flux,
                        phase_buffers,
                        options,
                    )) |_| {
                        var has_newton_coordinate = false;
                        for (residual, probe_residual, topology_upper, newton_delta) |base_residual, sampled_residual, frozen, *delta| {
                            delta.* = 0;
                            if (frozen != 0) continue;
                            const derivative_along_residual =
                                (sampled_residual - base_residual) /
                                probe_fraction;
                            if (!std.math.isFinite(derivative_along_residual) or
                                @abs(derivative_along_residual) <= std.math.floatEps(f64))
                                continue;
                            const raw_fraction =
                                -base_residual / derivative_along_residual;
                            if (!std.math.isFinite(raw_fraction) or raw_fraction <= 0)
                                continue;
                            delta.* = std.math.clamp(
                                raw_fraction,
                                options.minimum_newton_fraction,
                                options.maximum_newton_fraction,
                            ) * base_residual;
                            has_newton_coordinate = has_newton_coordinate or delta.* != 0;
                        }
                        if (has_newton_coordinate) {
                            var best_active_norm = representable_norm;
                            var best_active_endpoint_proof_valid = false;
                            var fraction: f64 = 1;
                            var full_step_improved = false;
                            var line_search: u8 = 0;
                            while (line_search < options.directional_newton_max_line_search_steps) : (line_search += 1) {
                                var admissible = true;
                                for (current, newton_delta, candidate) |value, delta, *trial_value| {
                                    trial_value.* = value + fraction * delta;
                                    if (!group_validation.isPhysicalTemperatureK(trial_value.*)) {
                                        admissible = false;
                                        break;
                                    }
                                }
                                if (admissible) {
                                    if (try repriceAdjacentEnthalpyEndpoints(
                                        faces,
                                        properties,
                                        water_fluxes,
                                        base,
                                        candidate,
                                        topology_upper,
                                        target,
                                        candidate_residual,
                                        scratch,
                                        probe,
                                        probe_residual,
                                        topology_lower,
                                        topology_diagonal,
                                        trial_flux,
                                        phase_buffers,
                                        options,
                                        &enthalpy_representability_probes,
                                    )) |candidate_norm| {
                                        if (candidate_norm < best_active_norm) {
                                            best_active_norm = candidate_norm;
                                            @memcpy(accelerated, candidate);
                                            best_active_endpoint_proof_valid =
                                                candidate_norm <= 1;
                                            if (candidate_norm <= 1)
                                                @memcpy(
                                                    accepted_endpoint_proof_mask,
                                                    topology_diagonal,
                                                );
                                            if (line_search == 0)
                                                full_step_improved = true;
                                        }
                                    }
                                }
                                fraction *= 0.5;
                            }
                            if (best_active_norm < representable_norm) {
                                if (properties.enthalpy_coupling == null)
                                    rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
                                @memcpy(current, accelerated);
                                newton_steps += 1;
                                if (!full_step_improved)
                                    damped_directional_newton_steps += 1;
                                enthalpy_repriced_neighbor_steps += 1;
                                accepted_state_endpoint_proof_valid =
                                    best_active_endpoint_proof_valid;
                                accepted_state_endpoint_proof_norm =
                                    best_active_norm;
                                committed_neighbor = true;
                            }
                        }
                    } else |_| {}
                }
            }
            if (committed_neighbor) continue;
            norm = representable_norm;
            for (enthalpy_endpoint_mask) |recognized| {
                if (recognized != 0) {
                    has_representable_endpoints = true;
                    break;
                }
            }
        }
        final_norm = norm;
        const improved_best_state = !best_state_valid or norm < best_norm;
        if (improved_best_state) {
            best_norm = norm;
            @memcpy(best_state, current);
            best_state_valid = true;
        }
        if (!retrying_newton_after_anderson and norm <= 1) {
            try group_residual.residualAt(faces, properties, water_fluxes, base, current, target, residual, scratch, trial_flux, phase_buffers, options);
            const nonlinear_norm = try group_residual.scaledNorm(current, residual, scratch, properties.enthalpy_coupling != null, options);
            const conservation_norm = try group_residual.conservationScaledNormWithRepresentedEndpoints(
                properties,
                base,
                current,
                residual,
                enthalpy_endpoint_mask,
            );
            try group_residual.fillConservationRepresentabilityAllowances(
                properties,
                current,
                residual,
                enthalpy_endpoint_mask,
                accepted_conservation_representability_megajoules,
            );
            const boundary_heat = try commitAcceptedState(
                grid,
                properties,
                current,
                phase_buffers,
                trial_flux,
                heat_flux_megajoules,
            );
            return .{ .iterations = iteration + 1, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = anderson_steps, .topology_newton_steps = topology_newton_steps, .topology_newton_probes = topology_newton_probes, .enthalpy_topology_newton_steps = enthalpy_topology_newton_steps, .enthalpy_topology_newton_probes = enthalpy_topology_newton_probes, .enthalpy_dense_newton_steps = enthalpy_dense_newton_steps, .enthalpy_dense_newton_probes = enthalpy_dense_newton_probes, .megajoule_active_set_newton_steps = megajoule_active_set_newton_steps, .megajoule_active_set_newton_probes = megajoule_active_set_newton_probes, .directional_newton_probes = directional_newton_probes, .enthalpy_representability_probes = enthalpy_representability_probes, .phase_transition_newton_steps = phase_transition_newton_steps, .enthalpy_repriced_neighbor_steps = enthalpy_repriced_neighbor_steps, .constitutive_energy_newton_steps = constitutive_energy_newton_steps, .constitutive_energy_newton_probes = constitutive_energy_newton_probes, .damped_directional_newton_steps = damped_directional_newton_steps, .maximum_scaled_residual = norm, .maximum_scaled_nonlinear_residual = nonlinear_norm, .maximum_scaled_conservation_residual = conservation_norm, .boundary_heat_input_megajoules = boundary_heat.input_megajoules, .boundary_heat_output_megajoules = boundary_heat.output_megajoules };
        }
        phase_transition_exact_inversion: {
            if (properties.enthalpy_coupling == null or
                has_representable_endpoints)
                break :phase_transition_exact_inversion;
            if (!try phaseTransitionExactInversionDirection(
                properties,
                base,
                current,
                residual,
                scratch,
                newton_delta,
            )) break :phase_transition_exact_inversion;
            var best_transition_norm = norm;
            if (try priceNewtonDirection(
                faces,
                properties,
                water_fluxes,
                base,
                current,
                newton_delta,
                target,
                accelerated,
                &best_transition_norm,
                candidate,
                probe_residual,
                scratch,
                trial_flux,
                phase_buffers,
                options,
                options.directional_newton_max_line_search_steps,
                &constitutive_energy_newton_probes,
            )) |accepted| {
                @memcpy(current, accelerated);
                newton_steps += 1;
                phase_transition_newton_steps += 1;
                constitutive_energy_newton_steps += 1;
                if (accepted.fraction < 1 and !accepted.full_step_improved)
                    damped_directional_newton_steps += 1;
                continue;
            }
        }
        var progress_requires_anderson = false;
        if (!replaying_speculative_newton) {
            // Divergence/oscillation watch. `max_iterations` is a hard safety
            // ceiling, not a target, so a trajectory that is provably running
            // away from the best point it has found should say so instead of
            // spending the rest of the budget to report mere non-convergence.
            if (improved_best_state) {
                non_improving_steps = 0;
            } else if (norm > options.divergence_growth_factor * best_norm) {
                non_improving_steps += 1;
                if (non_improving_steps >= options.divergence_patience) {
                    // A transition shortcut is not evidence of divergence.
                    if (endpoint_discovery_optimization_skipped and
                        !force_full_endpoint_scan)
                    {
                        force_full_endpoint_scan = true;
                        continue;
                    }
                    terminal_reason = .diverged;
                    terminal_iterations = iteration + 1;
                    restore_best_before_final_audit = true;
                    break;
                }
            } else {
                non_improving_steps = 0;
            }
            const progress_floor = std.math.sqrt(std.math.floatEps(f64)) * @max(1.0, previous_norm);
            if (std.math.isFinite(previous_norm) and previous_norm - norm <= progress_floor)
                insufficient_progress_steps +|= 1
            else
                insufficient_progress_steps = 0;
            previous_norm = norm;
            progress_requires_anderson = insufficient_progress_steps >= options.divergence_patience;
            const remaining_updates = options.max_iterations - iteration;
            const minimum_recovery_updates: u16 = if (endpoint_discovery_optimization_skipped and
                !force_full_endpoint_scan)
                slow_newton_recovery_reserve
            else
                2;
            const test_forces_speculative_recovery = if (builtin.is_test)
                if (options.recovery_routing_test_control) |control|
                    control.force_speculative_iteration == iteration
                else
                    false
            else
                false;
            if (!retrying_newton_after_anderson and
                !slow_progress_recovery_pending and
                rejected_speculative_recovery_step != newton_steps and
                (test_forces_speculative_recovery or
                    (remaining_updates <= slow_newton_recovery_reserve and
                        remaining_updates >= minimum_recovery_updates and
                        slow_newton_norm_count == slow_newton_progress_history_length and
                        slowNewtonProgressNeedsRecovery(
                            slow_newton_norm_history[0],
                            slow_newton_norm_history[slow_newton_progress_history_length - 1],
                            slow_newton_progress_window_updates,
                            remaining_updates,
                        ))))
            {
                slow_progress_recovery_pending = true;
            }
        }
        const slow_progress_requires_anderson = slow_progress_recovery_pending;
        newton_primary: {
            if (!replaying_speculative_newton and
                (progress_requires_anderson or slow_progress_requires_anderson) and
                !retrying_newton_after_anderson)
                break :newton_primary;
            var accepted_newton = false;
            // A bounded dense workspace is topology-independent. When the
            // signed energy coordinate governs and no adjacent-f64 endpoint
            // is being held, linearize that governing equation before the
            // sequential-column and diagonal fallbacks.
            if (use_dense_newton and
                energy_merit_dominates and
                !has_representable_endpoints and
                !isSequentialPathTopology(count, faces, topology_lower))
            {
                if (try tryDenseSignedEnthalpyNewton(.{
                    .faces = faces,
                    .properties = properties,
                    .water_fluxes = water_fluxes,
                    .base = base,
                    .current = current,
                    .signed_scaled_enthalpy = accelerated_residual,
                    .target = target,
                    .jacobian = jacobian,
                    .direction = newton_delta,
                    .probe_state = probe,
                    .positive_scaled_enthalpy = probe_residual,
                    .best_candidate = accelerated,
                    .trial_state = candidate,
                    .trial_residual = candidate_residual,
                    .scratch = scratch,
                    .trial_flux = trial_flux,
                    .phase_buffers = phase_buffers,
                    .options = options,
                    .current_norm = norm,
                    .probe_count = &enthalpy_dense_newton_probes,
                })) |accepted| {
                    @memcpy(current, accelerated);
                    newton_steps += 1;
                    enthalpy_dense_newton_steps += 1;
                    if (accepted.fraction < 1 and !accepted.full_step_improved)
                        damped_directional_newton_steps += 1;
                    accepted_newton = true;
                }
            }
            if (accepted_newton) continue;
            // When the temperature-residual coordinate governs the merit,
            // bounded dense workspace supplies the primary Newton method on
            // every entered iteration. If the independent signed-energy
            // coordinate governs instead, its tridiagonal Newton below must
            // linearize that governing equation directly. Accepting any tiny
            // decrease from the K-equivalent dense Jacobian can otherwise
            // consume every hard-ceiling slot before the energy Newton is
            // reached at a moving phase front.
            if (use_dense_newton and !energy_merit_dominates) {
                var jacobian_valid = true;
                for (0..count) |column| {
                    const perturbation = std.math.cbrt(std.math.floatEps(f64)) * @max(1.0, @abs(current[column]));
                    @memcpy(probe, current);
                    probe[column] += perturbation;
                    if (group_residual.residualAt(faces, properties, water_fluxes, base, probe, target, probe_residual, scratch, trial_flux, phase_buffers, options)) |_| {
                        @memcpy(probe, current);
                        probe[column] -= perturbation;
                        if (!group_validation.isPhysicalTemperatureK(probe[column])) {
                            for (0..count) |row| jacobian[row * count + column] = (probe_residual[row] - residual[row]) / perturbation;
                        } else if (group_residual.residualAt(faces, properties, water_fluxes, base, probe, target, candidate_residual, scratch, trial_flux, phase_buffers, options)) |_| {
                            for (0..count) |row| jacobian[row * count + column] = (probe_residual[row] - candidate_residual[row]) / (2.0 * perturbation);
                        } else |_| {
                            jacobian_valid = false;
                            break;
                        }
                    } else |_| {
                        jacobian_valid = false;
                        break;
                    }
                }
                if (jacobian_valid) {
                    for (residual, newton_delta) |value, *right_hand_side| right_hand_side.* = -value;
                    if (numerics.solveDenseLinearSystem(jacobian, newton_delta, count)) {
                        var line_fraction: f64 = 1;
                        var line_search: u8 = 0;
                        while (line_search < 8) : (line_search += 1) {
                            var candidate_valid = true;
                            for (current, newton_delta, candidate) |value, delta, *next| {
                                next.* = value + line_fraction * delta;
                                if (!group_validation.isPhysicalTemperatureK(next.*)) candidate_valid = false;
                            }
                            if (candidate_valid) {
                                if (group_residual.residualAt(faces, properties, water_fluxes, base, candidate, target, candidate_residual, scratch, trial_flux, phase_buffers, options)) |_| {
                                    if (try conservationAwareNorm(properties, base, candidate, candidate_residual, scratch, properties.enthalpy_coupling != null, options) < norm) {
                                        if (properties.enthalpy_coupling == null)
                                            rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
                                        @memcpy(current, candidate);
                                        newton_steps += 1;
                                        accepted_newton = true;
                                        break;
                                    }
                                } else |_| {}
                            }
                            line_fraction *= 0.5;
                        }
                    }
                }
            }
            if (accepted_newton) continue;
            temperature_residual_directional: {
                if (energy_merit_dominates)
                    break :temperature_residual_directional;
                if (stageAdmissibleDirectionProbe(
                    current,
                    residual,
                    options.directional_probe_fraction,
                    probe,
                    options.directional_newton_max_line_search_steps,
                )) |probe_fraction| {
                    directional_newton_probes += 1;
                    if (group_residual.residualAt(faces, properties, water_fluxes, base, probe, target, probe_residual, scratch, trial_flux, phase_buffers, options)) |_| {
                        // A component-wise secant approximation preserves the runtime
                        // memory bound while resolving the very different thermal
                        // stiffnesses of snow, litter, and mineral-soil cells. The
                        // former single scalar fraction forced every cell to advance
                        // at the rate of the stiffest one and could miss the source
                        // NPH ceiling by one otherwise unnecessary iteration.
                        var component_step_valid = true;
                        for (residual, probe_residual, newton_delta) |base_residual, sampled_residual, *delta| {
                            const derivative_along_residual =
                                (sampled_residual - base_residual) /
                                probe_fraction;
                            if (!std.math.isFinite(derivative_along_residual) or @abs(derivative_along_residual) <= std.math.floatEps(f64)) {
                                component_step_valid = false;
                                break;
                            }
                            const raw_fraction = -base_residual / derivative_along_residual;
                            if (!std.math.isFinite(raw_fraction) or raw_fraction <= 0) {
                                component_step_valid = false;
                                break;
                            }
                            const fraction = std.math.clamp(raw_fraction, options.minimum_newton_fraction, options.maximum_newton_fraction);
                            delta.* = fraction * base_residual;
                            if (!std.math.isFinite(delta.*)) {
                                component_step_valid = false;
                                break;
                            }
                        }
                        if (component_step_valid) {
                            var best_component_norm = norm;
                            if (try priceNewtonDirection(
                                faces,
                                properties,
                                water_fluxes,
                                base,
                                current,
                                newton_delta,
                                target,
                                accelerated,
                                &best_component_norm,
                                candidate,
                                candidate_residual,
                                scratch,
                                trial_flux,
                                phase_buffers,
                                options,
                                options.directional_newton_max_line_search_steps,
                                &directional_newton_probes,
                            )) |priced| {
                                if (properties.enthalpy_coupling == null)
                                    rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
                                @memcpy(current, accelerated);
                                newton_steps += 1;
                                if (priced.fraction < 1 and !priced.full_step_improved)
                                    damped_directional_newton_steps += 1;
                                accepted_newton = true;
                            }
                        }
                        if (accepted_newton) continue;
                        var numerator: f64 = 0;
                        var denominator: f64 = 0;
                        for (residual, probe_residual) |base_residual, sampled_residual| {
                            const derivative =
                                (sampled_residual - base_residual) /
                                probe_fraction;
                            numerator += base_residual * derivative;
                            denominator += derivative * derivative;
                        }
                        if (std.math.isFinite(denominator) and denominator > std.math.floatEps(f64)) {
                            const fraction = std.math.clamp(-numerator / denominator, options.minimum_newton_fraction, options.maximum_newton_fraction);
                            for (residual, newton_delta) |difference, *delta|
                                delta.* = fraction * difference;
                            var best_directional_norm = norm;
                            if (try priceNewtonDirection(
                                faces,
                                properties,
                                water_fluxes,
                                base,
                                current,
                                newton_delta,
                                target,
                                accelerated,
                                &best_directional_norm,
                                candidate,
                                candidate_residual,
                                scratch,
                                trial_flux,
                                phase_buffers,
                                options,
                                options.directional_newton_max_line_search_steps,
                                &directional_newton_probes,
                            )) |priced| {
                                if (properties.enthalpy_coupling == null)
                                    rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
                                @memcpy(current, accelerated);
                                newton_steps += 1;
                                if (priced.fraction < 1 and !priced.full_step_improved)
                                    damped_directional_newton_steps += 1;
                                accepted_newton = true;
                            }
                        }
                    } else |_| {}
                }
            }
            if (accepted_newton) {
                // Anderson stores evaluated pairs (T, g(T)-T). The way T was
                // generated is immaterial, so accepted Newton points remain valid
                // history for a later recovery step.
                continue;
            }
            // A soil column has a tridiagonal heat Jacobian: each cell residual
            // depends only on its own temperature and its two face neighbours.
            // Three graph colours therefore recover every nonzero finite-
            // difference entry with O(n) storage. At a moving phase front the
            // operator is semismooth, so every column is perturbed in its local
            // residual-descent direction: a cell that must cross the melting kink
            // samples the destination branch. Same-colour supports do not overlap,
            // hence mixed signs preserve the three-probe construction.
            // Arbitrary non-path topologies retain the bounded directional Newton
            // above and Anderson recovery below.
            if (!energy_merit_dominates and
                isSequentialPathTopology(count, faces, topology_lower))
            {
                // Price both global one-sided generalized Jacobians plus a
                // per-cell semismooth choice at the melting kink. Global merit
                // selects without changing the equation or publishing any probe.
                var best_topology_norm = norm;
                for (0..3) |jacobian_mode| {
                    for (current, residual, topology_diagonal, 0..) |value, difference, *perturbation, cell| {
                        const scale = @max(1.0, @abs(value));
                        const robust_magnitude = std.math.cbrt(std.math.floatEps(f64)) * scale;
                        const transitions: ?CellEnthalpyTransitions = if (properties.enthalpy_coupling) |coupling| transition: {
                            const parameters = try group_enthalpy.enthalpyParameters(
                                properties,
                                coupling,
                                cell,
                            );
                            break :transition CellEnthalpyTransitions
                                .fromParameters(parameters);
                        } else null;
                        const transition_distance = if (transitions) |cell_transitions|
                            cell_transitions.nearestDistanceK(value)
                        else
                            std.math.inf(f64);
                        const near_melting = transition_distance <= 2 * robust_magnitude;
                        const difference_sign: f64 = switch (jacobian_mode) {
                            0 => 1,
                            1 => -1,
                            else => if (near_melting and difference < 0) -1 else 1,
                        };
                        var magnitude = if (near_melting)
                            std.math.sqrt(std.math.floatEps(f64)) * scale
                        else
                            robust_magnitude;
                        if (transitions) |cell_transitions| {
                            const transition_distance_in_direction =
                                cell_transitions.distanceInDirectionK(
                                    value,
                                    difference_sign,
                                );
                            if (std.math.isFinite(transition_distance_in_direction))
                                magnitude = @min(
                                    magnitude,
                                    0.5 * transition_distance_in_direction,
                                );
                        }
                        perturbation.* = difference_sign * magnitude;
                    }
                    @memset(topology_lower, 0);
                    @memset(topology_upper, 0);
                    var topology_jacobian_valid = true;
                    for (0..3) |color| {
                        @memcpy(probe, current);
                        var has_column = false;
                        var column = color;
                        while (column < count) : (column += 3) {
                            probe[column] += topology_diagonal[column];
                            has_column = true;
                        }
                        if (!has_column) continue;
                        topology_newton_probes += 1;
                        group_residual.residualAt(
                            faces,
                            properties,
                            water_fluxes,
                            base,
                            probe,
                            target,
                            probe_residual,
                            scratch,
                            trial_flux,
                            phase_buffers,
                            options,
                        ) catch {
                            topology_jacobian_valid = false;
                            break;
                        };
                        column = color;
                        while (column < count) : (column += 3) {
                            const perturbation = topology_diagonal[column];
                            topology_diagonal[column] =
                                (probe_residual[column] - residual[column]) /
                                perturbation;
                            if (column > 0)
                                topology_upper[column - 1] =
                                    (probe_residual[column - 1] - residual[column - 1]) /
                                    perturbation;
                            if (column + 1 < count)
                                topology_lower[column + 1] =
                                    (probe_residual[column + 1] - residual[column + 1]) /
                                    perturbation;
                        }
                    }
                    if (topology_jacobian_valid) {
                        topology_lower[0] = 0;
                        topology_upper[count - 1] = 0;
                        for (residual, newton_delta) |value, *right_hand_side| {
                            right_hand_side.* = -value;
                        }
                        if (has_representable_endpoints)
                            std.debug.assert(constrainRepresentableEndpointRows(
                                enthalpy_endpoint_mask,
                                topology_lower,
                                topology_diagonal,
                                topology_upper,
                                newton_delta,
                            ));
                        if (solveTridiagonal(
                            topology_lower,
                            topology_diagonal,
                            topology_upper,
                            newton_delta,
                        )) {
                            const priced = if (has_representable_endpoints)
                                try priceRepresentableNewtonDirection(
                                    faces,
                                    properties,
                                    water_fluxes,
                                    base,
                                    current,
                                    newton_delta,
                                    enthalpy_endpoint_mask,
                                    target,
                                    accelerated,
                                    &best_topology_norm,
                                    candidate,
                                    candidate_residual,
                                    scratch,
                                    probe,
                                    probe_residual,
                                    topology_diagonal,
                                    topology_lower,
                                    accepted_endpoint_proof_mask,
                                    trial_flux,
                                    phase_buffers,
                                    options,
                                    options.topology_newton_max_line_search_steps,
                                    &topology_newton_probes,
                                )
                            else
                                try priceNewtonDirection(
                                    faces,
                                    properties,
                                    water_fluxes,
                                    base,
                                    current,
                                    newton_delta,
                                    target,
                                    accelerated,
                                    &best_topology_norm,
                                    candidate,
                                    candidate_residual,
                                    scratch,
                                    trial_flux,
                                    phase_buffers,
                                    options,
                                    options.topology_newton_max_line_search_steps,
                                    &topology_newton_probes,
                                );
                            if (priced) |accepted| {
                                accepted_newton = true;
                                accepted_state_endpoint_proof_valid =
                                    accepted.endpoint_proof_valid and
                                    best_topology_norm <= 1;
                                accepted_state_endpoint_proof_norm =
                                    best_topology_norm;
                            }
                        }
                    }
                }
                if (accepted_newton) {
                    if (properties.enthalpy_coupling == null)
                        rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
                    @memcpy(current, accelerated);
                    newton_steps += 1;
                    topology_newton_steps += 1;
                    continue;
                }
            }
            // When the independent MJ gate dominates, linearizing the derived
            // K-equivalent residual can be badly conditioned by the constitutive
            // dH/dT scale. The signed scaled enthalpy defect in
            // `accelerated_residual` is the governing energy equation itself. Its
            // Jacobian remains tridiagonal because each target enthalpy depends
            // only on the cell and its two face neighbours. Build that O(n)
            // operator with three graph colours. Smooth columns use the centered
            // cbrt(eps) stencil (six probes total); a column too close to the
            // melting kink uses one branch-safe one-sided semismooth probe. Price
            // the resulting single direction on the unchanged full K+MJ merit.
            if (energy_merit_dominates and
                properties.enthalpy_coupling != null and
                isSequentialPathTopology(count, faces, topology_lower))
            {
                var best_enthalpy_topology_norm = norm;
                const coupling = properties.enthalpy_coupling.?;
                // Until the linear solve, `topology_diagonal` and `newton_delta`
                // hold the positive and negative displacement of each column.
                for (current, accelerated_residual, enthalpy_endpoint_mask, topology_diagonal, newton_delta, 0..) |value, scaled_enthalpy_defect, endpoint, *positive_delta, *negative_delta, cell| {
                    if (endpoint != 0) {
                        positive_delta.* = 0;
                        negative_delta.* = 0;
                        continue;
                    }
                    const scale = @max(1.0, @abs(value));
                    const parameters = try group_enthalpy.enthalpyParameters(
                        properties,
                        coupling,
                        cell,
                    );
                    const transitions =
                        CellEnthalpyTransitions.fromParameters(parameters);
                    const transition_distance = transitions.nearestDistanceK(value);
                    const central_magnitude = @min(
                        std.math.cbrt(std.math.floatEps(f64)) * scale,
                        0.5 * transition_distance,
                    );
                    const centered_positive = value + central_magnitude;
                    const centered_negative = value - central_magnitude;
                    const centered_stays_on_branch = central_magnitude > 0 and
                        centered_positive != value and centered_negative != value;
                    if (centered_stays_on_branch) {
                        positive_delta.* = centered_positive - value;
                        negative_delta.* = centered_negative - value;
                    } else {
                        const difference_sign: f64 = if (scaled_enthalpy_defect < 0) -1 else 1;
                        var magnitude = std.math.sqrt(std.math.floatEps(f64)) * scale;
                        const transition_distance_in_direction =
                            transitions.distanceInDirectionK(
                                value,
                                difference_sign,
                            );
                        if (std.math.isFinite(transition_distance_in_direction))
                            magnitude = @min(
                                magnitude,
                                0.5 * transition_distance_in_direction,
                            );
                        const branch_delta = difference_sign * magnitude;
                        positive_delta.* = if (branch_delta > 0) branch_delta else 0;
                        negative_delta.* = if (branch_delta < 0) branch_delta else 0;
                    }
                }
                @memset(topology_lower, 0);
                @memset(topology_upper, 0);
                var enthalpy_jacobian_valid = true;
                for (0..3) |color| {
                    @memcpy(probe, current);
                    @memcpy(candidate, current);
                    var has_positive_column = false;
                    var has_negative_column = false;
                    var column = color;
                    while (column < count) : (column += 3) {
                        const positive_delta = topology_diagonal[column];
                        const negative_delta = newton_delta[column];
                        if (positive_delta != 0) {
                            probe[column] += positive_delta;
                            has_positive_column = true;
                        }
                        if (negative_delta != 0) {
                            candidate[column] += negative_delta;
                            has_negative_column = true;
                        }
                    }
                    @memcpy(candidate_residual, accelerated_residual);
                    if (has_positive_column) {
                        enthalpy_topology_newton_probes += 1;
                        group_residual.residualAt(
                            faces,
                            properties,
                            water_fluxes,
                            base,
                            probe,
                            target,
                            probe_residual,
                            scratch,
                            trial_flux,
                            phase_buffers,
                            options,
                        ) catch {
                            enthalpy_jacobian_valid = false;
                            break;
                        };
                        @memcpy(candidate_residual, scratch);
                    }
                    @memcpy(scratch, accelerated_residual);
                    if (has_negative_column) {
                        enthalpy_topology_newton_probes += 1;
                        group_residual.residualAt(
                            faces,
                            properties,
                            water_fluxes,
                            base,
                            candidate,
                            target,
                            probe_residual,
                            scratch,
                            trial_flux,
                            phase_buffers,
                            options,
                        ) catch {
                            enthalpy_jacobian_valid = false;
                            break;
                        };
                    }
                    column = color;
                    while (column < count) : (column += 3) {
                        if (enthalpy_endpoint_mask[column] != 0) continue;
                        const perturbation_span =
                            topology_diagonal[column] - newton_delta[column];
                        if (!std.math.isFinite(perturbation_span) or perturbation_span == 0) {
                            enthalpy_jacobian_valid = false;
                            break;
                        }
                        topology_diagonal[column] =
                            (candidate_residual[column] - scratch[column]) /
                            perturbation_span;
                        if (column > 0)
                            topology_upper[column - 1] =
                                (candidate_residual[column - 1] - scratch[column - 1]) /
                                perturbation_span;
                        if (column + 1 < count)
                            topology_lower[column + 1] =
                                (candidate_residual[column + 1] - scratch[column + 1]) /
                                perturbation_span;
                    }
                    if (!enthalpy_jacobian_valid) break;
                }
                if (enthalpy_jacobian_valid) {
                    topology_lower[0] = 0;
                    topology_upper[count - 1] = 0;
                    for (accelerated_residual, newton_delta) |scaled_enthalpy_defect, *right_hand_side|
                        right_hand_side.* = -scaled_enthalpy_defect;
                    if (has_representable_endpoints)
                        std.debug.assert(constrainRepresentableEndpointRows(
                            enthalpy_endpoint_mask,
                            topology_lower,
                            topology_diagonal,
                            topology_upper,
                            newton_delta,
                        ));
                    if (solveTridiagonal(
                        topology_lower,
                        topology_diagonal,
                        topology_upper,
                        newton_delta,
                    )) {
                        const priced = if (has_representable_endpoints)
                            try priceRepresentableNewtonDirection(
                                faces,
                                properties,
                                water_fluxes,
                                base,
                                current,
                                newton_delta,
                                enthalpy_endpoint_mask,
                                target,
                                accelerated,
                                &best_enthalpy_topology_norm,
                                candidate,
                                candidate_residual,
                                scratch,
                                probe,
                                probe_residual,
                                topology_diagonal,
                                topology_lower,
                                accepted_endpoint_proof_mask,
                                trial_flux,
                                phase_buffers,
                                options,
                                options.topology_newton_max_line_search_steps,
                                &enthalpy_topology_newton_probes,
                            )
                        else
                            try priceNewtonDirection(
                                faces,
                                properties,
                                water_fluxes,
                                base,
                                current,
                                newton_delta,
                                target,
                                accelerated,
                                &best_enthalpy_topology_norm,
                                candidate,
                                candidate_residual,
                                scratch,
                                trial_flux,
                                phase_buffers,
                                options,
                                options.topology_newton_max_line_search_steps,
                                &enthalpy_topology_newton_probes,
                            );
                        const accepted_two_coordinate = priced == null and
                            !has_representable_endpoints and
                            try priceTwoCoordinateNewtonDirection(
                                faces,
                                properties,
                                water_fluxes,
                                base,
                                current,
                                accelerated_residual,
                                newton_delta,
                                target,
                                accelerated,
                                &best_enthalpy_topology_norm,
                                candidate,
                                candidate_residual,
                                scratch,
                                trial_flux,
                                phase_buffers,
                                options,
                                options.topology_newton_max_line_search_steps,
                                &enthalpy_topology_newton_probes,
                            );
                        if (accepted_two_coordinate) accepted_newton = true;
                        if (priced) |accepted| {
                            accepted_newton = true;
                            accepted_state_endpoint_proof_valid =
                                accepted.endpoint_proof_valid and
                                best_enthalpy_topology_norm <= 1;
                            accepted_state_endpoint_proof_norm =
                                best_enthalpy_topology_norm;
                        }
                    }
                }
                if (accepted_newton) {
                    if (properties.enthalpy_coupling == null)
                        rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
                    @memcpy(current, accelerated);
                    newton_steps += 1;
                    enthalpy_topology_newton_steps += 1;
                    continue;
                }
            }
            // If the signed-energy topology solve cannot reduce a sharply
            // concentrated MJ defect, restrict the analytic diagonal Newton
            // correction to the limiting smooth, representable coordinates. The
            // full combined K+MJ merit globalizes every trial, and only its single
            // best strict decrease may consume an accepted update. Any tied
            // sub-ULP coordinate remains untouched for the ordinary
            // representability audit at the start of the next iteration.
            if (energy_merit_dominates and
                properties.enthalpy_coupling != null)
            {
                @memcpy(scratch, accelerated_residual);
                for (scratch, enthalpy_endpoint_mask) |*scaled_enthalpy_defect, endpoint| {
                    if (endpoint != 0) scaled_enthalpy_defect.* = 0;
                }
                if (try mjActiveSetNewtonDirection(
                    properties,
                    current,
                    residual,
                    scratch,
                    newton_delta,
                )) {
                    var best_megajoule_active_set_norm = norm;
                    const active_set_line_search_steps = @min(
                        options.directional_newton_max_line_search_steps,
                        megajoule_active_set_max_line_search_steps,
                    );
                    const priced = if (has_representable_endpoints)
                        try priceRepresentableNewtonDirection(
                            faces,
                            properties,
                            water_fluxes,
                            base,
                            current,
                            newton_delta,
                            enthalpy_endpoint_mask,
                            target,
                            accelerated,
                            &best_megajoule_active_set_norm,
                            candidate,
                            candidate_residual,
                            scratch,
                            probe,
                            probe_residual,
                            topology_diagonal,
                            topology_lower,
                            accepted_endpoint_proof_mask,
                            trial_flux,
                            phase_buffers,
                            options,
                            active_set_line_search_steps,
                            &megajoule_active_set_newton_probes,
                        )
                    else
                        try priceNewtonDirection(
                            faces,
                            properties,
                            water_fluxes,
                            base,
                            current,
                            newton_delta,
                            target,
                            accelerated,
                            &best_megajoule_active_set_norm,
                            candidate,
                            candidate_residual,
                            scratch,
                            trial_flux,
                            phase_buffers,
                            options,
                            active_set_line_search_steps,
                            &megajoule_active_set_newton_probes,
                        );
                    if (priced) |accepted| {
                        accepted_state_endpoint_proof_valid =
                            accepted.endpoint_proof_valid and
                            best_megajoule_active_set_norm <= 1;
                        accepted_state_endpoint_proof_norm =
                            best_megajoule_active_set_norm;
                        @memcpy(current, accelerated);
                        newton_steps += 1;
                        megajoule_active_set_newton_steps += 1;
                        if (accepted.fraction < 1 and !accepted.full_step_improved)
                            damped_directional_newton_steps += 1;
                        continue;
                    }
                }
            }
            // The direct Appendix C residual already divides the enthalpy defect
            // by the positive analytic constitutive tangent. If numerical secants
            // and the topology-local Jacobian cannot find a descent step in a
            // smooth branch, that temperature defect is the exact diagonal Newton
            // correction for H(T)-H_target. Every candidate is still globally
            // line-searched on both K and MJ gates, with one promotion at most.
            // Latent-kink coordinates remain owned by representability logic.
            if (properties.enthalpy_coupling != null) {
                if (try constitutiveEnergyNewtonDirection(
                    properties,
                    current,
                    residual,
                    newton_delta,
                )) {
                    for (newton_delta, enthalpy_endpoint_mask) |*delta, endpoint| {
                        if (endpoint != 0) delta.* = 0;
                    }
                    var best_constitutive_norm = norm;
                    const priced = if (has_representable_endpoints)
                        try priceRepresentableNewtonDirection(
                            faces,
                            properties,
                            water_fluxes,
                            base,
                            current,
                            newton_delta,
                            enthalpy_endpoint_mask,
                            target,
                            accelerated,
                            &best_constitutive_norm,
                            candidate,
                            candidate_residual,
                            scratch,
                            probe,
                            probe_residual,
                            topology_diagonal,
                            topology_lower,
                            accepted_endpoint_proof_mask,
                            trial_flux,
                            phase_buffers,
                            options,
                            options.directional_newton_max_line_search_steps,
                            &constitutive_energy_newton_probes,
                        )
                    else
                        try priceNewtonDirection(
                            faces,
                            properties,
                            water_fluxes,
                            base,
                            current,
                            newton_delta,
                            target,
                            accelerated,
                            &best_constitutive_norm,
                            candidate,
                            candidate_residual,
                            scratch,
                            trial_flux,
                            phase_buffers,
                            options,
                            options.directional_newton_max_line_search_steps,
                            &constitutive_energy_newton_probes,
                        );
                    if (priced) |accepted| {
                        accepted_state_endpoint_proof_valid =
                            accepted.endpoint_proof_valid and
                            best_constitutive_norm <= 1;
                        accepted_state_endpoint_proof_norm =
                            best_constitutive_norm;
                        if (properties.enthalpy_coupling == null)
                            rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
                        @memcpy(current, accelerated);
                        newton_steps += 1;
                        constitutive_energy_newton_steps += 1;
                        if (accepted.fraction < 1 and !accepted.full_step_improved)
                            damped_directional_newton_steps += 1;
                        continue;
                    }
                }
            }
        }
        if (retrying_newton_after_anderson) continue;
        // The transition-aware shortcut avoids probing obviously smooth cells
        // on ordinary iterations. Before declaring Newton stagnation and
        // entering recovery, repeat discovery without any shortcut if even one
        // unresolved MJ>1 coordinate was skipped. The final allowed iteration
        // already disables the shortcut above, so no hard-ceiling failure can
        // bypass this conservative audit.
        if (endpoint_discovery_optimization_skipped and
            !force_full_endpoint_scan)
        {
            force_full_endpoint_scan = true;
            continue;
        }
        if (iteration + 1 >= options.max_iterations) {
            terminal_iterations = iteration + 1;
            restore_best_before_final_audit = true;
            break;
        }
        // RECOVERY. In enthalpy-coupled cells, g(T) is the exact per-cell
        // inversion of the complete simultaneous-face target enthalpy. The
        // raw image and its relaxed seed are evaluated only to form a genuine
        // Anderson pair; neither is eligible for publication. Scalar
        // inversions occur only here, after every Newton path has failed.
        var used_anderson = false;
        var best_anderson_norm = norm;
        var recovery_pair_ready = false;
        var current_fixed_point_defect: []const f64 = residual;
        if (properties.enthalpy_coupling != null) {
            if (group_residual.exactEnthalpyPicardImage(
                faces,
                properties,
                water_fluxes,
                base,
                current,
                probe,
                target,
                candidate_residual,
                scratch,
                trial_flux,
                phase_buffers,
                options,
            )) |_| {
                var valid_seed = true;
                for (current, probe, accelerated_residual, candidate) |value, image, *defect, *seed| {
                    defect.* = image - value;
                    seed.* = value + options.picard_relaxation * defect.*;
                    if (!std.math.isFinite(defect.*) or
                        !group_validation.isPhysicalTemperatureK(seed.*))
                    {
                        valid_seed = false;
                        break;
                    }
                }
                if (valid_seed) {
                    if (group_residual.exactEnthalpyPicardImage(
                        faces,
                        properties,
                        water_fluxes,
                        base,
                        candidate,
                        newton_delta,
                        target,
                        probe_residual,
                        scratch,
                        trial_flux,
                        phase_buffers,
                        options,
                    )) |_| {
                        for (newton_delta, candidate, candidate_residual) |image, seed, *defect|
                            defect.* = image - seed;
                        current_fixed_point_defect = accelerated_residual;
                        recovery_pair_ready = true;
                    } else |_| {}
                }
            } else |_| {}
        } else {
            if (stageAdmissibleDirectionProbe(
                current,
                residual,
                options.picard_relaxation,
                candidate,
                options.directional_newton_max_line_search_steps,
            ) != null) {
                if (group_residual.residualAt(faces, properties, water_fluxes, base, candidate, target, candidate_residual, scratch, trial_flux, phase_buffers, options)) |_| {
                    recovery_pair_ready = true;
                } else |_| {}
            }
        }
        if (recovery_pair_ready) {
            // `candidate` is the evaluated raw/relaxed Picard seed used only
            // to form an Anderson pair. It is prohibited from publication, so
            // its merit cannot become the acceptance incumbent: doing so can
            // reject an Anderson proposal that strictly improves the current
            // publishable state merely because the forbidden seed is better.
            if (numerics.andersonDepthOneCandidate(current, current_fixed_point_defect, candidate, candidate_residual, accelerated)) {
                used_anderson = try priceAndersonDirection(
                    faces,
                    properties,
                    water_fluxes,
                    base,
                    current,
                    accelerated,
                    target,
                    candidate,
                    &best_anderson_norm,
                    probe,
                    probe_residual,
                    scratch,
                    trial_flux,
                    phase_buffers,
                    options,
                );
            }
        }
        // Anderson acceleration over consistent evaluated (T, g(T)-T) pairs.
        // Depth 2 is priced before depth 1, and every proposal must strictly
        // decrease the fully recomputed K+MJ merit. The plain exact image and
        // relaxed seed are never eligible for publication.
        if (options.anderson_recovery and recovery_pair_ready and history_count > 0) {
            if (history_count > 1) {
                // Depth-2 mixture: least squares over the two most recent
                // defect differences, solved as a 2x2 normal system. Scale
                // first so a physically small residual does not make a
                // nonsingular history look smaller than machine epsilon.
                var difference_scale: f64 = 0;
                for (current_fixed_point_defect, previous_residual, previous_previous_residual) |current_value, previous_value, older_value| {
                    difference_scale = @max(
                        difference_scale,
                        @max(
                            @abs(current_value - previous_value),
                            @abs(previous_value - older_value),
                        ),
                    );
                }
                var gram_00: f64 = 0;
                var gram_01: f64 = 0;
                var gram_11: f64 = 0;
                var right_hand_side_0: f64 = 0;
                var right_hand_side_1: f64 = 0;
                if (difference_scale > 0 and std.math.isFinite(difference_scale)) for (current_fixed_point_defect, previous_residual, previous_previous_residual) |current_value, previous_value, older_value| {
                    const difference_0 = (current_value - previous_value) / difference_scale;
                    const difference_1 = (previous_value - older_value) / difference_scale;
                    const scaled_current = current_value / difference_scale;
                    gram_00 += difference_0 * difference_0;
                    gram_01 += difference_0 * difference_1;
                    gram_11 += difference_1 * difference_1;
                    right_hand_side_0 += difference_0 * scaled_current;
                    right_hand_side_1 += difference_1 * scaled_current;
                };
                const determinant = gram_00 * gram_11 - gram_01 * gram_01;
                if (std.math.isFinite(determinant) and @abs(determinant) > std.math.floatEps(f64) * @max(1.0, gram_00 * gram_11)) {
                    const mixing_0 = (right_hand_side_0 * gram_11 - right_hand_side_1 * gram_01) / determinant;
                    const mixing_1 = (gram_00 * right_hand_side_1 - gram_01 * right_hand_side_0) / determinant;
                    var valid_candidate = std.math.isFinite(mixing_0) and std.math.isFinite(mixing_1);
                    if (valid_candidate) for (current, current_fixed_point_defect, previous_state, previous_residual, previous_previous_state, previous_previous_residual, accelerated) |value, value_residual, old_value, old_residual, older_value, older_residual, *next| {
                        const fixed_point = value + value_residual;
                        const old_fixed_point = old_value + old_residual;
                        const older_fixed_point = older_value + older_residual;
                        next.* = fixed_point - mixing_0 * (fixed_point - old_fixed_point) - mixing_1 * (old_fixed_point - older_fixed_point);
                        // An extrapolated endpoint may leave the physical
                        // domain; pricing still gets to recover a bounded
                        // interpolation toward it.
                        if (!std.math.isFinite(next.*)) {
                            valid_candidate = false;
                            break;
                        }
                    };
                    if (valid_candidate) {
                        used_anderson = (try priceAndersonDirection(
                            faces,
                            properties,
                            water_fluxes,
                            base,
                            current,
                            accelerated,
                            target,
                            candidate,
                            &best_anderson_norm,
                            probe,
                            probe_residual,
                            scratch,
                            trial_flux,
                            phase_buffers,
                            options,
                        )) or used_anderson;
                    }
                }
            }
            var difference_scale: f64 = 0;
            for (current_fixed_point_defect, previous_residual) |current_value, previous_value| {
                difference_scale = @max(
                    difference_scale,
                    @abs(current_value - previous_value),
                );
            }
            var numerator: f64 = 0;
            var denominator: f64 = 0;
            if (difference_scale > 0 and std.math.isFinite(difference_scale)) for (current_fixed_point_defect, previous_residual) |current_value, previous_value| {
                const change = (current_value - previous_value) / difference_scale;
                numerator += (current_value / difference_scale) * change;
                denominator += change * change;
            };
            if (std.math.isFinite(numerator) and
                std.math.isFinite(denominator) and
                denominator > std.math.floatEps(f64))
            {
                const mixing = numerator / denominator;
                var valid_candidate = std.math.isFinite(mixing);
                if (valid_candidate) for (current, current_fixed_point_defect, previous_state, previous_residual, accelerated) |value, value_residual, old_value, old_residual, *next| {
                    const fixed_point = value + value_residual;
                    const old_fixed_point = old_value + old_residual;
                    next.* = fixed_point - mixing * (fixed_point - old_fixed_point);
                    if (!std.math.isFinite(next.*)) {
                        valid_candidate = false;
                        break;
                    }
                };
                if (valid_candidate) {
                    used_anderson = (try priceAndersonDirection(
                        faces,
                        properties,
                        water_fluxes,
                        base,
                        current,
                        accelerated,
                        target,
                        candidate,
                        &best_anderson_norm,
                        probe,
                        probe_residual,
                        scratch,
                        trial_flux,
                        phase_buffers,
                        options,
                    )) or used_anderson;
                }
            }
        }
        if (slow_progress_requires_anderson and !progress_requires_anderson and
            builtin.is_test)
        {
            if (options.recovery_routing_test_control) |control| {
                control.speculative_probes +|= 1;
                control.speculative_anderson_iteration = iteration + 1;
                if (control.reject_speculative_anderson) {
                    used_anderson = false;
                }
            }
        }
        if (!used_anderson) {
            if (slow_progress_requires_anderson and !progress_requires_anderson) {
                // A contraction forecast is evidence that Anderson is worth
                // pricing, not evidence that Newton has failed. Every probe is
                // unpublished, so retry ordinary Newton in the next counted
                // outer slot when no strictly improving Anderson candidate
                // exists. The guard above reserves that retry inside the user
                // hard ceiling.
                slow_progress_recovery_pending = false;
                rejected_speculative_recovery_step = newton_steps;
                if (builtin.is_test) {
                    if (options.recovery_routing_test_control) |control|
                        control.next_slot_newton_fallbacks +|= 1;
                }
                speculative_newton_replay = true;
                continue;
            }
            // The interval-relative conservation norm is the authoritative
            // final gate, but it is not a globally monotone search merit once
            // a Newton step has crossed the base state in the direction
            // opposite to the expected heat forcing. On that wrong side its
            // denominator grows with the erroneous storage excursion, so
            // returning toward the root can look worse even while the actual
            // energy residual falls by orders of magnitude. Only after every
            // ordinary Newton and Anderson proposal has failed, allow one
            // bounded constitutive Newton update selected by strict nonlinear
            // descent. The next loop re-enters all ordinary gates, and no
            // state can be published without the unchanged conservation audit.
            if (properties.enthalpy_coupling != null) {
                try group_residual.residualAt(
                    faces,
                    properties,
                    water_fluxes,
                    base,
                    current,
                    target,
                    residual,
                    scratch,
                    trial_flux,
                    phase_buffers,
                    options,
                );
                if (try group_residual.worstConservationComponent(
                    properties,
                    base,
                    current,
                    residual,
                )) |component| {
                    const wrong_side_storage_excursion =
                        component.non_phase_heat_megajoules != 0 and
                        component.delta_storage_megajoules != 0 and
                        std.math.signbit(component.non_phase_heat_megajoules) !=
                            std.math.signbit(component.delta_storage_megajoules);
                    const current_nonlinear_norm = try group_residual.scaledNorm(
                        current,
                        residual,
                        scratch,
                        true,
                        options,
                    );
                    if (wrong_side_storage_excursion and
                        component.scaled_norm > current_nonlinear_norm and
                        current_nonlinear_norm > 1 and
                        try constitutiveEnergyNewtonDirection(
                            properties,
                            current,
                            residual,
                            newton_delta,
                        ))
                    {
                        for (newton_delta, enthalpy_endpoint_mask) |*delta, endpoint| {
                            if (endpoint != 0) delta.* = 0;
                        }
                        var best_nonlinear_norm = current_nonlinear_norm;
                        if (try priceNonlinearNewtonDirection(
                            faces,
                            properties,
                            water_fluxes,
                            base,
                            current,
                            newton_delta,
                            target,
                            accelerated,
                            &best_nonlinear_norm,
                            candidate,
                            candidate_residual,
                            scratch,
                            trial_flux,
                            phase_buffers,
                            options,
                            options.directional_newton_max_line_search_steps,
                            &constitutive_energy_newton_probes,
                        )) |accepted| {
                            @memcpy(current, accelerated);
                            newton_steps += 1;
                            constitutive_energy_newton_steps += 1;
                            if (accepted.fraction < 1 and
                                !accepted.full_step_improved)
                                damped_directional_newton_steps += 1;
                            continue;
                        }
                    }
                }
            }
            terminal_reason = .stagnated;
            terminal_iterations = iteration + 1;
            restore_best_before_final_audit = true;
            break;
        }
        if (options.anderson_recovery and recovery_pair_ready)
            rememberIteration(current, current_fixed_point_defect, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
        // Candidate pricing is probe-only. Exactly one full-state promotion
        // consumes this iteration, regardless of how many Anderson depths
        // improved the incumbent candidate before the final commit.
        @memcpy(current, candidate);
        anderson_steps += 1;
        picard_steps += 1;
        slow_newton_norm_count = 0;
        slow_progress_recovery_pending = false;
        rejected_speculative_recovery_step = null;
        newton_retry_required = true;
    }
    if (restore_best_before_final_audit and best_state_valid) {
        @memcpy(current, best_state);
        accepted_state_endpoint_proof_valid = false;
        accepted_state_endpoint_proof_norm = std.math.inf(f64);
        @memset(accepted_endpoint_proof_mask, 0);
        @memset(enthalpy_endpoint_mask, 0);
        newton_retry_required = false;
    }
    // The last permitted Newton/Picard update must be tested before declaring
    // failure; otherwise max_iterations=N permits only N-1 useful updates.
    try group_residual.residualAt(faces, properties, water_fluxes, base, current, target, residual, scratch, trial_flux, phase_buffers, options);
    var final_endpoint_proof_reused = false;
    final_norm = final_audit: {
        if (accepted_state_endpoint_proof_valid) {
            @memcpy(accelerated_residual, scratch);
            for (accepted_endpoint_proof_mask, accelerated_residual) |proven, *scaled_enthalpy| {
                if (proven != 0) scaled_enthalpy.* = 0;
            }
            const reused_norm = try conservationAwareMaskedEndpointNorm(
                properties,
                base,
                current,
                residual,
                accelerated_residual,
                accepted_endpoint_proof_mask,
                options,
            );
            if (reused_norm <= 1) {
                std.debug.assert(
                    reused_norm == accepted_state_endpoint_proof_norm,
                );
                @memcpy(
                    enthalpy_endpoint_mask,
                    accepted_endpoint_proof_mask,
                );
                final_endpoint_proof_reused = true;
                break :final_audit reused_norm;
            }
        }
        break :final_audit try probeOnlyFinalRepresentableNorm(
            faces,
            properties,
            water_fluxes,
            base,
            current,
            target,
            residual,
            scratch,
            candidate,
            candidate_residual,
            accelerated_residual,
            topology_upper,
            enthalpy_endpoint_mask,
            trial_flux,
            phase_buffers,
            options,
            &enthalpy_representability_probes,
        );
    };
    var nonlinear_norm = try group_residual.scaledNorm(current, residual, scratch, properties.enthalpy_coupling != null, options);
    var conservation_norm = try group_residual.conservationScaledNormWithRepresentedEndpoints(
        properties,
        base,
        current,
        residual,
        enthalpy_endpoint_mask,
    );
    // A converged K/MJ nonlinear state can still miss a much tighter local
    // relative-conservation target by a few dozen temperature ULPs. Do not
    // accept that residual and do not restart the external hour. Instead use
    // the existing exact constitutive inversion as a bounded last-mile
    // correction, globally line-search every proposal on the unchanged
    // nonlinear+conservation merit, and retain only strict improvements.
    // Fifteen corrections extend the ordinary 20-update Ottawa budget to the
    // requested ~35 patience without turning a genuinely unconverged state
    // into an open-ended retry cascade.
    const maximum_conservation_refinement_steps: u8 = 15;
    var conservation_refinement_steps: u8 = 0;
    var direct_conservation_refinement_steps: u8 = 0;
    var conservation_refinement_attempted = false;
    if (properties.enthalpy_coupling != null and
        nonlinear_norm <= 1 and conservation_norm > 1)
    {
        conservation_refinement_attempted = true;
        while (conservation_refinement_steps <
            maximum_conservation_refinement_steps)
        {
            // `residual` is the exact target-minus-trial enthalpy defect
            // divided by the positive constitutive tangent. At the last-mile
            // scale it is a more accurate Newton temperature correction than
            // reinverting target enthalpy with the ordinary scalar solver,
            // whose configured convergence tolerance can legitimately return
            // the unchanged temperature for a picokelvin defect.
            var has_recognized_endpoint = false;
            for (residual, enthalpy_endpoint_mask, newton_delta) |difference_k, endpoint, *delta| {
                delta.* = if (endpoint != 0) 0 else difference_k;
                has_recognized_endpoint = has_recognized_endpoint or
                    endpoint != 0;
            }
            var refined_norm = final_norm;
            var endpoint_proof_valid = false;
            var used_direct_correction = if (has_recognized_endpoint)
                if (try priceRepresentableNewtonDirection(
                    faces,
                    properties,
                    water_fluxes,
                    base,
                    current,
                    newton_delta,
                    enthalpy_endpoint_mask,
                    target,
                    candidate,
                    &refined_norm,
                    accelerated,
                    accelerated_residual,
                    scratch,
                    probe,
                    probe_residual,
                    topology_diagonal,
                    topology_lower,
                    accepted_endpoint_proof_mask,
                    trial_flux,
                    phase_buffers,
                    options,
                    8,
                    &enthalpy_representability_probes,
                )) |priced| endpoint_priced: {
                    endpoint_proof_valid = priced.endpoint_proof_valid;
                    break :endpoint_priced true;
                } else false
            else direct_priced: {
                for (current, newton_delta, probe) |temperature_k, delta, *next|
                    next.* = temperature_k + delta;
                break :direct_priced try priceAndersonDirection(
                    faces,
                    properties,
                    water_fluxes,
                    base,
                    current,
                    probe,
                    target,
                    candidate,
                    &refined_norm,
                    accelerated,
                    accelerated_residual,
                    scratch,
                    trial_flux,
                    phase_buffers,
                    options,
                );
            };
            if (!used_direct_correction) {
                group_residual.exactEnthalpyPicardImage(
                    faces,
                    properties,
                    water_fluxes,
                    base,
                    current,
                    probe,
                    target,
                    candidate_residual,
                    scratch,
                    trial_flux,
                    phase_buffers,
                    options,
                ) catch break;
                for (current, probe, enthalpy_endpoint_mask, newton_delta) |temperature_k, proposed_temperature_k, endpoint, *delta| {
                    delta.* = if (endpoint != 0)
                        0
                    else
                        proposed_temperature_k - temperature_k;
                }
                used_direct_correction = if (has_recognized_endpoint)
                    if (try priceRepresentableNewtonDirection(
                        faces,
                        properties,
                        water_fluxes,
                        base,
                        current,
                        newton_delta,
                        enthalpy_endpoint_mask,
                        target,
                        candidate,
                        &refined_norm,
                        accelerated,
                        accelerated_residual,
                        scratch,
                        probe,
                        probe_residual,
                        topology_diagonal,
                        topology_lower,
                        accepted_endpoint_proof_mask,
                        trial_flux,
                        phase_buffers,
                        options,
                        8,
                        &enthalpy_representability_probes,
                    )) |priced| endpoint_priced: {
                        endpoint_proof_valid = priced.endpoint_proof_valid;
                        break :endpoint_priced true;
                    } else false
                else picard_priced: {
                    for (current, newton_delta, probe) |temperature_k, delta, *next|
                        next.* = temperature_k + delta;
                    break :picard_priced try priceAndersonDirection(
                        faces,
                        properties,
                        water_fluxes,
                        base,
                        current,
                        probe,
                        target,
                        candidate,
                        &refined_norm,
                        accelerated,
                        accelerated_residual,
                        scratch,
                        trial_flux,
                        phase_buffers,
                        options,
                    );
                };
                if (!used_direct_correction) break;
            } else {
                direct_conservation_refinement_steps += 1;
            }
            validateSoilTemperaturePhysicalDomain(candidate) catch break;
            @memcpy(current, candidate);
            if (endpoint_proof_valid)
                @memcpy(
                    enthalpy_endpoint_mask,
                    accepted_endpoint_proof_mask,
                )
            else
                @memset(enthalpy_endpoint_mask, 0);
            conservation_refinement_steps += 1;
            // A last-slot Anderson promotion normally requires a subsequent
            // non-Anderson update before publication. This exact constitutive
            // correction is that update; its globally priced state is audited
            // again below before it can satisfy either acceptance path.
            newton_retry_required = false;
            try group_residual.residualAt(
                faces,
                properties,
                water_fluxes,
                base,
                current,
                target,
                residual,
                scratch,
                trial_flux,
                phase_buffers,
                options,
            );
            // Preserve every already-proven adjacent endpoint while a free
            // coordinate advances, then rebuild the complete simultaneous
            // certificate for this exact accepted state. Raw whole-vector
            // merit would let an unrepresentable coordinate veto Newton
            // progress on an unrelated resolvable conservation defect.
            final_norm = try probeOnlyFinalRepresentableNorm(
                faces,
                properties,
                water_fluxes,
                base,
                current,
                target,
                residual,
                scratch,
                candidate,
                candidate_residual,
                accelerated_residual,
                topology_upper,
                enthalpy_endpoint_mask,
                trial_flux,
                phase_buffers,
                options,
                &enthalpy_representability_probes,
            );
            nonlinear_norm = try group_residual.scaledNorm(
                current,
                residual,
                scratch,
                true,
                options,
            );
            conservation_norm = try group_residual.conservationScaledNormWithRepresentedEndpoints(
                properties,
                base,
                current,
                residual,
                enthalpy_endpoint_mask,
            );
            if (final_norm <= 1) break;
            if (nonlinear_norm > 1) break;
        }
        // A rejected proposal may leave shared probe buffers at an adjacent
        // state, while an accepted correction has already rebuilt provenance
        // for its exact state. Re-run the probe-only audit before deciding
        // acceptance; it cannot promote a neighboring temperature or spend
        // another nonlinear iteration.
        if (final_norm > 1 and nonlinear_norm <= 1) {
            final_norm = try probeOnlyFinalRepresentableNorm(
                faces,
                properties,
                water_fluxes,
                base,
                current,
                target,
                residual,
                scratch,
                candidate,
                candidate_residual,
                accelerated_residual,
                topology_upper,
                enthalpy_endpoint_mask,
                trial_flux,
                phase_buffers,
                options,
                &enthalpy_representability_probes,
            );
            conservation_norm = try group_residual.conservationScaledNormWithRepresentedEndpoints(
                properties,
                base,
                current,
                residual,
                enthalpy_endpoint_mask,
            );
        }
        if (!builtin.is_test and conservation_refinement_attempted)
            std.log.debug(
                "soil heat conservation refinement: steps={d} direct_steps={d} nonlinear_norm={e} conservation_norm={e} final_norm={e}",
                .{ conservation_refinement_steps, direct_conservation_refinement_steps, nonlinear_norm, conservation_norm, final_norm },
            );
    }
    const strict_accept = !newton_retry_required and final_norm <= 1;
    // NEWTON-ANDERSON-PRACTICAL-ACCEPTANCE-001: legacy ecosys_f77 never chases
    // tight nonlinear convergence at all -- `wthr.f`'s NPH/NPT/NPG/NPR/NPS
    // cycle counts (fixed or predictively sized, never adaptively retried on
    // "non-convergence") always accept their fixed-effort result outright.
    // This mirrors that acceptance philosophy for the *numerical* residual
    // only: a candidate whose raw K-space/enthalpy residual is still within
    // `practical_nonlinear_multiplier` times the strict Newton-Anderson
    // tolerance (still an extremely tight absolute/relative band -- 100x a
    // 1e-8 relative tolerance is 1e-6 relative, far tighter than any
    // practical physical measurement) is accepted PROVIDED the separately
    // computed, already physically-grounded conservation check
    // (`conservation_norm`, tied to the runscript's own
    // `mass_balance_tolerance`/`mass_balance_absolute_tolerance`/
    // `mass_balance_relative_tolerance` via `conservationScaledNorm`)
    // remains fully strict (`<= 1`). A separately proven adjacent-f64 heat
    // endpoint can contribute only its explicit one-ULP constitutive energy
    // width to that gate; this practical path adds no further allowance.
    // Water/energy/mass conservation is never otherwise loosened here -- only
    // the pursuit of numerical digits beyond what conservation itself requires. Finiteness and
    // physical bounds are enforced unconditionally by `scaledNorm`/
    // `conservationScaledNorm` themselves (`error.NonFiniteSoilHeatSolverState`)
    // and by the solve's own bound-clamped candidate construction, so no
    // separate check is needed here.
    //
    // This does NOT accept the `SURFACE-HEAT-BRACKET-RUNAWAY-001` failure
    // signature (K-space converges while `conservation_norm` itself stays
    // above 1) -- that is a genuine conservation violation and correctly
    // still falls through to `error.SoilHeatSolverDidNotConverge` below.
    // This path instead targets the more common case of a solve grinding
    // for the last few ULPs of K-space residual after conservation is
    // already satisfied.
    const practical_nonlinear_multiplier: f64 = 100.0;
    const practical_accept = !newton_retry_required and
        nonlinear_norm <= practical_nonlinear_multiplier and
        conservation_norm <= 1;
    if (options.diagnostic_trace) |trace| if (trace.on_final_acceptance) |callback|
        callback(trace.context, nonlinear_norm, conservation_norm, strict_accept, practical_accept);
    if (strict_accept or practical_accept) {
        if (practical_accept and !strict_accept and !builtin.is_test)
            std.log.warn("soil heat solver accepted via practical-residual path (NEWTON-ANDERSON-PRACTICAL-ACCEPTANCE-001): nonlinear_norm={e} conservation_norm={e} final_norm={e}", .{ nonlinear_norm, conservation_norm, final_norm });
        try group_residual.fillConservationRepresentabilityAllowances(
            properties,
            current,
            residual,
            enthalpy_endpoint_mask,
            accepted_conservation_representability_megajoules,
        );
        const boundary_heat = try commitAcceptedState(
            grid,
            properties,
            current,
            phase_buffers,
            trial_flux,
            heat_flux_megajoules,
        );
        return .{ .iterations = terminal_iterations, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = anderson_steps, .topology_newton_steps = topology_newton_steps, .topology_newton_probes = topology_newton_probes, .enthalpy_topology_newton_steps = enthalpy_topology_newton_steps, .enthalpy_topology_newton_probes = enthalpy_topology_newton_probes, .enthalpy_dense_newton_steps = enthalpy_dense_newton_steps, .enthalpy_dense_newton_probes = enthalpy_dense_newton_probes, .megajoule_active_set_newton_steps = megajoule_active_set_newton_steps, .megajoule_active_set_newton_probes = megajoule_active_set_newton_probes, .directional_newton_probes = directional_newton_probes, .enthalpy_representability_probes = enthalpy_representability_probes, .phase_transition_newton_steps = phase_transition_newton_steps, .enthalpy_repriced_neighbor_steps = enthalpy_repriced_neighbor_steps, .final_endpoint_proof_reused = final_endpoint_proof_reused, .constitutive_energy_newton_steps = constitutive_energy_newton_steps, .constitutive_energy_newton_probes = constitutive_energy_newton_probes, .damped_directional_newton_steps = damped_directional_newton_steps, .maximum_scaled_residual = final_norm, .maximum_scaled_nonlinear_residual = nonlinear_norm, .maximum_scaled_conservation_residual = conservation_norm, .boundary_heat_input_megajoules = boundary_heat.input_megajoules, .boundary_heat_output_megajoules = boundary_heat.output_megajoules };
    }
    if (!builtin.is_test) {
        switch (terminal_reason) {
            .diverged => std.log.warn("soil heat solver diverging after best-state physical audit: iteration={d} final_scaled_residual={e} best_scaled_residual={e} growth_factor={e} patience={d}", .{ terminal_iterations, final_norm, best_norm, options.divergence_growth_factor, options.divergence_patience }),
            .stagnated => std.log.err(
                "soil heat Newton-Raphson/Anderson stagnated after best-state physical audit: iteration={d} final_scaled_residual={e} best_scaled_residual={e} newton_steps={d} damped_directional_newton_steps={d} directional_newton_probes={d} topology_newton_steps={d} topology_newton_probes={d} enthalpy_topology_newton_steps={d} enthalpy_topology_newton_probes={d} enthalpy_dense_newton_steps={d} enthalpy_dense_newton_probes={d} megajoule_active_set_newton_steps={d} megajoule_active_set_newton_probes={d} constitutive_energy_newton_steps={d} constitutive_energy_newton_probes={d} enthalpy_representability_probes={d} phase_transition_newton_steps={d} enthalpy_repriced_neighbor_steps={d} picard_steps={d} anderson_steps={d} history_count={d} nonlinear_norm={e} conservation_norm={e}",
                .{ terminal_iterations, final_norm, best_norm, newton_steps, damped_directional_newton_steps, directional_newton_probes, topology_newton_steps, topology_newton_probes, enthalpy_topology_newton_steps, enthalpy_topology_newton_probes, enthalpy_dense_newton_steps, enthalpy_dense_newton_probes, megajoule_active_set_newton_steps, megajoule_active_set_newton_probes, constitutive_energy_newton_steps, constitutive_energy_newton_probes, enthalpy_representability_probes, phase_transition_newton_steps, enthalpy_repriced_neighbor_steps, picard_steps, anderson_steps, history_count, nonlinear_norm, conservation_norm },
            ),
            // Reports the SAME counter set as `.stagnated` above. The abbreviated
            // form this replaced omitted every enthalpy-path counter, which made
            // an iteration-limit failure impossible to attribute to a direction
            // path without rebuilding: it showed `topology_newton_steps=0` while
            // hiding that the work had gone into `enthalpy_repriced_neighbor_steps`.
            .iteration_limit => std.log.err(
                "soil heat Newton-Raphson/Anderson did not converge: iterations={d} final_scaled_residual={e} newton_steps={d} damped_directional_newton_steps={d} directional_newton_probes={d} topology_newton_steps={d} topology_newton_probes={d} enthalpy_topology_newton_steps={d} enthalpy_topology_newton_probes={d} enthalpy_dense_newton_steps={d} enthalpy_dense_newton_probes={d} megajoule_active_set_newton_steps={d} megajoule_active_set_newton_probes={d} constitutive_energy_newton_steps={d} constitutive_energy_newton_probes={d} enthalpy_representability_probes={d} phase_transition_newton_steps={d} enthalpy_repriced_neighbor_steps={d} picard_steps={d} anderson_steps={d} history_count={d} nonlinear_norm={e} conservation_norm={e}",
                .{ terminal_iterations, final_norm, newton_steps, damped_directional_newton_steps, directional_newton_probes, topology_newton_steps, topology_newton_probes, enthalpy_topology_newton_steps, enthalpy_topology_newton_probes, enthalpy_dense_newton_steps, enthalpy_dense_newton_probes, megajoule_active_set_newton_steps, megajoule_active_set_newton_probes, constitutive_energy_newton_steps, constitutive_energy_newton_probes, enthalpy_representability_probes, phase_transition_newton_steps, enthalpy_repriced_neighbor_steps, picard_steps, anderson_steps, history_count, nonlinear_norm, conservation_norm },
            ),
        }
        // REAL-DECK-HOUR-11-FATAL-STAGNATION-001 (2026-09-04): a large
        // conservation_norm here could mean either a genuine physical
        // conservation defect, or the same class of bug already found once
        // this session -- a candidate temperature drifting to an extreme,
        // unphysical value before ever reaching commitAcceptedState's own
        // [173.15, 373.15] K bound check (which never runs on this failure
        // path at all, since strict_accept/practical_accept are both
        // false). Dump the candidate's own temperature range to
        // distinguish these.
        var min_temperature_k: f64 = std.math.inf(f64);
        var max_temperature_k: f64 = -std.math.inf(f64);
        for (current) |value| {
            if (value < min_temperature_k) min_temperature_k = value;
            if (value > max_temperature_k) max_temperature_k = value;
        }
        std.log.err("soil heat Newton-Raphson/Anderson did not converge candidate range: min_temperature_k={e} max_temperature_k={e}", .{ min_temperature_k, max_temperature_k });
        const terminal_reason_name = switch (terminal_reason) {
            .iteration_limit => "iteration_limit",
            .stagnated => "stagnated",
            .diverged => "diverged",
        };
        logWorstConservationComponent(
            terminal_reason_name,
            properties,
            base,
            current,
            residual,
        );
        if (terminal_reason == .stagnated) logDirectConstitutiveRecoveryProbe(
            faces,
            properties,
            water_fluxes,
            base,
            current,
            target,
            residual,
            scratch,
            candidate,
            candidate_residual,
            accelerated_residual,
            trial_flux,
            phase_buffers,
            options,
        );
        logWorstConservationAdjacentProbe(
            faces,
            properties,
            water_fluxes,
            base,
            current,
            target,
            residual,
            scratch,
            candidate,
            candidate_residual,
            accelerated_residual,
            trial_flux,
            phase_buffers,
            options,
            enthalpy_endpoint_mask,
        );
    }
    if (options.failure_report_io) |io| {
        @import("failure_snapshot.zig").report(io, workspace.allocator, .{
            .grid = grid.*,
            .faces = faces,
            .properties = properties,
            .water_fluxes = water_fluxes,
            .options = options,
        }) catch |report_error| std.log.warn("heat failure snapshot could not be written: {s}", .{@errorName(report_error)});
    }
    return switch (terminal_reason) {
        .iteration_limit => error.SoilHeatSolverDidNotConverge,
        .stagnated => error.SoilHeatSolverStagnated,
        .diverged => error.SoilHeatSolverDiverged,
    };
}

pub fn solveAndBindTransportFaces(allocator: std.mem.Allocator, grid: *grid_module.GridState, hydrology: *transport_hydrology.State, shared_faces: *transport_hydrology.SoilFaces, geometry: group_types.FaceGeometry, properties: group_types.Properties, options: group_types.Options) !group_types.Result {
    const count = shared_faces.micropore_faces.len;
    var workspace = try group_types.Workspace.init(
        allocator,
        grid.layer_count,
        count,
        options.dense_newton_max_components,
    );
    defer workspace.deinit();
    return solveAndBindTransportFacesWithWorkspace(
        &workspace,
        grid,
        hydrology,
        shared_faces,
        geometry,
        properties,
        options,
    );
}

pub fn solveAndBindTransportFacesWithWorkspace(
    workspace: *group_types.Workspace,
    grid: *grid_module.GridState,
    hydrology: *transport_hydrology.State,
    shared_faces: *transport_hydrology.SoilFaces,
    geometry: group_types.FaceGeometry,
    properties: group_types.Properties,
    options: group_types.Options,
) !group_types.Result {
    const count = shared_faces.micropore_faces.len;
    if (shared_faces.macropore_faces.len != count or shared_faces.micropore_water_flux_m3_per_step.len != count or shared_faces.macropore_water_flux_m3_per_step.len != count or shared_faces.vapor_flux_m3_per_step.len != count or shared_faces.heat_flux_megajoules_per_step.len != count or geometry.source_path_length_m.len != count or geometry.destination_path_length_m.len != count or geometry.face_area_m2.len != count) return error.SoilHeatFaceGeometryDimensionMismatch;
    if (workspace.face_count != count)
        return error.SoilHeatWorkspaceDimensionMismatch;
    const faces = workspace.face_buffer;
    for (faces, 0..) |*face, index| face.* = .{ .active = shared_faces.active_by_face[index], .source_cell = shared_faces.micropore_faces[index].first_cell, .destination_cell = shared_faces.micropore_faces[index].second_cell, .source_path_length_m = geometry.source_path_length_m[index], .destination_path_length_m = geometry.destination_path_length_m[index], .face_area_m2 = geometry.face_area_m2[index] };
    var active_properties = properties;
    active_properties.active_by_layer = shared_faces.active_by_layer;
    const result = try solveWithWorkspace(workspace, grid, faces, active_properties, .{ .liquid_water_m3 = shared_faces.micropore_water_flux_m3_per_step, .vapor_m3 = shared_faces.vapor_flux_m3_per_step, .macropore_water_m3 = shared_faces.macropore_water_flux_m3_per_step }, shared_faces.heat_flux_megajoules_per_step, options);
    @memset(hydrology.heat_face_flux_megajoules_per_step, 0);
    for (faces, shared_faces.direction_axis, shared_faces.heat_flux_megajoules_per_step) |face, axis, flux| hydrology.heat_face_flux_megajoules_per_step[face.source_cell * 3 + axis] = if (face.active) flux else 0;
    const coupling = active_properties.enthalpy_coupling;
    _ = try group_boundary.acceptedBoundaryHeatByLayer(
        active_properties,
        grid.soil_temperature_k,
        .{
            .matrix_liquid_m3 = grid.matrix_liquid_water_m3,
            .matrix_ice_m3 = grid.matrix_ice_water_m3,
            .macropore_liquid_m3 = grid.macropore_liquid_water_m3,
            .macropore_ice_m3 = grid.macropore_ice_water_m3,
            .macropore_enabled = coupling != null and coupling.?.macropore_liquid_water_m3.len == grid.layer_count,
            .ice_density_megagrams_per_m3 = if (coupling) |value| value.ice_density_megagrams_per_m3 else 1,
        },
        hydrology.boundary_heat_exchange_megajoules_per_layer_per_step,
    );
    try hydrology.validateFinite();
    return result;
}

