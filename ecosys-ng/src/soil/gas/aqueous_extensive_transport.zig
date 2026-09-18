const std = @import("std");
const builtin = @import("builtin");
const numerics = @import("../../core/numerics.zig");
const scoped_conservation = @import("../../validation/scoped_conservation.zig");
const solute_transport = @import("../solute/transport.zig");
const Face = solute_transport.Face;

pub const Options = struct {
    /// Per-species nonlinear absolute residual floors, in the extensive unit
    /// used by the corresponding species. Preferred for mixed-unit vectors.
    absolute_tolerance_by_species: []const f64 = &.{},
    /// Legacy homogeneous-unit fallback retained for callers that transport a
    /// single unit family. Mixed-unit production callers must provide the
    /// per-species vector above.
    absolute_tolerance: f64 = 1e-12,
    relative_tolerance: f64,
    /// Independent physical conservation floors in each species' extensive
    /// unit. Zero requests no user absolute floor; the relative activity
    /// criterion remains active. These values are never used for nonlinear
    /// convergence.
    conservation_absolute_tolerance_by_species: []const f64 = &.{},
    conservation_absolute_tolerance: f64 = 0,
    conservation_absolute_tolerance_g_per_m2_by_species: []const f64 = &.{},
    conservation_relative_tolerance: f64 = 1.0e-9,
    soil_layer_capacity: usize = 0,
    horizontal_cell_area_m2: []const f64 = &.{},
    picard_relaxation: f64,
    max_iterations: u16,
    maximum_convective_fraction: f64 = 1,
    pore_exchange_fraction: f64 = 1,
    /// Divergence/oscillation watch, mirroring `core/numerics.zig`. This
    /// solver is vector-valued over layers and species, so it cannot
    /// delegate to the shared scalar solver and carries its own detector.
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    /// Required depth-one Anderson acceleration. The relaxed fixed-point
    /// sample seeds the accelerator but is never an accepted fallback.
    anderson_recovery: bool = true,
    /// Accepted signed face fluxes in the transported extensive unit,
    /// face-major/species. Positive is first_cell -> second_cell. Supply both
    /// pore-domain outputs or neither; publication is transaction-atomic.
    micropore_face_flux_by_component: ?[]f64 = null,
    macropore_face_flux_by_component: ?[]f64 = null,
};

pub const Inputs = struct {
    species_count: usize,
    /// Runtime DLYRM layer mask. Empty keeps standalone callers all-active.
    active_by_layer: []const bool = &.{},
    faces: []const Face,
    micropore_conductance_m3_per_step: []const f64,
    macropore_conductance_m3_per_step: []const f64,
    micropore_water_m3: []const f64,
    macropore_water_m3: []const f64,
    layer_bulk_volume_m3: []const f64,
    micropore_external_water_flux_m3_per_step: []const f64,
    macropore_external_water_flux_m3_per_step: []const f64,
    macropore_to_matrix_water_flux_m3_per_step: []const f64 = &.{},
    recharge_concentration_per_m3: []const f64,
    /// Deterministic test-only defect injection after every physical update
    /// and before local acceptance. Production builds reject this field.
    test_conservation_perturbation_by_component: ?[]const f64 = null,
};

pub const Result = struct {
    micropore_iterations: u16,
    macropore_iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    anderson_steps: u16 = 0,
};

/// Runtime-species extensive aqueous transport. Units may be grams or moles,
/// but every amount, concentration, tolerance, and boundary ledger supplied
/// to one invocation must use the same explicit extensive unit.
pub fn advance(
    allocator: std.mem.Allocator,
    micropore_amount: []f64,
    macropore_amount: []f64,
    boundary_net_flux: []f64,
    inputs: Inputs,
    options: Options,
) !Result {
    try validate(micropore_amount, macropore_amount, boundary_net_flux, inputs, options);
    const micro_before = try allocator.dupe(f64, micropore_amount);
    defer allocator.free(micro_before);
    const macro_before = try allocator.dupe(f64, macropore_amount);
    defer allocator.free(macro_before);
    const boundary_before = try allocator.dupe(f64, boundary_net_flux);
    defer allocator.free(boundary_before);
    const face_component_count = try std.math.mul(usize, inputs.faces.len, inputs.species_count);
    // Face candidates are always captured, even when the caller does not
    // request a face ledger: local conservation acceptance must be able to
    // distinguish inter-layer transport from a local storage defect.
    const micropore_face_candidate = try allocator.alloc(f64, face_component_count);
    defer allocator.free(micropore_face_candidate);
    const macropore_face_candidate = try allocator.alloc(f64, face_component_count);
    defer allocator.free(macropore_face_candidate);
    const boundary_candidate = try allocator.alloc(f64, boundary_net_flux.len);
    defer allocator.free(boundary_candidate);
    @memset(boundary_candidate, 0);
    const external_inputs = try allocator.alloc(f64, micropore_amount.len);
    defer allocator.free(external_inputs);
    @memset(external_inputs, 0);
    const external_outputs = try allocator.alloc(f64, micropore_amount.len);
    defer allocator.free(external_outputs);
    @memset(external_outputs, 0);
    const pore_exchange_activity = try allocator.alloc(f64, micropore_amount.len);
    defer allocator.free(pore_exchange_activity);
    @memset(pore_exchange_activity, 0);
    var state_updateted = false;
    defer if (!state_updateted) {
        @memcpy(micropore_amount, micro_before);
        @memcpy(macropore_amount, macro_before);
        @memcpy(boundary_net_flux, boundary_before);
    };
    const micro_result = try solve(allocator, .micropore, micropore_amount, inputs.micropore_water_m3, inputs.faces, inputs.micropore_conductance_m3_per_step, inputs.species_count, options, micropore_face_candidate);
    const macro_result = try solve(allocator, .macropore, macropore_amount, inputs.macropore_water_m3, inputs.faces, inputs.macropore_conductance_m3_per_step, inputs.species_count, options, macropore_face_candidate);
    try recordFaceTransfers(inputs.faces, micropore_face_candidate, inputs.species_count, external_inputs, external_outputs);
    try recordFaceTransfers(inputs.faces, macropore_face_candidate, inputs.species_count, external_inputs, external_outputs);
    for (0..inputs.micropore_water_m3.len) |layer| {
        if (inputs.active_by_layer.len != 0 and
            !inputs.active_by_layer[layer]) continue;
        const base = layer * inputs.species_count;
        try state_updateBoundary(micropore_amount[base..][0..inputs.species_count], inputs.micropore_water_m3[layer], inputs.micropore_external_water_flux_m3_per_step[layer], inputs.recharge_concentration_per_m3[base..][0..inputs.species_count], options.maximum_convective_fraction, boundary_candidate[base..][0..inputs.species_count], external_inputs[base..][0..inputs.species_count], external_outputs[base..][0..inputs.species_count]);
        try state_updateBoundary(macropore_amount[base..][0..inputs.species_count], inputs.macropore_water_m3[layer], inputs.macropore_external_water_flux_m3_per_step[layer], inputs.recharge_concentration_per_m3[base..][0..inputs.species_count], options.maximum_convective_fraction, boundary_candidate[base..][0..inputs.species_count], external_inputs[base..][0..inputs.species_count], external_outputs[base..][0..inputs.species_count]);
        for (0..inputs.species_count) |species| {
            const index = base + species;
            const convective_exchange = try solute_transport.calculateConvectivePoreExchangeFlux(
                micropore_amount[index],
                macropore_amount[index],
                inputs.micropore_water_m3[layer],
                inputs.macropore_water_m3[layer],
                if (inputs.macropore_to_matrix_water_flux_m3_per_step.len == 0) 0 else inputs.macropore_to_matrix_water_flux_m3_per_step[layer],
                options.maximum_convective_fraction,
            );
            try solute_transport.state_updatePoreExchange(&micropore_amount[index], &macropore_amount[index], convective_exchange);
            const exchange = try poreExchange(micropore_amount[index], macropore_amount[index], inputs.micropore_water_m3[layer], inputs.macropore_water_m3[layer], inputs.layer_bulk_volume_m3[layer], options.pore_exchange_fraction);
            micropore_amount[index] += exchange;
            macropore_amount[index] -= exchange;
            pore_exchange_activity[index] = @abs(convective_exchange) + @abs(exchange);
        }
    }
    if (inputs.test_conservation_perturbation_by_component) |perturbation|
        for (micropore_amount, perturbation) |*amount, change| {
            amount.* += change;
            if (!std.math.isFinite(amount.*) or amount.* < 0)
                return error.InvalidAqueousExtensiveTransportState;
        };
    // Acceptance is deliberately after boundary and pore exchange but before
    // any public ledger is copied or the transaction commits. Every
    // layer/species closes independently; aggregate cancellation cannot pass.
    try acceptLocalConservation(micro_before, macro_before, micropore_amount, macropore_amount, external_inputs, external_outputs, pore_exchange_activity, inputs.species_count, options);
    @memcpy(boundary_net_flux, boundary_candidate);
    if (options.micropore_face_flux_by_component) |output|
        @memcpy(output, micropore_face_candidate);
    if (options.macropore_face_flux_by_component) |output|
        @memcpy(output, macropore_face_candidate);
    state_updateted = true;
    return .{
        .micropore_iterations = micro_result.iterations,
        .macropore_iterations = macro_result.iterations,
        .newton_raphson_steps = micro_result.newton_steps + macro_result.newton_steps,
        .picard_steps = micro_result.picard_steps + macro_result.picard_steps,
        .anderson_steps = micro_result.anderson_steps + macro_result.anderson_steps,
    };
}

const SolverResult = struct { iterations: u16, newton_steps: u16, picard_steps: u16, anderson_steps: u16 = 0 };
const PoreDomain = enum { micropore, macropore };
const dense_newton_layer_limit: usize = 64;

fn solve(allocator: std.mem.Allocator, pore_domain: PoreDomain, amounts: []f64, water: []const f64, faces: []const Face, conductance: []const f64, species_count: usize, options: Options, accepted_face_flux: ?[]f64) !SolverResult {
    const layer_count = amounts.len / species_count;
    const base = try allocator.dupe(f64, amounts);
    defer allocator.free(base);
    const current = try allocator.dupe(f64, base);
    defer allocator.free(current);
    const best_state = try allocator.dupe(f64, base);
    defer allocator.free(best_state);
    const residual = try allocator.alloc(f64, amounts.len);
    defer allocator.free(residual);
    const probe = try allocator.alloc(f64, amounts.len);
    defer allocator.free(probe);
    const probe_residual = try allocator.alloc(f64, amounts.len);
    defer allocator.free(probe_residual);
    const candidate = try allocator.alloc(f64, amounts.len);
    defer allocator.free(candidate);
    const candidate_residual = try allocator.alloc(f64, amounts.len);
    defer allocator.free(candidate_residual);
    const target = try allocator.alloc(f64, amounts.len);
    defer allocator.free(target);
    const publication_candidate = try allocator.alloc(f64, amounts.len);
    defer allocator.free(publication_candidate);
    const publication_residual = try allocator.alloc(f64, amounts.len);
    defer allocator.free(publication_residual);
    // Depth-one Anderson history over the fixed-point defect g(x) - x, which
    // is exactly `residual` here, plus the plain relaxed-Picard candidate an
    // accepted Anderson step displaced (see the stagnation exit below).
    const previous_state = try allocator.alloc(f64, amounts.len);
    defer allocator.free(previous_state);
    const previous_residual = try allocator.alloc(f64, amounts.len);
    defer allocator.free(previous_residual);
    const dense_matrix = try allocator.alloc(f64, if (layer_count <= dense_newton_layer_limit) try std.math.mul(usize, layer_count, layer_count) else 0);
    defer allocator.free(dense_matrix);
    const dense_rhs = try allocator.alloc(f64, if (layer_count <= dense_newton_layer_limit) layer_count else 0);
    defer allocator.free(dense_rhs);
    var newton_steps: u16 = 0;
    var picard_steps: u16 = 0;
    var anderson_steps: u16 = 0;
    var have_history = false;
    var best_norm = std.math.inf(f64);
    var non_improving_steps: u16 = 0;
    var previous_norm = std.math.inf(f64);
    var insufficient_progress_steps: u16 = 0;
    var newton_retry_required = false;
    var iteration: u16 = 0;
    while (iteration < options.max_iterations) : (iteration += 1) {
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        try residualAt(base, current, water, faces, conductance, species_count, options.maximum_convective_fraction, target, residual);
        const norm = try scaledNorm(current, residual, species_count, options);
        if (!retrying_newton_after_anderson and norm <= 1) {
            if (accepted_face_flux) |output| {
                try captureAcceptedFaceFlux(base, current, water, faces, conductance, species_count, options.maximum_convective_fraction, publication_candidate, output);
                @memcpy(amounts, publication_candidate);
            } else {
                @memcpy(amounts, target);
            }
            return .{ .iterations = iteration + 1, .newton_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = anderson_steps };
        }
        if (norm < best_norm) {
            best_norm = norm;
            @memcpy(best_state, current);
            non_improving_steps = 0;
        } else if (norm > options.divergence_growth_factor * best_norm) {
            non_improving_steps += 1;
            if (non_improving_steps >= options.divergence_patience) {
                if (try acceptBestPhysicalState(base, best_state, water, faces, conductance, species_count, options, pore_domain, "divergence-watch", iteration + 1, best_norm, amounts, publication_candidate, target, publication_residual, accepted_face_flux))
                    return .{ .iterations = iteration + 1, .newton_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = anderson_steps };
                std.log.warn("aqueous extensive transport solver diverging: iteration={d} scaled_residual={e} best_scaled_residual={e} growth_factor={e} patience={d}", .{ iteration + 1, norm, best_norm, options.divergence_growth_factor, options.divergence_patience });
                return error.AqueousExtensiveTransportDiverged;
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
        var accepted_newton = false;
        if (!progress_requires_anderson or retrying_newton_after_anderson) {
            try addDirection(current, residual, 0.5, probe);
            try residualAt(base, probe, water, faces, conductance, species_count, options.maximum_convective_fraction, target, probe_residual);
            var numerator: f64 = 0;
            var denominator: f64 = 0;
            for (residual, probe_residual, current, 0..) |value, sampled, state_value, index| {
                const derivative = (sampled - value) / 0.5;
                const scale = absoluteTolerance(options, index % species_count) + options.relative_tolerance * state_value;
                const scaled_value = value / scale;
                const scaled_derivative = derivative / scale;
                numerator += scaled_value * scaled_derivative;
                denominator += scaled_derivative * scaled_derivative;
            }
            if (std.math.isFinite(denominator) and denominator > std.math.floatEps(f64)) {
                // Newton damping is bounded by one; overshooting is never a
                // substitute for a line search or Anderson recovery.
                const fraction = std.math.clamp(-numerator / denominator, 0.05, 1.0);
                if (addDirection(current, residual, fraction, candidate)) |_| {
                    if (residualAt(base, candidate, water, faces, conductance, species_count, options.maximum_convective_fraction, target, candidate_residual)) |_| {
                        if (try scaledNorm(candidate, candidate_residual, species_count, options) < norm) {
                            @memcpy(current, candidate);
                            newton_steps += 1;
                            accepted_newton = true;
                        }
                    } else |_| {}
                } else |_| {}
            }
        }
        if (accepted_newton) continue;
        if (try denseNewtonCandidate(base, current, residual, water, faces, conductance, species_count, options, dense_matrix, dense_rhs, probe, probe_residual, candidate, candidate_residual, target, norm)) {
            @memcpy(current, candidate);
            newton_steps += 1;
            continue;
        }
        if (retrying_newton_after_anderson) continue;
        // Anderson may not occupy the final nonlinear slot: its state must be
        // followed by a separately counted Newton attempt for strict residual
        // acceptance. Physical acceptance separately proves the conservative
        // map image and may therefore publish the best state already reached.
        if (iteration + 1 >= options.max_iterations) {
            if (try acceptBestPhysicalState(base, best_state, water, faces, conductance, species_count, options, pore_domain, "iteration-limit", iteration + 1, best_norm, amounts, publication_candidate, target, publication_residual, accepted_face_flux))
                return .{ .iterations = iteration + 1, .newton_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = anderson_steps };
            return error.AqueousExtensiveTransportDidNotConverge;
        }
        // RECOVERY. Evaluate a relaxed fixed-point seed, then accept only a
        // genuinely accelerated depth-one Anderson candidate.
        try addDirection(current, residual, options.picard_relaxation, candidate);
        var used_anderson = false;
        if (residualAt(base, candidate, water, faces, conductance, species_count, options.maximum_convective_fraction, target, candidate_residual)) |_| {
            if (numerics.andersonDepthOneCandidate(current, residual, candidate, candidate_residual, probe)) {
                var admissible = true;
                for (probe) |*value| {
                    if (!std.math.isFinite(value.*) or value.* < 0) admissible = false;
                }
                if (admissible) {
                    if (residualAt(base, probe, water, faces, conductance, species_count, options.maximum_convective_fraction, target, probe_residual)) |_| {
                        const accelerated_norm = try scaledNorm(probe, probe_residual, species_count, options);
                        if (numerics.andersonImprovesAcceptedMerit(accelerated_norm, norm)) {
                            @memcpy(candidate, probe);
                            anderson_steps += 1;
                            used_anderson = true;
                        }
                    } else |_| {}
                }
            }
        } else |_| {}
        if (!used_anderson and options.anderson_recovery and have_history) {
            var largest_change: f64 = 0;
            for (residual, previous_residual, current, 0..) |now, before, value, index| {
                const scale = absoluteTolerance(options, index % species_count) + options.relative_tolerance * value;
                largest_change = @max(largest_change, @abs((now - before) / scale));
            }
            var mixing_numerator: f64 = 0;
            var mixing_denominator: f64 = 0;
            if (std.math.isFinite(largest_change) and largest_change > 0) {
                for (residual, previous_residual, current, 0..) |now, before, value, index| {
                    const scale = absoluteTolerance(options, index % species_count) + options.relative_tolerance * value;
                    const change = ((now - before) / scale) / largest_change;
                    mixing_numerator += change * ((now / scale) / largest_change);
                    mixing_denominator += change * change;
                }
            }
            if (std.math.isFinite(mixing_numerator) and std.math.isFinite(mixing_denominator) and mixing_denominator > std.math.floatEps(f64)) {
                const mixing = mixing_numerator / mixing_denominator;
                if (std.math.isFinite(mixing)) {
                    var admissible = true;
                    for (probe, current, residual, previous_state, previous_residual) |*value, now, now_defect, before, before_defect| {
                        const mapped_now = now + options.picard_relaxation * now_defect;
                        const mapped_before = before + options.picard_relaxation * before_defect;
                        value.* = mapped_now - mixing * (mapped_now - mapped_before);
                        if (!std.math.isFinite(value.*) or value.* < 0) admissible = false;
                    }
                    if (admissible) {
                        if (residualAt(base, probe, water, faces, conductance, species_count, options.maximum_convective_fraction, target, probe_residual)) |_| {
                            const accelerated_norm = try scaledNorm(probe, probe_residual, species_count, options);
                            if (numerics.andersonImprovesAcceptedMerit(accelerated_norm, norm)) {
                                @memcpy(candidate, probe);
                                anderson_steps += 1;
                                used_anderson = true;
                            }
                        } else |_| {}
                    }
                }
            }
        }
        if (options.anderson_recovery) {
            @memcpy(previous_state, current);
            @memcpy(previous_residual, residual);
            have_history = true;
        }
        if (!used_anderson) {
            if (try acceptBestPhysicalState(base, best_state, water, faces, conductance, species_count, options, pore_domain, "anderson-rejected", iteration + 1, best_norm, amounts, publication_candidate, target, publication_residual, accepted_face_flux))
                return .{ .iterations = iteration + 1, .newton_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = anderson_steps };
            try reportStagnation(base, best_state, water, faces, conductance, species_count, options, pore_domain, "anderson-rejected", iteration + 1, norm, best_norm, target, publication_candidate, publication_residual);
            return error.AqueousExtensiveTransportStagnated;
        }
        if (maximumDifference(current, candidate) <= std.math.floatEps(f64) * @max(1.0, maximumMagnitude(current))) {
            if (try acceptBestPhysicalState(base, best_state, water, faces, conductance, species_count, options, pore_domain, "unrepresentable-update", iteration + 1, best_norm, amounts, publication_candidate, target, publication_residual, accepted_face_flux))
                return .{ .iterations = iteration + 1, .newton_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = anderson_steps };
            try reportStagnation(base, best_state, water, faces, conductance, species_count, options, pore_domain, "unrepresentable-update", iteration + 1, norm, best_norm, target, publication_candidate, publication_residual);
            return error.AqueousExtensiveTransportStagnated;
        }
        @memcpy(current, candidate);
        picard_steps += 1;
        newton_retry_required = true;
    }
    try residualAt(base, current, water, faces, conductance, species_count, options.maximum_convective_fraction, target, residual);
    const final_norm = try scaledNorm(current, residual, species_count, options);
    if (final_norm < best_norm) {
        best_norm = final_norm;
        @memcpy(best_state, current);
    }
    if (!newton_retry_required and final_norm <= 1) {
        if (accepted_face_flux) |output| {
            try captureAcceptedFaceFlux(base, current, water, faces, conductance, species_count, options.maximum_convective_fraction, publication_candidate, output);
            @memcpy(amounts, publication_candidate);
        } else {
            @memcpy(amounts, target);
        }
        return .{ .iterations = options.max_iterations, .newton_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = anderson_steps };
    }
    if (try acceptBestPhysicalState(base, best_state, water, faces, conductance, species_count, options, pore_domain, "iteration-limit", options.max_iterations, best_norm, amounts, publication_candidate, target, publication_residual, accepted_face_flux))
        return .{ .iterations = options.max_iterations, .newton_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = anderson_steps };
    return error.AqueousExtensiveTransportDidNotConverge;
}

fn acceptBestPhysicalState(
    base: []const f64,
    best_state: []const f64,
    water: []const f64,
    faces: []const Face,
    conductance: []const f64,
    species_count: usize,
    options: Options,
    pore_domain: PoreDomain,
    reason: []const u8,
    iteration: u16,
    best_norm: f64,
    amounts: []f64,
    publication_candidate: []f64,
    incoming_scratch: []f64,
    outgoing_scratch: []f64,
    accepted_face_flux: ?[]f64,
) !bool {
    const face_flux = accepted_face_flux orelse return false;
    try captureAcceptedFaceFlux(
        base,
        best_state,
        water,
        faces,
        conductance,
        species_count,
        options.maximum_convective_fraction,
        publication_candidate,
        face_flux,
    );
    @memset(incoming_scratch, 0);
    @memset(outgoing_scratch, 0);
    try recordFaceTransfers(faces, face_flux, species_count, incoming_scratch, outgoing_scratch);
    var maximum_conservation_absolute: f64 = 0;
    var maximum_conservation_relative: f64 = 0;
    for (base, publication_candidate, incoming_scratch, outgoing_scratch, 0..) |before, after, input, output, index| {
        if (!std.math.isFinite(after) or after < 0) return false;
        const closure = try scoped_conservation.evaluate(.{
            .storage_before = before,
            .storage_after = after,
            .external_inputs = input,
            .external_outputs = output,
        }, .{
            .absolute = conservationAbsoluteTolerance(options, index, species_count, before, after),
            .relative = options.conservation_relative_tolerance,
        });
        if (!closure.accepted) return false;
        maximum_conservation_absolute = @max(maximum_conservation_absolute, closure.absolute);
        maximum_conservation_relative = @max(maximum_conservation_relative, closure.normalized_relative);
    }
    try residualAt(base, publication_candidate, water, faces, conductance, species_count, options.maximum_convective_fraction, incoming_scratch, outgoing_scratch);
    const publication_norm = try scaledNorm(publication_candidate, outgoing_scratch, species_count, options);
    @memcpy(amounts, publication_candidate);
    if (!builtin.is_test) std.log.warn(
        "aqueous extensive transport accepted best conservative state: pore={s} reason={s} iteration={d} best_scaled_residual={e} publication_scaled_residual={e} maximum_conservation_absolute={e} maximum_conservation_relative={e}",
        .{ @tagName(pore_domain), reason, iteration, best_norm, publication_norm, maximum_conservation_absolute, maximum_conservation_relative },
    );
    return true;
}

fn denseNewtonCandidate(
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    water: []const f64,
    faces: []const Face,
    conductance: []const f64,
    species_count: usize,
    options: Options,
    matrix: []f64,
    right_hand_side: []f64,
    probe: []f64,
    probe_residual: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    target: []f64,
    current_norm: f64,
) !bool {
    const layer_count = current.len / species_count;
    if (layer_count == 0 or layer_count > dense_newton_layer_limit or
        matrix.len != layer_count * layer_count or right_hand_side.len != layer_count)
        return false;
    @memset(candidate, 0);
    var has_direction = false;
    for (0..species_count) |species| {
        var species_norm: f64 = 0;
        var species_probe_scale = absoluteTolerance(options, species);
        for (0..layer_count) |layer| {
            const index = layer * species_count + species;
            const scale = absoluteTolerance(options, species) + options.relative_tolerance * current[index];
            species_norm = @max(species_norm, @abs(residual[index]) / scale);
            species_probe_scale = @max(species_probe_scale, @max(@abs(base[index]), @max(@abs(current[index]), @abs(residual[index]))));
            right_hand_side[layer] = -residual[index];
        }
        if (species_norm <= 1) continue;
        for (0..layer_count) |column| {
            @memcpy(probe, current);
            const column_index = column * species_count + species;
            var probe_value = current[column_index] + std.math.cbrt(std.math.floatEps(f64)) * species_probe_scale;
            if (probe_value == current[column_index])
                probe_value = std.math.nextAfter(f64, current[column_index], std.math.inf(f64));
            if (!std.math.isFinite(probe_value) or probe_value <= current[column_index]) return false;
            probe[column_index] = probe_value;
            try residualAt(base, probe, water, faces, conductance, species_count, options.maximum_convective_fraction, target, probe_residual);
            const step = probe_value - current[column_index];
            for (0..layer_count) |row| {
                const row_index = row * species_count + species;
                matrix[row * layer_count + column] = (probe_residual[row_index] - residual[row_index]) / step;
            }
        }
        if (!numerics.solveDenseLinearSystem(matrix, right_hand_side, layer_count)) return false;
        for (0..layer_count) |layer| {
            const index = layer * species_count + species;
            candidate[index] = right_hand_side[layer];
            has_direction = has_direction or right_hand_side[layer] != 0;
        }
    }
    if (!has_direction) return false;

    var damping: f64 = 1;
    for (candidate, current) |change, value| {
        if (!std.math.isFinite(change)) return false;
        if (change < 0 and value + change < 0)
            damping = @min(damping, std.math.nextAfter(f64, value / -change, 0));
    }
    if (!std.math.isFinite(damping) or damping <= 0) return false;
    var line_search_step: u8 = 0;
    while (line_search_step < 12) : (line_search_step += 1) {
        var admissible = true;
        for (probe, current, candidate) |*trial, value, change| {
            trial.* = value + damping * change;
            if (!std.math.isFinite(trial.*) or trial.* < 0) admissible = false;
        }
        if (admissible) {
            try residualAt(base, probe, water, faces, conductance, species_count, options.maximum_convective_fraction, target, candidate_residual);
            if (try scaledNorm(probe, candidate_residual, species_count, options) < current_norm) {
                @memcpy(candidate, probe);
                return true;
            }
        }
        damping *= 0.5;
    }
    return false;
}

fn reportStagnation(
    base: []const f64,
    current: []const f64,
    water: []const f64,
    faces: []const Face,
    conductance: []const f64,
    species_count: usize,
    options: Options,
    pore_domain: PoreDomain,
    reason: []const u8,
    iteration: u16,
    norm: f64,
    best_norm: f64,
    target: []f64,
    publication_candidate: []f64,
    publication_residual: []f64,
) !void {
    try residualAt(base, current, water, faces, conductance, species_count, options.maximum_convective_fraction, target, publication_residual);
    @memcpy(publication_candidate, target);
    try residualAt(base, publication_candidate, water, faces, conductance, species_count, options.maximum_convective_fraction, target, publication_residual);
    const publication_norm = try scaledNorm(publication_candidate, publication_residual, species_count, options);
    var worst_index: usize = 0;
    var worst_scaled_residual: f64 = 0;
    var residual_l1: f64 = 0;
    var inventory_l1: f64 = 0;
    for (publication_candidate, publication_residual, 0..) |value, difference, index| {
        const tolerance = absoluteTolerance(options, index % species_count) + options.relative_tolerance * value;
        const scaled_residual = @abs(difference) / tolerance;
        if (scaled_residual > worst_scaled_residual) {
            worst_scaled_residual = scaled_residual;
            worst_index = index;
        }
        residual_l1 += @abs(difference);
        inventory_l1 += value;
    }
    if (!builtin.is_test) std.log.err(
        "aqueous extensive transport stagnated: pore={s} reason={s} iteration={d} scaled_residual={e} best_scaled_residual={e} publication_scaled_residual={e} layer={d} species={d} state={e} publication_residual={e} tolerance={e} residual_l1={e} inventory_l1={e}",
        .{
            @tagName(pore_domain),
            reason,
            iteration,
            norm,
            best_norm,
            publication_norm,
            worst_index / species_count,
            worst_index % species_count,
            publication_candidate[worst_index],
            publication_residual[worst_index],
            absoluteTolerance(options, worst_index % species_count) + options.relative_tolerance * publication_candidate[worst_index],
            residual_l1,
            inventory_l1,
        },
    );
}

fn maximumDifference(a: []const f64, b: []const f64) f64 {
    var maximum: f64 = 0;
    for (a, b) |left, right| maximum = @max(maximum, @abs(left - right));
    return maximum;
}

fn maximumMagnitude(values: []const f64) f64 {
    var maximum: f64 = 0;
    for (values) |value| maximum = @max(maximum, @abs(value));
    return maximum;
}

fn residualAt(base: []const f64, trial: []const f64, water: []const f64, faces: []const Face, conductance: []const f64, species_count: usize, maximum_fraction: f64, target: []f64, residual: []f64) !void {
    @memcpy(target, base);
    for (faces, 0..) |face, face_index| for (0..species_count) |species| {
        const first = face.first_cell * species_count + species;
        const second = face.second_cell * species_count + species;
        const first_concentration = if (water[face.first_cell] > 0) trial[first] / water[face.first_cell] else 0;
        const second_concentration = if (water[face.second_cell] > 0) trial[second] / water[face.second_cell] else 0;
        const donor_fraction = if (face.water_flux_m3_per_step >= 0)
            if (water[face.first_cell] > 0) @min(maximum_fraction, face.water_flux_m3_per_step / water[face.first_cell]) else maximum_fraction
        else if (water[face.second_cell] > 0) @min(maximum_fraction, -face.water_flux_m3_per_step / water[face.second_cell]) else maximum_fraction;
        const convection = if (face.water_flux_m3_per_step >= 0) donor_fraction * trial[first] else -donor_fraction * trial[second];
        const diffusion = conductance[face_index * species_count + species] * (first_concentration - second_concentration);
        const flux = std.math.clamp(convection + diffusion, -target[second], target[first]);
        target[first] -= flux;
        target[second] += flux;
    };
    for (target, trial, residual) |fixed_point, value, *difference| {
        difference.* = fixed_point - value;
        if (!std.math.isFinite(difference.*)) return error.NonFiniteAqueousExtensiveTransport;
    }
}

fn captureAcceptedFaceFlux(
    base: []const f64,
    trial: []const f64,
    water: []const f64,
    faces: []const Face,
    conductance: []const f64,
    species_count: usize,
    maximum_fraction: f64,
    accumulator: []f64,
    output: []f64,
) !void {
    if (accumulator.len != base.len or output.len != faces.len * species_count)
        return error.AqueousExtensiveFaceFluxOutputDimensionMismatch;
    @memcpy(accumulator, base);
    for (faces, 0..) |face, face_index| for (0..species_count) |species| {
        const first = face.first_cell * species_count + species;
        const second = face.second_cell * species_count + species;
        const first_concentration = if (water[face.first_cell] > 0) trial[first] / water[face.first_cell] else 0;
        const second_concentration = if (water[face.second_cell] > 0) trial[second] / water[face.second_cell] else 0;
        const donor_fraction = if (face.water_flux_m3_per_step >= 0)
            if (water[face.first_cell] > 0) @min(maximum_fraction, face.water_flux_m3_per_step / water[face.first_cell]) else maximum_fraction
        else if (water[face.second_cell] > 0) @min(maximum_fraction, -face.water_flux_m3_per_step / water[face.second_cell]) else maximum_fraction;
        const convection = if (face.water_flux_m3_per_step >= 0) donor_fraction * trial[first] else -donor_fraction * trial[second];
        const diffusion = conductance[face_index * species_count + species] * (first_concentration - second_concentration);
        const flux = std.math.clamp(convection + diffusion, -accumulator[second], accumulator[first]);
        if (!std.math.isFinite(flux)) return error.NonFiniteAqueousExtensiveTransport;
        accumulator[first] -= flux;
        accumulator[second] += flux;
        output[face_index * species_count + species] = flux;
    };
}

fn state_updateBoundary(amounts: []f64, water_m3: f64, outward_water_m3: f64, recharge: []const f64, maximum_fraction: f64, ledger: []f64, external_inputs: []f64, external_outputs: []f64) !void {
    if (amounts.len != recharge.len or amounts.len != ledger.len or amounts.len != external_inputs.len or amounts.len != external_outputs.len)
        return error.AqueousExtensiveTransportDimensionMismatch;
    for (amounts, recharge, ledger, external_inputs, external_outputs) |*amount, concentration, *net, *input, *output| {
        const change = if (outward_water_m3 >= 0)
            -amount.* * (if (water_m3 > 0) @min(maximum_fraction, outward_water_m3 / water_m3) else maximum_fraction)
        else
            -outward_water_m3 * concentration;
        if (!std.math.isFinite(change) or amount.* + change < 0 or !std.math.isFinite(net.* + change)) return error.InvalidAqueousExtensiveBoundaryFlux;
        amount.* += change;
        net.* += change;
        if (change >= 0)
            input.* += change
        else
            output.* -= change;
        if (!std.math.isFinite(input.*) or !std.math.isFinite(output.*))
            return error.NonFiniteAqueousExtensiveTransport;
    }
}

fn recordFaceTransfers(faces: []const Face, face_flux: []const f64, species_count: usize, external_inputs: []f64, external_outputs: []f64) !void {
    if (species_count == 0 or face_flux.len != faces.len * species_count or external_inputs.len != external_outputs.len or external_inputs.len % species_count != 0)
        return error.AqueousExtensiveTransportDimensionMismatch;
    const layer_count = external_inputs.len / species_count;
    for (faces, 0..) |face, face_index| {
        if (face.first_cell >= layer_count or face.second_cell >= layer_count)
            return error.AqueousExtensiveTransportFaceIndexOutOfBounds;
        for (0..species_count) |species| {
            const first = face.first_cell * species_count + species;
            const second = face.second_cell * species_count + species;
            const flux = face_flux[face_index * species_count + species];
            if (!std.math.isFinite(flux)) return error.NonFiniteAqueousExtensiveTransport;
            if (flux >= 0) {
                external_outputs[first] += flux;
                external_inputs[second] += flux;
            } else {
                external_inputs[first] -= flux;
                external_outputs[second] -= flux;
            }
            if (!std.math.isFinite(external_inputs[first]) or !std.math.isFinite(external_inputs[second]) or
                !std.math.isFinite(external_outputs[first]) or !std.math.isFinite(external_outputs[second]))
                return error.NonFiniteAqueousExtensiveTransport;
        }
    }
}

fn conservationAbsoluteTolerance(options: Options, index: usize, species_count: usize, storage_before: f64, storage_after: f64) f64 {
    const species = index % species_count;
    const direct = if (options.conservation_absolute_tolerance_by_species.len == 0)
        options.conservation_absolute_tolerance
    else
        options.conservation_absolute_tolerance_by_species[species];
    const per_area = if (options.horizontal_cell_area_m2.len == 0)
        0
    else
        options.conservation_absolute_tolerance_g_per_m2_by_species[species] *
            options.horizontal_cell_area_m2[(index / species_count) / options.soil_layer_capacity];
    const representation_floor = 64 * std.math.floatEps(f64) *
        @max(1, @max(@abs(storage_before), @abs(storage_after)));
    return @max(representation_floor, @max(direct, per_area));
}

fn acceptLocalConservation(
    micropore_before: []const f64,
    macropore_before: []const f64,
    micropore_after: []const f64,
    macropore_after: []const f64,
    external_inputs: []const f64,
    external_outputs: []const f64,
    pore_exchange_activity: []const f64,
    species_count: usize,
    options: Options,
) !void {
    if (species_count == 0 or micropore_before.len != macropore_before.len or
        micropore_before.len != micropore_after.len or micropore_before.len != macropore_after.len or
        micropore_before.len != external_inputs.len or micropore_before.len != external_outputs.len or
        micropore_before.len != pore_exchange_activity.len or micropore_before.len % species_count != 0)
        return error.AqueousExtensiveTransportDimensionMismatch;
    for (micropore_before, macropore_before, micropore_after, macropore_after, external_inputs, external_outputs, pore_exchange_activity, 0..) |micro_before, macro_before, micro_after, macro_after, input, output, exchange, index| {
        const closure = try scoped_conservation.evaluate(.{
            .storage_before = micro_before + macro_before,
            .storage_after = micro_after + macro_after,
            .external_inputs = input,
            .external_outputs = output,
            // Pore exchange is an internal donor/recipient transfer within
            // this layer/species scope. Recording both sides retains its
            // activity scale while contributing zero expected net change.
            .internal_production = exchange,
            .internal_consumption = exchange,
        }, .{
            .absolute = conservationAbsoluteTolerance(options, index, species_count, micro_before + macro_before, micro_after + macro_after),
            .relative = options.conservation_relative_tolerance,
        });
        if (!closure.accepted) {
            if (!builtin.is_test) std.log.err(
                "aqueous extensive local conservation failure: layer={d} species={d} residual={e} absolute={e} normalized_relative={e} acceptance_limit={e}",
                .{ index / species_count, index % species_count, closure.residual, closure.absolute, closure.normalized_relative, closure.acceptance_limit },
            );
            return error.AqueousExtensiveTransportConservationFailure;
        }
    }
}

fn poreExchange(micro: f64, macro: f64, micro_water: f64, macro_water: f64, bulk_volume: f64, fraction: f64) !f64 {
    if (macro_water == 0) return 0;
    const exchanging_macro_water = @min(0.05 * bulk_volume, macro_water);
    const combined_water = micro_water + exchanging_macro_water;
    if (combined_water == 0) return 0;
    const exchange = fraction * (macro * micro_water - micro * exchanging_macro_water) / combined_water;
    if (!std.math.isFinite(exchange)) return error.NonFiniteAqueousExtensivePoreExchange;
    return std.math.clamp(exchange, -micro, macro);
}

fn absoluteTolerance(options: Options, species: usize) f64 {
    return if (options.absolute_tolerance_by_species.len == 0)
        options.absolute_tolerance
    else
        options.absolute_tolerance_by_species[species];
}

fn scaledNorm(state: []const f64, residual: []const f64, species_count: usize, options: Options) !f64 {
    var maximum: f64 = 0;
    for (state, residual, 0..) |value, difference, index| {
        if (!std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference)) return error.NonFiniteAqueousExtensiveTransport;
        maximum = @max(maximum, @abs(difference) / (absoluteTolerance(options, index % species_count) + options.relative_tolerance * value));
    }
    return maximum;
}

fn addDirection(current: []const f64, direction: []const f64, fraction: f64, output: []f64) !void {
    for (current, direction, output) |value, change, *candidate| {
        candidate.* = value + fraction * change;
        if (!std.math.isFinite(candidate.*) or candidate.* < 0) return error.InvalidAqueousExtensiveTransportCandidate;
    }
}

fn validate(micro: []const f64, macro: []const f64, boundary: []const f64, inputs: Inputs, options: Options) !void {
    if (inputs.species_count == 0 or micro.len != macro.len or micro.len != boundary.len or micro.len != inputs.micropore_water_m3.len * inputs.species_count or inputs.macropore_water_m3.len != inputs.micropore_water_m3.len or inputs.layer_bulk_volume_m3.len != inputs.micropore_water_m3.len or (inputs.active_by_layer.len != 0 and inputs.active_by_layer.len != inputs.micropore_water_m3.len) or inputs.micropore_external_water_flux_m3_per_step.len != inputs.micropore_water_m3.len or inputs.macropore_external_water_flux_m3_per_step.len != inputs.micropore_water_m3.len or (inputs.macropore_to_matrix_water_flux_m3_per_step.len != 0 and inputs.macropore_to_matrix_water_flux_m3_per_step.len != inputs.micropore_water_m3.len) or inputs.recharge_concentration_per_m3.len != micro.len or inputs.micropore_conductance_m3_per_step.len != inputs.faces.len * inputs.species_count or inputs.macropore_conductance_m3_per_step.len != inputs.faces.len * inputs.species_count) return error.AqueousExtensiveTransportDimensionMismatch;
    if ((options.micropore_face_flux_by_component == null) != (options.macropore_face_flux_by_component == null)) return error.AqueousExtensiveTransportDimensionMismatch;
    if (options.micropore_face_flux_by_component) |values| {
        const expected = try std.math.mul(usize, inputs.faces.len, inputs.species_count);
        if (values.len != expected or options.macropore_face_flux_by_component.?.len != expected)
            return error.AqueousExtensiveTransportDimensionMismatch;
    }
    if (!options.anderson_recovery or (options.absolute_tolerance_by_species.len != 0 and options.absolute_tolerance_by_species.len != inputs.species_count) or (options.conservation_absolute_tolerance_by_species.len != 0 and options.conservation_absolute_tolerance_by_species.len != inputs.species_count) or (options.conservation_absolute_tolerance_g_per_m2_by_species.len != 0 and options.conservation_absolute_tolerance_g_per_m2_by_species.len != inputs.species_count) or !std.math.isFinite(options.absolute_tolerance) or options.absolute_tolerance <= 0 or !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or !std.math.isFinite(options.conservation_absolute_tolerance) or options.conservation_absolute_tolerance < 0 or !std.math.isFinite(options.conservation_relative_tolerance) or options.conservation_relative_tolerance <= 0 or !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or options.max_iterations == 0 or !std.math.isFinite(options.maximum_convective_fraction) or options.maximum_convective_fraction < 0 or options.maximum_convective_fraction > 1 or !std.math.isFinite(options.pore_exchange_fraction) or options.pore_exchange_fraction < 0 or options.pore_exchange_fraction > 1 or options.divergence_patience == 0 or !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1) return error.InvalidAqueousExtensiveTransportOptions;
    for (options.absolute_tolerance_by_species) |tolerance| if (!std.math.isFinite(tolerance) or tolerance <= 0) return error.InvalidAqueousExtensiveTransportOptions;
    for (options.conservation_absolute_tolerance_by_species) |tolerance| if (!std.math.isFinite(tolerance) or tolerance < 0) return error.InvalidAqueousExtensiveTransportOptions;
    for (options.conservation_absolute_tolerance_g_per_m2_by_species) |tolerance| if (!std.math.isFinite(tolerance) or tolerance < 0) return error.InvalidAqueousExtensiveTransportOptions;
    if (options.horizontal_cell_area_m2.len != 0) {
        if (options.soil_layer_capacity == 0 or
            inputs.micropore_water_m3.len != try std.math.mul(usize, options.horizontal_cell_area_m2.len, options.soil_layer_capacity) or
            options.conservation_absolute_tolerance_g_per_m2_by_species.len != inputs.species_count)
            return error.AqueousExtensiveTransportDimensionMismatch;
        for (options.horizontal_cell_area_m2) |area|
            if (!std.math.isFinite(area) or area <= 0) return error.InvalidAqueousExtensiveTransportOptions;
    }
    for (inputs.faces) |face| if (face.first_cell >= inputs.micropore_water_m3.len or face.second_cell >= inputs.micropore_water_m3.len) return error.AqueousExtensiveTransportFaceIndexOutOfBounds;
    if (inputs.test_conservation_perturbation_by_component) |perturbation| {
        if (!builtin.is_test) return error.TestOnlyAqueousTransportPerturbation;
        if (perturbation.len != micro.len) return error.AqueousExtensiveTransportDimensionMismatch;
        for (perturbation) |change| if (!std.math.isFinite(change)) return error.InvalidAqueousExtensiveTransportState;
    }
    for (micro, macro, inputs.recharge_concentration_per_m3) |a, b, recharge| if (!std.math.isFinite(a) or a < 0 or !std.math.isFinite(b) or b < 0 or !std.math.isFinite(recharge) or recharge < 0) return error.InvalidAqueousExtensiveTransportState;
    for (inputs.micropore_water_m3, inputs.macropore_water_m3, inputs.layer_bulk_volume_m3, inputs.micropore_external_water_flux_m3_per_step, inputs.macropore_external_water_flux_m3_per_step) |a, b, bulk, fa, fb| {
        if (!std.math.isFinite(a) or a < 0 or !std.math.isFinite(b) or b < 0 or !std.math.isFinite(bulk) or bulk <= 0 or !std.math.isFinite(fa) or !std.math.isFinite(fb)) return error.InvalidAqueousExtensiveTransportState;
    }
}

test "runtime species transport conserves internal mass and publishes boundary sign" {
    var micro = [_]f64{ 2, 4 };
    var macro = [_]f64{ 0, 0 };
    var boundary = [_]f64{ 0, 0 };
    const result = try advance(std.testing.allocator, &micro, &macro, &boundary, .{
        .species_count = 2,
        .faces = &.{},
        .micropore_conductance_m3_per_step = &.{},
        .macropore_conductance_m3_per_step = &.{},
        .micropore_water_m3 = &.{1},
        .macropore_water_m3 = &.{0},
        .layer_bulk_volume_m3 = &.{1},
        .micropore_external_water_flux_m3_per_step = &.{0.25},
        .macropore_external_water_flux_m3_per_step = &.{0},
        .recharge_concentration_per_m3 = &.{ 0, 0 },
    }, .{ .absolute_tolerance = 1e-12, .relative_tolerance = 1e-8, .picard_relaxation = 0.5, .max_iterations = 20, .pore_exchange_fraction = 0 });
    try std.testing.expectEqual(@as(u16, 1), result.micropore_iterations);
    try std.testing.expectEqual(result.picard_steps, result.anderson_steps);
    try std.testing.expectEqualSlices(f64, &.{ 1.5, 3 }, &micro);
    try std.testing.expectEqualSlices(f64, &.{ -0.5, -1 }, &boundary);
}

test "mixed species residuals use distinct absolute floors" {
    const options: Options = .{
        .absolute_tolerance_by_species = &.{ 1.0e-10, 1.0e-12 },
        .relative_tolerance = 1.0e-8,
        .picard_relaxation = 0.5,
        .max_iterations = 20,
    };
    const state = [_]f64{ 0, 0 };
    const residual = [_]f64{ 1.0e-10, 1.0e-10 };
    try std.testing.expectApproxEqAbs(@as(f64, 100), try scaledNorm(&state, &residual, 2, options), 1.0e-12);
}

test "trace transport Newton step is independent of extensive-unit magnitude" {
    var micro = [_]f64{ 1.0e-6, 0 };
    var macro = [_]f64{ 0, 0 };
    var boundary = [_]f64{ 0, 0 };
    const result = try advance(std.testing.allocator, &micro, &macro, &boundary, .{
        .species_count = 1,
        .faces = &.{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 1.0e-4 }},
        .micropore_conductance_m3_per_step = &.{0},
        .macropore_conductance_m3_per_step = &.{0},
        .micropore_water_m3 = &.{ 1, 1 },
        .macropore_water_m3 = &.{ 0, 0 },
        .layer_bulk_volume_m3 = &.{ 1, 1 },
        .micropore_external_water_flux_m3_per_step = &.{ 0, 0 },
        .macropore_external_water_flux_m3_per_step = &.{ 0, 0 },
        .recharge_concentration_per_m3 = &.{ 0, 0 },
    }, .{
        .absolute_tolerance = 1.0e-14,
        .relative_tolerance = 1.0e-8,
        .picard_relaxation = 0.5,
        .max_iterations = 1,
        .pore_exchange_fraction = 0,
    });
    try std.testing.expectEqual(@as(u16, 1), result.newton_raphson_steps);
    try std.testing.expectApproxEqRel(@as(f64, 1.0e-6 / 1.0001), micro[0], 1.0e-12);
    try std.testing.expectApproxEqRel(@as(f64, 1.0e-10 / 1.0001), micro[1], 1.0e-12);
}

test "dense aqueous Newton rescue resolves coupled empty layers" {
    const base = [_]f64{ 1, 0, 0 };
    var current = base;
    const water = [_]f64{ 1, 1, 1 };
    const faces = [_]Face{
        .{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 },
        .{ .first_cell = 1, .second_cell = 2, .water_flux_m3_per_step = 0 },
    };
    const conductance = [_]f64{ 0.2, 0.2 };
    const options: Options = .{
        .absolute_tolerance = 1.0e-14,
        .relative_tolerance = 1.0e-10,
        .picard_relaxation = 0.5,
        .max_iterations = 2,
    };
    var target: [3]f64 = undefined;
    var residual: [3]f64 = undefined;
    try residualAt(&base, &current, &water, &faces, &conductance, 1, 1, &target, &residual);
    var matrix: [9]f64 = undefined;
    var right_hand_side: [3]f64 = undefined;
    var probe: [3]f64 = undefined;
    var probe_residual: [3]f64 = undefined;
    var candidate: [3]f64 = undefined;
    var candidate_residual: [3]f64 = undefined;
    var norm = try scaledNorm(&current, &residual, 1, options);
    for (0..4) |_| {
        if (norm <= 1) break;
        try std.testing.expect(try denseNewtonCandidate(
            &base,
            &current,
            &residual,
            &water,
            &faces,
            &conductance,
            1,
            options,
            &matrix,
            &right_hand_side,
            &probe,
            &probe_residual,
            &candidate,
            &candidate_residual,
            &target,
            norm,
        ));
        @memcpy(&current, &candidate);
        try residualAt(&base, &current, &water, &faces, &conductance, 1, 1, &target, &residual);
        norm = try scaledNorm(&current, &residual, 1, options);
    }
    try std.testing.expect(norm <= 1);
    try std.testing.expectApproxEqAbs(@as(f64, 1), current[0] + current[1] + current[2], 1.0e-12);
}

test "converged iterate publishes conservative map image across clamp branch" {
    const base = [_]f64{ 1, 0 };
    const current = [_]f64{ 0.6000000000003, 0.4 };
    const water = [_]f64{ 1, 1 };
    const faces = [_]Face{.{
        .first_cell = 0,
        .second_cell = 1,
        .water_flux_m3_per_step = 0,
    }};
    const conductance = [_]f64{2};
    const options: Options = .{
        .absolute_tolerance = 1.0e-12,
        .relative_tolerance = 1.0e-15,
        .conservation_absolute_tolerance = 1.0e-12,
        .conservation_relative_tolerance = 1.0e-15,
        .picard_relaxation = 0.5,
        .max_iterations = 2,
    };
    var target: [2]f64 = undefined;
    var residual: [2]f64 = undefined;
    try residualAt(&base, &current, &water, &faces, &conductance, 1, 1, &target, &residual);
    try std.testing.expect(try scaledNorm(&current, &residual, 1, options) <= 1);

    const publication = target;
    var publication_target: [2]f64 = undefined;
    var publication_residual: [2]f64 = undefined;
    try residualAt(&base, &publication, &water, &faces, &conductance, 1, 1, &publication_target, &publication_residual);
    try std.testing.expect(try scaledNorm(&publication, &publication_residual, 1, options) > 1);

    var published: [2]f64 = undefined;
    var face_flux: [1]f64 = undefined;
    try captureAcceptedFaceFlux(
        &base,
        &current,
        &water,
        &faces,
        &conductance,
        1,
        options.maximum_convective_fraction,
        &published,
        &face_flux,
    );
    try std.testing.expectEqualSlices(f64, &publication, &published);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4000000000006), face_flux[0], 1.0e-15);
    const first_closure = try scoped_conservation.evaluate(.{
        .storage_before = base[0],
        .storage_after = published[0],
        .external_outputs = face_flux[0],
    }, .{ .absolute = 0, .relative = 0 });
    const second_closure = try scoped_conservation.evaluate(.{
        .storage_before = base[1],
        .storage_after = published[1],
        .external_inputs = face_flux[0],
    }, .{ .absolute = 0, .relative = 0 });
    try std.testing.expect(first_closure.accepted);
    try std.testing.expect(second_closure.accepted);
}

test "stalled trace transport accepts best finite conservative map image" {
    const base = [_]f64{ 1.0e-8, 0 };
    const best_state = base;
    const water = [_]f64{ 1, 1 };
    const faces = [_]Face{.{
        .first_cell = 0,
        .second_cell = 1,
        .water_flux_m3_per_step = 0,
    }};
    const conductance = [_]f64{0.4};
    const options: Options = .{
        .absolute_tolerance = 1.0e-12,
        .relative_tolerance = 1.0e-10,
        .conservation_absolute_tolerance = 0,
        .conservation_relative_tolerance = 1.0e-9,
        .picard_relaxation = 0.5,
        .max_iterations = 2,
    };
    var fixed_point: [2]f64 = undefined;
    var residual: [2]f64 = undefined;
    try residualAt(&base, &best_state, &water, &faces, &conductance, 1, 1, &fixed_point, &residual);
    const best_norm = try scaledNorm(&best_state, &residual, 1, options);
    try std.testing.expect(best_norm > 1);

    var amounts = base;
    var publication: [2]f64 = undefined;
    var incoming: [2]f64 = undefined;
    var outgoing: [2]f64 = undefined;
    var face_flux: [1]f64 = undefined;
    try std.testing.expect(try acceptBestPhysicalState(
        &base,
        &best_state,
        &water,
        &faces,
        &conductance,
        1,
        options,
        .macropore,
        "test-stagnation",
        2,
        best_norm,
        &amounts,
        &publication,
        &incoming,
        &outgoing,
        &face_flux,
    ));
    try std.testing.expectApproxEqAbs(@as(f64, 6.0e-9), amounts[0], 1.0e-24);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0e-9), amounts[1], 1.0e-24);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0e-9), face_flux[0], 1.0e-24);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0e-8), amounts[0] + amounts[1], 1.0e-24);

    try residualAt(&base, &amounts, &water, &faces, &conductance, 1, 1, &fixed_point, &residual);
    try std.testing.expect(try scaledNorm(&amounts, &residual, 1, options) > 1);
}

test "per-layer conservation rejects equal and opposite defects that cancel globally" {
    const micro_before = [_]f64{ 10, 20 };
    const macro_before = [_]f64{ 0, 0 };
    const micro_after = [_]f64{ 10.25, 19.75 };
    const macro_after = [_]f64{ 0, 0 };
    const zero = [_]f64{ 0, 0 };
    try std.testing.expectError(
        error.AqueousExtensiveTransportConservationFailure,
        acceptLocalConservation(
            &micro_before,
            &macro_before,
            &micro_after,
            &macro_after,
            &zero,
            &zero,
            &zero,
            1,
            .{
                .conservation_absolute_tolerance = 1.0e-12,
                .conservation_relative_tolerance = 1.0e-10,
                .relative_tolerance = 1.0e-8,
                .picard_relaxation = 0.5,
                .max_iterations = 20,
            },
        ),
    );
}

test "wrong species face index cannot hide behind transfer cancellation" {
    const micro_before = [_]f64{ 2, 3, 4, 5 };
    const macro_before = [_]f64{ 0, 0, 0, 0 };
    // The accepted storage moved species zero from layer zero to layer one.
    const micro_after = [_]f64{ 1.75, 3, 4.25, 5 };
    const macro_after = [_]f64{ 0, 0, 0, 0 };
    var external_inputs = [_]f64{ 0, 0, 0, 0 };
    var external_outputs = [_]f64{ 0, 0, 0, 0 };
    // A wrongly indexed face ledger claims that the same +d/-d transfer
    // belonged to species one. Domain totals still cancel exactly.
    try recordFaceTransfers(
        &.{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }},
        &.{ 0, 0.25 },
        2,
        &external_inputs,
        &external_outputs,
    );
    try std.testing.expectError(
        error.AqueousExtensiveTransportConservationFailure,
        acceptLocalConservation(
            &micro_before,
            &macro_before,
            &micro_after,
            &macro_after,
            &external_inputs,
            &external_outputs,
            &.{ 0, 0, 0, 0 },
            2,
            .{
                .conservation_absolute_tolerance_by_species = &.{ 1.0e-12, 1.0e-12 },
                .conservation_relative_tolerance = 1.0e-10,
                .relative_tolerance = 1.0e-8,
                .picard_relaxation = 0.5,
                .max_iterations = 20,
            },
        ),
    );
}

test "local conservation failure rolls back both pore states and every ledger" {
    var micro = [_]f64{ 1, 2 };
    var macro = [_]f64{ 1, 0 };
    var boundary = [_]f64{ 7, 6 };
    var micro_face = [_]f64{8};
    var macro_face = [_]f64{9};
    const micro_before = micro;
    const macro_before = macro;
    const boundary_before = boundary;
    const micro_face_before = micro_face;
    const macro_face_before = macro_face;
    try std.testing.expectError(
        error.AqueousExtensiveTransportConservationFailure,
        advance(std.testing.allocator, &micro, &macro, &boundary, .{
            .species_count = 1,
            .faces = &.{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }},
            .micropore_conductance_m3_per_step = &.{0},
            .macropore_conductance_m3_per_step = &.{0},
            .micropore_water_m3 = &.{ 1, 1 },
            .macropore_water_m3 = &.{ 1, 0 },
            .layer_bulk_volume_m3 = &.{ 1, 1 },
            .micropore_external_water_flux_m3_per_step = &.{ 0, 0 },
            .macropore_external_water_flux_m3_per_step = &.{ 0, 0 },
            .recharge_concentration_per_m3 = &.{ 0, 0 },
            // Equal and opposite defects cancel over the domain but must fail
            // both local layer scopes deterministically.
            .test_conservation_perturbation_by_component = &.{ 0.1, -0.1 },
        }, .{
            .conservation_absolute_tolerance = 0,
            .conservation_relative_tolerance = 1.0e-12,
            .relative_tolerance = 1.0e-8,
            .picard_relaxation = 0.5,
            .max_iterations = 20,
            .pore_exchange_fraction = 1,
            .micropore_face_flux_by_component = &micro_face,
            .macropore_face_flux_by_component = &macro_face,
        }),
    );
    try std.testing.expectEqualSlices(f64, &micro_before, &micro);
    try std.testing.expectEqualSlices(f64, &macro_before, &macro);
    try std.testing.expectEqualSlices(f64, &boundary_before, &boundary);
    try std.testing.expectEqualSlices(f64, &micro_face_before, &micro_face);
    try std.testing.expectEqualSlices(f64, &macro_face_before, &macro_face);
}
