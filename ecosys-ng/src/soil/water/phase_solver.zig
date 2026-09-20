const std = @import("std");
const builtin = @import("builtin");
const grid_module = @import("../../state/grid.zig");
const phase = @import("phase_change.zig");
const numerics = @import("../../core/numerics.zig");
const retention = @import("retention.zig");
const ice_units = @import("../../core/ice_units.zig");
const scoped_conservation = @import("../../validation/scoped_conservation.zig");
const heat_solver = @import("../heat/solver.zig");

pub const Properties = struct {
    /// Runtime DLYRM mask. Empty preserves standalone all-layer behavior.
    active_by_layer: []const bool = &.{},
    matrix_bulk_volume_m3: []const f64,
    retention_curve: []const retention.ResolvedCurve,
    mualem_van_genuchten_parameters: []const retention.MualemVanGenuchtenParameters = &.{},
    macropore_mualem_van_genuchten_parameters: []const retention.MualemVanGenuchtenParameters = &.{},
    osmotic_potential_megapascal: []const f64,
    saturation_water_potential_megapascal: []const f64,
    heat_capacity_megajoules_per_k: []const f64,
    saturated_lateral_matrix_conductivity_m2_per_h_megapascal: []const f64,
    face_area_m2: []const f64,
    macropore_spacing_m: []const f64,
    macropore_radius_m: []const f64,
    pore_exchange_enabled: []const bool,
    /// Per-layer ground area for the independent phase-energy acceptance
    /// gate. Empty preserves standalone solver use without conservation
    /// policy; production always binds the runtime balance area.
    conservation_cell_area_m2: []const f64 = &.{},
    /// Number of flattened soil layers belonging to one horizontal cell.
    /// The cell's fixed absolute phase-energy budget is shared equally among
    /// its active layers; inactive DLYRM layers neither consume nor receive a
    /// share. Zero preserves the former standalone behavior in which every
    /// flattened entry has its own budget; production always binds the grid
    /// layer capacity explicitly.
    conservation_layer_capacity: usize = 0,
    /// Source-order WATSUB vapor and local VOLW/VOLI, VOLWH/VOLIH phase
    /// changes. The spatial heat solve may subsequently repartition phase at
    /// its transported endpoint temperature; both operations conserve the
    /// enthalpy of their accepted endpoints and latent heat is internal.
    vapor: phase.VaporEquilibriumParameters,
    freeze_thaw: phase.FreezeThawParameters,
    gravitational_water_potential_mpa_per_m: f64 = 0.0098,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    /// Ice sensible-heat coefficient per cubic metre water equivalent. The
    /// production boundary converts WATSUB's physical-volume coefficient.
    ice_heat_capacity_megajoules_per_m3_k: f64,
    /// Physical duration for rate-limited matrix/macropore exchange. Phase
    /// equilibrium and latent-heat closure remain algebraic at every substep.
    time_step_hours: f64 = 1,
};

fn iceWaterEquivalentFactor(properties: Properties) f64 {
    _ = properties;
    return 1.0;
}

pub const Options = struct {
    max_iterations: u16,
    absolute_tolerance_m3: f64 = 1e-14,
    absolute_temperature_tolerance_k: f64 = 1e-10,
    relative_tolerance: f64 = 1e-9,
    energy_conservation_absolute_tolerance_megajoules_per_m2: f64 = 0,
    energy_conservation_relative_tolerance: f64 = 1e-9,
    picard_relaxation: f64 = 0.5,
    directional_probe_fraction: f64 = 0.5,
    minimum_newton_fraction: f64 = 0.05,
    maximum_newton_fraction: f64 = 1.0,
    /// Divergence watch, mirroring `core/numerics.zig` and the vector-valued
    /// snow transport solver. This system is vector-valued over six components
    /// per cell, so it cannot delegate to the shared scalar solver and needs its
    /// own detector. Consecutive iterations whose scaled norm exceeds
    /// `divergence_growth_factor` times the best norm seen are counted; past
    /// `divergence_patience` of them the solve is diverging.
    ///
    /// Every step this solver accepts is required to strictly decrease the
    /// scaled norm, so with the current acceptance rules the counted condition
    /// cannot arise: the watch is a guard that keeps a future non-monotone step
    /// (a trust-region or over-relaxed acceleration, say) from silently burning
    /// the whole iteration ceiling. `ResidualWatch.observe` is therefore tested
    /// directly rather than through a contrived diverging solve.
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    /// Oscillation watch. Monotone norm decrease does not imply progress: at a
    /// semismooth phase or pore-capacity switch the fallback cascade can accept
    /// a sequence of alternating coordinate steps that return the iterate to
    /// where it was two recovery iterations earlier while removing almost none
    /// of the residual. That two-cycle is the shape of the Ottawa hour-12
    /// `SoilPhaseSolverStagnated` history, and the existing stagnation exit
    /// cannot see it because a step is still being accepted every iteration.
    ///
    /// An iteration counts as oscillating when the iterate has returned to
    /// within eps-scaled distance of the iterate two recovery iterations back
    /// AND the scaled norm has improved on the best seen by less than
    /// `oscillation_improvement_factor`. Both conditions are required so a slow
    /// but genuinely converging solve is never cut off.
    oscillation_patience: u16 = 4,
    oscillation_improvement_factor: f64 = 0.999,
    /// Anderson-accelerated Picard recovery over the remembered recovery
    /// iterates, depth two then depth one, as in the conserved soil water
    /// system in `solver_solve.zig`.
    ///
    /// This is a measurement control, not a tuning knob: the recovery is only
    /// ever consulted where the solver would otherwise report stagnation, and
    /// an accelerated candidate is accepted only if it strictly decreases the
    /// same scaled norm every other accepted step must decrease. Disabling it
    /// must therefore change the path taken and never the fixed point.
    ///
    /// Compatibility field only. Production validation rejects false because
    /// an unaccelerated fixed-point fallback is not permitted.
    anderson_recovery_enabled: bool = true,
    /// issue-068 (numerical-analysis round, 2026-09-20): per-iteration global
    /// scaled-residual trace, mirroring `vapor_solver.Options.diagnostic_trace_layer_index`'s
    /// established convention exactly (a call-site-gated, no-cost-when-null
    /// diagnostic; `null` in every production/test call except the one narrow
    /// hour window this issue's chain already gates its siblings to). The
    /// index value itself is not read for indexing here -- this solve's own
    /// `norm` is already a single global scaled-residual scalar over the
    /// whole state vector, not a per-component value -- it is reused purely
    /// as the identical enable/disable gate and log tag every sibling solver
    /// already uses, so a future reader does not have to learn a second
    /// convention. See `logIterationDiagnosticTrace`.
    diagnostic_trace_layer_index: ?usize = null,
};

/// Divergence and oscillation watch over the sequence of scaled residual norms.
///
/// Kept as a separate value with a pure `observe` so the detector's logic is
/// testable without constructing a solve that has to diverge on demand.
const ResidualWatch = struct {
    best_norm: f64 = std.math.inf(f64),
    non_improving_steps: u16 = 0,
    oscillating_steps: u16 = 0,

    const Verdict = enum { progressing, diverged, oscillating };

    fn observe(self: *ResidualWatch, norm: f64, repeats_earlier_iterate: bool, options: Options) Verdict {
        const improved_materially = norm < options.oscillation_improvement_factor * self.best_norm;
        if (repeats_earlier_iterate and !improved_materially) {
            self.oscillating_steps += 1;
        } else {
            self.oscillating_steps = 0;
        }
        if (norm < self.best_norm) {
            self.best_norm = norm;
            self.non_improving_steps = 0;
        } else if (norm > options.divergence_growth_factor * self.best_norm) {
            self.non_improving_steps += 1;
            if (self.non_improving_steps >= options.divergence_patience) return .diverged;
        } else {
            self.non_improving_steps = 0;
        }
        if (self.oscillating_steps >= options.oscillation_patience) return .oscillating;
        return .progressing;
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

/// Uses only accepted Newton merits to ask whether their measured logarithmic
/// contraction can reach the unchanged `norm <= 1` gate before the hard
/// iteration ceiling. Recovery is priced only while one Anderson update and
/// its mandatory Newton retry still fit; it never relaxes either gate.
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

pub const DisplacementOutputs = struct {
    /// Water-equivalent carriers expelled from a rigid pore domain by the
    /// physical-volume expansion of newly formed ice. WATSUB routes these
    /// upward through FLWL/FLWHL; this solver only produces the transactional
    /// sidecar and must not silently choose the receiving surface domain.
    matrix_liquid_water_m3: []f64,
    matrix_ice_water_equivalent_m3: []f64,
    macropore_liquid_water_m3: []f64,
    macropore_ice_water_equivalent_m3: []f64,
    advective_enthalpy_megajoules: []f64,
};

pub const Outputs = struct {
    latent_heat_megajoules: []f64,
    macropore_to_matrix_water_m3: []f64,
    /// Required whenever freezing produces physical pore overfill. Production
    /// currently leaves this unbound and therefore fails closed rather than
    /// suppressing source-order freezing or losing the displaced carrier.
    displacement: ?DisplacementOutputs = null,
};

pub const Result = struct { iterations: u16, newton_raphson_steps: u16, picard_steps: u16, maximum_scaled_residual: f64, anderson_recovery_steps: u16 = 0 };

const PhaseEnergyConservationScope = enum { layer, horizontal_cell };

/// Fixed-size record of the first scope that rejected one phase endpoint.
/// Keeping only the most recent rejected endpoint avoids allocating diagnostic
/// history and, more importantly, avoids formatting a warning on every
/// nonlinear iterate. A failed solve emits this record once from its terminal
/// error path.
const PhaseEnergyConservationDiagnostic = struct {
    scope: PhaseEnergyConservationScope = .layer,
    layer_cell: usize,
    residual_megajoules: f64,
    normalized_relative: f64,
    physical_limit_megajoules: f64,
    arithmetic_allowance_megajoules: f64,
    effective_limit_megajoules: f64,
};

const PhaseEnergyConservationCheck = struct {
    accepted: bool,
    diagnostic: ?PhaseEnergyConservationDiagnostic = null,
};

fn emitPhaseEnergyConservationDiagnostic(diagnostic: ?PhaseEnergyConservationDiagnostic) void {
    if (builtin.is_test) return;
    const rejected = diagnostic orelse return;
    std.log.warn(
        "last rejected soil phase endpoint at final solve failure: scope={s} layer_cell={d} residual_mj={e} normalized_relative={e} physical_limit_mj={e} arithmetic_mj={e} effective_limit_mj={e}",
        .{
            @tagName(rejected.scope),
            rejected.layer_cell,
            rejected.residual_megajoules,
            rejected.normalized_relative,
            rejected.physical_limit_megajoules,
            rejected.arithmetic_allowance_megajoules,
            rejected.effective_limit_megajoules,
        },
    );
}

const independent_components_per_cell: usize = 5;

const ReducedBlockColumnProbeContext = struct {
    grid: *const grid_module.GridState,
    properties: Properties,
    base: []const f64,
    current: []const f64,
    target: []f64,
    residual: []const f64,
    probe: []f64,
    probe_residual: []f64,
    scratch: []f64,
    trial_heat: []f64,
    trial_exchange: []f64,
    trial_displacement: DisplacementOutputs,
    block_jacobian: []f64,
    block_coordinate_fixed: []bool,
    probe_step: []f64,
    last_probe_error: *?anyerror,
};

const MethodEvent = enum { newton_attempt, anderson_accept };

const TestControl = struct {
    forced_initial_newton_failures: u16 = 0,
    events: [8]MethodEvent = undefined,
    event_count: usize = 0,

    fn record(self: *TestControl, event: MethodEvent) void {
        if (self.event_count < self.events.len) {
            self.events[self.event_count] = event;
            self.event_count += 1;
        }
    }
};

/// Two consecutive iterates count as the same point when every component agrees
/// to this many ULP. The tolerance has to be wider than one ULP because the
/// fallback cascade reaches a repeated point through different arithmetic than
/// the one that first produced it, and narrower than the convergence tolerance
/// so a genuinely advancing solve is never called a cycle.
const iterate_repeat_ulp: f64 = 1024;

fn iteratesCoincide(state: []const f64, earlier: []const f64) bool {
    for (state, earlier) |value, earlier_value| {
        const tolerance = iterate_repeat_ulp * std.math.floatEps(f64) * @max(1.0, @abs(value));
        if (!(@abs(value - earlier_value) <= tolerance)) return false;
    }
    return true;
}

/// Shifts one (state, residual) pair into the depth-two recovery history, in the
/// same shape as the conserved soil water system's `rememberIteration`.
fn rememberIteration(current: []const f64, residual: []const f64, previous_state: []f64, previous_residual: []f64, previous_previous_state: []f64, previous_previous_residual: []f64, history_count: *u8) void {
    if (history_count.* > 0) {
        @memcpy(previous_previous_state, previous_state);
        @memcpy(previous_previous_residual, previous_residual);
    }
    @memcpy(previous_state, current);
    @memcpy(previous_residual, residual);
    history_count.* = @min(@as(u8, 2), history_count.* + 1);
}

/// Everything the accelerated recovery needs to evaluate one trial residual.
/// Bundled so the recovery reads as one decision instead of another dozen
/// parameters threaded through the iteration body.
const RecoveryContext = struct {
    grid: *grid_module.GridState,
    properties: Properties,
    base: []const f64,
    target: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    scratch: []f64,
    trial_heat: []f64,
    trial_exchange: []f64,
    trial_displacement: DisplacementOutputs,
    options: Options,

    /// Accepts the assembled `candidate` only when it is representable, keeps
    /// every volume non-negative and the endpoint temperature positive, and
    /// strictly decreases the same scaled norm every other accepted step must
    /// decrease. That last condition is what makes the recovery unable to move
    /// the fixed point: it can only shorten the path to one.
    fn accept(self: RecoveryContext, current: []f64, cells: usize, norm: f64) bool {
        if (!representablePhaseState(self.candidate, cells)) return false;
        residualAt(self.grid, self.properties, self.base, self.candidate, self.target, self.candidate_residual, self.scratch, self.trial_heat, self.trial_exchange, self.trial_displacement) catch return false;
        const candidate_norm = scaledNorm(self.base, self.candidate, self.candidate_residual, self.options) catch return false;
        if (!(candidate_norm < norm)) return false;
        @memcpy(current, self.candidate);
        return true;
    }
};

fn representablePhaseState(state: []const f64, cells: usize) bool {
    if (state.len != 6 * cells) return false;
    for (state, 0..) |value, index| {
        if (!std.math.isFinite(value)) return false;
        if (index >= 5 * cells) {
            if (value <= 0) return false;
        } else if (value < 0) return false;
    }
    return true;
}

test "Anderson candidate admission rejects finite negative phase state" {
    var state = [_]f64{ 1, 0, 0, 0, 0, 273.15 };
    try std.testing.expect(representablePhaseState(&state, 1));
    state[3] = -std.math.floatEps(f64);
    try std.testing.expect(!representablePhaseState(&state, 1));
    state[3] = 0;
    state[5] = 0;
    try std.testing.expect(!representablePhaseState(&state, 1));
}

/// Anderson-accelerated Picard recovery: depth two when two prior recovery
/// iterates are remembered, then depth one. The mixing coefficients minimise
/// the norm of the affine combination of remembered residuals, and the
/// candidate is the same combination of the corresponding fixed-point images
/// `state + residual`, which is exactly the Picard map of this system.
fn attemptAndersonRecovery(
    context: RecoveryContext,
    cells: usize,
    current: []f64,
    residual: []const f64,
    previous_state: []const f64,
    previous_residual: []const f64,
    previous_previous_state: []const f64,
    previous_previous_residual: []const f64,
    history_count: u8,
    norm: f64,
) bool {
    if (history_count > 1) {
        var gram_00: f64 = 0;
        var gram_01: f64 = 0;
        var gram_11: f64 = 0;
        var rhs_0: f64 = 0;
        var rhs_1: f64 = 0;
        for (residual, previous_residual, previous_previous_residual) |value, previous_value, older_value| {
            const difference_0 = value - previous_value;
            const difference_1 = previous_value - older_value;
            gram_00 += difference_0 * difference_0;
            gram_01 += difference_0 * difference_1;
            gram_11 += difference_1 * difference_1;
            rhs_0 += difference_0 * value;
            rhs_1 += difference_1 * value;
        }
        const determinant = gram_00 * gram_11 - gram_01 * gram_01;
        if (std.math.isFinite(determinant) and @abs(determinant) > std.math.floatEps(f64) * @max(1.0, gram_00 * gram_11)) {
            const mixing_0 = (rhs_0 * gram_11 - rhs_1 * gram_01) / determinant;
            const mixing_1 = (gram_00 * rhs_1 - gram_01 * rhs_0) / determinant;
            if (std.math.isFinite(mixing_0) and std.math.isFinite(mixing_1)) {
                for (current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, context.candidate) |value, value_residual, old_value, old_residual, older_value, older_residual, *next| {
                    const fixed_point = value + value_residual;
                    const old_fixed_point = old_value + old_residual;
                    const older_fixed_point = older_value + older_residual;
                    next.* = fixed_point - mixing_0 * (fixed_point - old_fixed_point) - mixing_1 * (old_fixed_point - older_fixed_point);
                }
                if (context.accept(current, cells, norm)) return true;
            }
        }
    }
    var numerator: f64 = 0;
    var denominator: f64 = 0;
    for (residual, previous_residual) |value, previous_value| {
        const change = value - previous_value;
        numerator += value * change;
        denominator += change * change;
    }
    if (!std.math.isFinite(denominator) or denominator <= std.math.floatEps(f64)) return false;
    const mixing = numerator / denominator;
    if (!std.math.isFinite(mixing)) return false;
    for (current, residual, previous_state, previous_residual, context.candidate) |value, value_residual, old_value, old_residual, *next| {
        const fixed_point = value + value_residual;
        const old_fixed_point = old_value + old_residual;
        next.* = fixed_point - mixing * (fixed_point - old_fixed_point);
    }
    return context.accept(current, cells, norm);
}

/// Simultaneously converges VOLW/VOLV/VOLI, VOLWH/VOLIH, and the cell-local
/// endpoint enthalpy temperature for every runtime cell. NPH is a maximum
/// iteration count, never a repeated model cycle.
pub fn solve(allocator: std.mem.Allocator, grid: *grid_module.GridState, properties: Properties, outputs: Outputs, options: Options) !Result {
    var control: TestControl = .{};
    return solveControlled(allocator, grid, properties, outputs, options, &control);
}

noinline fn solveControlled(allocator: std.mem.Allocator, grid: *grid_module.GridState, properties: Properties, outputs: Outputs, options: Options, control: *TestControl) !Result {
    var last_phase_energy_diagnostic: ?PhaseEnergyConservationDiagnostic = null;
    return solveControlledImpl(
        allocator,
        grid,
        properties,
        outputs,
        options,
        control,
        &last_phase_energy_diagnostic,
    ) catch |err| {
        emitPhaseEnergyConservationDiagnostic(last_phase_energy_diagnostic);
        return err;
    };
}

noinline fn solveControlledImpl(
    allocator: std.mem.Allocator,
    grid: *grid_module.GridState,
    properties: Properties,
    outputs: Outputs,
    options: Options,
    control: *TestControl,
    last_phase_energy_diagnostic: *?PhaseEnergyConservationDiagnostic,
) !Result {
    try validateInputs(grid, properties, outputs, options);
    const cells = grid.layer_count;
    const components_per_cell: usize = 6;
    const components = try std.math.mul(usize, cells, components_per_cell);
    const base = try allocator.alloc(f64, components);
    defer allocator.free(base);
    @memcpy(base[0 * cells .. 1 * cells], grid.matrix_liquid_water_m3);
    @memcpy(base[1 * cells .. 2 * cells], grid.water_vapor_volume_m3);
    @memcpy(base[2 * cells .. 3 * cells], grid.matrix_ice_water_m3);
    @memcpy(base[3 * cells .. 4 * cells], grid.macropore_liquid_water_m3);
    @memcpy(base[4 * cells .. 5 * cells], grid.macropore_ice_water_m3);
    @memcpy(base[5 * cells .. 6 * cells], grid.soil_temperature_k);
    const current = try allocator.dupe(f64, base);
    defer allocator.free(current);
    const residual = try allocator.alloc(f64, components);
    defer allocator.free(residual);
    const target = try allocator.alloc(f64, components);
    defer allocator.free(target);
    const scratch = try allocator.alloc(f64, components);
    defer allocator.free(scratch);
    const trial_heat = try allocator.alloc(f64, cells);
    defer allocator.free(trial_heat);
    const trial_exchange = try allocator.alloc(f64, cells);
    defer allocator.free(trial_exchange);
    const trial_displacement_storage = try allocator.alloc(f64, try std.math.mul(usize, cells, 5));
    defer allocator.free(trial_displacement_storage);
    const trial_displacement: DisplacementOutputs = .{
        .matrix_liquid_water_m3 = trial_displacement_storage[0 * cells .. 1 * cells],
        .matrix_ice_water_equivalent_m3 = trial_displacement_storage[1 * cells .. 2 * cells],
        .macropore_liquid_water_m3 = trial_displacement_storage[2 * cells .. 3 * cells],
        .macropore_ice_water_equivalent_m3 = trial_displacement_storage[3 * cells .. 4 * cells],
        .advective_enthalpy_megajoules = trial_displacement_storage[4 * cells .. 5 * cells],
    };
    const probe = try allocator.alloc(f64, components);
    defer allocator.free(probe);
    const probe_residual = try allocator.alloc(f64, components);
    defer allocator.free(probe_residual);
    const candidate = try allocator.alloc(f64, components);
    defer allocator.free(candidate);
    const candidate_residual = try allocator.alloc(f64, components);
    defer allocator.free(candidate_residual);
    // Recovery history. It is fed only by iterations that reached the fallback
    // cascade, because an iteration whose Newton step was accepted continues
    // before the history is shifted. The remembered pairs are therefore
    // consecutive *recovery* iterates, which is what the Anderson mixing
    // extrapolates and what the oscillation test compares against; mixing in an
    // intervening Newton step would describe a different sequence.
    const previous_state = try allocator.alloc(f64, components);
    defer allocator.free(previous_state);
    const previous_residual = try allocator.alloc(f64, components);
    defer allocator.free(previous_residual);
    const previous_previous_state = try allocator.alloc(f64, components);
    defer allocator.free(previous_previous_state);
    const previous_previous_residual = try allocator.alloc(f64, components);
    defer allocator.free(previous_previous_residual);
    // The pre-step iterate of the current iteration. `current` is overwritten in
    // place by whichever fallback is accepted, so the history has to be fed from
    // a snapshot taken while `current` and `residual` still correspond.
    const recovery_state = try allocator.alloc(f64, components);
    defer allocator.free(recovery_state);
    var history_count: u8 = 0;
    var anderson_recovery_steps: u16 = 0;
    var watch: ResidualWatch = .{};
    const block_jacobian = try allocator.alloc(f64, try std.math.mul(usize, cells, independent_components_per_cell * independent_components_per_cell));
    defer allocator.free(block_jacobian);
    const block_right_hand_side = try allocator.alloc(f64, try std.math.mul(usize, cells, independent_components_per_cell));
    defer allocator.free(block_right_hand_side);
    const block_delta = try allocator.alloc(f64, components);
    defer allocator.free(block_delta);
    const probe_step = try allocator.alloc(f64, cells);
    defer allocator.free(probe_step);
    const block_coordinate_fixed = try allocator.alloc(bool, try std.math.mul(usize, cells, independent_components_per_cell));
    defer allocator.free(block_coordinate_fixed);
    @memset(block_coordinate_fixed, false);
    var newton_steps: u16 = 0;
    var directional_newton_steps: u16 = 0;
    var reduced_block_newton_steps: u16 = 0;
    var diagonal_newton_steps: u16 = 0;
    var reduced_block_invalid_iterations: u16 = 0;
    var reduced_block_rejected_iterations: u16 = 0;
    var last_reduced_block_probe_error: ?anyerror = null;
    var picard_steps: u16 = 0;
    var previous_norm = std.math.inf(f64);
    var insufficient_progress_steps: u16 = 0;
    var newton_retry_required = false;
    var slow_newton_norm_history: [slow_newton_progress_history_length]f64 = undefined;
    var slow_newton_norm_count: u8 = 0;
    var slow_newton_last_recorded_step: u16 = 0;
    var rejected_forecast_recovery_step: ?u16 = null;
    var iteration: u16 = 0;
    while (iteration < options.max_iterations) : (iteration += 1) {
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        try residualAt(grid, properties, base, current, target, residual, scratch, trial_heat, trial_exchange, trial_displacement);
        const norm = try scaledNorm(base, current, residual, options);
        // Only accepted Newton promotions extend the contraction history.
        // Anderson states reset it, while a rejected speculative recovery is
        // not repriced until Newton has changed the trajectory.
        const accepted_newton_since_forecast = slow_newton_norm_count != 0 and
            newton_steps != slow_newton_last_recorded_step;
        if (slow_newton_norm_count == 0 or accepted_newton_since_forecast) {
            rememberNewtonNorm(
                &slow_newton_norm_history,
                &slow_newton_norm_count,
                norm,
            );
            slow_newton_last_recorded_step = newton_steps;
        }
        var phase_energy_accepted = false;
        const norm_admissible_and_not_retrying = !retrying_newton_after_anderson and norm <= 1;
        const committable = norm_admissible_and_not_retrying and
            committableState(grid, current, properties.freeze_thaw.ice_density_megagrams_per_m3);
        // issue-068 (seventh-round follow-up): only characterize the exact
        // window this round is asking about -- the residual is already
        // admissible but the aggregate acceptance gate is not -- so this
        // never fires for an ordinary committable iteration or hour.
        if (norm_admissible_and_not_retrying and !committable) {
            logCommittableStateDiagnosticIfGated(options, iteration, grid, current, properties.freeze_thaw.ice_density_megagrams_per_m3);
        }
        if (committable) {
            const check = try evaluatePhaseEnergyConservation(base, current, trial_displacement, properties, options);
            phase_energy_accepted = check.accepted;
            if (check.diagnostic) |diagnostic| last_phase_energy_diagnostic.* = diagnostic;
        }
        logIterationDiagnosticTrace(options, iteration, norm, committable, phase_energy_accepted);
        if (phase_energy_accepted) {
            try residualAt(grid, properties, base, current, target, residual, scratch, trial_heat, trial_exchange, trial_displacement);
            // Publish the iterate whose F(x)-x residual was actually accepted.
            // `target` is a fresh fixed-point image and has not itself passed a
            // residual check; committing it here would be a vanilla Picard
            // correction after Newton/Anderson convergence.
            try acceptedLatentHeat(base, current, properties, trial_heat);
            try requireDisplacementBinding(outputs.displacement, trial_displacement);
            try state_update(grid, current, properties.freeze_thaw.ice_density_megagrams_per_m3);
            copyDisplacement(outputs.displacement, trial_displacement);
            @memcpy(outputs.latent_heat_megajoules, trial_heat);
            @memcpy(outputs.macropore_to_matrix_water_m3, trial_exchange);
            return .{ .iterations = iteration + 1, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .maximum_scaled_residual = norm, .anderson_recovery_steps = anderson_recovery_steps };
        }
        // Watch before stepping, while `current` and `residual` still describe
        // the same point. The oscillation test asks whether this iterate is the
        // one from two iterations ago; the divergence test only looks at norms.
        const repeats_earlier_iterate = history_count > 1 and iteratesCoincide(current, previous_previous_state);
        var progress_requires_anderson = false;
        switch (watch.observe(norm, repeats_earlier_iterate, options)) {
            .progressing => {},
            .diverged => {
                if (!builtin.is_test) std.log.err("soil phase-enthalpy solve diverging: iteration={d} scaled_residual={e} best_scaled_residual={e} growth_factor={e} patience={d}", .{ iteration + 1, norm, watch.best_norm, options.divergence_growth_factor, options.divergence_patience });
                return error.SoilPhaseSolverDiverged;
            },
            .oscillating => {
                progress_requires_anderson = true;
            },
        }
        const progress_floor = std.math.sqrt(std.math.floatEps(f64)) * @max(1.0, previous_norm);
        if (std.math.isFinite(previous_norm) and previous_norm - norm <= progress_floor)
            insufficient_progress_steps +|= 1
        else
            insufficient_progress_steps = 0;
        previous_norm = norm;
        const stagnation_requires_anderson = progress_requires_anderson or
            insufficient_progress_steps >= options.oscillation_patience;
        const remaining_updates = options.max_iterations - iteration;
        const forecast_requires_anderson = !retrying_newton_after_anderson and
            rejected_forecast_recovery_step != newton_steps and
            remaining_updates >= 2 and
            remaining_updates <= slow_newton_recovery_reserve and
            slow_newton_norm_count == slow_newton_progress_history_length and
            slowNewtonProgressNeedsRecovery(
                slow_newton_norm_history[0],
                slow_newton_norm_history[slow_newton_progress_history_length - 1],
                slow_newton_progress_window_updates,
                remaining_updates,
            );
        progress_requires_anderson =
            stagnation_requires_anderson or forecast_requires_anderson;
        // The pre-step iterate paired with the residual just evaluated at it.
        // Every fallback below overwrites `current` in place, so the history has
        // to be fed from this copy rather than from `current`.
        @memcpy(recovery_state, current);
        newton_primary: {
            if (progress_requires_anderson and !retrying_newton_after_anderson) break :newton_primary;
            control.record(.newton_attempt);
            if (control.forced_initial_newton_failures > 0) {
                control.forced_initial_newton_failures -= 1;
                break :newton_primary;
            }
            var accepted_newton = false;
            if (addDirection(current, residual, options.directional_probe_fraction, probe)) |_| {
                if (residualAt(grid, properties, base, probe, target, probe_residual, scratch, trial_heat, trial_exchange, trial_displacement)) |_| {
                    var numerator: f64 = 0;
                    var denominator: f64 = 0;
                    for (residual, probe_residual) |base_residual, sampled_residual| {
                        const derivative = (sampled_residual - base_residual) / options.directional_probe_fraction;
                        numerator += base_residual * derivative;
                        denominator += derivative * derivative;
                    }
                    if (std.math.isFinite(denominator) and denominator > std.math.floatEps(f64)) {
                        const fraction = std.math.clamp(-numerator / denominator, options.minimum_newton_fraction, options.maximum_newton_fraction);
                        if (addDirection(current, residual, fraction, candidate)) |_| {
                            if (residualAt(grid, properties, base, candidate, target, candidate_residual, scratch, trial_heat, trial_exchange, trial_displacement)) |_| {
                                // This inexpensive global residual-direction probe
                                // is only a predictor. Requiring material decrease
                                // prevents tiny improvements from starving the
                                // exact cell-local Newton block near convergence.
                                // A bounded residual-direction Newton step often
                                // removes 50-75% of a freeze/thaw residual. That is
                                // substantial progress within NPH; requiring 80%
                                // removal rejected the useful step and forced six
                                // geometric Picard halvings in the Arctic case.
                                if (try scaledNorm(base, candidate, candidate_residual, options) <= 0.5 * norm) {
                                    @memcpy(current, candidate);
                                    newton_steps += 1;
                                    directional_newton_steps += 1;
                                    accepted_newton = true;
                                }
                            } else |_| {}
                        } else |_| {}
                    }
                } else |_| {}
            } else |_| {}
            if (accepted_newton) continue;
            // Eliminate matrix liquid water from the Newton coordinates through
            // exact water-equivalent conservation. The independent coordinates
            // are vapor, matrix ice, macropore liquid, macropore ice, and endpoint
            // temperature; this removes the structural nullspace of the 6x6 block.
            var block_jacobian_valid = true;
            const independent_component = [_]usize{ 1, 2, 3, 4, 5 };
            @memset(block_coordinate_fixed, false);
            for (independent_component, 0..) |column_component, column| {
                @memcpy(probe, current);
                const conservation_coefficient: f64 = if (column_component >= 1 and column_component <= 4) 1.0 else 0.0;
                for (0..cells) |cell| {
                    const index = column_component * cells + cell;
                    const nominal = std.math.cbrt(std.math.floatEps(f64)) * @max(1e-6, @abs(current[index]));
                    probe_step[cell] = reducedBlockProbeStep(
                        grid,
                        current,
                        column_component,
                        cell,
                        nominal,
                        residual[index],
                        properties.freeze_thaw.ice_density_megagrams_per_m3,
                    );
                    if (!std.math.isFinite(probe_step[cell]) or @abs(probe_step[cell]) <= 1e-20) {
                        // This coordinate is fixed by simultaneous non-negativity
                        // and pore-capacity constraints in this cell. Leave the
                        // batched probe unchanged and install an identity column
                        // for this cell below instead of invalidating other cells.
                        probe_step[cell] = 0;
                        block_coordinate_fixed[cell * independent_components_per_cell + column] = true;
                        continue;
                    }
                    probe[index] += probe_step[cell];
                    probe[cell] -= conservation_coefficient * probe_step[cell];
                }
                var batched_probe_valid = true;
                var probe_attempt: u8 = 0;
                while (true) : (probe_attempt += 1) {
                    if (residualAt(grid, properties, base, probe, target, probe_residual, scratch, trial_heat, trial_exchange, trial_displacement)) |_| break else |err| {
                        last_reduced_block_probe_error = err;
                        if (probe_attempt >= 15) {
                            batched_probe_valid = false;
                            break;
                        }
                        @memcpy(probe, current);
                        for (0..cells) |cell| {
                            probe_step[cell] *= 0.5;
                            probe[column_component * cells + cell] += probe_step[cell];
                            probe[cell] -= conservation_coefficient * probe_step[cell];
                        }
                    }
                }
                if (!batched_probe_valid) {
                    // The residual map is cell-local. A near-zero carrier at an
                    // active bound in one layer must not discard valid Newton
                    // columns for every other layer. Recover this failed batch
                    // with independent one-sided probes, trying the other
                    // feasible side before declaring only that coordinate fixed.
                    recoverCellLocalReducedColumn(.{
                        .grid = grid,
                        .properties = properties,
                        .base = base,
                        .current = current,
                        .target = target,
                        .residual = residual,
                        .probe = probe,
                        .probe_residual = probe_residual,
                        .scratch = scratch,
                        .trial_heat = trial_heat,
                        .trial_exchange = trial_exchange,
                        .trial_displacement = trial_displacement,
                        .block_jacobian = block_jacobian,
                        .block_coordinate_fixed = block_coordinate_fixed,
                        .probe_step = probe_step,
                        .last_probe_error = &last_reduced_block_probe_error,
                    }, column_component, column);
                    continue;
                }
                for (0..cells) |cell| for (independent_component, 0..) |row_component, row| {
                    const residual_index = row_component * cells + cell;
                    block_jacobian[cell * independent_components_per_cell * independent_components_per_cell + row * independent_components_per_cell + column] = if (probe_step[cell] == 0) @as(f64, if (row == column) 1 else 0) else (probe_residual[residual_index] - residual[residual_index]) / probe_step[cell];
                };
            }
            if (block_jacobian_valid) {
                @memset(block_delta, 0);
                for (0..cells) |cell| {
                    const matrix = block_jacobian[cell * independent_components_per_cell * independent_components_per_cell ..][0 .. independent_components_per_cell * independent_components_per_cell];
                    const rhs = block_right_hand_side[cell * independent_components_per_cell ..][0..independent_components_per_cell];
                    for (independent_component, 0..) |component, row| rhs[row] = if (block_coordinate_fixed[cell * independent_components_per_cell + row]) 0 else -residual[component * cells + cell];
                    // A fixed coordinate is an active-bound unknown, not an
                    // identity *column*. Replace its equation with delta=0 so
                    // off-diagonal derivatives cannot move it indirectly.
                    for (0..independent_components_per_cell) |fixed_row| {
                        if (!block_coordinate_fixed[cell * independent_components_per_cell + fixed_row]) continue;
                        for (0..independent_components_per_cell) |column_index|
                            matrix[fixed_row * independent_components_per_cell + column_index] = 0;
                        matrix[fixed_row * independent_components_per_cell + fixed_row] = 1;
                        rhs[fixed_row] = 0;
                    }
                    for (0..independent_components_per_cell) |diagonal| {
                        const index = diagonal * independent_components_per_cell + diagonal;
                        matrix[index] += std.math.sqrt(std.math.floatEps(f64)) * @max(1.0, @abs(matrix[index]));
                    }
                    if (!numerics.solveDenseLinearSystem(matrix, rhs, independent_components_per_cell)) {
                        block_jacobian_valid = false;
                        break;
                    }
                    for (independent_component, 0..) |component, row| block_delta[component * cells + cell] = rhs[row];
                    const ice_water_equivalent_factor = iceWaterEquivalentFactor(properties);
                    block_delta[cell] = -(rhs[0] + ice_water_equivalent_factor * rhs[1] + rhs[2] + ice_water_equivalent_factor * rhs[3]);
                }
            }
            if (!block_jacobian_valid) reduced_block_invalid_iterations += 1;
            if (block_jacobian_valid) {
                var line_fraction: f64 = 1;
                var line: u8 = 0;
                while (line < 12) : (line += 1) {
                    addCellFeasibleBlockDirection(
                        grid,
                        current,
                        block_delta,
                        line_fraction,
                        properties.freeze_thaw.ice_density_megagrams_per_m3,
                        candidate,
                    ) catch {
                        line_fraction *= 0.5;
                        continue;
                    };
                    if (residualAt(grid, properties, base, candidate, target, candidate_residual, scratch, trial_heat, trial_exchange, trial_displacement)) |_| {
                        if (try scaledNorm(base, candidate, candidate_residual, options) < norm) {
                            @memcpy(current, candidate);
                            newton_steps += 1;
                            reduced_block_newton_steps += 1;
                            accepted_newton = true;
                            break;
                        }
                    } else |_| {}
                    line_fraction *= 0.5;
                }
                if (!accepted_newton) reduced_block_rejected_iterations += 1;
            }
            if (accepted_newton) continue;
            // Active-set switches can make the full block Jacobian singular even
            // though the limiting scalar equation has a well-defined one-sided
            // derivative. Try that semismooth diagonal Newton correction before
            // entering the Anderson-only recovery.
            const limiting_index = largestScaledResidualIndex(base, current, residual, options) catch unreachable;
            const limiting_diagonal_component = limiting_index / cells;
            diagonal_newton: {
                if (limiting_diagonal_component != 0 and limiting_diagonal_component != 5)
                    break :diagonal_newton;
                // Matrix liquid is normally reconstructed from exact internal
                // phase-water conservation in the reduced block. Rigid-pore
                // displacement is different: it is an explicitly accounted
                // transfer out of this local phase state, so its active-set
                // residual needs the same direct semismooth Newton correction
                // used for endpoint temperature. The residual evaluation still
                // owns the displacement science and the line search still
                // accepts only a lower full-system merit.
                const displacement_water = limiting_diagonal_component == 0;
                const limiting_diagonal_cell = limiting_index % cells;
                if (displacement_water) {
                    // Earlier Jacobian probes overwrite the transactional
                    // sidecar. Restore it at the actual iterate, then admit this
                    // open-system direction only on the displacement branch.
                    residualAt(grid, properties, base, current, target, residual, scratch, trial_heat, trial_exchange, trial_displacement) catch break :diagonal_newton;
                    if (!hasDisplacementAtCell(trial_displacement, limiting_diagonal_cell))
                        break :diagonal_newton;
                }
                @memcpy(probe, current);
                const diagonal_probe_step = std.math.cbrt(std.math.floatEps(f64)) * @max(1.0e-6, @abs(current[limiting_index]));
                probe[limiting_index] += diagonal_probe_step;
                if (residualAt(grid, properties, base, probe, target, probe_residual, scratch, trial_heat, trial_exchange, trial_displacement)) |_| {
                    if (displacement_water and !hasDisplacementAtCell(trial_displacement, limiting_diagonal_cell))
                        break :diagonal_newton;
                    var diagonal_derivative = (probe_residual[limiting_index] - residual[limiting_index]) / diagonal_probe_step;
                    // Temperature is smooth enough for a centered derivative.
                    // Displacement is an active-set map: retain the positive
                    // one-sided derivative so no probe crosses its kink.
                    if (!displacement_water) {
                        @memcpy(candidate, current);
                        candidate[limiting_index] -= diagonal_probe_step;
                        if (candidate[limiting_index] > 0) {
                            if (residualAt(grid, properties, base, candidate, target, candidate_residual, scratch, trial_heat, trial_exchange, trial_displacement)) |_| {
                                diagonal_derivative = (probe_residual[limiting_index] - candidate_residual[limiting_index]) / (2 * diagonal_probe_step);
                            } else |_| {}
                        }
                    }
                    if (std.math.isFinite(diagonal_derivative) and @abs(diagonal_derivative) > std.math.floatEps(f64)) {
                        const diagonal_delta = -residual[limiting_index] / diagonal_derivative;
                        var line_fraction: f64 = 1;
                        var line: u8 = 0;
                        while (line < 16) : (line += 1) {
                            @memcpy(candidate, current);
                            candidate[limiting_index] += line_fraction * diagonal_delta;
                            if (!std.math.isFinite(candidate[limiting_index]) or candidate[limiting_index] < 0) {
                                line_fraction *= 0.5;
                                continue;
                            }
                            if (residualAt(grid, properties, base, candidate, target, candidate_residual, scratch, trial_heat, trial_exchange, trial_displacement)) |_| {
                                if (displacement_water and !hasDisplacementAtCell(trial_displacement, limiting_diagonal_cell)) {
                                    line_fraction *= 0.5;
                                    continue;
                                }
                                if (try scaledNorm(base, candidate, candidate_residual, options) < norm) {
                                    @memcpy(current, candidate);
                                    newton_steps += 1;
                                    diagonal_newton_steps += 1;
                                    accepted_newton = true;
                                    break;
                                }
                            } else |_| {}
                            line_fraction *= 0.5;
                        }
                    }
                } else |_| {}
            }
            if (accepted_newton) continue;
            // A phase coordinate can be locally active even when the simultaneous
            // five-coordinate block crosses another cell's active-set boundary.
            // Probe only the limiting cell while eliminating matrix liquid through
            // exact water-equivalent conservation. This is a local semismooth
            // Newton direction, not another model timestep.
            const limiting_component = limiting_index / cells;
            const limiting_phase_cell = limiting_index % cells;
            if (limiting_component >= 1 and limiting_component <= 4) {
                const conservation_coefficient = switch (limiting_component) {
                    1, 3 => 1.0,
                    2, 4 => iceWaterEquivalentFactor(properties),
                    else => unreachable,
                };
                var local_probe_step = std.math.cbrt(std.math.floatEps(f64)) * @max(1.0e-6, @abs(current[limiting_index]));
                if (current[limiting_phase_cell] < conservation_coefficient * local_probe_step) local_probe_step = -@min(local_probe_step, 0.5 * current[limiting_index]);
                if (@abs(local_probe_step) > 1.0e-20) {
                    @memcpy(probe, current);
                    probe[limiting_index] += local_probe_step;
                    probe[limiting_phase_cell] -= conservation_coefficient * local_probe_step;
                    if (probe[limiting_index] >= 0 and probe[limiting_phase_cell] >= 0) {
                        if (residualAt(grid, properties, base, probe, target, probe_residual, scratch, trial_heat, trial_exchange, trial_displacement)) |_| {
                            const derivative = (probe_residual[limiting_index] - residual[limiting_index]) / local_probe_step;
                            if (std.math.isFinite(derivative) and @abs(derivative) > std.math.floatEps(f64)) {
                                const local_delta = -residual[limiting_index] / derivative;
                                var line_fraction: f64 = 1;
                                var line: u8 = 0;
                                while (line < 16) : (line += 1) {
                                    @memcpy(candidate, current);
                                    candidate[limiting_index] += line_fraction * local_delta;
                                    candidate[limiting_phase_cell] -= conservation_coefficient * line_fraction * local_delta;
                                    if (candidate[limiting_index] < 0 or candidate[limiting_phase_cell] < 0 or !std.math.isFinite(candidate[limiting_index]) or !std.math.isFinite(candidate[limiting_phase_cell])) {
                                        line_fraction *= 0.5;
                                        continue;
                                    }
                                    if (residualAt(grid, properties, base, candidate, target, candidate_residual, scratch, trial_heat, trial_exchange, trial_displacement)) |_| {
                                        if (try scaledNorm(base, candidate, candidate_residual, options) < norm) {
                                            @memcpy(current, candidate);
                                            newton_steps += 1;
                                            directional_newton_steps += 1;
                                            accepted_newton = true;
                                            break;
                                        }
                                    } else |_| {}
                                    line_fraction *= 0.5;
                                }
                            }
                        } else |_| {}
                    }
                }
            }
            if (accepted_newton) continue;
            // Last local fallback: jointly correct the limiting phase coordinate
            // and endpoint temperature in one cell. Eliminating matrix liquid
            // preserves water exactly, while the 2x2 block captures latent-heat
            // feedback that a scalar coordinate step cannot.
            local_phase_temperature: {
                var phase_index: usize = 0;
                var phase_scaled: f64 = -1;
                for (1..5) |component| for (0..cells) |cell| {
                    const index = component * cells + cell;
                    const scaled = scaledResidualAt(base, current, residual, options, index);
                    if (scaled > phase_scaled) {
                        phase_scaled = scaled;
                        phase_index = index;
                    }
                };
                const phase_component = phase_index / cells;
                const cell = phase_index % cells;
                const temperature_index = 5 * cells + cell;
                const conservation_coefficient = switch (phase_component) {
                    1, 3 => 1.0,
                    2, 4 => iceWaterEquivalentFactor(properties),
                    else => break :local_phase_temperature,
                };
                var phase_step = std.math.cbrt(std.math.floatEps(f64)) * @max(1.0e-6, @abs(current[phase_index]));
                if (current[cell] < conservation_coefficient * phase_step) phase_step = -@min(phase_step, 0.5 * current[phase_index]);
                if (@abs(phase_step) <= 1.0e-20) break :local_phase_temperature;
                @memcpy(probe, current);
                probe[phase_index] += phase_step;
                probe[cell] -= conservation_coefficient * phase_step;
                residualAt(grid, properties, base, probe, target, probe_residual, scratch, trial_heat, trial_exchange, trial_displacement) catch break :local_phase_temperature;
                const local_matrix = block_jacobian[0..4];
                const local_rhs = block_right_hand_side[0..2];
                local_matrix[0] = (probe_residual[phase_index] - residual[phase_index]) / phase_step;
                local_matrix[2] = (probe_residual[temperature_index] - residual[temperature_index]) / phase_step;
                const temperature_step = std.math.cbrt(std.math.floatEps(f64)) * @max(1.0, @abs(current[temperature_index]));
                @memcpy(probe, current);
                probe[temperature_index] += temperature_step;
                residualAt(grid, properties, base, probe, target, probe_residual, scratch, trial_heat, trial_exchange, trial_displacement) catch break :local_phase_temperature;
                local_matrix[1] = (probe_residual[phase_index] - residual[phase_index]) / temperature_step;
                local_matrix[3] = (probe_residual[temperature_index] - residual[temperature_index]) / temperature_step;
                local_rhs[0] = -residual[phase_index];
                local_rhs[1] = -residual[temperature_index];
                if (!numerics.solveDenseLinearSystem(local_matrix, local_rhs, 2)) break :local_phase_temperature;
                var fraction: f64 = 1;
                while (fraction >= 1.0e-8) : (fraction *= 0.5) {
                    @memcpy(candidate, current);
                    candidate[phase_index] += fraction * local_rhs[0];
                    candidate[cell] -= conservation_coefficient * fraction * local_rhs[0];
                    candidate[temperature_index] += fraction * local_rhs[1];
                    if (candidate[phase_index] < 0 or candidate[cell] < 0 or candidate[temperature_index] <= 0) continue;
                    residualAt(grid, properties, base, candidate, target, candidate_residual, scratch, trial_heat, trial_exchange, trial_displacement) catch continue;
                    if (try scaledNorm(base, candidate, candidate_residual, options) >= norm) continue;
                    @memcpy(current, candidate);
                    accepted_newton = true;
                    newton_steps += 1;
                    directional_newton_steps += 1;
                    break;
                }
            }
            if (accepted_newton) continue;
        }
        if (retrying_newton_after_anderson) continue;
        if (iteration + 1 >= options.max_iterations) return error.SoilPhaseSolverDidNotConverge;
        // Sole nonlinear fallback. A relaxed fixed-point point is evaluated as
        // the second Anderson sample but is never committed. This makes the
        // first recovery update genuinely accelerated; the next outer
        // iteration restarts Newton.
        var accepted_anderson = false;
        var seed_fraction: f64 = 1;
        while (seed_fraction >= 1.0e-8) : (seed_fraction = if (seed_fraction == 1) @min(options.picard_relaxation, 0.5) else seed_fraction * 0.5) {
            addDirection(current, residual, seed_fraction, candidate) catch continue;
            residualAt(grid, properties, base, candidate, target, candidate_residual, scratch, trial_heat, trial_exchange, trial_displacement) catch continue;
            if (!numerics.andersonDepthOneCandidate(current, residual, candidate, candidate_residual, probe)) continue;
            if (!representablePhaseState(probe, cells)) continue;
            residualAt(grid, properties, base, probe, target, probe_residual, scratch, trial_heat, trial_exchange, trial_displacement) catch continue;
            const accelerated_norm = try scaledNorm(base, probe, probe_residual, options);
            if (!numerics.andersonImprovesAcceptedMerit(accelerated_norm, norm)) continue;
            @memcpy(current, probe);
            accepted_anderson = true;
            anderson_recovery_steps += 1;
            break;
        }
        if (!accepted_anderson and history_count > 0) {
            const context: RecoveryContext = .{ .grid = grid, .properties = properties, .base = base, .target = target, .candidate = candidate, .candidate_residual = candidate_residual, .scratch = scratch, .trial_heat = trial_heat, .trial_exchange = trial_exchange, .trial_displacement = trial_displacement, .options = options };
            if (attemptAndersonRecovery(context, cells, current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, history_count, norm)) {
                accepted_anderson = true;
                anderson_recovery_steps += 1;
            }
        }
        if (!accepted_anderson) {
            if (forecast_requires_anderson and !stagnation_requires_anderson) {
                // The forecast only prices a bounded recovery attempt. A
                // rejected Anderson probe consumes this counted slot, then
                // Newton resumes. Reprice only after an accepted Newton step.
                rejected_forecast_recovery_step = newton_steps;
                continue;
            }
            if (!builtin.is_test) {
                const largest_index = largestScaledResidualIndex(base, current, residual, options) catch unreachable;
                const component_names = [_][]const u8{ "matrix_liquid_water_m3", "water_vapor_volume_m3", "matrix_ice_water_m3", "macropore_liquid_water_m3", "macropore_ice_volume_m3", "endpoint_temperature_k" };
                std.log.err("soil phase-enthalpy Newton-Picard stagnated: iteration={d} scaled_residual={e} limiting_component={s} layer_cell={d} state={e} residual={e} target={e}", .{ iteration + 1, norm, component_names[largest_index / cells], largest_index % cells, current[largest_index], residual[largest_index], current[largest_index] + residual[largest_index] });
                const limiting_cell = largest_index % cells;
                std.log.err("soil phase limiting block: temperature_k={e}->{e} matrix_water={e}->{e} vapor={e}->{e} matrix_ice={e}->{e} macropore_water={e}->{e} macropore_ice={e}->{e}", .{ current[5 * cells + limiting_cell], current[5 * cells + limiting_cell] + residual[5 * cells + limiting_cell], current[limiting_cell], current[limiting_cell] + residual[limiting_cell], current[cells + limiting_cell], current[cells + limiting_cell] + residual[cells + limiting_cell], current[2 * cells + limiting_cell], current[2 * cells + limiting_cell] + residual[2 * cells + limiting_cell], current[3 * cells + limiting_cell], current[3 * cells + limiting_cell] + residual[3 * cells + limiting_cell], current[4 * cells + limiting_cell], current[4 * cells + limiting_cell] + residual[4 * cells + limiting_cell] });
            }
            return error.SoilPhaseSolverStagnated;
        }
        control.record(.anderson_accept);
        rememberIteration(recovery_state, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
        picard_steps += 1;
        newton_retry_required = true;
        slow_newton_norm_count = 0;
        rejected_forecast_recovery_step = null;
    }
    try residualAt(grid, properties, base, current, target, residual, scratch, trial_heat, trial_exchange, trial_displacement);
    const final_norm = try scaledNorm(base, current, residual, options);
    var final_phase_energy_accepted = false;
    if (!newton_retry_required and final_norm <= 1 and
        committableState(grid, current, properties.freeze_thaw.ice_density_megagrams_per_m3))
    {
        const check = try evaluatePhaseEnergyConservation(base, current, trial_displacement, properties, options);
        final_phase_energy_accepted = check.accepted;
        if (check.diagnostic) |diagnostic| last_phase_energy_diagnostic.* = diagnostic;
    }
    if (final_phase_energy_accepted) {
        try residualAt(grid, properties, base, current, target, residual, scratch, trial_heat, trial_exchange, trial_displacement);
        try acceptedLatentHeat(base, current, properties, trial_heat);
        try requireDisplacementBinding(outputs.displacement, trial_displacement);
        try state_update(grid, current, properties.freeze_thaw.ice_density_megagrams_per_m3);
        copyDisplacement(outputs.displacement, trial_displacement);
        @memcpy(outputs.latent_heat_megajoules, trial_heat);
        @memcpy(outputs.macropore_to_matrix_water_m3, trial_exchange);
        return .{ .iterations = options.max_iterations, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .maximum_scaled_residual = final_norm, .anderson_recovery_steps = anderson_recovery_steps };
    }
    if (!builtin.is_test) {
        const limiting_index = largestScaledResidualIndex(base, current, residual, options) catch unreachable;
        const component_names = [_][]const u8{ "matrix_liquid_water_m3", "water_vapor_volume_m3", "matrix_ice_water_m3", "macropore_liquid_water_m3", "macropore_ice_volume_m3", "endpoint_temperature_k" };
        std.log.err("soil phase-enthalpy iteration ceiling reached: iterations={d} directional_newton={d} reduced_block_newton={d} reduced_block_invalid={d} reduced_block_rejected={d} diagonal_newton={d} picard={d} scaled_residual={e} limiting_component={s} layer_cell={d} state={e} residual={e} target={e}", .{ options.max_iterations, directional_newton_steps, reduced_block_newton_steps, reduced_block_invalid_iterations, reduced_block_rejected_iterations, diagonal_newton_steps, picard_steps, final_norm, component_names[limiting_index / cells], limiting_index % cells, current[limiting_index], residual[limiting_index], target[limiting_index] });
        if (last_reduced_block_probe_error) |err| std.log.err("last reduced phase block probe error: {s}", .{@errorName(err)});
    }
    return error.SoilPhaseSolverDidNotConverge;
}

/// Independent acceptance gate for the WATSUB phase endpoint. The nonlinear
/// temperature coordinate is deliberately scaled by a solver tolerance, but
/// that tolerance is not permission to create or destroy energy. For every
/// active layer this checks the source identity
///
///   C1*T1 = C0*T0 - displaced enthalpy + condensation + freezing.
///
/// The physical absolute-plus-relative balance tolerance stays separate from
/// the nonlinear merit. The upstream allowance below is only a forward-error
/// bound for assembling this identity in binary64; it never contains the
/// observed residual or the nonlinear tolerance.
fn evaluatePhaseEnergyConservation(
    base: []const f64,
    current: []const f64,
    displacement: DisplacementOutputs,
    properties: Properties,
    options: Options,
) !PhaseEnergyConservationCheck {
    if (properties.conservation_cell_area_m2.len == 0) return .{ .accepted = true };
    const cells = properties.conservation_cell_area_m2.len;
    if (base.len != 6 * cells or current.len != base.len)
        return error.SoilPhaseSolverDimensionMismatch;
    const layer_capacity = if (properties.conservation_layer_capacity == 0)
        1
    else
        properties.conservation_layer_capacity;
    if (layer_capacity == 0 or cells % layer_capacity != 0)
        return error.SoilPhaseSolverDimensionMismatch;
    const liquid_capacity = properties.liquid_water_heat_capacity_megajoules_per_m3_k;
    const ice_capacity = properties.ice_heat_capacity_megajoules_per_m3_k;
    const vaporization_latent = properties.vapor.latent_heat_of_vaporization_megajoules_per_m3;
    const fusion_latent = properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3;
    const arithmetic_operation_count: f64 = 64;
    const scaled_epsilon = arithmetic_operation_count * std.math.floatEps(f64);
    if (scaled_epsilon >= 1) return error.NonFiniteSoilPhaseFlux;

    const horizontal_cells = cells / layer_capacity;
    for (0..horizontal_cells) |horizontal_cell| {
        const first_layer = horizontal_cell * layer_capacity;
        const end_layer = first_layer + layer_capacity;
        const area_m2 = properties.conservation_cell_area_m2[first_layer];
        if (!std.math.isFinite(area_m2) or area_m2 < 0)
            return error.InvalidSoilPhaseInput;
        var participating_layers: usize = 0;
        for (first_layer..end_layer) |cell| {
            const layer_area_m2 = properties.conservation_cell_area_m2[cell];
            if (!std.math.isFinite(layer_area_m2) or layer_area_m2 < 0)
                return error.InvalidSoilPhaseInput;
            // One horizontal control volume has one ground area. Requiring the
            // replicated layer binding to agree exactly avoids silently
            // inventing an allocation rule for inconsistent geometry.
            if (layer_area_m2 != area_m2) return error.InvalidSoilPhaseInput;
            if (properties.active_by_layer.len == 0 or properties.active_by_layer[cell])
                participating_layers += 1;
        }
        if (participating_layers == 0) continue;
        const participant_count: f64 = @floatFromInt(participating_layers);
        const cell_absolute_budget =
            options.energy_conservation_absolute_tolerance_megajoules_per_m2 * area_m2;
        const layer_absolute_budget = cell_absolute_budget / participant_count;
        if (!std.math.isFinite(cell_absolute_budget) or
            !std.math.isFinite(layer_absolute_budget))
            return error.NonFiniteSoilPhaseFlux;

        var cell_transaction: scoped_conservation.Transaction = .{
            .storage_before = 0,
            .storage_after = 0,
        };
        var cell_upstream_roundoff: f64 = 0;
        var cell_addend_magnitude: f64 = 0;
        for (first_layer..end_layer) |cell| {
            if (properties.active_by_layer.len != 0 and !properties.active_by_layer[cell])
                continue;
            const matrix_water = cell;
            const vapor = cells + cell;
            const matrix_ice = 2 * cells + cell;
            const macro_water = 3 * cells + cell;
            const macro_ice = 4 * cells + cell;
            const temperature = 5 * cells + cell;
            const initial_liquid_m3 = base[matrix_water] + base[vapor] + base[macro_water];
            const initial_ice_m3 = base[matrix_ice] + base[macro_ice];
            const endpoint_liquid_m3 = current[matrix_water] + current[vapor] + current[macro_water];
            const endpoint_ice_m3 = current[matrix_ice] + current[macro_ice];
            const solid_capacity = properties.heat_capacity_megajoules_per_k[cell] -
                liquid_capacity * initial_liquid_m3 - ice_capacity * initial_ice_m3;
            const endpoint_capacity = solid_capacity +
                liquid_capacity * endpoint_liquid_m3 + ice_capacity * endpoint_ice_m3;
            const condensation_heat = vaporization_latent * (base[vapor] - current[vapor]);
            const freezing_heat = fusion_latent * (endpoint_ice_m3 - initial_ice_m3);
            const phase_heat = condensation_heat + freezing_heat;
            const displaced_heat = displacement.advective_enthalpy_megajoules[cell];
            const storage_before = properties.heat_capacity_megajoules_per_k[cell] * base[temperature];
            const storage_after = endpoint_capacity * current[temperature];
            inline for (.{
                solid_capacity,
                endpoint_capacity,
                condensation_heat,
                freezing_heat,
                phase_heat,
                displaced_heat,
                storage_before,
                storage_after,
            }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilPhaseFlux;
            if (solid_capacity < 0 or endpoint_capacity <= 0 or displaced_heat < 0)
                return error.InvalidSoilPhaseInput;
            const upstream_magnitude = @abs(storage_before) + @abs(storage_after) +
                @abs(condensation_heat) + @abs(freezing_heat) + @abs(displaced_heat) +
                @abs(liquid_capacity * initial_liquid_m3) + @abs(ice_capacity * initial_ice_m3) +
                @abs(liquid_capacity * endpoint_liquid_m3) + @abs(ice_capacity * endpoint_ice_m3);
            const upstream_roundoff = scaled_epsilon / (1 - scaled_epsilon) * upstream_magnitude;
            const transaction: scoped_conservation.Transaction = .{
                .storage_before = storage_before,
                .storage_after = storage_after,
                .external_outputs = displaced_heat,
                .internal_production = @max(0, phase_heat),
                .internal_consumption = @max(0, -phase_heat),
            };
            const closure = try scoped_conservation.evaluate(transaction, .{
                .absolute = layer_absolute_budget,
                // The local activity scale remains layer-specific; only the
                // cell's fixed absolute budget is apportioned.
                .relative = options.energy_conservation_relative_tolerance,
                .upstream_arithmetic_roundoff_allowance = upstream_roundoff,
            });
            if (!closure.accepted) {
                return .{
                    .accepted = false,
                    .diagnostic = .{
                        .scope = .layer,
                        .layer_cell = cell,
                        .residual_megajoules = closure.residual,
                        .normalized_relative = closure.normalized_relative,
                        .physical_limit_megajoules = closure.acceptance_limit,
                        .arithmetic_allowance_megajoules = closure.arithmetic_roundoff_allowance,
                        .effective_limit_megajoules = closure.effective_acceptance_limit,
                    },
                };
            }
            cell_transaction.storage_before += transaction.storage_before;
            cell_transaction.storage_after += transaction.storage_after;
            cell_transaction.external_outputs += transaction.external_outputs;
            cell_transaction.internal_production += transaction.internal_production;
            cell_transaction.internal_consumption += transaction.internal_consumption;
            cell_upstream_roundoff += upstream_roundoff;
            cell_addend_magnitude += @abs(transaction.storage_before) +
                @abs(transaction.storage_after) + transaction.external_outputs +
                transaction.internal_production + transaction.internal_consumption;
        }

        // Bound the additional additions used to reduce active layer terms
        // into the horizontal-cell transaction. This is representation error,
        // not residual booking and not part of the physical tolerance.
        const reduction_operation_count = 8 * participant_count + 1;
        const reduction_scaled_epsilon = reduction_operation_count * std.math.floatEps(f64);
        if (reduction_scaled_epsilon >= 1) return error.NonFiniteSoilPhaseFlux;
        cell_upstream_roundoff += reduction_scaled_epsilon /
            (1 - reduction_scaled_epsilon) *
            (cell_addend_magnitude + cell_upstream_roundoff);
        if (!std.math.isFinite(cell_upstream_roundoff))
            return error.NonFiniteSoilPhaseFlux;
        const cell_closure = try scoped_conservation.evaluate(cell_transaction, .{
            .absolute = cell_absolute_budget,
            .relative = options.energy_conservation_relative_tolerance,
            .upstream_arithmetic_roundoff_allowance = cell_upstream_roundoff,
        });
        if (!cell_closure.accepted) {
            return .{
                .accepted = false,
                .diagnostic = .{
                    .scope = .horizontal_cell,
                    .layer_cell = first_layer,
                    .residual_megajoules = cell_closure.residual,
                    .normalized_relative = cell_closure.normalized_relative,
                    .physical_limit_megajoules = cell_closure.acceptance_limit,
                    .arithmetic_allowance_megajoules = cell_closure.arithmetic_roundoff_allowance,
                    .effective_limit_megajoules = cell_closure.effective_acceptance_limit,
                },
            };
        }
    }
    return .{ .accepted = true };
}

fn phaseEnergyConservationAccepted(
    base: []const f64,
    current: []const f64,
    displacement: DisplacementOutputs,
    properties: Properties,
    options: Options,
) !bool {
    return (try evaluatePhaseEnergyConservation(base, current, displacement, properties, options)).accepted;
}

test "phase endpoint requires energy closure independently of nonlinear convergence" {
    const area = [_]f64{1};
    var properties = testProperties();
    properties.conservation_cell_area_m2 = &area;
    const base = [_]f64{ 0.5, 0, 0, 0, 0, 280 };
    var candidate = base;
    candidate[5] += 5.0e-10;
    const options: Options = .{
        .max_iterations = 20,
        .absolute_temperature_tolerance_k = 1.0e-9,
        .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1.0e-12,
        .energy_conservation_relative_tolerance = 1.0e-9,
    };
    var residual = [_]f64{0} ** 6;
    residual[5] = -5.0e-10;
    try std.testing.expect(try scaledNorm(&base, &candidate, &residual, options) <= 1);
    var zeros = [_]f64{0};
    const displacement: DisplacementOutputs = .{
        .matrix_liquid_water_m3 = &zeros,
        .matrix_ice_water_equivalent_m3 = &zeros,
        .macropore_liquid_water_m3 = &zeros,
        .macropore_ice_water_equivalent_m3 = &zeros,
        .advective_enthalpy_megajoules = &zeros,
    };
    const rejected = try evaluatePhaseEnergyConservation(
        &base,
        &candidate,
        displacement,
        properties,
        options,
    );
    try std.testing.expect(!rejected.accepted);
    try std.testing.expectEqual(rejected.accepted, try phaseEnergyConservationAccepted(
        &base,
        &candidate,
        displacement,
        properties,
        options,
    ));
    const diagnostic = rejected.diagnostic orelse return error.TestExpectedPhaseEnergyDiagnostic;
    try std.testing.expectEqual(@as(usize, 0), diagnostic.layer_cell);
    try std.testing.expect(std.math.isFinite(diagnostic.residual_megajoules));
    try std.testing.expect(std.math.isFinite(diagnostic.normalized_relative));
    try std.testing.expect(@abs(diagnostic.residual_megajoules) > diagnostic.effective_limit_megajoules);
    try std.testing.expect(diagnostic.effective_limit_megajoules >= diagnostic.physical_limit_megajoules);
    try std.testing.expect(diagnostic.effective_limit_megajoules >= diagnostic.arithmetic_allowance_megajoules);

    candidate[5] = std.math.nextAfter(f64, base[5], std.math.inf(f64));
    const accepted = try evaluatePhaseEnergyConservation(
        &base,
        &candidate,
        displacement,
        properties,
        options,
    );
    try std.testing.expect(accepted.accepted);
    try std.testing.expect(accepted.diagnostic == null);
    try std.testing.expectEqual(accepted.accepted, try phaseEnergyConservationAccepted(
        &base,
        &candidate,
        displacement,
        properties,
        options,
    ));
}

test "multilayer phase endpoint apportions one cell absolute energy budget" {
    const one_area = [_]f64{1};
    var one_zero = [_]f64{0};
    var one_layer_properties = testProperties();
    one_layer_properties.conservation_cell_area_m2 = &one_area;
    const one_layer_base = [_]f64{ 0, 0, 0, 0, 0, 280 };
    var one_layer_candidate = one_layer_base;
    // Five MJ/K times this temperature offset is about 0.75 microjoule:
    // below the one-cell 1.0-microjoule absolute budget.
    one_layer_candidate[5] += 1.5e-7;
    const options: Options = .{
        .max_iterations = 20,
        .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1.0e-6,
        .energy_conservation_relative_tolerance = 1.0e-15,
    };
    const one_layer_displacement: DisplacementOutputs = .{
        .matrix_liquid_water_m3 = &one_zero,
        .matrix_ice_water_equivalent_m3 = &one_zero,
        .macropore_liquid_water_m3 = &one_zero,
        .macropore_ice_water_equivalent_m3 = &one_zero,
        .advective_enthalpy_megajoules = &one_zero,
    };
    try std.testing.expect((try evaluatePhaseEnergyConservation(
        &one_layer_base,
        &one_layer_candidate,
        one_layer_displacement,
        one_layer_properties,
        options,
    )).accepted);

    const areas = [_]f64{ 1, 1 };
    const capacities = [_]f64{ 5, 5 };
    var zeros = [_]f64{ 0, 0 };
    const both_active = [_]bool{ true, true };
    var properties = testProperties();
    properties.active_by_layer = &both_active;
    properties.heat_capacity_megajoules_per_k = &capacities;
    properties.conservation_cell_area_m2 = &areas;
    const base = [_]f64{
        0, 0, // matrix liquid
        0, 0, // vapor
        0, 0, // matrix ice
        0, 0, // macropore liquid
        0, 0, // macropore ice
        280, 280, // endpoint temperature
    };
    var candidate = base;
    candidate[10] += 1.5e-7;
    candidate[11] += 1.5e-7;
    const displacement: DisplacementOutputs = .{
        .matrix_liquid_water_m3 = &zeros,
        .matrix_ice_water_equivalent_m3 = &zeros,
        .macropore_liquid_water_m3 = &zeros,
        .macropore_ice_water_equivalent_m3 = &zeros,
        .advective_enthalpy_megajoules = &zeros,
    };
    // An omitted grouping retains the original standalone contract: each
    // flattened entry is an independent control volume with its own budget.
    try std.testing.expect((try evaluatePhaseEnergyConservation(
        &base,
        &candidate,
        displacement,
        properties,
        options,
    )).accepted);

    properties.conservation_layer_capacity = 2;
    const rejected = try evaluatePhaseEnergyConservation(
        &base,
        &candidate,
        displacement,
        properties,
        options,
    );
    // Each same-sign layer error would pass if it independently received the
    // full cell budget. With two participants each receives one half, so the
    // candidate is rejected and the caller's Newton/Anderson loop continues.
    try std.testing.expect(!rejected.accepted);
    const diagnostic = rejected.diagnostic orelse
        return error.TestExpectedPhaseEnergyDiagnostic;
    try std.testing.expectEqual(PhaseEnergyConservationScope.layer, diagnostic.scope);
    try std.testing.expectApproxEqAbs(5.0e-7, diagnostic.physical_limit_megajoules, 1.0e-12);

    // An inactive DLYRM layer does not consume a share and its unchanged state
    // is excluded from both the local and horizontal-cell transactions.
    const one_active = [_]bool{ true, false };
    properties.active_by_layer = &one_active;
    candidate[11] = base[11];
    try std.testing.expect((try evaluatePhaseEnergyConservation(
        &base,
        &candidate,
        displacement,
        properties,
        options,
    )).accepted);
}

fn residualAt(grid: *const grid_module.GridState, properties: Properties, base: []const f64, trial: []const f64, target: []f64, residual: []f64, scratch: []f64, latent_heat: []f64, exchange_flux: []f64, displacement: DisplacementOutputs) !void {
    const cells = grid.layer_count;
    @memcpy(scratch, trial);
    @memcpy(target, base);
    @memset(latent_heat, 0);
    @memset(exchange_flux, 0);
    @memset(displacement.matrix_liquid_water_m3, 0);
    @memset(displacement.matrix_ice_water_equivalent_m3, 0);
    @memset(displacement.macropore_liquid_water_m3, 0);
    @memset(displacement.macropore_ice_water_equivalent_m3, 0);
    @memset(displacement.advective_enthalpy_megajoules, 0);
    for (0..cells) |cell| {
        if (properties.active_by_layer.len != 0 and
            !properties.active_by_layer[cell]) continue;
        const matrix_water = cell;
        const vapor = cells + cell;
        const matrix_ice = 2 * cells + cell;
        const macro_water = 3 * cells + cell;
        const macro_ice = 4 * cells + cell;
        const temperature = 5 * cells + cell;
        const matrix_water_fraction = scratch[matrix_water] / properties.matrix_bulk_volume_m3[cell];
        const matrix_parameters = properties.mualem_van_genuchten_parameters[cell];
        const matric_plus_osmotic_potential_megapascal =
            try matrix_parameters.pressureHeadAtWaterContent(std.math.clamp(
                matrix_water_fraction,
                matrix_parameters.residual_water_content_m3_per_m3,
                matrix_parameters.saturated_water_content_m3_per_m3,
            )) * properties.gravitational_water_potential_mpa_per_m +
            properties.osmotic_potential_megapascal[cell];
        const ice_density = properties.freeze_thaw.ice_density_megagrams_per_m3;
        const matrix_air_before_phase_m3 = @max(0.0, grid.matrix_pore_capacity_m3[cell] - scratch[matrix_water] - scratch[matrix_ice] / ice_density);
        const total_air_before_phase_m3 = matrix_air_before_phase_m3 + @max(0.0, grid.macropore_pore_capacity_m3[cell] - scratch[macro_water] - scratch[macro_ice] / ice_density);
        var vapor_change = phase.vaporLiquidEquilibrium(scratch[temperature], matric_plus_osmotic_potential_megapascal, scratch[vapor], total_air_before_phase_m3, scratch[matrix_water], 1, properties.vapor) catch |err| {
            if (!builtin.is_test) std.log.err("soil vapor equilibrium failed: layer_cell={d} temperature_k={e} potential_megapascal={e} vapor_m3={e} air_m3={e} matrix_water_m3={e} error={s}", .{ cell, scratch[temperature], matric_plus_osmotic_potential_megapascal, scratch[vapor], total_air_before_phase_m3, scratch[matrix_water], @errorName(err) });
            return err;
        };
        if (vapor_change.water_condensation_m3 > matrix_air_before_phase_m3) {
            const scale = matrix_air_before_phase_m3 / vapor_change.water_condensation_m3;
            vapor_change.water_condensation_m3 *= scale;
            vapor_change.vapor_change_m3 *= scale;
            vapor_change.latent_heat_megajoules *= scale;
        }
        // The nonlinear trial supplies temperature, potential, and saturation,
        // but the fixed-point image is applied to the transactional `target`
        // copied from `base`. WATSUB 6366--6380 evaluates and applies WFLVT to
        // the same VOLV02/VOLW02 inventory, so its condensation can never debit
        // more vapor than that image owns and its evaporation can never debit
        // more liquid. Preserve that source invariant when trial and target are
        // distinct instead of letting a synthetic finite-difference carrier
        // drive the endpoint inventory negative.
        vapor_change = try bindVaporLiquidEquilibriumToTargetDonors(
            vapor_change,
            target[matrix_water],
            target[vapor],
            properties.vapor.latent_heat_of_vaporization_megajoules_per_m3,
        );
        applyChange(scratch, target, matrix_water, vapor_change.water_condensation_m3);
        applyChange(scratch, target, vapor, vapor_change.vapor_change_m3);
        // WATSUB applies vapor first, then caps freezing/thawing against the
        // carrier physically available at this process boundary. Newton trial
        // ice is a coordinate, not inventory that a warm probe may donate:
        // using it here makes a branch-crossing probe request negative target
        // ice and destroys the semismooth line search. Keep trial temperature
        // and potential as the nonlinear drivers, but use the transactional
        // post-vapor liquid and pre-phase ice as the exact donors.
        const matrix_freeze_raw = phase.matrixFreezeThaw(
            scratch[temperature],
            matric_plus_osmotic_potential_megapascal,
            target[matrix_water],
            base[matrix_ice] / ice_density,
            properties.heat_capacity_megajoules_per_k[cell],
            properties.time_step_hours,
            properties.freeze_thaw,
        ) catch |err| {
            if (!builtin.is_test) std.log.err("matrix freeze-thaw input rejected: layer_cell={d} temperature_k={e} potential_megapascal={e} liquid_water_m3={e} ice_water_equivalent_m3={e} heat_capacity_megajoules_per_k={e} time_step_hours={e} error={s}", .{ cell, scratch[temperature], matric_plus_osmotic_potential_megapascal, target[matrix_water], base[matrix_ice], properties.heat_capacity_megajoules_per_k[cell], properties.time_step_hours, @errorName(err) });
            return err;
        };
        const matrix_freeze = try boundFreezeThawWaterEquivalent(
            freezeThawWaterEquivalent(matrix_freeze_raw, ice_density),
            target[matrix_water],
            base[matrix_ice],
            properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3,
        );
        applyChange(scratch, target, matrix_water, matrix_freeze.liquid_water_change_m3);
        applyChange(scratch, target, matrix_ice, matrix_freeze.ice_volume_change_m3);
        const macro_freeze = if (grid.macropore_pore_capacity_m3[cell] > 0) macro_freeze: {
            const raw = phase.macroporeFreezeThaw(
                scratch[temperature],
                matric_plus_osmotic_potential_megapascal,
                base[macro_water],
                base[macro_ice] / ice_density,
                properties.liquid_water_heat_capacity_megajoules_per_m3_k,
                properties.ice_heat_capacity_megajoules_per_m3_k * ice_density,
                properties.time_step_hours,
                properties.freeze_thaw,
            ) catch |err| {
                if (!builtin.is_test) std.log.err("macropore freeze-thaw input rejected: layer_cell={d} temperature_k={e} potential_megapascal={e} liquid_water_m3={e} ice_water_equivalent_m3={e} time_step_hours={e} error={s}", .{ cell, scratch[temperature], matric_plus_osmotic_potential_megapascal, base[macro_water], base[macro_ice], properties.time_step_hours, @errorName(err) });
                return err;
            };
            break :macro_freeze try boundFreezeThawWaterEquivalent(
                freezeThawWaterEquivalent(raw, ice_density),
                base[macro_water],
                base[macro_ice],
                properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3,
            );
        } else phase.FreezeThaw{
            .freezing_temperature_k = properties.freeze_thaw.pure_water_freezing_temperature_k,
            .liquid_water_change_m3 = 0,
            .ice_volume_change_m3 = 0,
            .latent_heat_megajoules = 0,
        };
        applyChange(scratch, target, macro_water, macro_freeze.liquid_water_change_m3);
        applyChange(scratch, target, macro_ice, macro_freeze.ice_volume_change_m3);
        var matrix_displacement_heat: f64 = 0;
        try displaceRigidPoreOverfill(
            target,
            matrix_water,
            matrix_ice,
            grid.matrix_pore_capacity_m3[cell],
            ice_density,
            base[temperature],
            properties.liquid_water_heat_capacity_megajoules_per_m3_k,
            &displacement.matrix_liquid_water_m3[cell],
            &displacement.matrix_ice_water_equivalent_m3[cell],
            &matrix_displacement_heat,
        );
        var macropore_displacement_heat: f64 = 0;
        try displaceRigidPoreOverfill(
            target,
            macro_water,
            macro_ice,
            grid.macropore_pore_capacity_m3[cell],
            ice_density,
            base[temperature],
            properties.liquid_water_heat_capacity_megajoules_per_m3_k,
            &displacement.macropore_liquid_water_m3[cell],
            &displacement.macropore_ice_water_equivalent_m3[cell],
            &macropore_displacement_heat,
        );
        displacement.advective_enthalpy_megajoules[cell] =
            matrix_displacement_heat + macropore_displacement_heat;
        const pore_exchange_enabled = sourcePoreExchangeEnabled(
            properties.pore_exchange_enabled,
            cell,
            base[macro_water],
            properties.face_area_m2[cell],
            grid.macropore_pore_capacity_m3[cell],
        ) catch |err| {
            if (!builtin.is_test) std.log.err("FINHL admission input rejected: layer_cell={d} entry_macropore_water_m3={e} face_area_m2={e} macropore_capacity_m3={e} error={s}", .{ cell, base[macro_water], properties.face_area_m2[cell], grid.macropore_pore_capacity_m3[cell], @errorName(err) });
            return err;
        };
        if (pore_exchange_enabled) {
            // VOLW2/VOLWH2 at this source point are the endpoint ledger assembled
            // from the accepted entry state plus all preceding fluxes. They are
            // represented by `target`, not by the nonlinear trial scratch. Using
            // the trial as the donor makes exact depletion discontinuous:
            // positive trials map to zero while a zero trial disables its own
            // transfer and maps back to the entry inventory.
            const matrix_water_for_exchange = if (target[matrix_water] >= 0) target[matrix_water] else return error.InvalidSoilPhaseCandidate;
            const macropore_water_for_exchange = if (target[macro_water] >= 0) target[macro_water] else return error.InvalidSoilPhaseCandidate;
            const matrix_air = @max(0.0, grid.matrix_pore_capacity_m3[cell] - matrix_water_for_exchange - target[matrix_ice] / ice_density);
            const macro_air = @max(0.0, grid.macropore_pore_capacity_m3[cell] - macropore_water_for_exchange - target[macro_ice] / ice_density);
            // PSISA1 is the accepted substep-entry matrix potential. The
            // post-vapor/freeze endpoint ledger above owns only the source
            // donor/receiver bounds (WATSUB 6516-6530).
            const exchange_water_fraction = base[matrix_water] / properties.matrix_bulk_volume_m3[cell];
            const exchange_matric_potential_megapascal = try properties.retention_curve[cell].waterPotentialMpa(@max(exchange_water_fraction, std.math.floatMin(f64)));
            const exchange = phase.macroporeMatrixExchange(.{ .saturated_lateral_matrix_conductivity_m2_per_h_megapascal = properties.saturated_lateral_matrix_conductivity_m2_per_h_megapascal[cell], .face_area_m2 = properties.face_area_m2[cell], .saturation_water_potential_megapascal = properties.saturation_water_potential_megapascal[cell], .current_matric_potential_megapascal = exchange_matric_potential_megapascal, .macropore_spacing_m = properties.macropore_spacing_m[cell], .macropore_radius_m = properties.macropore_radius_m[cell], .time_fraction = properties.time_step_hours, .matrix_water_m3 = matrix_water_for_exchange, .matrix_air_m3 = matrix_air, .macropore_water_m3 = macropore_water_for_exchange, .macropore_air_m3 = macro_air }) catch |err| {
                if (!builtin.is_test) std.log.err("macropore-matrix exchange failed: layer_cell={d} conductivity={e} face_area_m2={e} spacing_m={e} radius_m={e} matrix_water_m3={e} matrix_air_m3={e} macropore_water_m3={e} macropore_air_m3={e} error={s}", .{ cell, properties.saturated_lateral_matrix_conductivity_m2_per_h_megapascal[cell], properties.face_area_m2[cell], properties.macropore_spacing_m[cell], properties.macropore_radius_m[cell], matrix_water_for_exchange, matrix_air, macropore_water_for_exchange, macro_air, @errorName(err) });
                return err;
            };
            target[matrix_water] += exchange;
            target[macro_water] -= exchange;
            exchange_flux[cell] = exchange;
        }
        const matrix_occupancy_m3 =
            target[matrix_water] + target[matrix_ice] / ice_density;
        const macropore_occupancy_m3 =
            target[macro_water] + target[macro_ice] / ice_density;
        // The layer's total pore capacity is the scale of the arithmetic that
        // produced either domain's occupancy, so it bounds the roundoff both
        // comparisons may legitimately carry.
        const layer_pore_scale_m3 =
            grid.matrix_pore_capacity_m3[cell] + grid.macropore_pore_capacity_m3[cell];
        if (matrix_occupancy_m3 >
            grid.matrix_pore_capacity_m3[cell] +
                poreCapacityRoundoffToleranceM3(
                    grid.matrix_pore_capacity_m3[cell],
                    layer_pore_scale_m3,
                ) or
            macropore_occupancy_m3 >
                grid.macropore_pore_capacity_m3[cell] +
                    poreCapacityRoundoffToleranceM3(
                        grid.macropore_pore_capacity_m3[cell],
                        layer_pore_scale_m3,
                    ))
        {
            // SOIL-PORE-GUARD-TESTSCALE-001: this is raised from inside a
            // trial-point evaluation whose callers (Picard backtracking, line
            // search) catch and retry with a smaller step, so a rejection
            // here is ordinary, recovered solver behaviour, not a hard
            // failure — err severity trained readers to treat it as one and
            // was indistinguishable in the log from a genuine unrecovered
            // violation. debug severity keeps the diagnostic available
            // without that false alarm; the typed error is still returned
            // and still fatal if no caller recovers it.
            if (!builtin.is_test) std.log.debug(
                "soil phase candidate exceeds pore capacity: layer_cell={d} matrix_liquid_m3={e} matrix_ice_m3={e} matrix_capacity_m3={e} matrix_excess_m3={e} macropore_liquid_m3={e} macropore_ice_m3={e} macropore_capacity_m3={e} macropore_excess_m3={e}",
                .{
                    cell,
                    target[matrix_water],
                    target[matrix_ice],
                    grid.matrix_pore_capacity_m3[cell],
                    matrix_occupancy_m3 -
                        grid.matrix_pore_capacity_m3[cell],
                    target[macro_water],
                    target[macro_ice],
                    grid.macropore_pore_capacity_m3[cell],
                    macropore_occupancy_m3 -
                        grid.macropore_pore_capacity_m3[cell],
                },
            );
            return error.SoilPhaseCandidateExceedsPoreCapacity;
        }
        latent_heat[cell] = vapor_change.latent_heat_megajoules + matrix_freeze.latent_heat_megajoules + macro_freeze.latent_heat_megajoules;
        target[temperature] = phase.endpointTemperatureFromPhaseEnthalpy(
            grid.soil_temperature_k[cell],
            properties.heat_capacity_megajoules_per_k[cell],
            .{ .matrix_liquid_water_m3 = base[matrix_water], .water_vapor_volume_m3 = base[vapor], .matrix_ice_volume_m3 = base[matrix_ice], .macropore_liquid_water_m3 = base[macro_water], .macropore_ice_volume_m3 = base[macro_ice] },
            .{ .matrix_liquid_water_m3 = target[matrix_water], .water_vapor_volume_m3 = target[vapor], .matrix_ice_volume_m3 = target[matrix_ice], .macropore_liquid_water_m3 = target[macro_water], .macropore_ice_volume_m3 = target[macro_ice] },
            -displacement.advective_enthalpy_megajoules[cell],
            .{ .liquid_heat_capacity_megajoules_per_m3_k = properties.liquid_water_heat_capacity_megajoules_per_m3_k, .ice_heat_capacity_megajoules_per_m3_k = properties.ice_heat_capacity_megajoules_per_m3_k, .vaporization_latent_heat_megajoules_per_m3 = properties.vapor.latent_heat_of_vaporization_megajoules_per_m3, .fusion_latent_heat_megajoules_per_m3 = properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3 },
        ) catch |err| {
            if (!builtin.is_test) std.log.err("phase endpoint enthalpy input rejected: layer_cell={d} initial_temperature_k={e} heat_capacity_megajoules_per_k={e} base_matrix_water_m3={e} target_matrix_water_m3={e} base_vapor_m3={e} target_vapor_m3={e} base_matrix_ice_m3={e} target_matrix_ice_m3={e} base_macro_water_m3={e} target_macro_water_m3={e} base_macro_ice_m3={e} target_macro_ice_m3={e} advective_enthalpy_megajoules={e} error={s}", .{ cell, grid.soil_temperature_k[cell], properties.heat_capacity_megajoules_per_k[cell], base[matrix_water], target[matrix_water], base[vapor], target[vapor], base[matrix_ice], target[matrix_ice], base[macro_water], target[macro_water], base[macro_ice], target[macro_ice], displacement.advective_enthalpy_megajoules[cell], @errorName(err) });
            return err;
        };
    }
    for (target, trial, residual) |*value, trial_value, *difference| {
        if (!std.math.isFinite(value.*) or value.* < 0) return error.InvalidSoilPhaseCandidate;
        difference.* = value.* - trial_value;
    }
}

/// WATSUB 6512 admission rule. ZERO2 is a source constant with length units,
/// while ZEROS2 is extensive and therefore scales with each cell's plan area.
fn sourcePoreExchangeEnabled(enabled: []const bool, cell: usize, entry_macropore_water_m3: f64, plan_area_m2: f64, macropore_capacity_m3: f64) !bool {
    if (!std.math.isFinite(entry_macropore_water_m3) or entry_macropore_water_m3 < 0 or
        !std.math.isFinite(plan_area_m2) or plan_area_m2 < 0 or
        !std.math.isFinite(macropore_capacity_m3) or macropore_capacity_m3 < 0)
        return error.InvalidSoilPhaseInput;
    if (enabled.len == 0 or !enabled[cell] or macropore_capacity_m3 == 0) return false;
    return entry_macropore_water_m3 > 1.0e-6 * plan_area_m2;
}

test "WATSUB FINHL admission uses immutable area-scaled ZEROS2" {
    const enabled = [_]bool{true};
    try std.testing.expect(!try sourcePoreExchangeEnabled(&enabled, 0, 0, 2, 1));
    try std.testing.expect(!try sourcePoreExchangeEnabled(&enabled, 0, 2.0e-6, 2, 1));
    try std.testing.expect(try sourcePoreExchangeEnabled(&enabled, 0, std.math.nextAfter(f64, 2.0e-6, std.math.inf(f64)), 2, 1));
    try std.testing.expect(!try sourcePoreExchangeEnabled(&.{false}, 0, 1, 2, 1));
}

/// WATSUB 3677-3686, 4891-4903 and 4977-4990 do not suppress freezing when
/// physical ice overfills a rigid pore domain. They expel liquid upward and
/// book its convective heat. This layer-local solver exposes that carrier as a
/// sidecar; its caller owns the vertical/litter/pond recipient.
fn displaceRigidPoreOverfill(
    target: []f64,
    liquid_index: usize,
    ice_index: usize,
    pore_capacity_m3: f64,
    ice_density_megagrams_per_m3: f64,
    donor_temperature_k: f64,
    liquid_heat_capacity_megajoules_per_m3_k: f64,
    displaced_liquid_water_m3: *f64,
    displaced_ice_water_equivalent_m3: *f64,
    displaced_enthalpy_megajoules: *f64,
) !void {
    displaced_liquid_water_m3.* = 0;
    displaced_ice_water_equivalent_m3.* = 0;
    displaced_enthalpy_megajoules.* = 0;
    const occupancy_m3 = target[liquid_index] +
        target[ice_index] / ice_density_megagrams_per_m3;
    const excess_m3 = occupancy_m3 - pore_capacity_m3;
    if (excess_m3 <= poreCapacityRoundoffToleranceM3(
        pore_capacity_m3,
        pore_capacity_m3,
    )) return;
    // The oracle's soil overfill correction transports liquid, not ice. Keep
    // an explicit zero ice sidecar so downstream code cannot accidentally
    // reinterpret physical pore excess as an ice-mass transfer.
    const transferable_liquid_m3 = @min(
        target[liquid_index],
        excess_m3,
    );
    const unresolved_physical_overfill_m3 = excess_m3 - transferable_liquid_m3;
    if (unresolved_physical_overfill_m3 > poreCapacityRoundoffToleranceM3(
        pore_capacity_m3,
        pore_capacity_m3,
    )) return error.SoilPhasePoreOverfillRequiresUnimplementedIceDisplacement;
    target[liquid_index] -= transferable_liquid_m3;
    displaced_liquid_water_m3.* = transferable_liquid_m3;
    displaced_enthalpy_megajoules.* = transferable_liquid_m3 *
        liquid_heat_capacity_megajoules_per_m3_k * donor_temperature_k;
    if (!std.math.isFinite(displaced_enthalpy_megajoules.*))
        return error.NonFiniteSoilPhaseFlux;
}

/// WATSUB's phase kernels return physical `VOLI` change. Runtime ice carriers
/// are water-equivalent so their donor/recipient mass closure is exact and the
/// physical expansion appears only in pore occupancy (`WE / DENSI`).
fn freezeThawWaterEquivalent(change_physical: phase.FreezeThaw, ice_density_megagrams_per_m3: f64) phase.FreezeThaw {
    var change = change_physical;
    change.ice_volume_change_m3 *= ice_density_megagrams_per_m3;
    return change;
}

/// WATSUB defines the liquid and ice changes as one stoichiometric transfer:
/// WFLFL=-HFLFM/333 and the ice update is -WFLFL/DENSI. After converting ice
/// to water-equivalent volume, donor loss and recipient gain must therefore be
/// exact opposites. Multiplication/division round trips may overshoot an
/// exhausted donor by a fraction of one ulp; normalize only that proven active
/// bound and reject any material overshoot.
fn boundFreezeThawWaterEquivalent(
    unbounded: phase.FreezeThaw,
    available_liquid_water_m3: f64,
    available_ice_water_equivalent_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
) !phase.FreezeThaw {
    if (!std.math.isFinite(available_liquid_water_m3) or available_liquid_water_m3 < 0 or
        !std.math.isFinite(available_ice_water_equivalent_m3) or available_ice_water_equivalent_m3 < 0 or
        !std.math.isFinite(latent_heat_of_fusion_megajoules_per_m3) or latent_heat_of_fusion_megajoules_per_m3 <= 0 or
        !std.math.isFinite(unbounded.liquid_water_change_m3))
        return error.InvalidSoilPhaseCandidate;

    var liquid_change_m3 = unbounded.liquid_water_change_m3;
    const requested_donor_m3 = if (liquid_change_m3 < 0)
        -liquid_change_m3
    else
        liquid_change_m3;
    const available_donor_m3 = if (liquid_change_m3 < 0)
        available_liquid_water_m3
    else
        available_ice_water_equivalent_m3;
    if (requested_donor_m3 > available_donor_m3) {
        const arithmetic_scale_m3 = @max(requested_donor_m3, available_donor_m3);
        const forward_error_m3 = 4 * std.math.floatEps(f64) * arithmetic_scale_m3;
        if (requested_donor_m3 - available_donor_m3 > forward_error_m3)
            return error.InvalidSoilPhaseCandidate;
        liquid_change_m3 = if (liquid_change_m3 < 0)
            -available_donor_m3
        else
            available_donor_m3;
    }

    var bounded = unbounded;
    bounded.liquid_water_change_m3 = liquid_change_m3;
    bounded.ice_volume_change_m3 = -liquid_change_m3;
    bounded.latent_heat_megajoules =
        latent_heat_of_fusion_megajoules_per_m3 * bounded.ice_volume_change_m3;
    if (!std.math.isFinite(bounded.latent_heat_megajoules))
        return error.NonFiniteSoilPhaseFlux;
    return bounded;
}

test "freeze-thaw water-equivalent donor exhaustion is exact and conservative" {
    const donor_m3 = 1.387778404244234e-17;
    const overshoot_m3 = std.math.nextAfter(f64, donor_m3, std.math.inf(f64));
    const bounded = try boundFreezeThawWaterEquivalent(
        .{
            .freezing_temperature_k = 273.15,
            .liquid_water_change_m3 = overshoot_m3,
            .ice_volume_change_m3 = -overshoot_m3,
            .latent_heat_megajoules = -333 * overshoot_m3,
        },
        1,
        donor_m3,
        333,
    );
    try std.testing.expectEqual(donor_m3, bounded.liquid_water_change_m3);
    try std.testing.expectEqual(-donor_m3, bounded.ice_volume_change_m3);
    try std.testing.expectEqual(@as(f64, 0), donor_m3 + bounded.ice_volume_change_m3);
    try std.testing.expectEqual(
        333 * bounded.ice_volume_change_m3,
        bounded.latent_heat_megajoules,
    );

    try std.testing.expectError(
        error.InvalidSoilPhaseCandidate,
        boundFreezeThawWaterEquivalent(
            .{
                .freezing_temperature_k = 273.15,
                .liquid_water_change_m3 = 1.01 * donor_m3,
                .ice_volume_change_m3 = -1.01 * donor_m3,
                .latent_heat_megajoules = -333 * 1.01 * donor_m3,
            },
            1,
            donor_m3,
            333,
        ),
    );
}

/// Exact latent-energy activity of the accepted endpoint. Residual evaluation
/// uses scratch arrays throughout Newton/Anderson; publishing from the actual
/// accepted carrier delta prevents a tolerance-sized target/iterate mismatch
/// from entering the conservation ledger.
fn acceptedLatentHeat(base: []const f64, accepted: []const f64, properties: Properties, output: []f64) !void {
    const cells = output.len;
    if (base.len != 6 * cells or accepted.len != base.len)
        return error.SoilPhaseSolverDimensionMismatch;
    for (output, 0..) |*latent, cell| {
        const condensation_m3 = base[cells + cell] - accepted[cells + cell];
        const ice_change_m3 =
            accepted[2 * cells + cell] + accepted[4 * cells + cell] -
            base[2 * cells + cell] - base[4 * cells + cell];
        latent.* = properties.vapor.latent_heat_of_vaporization_megajoules_per_m3 *
            condensation_m3 +
            properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3 *
                ice_change_m3;
        if (!std.math.isFinite(latent.*)) return error.NonFiniteSoilPhaseFlux;
    }
}

fn hasDisplacement(displacement: DisplacementOutputs) bool {
    for (displacement.matrix_liquid_water_m3) |value| if (value != 0) return true;
    for (displacement.matrix_ice_water_equivalent_m3) |value| if (value != 0) return true;
    for (displacement.macropore_liquid_water_m3) |value| if (value != 0) return true;
    for (displacement.macropore_ice_water_equivalent_m3) |value| if (value != 0) return true;
    return false;
}

fn hasDisplacementAtCell(displacement: DisplacementOutputs, cell: usize) bool {
    return displacement.matrix_liquid_water_m3[cell] != 0 or
        displacement.matrix_ice_water_equivalent_m3[cell] != 0 or
        displacement.macropore_liquid_water_m3[cell] != 0 or
        displacement.macropore_ice_water_equivalent_m3[cell] != 0;
}

fn requireDisplacementBinding(destination: ?DisplacementOutputs, source: DisplacementOutputs) !void {
    if (destination == null and hasDisplacement(source))
        return error.UnboundSoilPhaseDisplacement;
}

fn copyDisplacement(destination: ?DisplacementOutputs, source: DisplacementOutputs) void {
    const output = destination orelse return;
    @memcpy(output.matrix_liquid_water_m3, source.matrix_liquid_water_m3);
    @memcpy(output.matrix_ice_water_equivalent_m3, source.matrix_ice_water_equivalent_m3);
    @memcpy(output.macropore_liquid_water_m3, source.macropore_liquid_water_m3);
    @memcpy(output.macropore_ice_water_equivalent_m3, source.macropore_ice_water_equivalent_m3);
    @memcpy(output.advective_enthalpy_megajoules, source.advective_enthalpy_megajoules);
}

/// Roundoff allowance for a pore-occupancy comparison.
///
/// `capacity_m3` is the domain's own capacity and `domain_scale_m3` is the
/// scale of the arithmetic that produced the occupancy. They differ for a
/// zero-capacity macropore: its residual ice arrives from transfers and phase
/// changes scaled to the whole layer, so scaling the allowance by its own zero
/// capacity would compare a layer-scale rounding residual against an absolute
/// `1e-12` floor. On the Ottawa deck (single 1 m2 cell, layer pore scale on
/// the order of `0.1` m3, not the `8.9e6` m3 previously and incorrectly
/// stated here) a `6.06e-12` m3 macropore ice residual exceeds this floor by
/// about 6x and is correctly rejected, not tolerated — see
/// `docs/discrepancy_register.md`'s `SOIL-PORE-GUARD-TESTSCALE-001`.
fn poreCapacityRoundoffToleranceM3(capacity_m3: f64, domain_scale_m3: f64) f64 {
    return @max(
        1.0e-12,
        64.0 * std.math.floatEps(f64) *
            @max(1.0, @max(@abs(capacity_m3), @abs(domain_scale_m3))),
    );
}

test "pore roundoff allowance scales with the layer, not a zero domain capacity" {
    // A zero-capacity macropore receives residual ice from transfers scaled to
    // the whole layer. On a large layer the allowance grows past the floor.
    const large_layer_scale_m3: f64 = 8.9e6;
    const residual_m3: f64 = 6.055454452393339e-12;
    try std.testing.expect(residual_m3 <= poreCapacityRoundoffToleranceM3(0, large_layer_scale_m3));
    // Without the layer scale the same residual is rejected against the floor.
    try std.testing.expect(residual_m3 > poreCapacityRoundoffToleranceM3(0, 0));
    // The allowance must stay far below any physically meaningful overfill: a
    // millilitre of excess is still an error at this layer scale.
    try std.testing.expect(1.0e-6 > poreCapacityRoundoffToleranceM3(0, large_layer_scale_m3));
    // It never shrinks below the absolute floor for small layers.
    try std.testing.expectEqual(@as(f64, 1.0e-12), poreCapacityRoundoffToleranceM3(0, 1));
}

test "pore roundoff allowance at the Ottawa deck's real layer scale correctly rejects the historical residual" {
    // SOIL-PORE-GUARD-TESTSCALE-001: the sibling test above previously cited
    // this same 6.06e-12 m3 residual as tolerated "in an 8.9e6 m3 layer," but
    // the Ottawa deck's real cell area is 1 m2, so its layer pore scale
    // (matrix_pore_capacity_m3 + macropore_pore_capacity_m3) is order 0.1 m3,
    // not 8.9e6. At the real scale the allowance collapses to the 1e-12
    // floor and the residual is correctly rejected, not tolerated.
    const ottawa_layer_7_pore_scale_m3: f64 = 1.0209637003464284e-1;
    const residual_m3: f64 = 6.055454452393339e-12;
    try std.testing.expectEqual(@as(f64, 1.0e-12), poreCapacityRoundoffToleranceM3(0, ottawa_layer_7_pore_scale_m3));
    try std.testing.expect(residual_m3 > poreCapacityRoundoffToleranceM3(0, ottawa_layer_7_pore_scale_m3));
}

fn applyChange(scratch: []f64, target: []f64, index: usize, change: f64) void {
    scratch[index] += change;
    target[index] += change;
}

/// Bind a trial-derived vapor/liquid equilibrium transfer to the donors owned
/// by the fixed-point target. The signed transfer remains one atomic internal
/// conversion: liquid gain is exactly vapor loss and latent heat is recomputed
/// from the accepted transfer rather than scaled or clipped after publication.
fn bindVaporLiquidEquilibriumToTargetDonors(
    equilibrium: phase.VaporEquilibrium,
    target_matrix_water_m3: f64,
    target_vapor_m3: f64,
    latent_heat_of_vaporization_megajoules_per_m3: f64,
) !phase.VaporEquilibrium {
    if (!std.math.isFinite(equilibrium.saturated_vapor_fraction) or
        !std.math.isFinite(equilibrium.water_condensation_m3) or
        !std.math.isFinite(equilibrium.vapor_change_m3) or
        !std.math.isFinite(equilibrium.latent_heat_megajoules) or
        !std.math.isFinite(target_matrix_water_m3) or
        !std.math.isFinite(target_vapor_m3) or
        !std.math.isFinite(latent_heat_of_vaporization_megajoules_per_m3) or
        target_matrix_water_m3 < 0 or target_vapor_m3 < 0 or
        latent_heat_of_vaporization_megajoules_per_m3 <= 0)
        return error.InvalidSoilPhaseInput;

    const raw = equilibrium.water_condensation_m3;
    const accepted = if (raw > 0)
        @min(raw, target_vapor_m3)
    else if (raw < 0)
        @max(raw, -target_matrix_water_m3)
    else
        raw;
    const latent = latent_heat_of_vaporization_megajoules_per_m3 * accepted;
    if (!std.math.isFinite(latent)) return error.NonFiniteSoilPhaseFlux;
    return .{
        .saturated_vapor_fraction = equilibrium.saturated_vapor_fraction,
        .water_condensation_m3 = accepted,
        .vapor_change_m3 = -accepted,
        .latent_heat_megajoules = latent,
    };
}

test "vapor equilibrium donor binding preserves paired transfer and latent heat" {
    const latent_heat: f64 = 2450;
    const condensation = try bindVaporLiquidEquilibriumToTargetDonors(.{
        .saturated_vapor_fraction = 1.0e-6,
        .water_condensation_m3 = 6.0554123e-12,
        .vapor_change_m3 = -6.0554123e-12,
        .latent_heat_megajoules = latent_heat * 6.0554123e-12,
    }, 0.25, 1.159296462292623e-21, latent_heat);
    try std.testing.expectEqual(@as(f64, 1.159296462292623e-21), condensation.water_condensation_m3);
    try std.testing.expectEqual(-condensation.water_condensation_m3, condensation.vapor_change_m3);
    try std.testing.expectEqual(latent_heat * condensation.water_condensation_m3, condensation.latent_heat_megajoules);

    const evaporation = try bindVaporLiquidEquilibriumToTargetDonors(.{
        .saturated_vapor_fraction = 1.0e-6,
        .water_condensation_m3 = -6.0554123e-12,
        .vapor_change_m3 = 6.0554123e-12,
        .latent_heat_megajoules = -latent_heat * 6.0554123e-12,
    }, 2.062713811987489e-16, 0.1, latent_heat);
    try std.testing.expectEqual(@as(f64, -2.062713811987489e-16), evaporation.water_condensation_m3);
    try std.testing.expectEqual(-evaporation.water_condensation_m3, evaporation.vapor_change_m3);
    try std.testing.expectEqual(latent_heat * evaporation.water_condensation_m3, evaporation.latent_heat_megajoules);

    const within_donor: phase.VaporEquilibrium = .{
        .saturated_vapor_fraction = 2.0e-6,
        .water_condensation_m3 = 1.0e-8,
        .vapor_change_m3 = -1.0e-8,
        .latent_heat_megajoules = latent_heat * 1.0e-8,
    };
    try std.testing.expectEqualDeep(
        within_donor,
        try bindVaporLiquidEquilibriumToTargetDonors(within_donor, 0.25, 0.1, latent_heat),
    );
}

fn committableState(grid: *const grid_module.GridState, state: []const f64, ice_density_megagrams_per_m3: f64) bool {
    const cells = grid.layer_count;
    if (state.len != 6 * cells) return false;
    for (0..cells) |cell| {
        const layer_scale = grid.matrix_pore_capacity_m3[cell] +
            grid.macropore_pore_capacity_m3[cell];
        _ = derivedAirVolumeM3(
            grid.matrix_pore_capacity_m3[cell],
            state[cell],
            state[2 * cells + cell],
            ice_density_megagrams_per_m3,
            layer_scale,
        ) catch return false;
        _ = derivedAirVolumeM3(
            grid.macropore_pore_capacity_m3[cell],
            state[3 * cells + cell],
            state[4 * cells + cell],
            ice_density_megagrams_per_m3,
            layer_scale,
        ) catch return false;
        if (!std.math.isFinite(state[1 * cells + cell]) or state[1 * cells + cell] < 0 or
            !std.math.isFinite(state[5 * cells + cell]) or state[5 * cells + cell] <= 0)
            return false;
        // issue-068 (2026-09-20, sixth round): this simultaneous VOLW/VOLV/
        // VOLI/VOLWH/VOLIH + endpoint-temperature solve is a genuinely
        // separate Newton/Anderson loop from the dense spatial heat solver in
        // `solver_solve.zig`, with its own accept path directly into
        // `grid.soil_temperature_k` (`state_update` below). Its only prior
        // temperature check was `> 0` -- finite and above absolute zero, but
        // not bounded to the same [173.15, 373.15] K physical domain every
        // sibling solver enforces before committing. A residual-scaled accept
        // here is exactly as vulnerable to a near-zero-heat-capacity layer
        // (this issue's chronic cell 0/layer 0) as the two branches guarded
        // in `solver_solve.zig`'s `allTemperaturesPhysicallyValid` (issue-068,
        // second round): a small scaled residual can still hide a huge
        // absolute temperature departure. Guarding the acceptance gate here
        // (rather than widening or removing this check) makes a physically
        // absurd candidate fall through to this solver's own existing,
        // already-tested `.stagnated`/`SoilPhaseSolverDidNotConverge` failure
        // path instead of being committed -- never changes behavior for a
        // normal layer, whose endpoint temperature is already far inside the
        // band.
        if (!heat_solver.isPhysicalTemperatureK(state[5 * cells + cell]))
            return false;
    }
    return true;
}

fn state_update(grid: *grid_module.GridState, state: []const f64, ice_density_megagrams_per_m3: f64) !void {
    const cells = grid.layer_count;
    // The nonlinear state is six components per cell: five phase inventories
    // plus the endpoint enthalpy temperature. Validate every component before
    // publishing any of them so a rejected endpoint remains side-effect free.
    if (state.len != 6 * cells) return error.SoilPhaseStateDimensionMismatch;
    // Validate the complete candidate before publishing any carrier. Air is a
    // derived representation; only a subtraction-sized roundoff residual may
    // be normalized to zero. A physically overfilled pore domain is rejected
    // atomically instead of being hidden by independent clipping.
    for (0..cells) |cell| {
        const matrix_capacity = grid.matrix_pore_capacity_m3[cell];
        const macropore_capacity = grid.macropore_pore_capacity_m3[cell];
        const layer_scale = matrix_capacity + macropore_capacity;
        _ = try derivedAirVolumeM3(
            matrix_capacity,
            state[0 * cells + cell],
            state[2 * cells + cell],
            ice_density_megagrams_per_m3,
            layer_scale,
        );
        _ = try derivedAirVolumeM3(
            macropore_capacity,
            state[3 * cells + cell],
            state[4 * cells + cell],
            ice_density_megagrams_per_m3,
            layer_scale,
        );
        if (!std.math.isFinite(state[1 * cells + cell]) or state[1 * cells + cell] < 0)
            return error.InvalidSoilPhaseCandidate;
        if (!std.math.isFinite(state[5 * cells + cell]) or state[5 * cells + cell] <= 0)
            return error.InvalidSoilPhaseCandidate;
        if (!std.math.isFinite(state[0 * cells + cell] + state[3 * cells + cell]) or
            !std.math.isFinite(state[2 * cells + cell] + state[4 * cells + cell]))
            return error.InvalidSoilPhaseCandidate;
        // issue-068 (2026-09-20, sixth round): belt-and-suspenders match to
        // `committableState`'s own new guard above (same rationale as
        // `commitAcceptedState`'s own internal `validateSoilTemperaturePhysicalDomain`
        // call in `solver_solve.zig`, which re-checks a value its caller
        // already validated). A distinct error name -- not a reuse of
        // `InvalidSoilPhaseCandidate` -- keeps this failure separately
        // attributable in a log, the same reasoning that gave
        // `SoilHeatRenormalizedTemperatureOutsidePhysicalDomain` its own name
        // in the second round rather than reusing
        // `SoilHeatSolverTemperatureOutsidePhysicalDomain`.
        if (!heat_solver.isPhysicalTemperatureK(state[5 * cells + cell]))
            return error.SoilPhaseSolverTemperatureOutsidePhysicalDomain;
    }
    @memcpy(grid.matrix_liquid_water_m3, state[0 * cells .. 1 * cells]);
    @memcpy(grid.water_vapor_volume_m3, state[1 * cells .. 2 * cells]);
    @memcpy(grid.matrix_ice_water_m3, state[2 * cells .. 3 * cells]);
    @memcpy(grid.macropore_liquid_water_m3, state[3 * cells .. 4 * cells]);
    @memcpy(grid.macropore_ice_water_m3, state[4 * cells .. 5 * cells]);
    @memcpy(grid.soil_temperature_k, state[5 * cells .. 6 * cells]);
    for (0..cells) |cell| {
        grid.liquid_water_m3[cell] = grid.matrix_liquid_water_m3[cell] + grid.macropore_liquid_water_m3[cell];
        grid.ice_water_m3[cell] = grid.matrix_ice_water_m3[cell] + grid.macropore_ice_water_m3[cell];
        const layer_scale = grid.matrix_pore_capacity_m3[cell] + grid.macropore_pore_capacity_m3[cell];
        grid.matrix_air_volume_m3[cell] = try derivedAirVolumeM3(
            grid.matrix_pore_capacity_m3[cell],
            grid.matrix_liquid_water_m3[cell],
            grid.matrix_ice_water_m3[cell],
            ice_density_megagrams_per_m3,
            layer_scale,
        );
        grid.macropore_air_volume_m3[cell] = try derivedAirVolumeM3(
            grid.macropore_pore_capacity_m3[cell],
            grid.macropore_liquid_water_m3[cell],
            grid.macropore_ice_water_m3[cell],
            ice_density_megagrams_per_m3,
            layer_scale,
        );
        grid.air_volume_m3[cell] = grid.matrix_air_volume_m3[cell] + grid.macropore_air_volume_m3[cell];
    }
    try grid.validateFinite();
}

fn derivedAirVolumeM3(capacity_m3: f64, liquid_m3: f64, ice_water_equivalent_m3: f64, ice_density_megagrams_per_m3: f64, layer_scale_m3: f64) !f64 {
    if (!std.math.isFinite(capacity_m3) or capacity_m3 < 0 or
        !std.math.isFinite(liquid_m3) or liquid_m3 < 0 or
        !std.math.isFinite(ice_water_equivalent_m3) or ice_water_equivalent_m3 < 0 or
        !std.math.isFinite(layer_scale_m3) or layer_scale_m3 < 0)
        return error.InvalidSoilPhaseCandidate;
    const physical_ice_m3 = ice_units.physicalVolumeM3FromWaterEquivalent(ice_water_equivalent_m3, ice_density_megagrams_per_m3) catch return error.InvalidSoilPhaseCandidate;
    const raw_air_m3 = capacity_m3 - liquid_m3 - physical_ice_m3;
    if (!std.math.isFinite(raw_air_m3)) return error.InvalidSoilPhaseCandidate;
    if (raw_air_m3 < -poreCapacityRoundoffToleranceM3(capacity_m3, layer_scale_m3))
        return error.SoilPhaseCandidateExceedsPoreCapacity;
    return if (raw_air_m3 < 0) 0 else raw_air_m3;
}

test "derived phase air rejects physical overfill and only normalizes roundoff" {
    try std.testing.expectError(
        error.SoilPhaseCandidateExceedsPoreCapacity,
        derivedAirVolumeM3(1, 0.75, 0.917 * 0.250001, 0.917, 1),
    );
    const roundoff_overfill = 0.5 * poreCapacityRoundoffToleranceM3(1, 1);
    try std.testing.expectEqual(
        @as(f64, 0),
        try derivedAirVolumeM3(1, 0.75, 0.917 * (0.25 + roundoff_overfill), 0.917, 1),
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.1),
        try derivedAirVolumeM3(1, 0.6, 0.917 * 0.3, 0.917, 1),
        8 * std.math.floatEps(f64),
    );
}

test "phase commit publishes endpoint temperature and rejects it atomically" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.macropore_pore_capacity_m3[0] = 1;

    const accepted = [_]f64{ 0.75, 0.015625, 0.25, 0.25, 0.125, 271.25 };
    try state_update(&grid, &accepted, 0.917);
    try std.testing.expectEqual(@as(f64, 271.25), grid.soil_temperature_k[0]);
    try std.testing.expectEqual(@as(f64, 1.0), grid.liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.375), grid.ice_water_m3[0]);

    var rejected = accepted;
    rejected[0] = 0.625;
    rejected[5] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidSoilPhaseCandidate, state_update(&grid, &rejected, 0.917));
    try std.testing.expectEqual(@as(f64, 0.75), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 271.25), grid.soil_temperature_k[0]);
}

test "issue-068 (sixth round): state_update rejects a finite but physically absurd endpoint temperature" {
    // Direct proof that `state_update`'s own belt-and-suspenders guard fires
    // for the exact class of finite, positive, but physically absurd
    // endpoint temperature this issue chain has chased since the third
    // round (401.75-519.16 K, all comfortably `> 0` and finite, which is all
    // this function checked before this round). 452.64 K is one of the
    // exact captured hour-2895 offending values from the fifth round's own
    // validation run.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.macropore_pore_capacity_m3[0] = 1;
    grid.soil_temperature_k[0] = 271.25;

    var too_hot = [_]f64{ 0.75, 0.015625, 0.25, 0.25, 0.125, 452.64 };
    try std.testing.expectError(
        error.SoilPhaseSolverTemperatureOutsidePhysicalDomain,
        state_update(&grid, &too_hot, 0.917),
    );
    // Rejected atomically: no carrier, including temperature, changed.
    try std.testing.expectEqual(@as(f64, 271.25), grid.soil_temperature_k[0]);
    try std.testing.expectEqual(@as(f64, 0), grid.matrix_liquid_water_m3[0]);

    var too_cold = [_]f64{ 0.75, 0.015625, 0.25, 0.25, 0.125, 120.0 };
    try std.testing.expectError(
        error.SoilPhaseSolverTemperatureOutsidePhysicalDomain,
        state_update(&grid, &too_cold, 0.917),
    );
    try std.testing.expectEqual(@as(f64, 271.25), grid.soil_temperature_k[0]);
}

test "issue-068 (sixth round): committableState requires the endpoint temperature inside the physical domain" {
    // Proves the acceptance-gate half of the fix (mirroring `solver_solve.zig`'s
    // `allTemperaturesPhysicallyValid`, issue-068 second round): a candidate
    // otherwise admissible to `committableState` (finite, non-negative
    // carriers, non-overfilled pores) is rejected purely because its endpoint
    // temperature is outside [173.15, 373.15] K, so `solve`'s own Newton/
    // Anderson loop falls through to its existing tested failure path
    // instead of ever reaching `state_update`.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.macropore_pore_capacity_m3[0] = 1;

    const in_domain = [_]f64{ 0.75, 0.015625, 0.25, 0.25, 0.125, 271.25 };
    try std.testing.expect(committableState(&grid, &in_domain, 0.917));

    var out_of_domain = in_domain;
    out_of_domain[5] = 452.64;
    try std.testing.expect(!committableState(&grid, &out_of_domain, 0.917));
}

fn addDirection(current: []const f64, direction: []const f64, fraction: f64, output: []f64) !void {
    for (current, direction, output) |value, delta, *candidate| {
        candidate.* = value + fraction * delta;
        if (!std.math.isFinite(candidate.*) or candidate.* < 0) return error.InvalidSoilPhaseCandidate;
    }
}

fn reducedBlockProbeStep(
    grid: *const grid_module.GridState,
    current: []const f64,
    column_component: usize,
    cell: usize,
    nominal: f64,
    coordinate_residual: f64,
    ice_density_megagrams_per_m3: f64,
) f64 {
    const cells = grid.layer_count;
    const index = column_component * cells + cell;
    const conservation_coefficient: f64 = if (column_component >= 1 and column_component <= 4) 1.0 else 0.0;
    const matrix_air_m3 = @max(0, grid.matrix_pore_capacity_m3[cell] - current[cell] - current[2 * cells + cell] / ice_density_megagrams_per_m3);
    const macropore_air_m3 = @max(0, grid.macropore_pore_capacity_m3[cell] - current[3 * cells + cell] - current[4 * cells + cell] / ice_density_megagrams_per_m3);
    // At zero vapor in a fully saturated cell, neither finite-difference side
    // exists: the negative side violates vapor non-negativity, while a positive
    // conserved probe creates air by removing matrix liquid and immediately
    // condenses the synthetic vapor against a zero base inventory. That makes
    // the fixed-point target negative for every nonzero step. Treat the exact
    // active-set coordinate as fixed instead of exhausting same-sign retries.
    if (column_component == 1 and current[index] == 0 and coordinate_residual == 0 and matrix_air_m3 == 0 and macropore_air_m3 == 0)
        return 0;
    var positive_limit = if (conservation_coefficient > 0) current[cell] / conservation_coefficient else std.math.inf(f64);
    if (column_component == 2) {
        const physical_expansion_per_m3_we = 1.0 / ice_density_megagrams_per_m3 - 1.0;
        positive_limit = @min(positive_limit, matrix_air_m3 / physical_expansion_per_m3_we);
    }
    if (column_component == 3) positive_limit = @min(positive_limit, macropore_air_m3);
    // Macropore ice is paired with eliminated *matrix* liquid. Increasing it
    // therefore consumes macropore air at 1/rho per m3 WE; there is no
    // same-domain liquid removal to subtract from that occupancy change.
    if (column_component == 4) positive_limit = @min(positive_limit, macropore_air_m3 * ice_density_megagrams_per_m3);
    if (positive_limit >= nominal) return nominal;

    var negative_limit = current[index];
    // Reducing vapor or either macropore carrier adds its conserved water to
    // matrix liquid, so matrix air bounds all three negative directions.
    if (column_component == 1 or column_component == 3 or column_component == 4)
        negative_limit = @min(negative_limit, matrix_air_m3 / conservation_coefficient);
    var step = -@min(nominal, 0.5 * negative_limit);
    if (@abs(step) <= 1e-20) step = 0.5 * positive_limit;
    return step;
}

/// Return the feasible one-sided probe opposite `primary_step`. This is used
/// only after a batched column was rejected: an active-set map may be undefined
/// on one finite-difference side while retaining a valid semismooth derivative
/// on the other. Both sides preserve water by the same eliminated matrix-liquid
/// coordinate used by the reduced Newton block.
fn alternateReducedBlockProbeStep(
    grid: *const grid_module.GridState,
    current: []const f64,
    column_component: usize,
    cell: usize,
    nominal: f64,
    primary_step: f64,
    ice_density_megagrams_per_m3: f64,
) f64 {
    if (primary_step == 0) return 0;
    const cells = grid.layer_count;
    const index = column_component * cells + cell;
    const conservation_coefficient: f64 = if (column_component >= 1 and column_component <= 4) 1.0 else 0.0;
    const matrix_air_m3 = @max(0, grid.matrix_pore_capacity_m3[cell] - current[cell] - current[2 * cells + cell] / ice_density_megagrams_per_m3);
    const macropore_air_m3 = @max(0, grid.macropore_pore_capacity_m3[cell] - current[3 * cells + cell] - current[4 * cells + cell] / ice_density_megagrams_per_m3);
    if (primary_step > 0) {
        var negative_limit = current[index];
        if (column_component == 1 or column_component == 3 or column_component == 4)
            negative_limit = @min(negative_limit, matrix_air_m3 / conservation_coefficient);
        return -@min(nominal, 0.5 * negative_limit);
    }

    var positive_limit = if (conservation_coefficient > 0)
        current[cell] / conservation_coefficient
    else
        std.math.inf(f64);
    if (column_component == 2) {
        const physical_expansion_per_m3_we = 1.0 / ice_density_megagrams_per_m3 - 1.0;
        positive_limit = @min(positive_limit, matrix_air_m3 / physical_expansion_per_m3_we);
    }
    if (column_component == 3) positive_limit = @min(positive_limit, macropore_air_m3);
    if (column_component == 4) positive_limit = @min(positive_limit, macropore_air_m3 * ice_density_megagrams_per_m3);
    return @min(nominal, 0.5 * positive_limit);
}

noinline fn recoverCellLocalReducedColumn(
    context: ReducedBlockColumnProbeContext,
    column_component: usize,
    column: usize,
) void {
    const cells = context.grid.layer_count;
    const independent_component = [_]usize{ 1, 2, 3, 4, 5 };
    const conservation_coefficient: f64 = if (column_component >= 1 and column_component <= 4) 1.0 else 0.0;
    for (0..cells) |cell| {
        const fixed_index = cell * independent_components_per_cell + column;
        // A failed batched probe reaches this helper with the Jacobian storage
        // from the preceding nonlinear iteration still intact. Initialize this
        // cell's complete column before either filling it from a valid local
        // probe or leaving it fixed. The fixed-variable row installed by the
        // caller enforces delta=0, but stale/undefined off-row entries can still
        // contain NaN and poison dense elimination before that constraint is
        // resolved.
        for (0..independent_components_per_cell) |row| {
            context.block_jacobian[cell * independent_components_per_cell * independent_components_per_cell + row * independent_components_per_cell + column] = 0;
        }
        if (context.block_coordinate_fixed[fixed_index]) continue;
        const index = column_component * cells + cell;
        const nominal = std.math.cbrt(std.math.floatEps(f64)) * @max(1e-6, @abs(context.current[index]));
        const primary_step = reducedBlockProbeStep(
            context.grid,
            context.current,
            column_component,
            cell,
            nominal,
            context.residual[index],
            context.properties.freeze_thaw.ice_density_megagrams_per_m3,
        );
        const alternate_step = alternateReducedBlockProbeStep(
            context.grid,
            context.current,
            column_component,
            cell,
            nominal,
            primary_step,
            context.properties.freeze_thaw.ice_density_megagrams_per_m3,
        );
        var local_probe_valid = false;
        for ([_]f64{ primary_step, alternate_step }) |initial_step| {
            if (!std.math.isFinite(initial_step) or @abs(initial_step) <= 1e-20) continue;
            var local_step = initial_step;
            for (0..16) |_| {
                @memcpy(context.probe, context.current);
                context.probe[index] += local_step;
                context.probe[cell] -= conservation_coefficient * local_step;
                if (residualAt(
                    context.grid,
                    context.properties,
                    context.base,
                    context.probe,
                    context.target,
                    context.probe_residual,
                    context.scratch,
                    context.trial_heat,
                    context.trial_exchange,
                    context.trial_displacement,
                )) |_| {
                    context.probe_step[cell] = local_step;
                    for (independent_component, 0..) |row_component, row| {
                        const residual_index = row_component * cells + cell;
                        context.block_jacobian[cell * independent_components_per_cell * independent_components_per_cell + row * independent_components_per_cell + column] =
                            (context.probe_residual[residual_index] - context.residual[residual_index]) / local_step;
                    }
                    local_probe_valid = true;
                    break;
                } else |err| {
                    context.last_probe_error.* = err;
                }
                local_step *= 0.5;
            }
            if (local_probe_valid) break;
        }
        if (!local_probe_valid) {
            context.probe_step[cell] = 0;
            context.block_coordinate_fixed[fixed_index] = true;
        }
    }
}

test "reduced phase block alternate probe uses feasible opposite active-set side" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_pore_capacity_m3[0] = 1;
    grid.macropore_pore_capacity_m3[0] = 0;
    const density: f64 = 0.917;
    const state = [_]f64{ 0.25, 1.3e-15, 0, 0, 0, 278.55 };
    const nominal: f64 = 6.0e-12;
    const primary = reducedBlockProbeStep(&grid, &state, 1, 0, nominal, 0, density);
    try std.testing.expectEqual(nominal, primary);
    const alternate = alternateReducedBlockProbeStep(&grid, &state, 1, 0, nominal, primary, density);
    try std.testing.expectEqual(-0.5 * state[1], alternate);
    try std.testing.expect(state[1] + alternate >= 0);
    try std.testing.expect(state[0] - alternate <= grid.matrix_pore_capacity_m3[0]);
}

test "batched phase vapor probe binds every cell to its transactional donor" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    const one = testProperties();
    const bulk = [_]f64{ 2, 1 };
    const curves = [_]retention.ResolvedCurve{ one.retention_curve[0], one.retention_curve[0] };
    const matrix = [_]retention.MualemVanGenuchtenParameters{ one.mualem_van_genuchten_parameters[0], one.mualem_van_genuchten_parameters[0] };
    const macropore = [_]retention.MualemVanGenuchtenParameters{ one.macropore_mualem_van_genuchten_parameters[0], one.macropore_mualem_van_genuchten_parameters[0] };
    const zeros = [_]f64{ 0, 0 };
    const saturation = [_]f64{ -0.0005, -0.0005 };
    const capacity = [_]f64{ 5, 1.63435 };
    const ones = [_]f64{ 1, 1 };
    const spacing = [_]f64{ 1, 1 };
    const radius = [_]f64{ 0.01, 0.01 };
    const disabled = [_]bool{ false, false };
    var properties = one;
    properties.matrix_bulk_volume_m3 = &bulk;
    properties.retention_curve = &curves;
    properties.mualem_van_genuchten_parameters = &matrix;
    properties.macropore_mualem_van_genuchten_parameters = &macropore;
    properties.osmotic_potential_megapascal = &zeros;
    properties.saturation_water_potential_megapascal = &saturation;
    properties.heat_capacity_megajoules_per_k = &capacity;
    properties.saturated_lateral_matrix_conductivity_m2_per_h_megapascal = &ones;
    properties.face_area_m2 = &ones;
    properties.macropore_spacing_m = &spacing;
    properties.macropore_radius_m = &radius;
    properties.pore_exchange_enabled = &disabled;

    grid.matrix_liquid_water_m3[0] = 1;
    grid.matrix_liquid_water_m3[1] = 0.25;
    grid.water_vapor_volume_m3[0] = 0.01;
    grid.water_vapor_volume_m3[1] = 1.3e-15;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.matrix_pore_capacity_m3[1] = 0.25;
    grid.soil_temperature_k[0] = 260;
    grid.soil_temperature_k[1] = 278.55;
    const base = [_]f64{
        1,    0.25,
        0.01, 1.3e-15,
        0,    0,
        0,    0,
        0,    0,
        260,  278.55,
    };
    const current = base;
    var target: [12]f64 = undefined;
    var residual: [12]f64 = undefined;
    var probe = current;
    var probe_residual: [12]f64 = undefined;
    var scratch: [12]f64 = undefined;
    var heat: [2]f64 = undefined;
    var exchange: [2]f64 = undefined;
    var displacement_storage: [10]f64 = undefined;
    const displacement: DisplacementOutputs = .{
        .matrix_liquid_water_m3 = displacement_storage[0..2],
        .matrix_ice_water_equivalent_m3 = displacement_storage[2..4],
        .macropore_liquid_water_m3 = displacement_storage[4..6],
        .macropore_ice_water_equivalent_m3 = displacement_storage[6..8],
        .advective_enthalpy_megajoules = displacement_storage[8..10],
    };
    try residualAt(&grid, properties, &base, &current, &target, &residual, &scratch, &heat, &exchange, displacement);

    var probe_step: [2]f64 = undefined;
    for (0..2) |cell| {
        const index = 2 + cell;
        const nominal = std.math.cbrt(std.math.floatEps(f64)) * @max(1e-6, @abs(current[index]));
        probe_step[cell] = reducedBlockProbeStep(&grid, &current, 1, cell, nominal, residual[index], properties.freeze_thaw.ice_density_megagrams_per_m3);
        probe[index] += probe_step[cell];
        probe[cell] -= probe_step[cell];
    }
    const grid_matrix_before = grid.matrix_liquid_water_m3[1];
    const grid_vapor_before = grid.water_vapor_volume_m3[1];
    try residualAt(&grid, properties, &base, &probe, &target, &probe_residual, &scratch, &heat, &exchange, displacement);
    try std.testing.expect(target[3] >= 0);
    try std.testing.expectEqual(grid_matrix_before, grid.matrix_liquid_water_m3[1]);
    try std.testing.expectEqual(grid_vapor_before, grid.water_vapor_volume_m3[1]);
    try std.testing.expectEqualSlices(f64, &current, &base);
    try std.testing.expectEqual(
        base[1] + base[3] + base[5] + base[7] + base[9],
        target[1] + target[3] + target[5] + target[7] + target[9],
    );
}

test "reduced phase block macropore ice probes respect both pore domains" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    const density: f64 = 0.917;
    grid.matrix_pore_capacity_m3[0] = 1;
    grid.macropore_pore_capacity_m3[0] = 1;

    // A positive macropore-ice coordinate removes matrix liquid, so the full
    // physical ice volume (step/rho), not only ice expansion, enters the other
    // pore domain. The old expansion-only limit admitted an overfilled probe.
    const positive_state = [_]f64{ 0.75, 0.01, 0.25 * density, 0.1, 0.5 * density, 270 };
    const positive_step = reducedBlockProbeStep(&grid, &positive_state, 4, 0, 0.5, 0, density);
    try std.testing.expectApproxEqAbs(0.5 * 0.4 * density, positive_step, 1e-15);
    const positive_matrix_occupancy = positive_state[0] - positive_step + positive_state[2] / density;
    const positive_macropore_occupancy = positive_state[3] + (positive_state[4] + positive_step) / density;
    try std.testing.expect(positive_matrix_occupancy <= grid.matrix_pore_capacity_m3[0]);
    try std.testing.expect(positive_macropore_occupancy <= grid.macropore_pore_capacity_m3[0]);

    // A negative macropore-ice coordinate moves the conserved WE into matrix
    // liquid. The old bound ignored matrix air and overfilled a nearly saturated
    // matrix even though the macropore donor itself was large enough.
    const negative_state = [_]f64{ 0, 0, 0.99 * density, 0.1, 0.2, 270 };
    const negative_step = reducedBlockProbeStep(&grid, &negative_state, 4, 0, 0.1, 0, density);
    try std.testing.expectApproxEqAbs(-0.005, negative_step, 1e-15);
    const negative_matrix_occupancy = negative_state[0] - negative_step + negative_state[2] / density;
    const negative_macropore_occupancy = negative_state[3] + (negative_state[4] + negative_step) / density;
    try std.testing.expect(negative_matrix_occupancy <= grid.matrix_pore_capacity_m3[0]);
    try std.testing.expect(negative_macropore_occupancy <= grid.macropore_pore_capacity_m3[0]);

    grid.matrix_liquid_water_m3[0] = negative_state[0];
    grid.water_vapor_volume_m3[0] = negative_state[1];
    grid.matrix_ice_water_m3[0] = negative_state[2];
    grid.macropore_liquid_water_m3[0] = negative_state[3];
    grid.macropore_ice_water_m3[0] = negative_state[4];
    grid.soil_temperature_k[0] = negative_state[5];
    var target: [6]f64 = undefined;
    var residual: [6]f64 = undefined;
    var scratch: [6]f64 = undefined;
    var latent_heat: [1]f64 = undefined;
    var exchange: [1]f64 = undefined;
    var displacement_storage: [5]f64 = undefined;
    const displacement: DisplacementOutputs = .{
        .matrix_liquid_water_m3 = displacement_storage[0..1],
        .matrix_ice_water_equivalent_m3 = displacement_storage[1..2],
        .macropore_liquid_water_m3 = displacement_storage[2..3],
        .macropore_ice_water_equivalent_m3 = displacement_storage[3..4],
        .advective_enthalpy_megajoules = displacement_storage[4..5],
    };
    try residualAt(&grid, testProperties(), &negative_state, &negative_state, &target, &residual, &scratch, &latent_heat, &exchange, displacement);
    var negative_probe = negative_state;
    negative_probe[4] += negative_step;
    negative_probe[0] -= negative_step;
    try residualAt(&grid, testProperties(), &negative_state, &negative_probe, &target, &residual, &scratch, &latent_heat, &exchange, displacement);
}

test "saturated zero-vapor probe has a nonnegative donor-bounded target" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 1;
    grid.matrix_pore_capacity_m3[0] = 1;
    grid.soil_temperature_k[0] = 280;
    const state = [_]f64{ 1, 0, 0, 0, 0, 280 };
    var target: [6]f64 = undefined;
    var residual: [6]f64 = undefined;
    var probe_residual: [6]f64 = undefined;
    var scratch: [6]f64 = undefined;
    var latent_heat: [1]f64 = undefined;
    var exchange: [1]f64 = undefined;
    var displacement_storage: [5]f64 = undefined;
    const displacement: DisplacementOutputs = .{
        .matrix_liquid_water_m3 = displacement_storage[0..1],
        .matrix_ice_water_equivalent_m3 = displacement_storage[1..2],
        .macropore_liquid_water_m3 = displacement_storage[2..3],
        .macropore_ice_water_equivalent_m3 = displacement_storage[3..4],
        .advective_enthalpy_megajoules = displacement_storage[4..5],
    };
    const properties = testProperties();
    try residualAt(&grid, properties, &state, &state, &target, &residual, &scratch, &latent_heat, &exchange, displacement);

    // A positive conserved probe creates synthetic trial vapor and matching
    // air. The fixed-point image is still owned by the zero-vapor base state,
    // so its equilibrium transfer must not debit that target below zero.
    const nominal: f64 = 1e-6;
    var bounded_probe = state;
    bounded_probe[0] -= nominal;
    bounded_probe[1] += nominal;
    try residualAt(&grid, properties, &state, &bounded_probe, &target, &probe_residual, &scratch, &latent_heat, &exchange, displacement);
    try std.testing.expect(target[1] >= 0);
    try std.testing.expectEqual(state[0] + state[1], target[0] + target[1]);
    try std.testing.expectEqual(@as(f64, 1), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0), grid.water_vapor_volume_m3[0]);
    try std.testing.expectEqual(@as(f64, 0), reducedBlockProbeStep(&grid, &state, 1, 0, nominal, residual[1], properties.freeze_thaw.ice_density_megagrams_per_m3));
    try std.testing.expectEqual(nominal, reducedBlockProbeStep(&grid, &state, 1, 0, nominal, 1.0e-8, properties.freeze_thaw.ice_density_megagrams_per_m3));
}

test "production saturated-layer vapor probe is donor bounded and atomic" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    const base_matrix_water_m3: f64 = 2.556319326265916e-1;
    const base_vapor_m3: f64 = 1.159296462292623e-21;
    const temperature_k: f64 = 2.785507979767238e2;
    grid.matrix_liquid_water_m3[0] = base_matrix_water_m3;
    grid.water_vapor_volume_m3[0] = base_vapor_m3;
    grid.matrix_pore_capacity_m3[0] = base_matrix_water_m3;
    grid.soil_temperature_k[0] = temperature_k;

    const capacity = [_]f64{1.6343864172731903};
    var properties = testProperties();
    properties.heat_capacity_megajoules_per_k = &capacity;
    const base = [_]f64{ base_matrix_water_m3, base_vapor_m3, 0, 0, 0, temperature_k };
    var probe = base;
    const nominal = std.math.cbrt(std.math.floatEps(f64)) * 1.0e-6;
    probe[0] -= nominal;
    probe[1] += nominal;
    const probe_before = probe;
    var target: [6]f64 = undefined;
    var residual: [6]f64 = undefined;
    var scratch: [6]f64 = undefined;
    var latent_heat: [1]f64 = undefined;
    var exchange: [1]f64 = undefined;
    var displacement_storage: [5]f64 = undefined;
    const displacement: DisplacementOutputs = .{
        .matrix_liquid_water_m3 = displacement_storage[0..1],
        .matrix_ice_water_equivalent_m3 = displacement_storage[1..2],
        .macropore_liquid_water_m3 = displacement_storage[2..3],
        .macropore_ice_water_equivalent_m3 = displacement_storage[3..4],
        .advective_enthalpy_megajoules = displacement_storage[4..5],
    };

    try residualAt(&grid, properties, &base, &probe, &target, &residual, &scratch, &latent_heat, &exchange, displacement);
    try std.testing.expect(target[1] >= 0);
    try std.testing.expect(target[1] <= base_vapor_m3);
    try std.testing.expectEqual(base_matrix_water_m3, grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(base_vapor_m3, grid.water_vapor_volume_m3[0]);
    try std.testing.expectEqualSlices(f64, &probe_before, &probe);

    var invalid_probe = probe;
    invalid_probe[5] = -temperature_k;
    try std.testing.expectError(
        error.InvalidSoilPhaseInput,
        residualAt(&grid, properties, &base, &invalid_probe, &target, &residual, &scratch, &latent_heat, &exchange, displacement),
    );
    try std.testing.expectEqual(base_matrix_water_m3, grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(base_vapor_m3, grid.water_vapor_volume_m3[0]);
    try std.testing.expectEqual(temperature_k, grid.soil_temperature_k[0]);
}

/// Apply the independent cell-local Newton blocks with a separate feasible
/// fraction for each cell. Soil cells are uncoupled in this phase residual;
/// forcing every cell to use the smallest globally feasible line fraction
/// lets one saturated active set stall all other cells.
fn addCellFeasibleBlockDirection(
    grid: *const grid_module.GridState,
    current: []const f64,
    direction: []const f64,
    requested_fraction: f64,
    ice_density_megagrams_per_m3: f64,
    output: []f64,
) !void {
    const cells = grid.layer_count;
    if (current.len != 6 * cells or
        direction.len != current.len or
        output.len != current.len or
        !std.math.isFinite(requested_fraction) or
        requested_fraction <= 0)
        return error.InvalidSoilPhaseCandidate;
    @memcpy(output, current);
    for (0..cells) |cell| {
        var fraction = requested_fraction;
        for (0..6) |component| {
            const index = component * cells + cell;
            const delta = direction[index];
            if (!std.math.isFinite(delta)) return error.InvalidSoilPhaseCandidate;
            if (delta < 0)
                fraction = @min(fraction, current[index] / -delta);
        }
        const matrix_occupancy_m3 =
            current[cell] + current[2 * cells + cell] / ice_density_megagrams_per_m3;
        const matrix_occupancy_change_m3 =
            direction[cell] + direction[2 * cells + cell] / ice_density_megagrams_per_m3;
        if (matrix_occupancy_change_m3 > 0)
            fraction = @min(
                fraction,
                @max(0, grid.matrix_pore_capacity_m3[cell] -
                    matrix_occupancy_m3) /
                    matrix_occupancy_change_m3,
            );
        const macropore_occupancy_m3 =
            current[3 * cells + cell] + current[4 * cells + cell] / ice_density_megagrams_per_m3;
        const macropore_occupancy_change_m3 =
            direction[3 * cells + cell] + direction[4 * cells + cell] / ice_density_megagrams_per_m3;
        if (macropore_occupancy_change_m3 > 0)
            fraction = @min(
                fraction,
                @max(0, grid.macropore_pore_capacity_m3[cell] -
                    macropore_occupancy_m3) /
                    macropore_occupancy_change_m3,
            );
        if (!std.math.isFinite(fraction) or fraction < 0)
            return error.InvalidSoilPhaseCandidate;
        // Stay a few ulps inside active constraints so residual evaluation
        // cannot reject an otherwise feasible Newton block after rounding.
        if (fraction < requested_fraction)
            fraction *= 1.0 - 16.0 * std.math.floatEps(f64);
        for (0..6) |component| {
            const index = component * cells + cell;
            output[index] = current[index] + fraction * direction[index];
            if (!std.math.isFinite(output[index]) or
                output[index] < 0 or
                (component == 5 and output[index] <= 0))
                return error.InvalidSoilPhaseCandidate;
        }
    }
}

/// Forward-error bound for one cell's phase residual.
///
/// A component's residual is assembled from that cell's whole water and air
/// inventory: the vapor equilibrium reads matrix water, matrix air, and
/// macropore air, and the freeze-thaw terms read both domains' liquid and ice.
/// Each of those is independently rounded before the residual is formed, so the
/// smallest residual the arithmetic can distinguish is set by the largest of
/// them, not by the component's own magnitude. Without this term a cell whose
/// carriers are ~1e6 m3 can never satisfy a relative tolerance on a vapor
/// volume of ~1 m3: the sub-ULP residual of the large carriers is thousands of
/// times the scale allowed for the small component.
///
/// This mirrors `mass_balance_audit.representationFloorPerArea`, which solves
/// the same problem for the landscape census.
fn cellRepresentationFloorM3(state: []const f64, cells: usize, cell: usize) f64 {
    var largest: f64 = 0;
    // Components zero through four are volumes; five is temperature and is not
    // a carrier of these volume residuals.
    for (0..5) |component| largest = @max(largest, @abs(state[component * cells + cell]));
    return 64.0 * std.math.floatEps(f64) * largest;
}

/// The single merit scale used by convergence, Newton-coordinate selection,
/// and failure diagnostics. Keeping those consumers identical matters for a
/// mixed-unit vector: ranking endpoint temperature with the water-volume floor,
/// or ranking a phase carrier by its inventory instead of its requested
/// correction, can send a semismooth Newton fallback to an equation that does
/// not limit the norm it is required to reduce.
fn scaledResidualAt(base: []const f64, state: []const f64, residual: []const f64, options: Options, index: usize) f64 {
    const cells = state.len / 6;
    const component = index / cells;
    const absolute_tolerance = if (component == 5)
        options.absolute_temperature_tolerance_k
    else
        options.absolute_tolerance_m3;
    const representation_floor = if (component == 5)
        0
    else
        cellRepresentationFloorM3(state, cells, index % cells);
    const requested_change = @max(
        @abs(state[index] - base[index]),
        @abs(state[index] + residual[index] - base[index]),
    );
    const scale = absolute_tolerance +
        options.relative_tolerance * requested_change +
        representation_floor;
    return @abs(residual[index]) / scale;
}

fn largestScaledResidualIndex(base: []const f64, state: []const f64, residual: []const f64, options: Options) !usize {
    if (base.len != state.len or residual.len != state.len or state.len == 0 or state.len % 6 != 0)
        return error.SoilPhaseSolverDimensionMismatch;
    var largest_index: usize = 0;
    var largest_scaled: f64 = -1;
    for (state, residual, 0..) |value, difference, index| {
        if (!std.math.isFinite(base[index]) or !std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference))
            return error.NonFiniteSoilPhaseSolverState;
        const scaled = scaledResidualAt(base, state, residual, options, index);
        if (scaled > largest_scaled) {
            largest_scaled = scaled;
            largest_index = index;
        }
    }
    return largest_index;
}

fn scaledNorm(base: []const f64, state: []const f64, residual: []const f64, options: Options) !f64 {
    if (base.len != state.len or residual.len != state.len or state.len == 0 or state.len % 6 != 0)
        return error.SoilPhaseSolverDimensionMismatch;
    var maximum: f64 = 0;
    for (base, state, residual, 0..) |base_value, value, difference, index| {
        if (!std.math.isFinite(base_value) or !std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference)) return error.NonFiniteSoilPhaseSolverState;
        maximum = @max(maximum, scaledResidualAt(base, state, residual, options, index));
    }
    return maximum;
}

/// issue-068 (numerical-analysis round, 2026-09-20): per-iteration trace of
/// the solve's own global scaled-residual norm, gated identically to every
/// sibling solver's `diagnostic_trace_layer_index` convention (a no-op when
/// unset, which is every production/test call except the one narrow hour
/// window this issue's chain already gates its siblings to). Added to
/// answer this round's specific question -- is the residual trend leading
/// into a `SoilPhaseSolverStagnated` exit monotonically decreasing (iteration-
/// starved), oscillating, or flat (genuinely stuck) -- which the pre-existing
/// terminal-only stagnation log (below) cannot show on its own.
fn logIterationDiagnosticTrace(options: Options, iteration: u16, norm: f64, committable: bool, phase_energy_accepted: bool) void {
    if (builtin.is_test) return;
    const index = options.diagnostic_trace_layer_index orelse return;
    std.log.info(
        "TEMP_DIAGNOSTIC phase solver iteration residual trace (issue-068 numerical-analysis round): trace_index={d} iteration={d} max_iterations={d} scaled_residual={e} committable={} phase_energy_accepted={}",
        .{ index, iteration + 1, options.max_iterations, norm, committable, phase_energy_accepted },
    );
}

/// issue-068 (2026-09-20, seventh-round follow-up): per-cell/per-check trace
/// of `committableState`'s own hard nonnegativity/pore-capacity gate,
/// including `derivedAirVolumeM3`'s inputs/output and the specific failing
/// check's signed margin (negative == infeasible, magnitude == how far past
/// the boundary). The seventh round's own iteration trace above proved the
/// gate stays `false` for 3-4 iterations after the residual norm is already
/// `<=1`, but only reported the aggregate boolean, not which of the ~12
/// flattened cell-layers or which specific check is the blocker. This
/// re-implements `committableState`'s exact checks (never changes them) and
/// only emits a line for a check that actually fails, gated identically to
/// every sibling diagnostic in this file (a no-op unless
/// `diagnostic_trace_layer_index` is set, which is only this issue's own
/// narrow hour-2893-2896/cell-0 window). Called only when the residual norm
/// is already admissible but the aggregate gate is not -- the exact window
/// this round is trying to characterize -- so it never fires for an ordinary
/// committable iteration or an ordinary (non-degenerate) hour.
fn logCommittableStateDiagnosticIfGated(
    options: Options,
    iteration: u16,
    grid: *const grid_module.GridState,
    state: []const f64,
    ice_density_megagrams_per_m3: f64,
) void {
    if (builtin.is_test) return;
    const index = options.diagnostic_trace_layer_index orelse return;
    const cells = grid.layer_count;
    if (state.len != 6 * cells) {
        std.log.warn(
            "TEMP_DIAGNOSTIC phase solver committableState trace (issue-068 seventh round): trace_index={d} iteration={d} state dimension mismatch state_len={d} expected={d}",
            .{ index, iteration + 1, state.len, 6 * cells },
        );
        return;
    }
    for (0..cells) |cell| {
        const layer_scale = grid.matrix_pore_capacity_m3[cell] + grid.macropore_pore_capacity_m3[cell];
        logDerivedAirVolumeDiagnosticIfFailing(
            index,
            iteration,
            cell,
            "matrix",
            grid.matrix_pore_capacity_m3[cell],
            state[cell],
            state[2 * cells + cell],
            ice_density_megagrams_per_m3,
            layer_scale,
        );
        logDerivedAirVolumeDiagnosticIfFailing(
            index,
            iteration,
            cell,
            "macropore",
            grid.macropore_pore_capacity_m3[cell],
            state[3 * cells + cell],
            state[4 * cells + cell],
            ice_density_megagrams_per_m3,
            layer_scale,
        );
        const vapor_m3 = state[1 * cells + cell];
        if (!std.math.isFinite(vapor_m3) or vapor_m3 < 0) {
            std.log.warn(
                "TEMP_DIAGNOSTIC phase solver committableState trace (issue-068 seventh round): trace_index={d} iteration={d} cell={d} check=water_vapor_volume_m3_nonnegativity FAILS water_vapor_volume_m3={e} margin_m3={e}",
                .{ index, iteration + 1, cell, vapor_m3, vapor_m3 },
            );
        }
        const temperature_k = state[5 * cells + cell];
        if (!std.math.isFinite(temperature_k) or temperature_k <= 0 or
            !heat_solver.isPhysicalTemperatureK(temperature_k))
        {
            std.log.warn(
                "TEMP_DIAGNOSTIC phase solver committableState trace (issue-068 seventh round): trace_index={d} iteration={d} cell={d} check=endpoint_temperature_domain FAILS temperature_k={e}",
                .{ index, iteration + 1, cell, temperature_k },
            );
        }
    }
}

/// Re-implements `derivedAirVolumeM3`'s exact checks (never changes them) to
/// report which specific sub-check fails and its signed margin. Silent when
/// every sub-check passes, including the ordinary roundoff-clamped case
/// (`raw_air_m3` slightly negative but within `poreCapacityRoundoffToleranceM3`)
/// -- that path is already accepted by `derivedAirVolumeM3` itself and is not
/// this round's open question.
fn logDerivedAirVolumeDiagnosticIfFailing(
    index: usize,
    iteration: u16,
    cell: usize,
    domain_name: []const u8,
    capacity_m3: f64,
    liquid_m3: f64,
    ice_water_equivalent_m3: f64,
    ice_density_megagrams_per_m3: f64,
    layer_scale_m3: f64,
) void {
    if (!std.math.isFinite(capacity_m3) or capacity_m3 < 0 or
        !std.math.isFinite(layer_scale_m3) or layer_scale_m3 < 0)
    {
        std.log.warn(
            "TEMP_DIAGNOSTIC phase solver committableState trace (issue-068 seventh round): trace_index={d} iteration={d} cell={d} domain={s} check=capacity_or_scale_finite FAILS capacity_m3={e} layer_scale_m3={e}",
            .{ index, iteration + 1, cell, domain_name, capacity_m3, layer_scale_m3 },
        );
        return;
    }
    if (!std.math.isFinite(liquid_m3) or liquid_m3 < 0) {
        std.log.warn(
            "TEMP_DIAGNOSTIC phase solver committableState trace (issue-068 seventh round): trace_index={d} iteration={d} cell={d} domain={s} check=liquid_nonnegativity FAILS liquid_m3={e} margin_m3={e}",
            .{ index, iteration + 1, cell, domain_name, liquid_m3, liquid_m3 },
        );
        return;
    }
    if (!std.math.isFinite(ice_water_equivalent_m3) or ice_water_equivalent_m3 < 0) {
        std.log.warn(
            "TEMP_DIAGNOSTIC phase solver committableState trace (issue-068 seventh round): trace_index={d} iteration={d} cell={d} domain={s} check=ice_water_equivalent_nonnegativity FAILS ice_water_equivalent_m3={e} margin_m3={e}",
            .{ index, iteration + 1, cell, domain_name, ice_water_equivalent_m3, ice_water_equivalent_m3 },
        );
        return;
    }
    const physical_ice_m3 = ice_units.physicalVolumeM3FromWaterEquivalent(ice_water_equivalent_m3, ice_density_megagrams_per_m3) catch {
        std.log.warn(
            "TEMP_DIAGNOSTIC phase solver committableState trace (issue-068 seventh round): trace_index={d} iteration={d} cell={d} domain={s} check=ice_density_conversion FAILS ice_water_equivalent_m3={e} ice_density_megagrams_per_m3={e}",
            .{ index, iteration + 1, cell, domain_name, ice_water_equivalent_m3, ice_density_megagrams_per_m3 },
        );
        return;
    };
    const raw_air_m3 = capacity_m3 - liquid_m3 - physical_ice_m3;
    if (!std.math.isFinite(raw_air_m3)) {
        std.log.warn(
            "TEMP_DIAGNOSTIC phase solver committableState trace (issue-068 seventh round): trace_index={d} iteration={d} cell={d} domain={s} check=raw_air_finite FAILS capacity_m3={e} liquid_m3={e} physical_ice_m3={e}",
            .{ index, iteration + 1, cell, domain_name, capacity_m3, liquid_m3, physical_ice_m3 },
        );
        return;
    }
    const tolerance_m3 = poreCapacityRoundoffToleranceM3(capacity_m3, layer_scale_m3);
    if (raw_air_m3 < -tolerance_m3) {
        // Signed margin: negative == infeasible; magnitude is how far past
        // the roundoff-tolerant boundary this candidate's implied air volume
        // sits (i.e. how much the layer is overfilled beyond what roundoff
        // alone would explain).
        const margin_m3 = raw_air_m3 + tolerance_m3;
        std.log.warn(
            "TEMP_DIAGNOSTIC phase solver committableState trace (issue-068 seventh round): trace_index={d} iteration={d} cell={d} domain={s} check=pore_capacity FAILS capacity_m3={e} liquid_m3={e} physical_ice_m3={e} raw_air_m3={e} tolerance_m3={e} margin_m3={e}",
            .{ index, iteration + 1, cell, domain_name, capacity_m3, liquid_m3, physical_ice_m3, raw_air_m3, tolerance_m3, margin_m3 },
        );
    }
}

test "phase Newton recovery targets the component that limits convergence merit" {
    const options: Options = .{
        .max_iterations = 20,
        .absolute_tolerance_m3 = 1.0e-13,
        .absolute_temperature_tolerance_k = 1.0e-9,
        .relative_tolerance = 1.0e-8,
    };
    const base = [_]f64{ 1.0, 1.0e-7, 0, 0, 0, 280 };
    const state = base;
    const residual = [_]f64{ 0, 2.0e-13, 0, 0, 0, 2.0e-8 };

    // Ranking these mixed-unit coordinates with the old water-floor plus
    // state-magnitude expression chose vapor. The actual convergence norm is
    // temperature-limited, so a local vapor correction cannot reduce it.
    const old_vapor_rank = @abs(residual[1]) /
        (options.absolute_tolerance_m3 + options.relative_tolerance * @abs(state[1]));
    const old_temperature_rank = @abs(residual[5]) /
        (options.absolute_tolerance_m3 + options.relative_tolerance * @abs(state[5]));
    try std.testing.expect(old_vapor_rank > old_temperature_rank);

    const limiting_index = try largestScaledResidualIndex(&base, &state, &residual, options);
    try std.testing.expectEqual(@as(usize, 5), limiting_index);
    try std.testing.expectEqual(
        try scaledNorm(&base, &state, &residual, options),
        scaledResidualAt(&base, &state, &residual, options, limiting_index),
    );
}

test "phase convergence admits sub-ULP carrier roundoff but rejects real error" {
    // A11-PHASE-TOLERANCE-FIXTURE-001. The solver conformance audit flagged
    // these two fixtures as call sites that "override" the file's `1e-14` /
    // `1e-9` defaults up to a blunter `1e-11` / `1e-8`. They are not call sites:
    // both are tests, and no production path reads these literals. What
    // production does pass is the deck's own runtime line, and for the Ottawa
    // deck that line is `runtime,4,1,1e-8,1e-11,100,0.5`, which reaches this
    // solver as `soil/water/heat_step.zig`'s `phase_options`, where
    // `absolute_tolerance_m3` and `absolute_temperature_tolerance_k` are both
    // set from the deck's absolute `1e-11` and `relative_tolerance` from its
    // `1e-8`. These fixtures therefore *reproduce* the production
    // acceptance rather than weaken it, which is the only reason the roundoff
    // case below is a faithful regression test of the Ottawa cell at all.
    // Tightening them to the struct defaults would test a configuration the
    // model is never run in and would stop pinning the shipped behaviour.
    const options: Options = .{
        .max_iterations = 20,
        .absolute_tolerance_m3 = 1e-11,
        .relative_tolerance = 1e-8,
    };
    // The Ottawa hour-12 stagnation: a vapor volume near 1.44 m3 in a cell whose
    // matrix water and ice carriers are ~1.4e5 m3. The residual is 1.57e-10 m3,
    // which is 1.09e-10 of the vapor state and far below the rounding floor of
    // the carriers that produced it.
    const base = [_]f64{ 1.4847370138721637e5, 1.4381965962775536, 1.3078211093884993e5, 5.478311123604301e-4, 2.9426803598478693e2, 261.8846954490114 };
    var state = base;
    state[1] -= 9.548578e-3;
    const residual = [_]f64{ 0, -1.5698331523594788e-10, 0, 0, 0, 0 };
    const norm = try scaledNorm(&base, &state, &residual, options);
    try std.testing.expect(norm <= 1);

    // A residual that is physically meaningful at this cell's scale must still
    // fail. One cubic metre of unexplained vapor is not roundoff.
    const real_error = [_]f64{ 0, 1.0, 0, 0, 0, 0 };
    try std.testing.expect(try scaledNorm(&base, &state, &real_error, options) > 1);

    // The floor is proportional to the carriers, so a small cell keeps a tight
    // convergence requirement: the same absolute residual fails there.
    const small_base = [_]f64{ 0.1, 0.01, 0.02, 0.0, 0.0, 275.0 };
    try std.testing.expect(try scaledNorm(&small_base, &small_base, &residual, options) > 1);
}

test "phase convergence scales material correction independently of inventory size" {
    const options: Options = .{
        .max_iterations = 20,
        .absolute_tolerance_m3 = 1e-11,
        .relative_tolerance = 1e-8,
    };
    const base = [_]f64{ 1e10, 0, 0, 0, 0, 280 };
    const initial = base;
    const material_residual = [_]f64{ 100, 0, 0, 0, 0, 0 };
    const norm = try scaledNorm(&base, &initial, &material_residual, options);
    // A 100 m3 residual is a real material error at any scale and must be
    // rejected by orders of magnitude. The threshold is 1e5 rather than 1e7
    // because the scale now also carries the carrier representation floor,
    // which for a 1e10 m3 inventory is 1.42e-4 m3. That floor is what lets a
    // genuinely sub-ULP residual converge; it is still 700000x smaller than
    // this residual.
    try std.testing.expect(norm > 1e5);
    const converged = try scaledNorm(
        &base,
        &.{ 1e10 + 100, 0, 0, 0, 0, 280 },
        &.{ 5e-7, 0, 0, 0, 0, 5e-11 },
        options,
    );
    try std.testing.expect(converged <= 1);
}

fn validateInputs(grid: *const grid_module.GridState, properties: Properties, outputs: Outputs, options: Options) !void {
    const cells = grid.layer_count;
    inline for (@typeInfo(Properties).@"struct".fields) |field| {
        if (field.type == []const f64) {
            const values = @field(properties, field.name);
            if (comptime std.mem.eql(u8, field.name, "conservation_cell_area_m2")) {
                if (values.len != 0 and values.len != cells)
                    return error.SoilPhaseSolverDimensionMismatch;
            } else if (values.len != cells) {
                return error.SoilPhaseSolverDimensionMismatch;
            }
        }
        if (field.type == []const bool and @field(properties, field.name).len != 0 and @field(properties, field.name).len != cells) return error.SoilPhaseSolverDimensionMismatch;
    }
    if (properties.retention_curve.len != cells) return error.SoilPhaseSolverDimensionMismatch;
    if (properties.conservation_cell_area_m2.len != 0) {
        const conservation_layer_capacity = if (properties.conservation_layer_capacity == 0)
            1
        else
            properties.conservation_layer_capacity;
        if (conservation_layer_capacity == 0 or cells % conservation_layer_capacity != 0)
            return error.SoilPhaseSolverDimensionMismatch;
    }
    if (properties.mualem_van_genuchten_parameters.len != cells or
        properties.macropore_mualem_van_genuchten_parameters.len != cells)
    {
        return error.SoilPhaseSolverDimensionMismatch;
    }
    for (properties.mualem_van_genuchten_parameters) |parameters|
        try parameters.validate();
    for (properties.macropore_mualem_van_genuchten_parameters) |parameters|
        try parameters.validate();
    if (properties.freeze_thaw.ice_density_megagrams_per_m3 <= 0 or properties.freeze_thaw.ice_density_megagrams_per_m3 >= 1) return error.InvalidSoilPhaseInput;
    if (!std.math.isFinite(properties.gravitational_water_potential_mpa_per_m) or
        properties.gravitational_water_potential_mpa_per_m <= 0)
        return error.InvalidSoilPhaseInput;
    if (!std.math.isFinite(properties.liquid_water_heat_capacity_megajoules_per_m3_k) or properties.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or !std.math.isFinite(properties.ice_heat_capacity_megajoules_per_m3_k) or properties.ice_heat_capacity_megajoules_per_m3_k <= 0) return error.InvalidSoilPhaseInput;
    if (!std.math.isFinite(properties.time_step_hours) or properties.time_step_hours <= 0 or properties.time_step_hours > 1) return error.InvalidSoilPhaseInput;
    for (properties.matrix_bulk_volume_m3, properties.retention_curve) |bulk_volume_m3, curve| {
        if (!std.math.isFinite(bulk_volume_m3) or bulk_volume_m3 <= 0) return error.InvalidSoilPhaseInput;
        if (!std.math.isFinite(curve.porosity_fraction) or curve.porosity_fraction <= 0) return error.InvalidSoilPhaseInput;
    }
    if (outputs.latent_heat_megajoules.len != cells or outputs.macropore_to_matrix_water_m3.len != cells) return error.SoilPhaseSolverDimensionMismatch;
    if (outputs.displacement) |displacement| {
        if (displacement.matrix_liquid_water_m3.len != cells or
            displacement.matrix_ice_water_equivalent_m3.len != cells or
            displacement.macropore_liquid_water_m3.len != cells or
            displacement.macropore_ice_water_equivalent_m3.len != cells or
            displacement.advective_enthalpy_megajoules.len != cells)
            return error.SoilPhaseSolverDimensionMismatch;
    }
    if (options.max_iterations == 0 or !options.anderson_recovery_enabled or !std.math.isFinite(options.absolute_tolerance_m3) or options.absolute_tolerance_m3 <= 0 or !std.math.isFinite(options.absolute_temperature_tolerance_k) or options.absolute_temperature_tolerance_k <= 0 or !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or !std.math.isFinite(options.energy_conservation_absolute_tolerance_megajoules_per_m2) or options.energy_conservation_absolute_tolerance_megajoules_per_m2 < 0 or !std.math.isFinite(options.energy_conservation_relative_tolerance) or options.energy_conservation_relative_tolerance <= 0 or !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or !std.math.isFinite(options.directional_probe_fraction) or options.directional_probe_fraction <= 0 or !std.math.isFinite(options.minimum_newton_fraction) or options.minimum_newton_fraction <= 0 or !std.math.isFinite(options.maximum_newton_fraction) or options.maximum_newton_fraction < options.minimum_newton_fraction or options.maximum_newton_fraction > 1) return error.InvalidSoilPhaseSolverOptions;
    // A patience of zero would abort on the first iteration, before any step is
    // taken; a growth factor below one would call an improving norm divergent;
    // an improvement factor outside (0, 1] would either never or always count an
    // iteration as oscillating. All three are configuration errors, not
    // conditions to be silently clamped.
    if (options.divergence_patience == 0 or !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1) return error.InvalidSoilPhaseSolverOptions;
    if (options.oscillation_patience == 0 or !std.math.isFinite(options.oscillation_improvement_factor) or options.oscillation_improvement_factor <= 0 or options.oscillation_improvement_factor > 1) return error.InvalidSoilPhaseSolverOptions;
}

fn testProperties() Properties {
    const values = struct {
        const bulk = [_]f64{2};
        const osmotic = [_]f64{0};
        const curves = [_]retention.ResolvedCurve{.{ .porosity_fraction = 1, .curve = .{ .field_capacity_fraction = 0.6, .wilting_point_fraction = 0.2, .saturation_water_potential_megapascal = -0.0005, .field_capacity_water_potential_megapascal = -0.01, .wilting_point_water_potential_megapascal = -1.5, .minimum_water_potential_megapascal = -1.5e12, .saturation_to_field_shape = 0.5, .below_wilting_shape = 0.5 } }};
        const saturation_potential = [_]f64{-0.0005};
        // Includes a positive dry-solid contribution in addition to water.
        const capacity = [_]f64{5.0};
        const one = [_]f64{1};
        const spacing = [_]f64{1};
        const radius = [_]f64{0.01};
        const disabled = [_]bool{false};
        const matrix = [_]retention.MualemVanGenuchtenParameters{.{
            .residual_water_content_m3_per_m3 = 0.05,
            .saturated_water_content_m3_per_m3 = 1,
            .alpha_per_m = 1.6,
            .n = 1.6,
            .saturated_hydraulic_conductivity_m_per_h = 0.01,
        }};
        const macropore = [_]retention.MualemVanGenuchtenParameters{.{
            .residual_water_content_m3_per_m3 = 0,
            .saturated_water_content_m3_per_m3 = 1,
            .alpha_per_m = 15,
            .n = 2.68,
            .saturated_hydraulic_conductivity_m_per_h = 0.1,
        }};
    };
    return .{ .matrix_bulk_volume_m3 = &values.bulk, .retention_curve = &values.curves, .mualem_van_genuchten_parameters = &values.matrix, .macropore_mualem_van_genuchten_parameters = &values.macropore, .osmotic_potential_megapascal = &values.osmotic, .saturation_water_potential_megapascal = &values.saturation_potential, .heat_capacity_megajoules_per_k = &values.capacity, .saturated_lateral_matrix_conductivity_m2_per_h_megapascal = &values.one, .face_area_m2 = &values.one, .macropore_spacing_m = &values.spacing, .macropore_radius_m = &values.radius, .pore_exchange_enabled = &values.disabled, .vapor = .{ .vapor_density_temperature_coefficient = 2.173e-3, .molecular_weight_ratio = 0.61, .clausius_clapeyron_coefficient_k = 5360, .reference_inverse_temperature_per_k = 3.661e-3, .water_molar_mass_g_per_mol = 18, .gas_constant_j_per_mol_k = 8.3143, .latent_heat_of_vaporization_megajoules_per_m3 = 2450 }, .freeze_thaw = .{ .freezing_potential_numerator_k_megapascal = 9.0959e4, .latent_heat_of_fusion_megajoules_per_m3 = 333, .ice_density_megagrams_per_m3 = 0.917, .heat_capacity_temperature_feedback_per_k = 6.2913e-3, .pure_water_freezing_temperature_k = 273.15 }, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274 / 0.917 };
}

fn dallAmicoTestProperties() Properties {
    const values = struct {
        const matrix = [_]retention.MualemVanGenuchtenParameters{.{
            .residual_water_content_m3_per_m3 = 0.05,
            .saturated_water_content_m3_per_m3 = 0.45,
            .alpha_per_m = 1.6,
            .n = 1.6,
            .saturated_hydraulic_conductivity_m_per_h = 0.01,
        }};
        const macropore = [_]retention.MualemVanGenuchtenParameters{.{
            .residual_water_content_m3_per_m3 = 0,
            .saturated_water_content_m3_per_m3 = 1,
            .alpha_per_m = 15,
            .n = 2.68,
            .saturated_hydraulic_conductivity_m_per_h = 0.1,
        }};
    };
    var properties = testProperties();
    properties.mualem_van_genuchten_parameters = &values.matrix;
    properties.macropore_mualem_van_genuchten_parameters = &values.macropore;
    return properties;
}

test "source FINHL donor depletion remains a convergent fixed point" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.5;
    grid.macropore_liquid_water_m3[0] = 1.0e-5;
    grid.liquid_water_m3[0] = 0.50001;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.macropore_pore_capacity_m3[0] = 0.1;
    grid.soil_temperature_k[0] = 280;

    const exchange_enabled = [_]bool{true};
    var properties = testProperties();
    properties.pore_exchange_enabled = &exchange_enabled;
    const base = [_]f64{ 0.5, 0, 0, 1.0e-5, 0, 280 };
    var trial = base;
    var target: [6]f64 = undefined;
    var residual: [6]f64 = undefined;
    var scratch: [6]f64 = undefined;
    var residual_heat = [_]f64{0};
    var residual_exchange = [_]f64{0};
    var displacement_storage: [5]f64 = undefined;
    const displacement: DisplacementOutputs = .{
        .matrix_liquid_water_m3 = displacement_storage[0..1],
        .matrix_ice_water_equivalent_m3 = displacement_storage[1..2],
        .macropore_liquid_water_m3 = displacement_storage[2..3],
        .macropore_ice_water_equivalent_m3 = displacement_storage[3..4],
        .advective_enthalpy_megajoules = displacement_storage[4..5],
    };

    trial[3] = 0;
    try residualAt(&grid, properties, &base, &trial, &target, &residual, &scratch, &residual_heat, &residual_exchange, displacement);
    const zero_trial_residual = residual[3];
    try std.testing.expectEqual(@as(f64, 0), target[3]);
    try std.testing.expectEqual(@as(f64, 0), zero_trial_residual);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0e-5), residual_exchange[0], 1.0e-15);

    const active_side_epsilon_m3 = 1.0e-8;
    trial[3] = active_side_epsilon_m3;
    try residualAt(&grid, properties, &base, &trial, &target, &residual, &scratch, &residual_heat, &residual_exchange, displacement);
    try std.testing.expectEqual(@as(f64, 0), target[3]);
    try std.testing.expectApproxEqAbs(-active_side_epsilon_m3, residual[3], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -1), (residual[3] - zero_trial_residual) / active_side_epsilon_m3, 1.0e-12);

    var heat_output = [_]f64{0};
    var exchange = [_]f64{0};
    const before_water_m3 = grid.matrix_liquid_water_m3[0] +
        grid.macropore_liquid_water_m3[0] +
        grid.water_vapor_volume_m3[0];

    const result = try solve(
        std.testing.allocator,
        &grid,
        properties,
        .{
            .latent_heat_megajoules = &heat_output,
            .macropore_to_matrix_water_m3 = &exchange,
        },
        .{ .max_iterations = 80 },
    );

    const after_water_m3 = grid.matrix_liquid_water_m3[0] +
        grid.macropore_liquid_water_m3[0] +
        grid.matrix_ice_water_m3[0] +
        grid.macropore_ice_water_m3[0] +
        grid.water_vapor_volume_m3[0];
    try std.testing.expect(result.iterations < 80);
    try std.testing.expect(grid.macropore_liquid_water_m3[0] <= 1.0e-11);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0e-5), exchange[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(before_water_m3, after_water_m3, 1.0e-10);

    exchange[0] = 99;
    _ = try solve(
        std.testing.allocator,
        &grid,
        properties,
        .{
            .latent_heat_megajoules = &heat_output,
            .macropore_to_matrix_water_m3 = &exchange,
        },
        .{ .max_iterations = 80 },
    );
    try std.testing.expectEqual(@as(f64, 0), exchange[0]);
}

test "entry pore contraction displacement is target-owned and conservative" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    const pore_capacity_m3 = 0.25;
    const excess_m3 = 1.0e-8;
    grid.matrix_liquid_water_m3[0] = pore_capacity_m3 + excess_m3;
    grid.liquid_water_m3[0] = grid.matrix_liquid_water_m3[0];
    grid.matrix_pore_capacity_m3[0] = pore_capacity_m3;
    grid.soil_temperature_k[0] = 280;

    var latent_heat = [_]f64{0};
    var pore_exchange = [_]f64{0};
    var matrix_liquid_displacement = [_]f64{0};
    var matrix_ice_displacement = [_]f64{0};
    var macro_liquid_displacement = [_]f64{0};
    var macro_ice_displacement = [_]f64{0};
    var displacement_enthalpy = [_]f64{0};
    const displacement: DisplacementOutputs = .{
        .matrix_liquid_water_m3 = &matrix_liquid_displacement,
        .matrix_ice_water_equivalent_m3 = &matrix_ice_displacement,
        .macropore_liquid_water_m3 = &macro_liquid_displacement,
        .macropore_ice_water_equivalent_m3 = &macro_ice_displacement,
        .advective_enthalpy_megajoules = &displacement_enthalpy,
    };
    const properties = testProperties();
    const base = [_]f64{
        pore_capacity_m3 + excess_m3,
        0,
        0,
        0,
        0,
        280,
    };
    var trial = base;
    var target: [6]f64 = undefined;
    var residual: [6]f64 = undefined;
    var scratch: [6]f64 = undefined;
    const water_trials = [_]f64{
        base[0],
        0.5 * (base[0] + pore_capacity_m3),
        pore_capacity_m3,
    };
    for (water_trials) |water_trial_m3| {
        trial = base;
        trial[0] = water_trial_m3;
        try residualAt(
            &grid,
            properties,
            &base,
            &trial,
            &target,
            &residual,
            &scratch,
            &latent_heat,
            &pore_exchange,
            displacement,
        );
        try std.testing.expectApproxEqAbs(pore_capacity_m3, target[0], 1.0e-15);
        try std.testing.expectApproxEqAbs(pore_capacity_m3 - water_trial_m3, residual[0], 1.0e-15);
        try std.testing.expectApproxEqAbs(excess_m3, matrix_liquid_displacement[0], 1.0e-15);
        try std.testing.expectEqual(
            matrix_liquid_displacement[0] * 4.19 * base[5],
            displacement_enthalpy[0],
        );
    }
    const before_water_m3 = grid.matrix_liquid_water_m3[0];

    const result = try solve(
        std.testing.allocator,
        &grid,
        properties,
        .{
            .latent_heat_megajoules = &latent_heat,
            .macropore_to_matrix_water_m3 = &pore_exchange,
            .displacement = displacement,
        },
        .{ .max_iterations = 40 },
    );

    try std.testing.expect(result.iterations < 40);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_recovery_steps);
    try std.testing.expectApproxEqAbs(pore_capacity_m3, grid.matrix_liquid_water_m3[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(excess_m3, matrix_liquid_displacement[0], 1.0e-15);
    try std.testing.expectEqual(@as(f64, 0), matrix_ice_displacement[0]);
    try std.testing.expectApproxEqAbs(
        before_water_m3,
        grid.matrix_liquid_water_m3[0] + matrix_liquid_displacement[0],
        1.0e-15,
    );
    try std.testing.expectApproxEqAbs(
        matrix_liquid_displacement[0] * 4.19 * 280,
        displacement_enthalpy[0],
        1.0e-15,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 280), grid.soil_temperature_k[0], 1.0e-12);
}

test "phase solver binds source-order matrix freezing and closes water plus latent energy" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 1;
    grid.water_vapor_volume_m3[0] = 0.01;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.soil_temperature_k[0] = 260;
    var heat_output = [_]f64{0};
    var exchange = [_]f64{0};
    const before = grid.matrix_liquid_water_m3[0] + grid.matrix_ice_water_m3[0] + grid.water_vapor_volume_m3[0];
    const result = try solve(std.testing.allocator, &grid, testProperties(), .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange }, .{ .max_iterations = 40 });
    const after = grid.matrix_liquid_water_m3[0] + grid.matrix_ice_water_m3[0] + grid.water_vapor_volume_m3[0];
    try std.testing.expect(result.iterations < 40);
    try std.testing.expectApproxEqAbs(before, after, 1e-10);
    try std.testing.expect(grid.matrix_ice_water_m3[0] > 0);
    try std.testing.expect(grid.matrix_liquid_water_m3[0] < 1);
    const expected_latent = 2450 * (0.01 - grid.water_vapor_volume_m3[0]) +
        333 * grid.matrix_ice_water_m3[0];
    try std.testing.expectApproxEqAbs(expected_latent, heat_output[0], 1e-11);
    const expected_temperature = try phase.endpointTemperatureFromPhaseEnthalpy(
        260,
        5,
        .{ .matrix_liquid_water_m3 = 1, .water_vapor_volume_m3 = 0.01, .matrix_ice_volume_m3 = 0, .macropore_liquid_water_m3 = 0, .macropore_ice_volume_m3 = 0 },
        .{ .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3[0], .water_vapor_volume_m3 = grid.water_vapor_volume_m3[0], .matrix_ice_volume_m3 = grid.matrix_ice_water_m3[0], .macropore_liquid_water_m3 = grid.macropore_liquid_water_m3[0], .macropore_ice_volume_m3 = grid.macropore_ice_water_m3[0] },
        0,
        .{ .liquid_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274 / 0.917, .vaporization_latent_heat_megajoules_per_m3 = 2450, .fusion_latent_heat_megajoules_per_m3 = 333 },
    );
    try std.testing.expectApproxEqAbs(expected_temperature, grid.soil_temperature_k[0], 1e-9);
}

test "phase recovery traces Newton Anderson Newton and rejects the final slot atomically" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 1;
    grid.water_vapor_volume_m3[0] = 0.01;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.soil_temperature_k[0] = 260;
    const before_liquid = grid.matrix_liquid_water_m3[0];
    const before_vapor = grid.water_vapor_volume_m3[0];
    const before_temperature = grid.soil_temperature_k[0];
    var heat_output = [_]f64{0};
    var exchange = [_]f64{0};

    var final_slot_control: TestControl = .{ .forced_initial_newton_failures = 1 };
    try std.testing.expectError(error.SoilPhaseSolverDidNotConverge, solveControlled(std.testing.allocator, &grid, testProperties(), .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange }, .{ .max_iterations = 1 }, &final_slot_control));
    try std.testing.expectEqual(before_liquid, grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(before_vapor, grid.water_vapor_volume_m3[0]);
    try std.testing.expectEqual(before_temperature, grid.soil_temperature_k[0]);
    try std.testing.expectEqual(@as(usize, 1), final_slot_control.event_count);

    var control: TestControl = .{ .forced_initial_newton_failures = 1 };
    const result = try solveControlled(std.testing.allocator, &grid, testProperties(), .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange }, .{ .max_iterations = 40 }, &control);
    try std.testing.expect(result.anderson_recovery_steps > 0);
    try std.testing.expect(control.event_count >= 3);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[0]);
    try std.testing.expectEqual(MethodEvent.anderson_accept, control.events[1]);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[2]);
}

test "source-order depressed matrix freezing remains active with production retention parameters" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    const properties = dallAmicoTestProperties();
    grid.matrix_liquid_water_m3[0] = try properties.mualem_van_genuchten_parameters[0].waterContentAtPressureHead(-2) * properties.matrix_bulk_volume_m3[0];
    grid.water_vapor_volume_m3[0] = 1.0e-5;
    grid.matrix_pore_capacity_m3[0] = properties.mualem_van_genuchten_parameters[0].saturated_water_content_m3_per_m3 * properties.matrix_bulk_volume_m3[0];
    grid.soil_temperature_k[0] = 268;
    const before = grid.matrix_liquid_water_m3[0] + grid.matrix_ice_water_m3[0] + grid.water_vapor_volume_m3[0];
    var heat_output = [_]f64{0};
    var exchange = [_]f64{0};
    const result = try solve(std.testing.allocator, &grid, properties, .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange }, .{ .max_iterations = 80 });
    const after = grid.matrix_liquid_water_m3[0] + grid.matrix_ice_water_m3[0] + grid.water_vapor_volume_m3[0];
    try std.testing.expect(result.iterations < 80);
    try std.testing.expectApproxEqAbs(before, after, 1e-10);
    try std.testing.expect(grid.matrix_ice_water_m3[0] > 0);
    try std.testing.expect(grid.matrix_liquid_water_m3[0] < before);
    try std.testing.expect(grid.matrix_liquid_water_m3[0] >= properties.mualem_van_genuchten_parameters[0].residual_water_content_m3_per_m3 * properties.matrix_bulk_volume_m3[0]);
}

test "source-order matrix thaw consumes ice donor and conserves water equivalent" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.4;
    grid.matrix_ice_water_m3[0] = 0.2;
    grid.liquid_water_m3[0] = 0.4;
    grid.ice_water_m3[0] = 0.2;
    grid.water_vapor_volume_m3[0] = 1e-5;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.soil_temperature_k[0] = 280;
    const before = grid.matrix_liquid_water_m3[0] + grid.matrix_ice_water_m3[0] + grid.water_vapor_volume_m3[0];
    var heat_output = [_]f64{0};
    var exchange = [_]f64{0};
    _ = try solve(std.testing.allocator, &grid, testProperties(), .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange }, .{ .max_iterations = 80 });
    const after = grid.matrix_liquid_water_m3[0] + grid.matrix_ice_water_m3[0] + grid.water_vapor_volume_m3[0];
    try std.testing.expect(grid.matrix_ice_water_m3[0] < 0.2);
    try std.testing.expect(grid.matrix_liquid_water_m3[0] > 0.4);
    try std.testing.expectApproxEqAbs(before, after, 1e-10);
    try std.testing.expectApproxEqAbs(
        2450 * (1e-5 - grid.water_vapor_volume_m3[0]) +
            333 * (grid.matrix_ice_water_m3[0] - 0.2),
        heat_output[0],
        1e-10,
    );
}

test "source-order macropore freezing is bound and conserves both pore domains" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.5;
    grid.macropore_liquid_water_m3[0] = 0.25;
    grid.liquid_water_m3[0] = 0.75;
    grid.water_vapor_volume_m3[0] = 1e-5;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.macropore_pore_capacity_m3[0] = 0.5;
    grid.soil_temperature_k[0] = 260;
    const before = grid.matrix_liquid_water_m3[0] + grid.macropore_liquid_water_m3[0] + grid.water_vapor_volume_m3[0];
    var heat_output = [_]f64{0};
    var exchange = [_]f64{0};
    _ = try solve(std.testing.allocator, &grid, testProperties(), .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange }, .{ .max_iterations = 100 });
    const after = grid.matrix_liquid_water_m3[0] + grid.macropore_liquid_water_m3[0] + grid.matrix_ice_water_m3[0] + grid.macropore_ice_water_m3[0] + grid.water_vapor_volume_m3[0];
    try std.testing.expect(grid.matrix_ice_water_m3[0] > 0);
    try std.testing.expect(grid.macropore_ice_water_m3[0] > 0);
    try std.testing.expect(grid.macropore_liquid_water_m3[0] < 0.25);
    try std.testing.expectApproxEqAbs(before, after, 1e-10);
    try std.testing.expect(grid.macropore_liquid_water_m3[0] + grid.macropore_ice_water_m3[0] / 0.917 <= grid.macropore_pore_capacity_m3[0] + 1e-12);
}

test "saturated freezing emits explicit conservative displacement and fails closed when unbound" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 1;
    grid.liquid_water_m3[0] = 1;
    grid.matrix_pore_capacity_m3[0] = 1;
    grid.soil_temperature_k[0] = 260;
    var heat_output = [_]f64{99};
    var exchange = [_]f64{88};
    try std.testing.expectError(error.UnboundSoilPhaseDisplacement, solve(std.testing.allocator, &grid, testProperties(), .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange }, .{ .max_iterations = 40 }));
    try std.testing.expectEqual(@as(f64, 1), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0), grid.matrix_ice_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 99), heat_output[0]);
    try std.testing.expectEqual(@as(f64, 88), exchange[0]);

    var matrix_liquid_displacement = [_]f64{0};
    var matrix_ice_displacement = [_]f64{0};
    var macro_liquid_displacement = [_]f64{0};
    var macro_ice_displacement = [_]f64{0};
    var displacement_enthalpy = [_]f64{0};
    const displacement: DisplacementOutputs = .{
        .matrix_liquid_water_m3 = &matrix_liquid_displacement,
        .matrix_ice_water_equivalent_m3 = &matrix_ice_displacement,
        .macropore_liquid_water_m3 = &macro_liquid_displacement,
        .macropore_ice_water_equivalent_m3 = &macro_ice_displacement,
        .advective_enthalpy_megajoules = &displacement_enthalpy,
    };
    const before_water_equivalent_m3: f64 = 1;
    _ = try solve(std.testing.allocator, &grid, testProperties(), .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange, .displacement = displacement }, .{ .max_iterations = 80 });
    try std.testing.expect(grid.matrix_ice_water_m3[0] > 0);
    try std.testing.expect(matrix_liquid_displacement[0] > 0);
    try std.testing.expectEqual(@as(f64, 0), matrix_ice_displacement[0]);
    try std.testing.expectEqual(@as(f64, 0), macro_liquid_displacement[0]);
    try std.testing.expectEqual(@as(f64, 0), macro_ice_displacement[0]);
    const after_water_equivalent_m3 = grid.matrix_liquid_water_m3[0] +
        grid.matrix_ice_water_m3[0] + matrix_liquid_displacement[0];
    try std.testing.expectApproxEqAbs(before_water_equivalent_m3, after_water_equivalent_m3, 1e-10);
    const occupancy_m3 = grid.matrix_liquid_water_m3[0] +
        grid.matrix_ice_water_m3[0] / 0.917;
    try std.testing.expect(occupancy_m3 <= grid.matrix_pore_capacity_m3[0] + 1e-12);
    // WATSUB 3687-3691 books convective heat at the donor temperature that
    // exists before this transfer; the warmed phase endpoint is not the donor.
    try std.testing.expectApproxEqAbs(
        matrix_liquid_displacement[0] * 4.19 * 260,
        displacement_enthalpy[0],
        1e-9,
    );
    const initial_capacity: f64 = 5;
    const initial_solid_capacity = initial_capacity - 4.19;
    const endpoint_capacity = initial_solid_capacity +
        4.19 * grid.matrix_liquid_water_m3[0] +
        (1.9274 / 0.917) * grid.matrix_ice_water_m3[0];
    try std.testing.expectApproxEqAbs(
        initial_capacity * 260 + 333 * grid.matrix_ice_water_m3[0] -
            displacement_enthalpy[0],
        endpoint_capacity * grid.soil_temperature_k[0],
        1e-8,
    );
}

test "rejected phase solve leaves grid and outputs unchanged" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 1;
    grid.water_vapor_volume_m3[0] = 0.01;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.soil_temperature_k[0] = 260;
    var heat_output = [_]f64{99};
    var exchange = [_]f64{88};
    try std.testing.expectError(error.InvalidSoilPhaseSolverOptions, solve(std.testing.allocator, &grid, testProperties(), .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange }, .{ .max_iterations = 0 }));
    try std.testing.expectEqual(@as(f64, 1), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 99), heat_output[0]);
    try std.testing.expectEqual(@as(f64, 88), exchange[0]);
}

test "non-finite phase input rolls back every carrier and sidecar" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.5;
    grid.matrix_ice_water_m3[0] = 0.1;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.soil_temperature_k[0] = std.math.nan(f64);
    var heat_output = [_]f64{91};
    var exchange = [_]f64{92};
    var matrix_liquid_displacement = [_]f64{93};
    var matrix_ice_displacement = [_]f64{94};
    var macro_liquid_displacement = [_]f64{95};
    var macro_ice_displacement = [_]f64{96};
    var displacement_enthalpy = [_]f64{97};
    try std.testing.expectError(error.NonFiniteSoilPhaseInput, solve(std.testing.allocator, &grid, testProperties(), .{
        .latent_heat_megajoules = &heat_output,
        .macropore_to_matrix_water_m3 = &exchange,
        .displacement = .{
            .matrix_liquid_water_m3 = &matrix_liquid_displacement,
            .matrix_ice_water_equivalent_m3 = &matrix_ice_displacement,
            .macropore_liquid_water_m3 = &macro_liquid_displacement,
            .macropore_ice_water_equivalent_m3 = &macro_ice_displacement,
            .advective_enthalpy_megajoules = &displacement_enthalpy,
        },
    }, .{ .max_iterations = 40 }));
    try std.testing.expectEqual(@as(f64, 0.5), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.1), grid.matrix_ice_water_m3[0]);
    try std.testing.expect(std.math.isNan(grid.soil_temperature_k[0]));
    try std.testing.expectEqual(@as(f64, 91), heat_output[0]);
    try std.testing.expectEqual(@as(f64, 92), exchange[0]);
    try std.testing.expectEqual(@as(f64, 93), matrix_liquid_displacement[0]);
    try std.testing.expectEqual(@as(f64, 94), matrix_ice_displacement[0]);
    try std.testing.expectEqual(@as(f64, 95), macro_liquid_displacement[0]);
    try std.testing.expectEqual(@as(f64, 96), macro_ice_displacement[0]);
    try std.testing.expectEqual(@as(f64, 97), displacement_enthalpy[0]);
}

test "phase watch reports divergence only after sustained growth past the best norm" {
    const options: Options = .{ .max_iterations = 40, .divergence_patience = 3, .divergence_growth_factor = 1.0e3 };
    var watch: ResidualWatch = .{};
    // A norm that improves, then grows enormously. Two counted iterations are
    // not enough; the third reaches the patience.
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(1.0e3, false, options));
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(1.0e2, false, options));
    try std.testing.expectEqual(@as(f64, 1.0e2), watch.best_norm);
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(1.0e8, false, options));
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(1.0e8, false, options));
    try std.testing.expectEqual(ResidualWatch.Verdict.diverged, watch.observe(1.0e8, false, options));
}

test "phase slow-Newton forecast preserves the hard acceptance gate" {
    try std.testing.expect(slowNewtonProgressNeedsRecovery(
        2000,
        1400,
        4,
        7,
    ));
    try std.testing.expect(!slowNewtonProgressNeedsRecovery(
        1.0e6,
        100,
        4,
        7,
    ));
    try std.testing.expect(!slowNewtonProgressNeedsRecovery(
        2000,
        1400,
        4,
        1,
    ));
    try std.testing.expect(!slowNewtonProgressNeedsRecovery(
        2000,
        1,
        4,
        7,
    ));
}

test "phase watch requires consecutive explosive residuals" {
    const options: Options = .{ .max_iterations = 40, .divergence_patience = 2 };
    var watch: ResidualWatch = .{};
    // A norm merely failing to improve is not divergence: nothing exceeds
    // `divergence_growth_factor` times the best, so the stagnation exit and the
    // iteration ceiling remain the only ways such a solve can end.
    for (0..8) |_| try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(5.0, false, options));
    // A single excursion is forgiven both by a neutral-band recovery and by a
    // new best. Only consecutive explosive observations reach the patience.
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(1.0e6, false, options));
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(50.0, false, options));
    try std.testing.expectEqual(@as(u16, 0), watch.non_improving_steps);
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(1.0e6, false, options));
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(4.0, false, options));
    try std.testing.expectEqual(@as(u16, 0), watch.non_improving_steps);
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(1.0e6, false, options));
    try std.testing.expectEqual(ResidualWatch.Verdict.diverged, watch.observe(1.0e6, false, options));
}

test "phase watch reports a two-cycle that removes no residual" {
    const options: Options = .{ .max_iterations = 40, .oscillation_patience = 3 };
    var watch: ResidualWatch = .{};
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(10.0, false, options));
    // The iterate has returned to where it was two recovery iterations ago and
    // the norm has improved by far less than the improvement factor demands.
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(10.0 - 1.0e-9, true, options));
    try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(10.0 - 2.0e-9, true, options));
    try std.testing.expectEqual(ResidualWatch.Verdict.oscillating, watch.observe(10.0 - 3.0e-9, true, options));
}

test "phase watch does not call a repeated iterate oscillating while it converges" {
    const options: Options = .{ .max_iterations = 40, .oscillation_patience = 2 };
    var watch: ResidualWatch = .{};
    // Both conditions are required. A solve that halves its norm every step is
    // making progress even if the coincidence test fires, so it is never cut off.
    var norm: f64 = 1.0e6;
    for (0..30) |_| {
        try std.testing.expectEqual(ResidualWatch.Verdict.progressing, watch.observe(norm, true, options));
        norm *= 0.5;
    }
}

test "phase iterate coincidence is per-component and scale relative" {
    const state = [_]f64{ 1.4847370138721637e5, 1.4381965962775536, 0, 0, 0, 261.8846954490114 };
    var same = state;
    // A few ULP of the largest carrier is the same point.
    same[0] = std.math.nextAfter(f64, std.math.nextAfter(f64, state[0], 1.0e30), 1.0e30);
    try std.testing.expect(iteratesCoincide(&same, &state));
    // A change that the convergence test would still call a real residual is
    // not the same point, even though it is tiny next to the carrier.
    var moved = state;
    moved[1] += 1.0e-6;
    try std.testing.expect(!iteratesCoincide(&moved, &state));
}

test "phase solver rejects unusable watch settings instead of clamping them" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 1;
    grid.water_vapor_volume_m3[0] = 0.01;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.soil_temperature_k[0] = 260;
    var heat_output = [_]f64{0};
    var exchange = [_]f64{0};
    const outputs: Outputs = .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange };
    const rejected = [_]Options{
        .{ .max_iterations = 20, .divergence_patience = 0 },
        .{ .max_iterations = 20, .divergence_growth_factor = 0.5 },
        .{ .max_iterations = 20, .divergence_growth_factor = std.math.nan(f64) },
        .{ .max_iterations = 20, .oscillation_patience = 0 },
        .{ .max_iterations = 20, .oscillation_improvement_factor = 0 },
        .{ .max_iterations = 20, .oscillation_improvement_factor = 1.5 },
        .{ .max_iterations = 20, .oscillation_improvement_factor = std.math.nan(f64) },
    };
    for (rejected) |options|
        try std.testing.expectError(error.InvalidSoilPhaseSolverOptions, solve(std.testing.allocator, &grid, testProperties(), outputs, options));
    // The rejections are not a blanket refusal: the same deck with a growth
    // factor of exactly one, the tightest defensible setting, still solves.
    _ = try solve(std.testing.allocator, &grid, testProperties(), outputs, .{ .max_iterations = 40, .divergence_growth_factor = 1 });
}

test "phase solver requires Anderson recovery and preserves freeze-thaw fixed points" {
    const cases = [_]struct { temperature_k: f64, dall_amico: bool, max_iterations: u16 }{
        .{ .temperature_k = 260, .dall_amico = false, .max_iterations = 40 },
        .{ .temperature_k = 268, .dall_amico = true, .max_iterations = 80 },
        .{ .temperature_k = 272.9, .dall_amico = true, .max_iterations = 100 },
        .{ .temperature_k = 273.14, .dall_amico = false, .max_iterations = 100 },
    };
    for (cases) |case| {
        const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
        const properties = if (case.dall_amico) dallAmicoTestProperties() else testProperties();
        var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
        defer grid.deinit();
        grid.matrix_liquid_water_m3[0] = if (case.dall_amico)
            try properties.mualem_van_genuchten_parameters[0].waterContentAtPressureHead(-2) * properties.matrix_bulk_volume_m3[0]
        else
            1;
        grid.water_vapor_volume_m3[0] = 0.01;
        grid.matrix_pore_capacity_m3[0] = 2;
        grid.soil_temperature_k[0] = case.temperature_k;
        var heat_output = [_]f64{0};
        var exchange = [_]f64{0};
        _ = try solve(std.testing.allocator, &grid, properties, .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange }, .{ .max_iterations = case.max_iterations });
    }
}

test "phase solver rejects disabled Anderson recovery" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 1;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.soil_temperature_k[0] = 268;
    var heat_output = [_]f64{0};
    var exchange = [_]f64{0};
    try std.testing.expectError(error.InvalidSoilPhaseSolverOptions, solve(std.testing.allocator, &grid, testProperties(), .{ .latent_heat_megajoules = &heat_output, .macropore_to_matrix_water_m3 = &exchange }, .{ .max_iterations = 20, .anderson_recovery_enabled = false }));
}

/// Everything one direct `attemptAndersonRecovery` call needs. The forced
/// end-to-end test above proves the production flow Newton -> Anderson ->
/// Newton; these fixtures separately pin the acceleration arithmetic and its
/// strict merit guard.
const RecoveryFixture = struct {
    grid: grid_module.GridState,
    properties: Properties,
    base: []f64,
    current: []f64,
    residual: []f64,
    previous_state: []f64,
    previous_residual: []f64,
    target: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    scratch: []f64,
    trial_heat: []f64,
    trial_exchange: []f64,
    trial_displacement_storage: []f64,
    trial_displacement: DisplacementOutputs,
    cells: usize,

    fn init(temperature_k: f64) !RecoveryFixture {
        const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
        var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
        grid.matrix_liquid_water_m3[0] = 1;
        grid.water_vapor_volume_m3[0] = 0.01;
        grid.matrix_pore_capacity_m3[0] = 2;
        grid.soil_temperature_k[0] = temperature_k;
        const cells = grid.layer_count;
        const components = cells * 6;
        const base = try std.testing.allocator.alloc(f64, components);
        @memcpy(base[0 * cells .. 1 * cells], grid.matrix_liquid_water_m3);
        @memcpy(base[1 * cells .. 2 * cells], grid.water_vapor_volume_m3);
        @memcpy(base[2 * cells .. 3 * cells], grid.matrix_ice_water_m3);
        @memcpy(base[3 * cells .. 4 * cells], grid.macropore_liquid_water_m3);
        @memcpy(base[4 * cells .. 5 * cells], grid.macropore_ice_water_m3);
        @memcpy(base[5 * cells .. 6 * cells], grid.soil_temperature_k);
        const trial_displacement_storage = try std.testing.allocator.alloc(f64, 5 * cells);
        return .{
            .grid = grid,
            .properties = testProperties(),
            .base = base,
            .current = try std.testing.allocator.dupe(f64, base),
            .residual = try std.testing.allocator.alloc(f64, components),
            .previous_state = try std.testing.allocator.alloc(f64, components),
            .previous_residual = try std.testing.allocator.alloc(f64, components),
            .target = try std.testing.allocator.alloc(f64, components),
            .candidate = try std.testing.allocator.alloc(f64, components),
            .candidate_residual = try std.testing.allocator.alloc(f64, components),
            .scratch = try std.testing.allocator.alloc(f64, components),
            .trial_heat = try std.testing.allocator.alloc(f64, cells),
            .trial_exchange = try std.testing.allocator.alloc(f64, cells),
            .trial_displacement_storage = trial_displacement_storage,
            .trial_displacement = .{
                .matrix_liquid_water_m3 = trial_displacement_storage[0 * cells .. 1 * cells],
                .matrix_ice_water_equivalent_m3 = trial_displacement_storage[1 * cells .. 2 * cells],
                .macropore_liquid_water_m3 = trial_displacement_storage[2 * cells .. 3 * cells],
                .macropore_ice_water_equivalent_m3 = trial_displacement_storage[3 * cells .. 4 * cells],
                .advective_enthalpy_megajoules = trial_displacement_storage[4 * cells .. 5 * cells],
            },
            .cells = cells,
        };
    }

    fn deinit(self: *RecoveryFixture) void {
        std.testing.allocator.free(self.base);
        std.testing.allocator.free(self.current);
        std.testing.allocator.free(self.residual);
        std.testing.allocator.free(self.previous_state);
        std.testing.allocator.free(self.previous_residual);
        std.testing.allocator.free(self.target);
        std.testing.allocator.free(self.candidate);
        std.testing.allocator.free(self.candidate_residual);
        std.testing.allocator.free(self.scratch);
        std.testing.allocator.free(self.trial_heat);
        std.testing.allocator.free(self.trial_exchange);
        std.testing.allocator.free(self.trial_displacement_storage);
        self.grid.deinit();
    }

    fn context(self: *RecoveryFixture, options: Options) RecoveryContext {
        return .{ .grid = &self.grid, .properties = self.properties, .base = self.base, .target = self.target, .candidate = self.candidate, .candidate_residual = self.candidate_residual, .scratch = self.scratch, .trial_heat = self.trial_heat, .trial_exchange = self.trial_exchange, .trial_displacement = self.trial_displacement, .options = options };
    }

    fn residualAtCurrent(self: *RecoveryFixture) !void {
        try residualAt(&self.grid, self.properties, self.base, self.current, self.target, self.residual, self.scratch, self.trial_heat, self.trial_exchange, self.trial_displacement);
    }

    /// Advances `current` by one full Picard step, leaving the pre-step iterate
    /// and its residual in the depth-one history. Two genuine consecutive
    /// iterates of the real residual are what the mixing is defined over;
    /// hand-written history vectors would test arithmetic against itself.
    fn takePicardStep(self: *RecoveryFixture) !void {
        try self.residualAtCurrent();
        @memcpy(self.previous_state, self.current);
        @memcpy(self.previous_residual, self.residual);
        for (self.current, self.residual) |*value, difference| value.* += difference;
        try self.residualAtCurrent();
    }
};

test "phase Anderson recovery accepts a real extrapolation and strictly lowers the norm" {
    const options: Options = .{ .max_iterations = 40 };
    var fixture = try RecoveryFixture.init(260);
    defer fixture.deinit();
    try fixture.takePicardStep();
    const norm_before = try scaledNorm(fixture.base, fixture.current, fixture.residual, options);
    var entry_state: [6]f64 = undefined;
    @memcpy(&entry_state, fixture.current);
    const accepted = attemptAndersonRecovery(fixture.context(options), fixture.cells, fixture.current, fixture.residual, fixture.previous_state, fixture.previous_residual, fixture.previous_state, fixture.previous_residual, 1, norm_before);
    try std.testing.expect(accepted);
    // The recovery must have moved the iterate, and the move must be a strict
    // decrease of the same scaled norm the rest of the cascade is judged by.
    try std.testing.expect(!std.mem.eql(f64, &entry_state, fixture.current));
    try fixture.residualAtCurrent();
    try std.testing.expect(try scaledNorm(fixture.base, fixture.current, fixture.residual, options) < norm_before);
    for (fixture.current, 0..) |value, index| {
        try std.testing.expect(std.math.isFinite(value));
        if (index >= 5 * fixture.cells) try std.testing.expect(value > 0) else try std.testing.expect(value >= 0);
    }
}

test "phase Anderson recovery leaves the iterate alone when it cannot improve it" {
    const options: Options = .{ .max_iterations = 40 };
    var fixture = try RecoveryFixture.init(260);
    defer fixture.deinit();
    try fixture.takePicardStep();
    const norm_before = try scaledNorm(fixture.base, fixture.current, fixture.residual, options);
    var entry_state: [6]f64 = undefined;
    @memcpy(&entry_state, fixture.current);
    // A history whose residual never changed carries no secant information: the
    // depth-one denominator vanishes and the recovery must decline rather than
    // divide by it.
    @memcpy(fixture.previous_residual, fixture.residual);
    try std.testing.expect(!attemptAndersonRecovery(fixture.context(options), fixture.cells, fixture.current, fixture.residual, fixture.previous_state, fixture.previous_residual, fixture.previous_state, fixture.previous_residual, 1, norm_before));
    try std.testing.expectEqualSlices(f64, &entry_state, fixture.current);
    // The acceptance guard is a *strict* decrease, so the exact norm the
    // candidate achieves must itself be declined. Discovering that norm first
    // (by offering an unreachable one) and then offering it back is what pins
    // the comparison as strict; a test that only offers zero would still pass
    // against an arbitrarily slack guard.
    var second_fixture = try RecoveryFixture.init(260);
    defer second_fixture.deinit();
    try second_fixture.takePicardStep();
    var second_entry: [6]f64 = undefined;
    @memcpy(&second_entry, second_fixture.current);
    try std.testing.expect(attemptAndersonRecovery(second_fixture.context(options), second_fixture.cells, second_fixture.current, second_fixture.residual, second_fixture.previous_state, second_fixture.previous_residual, second_fixture.previous_state, second_fixture.previous_residual, 1, std.math.inf(f64)));
    try second_fixture.residualAtCurrent();
    const achieved_norm = try scaledNorm(second_fixture.base, second_fixture.current, second_fixture.residual, options);
    try std.testing.expect(std.math.isFinite(achieved_norm));
    @memcpy(second_fixture.current, &second_entry);
    try second_fixture.residualAtCurrent();
    try std.testing.expect(!attemptAndersonRecovery(second_fixture.context(options), second_fixture.cells, second_fixture.current, second_fixture.residual, second_fixture.previous_state, second_fixture.previous_residual, second_fixture.previous_state, second_fixture.previous_residual, 1, achieved_norm));
    try std.testing.expectEqualSlices(f64, &second_entry, second_fixture.current);
}
