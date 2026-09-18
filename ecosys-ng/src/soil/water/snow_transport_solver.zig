const std = @import("std");
const numerics = @import("../../core/numerics.zig");
const snow = @import("../solute/snow_solute_transport.zig");

pub const Inputs = struct {
    atmospheric_top_input_g: []const f64,
    /// Dynamic precipitation-equilibrium input, cell-major in snow salt
    /// order. Empty is a compatibility zero input for static focused tests.
    atmospheric_top_input_salt_mol: []const f64 = &.{},
    transport_water_volume_m3: []const f64,
    water_flux_to_lower_m3: []const f64,
    litter_water_flux_m3: []const f64,
    soil_micropore_water_flux_m3: []const f64,
    soil_macropore_water_flux_m3: []const f64,
    surface_partitions: []const snow.SurfacePartition,
    water_flux_absolute_tolerance_m3: f64 = 1e-12,
    water_flux_relative_tolerance: f64 = 1e-10,
    /// Optional caller-owned accepted internal transfers. Published only with
    /// the state/discharge transaction; failed solves leave them unchanged.
    accepted_downward_g: ?[]f64 = null,
    accepted_downward_salt_mol: ?[]f64 = null,
};

pub const Options = struct {
    /// Species-specific nonlinear floors in each snow solute's tracked-element
    /// gram basis. Production mixed-element callers provide this vector.
    absolute_tolerance_g_by_species: [snow.species_count]f64 = @splat(1e-12),
    /// Deprecated homogeneous override retained for legacy focused callers.
    absolute_tolerance_g: f64 = std.math.nan(f64),
    relative_tolerance: f64 = 1e-8,
    picard_relaxation: f64 = 0.5,
    directional_probe_fraction: f64 = 0.5,
    minimum_newton_fraction: f64 = 0.05,
    maximum_newton_fraction: f64 = 1.0,
    /// Source-derived snowpack ceiling (20 unless supplied at runtime).
    max_iterations: u16 = 20,
    /// Divergence/oscillation watch, mirroring `core/numerics.zig`. This solver
    /// is vector-valued over layers and species, so it cannot delegate to the
    /// shared scalar solver and needs its own detector. Consecutive iterations
    /// whose scaled norm exceeds `divergence_growth_factor` times the best norm
    /// seen are counted; past `divergence_patience` of them the solve is
    /// diverging or oscillating, and reporting that is more useful than burning
    /// the remaining iterations and reporting mere non-convergence.
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    /// Depth-one Anderson acceleration of the relaxed Picard recovery step,
    /// mirroring `core/numerics.zig` and `soil/gas/vapor_solver.zig`. The
    /// residual here couples every layer to its neighbours across an arbitrary
    /// number of species, so this is not a scalar problem per coordinate and
    /// cannot delegate to the shared scalar solver; the same recovery semantics
    /// are reproduced locally instead. An Anderson candidate is accepted only
    /// when it strictly improves the accepted current iterate; the relaxed
    /// point remains private secant history. Production validation rejects false.
    anderson_recovery: bool = true,
};

pub const Result = struct {
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    maximum_scaled_residual: f64,
    /// Recovery steps taken with the Anderson candidate rather than the plain
    /// relaxed Picard candidate. Counted inside `picard_steps` as well, so the
    /// existing step accounting is unchanged.
    anderson_steps: u16 = 0,
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

/// Implicitly advances only snow solute transport. The rest of the ecosystem
/// model is not repeated while the snow state converges.
pub fn solve(allocator: std.mem.Allocator, state: *snow.State, inputs: Inputs, options: Options, output_surface_discharge: []snow.SurfaceDischarge) !Result {
    var control: TestControl = .{};
    return solveControlled(allocator, state, inputs, options, output_surface_discharge, &control);
}

fn solveControlled(allocator: std.mem.Allocator, state: *snow.State, inputs: Inputs, options: Options, output_surface_discharge: []snow.SurfaceDischarge, control: *TestControl) !Result {
    try validate(state, inputs, options, output_surface_discharge);
    const base = try allocator.dupe(f64, state.amount_g);
    defer allocator.free(base);
    const current = try allocator.dupe(f64, base);
    defer allocator.free(current);
    const residual = try allocator.alloc(f64, base.len);
    defer allocator.free(residual);
    const probe = try allocator.alloc(f64, base.len);
    defer allocator.free(probe);
    const probe_residual = try allocator.alloc(f64, base.len);
    defer allocator.free(probe_residual);
    const candidate = try allocator.alloc(f64, base.len);
    defer allocator.free(candidate);
    const candidate_residual = try allocator.alloc(f64, base.len);
    defer allocator.free(candidate_residual);
    const target = try allocator.alloc(f64, base.len);
    defer allocator.free(target);
    const salt_target = try allocator.alloc(f64, state.salt_amount_mol.len);
    defer allocator.free(salt_target);
    const accepted_discharge = try allocator.alloc(snow.SurfaceDischarge, state.cell_count);
    defer allocator.free(accepted_discharge);
    const accepted_downward_g = try allocator.alloc(f64, state.amount_g.len);
    defer allocator.free(accepted_downward_g);
    const accepted_downward_salt_mol = try allocator.alloc(f64, state.salt_amount_mol.len);
    defer allocator.free(accepted_downward_salt_mol);
    var scratch = try snow.State.init(allocator, state.cell_count, state.layer_capacity);
    defer scratch.deinit();
    @memcpy(scratch.active, state.active);
    @memcpy(scratch.liquid_water_volume_m3, inputs.transport_water_volume_m3);
    @memcpy(scratch.salt_amount_mol, state.salt_amount_mol);

    var newton_steps: u16 = 0;
    var picard_steps: u16 = 0;
    var anderson_steps: u16 = 0;
    // Divergence/oscillation watch state.
    var best_norm = std.math.inf(f64);
    var non_improving_steps: u16 = 0;
    var previous_norm = std.math.inf(f64);
    var insufficient_progress_steps: u16 = 0;
    var newton_retry_required = false;
    var iteration: u16 = 0;
    while (iteration < options.max_iterations) : (iteration += 1) {
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        try residualAt(allocator, &scratch, base, current, inputs, target, residual, null, null);
        const norm = try scaledNorm(current, residual, options);
        if (!retrying_newton_after_anderson and norm <= 1) {
            // StateUpdate the fixed-point IMAGE, not the trial that produced it.
            //
            // `target` is conservative by construction: it is `base` plus the
            // atmospheric input, minus each layer's actually-transferred
            // downward amount and plus that same amount into the layer below,
            // minus the actually-discharged surface amount. Every internal
            // transfer appears once as a debit and once as a credit, so
            // sum(target) + sum(discharge) equals sum(base) + sum(input) to
            // within floating-point summation error alone.
            //
            // `current` carries no such guarantee. It is whatever trial the
            // iteration last proposed, and it differs from `target` by exactly
            // `residual`, whose per-component size the convergence test is
            // willing to leave as large as
            // `species_absolute_tolerance_g + relative_tolerance * |value|`.
            // StateUpdateting `current` while reporting the discharge computed from
            // it published that residual as real mass: solute that left in the
            // discharge but was never removed from storage, or vice versa. On
            // the Ottawa production deck that was the whole of the day-1
            // nitrogen non-closure (EXEC-N-BALANCE-DAY1-001, cause
            // SNOW-SOLVER-TOLERANCE-SLACK-001), because the deck's relative
            // tolerance of 1e-8 is a thousand times the audit's 1e-11.
            //
            // StateUpdateting the image makes conservation independent of the
            // convergence tolerance rather than contingent on it. A loose
            // tolerance now costs accuracy in the transport split, which is a
            // discretization choice, instead of fabricating mass, which is a
            // conservation violation no downstream sum could detect.
            try residualAt(allocator, &scratch, base, current, inputs, target, residual, accepted_discharge, accepted_downward_g);
            try acceptedSaltTarget(allocator, &scratch, inputs, salt_target, accepted_discharge, accepted_downward_salt_mol);
            @memcpy(state.amount_g, target);
            @memcpy(state.salt_amount_mol, salt_target);
            @memcpy(output_surface_discharge, accepted_discharge);
            if (inputs.accepted_downward_g) |output| @memcpy(output, accepted_downward_g);
            if (inputs.accepted_downward_salt_mol) |output| @memcpy(output, accepted_downward_salt_mol);
            return .{ .iterations = iteration + 1, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .maximum_scaled_residual = norm, .anderson_steps = anderson_steps };
        }
        if (norm < best_norm) {
            best_norm = norm;
            non_improving_steps = 0;
        } else if (norm > options.divergence_growth_factor * best_norm) {
            non_improving_steps += 1;
            if (non_improving_steps >= options.divergence_patience) {
                std.log.warn("snow transport solver diverging: iteration={d} scaled_residual={e} best_scaled_residual={e} growth_factor={e} patience={d}", .{ iteration + 1, norm, best_norm, options.divergence_growth_factor, options.divergence_patience });
                return error.SnowTransportSolverDiverged;
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
        const progress_requires_anderson = insufficient_progress_steps >= 4;
        newton_primary: {
            if (progress_requires_anderson and !retrying_newton_after_anderson) break :newton_primary;
            control.record(.newton_attempt);
            if (control.forced_initial_newton_failures > 0) {
                control.forced_initial_newton_failures -= 1;
                break :newton_primary;
            }
            var accepted_newton = false;
            if (addDirection(current, residual, options.directional_probe_fraction, probe)) |_| {
                if (residualAt(allocator, &scratch, base, probe, inputs, target, probe_residual, null, null)) |_| {
                    var numerator: f64 = 0;
                    var denominator: f64 = 0;
                    for (residual, probe_residual) |value, sampled| {
                        const derivative = (sampled - value) / options.directional_probe_fraction;
                        numerator += value * derivative;
                        denominator += derivative * derivative;
                    }
                    if (std.math.isFinite(denominator) and denominator > std.math.floatEps(f64)) {
                        const fraction = std.math.clamp(-numerator / denominator, options.minimum_newton_fraction, options.maximum_newton_fraction);
                        if (addDirection(current, residual, fraction, candidate)) |_| {
                            if (residualAt(allocator, &scratch, base, candidate, inputs, target, candidate_residual, null, null)) |_| {
                                if (try scaledNorm(candidate, candidate_residual, options) < norm) {
                                    @memcpy(current, candidate);
                                    newton_steps += 1;
                                    accepted_newton = true;
                                }
                            } else |_| {}
                        } else |_| {}
                    }
                } else |_| {}
            } else |_| {}
            if (accepted_newton) continue;
        }
        if (retrying_newton_after_anderson) continue;
        // Anderson is never a final-slot publication. Its accepted iterate must
        // receive a separately counted Newton attempt before any success gate.
        if (iteration + 1 >= options.max_iterations) return error.SnowTransportSolverDidNotConverge;
        // Sole recovery: evaluate a relaxed fixed-point seed without committing
        // it, then form a genuine depth-one Anderson candidate from the two
        // defects. Newton is restarted on the next outer iteration.
        try addDirection(current, residual, options.picard_relaxation, candidate);
        try residualAt(allocator, &scratch, base, candidate, inputs, target, candidate_residual, null, null);
        if (!numerics.andersonDepthOneCandidate(current, residual, candidate, candidate_residual, probe)) return error.SnowTransportSolverStagnated;
        for (probe) |*value| {
            if (!std.math.isFinite(value.*) or value.* < 0) return error.SnowTransportSolverStagnated;
        }
        try residualAt(allocator, &scratch, base, probe, inputs, target, probe_residual, null, null);
        const anderson_norm = try scaledNorm(probe, probe_residual, options);
        if (!numerics.andersonImprovesAcceptedMerit(anderson_norm, norm)) return error.SnowTransportSolverStagnated;
        @memcpy(current, probe);
        control.record(.anderson_accept);
        anderson_steps += 1;
        picard_steps += 1;
        newton_retry_required = true;
    }
    // The last allowed update above has not yet been audited by the loop head.
    // Evaluate it once without changing `current`; convergence reached exactly
    // on the hard ceiling must succeed, while an unconverged candidate remains
    // private and the caller transaction stays untouched.
    try residualAt(allocator, &scratch, base, current, inputs, target, residual, null, null);
    const final_norm = try scaledNorm(current, residual, options);
    if (!newton_retry_required and final_norm <= 1) {
        try residualAt(allocator, &scratch, base, current, inputs, target, residual, accepted_discharge, accepted_downward_g);
        try acceptedSaltTarget(allocator, &scratch, inputs, salt_target, accepted_discharge, accepted_downward_salt_mol);
        @memcpy(state.amount_g, target);
        @memcpy(state.salt_amount_mol, salt_target);
        @memcpy(output_surface_discharge, accepted_discharge);
        if (inputs.accepted_downward_g) |output| @memcpy(output, accepted_downward_g);
        if (inputs.accepted_downward_salt_mol) |output| @memcpy(output, accepted_downward_salt_mol);
        return .{ .iterations = options.max_iterations, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .maximum_scaled_residual = final_norm, .anderson_steps = anderson_steps };
    }
    return error.SnowTransportSolverDidNotConverge;
}

fn acceptedSaltTarget(
    allocator: std.mem.Allocator,
    scratch: *const snow.State,
    inputs: Inputs,
    target: []f64,
    output_discharge: []snow.SurfaceDischarge,
    accepted_downward_mol: []f64,
) !void {
    if (target.len != scratch.salt_amount_mol.len or accepted_downward_mol.len != target.len or output_discharge.len != scratch.cell_count)
        return error.SnowTransportInputSizeMismatch;
    @memset(accepted_downward_mol, 0);
    const salt_with_input = try allocator.dupe(f64, scratch.salt_amount_mol);
    defer allocator.free(salt_with_input);
    for (0..scratch.cell_count) |cell| {
        const top = cell * scratch.layer_capacity;
        for (0..snow.salt_species_count) |species| {
            const input_mol = if (inputs.atmospheric_top_input_salt_mol.len == 0)
                0
            else
                inputs.atmospheric_top_input_salt_mol[cell * snow.salt_species_count + species];
            const next = salt_with_input[top * snow.salt_species_count + species] + input_mol;
            if (!std.math.isFinite(next) or next < 0) return error.InvalidImplicitSnowCandidate;
            salt_with_input[top * snow.salt_species_count + species] = next;
        }
    }
    var salt_scratch = scratch.*;
    salt_scratch.salt_amount_mol = salt_with_input;
    var fluxes = try snow.calculateFluxes(allocator, &salt_scratch, inputs.water_flux_to_lower_m3, inputs.litter_water_flux_m3, inputs.soil_micropore_water_flux_m3, inputs.soil_macropore_water_flux_m3, inputs.surface_partitions, .{ .water_absolute_m3 = inputs.water_flux_absolute_tolerance_m3, .relative = inputs.water_flux_relative_tolerance });
    defer fluxes.deinit();
    @memcpy(target, salt_with_input);
    for (0..scratch.cell_count) |cell| {
        output_discharge[cell].litter_salt_mol = fluxes.surface_discharge[cell].litter_salt_mol;
        output_discharge[cell].soil_nonband_salt_mol = fluxes.surface_discharge[cell].soil_nonband_salt_mol;
        output_discharge[cell].soil_band_salt_mol = fluxes.surface_discharge[cell].soil_band_salt_mol;
        var discharged = false;
        for (0..scratch.layer_capacity) |layer| {
            const index = try scratch.layerIndex(cell, layer);
            if (!scratch.active[index]) continue;
            const has_lower = layer + 1 < scratch.layer_capacity and scratch.active[try scratch.layerIndex(cell, layer + 1)];
            for (0..snow.salt_species_count) |species| {
                const component = index * snow.salt_species_count + species;
                const requested_downward = fluxes.downward_salt_mol[component];
                const actual_downward = @min(target[component], requested_downward);
                target[component] -= actual_downward;
                if (has_lower) {
                    target[(index + 1) * snow.salt_species_count + species] += actual_downward;
                    accepted_downward_mol[component] = actual_downward;
                }
                if (!has_lower and !discharged) {
                    const discharge = &output_discharge[cell];
                    const requested = discharge.litter_salt_mol[species] + discharge.soil_nonband_salt_mol[species] + discharge.soil_band_salt_mol[species];
                    const actual = @min(target[component], requested);
                    target[component] -= actual;
                    if (requested > 0 and actual < requested) {
                        const scale = actual / requested;
                        discharge.litter_salt_mol[species] *= scale;
                        discharge.soil_nonband_salt_mol[species] *= scale;
                        discharge.soil_band_salt_mol[species] *= scale;
                    }
                }
            }
            if (!has_lower and !discharged) discharged = true;
        }
    }
    for (target) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidImplicitSnowCandidate;
}

fn residualAt(allocator: std.mem.Allocator, scratch: *snow.State, base: []const f64, trial: []const f64, inputs: Inputs, target: []f64, residual: []f64, output_discharge: ?[]snow.SurfaceDischarge, accepted_downward_g: ?[]f64) !void {
    // REDIST transports the hour's accepted source inventory: storage at the
    // start of the transport process plus precipitation/irrigation entering
    // the top layer. It does not repeatedly recompute a different physical
    // flux from each nonlinear trial. Apart from changing source order, using
    // `trial` here also stranded half the chemistry when the carrier drained
    // completely (the fixed point of M = M0 - M is M0/2). Keep flux physics
    // fixed at the process source; Newton/Anderson solve only the conservative
    // state image and a full carrier discharge therefore exports all species.
    @memcpy(scratch.amount_g, base);
    for (0..scratch.cell_count) |cell| {
        const top = try scratch.layerIndex(cell, 0);
        for (0..snow.species_count) |species|
            scratch.amount_g[top * snow.species_count + species] += inputs.atmospheric_top_input_g[cell * snow.species_count + species];
    }
    var fluxes = try snow.calculateFluxes(allocator, scratch, inputs.water_flux_to_lower_m3, inputs.litter_water_flux_m3, inputs.soil_micropore_water_flux_m3, inputs.soil_macropore_water_flux_m3, inputs.surface_partitions, .{ .water_absolute_m3 = inputs.water_flux_absolute_tolerance_m3, .relative = inputs.water_flux_relative_tolerance });
    defer fluxes.deinit();
    @memcpy(target, scratch.amount_g);
    if (accepted_downward_g) |output| @memset(output, 0);
    for (0..scratch.cell_count) |cell| {
        var discharged = false;
        for (0..scratch.layer_capacity) |layer| {
            const index = try scratch.layerIndex(cell, layer);
            if (!scratch.active[index]) continue;
            const has_lower = layer + 1 < scratch.layer_capacity and scratch.active[try scratch.layerIndex(cell, layer + 1)];
            for (0..snow.species_count) |species| {
                const component = index * snow.species_count + species;
                const downward = fluxes.downward_g[component];
                const actual_downward = @min(target[component], downward);
                target[component] -= actual_downward;
                if (has_lower) {
                    target[(index + 1) * snow.species_count + species] += actual_downward;
                    if (accepted_downward_g) |output| output[component] = actual_downward;
                }
                if (!has_lower and !discharged) {
                    // The discharge handed to the caller must be what storage
                    // actually gave up, not what the flux calculation asked
                    // for. `calculateFluxes` derives the request from the
                    // accepted source inventory, while the debit below is
                    // bounded by the staged target; when the bound applies, the unscaled
                    // request would credit the litter and soil receivers with
                    // solute that was never removed from the snowpack, which
                    // is a mass source the receiving ledgers cannot detect.
                    // Scaling all three destinations by the same factor
                    // preserves the litter/nonband/band split exactly.
                    const discharge = &fluxes.surface_discharge[cell];
                    const requested = discharge.litter_g[species] + discharge.soil_nonband_g[species] + discharge.soil_band_g[species];
                    const actual = @min(target[component], requested);
                    target[component] -= actual;
                    if (requested > 0 and actual < requested) {
                        const scale = actual / requested;
                        discharge.litter_g[species] *= scale;
                        discharge.soil_nonband_g[species] *= scale;
                        discharge.soil_band_g[species] *= scale;
                    }
                }
            }
            if (!has_lower and !discharged) discharged = true;
        }
    }
    if (output_discharge) |output| @memcpy(output, fluxes.surface_discharge);
    for (target, trial, residual) |fixed_point, value, *difference| {
        if (!std.math.isFinite(fixed_point) or fixed_point < 0) return error.InvalidImplicitSnowCandidate;
        difference.* = fixed_point - value;
    }
}

fn validate(state: *const snow.State, inputs: Inputs, options: Options, output: []snow.SurfaceDischarge) !void {
    const layers = try std.math.mul(usize, state.cell_count, state.layer_capacity);
    if (inputs.atmospheric_top_input_g.len != state.cell_count * snow.species_count or
        (inputs.atmospheric_top_input_salt_mol.len != 0 and inputs.atmospheric_top_input_salt_mol.len != state.cell_count * snow.salt_species_count) or
        inputs.transport_water_volume_m3.len != layers or inputs.water_flux_to_lower_m3.len != layers or inputs.litter_water_flux_m3.len != state.cell_count or inputs.soil_micropore_water_flux_m3.len != state.cell_count or inputs.soil_macropore_water_flux_m3.len != state.cell_count or inputs.surface_partitions.len != state.cell_count or output.len != state.cell_count) return error.SnowTransportInputSizeMismatch;
    if (inputs.accepted_downward_g) |accepted|
        if (accepted.len != state.amount_g.len) return error.SnowTransportInputSizeMismatch;
    if (inputs.accepted_downward_salt_mol) |accepted|
        if (accepted.len != state.salt_amount_mol.len) return error.SnowTransportInputSizeMismatch;
    for (inputs.atmospheric_top_input_salt_mol) |amount_mol|
        if (!std.math.isFinite(amount_mol) or amount_mol < 0) return error.InvalidSnowTransportInput;
    if (!std.math.isFinite(inputs.water_flux_absolute_tolerance_m3) or inputs.water_flux_absolute_tolerance_m3 < 0 or
        !std.math.isFinite(inputs.water_flux_relative_tolerance) or inputs.water_flux_relative_tolerance <= 0)
        return error.InvalidSnowTransportInput;
    for (options.absolute_tolerance_g_by_species) |tolerance_g|
        if (!std.math.isFinite(tolerance_g) or tolerance_g <= 0) return error.InvalidSnowTransportSolverOptions;
    if (!options.anderson_recovery or (!std.math.isNan(options.absolute_tolerance_g) and (!std.math.isFinite(options.absolute_tolerance_g) or options.absolute_tolerance_g <= 0)) or !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or !std.math.isFinite(options.directional_probe_fraction) or options.directional_probe_fraction <= 0 or !std.math.isFinite(options.minimum_newton_fraction) or options.minimum_newton_fraction <= 0 or !std.math.isFinite(options.maximum_newton_fraction) or options.maximum_newton_fraction < options.minimum_newton_fraction or options.maximum_newton_fraction > 1 or options.max_iterations == 0 or options.divergence_patience == 0 or !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1) return error.InvalidSnowTransportSolverOptions;
}

fn addDirection(current: []const f64, direction: []const f64, fraction: f64, output: []f64) !void {
    for (current, direction, output) |value, delta, *candidate| {
        candidate.* = value + fraction * delta;
        if (!std.math.isFinite(candidate.*) or candidate.* < 0) return error.InvalidImplicitSnowCandidate;
    }
}

fn scaledNorm(state: []const f64, residual: []const f64, options: Options) !f64 {
    var maximum: f64 = 0;
    for (state, residual, 0..) |value, difference, index| {
        if (!std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference)) return error.NonFiniteImplicitSnowState;
        maximum = @max(maximum, @abs(difference) / (absoluteToleranceForSpecies(options, index % snow.species_count) + options.relative_tolerance * @abs(value)));
    }
    return maximum;
}

fn absoluteToleranceForSpecies(options: Options, species: usize) f64 {
    return if (std.math.isFinite(options.absolute_tolerance_g) and options.absolute_tolerance_g > 0)
        options.absolute_tolerance_g
    else
        options.absolute_tolerance_g_by_species[species];
}

test "snow transport preserves species-specific nonlinear floors" {
    var tolerances: [snow.species_count]f64 = @splat(1e-12);
    tolerances[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 1e-9;
    tolerances[@intFromEnum(snow.Species.ammonium_nitrogen)] = 2e-10;
    const options: Options = .{ .absolute_tolerance_g_by_species = tolerances };
    try std.testing.expectEqual(@as(f64, 1e-9), absoluteToleranceForSpecies(options, @intFromEnum(snow.Species.carbon_dioxide_carbon)));
    try std.testing.expectEqual(@as(f64, 2e-10), absoluteToleranceForSpecies(options, @intFromEnum(snow.Species.ammonium_nitrogen)));
    try std.testing.expectEqual(@as(f64, 1e-12), absoluteToleranceForSpecies(options, @intFromEnum(snow.Species.calcium)));
}

fn testPartition() snow.SurfacePartition {
    return .{ .litter_cover_fraction = 0.25, .bare_soil_fraction = 0.75, .nonband_ammonium_fraction = 0.6, .band_ammonium_fraction = 0.4, .nonband_nitrate_fraction = 0.7, .band_nitrate_fraction = 0.3, .nonband_phosphate_fraction = 0.8, .band_phosphate_fraction = 0.2 };
}

test "snow hybrid converges before legacy 20 iteration ceiling" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    state.active[0] = true;
    state.active[1] = true;
    state.liquid_water_volume_m3[0] = 2;
    state.liquid_water_volume_m3[1] = 2;
    @memset(try state.amounts(0, 0), 10);
    var discharge: [1]snow.SurfaceDischarge = undefined;
    const zero_input = [_]f64{0} ** snow.species_count;
    const result = try solve(std.testing.allocator, &state, .{ .atmospheric_top_input_g = &zero_input, .transport_water_volume_m3 = state.liquid_water_volume_m3, .water_flux_to_lower_m3 = &[_]f64{ 0, 0.2 }, .litter_water_flux_m3 = &[_]f64{0.1}, .soil_micropore_water_flux_m3 = &[_]f64{0.1}, .soil_macropore_water_flux_m3 = &[_]f64{0}, .surface_partitions = &[_]snow.SurfacePartition{testPartition()} }, .{}, &discharge);
    try std.testing.expect(result.iterations < 20);
    try std.testing.expect(result.newton_raphson_steps + result.picard_steps > 0);
}

test "snow transport first fallback is Anderson accelerated" {
    // Conformance guard for the v1.0.0 brief: this solver's only nonlinear
    // fallback must be Anderson-accelerated Picard, never plain Picard.
    // A private test seam rejects the first Newton attempt without weakening
    // any production bound or tolerance. The accepted Anderson candidate must
    // then be followed immediately by a real Newton retry.
    const zero_input = [_]f64{0} ** snow.species_count;
    const partitions = [_]snow.SurfacePartition{testPartition()};
    const forced_recovery: Options = .{ .max_iterations = 20 };
    var control: TestControl = .{ .forced_initial_newton_failures = 1 };

    var with_state = try snow.State.init(std.testing.allocator, 1, 2);
    defer with_state.deinit();
    with_state.active[0] = true;
    with_state.active[1] = true;
    with_state.liquid_water_volume_m3[0] = 2;
    with_state.liquid_water_volume_m3[1] = 2;
    @memset(try with_state.amounts(0, 0), 10);
    var with_discharge: [1]snow.SurfaceDischarge = undefined;
    const with_recovery = try solveControlled(std.testing.allocator, &with_state, .{ .atmospheric_top_input_g = &zero_input, .transport_water_volume_m3 = with_state.liquid_water_volume_m3, .water_flux_to_lower_m3 = &[_]f64{ 0, 0.2 }, .litter_water_flux_m3 = &[_]f64{0.1}, .soil_micropore_water_flux_m3 = &[_]f64{0.1}, .soil_macropore_water_flux_m3 = &[_]f64{0}, .surface_partitions = &partitions }, forced_recovery, &with_discharge, &control);
    try std.testing.expect(with_recovery.picard_steps > 0);
    try std.testing.expectEqual(with_recovery.picard_steps, with_recovery.anderson_steps);
    try std.testing.expect(with_recovery.maximum_scaled_residual <= 1);
    try std.testing.expect(control.event_count >= 3);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[0]);
    try std.testing.expectEqual(MethodEvent.anderson_accept, control.events[1]);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[2]);
}

test "snow transport final-slot Anderson is rejected atomically" {
    const zero_input = [_]f64{0} ** snow.species_count;
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    state.active[0] = true;
    state.active[1] = true;
    state.liquid_water_volume_m3[0] = 2;
    state.liquid_water_volume_m3[1] = 2;
    @memset(try state.amounts(0, 0), 10);
    const before = try std.testing.allocator.dupe(f64, state.amount_g);
    defer std.testing.allocator.free(before);
    var discharge = [_]snow.SurfaceDischarge{std.mem.zeroes(snow.SurfaceDischarge)};
    var control: TestControl = .{ .forced_initial_newton_failures = 1 };
    try std.testing.expectError(error.SnowTransportSolverDidNotConverge, solveControlled(std.testing.allocator, &state, .{ .atmospheric_top_input_g = &zero_input, .transport_water_volume_m3 = state.liquid_water_volume_m3, .water_flux_to_lower_m3 = &[_]f64{ 0, 0.2 }, .litter_water_flux_m3 = &[_]f64{0.1}, .soil_micropore_water_flux_m3 = &[_]f64{0.1}, .soil_macropore_water_flux_m3 = &[_]f64{0}, .surface_partitions = &[_]snow.SurfacePartition{testPartition()} }, .{ .max_iterations = 1 }, &discharge, &control));
    try std.testing.expectEqualSlices(f64, before, state.amount_g);
    try std.testing.expectEqual(@as(usize, 1), control.event_count);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[0]);
}

test "snow transport rejects disabled Anderson recovery" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.active[0] = true;
    state.liquid_water_volume_m3[0] = 1;
    var discharge: [1]snow.SurfaceDischarge = undefined;
    const zero_input = [_]f64{0} ** snow.species_count;
    try std.testing.expectError(error.InvalidSnowTransportSolverOptions, solve(std.testing.allocator, &state, .{ .atmospheric_top_input_g = &zero_input, .transport_water_volume_m3 = state.liquid_water_volume_m3, .water_flux_to_lower_m3 = &[_]f64{0}, .litter_water_flux_m3 = &[_]f64{0}, .soil_micropore_water_flux_m3 = &[_]f64{0}, .soil_macropore_water_flux_m3 = &[_]f64{0}, .surface_partitions = &[_]snow.SurfacePartition{testPartition()} }, .{ .anderson_recovery = false }, &discharge));
}

test "snow transport conserves mass regardless of accepted convergence slack" {
    // Regression guard for SNOW-SOLVER-TOLERANCE-SLACK-001. The solver is
    // deliberately given a very loose relative tolerance, so it accepts after
    // one iteration with a large self-declared residual. Conservation must not
    // depend on that: storage plus discharge must still equal the initial
    // amount plus the atmospheric input. Before the fix this test fails,
    // because the state_updateted state was the trial rather than its conservative
    // fixed-point image.
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    state.active[0] = true;
    state.active[1] = true;
    state.liquid_water_volume_m3[0] = 2;
    state.liquid_water_volume_m3[1] = 2;
    @memset(try state.amounts(0, 0), 10);
    @memset(try state.amounts(0, 1), 4);
    var discharge: [1]snow.SurfaceDischarge = undefined;
    const input = [_]f64{0.5} ** snow.species_count;
    var before: f64 = 0;
    for (state.amount_g) |value| before += value;
    for (input) |value| before += value;
    const result = try solve(std.testing.allocator, &state, .{
        .atmospheric_top_input_g = &input,
        .transport_water_volume_m3 = state.liquid_water_volume_m3,
        .water_flux_to_lower_m3 = &[_]f64{ 0, 0.7 },
        .litter_water_flux_m3 = &[_]f64{0.4},
        .soil_micropore_water_flux_m3 = &[_]f64{0.3},
        .soil_macropore_water_flux_m3 = &[_]f64{0},
        .surface_partitions = &[_]snow.SurfacePartition{testPartition()},
    }, .{ .relative_tolerance = 1e6, .absolute_tolerance_g = 1e6 }, &discharge);
    // Confirm the loose tolerance really did leave slack on the table, so the
    // conservation assertion below is not passing for the trivial reason that
    // the solver converged tightly anyway.
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    var after: f64 = 0;
    for (state.amount_g) |value| after += value;
    for (discharge[0].litter_g, discharge[0].soil_nonband_g, discharge[0].soil_band_g) |a, b, c| after += a + b + c;
    // Relative check: `before` is O(261), so the tolerance here covers only
    // a few ULP of the summation itself, not any solver slack.
    try std.testing.expectApproxEqRel(before, after, 1e-14);
}

test "production-scale retained snow nitrogen closes at the deck audit tolerance" {
    // Ottawa first retains snow solute at hour 20 with about 6.48e-2 g N in
    // storage. Exercise that scale with the public deck's 1e-8 relative and
    // 1e-11 absolute tolerances. The historical max(1, |value|) norm permits
    // component iteration slack near 1e-8 at this scale, but accepted slack
    // must never be published as mass. The unchanged production ceiling is 20.
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    state.active[0] = true;
    state.active[1] = true;
    state.liquid_water_volume_m3[0] = 1;
    state.liquid_water_volume_m3[1] = 1;

    const nitrogen_species = [_]snow.Species{
        .dinitrogen_nitrogen,
        .nitrous_oxide_nitrogen,
        .ammonium_nitrogen,
        .ammonia_nitrogen,
        .nitrate_nitrogen,
    };
    const top_nitrogen_g = [_]f64{ 0.01, 0.004, 0.02, 0.00084523, 0.03 };
    const lower_nitrogen_g = [_]f64{ 0.002, 0.001, 0.003, 0.001, 0.003 };
    const input_nitrogen_g = [_]f64{ 0.002, 0.001, 0.004, 0.00111294, 0.004 };
    var atmospheric_input = [_]f64{0} ** snow.species_count;
    for (nitrogen_species, top_nitrogen_g, lower_nitrogen_g, input_nitrogen_g) |species, top, lower, input| {
        const species_index = @intFromEnum(species);
        (try state.amounts(0, 0))[species_index] = top;
        (try state.amounts(0, 1))[species_index] = lower;
        atmospheric_input[species_index] = input;
    }

    var expected_nitrogen_g: f64 = 0;
    for (state.amount_g) |value| expected_nitrogen_g += value;
    for (atmospheric_input) |value| expected_nitrogen_g += value;
    var discharge: [1]snow.SurfaceDischarge = undefined;
    const result = try solve(std.testing.allocator, &state, .{
        .atmospheric_top_input_g = &atmospheric_input,
        .transport_water_volume_m3 = state.liquid_water_volume_m3,
        .water_flux_to_lower_m3 = &[_]f64{ 0, 0.2 },
        .litter_water_flux_m3 = &[_]f64{0.1},
        .soil_micropore_water_flux_m3 = &[_]f64{0.1},
        .soil_macropore_water_flux_m3 = &[_]f64{0},
        .surface_partitions = &[_]snow.SurfacePartition{testPartition()},
    }, .{
        .absolute_tolerance_g = 1e-11,
        .relative_tolerance = 1e-8,
        .max_iterations = 20,
    }, &discharge);

    var observed_nitrogen_g: f64 = 0;
    for (state.amount_g) |value| observed_nitrogen_g += value;
    for (discharge[0].litter_g, discharge[0].soil_nonband_g, discharge[0].soil_band_g, 0..) |litter, nonband, band, species_index| {
        const species: snow.Species = @enumFromInt(species_index);
        switch (species) {
            .dinitrogen_nitrogen, .nitrous_oxide_nitrogen, .ammonium_nitrogen, .ammonia_nitrogen, .nitrate_nitrogen => observed_nitrogen_g += litter + nonband + band,
            else => {},
        }
    }
    const conservation_residual_g_n = observed_nitrogen_g - expected_nitrogen_g;
    try std.testing.expect(result.iterations <= 20);
    // Conservation must hold to within floating-point summation rounding.
    // The residual is ~1e-17 (one ULP at scale ~0.087 g), not the ~1e-9 slack
    // that the old max(1,|v|) norm was injecting. Use 1e-14 absolute tolerance
    // (well above any ULP rounding, well below any real conservation defect).
    try std.testing.expectApproxEqAbs(@as(f64, 0), conservation_residual_g_n, 1e-14);
}

test "snow surface discharge never exceeds what storage gave up" {
    // The exported discharge is scaled to the clipped debit. With storage far
    // below the requested outflow the clip must bind, and the discharge must
    // then equal exactly the amount removed rather than the request.
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.active[0] = true;
    state.liquid_water_volume_m3[0] = 1;
    @memset(try state.amounts(0, 0), 1e-9);
    var discharge: [1]snow.SurfaceDischarge = undefined;
    const zero_input = [_]f64{0} ** snow.species_count;
    var before: f64 = 0;
    for (state.amount_g) |value| before += value;
    _ = try solve(std.testing.allocator, &state, .{
        .atmospheric_top_input_g = &zero_input,
        .transport_water_volume_m3 = state.liquid_water_volume_m3,
        .water_flux_to_lower_m3 = &[_]f64{0},
        .litter_water_flux_m3 = &[_]f64{0.5},
        .soil_micropore_water_flux_m3 = &[_]f64{0.5},
        .soil_macropore_water_flux_m3 = &[_]f64{0},
        .surface_partitions = &[_]snow.SurfacePartition{testPartition()},
    }, .{ .relative_tolerance = 1e6, .absolute_tolerance_g = 1e6 }, &discharge);
    var after: f64 = 0;
    for (state.amount_g) |value| after += value;
    var discharged: f64 = 0;
    for (discharge[0].litter_g, discharge[0].soil_nonband_g, discharge[0].soil_band_g) |a, b, c| discharged += a + b + c;
    try std.testing.expectApproxEqAbs(before, after + discharged, 1e-18);
    try std.testing.expect(discharged <= before + 1e-18);
}

test "accepted internal transfer ledger equals committed donor and recipient changes" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    state.active[0] = true;
    state.active[1] = true;
    state.dynamic_salts_by_cell[0] = true;
    state.liquid_water_volume_m3[0] = 1;
    state.liquid_water_volume_m3[1] = 1;
    for (try state.amounts(0, 0), 0..) |*amount, species| amount.* = @floatFromInt(species + 1);
    for (try state.saltAmounts(0, 0), 0..) |*amount, species| amount.* = @as(f64, @floatFromInt(species + 1)) / 100;
    const before_g = try std.testing.allocator.dupe(f64, state.amount_g);
    defer std.testing.allocator.free(before_g);
    const before_salt = try std.testing.allocator.dupe(f64, state.salt_amount_mol);
    defer std.testing.allocator.free(before_salt);
    var accepted_g = [_]f64{-1} ** (2 * snow.species_count);
    var accepted_salt = [_]f64{-1} ** (2 * snow.salt_species_count);
    var discharge: [1]snow.SurfaceDischarge = undefined;
    const zero_input = [_]f64{0} ** snow.species_count;
    _ = try solve(std.testing.allocator, &state, .{
        .atmospheric_top_input_g = &zero_input,
        .transport_water_volume_m3 = state.liquid_water_volume_m3,
        .water_flux_to_lower_m3 = &[_]f64{ 0, 0.25 },
        .litter_water_flux_m3 = &[_]f64{0},
        .soil_micropore_water_flux_m3 = &[_]f64{0},
        .soil_macropore_water_flux_m3 = &[_]f64{0},
        .surface_partitions = &[_]snow.SurfacePartition{testPartition()},
        .accepted_downward_g = &accepted_g,
        .accepted_downward_salt_mol = &accepted_salt,
    }, .{}, &discharge);

    for (0..snow.species_count) |species| {
        const upper = species;
        const lower = snow.species_count + species;
        try std.testing.expectApproxEqAbs(before_g[upper] - state.amount_g[upper], accepted_g[upper], 1e-13);
        try std.testing.expectApproxEqAbs(state.amount_g[lower] - before_g[lower], accepted_g[upper], 1e-13);
        try std.testing.expectEqual(@as(f64, 0), accepted_g[lower]);
    }
    for (0..snow.salt_species_count) |species| {
        const upper = species;
        const lower = snow.salt_species_count + species;
        try std.testing.expectApproxEqAbs(before_salt[upper] - state.salt_amount_mol[upper], accepted_salt[upper], 1e-15);
        try std.testing.expectApproxEqAbs(state.salt_amount_mol[lower] - before_salt[lower], accepted_salt[upper], 1e-15);
        try std.testing.expectEqual(@as(f64, 0), accepted_salt[lower]);
    }
}

test "multi-hour dynamic atmospheric chemistry is retained then fully discharged on snow disappearance" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.active[0] = true;
    state.dynamic_salts_by_cell[0] = true;
    state.liquid_water_volume_m3[0] = 1;
    var primary_input: [snow.species_count]f64 = undefined;
    var salt_input: [snow.salt_species_count]f64 = undefined;
    for (&primary_input, 0..) |*value, species| value.* = @as(f64, @floatFromInt(species + 1)) / 100;
    for (&salt_input, 0..) |*value, species| value.* = @as(f64, @floatFromInt(species + 1)) / 1000;
    var discharge: [1]snow.SurfaceDischarge = undefined;

    // Hour one: equilibrium-derived precipitation enters the 10 primary and
    // full 41-species dynamic owner without melt.
    _ = try solve(std.testing.allocator, &state, .{
        .atmospheric_top_input_g = &primary_input,
        .atmospheric_top_input_salt_mol = &salt_input,
        .transport_water_volume_m3 = state.liquid_water_volume_m3,
        .water_flux_to_lower_m3 = &[_]f64{0},
        .litter_water_flux_m3 = &[_]f64{0},
        .soil_micropore_water_flux_m3 = &[_]f64{0},
        .soil_macropore_water_flux_m3 = &[_]f64{0},
        .surface_partitions = &[_]snow.SurfacePartition{testPartition()},
    }, .{}, &discharge);
    try std.testing.expectEqualSlices(f64, &primary_input, state.amount_g);
    try std.testing.expectEqualSlices(f64, &salt_input, state.salt_amount_mol);

    // Hour two: another equilibrium input arrives while the complete liquid
    // carrier leaves. No primary, free ion, or complex may remain stranded in
    // the now-disappeared snow layer.
    _ = try solve(std.testing.allocator, &state, .{
        .atmospheric_top_input_g = &primary_input,
        .atmospheric_top_input_salt_mol = &salt_input,
        .transport_water_volume_m3 = state.liquid_water_volume_m3,
        .water_flux_to_lower_m3 = &[_]f64{0},
        .litter_water_flux_m3 = &[_]f64{0.4},
        .soil_micropore_water_flux_m3 = &[_]f64{0.6},
        .soil_macropore_water_flux_m3 = &[_]f64{0},
        .surface_partitions = &[_]snow.SurfacePartition{testPartition()},
    }, .{}, &discharge);
    for (state.amount_g) |value| try std.testing.expectApproxEqAbs(@as(f64, 0), value, 1e-15);
    for (state.salt_amount_mol) |value| try std.testing.expectApproxEqAbs(@as(f64, 0), value, 1e-15);
    for (0..snow.species_count) |species| {
        const routed = discharge[0].litter_g[species] + discharge[0].soil_nonband_g[species] + discharge[0].soil_band_g[species];
        try std.testing.expectApproxEqAbs(2 * primary_input[species], routed, 1e-14);
    }
    for (0..snow.salt_species_count) |species| {
        const routed = discharge[0].litter_salt_mol[species] + discharge[0].soil_nonband_salt_mol[species] + discharge[0].soil_band_salt_mol[species];
        try std.testing.expectApproxEqAbs(2 * salt_input[species], routed, 1e-14);
    }
}

test "snow transport accepts convergence reached by the final allowed update" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.active[0] = true;
    state.liquid_water_volume_m3[0] = 1;
    state.amount_g[0] = 1;
    var discharge: [1]snow.SurfaceDischarge = undefined;
    const zero_input = [_]f64{0} ** snow.species_count;
    var accepted_g = [_]f64{17} ** snow.species_count;
    var accepted_salt = [_]f64{19} ** snow.salt_species_count;
    const result = try solve(std.testing.allocator, &state, .{ .atmospheric_top_input_g = &zero_input, .transport_water_volume_m3 = state.liquid_water_volume_m3, .water_flux_to_lower_m3 = &[_]f64{0}, .litter_water_flux_m3 = &[_]f64{0.2}, .soil_micropore_water_flux_m3 = &[_]f64{0}, .soil_macropore_water_flux_m3 = &[_]f64{0}, .surface_partitions = &[_]snow.SurfacePartition{testPartition()}, .accepted_downward_g = &accepted_g, .accepted_downward_salt_mol = &accepted_salt }, .{ .max_iterations = 1 }, &discharge);
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    try std.testing.expectEqual(@as(u16, 1), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), result.picard_steps);
    try std.testing.expect(result.maximum_scaled_residual <= 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), state.amount_g[0], 1e-15);
}

test "failed snow hybrid leaves caller state unchanged after final audit" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.active[0] = true;
    state.liquid_water_volume_m3[0] = 1;
    state.amount_g[0] = 1;
    var discharge = [_]snow.SurfaceDischarge{.{}};
    const discharge_before = discharge;
    const zero_input = [_]f64{0} ** snow.species_count;
    var accepted_g = [_]f64{17} ** snow.species_count;
    var accepted_salt = [_]f64{19} ** snow.salt_species_count;
    try std.testing.expectError(error.SnowTransportSolverDidNotConverge, solve(std.testing.allocator, &state, .{ .atmospheric_top_input_g = &zero_input, .transport_water_volume_m3 = state.liquid_water_volume_m3, .water_flux_to_lower_m3 = &[_]f64{0}, .litter_water_flux_m3 = &[_]f64{0.2}, .soil_micropore_water_flux_m3 = &[_]f64{0}, .soil_macropore_water_flux_m3 = &[_]f64{0}, .surface_partitions = &[_]snow.SurfacePartition{testPartition()}, .accepted_downward_g = &accepted_g, .accepted_downward_salt_mol = &accepted_salt }, .{ .max_iterations = 1, .minimum_newton_fraction = 0.5, .maximum_newton_fraction = 0.5 }, &discharge));
    try std.testing.expectEqual(@as(f64, 1), state.amount_g[0]);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&discharge_before), std.mem.asBytes(&discharge));
    for (accepted_g) |value| try std.testing.expectEqual(@as(f64, 17), value);
    for (accepted_salt) |value| try std.testing.expectEqual(@as(f64, 19), value);
}

test "snow transport rejects degenerate divergence watch options" {
    // The conformance audit flags the absence of any oscillation/divergence
    // detector as universal. This solver is vector-valued over layers and
    // species, so it cannot delegate to the shared scalar solver and carries its
    // own detector; its tuning knobs must be validated the same way
    // `core/numerics.zig` validates its own, so the detector cannot be silently
    // disabled by a nonsense value. Before the detector existed neither option
    // was present and this test could not compile.
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.active[0] = true;
    state.liquid_water_volume_m3[0] = 1;
    state.amount_g[0] = 1;
    var discharge: [1]snow.SurfaceDischarge = undefined;
    const zero_input = [_]f64{0} ** snow.species_count;
    const inputs: Inputs = .{
        .atmospheric_top_input_g = &zero_input,
        .transport_water_volume_m3 = state.liquid_water_volume_m3,
        .water_flux_to_lower_m3 = &[_]f64{0},
        .litter_water_flux_m3 = &[_]f64{0.05},
        .soil_micropore_water_flux_m3 = &[_]f64{0},
        .soil_macropore_water_flux_m3 = &[_]f64{0},
        .surface_partitions = &[_]snow.SurfacePartition{testPartition()},
    };
    // A patience of zero would fire on the first non-improving iteration and a
    // growth factor below one would fire on an improving one. Both are refused.
    try std.testing.expectError(error.InvalidSnowTransportSolverOptions, solve(std.testing.allocator, &state, inputs, .{ .divergence_patience = 0 }, &discharge));
    try std.testing.expectError(error.InvalidSnowTransportSolverOptions, solve(std.testing.allocator, &state, inputs, .{ .divergence_growth_factor = 0.5 }, &discharge));
    try std.testing.expectError(error.InvalidSnowTransportSolverOptions, solve(std.testing.allocator, &state, inputs, .{ .divergence_growth_factor = std.math.nan(f64) }, &discharge));
    // CONTROL: the same inputs with the default watch converge, so the
    // rejections above are proving option validation rather than that these
    // inputs cannot be solved at all.
    _ = try solve(std.testing.allocator, &state, inputs, .{}, &discharge);
    // CONTROL: an admissible non-default watch is accepted, so validation is not
    // simply refusing everything that is not the default.
    _ = try solve(std.testing.allocator, &state, inputs, .{ .divergence_patience = 2, .divergence_growth_factor = 10 }, &discharge);
}
