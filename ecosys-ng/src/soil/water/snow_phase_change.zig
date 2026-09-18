const std = @import("std");
const snow = @import("../solute/snow_solute_transport.zig");
const numerics = @import("../../core/numerics.zig");
const ice_units = @import("../../core/ice_units.zig");

pub const Options = struct {
    /// Physical whole-step rate factor used by the modern direct solve. This
    /// occupies WATSUB `XNPS`'s rate role without reusing its donor limiter.
    physical_rate_time_step_hours: f64 = 1,
    /// Donor inventory fraction (`XNPSX` role), separate because legacy
    /// WTHR defines `XNPSX = XNPH * XNPS`.
    donor_availability_fraction: f64 = 1,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    pure_water_melting_temperature_k: f64,
    damping_divisor: f64,
    absolute_temperature_tolerance_k: f64,
    relative_tolerance: f64,
    energy_conservation_absolute_tolerance_megajoules_per_m2: f64,
    energy_conservation_relative_tolerance: f64,
    picard_relaxation: f64,
    max_iterations: u16,
    /// Depth-1 Anderson acceleration of the singular-derivative Picard
    /// fallback below, mirroring `snow_vapor_equilibrium.Options` and
    /// `core/numerics.zig`'s `newtonPicard`. An Anderson candidate is accepted
    /// only when it strictly improves the accepted current affine phase-heat
    /// residual `|E + H - Tm*C(H)|`; the relaxed point remains private secant
    /// history. Production validation rejects false.
    anderson_recovery: bool = true,
    /// Restrict the source-ordered coupled driver to one local snow layer in
    /// every cell. Omit for the standalone all-layer solve.
    local_layer_index: ?usize = null,
};

pub const Report = struct {
    iterations: u16,
    converged: bool,
    maximum_temperature_residual_k: f64,
    /// Accepted exact/damped Newton phase updates.
    newton_raphson_steps: u16 = 0,
    /// Compatibility recovery count; every such update is Anderson accelerated.
    picard_steps: u16 = 0,
    /// Fallback iterations across all layers where the Anderson-mixed
    /// candidate was accepted rather than the plain relaxed-Picard
    /// candidate.
    anderson_steps: u16 = 0,
    /// Independently measured canonical storage closure across the accepted
    /// solve. Pure freeze/thaw is internal, so this is required to be zero
    /// within the configured conservation tolerance before publication.
    enthalpy_change_megajoules: f64,
    /// Compatibility publication term. Always zero: storage post-minus-pre
    /// must never be recycled as internal heat production.
    sensible_energy_change_megajoules: f64,
    sensible_energy_change_megajoules_by_cell: []f64,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.sensible_energy_change_megajoules_by_cell);
        self.* = undefined;
    }
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

/// Values one snow layer exactly as the accepted landscape census does.  The
/// owner publishes `Cs*S + Cl*(W+V) + Ci_phys*I_phys`; solid SWE and physical
/// ice must therefore be re-based separately onto their carrier-specific
/// frozen-WE enthalpies. F77 retains `Cs` for snow and `Ci_phys` for ice.
fn censusEnthalpyMegajoules(
    heat_capacity_megajoules_per_k: f64,
    temperature_k: f64,
    solid_snow_water_equivalent_m3: f64,
    physical_ice_volume_m3: f64,
    options: Options,
) !f64 {
    const ice_capacity_we = try ice_units.heatCapacityPerWaterEquivalentM3K(
        options.ice_heat_capacity_megajoules_per_m3_k,
        options.ice_density_megagrams_per_m3,
    );
    const ice_we = try ice_units.waterEquivalentM3FromPhysicalVolume(
        physical_ice_volume_m3,
        options.ice_density_megagrams_per_m3,
    );
    const solid_correction = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        options.solid_snow_heat_capacity_megajoules_per_m3_k,
        options.liquid_water_heat_capacity_megajoules_per_m3_k,
        options.latent_heat_of_fusion_megajoules_per_m3,
        options.pure_water_melting_temperature_k,
    );
    const ice_correction = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        ice_capacity_we,
        options.liquid_water_heat_capacity_megajoules_per_m3_k,
        options.latent_heat_of_fusion_megajoules_per_m3,
        options.pure_water_melting_temperature_k,
    );
    const enthalpy = heat_capacity_megajoules_per_k * temperature_k +
        solid_correction * solid_snow_water_equivalent_m3 +
        ice_correction * ice_we;
    if (!std.math.isFinite(enthalpy)) return error.NonFiniteSnowPhaseEnergyChange;
    return enthalpy;
}

/// Depth-1 Anderson mixing for the singular-derivative fallback: the secant
/// step over the affine source-rate defect of the two most recent fallback
/// iterates for a given layer, mirroring
/// `snow_vapor_equilibrium.andersonAcceleratedTransfer`. Returns `null` when
/// the mixing coefficient is undefined (stationary or repeated defect,
/// which is the expected outcome when the residual is genuinely flat -- the
/// same condition that put this layer in the fallback in the first place)
/// or non-finite, or when the accelerated point does not move -- the caller
/// causes explicit recovery stagnation in every such case.
fn andersonAcceleratedPhaseHeat(heat_megajoules: f64, defect_megajoules: f64, previous_heat_megajoules: f64, previous_defect_megajoules: f64) ?f64 {
    const defect_change_megajoules = defect_megajoules - previous_defect_megajoules;
    if (!std.math.isFinite(defect_change_megajoules) or @abs(defect_change_megajoules) <= std.math.floatEps(f64)) return null;
    const mixing = defect_megajoules / defect_change_megajoules;
    if (!std.math.isFinite(mixing)) return null;
    const accelerated_heat_megajoules = heat_megajoules - mixing * (heat_megajoules - previous_heat_megajoules);
    if (!std.math.isFinite(accelerated_heat_megajoules) or accelerated_heat_megajoules == heat_megajoules) return null;
    return accelerated_heat_megajoules;
}

/// Local WATSUB freeze/thaw solve. This replaces repeated whole-model snow
/// substeps with safeguarded Newton phase increments and an Anderson-only
/// fallback. State is state_updateted only after every runtime snow layer is valid.
pub fn solve(allocator: std.mem.Allocator, state: *snow.State, options: Options) !Report {
    var control: TestControl = .{};
    return solveControlled(allocator, state, options, &control);
}

fn solveControlled(allocator: std.mem.Allocator, state: *snow.State, options: Options, control: *TestControl) !Report {
    if (!std.math.isFinite(options.physical_rate_time_step_hours) or options.physical_rate_time_step_hours <= 0 or options.physical_rate_time_step_hours > 1 or
        !std.math.isFinite(options.donor_availability_fraction) or options.donor_availability_fraction <= 0 or options.donor_availability_fraction > 1 or
        !std.math.isFinite(options.ice_density_megagrams_per_m3) or options.ice_density_megagrams_per_m3 <= 0 or
        !std.math.isFinite(options.latent_heat_of_fusion_megajoules_per_m3) or options.latent_heat_of_fusion_megajoules_per_m3 <= 0 or
        !std.math.isFinite(options.solid_snow_heat_capacity_megajoules_per_m3_k) or options.solid_snow_heat_capacity_megajoules_per_m3_k <= 0 or
        !std.math.isFinite(options.liquid_water_heat_capacity_megajoules_per_m3_k) or options.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or
        !std.math.isFinite(options.ice_heat_capacity_megajoules_per_m3_k) or options.ice_heat_capacity_megajoules_per_m3_k <= 0 or
        !std.math.isFinite(options.pure_water_melting_temperature_k) or options.pure_water_melting_temperature_k <= 0 or
        !std.math.isFinite(options.damping_divisor) or options.damping_divisor <= 0 or
        !std.math.isFinite(options.absolute_temperature_tolerance_k) or options.absolute_temperature_tolerance_k < 0 or
        !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance < 0 or
        !std.math.isFinite(options.energy_conservation_absolute_tolerance_megajoules_per_m2) or options.energy_conservation_absolute_tolerance_megajoules_per_m2 < 0 or
        !std.math.isFinite(options.energy_conservation_relative_tolerance) or options.energy_conservation_relative_tolerance < 0 or
        !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or
        options.max_iterations == 0 or !options.anderson_recovery) return error.InvalidSnowPhaseSolverOptions;
    if (options.local_layer_index) |layer|
        if (layer >= state.layer_capacity) return error.SnowPhaseLayerOutOfBounds;

    const sensible_energy_change_megajoules_by_cell = try allocator.alloc(f64, state.cell_count);
    errdefer allocator.free(sensible_energy_change_megajoules_by_cell);
    @memset(sensible_energy_change_megajoules_by_cell, 0);
    const solid = try allocator.dupe(f64, state.solid_snow_water_equivalent_m3);
    defer allocator.free(solid);
    const liquid = try allocator.dupe(f64, state.liquid_water_volume_m3);
    defer allocator.free(liquid);
    const ice = try allocator.dupe(f64, state.ice_volume_m3);
    defer allocator.free(ice);
    const temperature = try allocator.dupe(f64, state.temperature_k);
    defer allocator.free(temperature);
    const heat_capacity = try allocator.dupe(f64, state.heat_capacity_megajoules_per_k);
    defer allocator.free(heat_capacity);
    const retry_required = try allocator.alloc(bool, state.active.len);
    defer allocator.free(retry_required);
    @memset(retry_required, false);

    const ice_capacity_we = try ice_units.heatCapacityPerWaterEquivalentM3K(
        options.ice_heat_capacity_megajoules_per_m3_k,
        options.ice_density_megagrams_per_m3,
    );
    const solid_frozen_reference_megajoules_per_m3 = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        options.solid_snow_heat_capacity_megajoules_per_m3_k,
        options.liquid_water_heat_capacity_megajoules_per_m3_k,
        options.latent_heat_of_fusion_megajoules_per_m3,
        options.pure_water_melting_temperature_k,
    );
    const ice_frozen_reference_megajoules_per_we_m3 = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        ice_capacity_we,
        options.liquid_water_heat_capacity_megajoules_per_m3_k,
        options.latent_heat_of_fusion_megajoules_per_m3,
        options.pure_water_melting_temperature_k,
    );

    var report: Report = .{ .iterations = 0, .converged = false, .maximum_temperature_residual_k = 0, .enthalpy_change_megajoules = 0, .sensible_energy_change_megajoules = 0, .sensible_energy_change_megajoules_by_cell = sensible_energy_change_megajoules_by_cell };
    var previous_norm = std.math.inf(f64);
    var insufficient_progress_steps: u8 = 0;
    var progress_requires_anderson = false;
    for (1..@as(usize, options.max_iterations) + 1) |iteration| {
        var maximum_residual: f64 = 0;
        var maximum_scaled_residual: f64 = 0;
        const first_local_layer = options.local_layer_index orelse 0;
        const local_layer_end = if (options.local_layer_index) |layer| layer + 1 else state.layer_capacity;
        for (0..state.cell_count) |cell| {
            for (first_local_layer..local_layer_end) |local_layer| {
                const layer_index = cell * state.layer_capacity + local_layer;
                const solid_m3 = &solid[layer_index];
                const liquid_m3 = &liquid[layer_index];
                const ice_m3 = &ice[layer_index];
                const temperature_k = &temperature[layer_index];
                const capacity = &heat_capacity[layer_index];
                inline for (.{ solid_m3.*, liquid_m3.*, ice_m3.*, temperature_k.*, capacity.* }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSnowPhaseState;
                if (solid_m3.* < 0 or liquid_m3.* < 0 or ice_m3.* < 0 or temperature_k.* <= 0 or capacity.* < 0) return error.InvalidSnowPhaseState;
                const activation_threshold = snow.activation_heat_capacity_megajoules_per_m2_k *
                    state.horizontal_area_m2[layer_index];
                if (capacity.* <= activation_threshold) continue;
                const retrying_newton_after_anderson = retry_required[layer_index];
                retry_required[layer_index] = false;
                // Re-evaluating the bounded phase active set is the Newton retry
                // when Anderson lands exactly on an inventory boundary.
                if (retrying_newton_after_anderson) control.record(.newton_attempt);
                const frozen_water_equivalent_m3 = solid_m3.* + ice_m3.* * options.ice_density_megagrams_per_m3;
                const can_thaw = temperature_k.* > options.pure_water_melting_temperature_k and frozen_water_equivalent_m3 > 0;
                const can_freeze = temperature_k.* < options.pure_water_melting_temperature_k and liquid_m3.* > 0;
                if (!can_thaw and !can_freeze) continue;

                const residual_k = @abs(temperature_k.* - options.pure_water_melting_temperature_k);
                maximum_residual = @max(maximum_residual, residual_k);
                const tolerance_k = options.absolute_temperature_tolerance_k + options.relative_tolerance * options.pure_water_melting_temperature_k;
                maximum_scaled_residual = @max(maximum_scaled_residual, residual_k / @max(tolerance_k, std.math.floatMin(f64)));
                if (!retrying_newton_after_anderson and residual_k <= tolerance_k) continue;

                // Solve the canonical carrier-reference balance
                // E - dK(H) - Tm*C(H) = 0. `H/L` determines the accepted phase
                // amount, but latent heat is an internal transfer and is not an
                // energy source. Within either active phase branch both `K(H)`
                // and `C(H)` are affine, so this is the exact Newton step.
                const old_sensible_energy_megajoules = capacity.* * temperature_k.*;
                const solid_fraction = if (frozen_water_equivalent_m3 > 0) solid_m3.* / frozen_water_equivalent_m3 else 0;
                // WATSUB 2381: this is a source-derived rate equation, not an
                // equilibrium jump. Newton solves the affine residual
                // H - C*(Tm-T)/DAMPING*XNPS = 0 exactly in one accepted step.
                const newton_heat_megajoules = capacity.* *
                    (options.pure_water_melting_temperature_k - temperature_k.*) /
                    options.damping_divisor * options.physical_rate_time_step_hours;
                const newton_usable = std.math.isFinite(newton_heat_megajoules);
                var forced_newton_failure = false;
                if ((!progress_requires_anderson or retrying_newton_after_anderson) and !retrying_newton_after_anderson) {
                    control.record(.newton_attempt);
                    if (control.forced_initial_newton_failures > 0) {
                        control.forced_initial_newton_failures -= 1;
                        forced_newton_failure = true;
                    }
                }
                const requested_heat_megajoules = if (!forced_newton_failure and newton_usable and (!progress_requires_anderson or retrying_newton_after_anderson)) newton: {
                    report.newton_raphson_steps += 1;
                    break :newton newton_heat_megajoules;
                } else fallback: {
                    if (retrying_newton_after_anderson) continue;
                    if (iteration >= options.max_iterations) return error.SnowPhaseSolverDidNotConverge;
                    const relaxed_heat_megajoules = newton_heat_megajoules * options.picard_relaxation;
                    if (!std.math.isFinite(relaxed_heat_megajoules)) return error.NonFiniteSnowPhaseStep;
                    const base_defect_megajoules = newton_heat_megajoules;
                    const relaxed_defect_megajoules = newton_heat_megajoules - relaxed_heat_megajoules;
                    const accelerated_heat_megajoules = andersonAcceleratedPhaseHeat(relaxed_heat_megajoules, relaxed_defect_megajoules, 0, base_defect_megajoules) orelse return error.SnowPhaseSolverStagnated;
                    const accelerated_defect_megajoules = newton_heat_megajoules - accelerated_heat_megajoules;
                    if (!numerics.andersonImprovesAcceptedMerit(@abs(accelerated_defect_megajoules), @abs(base_defect_megajoules))) return error.SnowPhaseSolverStagnated;
                    report.anderson_steps += 1;
                    report.picard_steps += 1;
                    retry_required[layer_index] = true;
                    control.record(.anderson_accept);
                    break :fallback accelerated_heat_megajoules;
                };
                if (!std.math.isFinite(requested_heat_megajoules)) return error.NonFiniteSnowPhaseStep;
                const available_heat_megajoules = if (requested_heat_megajoules < 0)
                    options.latent_heat_of_fusion_megajoules_per_m3 * frozen_water_equivalent_m3 * options.donor_availability_fraction
                else
                    options.latent_heat_of_fusion_megajoules_per_m3 * liquid_m3.* * options.donor_availability_fraction;
                const phase_heat_megajoules = std.math.clamp(requested_heat_megajoules, -available_heat_megajoules, available_heat_megajoules);
                if (phase_heat_megajoules == 0) continue;
                const inventory_limited = @abs(phase_heat_megajoules) == available_heat_megajoules;
                const previous_solid_m3 = solid_m3.*;
                const previous_ice_we_m3 = ice_m3.* * options.ice_density_megagrams_per_m3;
                if (phase_heat_megajoules < 0) {
                    if (inventory_limited and options.donor_availability_fraction == 1) {
                        // The clamp selected the complete frozen inventory.
                        // Reconstructing it as `(L * donor) / L` can round one
                        // ulp above the donor. Exhaust the authoritative
                        // carriers exactly and move their already-computed
                        // water equivalent to liquid.
                        solid_m3.* = 0;
                        ice_m3.* = 0;
                        liquid_m3.* += frozen_water_equivalent_m3;
                    } else {
                        const thawed_water_equivalent_m3 = if (inventory_limited)
                            frozen_water_equivalent_m3 * options.donor_availability_fraction
                        else
                            -phase_heat_megajoules / options.latent_heat_of_fusion_megajoules_per_m3;
                        const from_solid_m3 = @min(solid_m3.*, thawed_water_equivalent_m3 * solid_fraction);
                        const from_ice_water_equivalent_m3 = @min(
                            ice_m3.* * options.ice_density_megagrams_per_m3,
                            thawed_water_equivalent_m3 - from_solid_m3,
                        );
                        solid_m3.* -= from_solid_m3;
                        ice_m3.* -= from_ice_water_equivalent_m3 / options.ice_density_megagrams_per_m3;
                        liquid_m3.* += from_solid_m3 + from_ice_water_equivalent_m3;
                    }
                } else {
                    const frozen_liquid_m3 = if (inventory_limited)
                        liquid_m3.* * options.donor_availability_fraction
                    else
                        phase_heat_megajoules / options.latent_heat_of_fusion_megajoules_per_m3;
                    if (inventory_limited and options.donor_availability_fraction == 1)
                        liquid_m3.* = 0
                    else
                        liquid_m3.* -= frozen_liquid_m3;
                    ice_m3.* += frozen_liquid_m3 / options.ice_density_megagrams_per_m3;
                }
                capacity.* = options.solid_snow_heat_capacity_megajoules_per_m3_k * solid_m3.* + options.liquid_water_heat_capacity_megajoules_per_m3_k * (liquid_m3.* + state.vapor_water_equivalent_m3[layer_index]) + options.ice_heat_capacity_megajoules_per_m3_k * ice_m3.*;
                if (!std.math.isFinite(capacity.*) or capacity.* <= 0) return error.InvalidSnowPhaseHeatCapacity;
                const frozen_reference_change_megajoules =
                    solid_frozen_reference_megajoules_per_m3 * (solid_m3.* - previous_solid_m3) +
                    ice_frozen_reference_megajoules_per_we_m3 *
                        (ice_m3.* * options.ice_density_megagrams_per_m3 - previous_ice_we_m3);
                temperature_k.* = (old_sensible_energy_megajoules - frozen_reference_change_megajoules) / capacity.*;
                if (!std.math.isFinite(temperature_k.*) or temperature_k.* <= 0) return error.InvalidSnowPhaseTemperature;
            }
        }
        report.iterations = @intCast(iteration);
        report.maximum_temperature_residual_k = maximum_residual;
        const progress_floor = std.math.sqrt(std.math.floatEps(f64)) * @max(1.0, previous_norm);
        if (std.math.isFinite(previous_norm) and previous_norm - maximum_scaled_residual <= progress_floor)
            insufficient_progress_steps +|= 1
        else
            insufficient_progress_steps = 0;
        previous_norm = maximum_scaled_residual;
        progress_requires_anderson = insufficient_progress_steps >= 4;
        var any_retry_required = false;
        for (0..state.cell_count) |cell| {
            for (first_local_layer..local_layer_end) |local_layer| {
                any_retry_required = any_retry_required or retry_required[cell * state.layer_capacity + local_layer];
            }
        }
        // One source-derived XNPS rate application completes this substep;
        // repeated equilibrium iterations would disconnect both damping and
        // the external recovery schedule's 60/2x30/4x15 timing.
        if (!any_retry_required) {
            report.converged = true;
            break;
        }
    }
    if (!report.converged) return error.SnowPhaseSolverDidNotConverge;
    // Phase change is internal: its independently accepted donor/recipient
    // transfer must leave the canonical snow enthalpy unchanged at every
    // layer. Never publish the measured storage delta as an RHS source.
    for (
        heat_capacity,
        temperature,
        solid,
        ice,
        state.heat_capacity_megajoules_per_k,
        state.temperature_k,
        state.solid_snow_water_equivalent_m3,
        state.ice_volume_m3,
        0..,
    ) |
        next_capacity,
        next_temperature,
        next_solid,
        next_ice,
        previous_capacity,
        previous_temperature,
        previous_solid,
        previous_ice,
        layer_index,
    | {
        const before = try censusEnthalpyMegajoules(
            previous_capacity,
            previous_temperature,
            previous_solid,
            previous_ice,
            options,
        );
        const after = try censusEnthalpyMegajoules(
            next_capacity,
            next_temperature,
            next_solid,
            next_ice,
            options,
        );
        const change = after - before;
        const cell = layer_index / state.layer_capacity;
        const scale = @max(@abs(before), @abs(after));
        const tolerance = options.energy_conservation_absolute_tolerance_megajoules_per_m2 *
            state.horizontal_area_m2[cell] +
            options.energy_conservation_relative_tolerance * scale +
            256 * std.math.floatEps(f64) * scale;
        inline for (.{ before, after, change, scale, tolerance }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteSnowPhaseEnergyChange;
        if (@abs(change) > tolerance) return error.SnowPhaseEnergyConservationFailure;
        report.enthalpy_change_megajoules += change;
        if (!std.math.isFinite(report.enthalpy_change_megajoules))
            return error.NonFiniteSnowPhaseEnergyChange;
    }
    // Kept for call-site compatibility: a canonical internal phase transfer
    // has no production/consumption term to publish.
    report.sensible_energy_change_megajoules = 0;
    @memcpy(state.solid_snow_water_equivalent_m3, solid);
    @memcpy(state.liquid_water_volume_m3, liquid);
    @memcpy(state.ice_volume_m3, ice);
    @memcpy(state.temperature_k, temperature);
    @memcpy(state.heat_capacity_megajoules_per_k, heat_capacity);
    state.refreshAllGeometry();
    return report;
}

test "snow phase Anderson mixing extrapolates a linear defect sequence to its exact root" {
    // Conformance guard mirroring snow_vapor_equilibrium's own Anderson test:
    // this solver's singular-derivative fallback must be Anderson-accelerated
    // Picard, never plain Picard. For a defect exactly linear in heat
    // (defect(H) = slope*(H - root)), the secant mixing coefficient computed
    // from any two iterates is exact, so the accelerated point lands on the
    // root itself.
    const slope = -5.0;
    const root = 0.02;
    const previous_heat_megajoules = 0.0;
    const previous_defect_megajoules = slope * (previous_heat_megajoules - root);
    const heat_megajoules = 1.0;
    const defect_megajoules = slope * (heat_megajoules - root);
    const accelerated = andersonAcceleratedPhaseHeat(heat_megajoules, defect_megajoules, previous_heat_megajoules, previous_defect_megajoules);
    try std.testing.expect(accelerated != null);
    try std.testing.expectApproxEqAbs(root, accelerated.?, 1e-12);
}

test "snow phase Anderson mixing yields nothing on a stationary or repeated defect" {
    // A zero defect_change (repeated fallback iterate, or genuinely
    // stationary defect -- exactly the condition that put the layer in the
    // fallback in the first place) leaves the mixing coefficient undefined;
    // the fallback must report stagnation, never divide by zero or commit the seed.
    try std.testing.expect(andersonAcceleratedPhaseHeat(0.01, 0.5, 0.01, 0.5) == null);
    try std.testing.expect(andersonAcceleratedPhaseHeat(0.01, 0.5, 0.0, 0.5) == null);
}

test "snow phase rejects disabled Anderson recovery" {
    // Mirrors snow_vapor_equilibrium's own behavior-neutrality regression.
    // At the codebase's realistic ice density (0.92), the thaw/freeze
    // derivative is a well-conditioned ~2.72 (see the sibling exact-Newton
    // test below), so every layer here takes the exact-Newton branch and
    // never reaches the singular-derivative fallback at all -- this proves
    // `anderson_recovery` is a true no-op on a real, already-covered
    // production scenario, not just in isolation on the pure helper.
    var state_with = try snow.State.init(std.testing.allocator, 2, 1);
    defer state_with.deinit();
    try state_with.initializePhysicalState(&.{ 0.1, 0.1 }, &.{ 1, 1 }, &.{ 275, 270 }, &.{0.2}, 0.05, snow.test_thermodynamics);
    state_with.temperature_k[0] = 275;
    state_with.liquid_water_volume_m3[1] = 0.002;
    state_with.heat_capacity_megajoules_per_k[1] += 4.19 * 0.002;

    const options: Options = .{ .ice_density_megagrams_per_m3 = 0.92, .latent_heat_of_fusion_megajoules_per_m3 = 333, .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .pure_water_melting_temperature_k = 273.15, .damping_divisor = 2.7185, .absolute_temperature_tolerance_k = 1e-8, .relative_tolerance = 1e-8, .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12, .energy_conservation_relative_tolerance = 1e-10, .picard_relaxation = 1, .max_iterations = 20 };
    var options_without = options;
    options_without.anderson_recovery = false;
    try std.testing.expectError(error.InvalidSnowPhaseSolverOptions, solve(std.testing.allocator, &state_with, options_without));
}

test "freeze thaw conserves water equivalent and state_updates atomically" {
    var state = try snow.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0.1, 0.1 }, &.{ 1, 1 }, &.{ 275, 270 }, &.{0.2}, 0.05, snow.test_thermodynamics);
    state.temperature_k[0] = 275;
    state.liquid_water_volume_m3[1] = 0.002;
    state.heat_capacity_megajoules_per_k[1] += 4.19 * 0.002;
    const before0 = state.solid_snow_water_equivalent_m3[0] + state.liquid_water_volume_m3[0] + state.ice_volume_m3[0] * 0.92;
    const before1 = state.solid_snow_water_equivalent_m3[1] + state.liquid_water_volume_m3[1] + state.ice_volume_m3[1] * 0.92;
    var report = try solve(std.testing.allocator, &state, .{ .ice_density_megagrams_per_m3 = 0.92, .latent_heat_of_fusion_megajoules_per_m3 = 333, .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .pure_water_melting_temperature_k = 273.15, .damping_divisor = 2.7185, .absolute_temperature_tolerance_k = 1e-8, .relative_tolerance = 1e-8, .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12, .energy_conservation_relative_tolerance = 1e-10, .picard_relaxation = 1, .max_iterations = 20 });
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.iterations < 20);
    try std.testing.expectApproxEqAbs(before0, state.solid_snow_water_equivalent_m3[0] + state.liquid_water_volume_m3[0] + state.ice_volume_m3[0] * 0.92, 1e-12);
    try std.testing.expectApproxEqAbs(before1, state.solid_snow_water_equivalent_m3[1] + state.liquid_water_volume_m3[1] + state.ice_volume_m3[1] * 0.92, 1e-12);
    try std.testing.expect(state.liquid_water_volume_m3[0] > 0);
    try std.testing.expect(state.ice_volume_m3[1] > 0);
    try std.testing.expectEqual(@as(f64, 0), report.sensible_energy_change_megajoules);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, report.sensible_energy_change_megajoules_by_cell);
    try std.testing.expect(@abs(report.enthalpy_change_megajoules) <= 2e-12);
}

test "snow phase recovery traces Newton Anderson Newton and rejects final slot atomically" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{275}, &.{0.2}, 0.05, snow.test_thermodynamics);
    state.temperature_k[0] = 275;
    const options: Options = .{ .ice_density_megagrams_per_m3 = 0.92, .latent_heat_of_fusion_megajoules_per_m3 = 333, .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .pure_water_melting_temperature_k = 273.15, .damping_divisor = 2.7185, .absolute_temperature_tolerance_k = 1e-8, .relative_tolerance = 1e-8, .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12, .energy_conservation_relative_tolerance = 1e-10, .picard_relaxation = 0.5, .max_iterations = 20 };
    const before_temperature = state.temperature_k[0];
    const before_solid = state.solid_snow_water_equivalent_m3[0];
    var final_options = options;
    final_options.max_iterations = 1;
    var final_control: TestControl = .{ .forced_initial_newton_failures = 1 };
    try std.testing.expectError(error.SnowPhaseSolverDidNotConverge, solveControlled(std.testing.allocator, &state, final_options, &final_control));
    try std.testing.expectEqual(before_temperature, state.temperature_k[0]);
    try std.testing.expectEqual(before_solid, state.solid_snow_water_equivalent_m3[0]);

    var control: TestControl = .{ .forced_initial_newton_failures = 1 };
    var report = try solveControlled(std.testing.allocator, &state, options, &control);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(report.picard_steps, report.anderson_steps);
    try std.testing.expect(control.event_count >= 3);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[0]);
    try std.testing.expectEqual(MethodEvent.anderson_accept, control.events[1]);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[2]);
}

test "snow phase source rate scales with physical dt and inverse damping" {
    var full = try snow.State.init(std.testing.allocator, 1, 1);
    defer full.deinit();
    var quarter = try snow.State.init(std.testing.allocator, 1, 1);
    defer quarter.deinit();
    var double_damping = try snow.State.init(std.testing.allocator, 1, 1);
    defer double_damping.deinit();
    inline for (.{ &full, &quarter, &double_damping }) |state| {
        try state.initializePhysicalState(&.{0.1}, &.{1}, &.{270}, &.{0.2}, 0.05, snow.test_thermodynamics);
        state.temperature_k[0] = 270;
        state.liquid_water_volume_m3[0] = 0.002;
        state.heat_capacity_megajoules_per_k[0] += 4.19 * 0.002;
    }
    const base: Options = .{ .ice_density_megagrams_per_m3 = 0.92, .latent_heat_of_fusion_megajoules_per_m3 = 333, .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .pure_water_melting_temperature_k = 273.15, .damping_divisor = 2.7185, .absolute_temperature_tolerance_k = 1e-10, .relative_tolerance = 1e-10, .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12, .energy_conservation_relative_tolerance = 1e-10, .picard_relaxation = 1, .max_iterations = 20 };
    var full_report = try solve(std.testing.allocator, &full, base);
    defer full_report.deinit(std.testing.allocator);
    var quarter_options = base;
    quarter_options.physical_rate_time_step_hours = 0.25;
    var quarter_report = try solve(std.testing.allocator, &quarter, quarter_options);
    defer quarter_report.deinit(std.testing.allocator);
    var double_options = base;
    double_options.damping_divisor *= 2;
    var double_report = try solve(std.testing.allocator, &double_damping, double_options);
    defer double_report.deinit(std.testing.allocator);

    const full_frozen = 0.002 - full.liquid_water_volume_m3[0];
    const quarter_frozen = 0.002 - quarter.liquid_water_volume_m3[0];
    const double_damping_frozen = 0.002 - double_damping.liquid_water_volume_m3[0];
    try std.testing.expect(full_frozen > 0);
    try std.testing.expectApproxEqAbs(4 * quarter_frozen, full_frozen, 1e-14);
    try std.testing.expectApproxEqAbs(2 * double_damping_frozen, full_frozen, 1e-14);
}

test "snow phase donor availability is independent from physical rate dt" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{270}, &.{0.2}, 0.05, snow.test_thermodynamics);
    state.temperature_k[0] = 270;
    state.liquid_water_volume_m3[0] = 0.002;
    state.heat_capacity_megajoules_per_k[0] += 4.19 * 0.002;
    var report = try solve(std.testing.allocator, &state, .{ .physical_rate_time_step_hours = 1, .donor_availability_fraction = 0.25, .ice_density_megagrams_per_m3 = 0.92, .latent_heat_of_fusion_megajoules_per_m3 = 333, .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .pure_water_melting_temperature_k = 273.15, .damping_divisor = 0.001, .absolute_temperature_tolerance_k = 1e-10, .relative_tolerance = 1e-10, .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12, .energy_conservation_relative_tolerance = 1e-10, .picard_relaxation = 1, .max_iterations = 20 });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0015), state.liquid_water_volume_m3[0], 1e-14);
}

test "inventory limited freeze exhausts liquid without a negative ulp" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{270}, &.{0.2}, 0.05, snow.test_thermodynamics);
    state.temperature_k[0] = 270;
    // For this representable donor, `(333 * donor) / 333` rounds one ulp
    // above the donor. A multiply/divide reconstruction followed by
    // subtraction therefore creates an impossible negative water volume.
    const donor_m3: f64 = 2.7e-11;
    state.liquid_water_volume_m3[0] = donor_m3;
    state.heat_capacity_megajoules_per_k[0] += 4.19 * donor_m3;
    const water_before = state.solid_snow_water_equivalent_m3[0] +
        state.liquid_water_volume_m3[0] + state.ice_volume_m3[0] * 0.92;
    var report = try solve(std.testing.allocator, &state, .{
        .physical_rate_time_step_hours = 1,
        .donor_availability_fraction = 1,
        .ice_density_megagrams_per_m3 = 0.92,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        .pure_water_melting_temperature_k = 273.15,
        .damping_divisor = 0.001,
        .absolute_temperature_tolerance_k = 1e-10,
        .relative_tolerance = 1e-10,
        .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
        .energy_conservation_relative_tolerance = 1e-10,
        .picard_relaxation = 1,
        .max_iterations = 20,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 0), state.liquid_water_volume_m3[0]);
    try std.testing.expectApproxEqAbs(
        water_before,
        state.solid_snow_water_equivalent_m3[0] +
            state.liquid_water_volume_m3[0] + state.ice_volume_m3[0] * 0.92,
        32 * std.math.floatEps(f64),
    );
}

test "inventory limited thaw exhausts frozen donors without a negative ulp" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{275}, &.{0.2}, 0.05, snow.test_thermodynamics);
    state.temperature_k[0] = 275;
    const water_before = state.solid_snow_water_equivalent_m3[0] +
        state.liquid_water_volume_m3[0] + state.ice_volume_m3[0] * 0.92;
    var report = try solve(std.testing.allocator, &state, .{
        .physical_rate_time_step_hours = 1,
        .donor_availability_fraction = 1,
        .ice_density_megagrams_per_m3 = 0.92,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        .pure_water_melting_temperature_k = 273.15,
        .damping_divisor = 0.001,
        .absolute_temperature_tolerance_k = 1e-10,
        .relative_tolerance = 1e-10,
        .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
        .energy_conservation_relative_tolerance = 1e-10,
        .picard_relaxation = 1,
        .max_iterations = 20,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 0), state.solid_snow_water_equivalent_m3[0]);
    try std.testing.expectEqual(@as(f64, 0), state.ice_volume_m3[0]);
    try std.testing.expectApproxEqAbs(
        water_before,
        state.solid_snow_water_equivalent_m3[0] +
            state.liquid_water_volume_m3[0] + state.ice_volume_m3[0] * 0.92,
        32 * std.math.floatEps(f64),
    );
}
