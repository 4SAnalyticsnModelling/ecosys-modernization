const std = @import("std");
const builtin = @import("builtin");
const numerics = @import("../../core/numerics.zig");
const grid_module = @import("../../state/grid.zig");
const water_flux = @import("../water/flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");

const maximum_dense_newton_components: usize = 256;

pub const FaceGeometry = struct { source_path_length_m: []const f64, destination_path_length_m: []const f64, face_area_m2: []const f64 };

pub const Properties = struct {
    vapor_diffusivity_m2_per_h: []const f64,
    air_fraction: []const f64,
    porosity_fraction: []const f64,
    tortuosity: f64,
    /// Physical duration represented by this solve. The external model clock
    /// remains hourly; retry substeps pass 0.5 or 0.25 here.
    time_step_hours: f64 = 1,
};

pub const Options = struct {
    max_iterations: u16,
    absolute_tolerance_m3: f64 = 1e-15,
    relative_tolerance: f64 = 1e-9,
    picard_relaxation: f64 = 0.5,
    directional_probe_fraction: f64 = 0.5,
    minimum_newton_fraction: f64 = 0.05,
    maximum_newton_fraction: f64 = 1.0,
    /// Depth-one Anderson acceleration of the relaxed Picard recovery step,
    /// mirroring `core/numerics.zig`. The residual here couples every cell to
    /// each of its face neighbours (the dense Jacobian below is built column by
    /// column over all cells), so this is not a scalar problem per coordinate
    /// and cannot delegate to the shared scalar solver; the same recovery
    /// semantics are reproduced locally instead, as in
    /// `soil/water/snow_transport_solver.zig`. An Anderson candidate is
    /// accepted only when it strictly improves the accepted current iterate;
    /// the relaxed point remains private secant history. Disable only to
    /// reproduce a pre-Anderson trajectory.
    anderson_recovery: bool = true,
    /// Divergence/oscillation watch, mirroring `core/numerics.zig`. Consecutive
    /// iterations whose scaled norm exceeds `divergence_growth_factor` times the
    /// best norm seen are counted; past `divergence_patience` of them the solve
    /// is diverging or oscillating, and saying so is more useful than burning
    /// the remaining ceiling to report mere non-convergence.
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    /// Runtime memory/performance tradeoff, mirroring `soil/heat/solver_types.zig`.
    /// Zero selects only the O(n) directional Newton/Picard path, which is also
    /// how tests force a reachable recovery branch without needing genuine
    /// physical stiffness. Values above the internal 256-component safety cap
    /// are clamped.
    dense_newton_max_components: usize = 256,
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

/// NPH-bounded replacement for WATSUB's repeated VOLV diffusion sweeps. The
/// converged face flux is published atomically to the shared water/heat graph.
pub fn solveAndBindTransportFaces(allocator: std.mem.Allocator, grid: *grid_module.GridState, hydrology: *transport_hydrology.State, shared_faces: *transport_hydrology.SoilFaces, geometry: FaceGeometry, properties: Properties, options: Options) !Result {
    var control: TestControl = .{};
    return solveAndBindTransportFacesControlled(allocator, grid, hydrology, shared_faces, geometry, properties, options, &control);
}

fn solveAndBindTransportFacesControlled(allocator: std.mem.Allocator, grid: *grid_module.GridState, hydrology: *transport_hydrology.State, shared_faces: *transport_hydrology.SoilFaces, geometry: FaceGeometry, properties: Properties, options: Options, control: *TestControl) !Result {
    const count = shared_faces.micropore_faces.len;
    const cells = grid.layer_count;
    if (shared_faces.active_by_face.len != count or shared_faces.active_by_layer.len != cells or shared_faces.vapor_flux_m3_per_step.len != count or geometry.source_path_length_m.len != count or geometry.destination_path_length_m.len != count or geometry.face_area_m2.len != count or properties.vapor_diffusivity_m2_per_h.len != cells or properties.air_fraction.len != cells or properties.porosity_fraction.len != cells or hydrology.water_vapor_volume_m3.len != cells) return error.SoilVaporSolverDimensionMismatch;
    try validateOptions(properties, options);
    const base = try allocator.dupe(f64, grid.water_vapor_volume_m3);
    defer allocator.free(base);
    const current = try allocator.dupe(f64, base);
    defer allocator.free(current);
    const residual = try allocator.alloc(f64, cells);
    defer allocator.free(residual);
    const target = try allocator.alloc(f64, cells);
    defer allocator.free(target);
    const scratch = try allocator.alloc(f64, cells);
    defer allocator.free(scratch);
    const trial_flux = try allocator.alloc(f64, count);
    defer allocator.free(trial_flux);
    const probe = try allocator.alloc(f64, cells);
    defer allocator.free(probe);
    const probe_residual = try allocator.alloc(f64, cells);
    defer allocator.free(probe_residual);
    const candidate = try allocator.alloc(f64, cells);
    defer allocator.free(candidate);
    const candidate_residual = try allocator.alloc(f64, cells);
    defer allocator.free(candidate_residual);
    const dense_matrix_elements = try denseMatrixElements(
        cells,
        options.dense_newton_max_components,
    );
    const jacobian = try allocator.alloc(f64, dense_matrix_elements);
    defer allocator.free(jacobian);
    const newton_delta = try allocator.alloc(f64, cells);
    defer allocator.free(newton_delta);
    // Depth-one Anderson history over the fixed-point defect g(x) - x, which is
    // exactly `residual` here, plus the plain relaxed-Picard candidate an
    // accepted Anderson step displaced (see the stagnation exit below).
    const previous_state = try allocator.alloc(f64, cells);
    defer allocator.free(previous_state);
    const previous_residual = try allocator.alloc(f64, cells);
    defer allocator.free(previous_residual);
    var conserved_vapor_total_m3: f64 = 0;
    for (base) |value| conserved_vapor_total_m3 += value;
    var newton_steps: u16 = 0;
    var picard_steps: u16 = 0;
    var anderson_steps: u16 = 0;
    var have_history = false;
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
        try residualAt(grid, shared_faces, geometry, properties, base, current, target, residual, scratch, trial_flux);
        const norm = try scaledNorm(current, residual, options);
        if (!retrying_newton_after_anderson and norm <= 1) {
            try residualAt(grid, shared_faces, geometry, properties, base, current, target, residual, scratch, shared_faces.vapor_flux_m3_per_step);
            @memcpy(grid.water_vapor_volume_m3, current);
            @memcpy(hydrology.water_vapor_volume_m3, current);
            @memset(hydrology.vapor_face_flux_m3_per_step, 0);
            for (shared_faces.micropore_faces, shared_faces.direction_axis, shared_faces.active_by_face, shared_faces.vapor_flux_m3_per_step) |face, axis, active, flux| hydrology.vapor_face_flux_m3_per_step[face.first_cell * 3 + axis] = if (active) flux else 0;
            try grid.validateFinite();
            try hydrology.validateFinite();
            return .{ .iterations = iteration + 1, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .maximum_scaled_residual = norm, .anderson_steps = anderson_steps };
        }
        if (norm < best_norm) {
            best_norm = norm;
            non_improving_steps = 0;
        } else if (norm > options.divergence_growth_factor * best_norm) {
            non_improving_steps += 1;
            if (non_improving_steps >= options.divergence_patience) {
                std.log.warn("soil vapor solver diverging: iteration={d} scaled_residual={e} best_scaled_residual={e} growth_factor={e} patience={d}", .{ iteration + 1, norm, best_norm, options.divergence_growth_factor, options.divergence_patience });
                return error.SoilVaporSolverDiverged;
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
            var dense_jacobian_valid = cells <= @min(options.dense_newton_max_components, maximum_dense_newton_components);
            for (0..cells) |column| {
                if (!dense_jacobian_valid) break;
                @memcpy(probe, current);
                const perturbation = std.math.cbrt(std.math.floatEps(f64)) * @max(1.0e-3, @abs(current[column]));
                probe[column] += perturbation;
                if (residualAt(grid, shared_faces, geometry, properties, base, probe, target, probe_residual, scratch, trial_flux)) |_| {
                    for (0..cells) |row| jacobian[row * cells + column] = probe_residual[row];
                    if (current[column] > perturbation) {
                        @memcpy(probe, current);
                        probe[column] -= perturbation;
                        if (residualAt(grid, shared_faces, geometry, properties, base, probe, target, candidate_residual, scratch, trial_flux)) |_| {
                            for (0..cells) |row| jacobian[row * cells + column] = (jacobian[row * cells + column] - candidate_residual[row]) / (2.0 * perturbation);
                        } else |_| {
                            dense_jacobian_valid = false;
                            break;
                        }
                    } else {
                        for (0..cells) |row| jacobian[row * cells + column] = (jacobian[row * cells + column] - residual[row]) / perturbation;
                    }
                } else |_| {
                    dense_jacobian_valid = false;
                    break;
                }
            }
            if (dense_jacobian_valid) {
                for (residual, newton_delta) |value, *rhs| rhs.* = -value;
                if (numerics.solveDenseLinearSystem(jacobian, newton_delta, cells)) {
                    var line_fraction: f64 = 1;
                    var line_search: u8 = 0;
                    while (line_search < 8) : (line_search += 1) {
                        var valid = true;
                        for (current, newton_delta, candidate) |value, delta, *next| {
                            next.* = value + line_fraction * delta;
                            if (!std.math.isFinite(next.*) or next.* < 0) valid = false;
                        }
                        if (valid) valid = projectConservedTotal(candidate, conserved_vapor_total_m3);
                        if (valid) {
                            if (residualAt(grid, shared_faces, geometry, properties, base, candidate, target, candidate_residual, scratch, trial_flux)) |_| {
                                if (try scaledNorm(candidate, candidate_residual, options) < norm) {
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
            if (accepted_newton) continue;
            if (addDirection(current, residual, options.directional_probe_fraction, probe)) |_| {
                if (residualAt(grid, shared_faces, geometry, properties, base, probe, target, probe_residual, scratch, trial_flux)) |_| {
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
                            if (residualAt(grid, shared_faces, geometry, properties, base, candidate, target, candidate_residual, scratch, trial_flux)) |_| {
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
        if (iteration + 1 >= options.max_iterations) return error.SoilVaporSolverDidNotConverge;
        // RECOVERY. A relaxed fixed-point sample seeds the same-iteration
        // depth-one Anderson candidate but is never committed. The map image is
        // `current + residual`, and every image carries the same conserved
        // vapour total by construction, so an affine combination of two images
        // carries that total too; the accepted candidate is conservatively
        // corrected in its largest pool, never componentwise clipped.
        _ = try addPrivateAndersonSeed(
            current,
            residual,
            options.picard_relaxation,
            candidate,
        ) orelse return error.SoilVaporSolverStagnated;
        var used_anderson = false;
        if (residualAt(grid, shared_faces, geometry, properties, base, candidate, target, candidate_residual, scratch, trial_flux)) |_| {
            if (numerics.andersonDepthOneCandidate(current, residual, candidate, candidate_residual, probe)) {
                var admissible = true;
                for (probe) |*value| {
                    if (!std.math.isFinite(value.*) or value.* < 0) admissible = false;
                }
                if (admissible) admissible = projectConservedTotal(probe, conserved_vapor_total_m3);
                if (admissible) {
                    if (residualAt(grid, shared_faces, geometry, properties, base, probe, target, probe_residual, scratch, trial_flux)) |_| {
                        const accelerated_norm = try scaledNorm(probe, probe_residual, options);
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
            // The secant ratio is computed on the *relaxed* defect, normalized
            // by its own largest scaled component. Without that normalization
            // the sums silently underflow: a slowly crawling recovery step
            // changes the defect by far less than one tolerance unit, the
            // squared terms fall below machine epsilon, and the acceleration
            // gate then rejects exactly the stalled sequence it exists to
            // rescue. Normalizing leaves the ratio unchanged (numerator and
            // denominator scale together) while putting the denominator at or
            // above one by construction.
            var largest_change: f64 = 0;
            for (residual, previous_residual, current) |now, before, value| {
                const scale = options.absolute_tolerance_m3 + options.relative_tolerance * @abs(value);
                largest_change = @max(largest_change, @abs((now - before) / scale));
            }
            var numerator: f64 = 0;
            var denominator: f64 = 0;
            if (std.math.isFinite(largest_change) and largest_change > 0) {
                for (residual, previous_residual, current) |now, before, value| {
                    const scale = options.absolute_tolerance_m3 + options.relative_tolerance * @abs(value);
                    const change = ((now - before) / scale) / largest_change;
                    numerator += change * ((now / scale) / largest_change);
                    denominator += change * change;
                }
            }
            if (std.math.isFinite(numerator) and std.math.isFinite(denominator) and denominator > std.math.floatEps(f64)) {
                const mixing = numerator / denominator;
                if (std.math.isFinite(mixing)) {
                    var admissible = true;
                    for (probe, current, residual, previous_state, previous_residual) |*value, now, now_defect, before, before_defect| {
                        // Relaxed images provide the private secant history.
                        // The unrelaxed Picard map is strongly expansive
                        // on a stiff vapour grid, so mixing its images produced
                        // unusable candidates. Both maps share the same fixed
                        // point, and the secant ratio above is invariant to
                        // this common factor.
                        const mapped_now = now + options.picard_relaxation * now_defect;
                        const mapped_before = before + options.picard_relaxation * before_defect;
                        value.* = mapped_now - mixing * (mapped_now - mapped_before);
                        if (!std.math.isFinite(value.*) or value.* < 0) admissible = false;
                    }
                    if (admissible) admissible = projectConservedTotal(probe, conserved_vapor_total_m3);
                    if (admissible) {
                        if (residualAt(grid, shared_faces, geometry, properties, base, probe, target, probe_residual, scratch, trial_flux)) |_| {
                            const accelerated_norm = try scaledNorm(probe, probe_residual, options);
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
        if (!used_anderson) return error.SoilVaporSolverStagnated;
        // STAGNATION. The audit records this solver as having no stagnation exit
        // at all: it could only end by convergence, NaN or ceiling exhaustion.
        // The step test is scaled to the physical size of the problem (the
        // largest inventory, floored by the conserved vapour total) rather than
        // to one model unit, because vapour volumes here are far below one and a
        // unit floor would make every meaningful step look stationary.
        const step_tolerance = 8.0 * std.math.floatEps(f64) * @max(maximumMagnitude(current), conserved_vapor_total_m3);
        if (maximumDifference(current, candidate) <= step_tolerance) {
            std.log.err("soil vapor Newton-Raphson/Picard stagnated: iteration={d} scaled_residual={e} step={e} step_tolerance={e}", .{ iteration + 1, norm, maximumDifference(current, candidate), step_tolerance });
            return error.SoilVaporSolverStagnated;
        }
        @memcpy(current, candidate);
        control.record(.anderson_accept);
        picard_steps += 1;
        newton_retry_required = true;
    }
    try residualAt(grid, shared_faces, geometry, properties, base, current, target, residual, scratch, trial_flux);
    const final_norm = try scaledNorm(current, residual, options);
    if (!newton_retry_required and final_norm <= 1) {
        try residualAt(grid, shared_faces, geometry, properties, base, current, target, residual, scratch, shared_faces.vapor_flux_m3_per_step);
        @memcpy(grid.water_vapor_volume_m3, current);
        @memcpy(hydrology.water_vapor_volume_m3, current);
        @memset(hydrology.vapor_face_flux_m3_per_step, 0);
        for (shared_faces.micropore_faces, shared_faces.direction_axis, shared_faces.active_by_face, shared_faces.vapor_flux_m3_per_step) |face, axis, active, flux| hydrology.vapor_face_flux_m3_per_step[face.first_cell * 3 + axis] = if (active) flux else 0;
        try grid.validateFinite();
        try hydrology.validateFinite();
        return .{ .iterations = options.max_iterations, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .maximum_scaled_residual = final_norm, .anderson_steps = anderson_steps };
    }
    if (!builtin.is_test) std.log.err("soil vapor Newton-Raphson/Picard did not converge: iterations={d} newton_raphson_steps={d} picard_steps={d} maximum_scaled_residual={e}", .{ options.max_iterations, newton_steps, picard_steps, final_norm });
    return error.SoilVaporSolverDidNotConverge;
}

fn projectConservedTotal(values: []f64, required_total: f64) bool {
    if (values.len == 0) return false;
    var actual_total: f64 = 0;
    var largest_index: usize = 0;
    for (values, 0..) |value, index| {
        if (!std.math.isFinite(value) or value < 0) return false;
        actual_total += value;
        if (value > values[largest_index]) largest_index = index;
    }
    values[largest_index] += required_total - actual_total;
    return std.math.isFinite(values[largest_index]) and values[largest_index] >= 0;
}

fn residualAt(grid: *const grid_module.GridState, faces: *const transport_hydrology.SoilFaces, geometry: FaceGeometry, properties: Properties, base: []const f64, trial: []const f64, target: []f64, residual: []f64, scratch: []f64, output_flux: []f64) !void {
    @memcpy(scratch, trial);
    @memcpy(target, base);
    @memset(output_flux, 0);
    for (faces.micropore_faces, 0..) |face, index| {
        if (!faces.active_by_face[index]) continue;
        if (face.first_cell >= grid.layer_count or face.second_cell >= grid.layer_count or face.first_cell == face.second_cell) return error.InvalidSoilVaporFace;
        const source = face.first_cell;
        const destination = face.second_cell;
        const flux = try water_flux.calculateVaporFaceFlux(.{ .source_air_volume_m3 = grid.air_volume_m3[source], .destination_air_volume_m3 = grid.air_volume_m3[destination], .source_vapor_volume_m3 = scratch[source], .destination_vapor_volume_m3 = scratch[destination], .source_vapor_diffusivity_m2_per_h = properties.vapor_diffusivity_m2_per_h[source], .destination_vapor_diffusivity_m2_per_h = properties.vapor_diffusivity_m2_per_h[destination], .source_air_fraction = properties.air_fraction[source], .destination_air_fraction = properties.air_fraction[destination], .source_porosity_fraction = properties.porosity_fraction[source], .destination_porosity_fraction = properties.porosity_fraction[destination], .tortuosity = properties.tortuosity, .source_path_length_m = geometry.source_path_length_m[index], .destination_path_length_m = geometry.destination_path_length_m[index], .face_area_m2 = geometry.face_area_m2[index], .time_fraction = properties.time_step_hours });
        // In the implicit whole-hour solve, positivity is enforced on the
        // converged inventories rather than by the explicit WATSUB donor cap.
        // Using the unlimited constitutive flux keeps the residual continuous;
        // the resulting diffusion matrix is conservative and positivity
        // preserving, without repeated sub-hour sweeps.
        const implicit_flux_m3 = flux.unlimited_vapor_m3;
        output_flux[index] = implicit_flux_m3;
        target[source] -= implicit_flux_m3;
        target[destination] += implicit_flux_m3;
    }
    for (target, trial, residual) |value, trial_value, *difference| {
        if (!std.math.isFinite(value)) return error.InvalidSoilVaporCandidate;
        difference.* = value - trial_value;
    }
}

fn addDirection(current: []const f64, direction: []const f64, fraction: f64, output: []f64) anyerror!void {
    for (current, direction, output) |value, delta, *candidate| {
        candidate.* = value + fraction * delta;
        if (!std.math.isFinite(candidate.*) or candidate.* < 0) return error.InvalidSoilVaporCandidate;
    }
}

/// Builds only the private relaxed-Picard image used to form an Anderson
/// candidate. The configured relaxation is unchanged when admissible. When it
/// would create a negative/non-finite private image, deterministically halve
/// the relaxation until the sample is admissible. The sample is never an
/// accepted iterate: the caller still requires strict Anderson merit
/// improvement and then a mandatory Newton retry.
fn addPrivateAndersonSeed(current: []const f64, direction: []const f64, requested_fraction: f64, output: []f64) !?f64 {
    const maximum_backtracks: u8 = 32;
    var fraction = requested_fraction;
    for (0..maximum_backtracks) |_| {
        addDirection(current, direction, fraction, output) catch |err| switch (err) {
            error.InvalidSoilVaporCandidate => {
                fraction *= 0.5;
                continue;
            },
            else => return err,
        };
        // A representational no-op cannot supply secant information. Smaller
        // fractions cannot improve it, so stop rather than looping pointlessly.
        if (maximumDifference(current, output) == 0) return null;
        return fraction;
    }
    return null;
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

fn scaledNorm(state: []const f64, residual: []const f64, options: Options) !f64 {
    var maximum: f64 = 0;
    for (state, residual) |value, difference| {
        if (!std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference)) return error.NonFiniteSoilVaporSolverState;
        maximum = @max(maximum, @abs(difference) / (options.absolute_tolerance_m3 + options.relative_tolerance * @abs(value)));
    }
    return maximum;
}

fn validateOptions(properties: Properties, options: Options) !void {
    if (!options.anderson_recovery or !std.math.isFinite(properties.tortuosity) or properties.tortuosity < 0 or !std.math.isFinite(properties.time_step_hours) or properties.time_step_hours <= 0 or properties.time_step_hours > 1 or options.max_iterations == 0 or !std.math.isFinite(options.absolute_tolerance_m3) or options.absolute_tolerance_m3 <= 0 or !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or !std.math.isFinite(options.directional_probe_fraction) or options.directional_probe_fraction <= 0 or !std.math.isFinite(options.minimum_newton_fraction) or options.minimum_newton_fraction <= 0 or !std.math.isFinite(options.maximum_newton_fraction) or options.maximum_newton_fraction < options.minimum_newton_fraction or options.maximum_newton_fraction > 1 or options.divergence_patience == 0 or !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1) return error.InvalidSoilVaporSolverOptions;
}

fn denseMatrixElements(cell_count: usize, maximum_dense_components: usize) !usize {
    if (cell_count > @min(maximum_dense_components, maximum_dense_newton_components)) return 0;
    return std.math.mul(usize, cell_count, cell_count);
}

test "soil vapor omits the dense Jacobian above its threshold" {
    try std.testing.expectEqual(@as(usize, 100), try denseMatrixElements(10, 256));
    try std.testing.expectEqual(@as(usize, 0), try denseMatrixElements(257, 256));
    try std.testing.expectEqual(@as(usize, 0), try denseMatrixElements(20_000, 256));
    try std.testing.expectEqual(@as(usize, 0), try denseMatrixElements(20_000, std.math.maxInt(usize)));
}

test "vapor hybrid solve conserves VOLV and publishes shared face flux" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.air_volume_m3, 1);
    grid.water_vapor_volume_m3[0] = 0.01;
    var snow = try @import("../solute/snow_solute_transport.zig").State.init(std.testing.allocator, 2, 1);
    defer snow.deinit();
    var hydrology = try transport_hydrology.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    try hydrology.syncStorage(&grid, &snow);
    var faces = try transport_hydrology.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    const one = [_]f64{1};
    const cell_one = [_]f64{ 1, 1 };
    const porosity = [_]f64{ 0.5, 0.5 };
    const result = try solveAndBindTransportFaces(std.testing.allocator, &grid, &hydrology, &faces, .{ .source_path_length_m = &one, .destination_path_length_m = &one, .face_area_m2 = &one }, .{ .vapor_diffusivity_m2_per_h = &cell_one, .air_fraction = &porosity, .porosity_fraction = &porosity, .tortuosity = 1 }, .{ .max_iterations = 20 });
    try std.testing.expect(result.iterations < 20);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), grid.water_vapor_volume_m3[0] + grid.water_vapor_volume_m3[1], 1e-12);
    try std.testing.expect(faces.vapor_flux_m3_per_step[0] > 0);
    try std.testing.expectEqual(faces.vapor_flux_m3_per_step[0], hydrology.vapor_face_flux_m3_per_step[0]);

    faces.active_by_face[0] = false;
    grid.water_vapor_volume_m3[0..2].* = .{ 0.01, 0 };
    hydrology.vapor_face_flux_m3_per_step[0] = 99;
    _ = try solveAndBindTransportFaces(std.testing.allocator, &grid, &hydrology, &faces, .{ .source_path_length_m = &one, .destination_path_length_m = &one, .face_area_m2 = &one }, .{ .vapor_diffusivity_m2_per_h = &cell_one, .air_fraction = &porosity, .porosity_fraction = &porosity, .tortuosity = 1 }, .{ .max_iterations = 20 });
    try std.testing.expectEqualSlices(f64, &.{ 0.01, 0 }, grid.water_vapor_volume_m3);
    try std.testing.expectEqual(@as(f64, 0), faces.vapor_flux_m3_per_step[0]);
    try std.testing.expectEqual(@as(f64, 0), hydrology.vapor_face_flux_m3_per_step[0]);
}

test "dense vapor Newton converges a linear face within one NPH iteration" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.air_volume_m3, 1);
    grid.water_vapor_volume_m3[0] = 0.01;
    var snow = try @import("../solute/snow_solute_transport.zig").State.init(std.testing.allocator, 2, 1);
    defer snow.deinit();
    var hydrology = try transport_hydrology.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    try hydrology.syncStorage(&grid, &snow);
    var faces = try transport_hydrology.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    const one = [_]f64{1};
    const cell_one = [_]f64{ 1, 1 };
    const porosity = [_]f64{ 0.5, 0.5 };
    const result = try solveAndBindTransportFaces(std.testing.allocator, &grid, &hydrology, &faces, .{ .source_path_length_m = &one, .destination_path_length_m = &one, .face_area_m2 = &one }, .{ .vapor_diffusivity_m2_per_h = &cell_one, .air_fraction = &porosity, .porosity_fraction = &porosity, .tortuosity = 1 }, .{ .max_iterations = 1, .minimum_newton_fraction = 0.05, .maximum_newton_fraction = 0.05 });
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), grid.water_vapor_volume_m3[0] + grid.water_vapor_volume_m3[1], 1e-12);
    try std.testing.expect(faces.vapor_flux_m3_per_step[0] > 0);
}

test "private Anderson seed preserves admissible relaxation and backtracks invalid candidates" {
    const admissible_current = [_]f64{ 1, 0 };
    const admissible_direction = [_]f64{ -0.5, 0.5 };
    var output: [2]f64 = undefined;
    try std.testing.expectEqual(
        @as(?f64, 0.5),
        try addPrivateAndersonSeed(&admissible_current, &admissible_direction, 0.5, &output),
    );
    try std.testing.expectEqualSlices(f64, &.{ 0.75, 0.25 }, &output);

    const stiff_current = [_]f64{ 0.01, 0 };
    const stiff_direction = [_]f64{ -0.2, 0.2 };
    try std.testing.expectError(
        error.InvalidSoilVaporCandidate,
        addDirection(&stiff_current, &stiff_direction, 0.5, &output),
    );
    try std.testing.expectEqual(
        @as(?f64, 0.03125),
        try addPrivateAndersonSeed(&stiff_current, &stiff_direction, 0.5, &output),
    );
    try std.testing.expectEqualSlices(f64, &.{ 0.00375, 0.00625 }, &output);

    try std.testing.expectEqual(
        @as(?f64, null),
        try addPrivateAndersonSeed(&admissible_current, &.{ 0, 0 }, 0.5, &output),
    );
}

test "stiff vapor backtracked seed accepts only Anderson then retries Newton" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.air_volume_m3, 1);
    grid.water_vapor_volume_m3[0..2].* = .{ 0.01, 0 };
    var snow = try @import("../solute/snow_solute_transport.zig").State.init(std.testing.allocator, 2, 1);
    defer snow.deinit();
    var hydrology = try transport_hydrology.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    try hydrology.syncStorage(&grid, &snow);
    var faces = try transport_hydrology.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    const one = [_]f64{1};
    const diffusivity = [_]f64{ 40, 40 };
    const fraction = [_]f64{ 0.5, 0.5 };
    const common_options: Options = .{
        .max_iterations = 20,
        .dense_newton_max_components = 0,
    };
    var control: TestControl = .{};
    const recovered = try solveAndBindTransportFacesControlled(
        std.testing.allocator,
        &grid,
        &hydrology,
        &faces,
        .{ .source_path_length_m = &one, .destination_path_length_m = &one, .face_area_m2 = &one },
        .{ .vapor_diffusivity_m2_per_h = &diffusivity, .air_fraction = &fraction, .porosity_fraction = &fraction, .tortuosity = 1 },
        common_options,
        &control,
    );
    try std.testing.expect(recovered.maximum_scaled_residual <= 1);
    try std.testing.expect(recovered.anderson_steps > 0);
    try std.testing.expectEqual(recovered.anderson_steps, recovered.picard_steps);
    try std.testing.expect(control.event_count >= 3);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[0]);
    try std.testing.expectEqual(MethodEvent.anderson_accept, control.events[1]);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[2]);
    try std.testing.expect(grid.water_vapor_volume_m3[0] >= 0);
    try std.testing.expect(grid.water_vapor_volume_m3[1] >= 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), grid.water_vapor_volume_m3[0] + grid.water_vapor_volume_m3[1], 1e-13);
}

/// Stiff-but-solvable vapour fixture shared by the conformance tests below.
/// Six cells in a line, a diffusivity large relative to the inventory and all
/// of the vapour concentrated in one end cell: the regime where the relaxed
/// Picard recovery map crawls, and so the regime the v1.0.0 brief wants an
/// Anderson-accelerated recovery for. Owned as a fixture because every buffer
/// has to outlive the solve call.
const StiffVaporCase = struct {
    grid: grid_module.GridState,
    snow: @import("../solute/snow_solute_transport.zig").State,
    hydrology: transport_hydrology.State,
    faces: transport_hydrology.SoilFaces,
    path_length: []f64,
    area: []f64,
    diffusivity: []f64,
    fraction: []f64,

    const cells: usize = 6;
    const total_m3: f64 = 0.02;

    fn init(allocator: std.mem.Allocator) !StiffVaporCase {
        const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = cells, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = cells }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
        var grid = try grid_module.GridState.init(allocator, cfg);
        errdefer grid.deinit();
        @memset(grid.air_volume_m3, 1);
        var snow = try @import("../solute/snow_solute_transport.zig").State.init(allocator, cells, 1);
        errdefer snow.deinit();
        var hydrology = try transport_hydrology.State.init(allocator, cells, 1, 1, 1);
        errdefer hydrology.deinit();
        try hydrology.syncStorage(&grid, &snow);
        var faces = try transport_hydrology.buildSoilFaces(allocator, &hydrology, &grid);
        errdefer faces.deinit();
        const path_length = try allocator.alloc(f64, faces.micropore_faces.len);
        errdefer allocator.free(path_length);
        @memset(path_length, 1);
        const area = try allocator.alloc(f64, faces.micropore_faces.len);
        errdefer allocator.free(area);
        @memset(area, 1);
        const diffusivity = try allocator.alloc(f64, grid.layer_count);
        errdefer allocator.free(diffusivity);
        // Large relative to the inventory, so the explicit relaxed-Picard map is
        // a slow contraction here. That is what makes recovery observable.
        @memset(diffusivity, 40);
        const fraction = try allocator.alloc(f64, grid.layer_count);
        errdefer allocator.free(fraction);
        @memset(fraction, 0.5);
        return .{ .grid = grid, .snow = snow, .hydrology = hydrology, .faces = faces, .path_length = path_length, .area = area, .diffusivity = diffusivity, .fraction = fraction };
    }

    fn deinit(self: *StiffVaporCase, allocator: std.mem.Allocator) void {
        allocator.free(self.fraction);
        allocator.free(self.diffusivity);
        allocator.free(self.area);
        allocator.free(self.path_length);
        self.faces.deinit();
        self.hydrology.deinit();
        self.snow.deinit();
        self.grid.deinit();
    }

    fn solve(self: *StiffVaporCase, allocator: std.mem.Allocator, options: Options) !Result {
        var control: TestControl = .{};
        return self.solveControlled(allocator, options, &control);
    }

    fn solveControlled(self: *StiffVaporCase, allocator: std.mem.Allocator, options: Options, control: *TestControl) !Result {
        // Reset the inventory so the trajectories compared below really do start
        // from the same state.
        @memset(self.grid.water_vapor_volume_m3, 0);
        self.grid.water_vapor_volume_m3[0] = total_m3;
        @memset(self.hydrology.water_vapor_volume_m3, 0);
        self.hydrology.water_vapor_volume_m3[0] = total_m3;
        return solveAndBindTransportFacesControlled(allocator, &self.grid, &self.hydrology, &self.faces, .{ .source_path_length_m = self.path_length, .destination_path_length_m = self.path_length, .face_area_m2 = self.area }, .{ .vapor_diffusivity_m2_per_h = self.diffusivity, .air_fraction = self.fraction, .porosity_fraction = self.fraction, .tortuosity = 1 }, options, control);
    }
};

test "soil vapor uses mandatory same-iteration Anderson recovery" {
    // Conformance guard for the v1.0.0 brief. Before this change the recovery
    // step was a plain relaxed Picard with no Anderson mixture, so neither the
    // `anderson_recovery` option nor the `anderson_steps` field existed and this
    // test could not have compiled, let alone passed.
    var case = try StiffVaporCase.init(std.testing.allocator);
    defer case.deinit(std.testing.allocator);

    // Dense Newton solves this fixture's near-linear residual exactly, so
    // reaching the recovery branch at all requires forcing it, not merely
    // picking a stiff diffusivity (a stiffness sweep either lets dense Newton
    // solve it outright or overwhelms the relaxed Picard fallback entirely,
    // with no stable band in between). A MILD diffusivity keeps the relaxed
    // Picard map itself a well-behaved contraction; disabling the dense path
    // while a private seam rejects the first Newton attempt without weakening
    // any production bound or tolerance.
    @memset(case.diffusivity, 1);
    const forced_recovery: Options = .{ .max_iterations = 20 };
    var control: TestControl = .{ .forced_initial_newton_failures = 1 };
    const with_recovery = try case.solveControlled(std.testing.allocator, forced_recovery, &control);
    const recovered = try std.testing.allocator.dupe(f64, case.grid.water_vapor_volume_m3);
    defer std.testing.allocator.free(recovered);

    // CONTROL: the knob may move the trajectory only. Disabling it has to land on
    // the same root, so this cannot pass by having Anderson solve some other
    // problem, and it would fail if recovery perturbed the fixed point.
    var without_recovery_options = forced_recovery;
    without_recovery_options.anderson_recovery = false;
    try std.testing.expectError(error.InvalidSoilVaporSolverOptions, case.solve(std.testing.allocator, without_recovery_options));
    try std.testing.expect(with_recovery.picard_steps > 0);
    // Accounting invariant: accelerated steps are reported inside picard_steps,
    // so the pre-existing step totals keep their old meaning.
    try std.testing.expect(with_recovery.anderson_steps <= with_recovery.picard_steps);

    // Conservation and nonnegativity are the properties this solver exists to
    // maintain, and they must hold on the accelerated path too.
    var total: f64 = 0;
    for (recovered) |value| {
        try std.testing.expect(value >= 0);
        total += value;
    }
    try std.testing.expectApproxEqAbs(StiffVaporCase.total_m3, total, 1e-13);
    try std.testing.expect(with_recovery.maximum_scaled_residual <= 1);
    try std.testing.expect(control.event_count >= 3);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[0]);
    try std.testing.expectEqual(MethodEvent.anderson_accept, control.events[1]);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[2]);
}

test "soil vapor final-slot Anderson is rejected atomically" {
    var case = try StiffVaporCase.init(std.testing.allocator);
    defer case.deinit(std.testing.allocator);
    @memset(case.diffusivity, 1);
    @memset(case.grid.water_vapor_volume_m3, 0);
    case.grid.water_vapor_volume_m3[0] = StiffVaporCase.total_m3;
    @memset(case.hydrology.water_vapor_volume_m3, 0);
    case.hydrology.water_vapor_volume_m3[0] = StiffVaporCase.total_m3;
    const before = try std.testing.allocator.dupe(f64, case.grid.water_vapor_volume_m3);
    defer std.testing.allocator.free(before);
    var control: TestControl = .{ .forced_initial_newton_failures = 1 };
    try std.testing.expectError(error.SoilVaporSolverDidNotConverge, case.solveControlled(std.testing.allocator, .{ .max_iterations = 1 }, &control));
    try std.testing.expectEqualSlices(f64, before, case.grid.water_vapor_volume_m3);
    try std.testing.expectEqual(@as(usize, 1), control.event_count);
    try std.testing.expectEqual(MethodEvent.newton_attempt, control.events[0]);
}

test "soil vapor solver validates recovery and divergence options" {
    // The new detectors must not be disableable through a nonsense value: a
    // patience of zero fires on the first non-improving iteration, and a growth
    // factor below one fires on an improving one.
    var case = try StiffVaporCase.init(std.testing.allocator);
    defer case.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidSoilVaporSolverOptions, case.solve(std.testing.allocator, .{ .max_iterations = 200, .divergence_patience = 0 }));
    try std.testing.expectError(error.InvalidSoilVaporSolverOptions, case.solve(std.testing.allocator, .{ .max_iterations = 200, .divergence_growth_factor = 0.5 }));
    try std.testing.expectError(error.InvalidSoilVaporSolverOptions, case.solve(std.testing.allocator, .{ .max_iterations = 200, .divergence_growth_factor = std.math.nan(f64) }));
    // CONTROL: an admissible non-default watch is accepted and still converges,
    // so validation refuses bad values rather than everything non-default.
    _ = try case.solve(std.testing.allocator, .{ .max_iterations = 200, .divergence_patience = 2, .divergence_growth_factor = 10 });
}

test "soil vapor solver keeps ceiling exhaustion distinct from stagnation" {
    // The audit recorded this solver as having no stagnation exit at all: it
    // could only end by convergence, NaN, or exhausting the ceiling. The two
    // outcomes must stay separate errors rather than being flattened into one.
    var case = try StiffVaporCase.init(std.testing.allocator);
    defer case.deinit(std.testing.allocator);
    // One iteration from far away cannot converge, and a single relaxed step is
    // not stationary, so this has to remain the ceiling-exhaustion error.
    try std.testing.expectError(error.SoilVaporSolverDidNotConverge, case.solve(std.testing.allocator, .{ .max_iterations = 1, .minimum_newton_fraction = 1e-14, .maximum_newton_fraction = 1e-14, .directional_probe_fraction = 1e-14, .picard_relaxation = 1e-14 }));
    // CONTROL: the same fixture converges under the defaults, so the error above
    // is about the ceiling and not about an unsolvable case.
    const converged = try case.solve(std.testing.allocator, .{ .max_iterations = 200 });
    try std.testing.expect(converged.iterations < 200);
}
