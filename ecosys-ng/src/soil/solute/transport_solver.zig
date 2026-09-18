const std = @import("std");
const transport = @import("transport.zig");
const numerics = @import("../../core/numerics.zig");

const maximum_dense_newton_components: usize = 256;

pub const Options = struct {
    absolute_tolerance_mol: f64 = 1e-12,
    relative_tolerance: f64 = 1e-8,
    picard_relaxation: f64 = 0.5,
    directional_probe_fraction: f64 = 0.5,
    minimum_newton_fraction: f64 = 0.05,
    maximum_newton_fraction: f64 = 1.0,
    /// Runtime NPH input: a ceiling, never a mandatory number of sweeps.
    max_iterations: u16,
    /// Optional exact accepted ledger indexed face × runtime species.
    /// Positive moves `first_cell -> second_cell`.
    face_flux_mol_by_component: ?[]f64 = null,
    /// Divergence/oscillation watch, mirroring `core/numerics.zig`. This
    /// solver is vector-valued over cells and species, so it cannot delegate
    /// to the shared scalar solver and carries its own detector.
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    /// Depth-one Anderson acceleration of the relaxed Picard recovery step,
    /// mirroring `soil/gas/vapor_solver.zig`. An Anderson candidate is
    /// accepted only when it strictly improves the accepted current iterate.
    /// The plain relaxed Picard candidate is private secant history and is
    /// never an acceptance incumbent. Production validation rejects false.
    anderson_recovery: bool = true,
    /// Maximum cell count for the per-species dense Newton Jacobian. Larger
    /// domains retain the O(n) directional Newton path. Zero disables dense
    /// transport Jacobians. Values above the internal 256-component safety cap
    /// are clamped.
    dense_newton_max_components: usize = 256,
};

/// Rolling window of the top-of-iteration scaled residual norm, used to
/// detect when two Newton-type branches are leapfrogging each other with
/// strictly-improving-but-vanishingly-small steps -- see
/// GAS-SOLVER-ZERO-AIR-VOLUME-001 for the coupled-gas-solver instance of the
/// same shape. Unlike a plain divergence watch, this fires on stagnating
/// *improvement*, not just on the norm increasing.
const StagnationWindow = struct {
    const window_len = 10;

    values: [window_len]f64 = undefined,
    count: usize = 0,
    index: usize = 0,

    /// Records `current_norm` and returns whether cumulative relative
    /// improvement over the trailing `window_len` iterations has dropped
    /// below `relative_improvement_threshold`. Always false until the
    /// window has filled once.
    fn observe(self: *StagnationWindow, current_norm: f64, relative_improvement_threshold: f64) bool {
        var stagnating = false;
        if (self.count >= window_len) {
            const oldest = self.values[self.index];
            if (std.math.isFinite(oldest) and oldest > 0) {
                const relative_drop = (oldest - current_norm) / oldest;
                if (relative_drop < relative_improvement_threshold) stagnating = true;
            }
        }
        self.values[self.index] = current_norm;
        self.index = (self.index + 1) % window_len;
        if (self.count < window_len) self.count += 1;
        return stagnating;
    }
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

/// Solves `final = initial + transport(final)` over all supplied faces. Each
/// face contributes equal and opposite species changes, so every iterate and
/// accepted Newton direction remains globally conservative.
pub fn solve(
    allocator: std.mem.Allocator,
    state: *transport.State,
    faces: []const transport.Face,
    diffusive_conductance_m3_per_step: []const f64,
    mobility_fraction: []const f64,
    face_parameters: transport.FaceParameters,
    options: Options,
) !Result {
    try validateInputs(state, faces, diffusive_conductance_m3_per_step, mobility_fraction, face_parameters, options);
    const component_count = state.amount_mol.len;
    const base = try allocator.dupe(f64, state.amount_mol);
    defer allocator.free(base);
    const current = try allocator.dupe(f64, base);
    defer allocator.free(current);
    const residual = try allocator.alloc(f64, component_count);
    defer allocator.free(residual);
    const probe = try allocator.alloc(f64, component_count);
    defer allocator.free(probe);
    const probe_residual = try allocator.alloc(f64, component_count);
    defer allocator.free(probe_residual);
    const candidate = try allocator.alloc(f64, component_count);
    defer allocator.free(candidate);
    const candidate_residual = try allocator.alloc(f64, component_count);
    defer allocator.free(candidate_residual);
    const dense_direction = try allocator.alloc(f64, component_count);
    defer allocator.free(dense_direction);
    const dense_matrix_elements = try denseMatrixElements(
        state.cell_count,
        options.dense_newton_max_components,
    );
    const dense_matrix = try allocator.alloc(f64, dense_matrix_elements);
    defer allocator.free(dense_matrix);
    const dense_rhs = try allocator.alloc(f64, state.cell_count);
    defer allocator.free(dense_rhs);
    const fixed_point = try allocator.alloc(f64, component_count);
    defer allocator.free(fixed_point);
    const publication_candidate = try allocator.alloc(f64, component_count);
    defer allocator.free(publication_candidate);
    const publication_residual = try allocator.alloc(f64, component_count);
    defer allocator.free(publication_residual);
    const face_flux = try allocator.alloc(f64, state.species_count);
    defer allocator.free(face_flux);
    var scratch = try transport.State.init(allocator, state.cell_count, state.species_count);
    defer scratch.deinit();
    @memcpy(scratch.water_volume_m3, state.water_volume_m3);
    var newton_steps: u16 = 0;
    var picard_steps: u16 = 0;
    var anderson_steps: u16 = 0;
    var best_norm = std.math.inf(f64);
    var non_improving_steps: u16 = 0;
    var iteration: u16 = 0;
    // Two early Newton-type branches (dense per-species Newton with
    // backtracking, directional-probe/secant step) can leapfrog each other
    // indefinitely, each making a technically-strict but vanishingly small
    // improvement, which starves the RECOVERY block's Picard+Anderson
    // fallback of any chance to run -- the same shape fixed in the coupled
    // gas solver, see GAS-SOLVER-ZERO-AIR-VOLUME-001. The existing
    // divergence watch above does not catch this: it resets on any
    // improvement, however tiny.
    const stagnation_relative_improvement_threshold = 0.01;
    var stagnation_window = StagnationWindow{};
    var previous_norm = std.math.inf(f64);
    var insufficient_progress_steps: u16 = 0;
    var newton_retry_required = false;
    while (iteration < options.max_iterations) : (iteration += 1) {
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        try residualAt(&scratch, base, current, faces, diffusive_conductance_m3_per_step, mobility_fraction, face_parameters, face_flux, fixed_point, residual);
        const current_norm = try scaledNorm(current, residual, options);
        if (!retrying_newton_after_anderson and current_norm <= 1) {
            // `fixed_point` is the exactly conservative image F(current), but
            // publishing it without checking F(F(current)) - F(current) is a
            // raw Picard step.  Verify the state that will actually be
            // committed; if it is not converged, retain `current` and let the
            // normal Newton -> Anderson -> Newton path continue.
            @memcpy(publication_candidate, fixed_point);
            try residualAt(&scratch, base, publication_candidate, faces, diffusive_conductance_m3_per_step, mobility_fraction, face_parameters, face_flux, fixed_point, publication_residual);
            const publication_norm = try scaledNorm(publication_candidate, publication_residual, options);
            if (publication_norm <= 1) {
                if (options.face_flux_mol_by_component) |accepted_flux| {
                    // The published conservative image was assembled from
                    // `current`; restore that flux-evaluation state after the
                    // independent publication-residual probe above.
                    @memcpy(scratch.amount_mol, current);
                    try captureAcceptedFaceFlux(
                        &scratch,
                        base,
                        faces,
                        diffusive_conductance_m3_per_step,
                        mobility_fraction,
                        face_parameters,
                        face_flux,
                        residual,
                        accepted_flux,
                    );
                }
                @memcpy(state.amount_mol, publication_candidate);
                return .{ .iterations = iteration + 1, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .maximum_scaled_residual = publication_norm, .anderson_steps = anderson_steps };
            }
        }
        const window_stagnating = stagnation_window.observe(current_norm, stagnation_relative_improvement_threshold);
        const progress_floor = std.math.sqrt(std.math.floatEps(f64)) * @max(1.0, previous_norm);
        if (std.math.isFinite(previous_norm) and previous_norm - current_norm <= progress_floor)
            insufficient_progress_steps +|= 1
        else
            insufficient_progress_steps = 0;
        previous_norm = current_norm;
        const stagnating_this_iteration = window_stagnating or insufficient_progress_steps >= 4;
        if (current_norm < best_norm) {
            best_norm = current_norm;
            non_improving_steps = 0;
        } else if (current_norm > options.divergence_growth_factor * best_norm) {
            non_improving_steps += 1;
            if (non_improving_steps >= options.divergence_patience) {
                std.log.warn("solute transport solver diverging: iteration={d} scaled_residual={e} best_scaled_residual={e} growth_factor={e} patience={d}", .{ iteration + 1, current_norm, best_norm, options.divergence_growth_factor, options.divergence_patience });
                return error.SoluteTransportSolverDiverged;
            }
        } else {
            non_improving_steps = 0;
        }

        var accepted_newton = false;
        // Species do not couple in the transport equations. Build every
        // unconverged species block in one Newton iteration; solving only the
        // current worst carrier made the NPH ceiling scale with the runtime
        // carrier count and could never cover all carriers when species>NPH.
        @memset(dense_direction, 0);
        var has_dense_direction = false;
        if (state.cell_count <= @min(options.dense_newton_max_components, maximum_dense_newton_components)) for (0..state.species_count) |species| {
            var species_norm: f64 = 0;
            for (0..state.cell_count) |cell| {
                const component = cell * state.species_count + species;
                species_norm = @max(
                    species_norm,
                    @abs(residual[component]) /
                        residualScale(current[component], residual[component], options),
                );
            }
            if (species_norm <= 1) continue;
            if (try denseSpeciesNewtonDirection(
                &scratch,
                base,
                current,
                residual,
                faces,
                diffusive_conductance_m3_per_step,
                mobility_fraction,
                face_parameters,
                options,
                species,
                fixed_point,
                probe,
                probe_residual,
                dense_matrix,
                dense_rhs,
                dense_direction,
            )) has_dense_direction = true;
        };
        if (has_dense_direction and (!stagnating_this_iteration or retrying_newton_after_anderson)) {
            var fraction: f64 = 1;
            var search: u8 = 0;
            while (search < 20) : (search += 1) {
                if (addDirection(
                    current,
                    dense_direction,
                    fraction,
                    candidate,
                )) |_| {
                    if (residualAt(
                        &scratch,
                        base,
                        candidate,
                        faces,
                        diffusive_conductance_m3_per_step,
                        mobility_fraction,
                        face_parameters,
                        face_flux,
                        fixed_point,
                        candidate_residual,
                    )) |_| {
                        if (try scaledNorm(
                            candidate,
                            candidate_residual,
                            options,
                        ) < current_norm) {
                            @memcpy(current, candidate);
                            newton_steps += 1;
                            accepted_newton = true;
                            break;
                        }
                    } else |_| {}
                } else |_| {}
                fraction *= 0.5;
            }
        }
        if (accepted_newton) continue;
        if (!stagnating_this_iteration or retrying_newton_after_anderson) {
            if (addDirection(current, residual, options.directional_probe_fraction, probe)) |_| {
                if (residualAt(&scratch, base, probe, faces, diffusive_conductance_m3_per_step, mobility_fraction, face_parameters, face_flux, fixed_point, probe_residual)) |_| {
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
                            if (residualAt(&scratch, base, candidate, faces, diffusive_conductance_m3_per_step, mobility_fraction, face_parameters, face_flux, fixed_point, candidate_residual)) |_| {
                                const candidate_norm = try scaledNorm(candidate, candidate_residual, options);
                                if (candidate_norm < current_norm) {
                                    @memcpy(current, candidate);
                                    newton_steps += 1;
                                    accepted_newton = true;
                                }
                            } else |_| {}
                        } else |_| {}
                    }
                } else |_| {}
            } else |_| {}
        }
        if (accepted_newton) continue;
        if (retrying_newton_after_anderson) continue;
        if (iteration + 1 >= options.max_iterations)
            return error.SoluteTransportSolverDidNotConverge;

        // Sole fallback: evaluate the relaxed point as a same-iteration seed,
        // then accept only the depth-one Anderson candidate.
        try addDirection(current, residual, options.picard_relaxation, candidate);
        try residualAt(&scratch, base, candidate, faces, diffusive_conductance_m3_per_step, mobility_fraction, face_parameters, face_flux, fixed_point, candidate_residual);
        if (!numerics.andersonDepthOneCandidate(current, residual, candidate, candidate_residual, probe)) {
            const stagnation_index =
                try worstResidualIndex(current, residual, options);
            std.log.err(
                "solute transport Newton-Picard stagnated: iteration={d} scaled_residual={e} cell={d} species={d} amount_mol={e} residual_mol={e}",
                .{
                    iteration + 1,
                    current_norm,
                    stagnation_index / state.species_count,
                    stagnation_index % state.species_count,
                    current[stagnation_index],
                    residual[stagnation_index],
                },
            );
            return error.SoluteTransportSolverStagnated;
        }
        for (probe) |*value| {
            if (!std.math.isFinite(value.*) or value.* < 0) return error.SoluteTransportSolverStagnated;
        }
        try residualAt(&scratch, base, probe, faces, diffusive_conductance_m3_per_step, mobility_fraction, face_parameters, face_flux, fixed_point, probe_residual);
        const anderson_norm = try scaledNorm(probe, probe_residual, options);
        if (!numerics.andersonImprovesAcceptedMerit(anderson_norm, current_norm)) return error.SoluteTransportSolverStagnated;
        @memcpy(current, probe);
        anderson_steps += 1;
        picard_steps += 1;
        newton_retry_required = true;
    }
    try residualAt(
        &scratch,
        base,
        current,
        faces,
        diffusive_conductance_m3_per_step,
        mobility_fraction,
        face_parameters,
        face_flux,
        fixed_point,
        residual,
    );
    const final_norm = try scaledNorm(current, residual, options);
    if (!newton_retry_required and final_norm <= 1) {
        @memcpy(publication_candidate, fixed_point);
        try residualAt(&scratch, base, publication_candidate, faces, diffusive_conductance_m3_per_step, mobility_fraction, face_parameters, face_flux, fixed_point, publication_residual);
        const publication_norm = try scaledNorm(publication_candidate, publication_residual, options);
        if (publication_norm <= 1) {
            if (options.face_flux_mol_by_component) |accepted_flux| {
                @memcpy(scratch.amount_mol, current);
                try captureAcceptedFaceFlux(
                    &scratch,
                    base,
                    faces,
                    diffusive_conductance_m3_per_step,
                    mobility_fraction,
                    face_parameters,
                    face_flux,
                    residual,
                    accepted_flux,
                );
            }
            @memcpy(state.amount_mol, publication_candidate);
            return .{
                .iterations = options.max_iterations,
                .newton_raphson_steps = newton_steps,
                .picard_steps = picard_steps,
                .maximum_scaled_residual = publication_norm,
                .anderson_steps = anderson_steps,
            };
        }
    }
    const limiting_index =
        try worstResidualIndex(current, residual, options);
    std.log.warn(
        "solute transport Newton-Picard exhausted runtime ceiling: max_iterations={d} scaled_residual={e} cell={d} species={d} amount_mol={e} residual_mol={e} newton_steps={d} picard_steps={d}",
        .{
            options.max_iterations,
            final_norm,
            limiting_index / state.species_count,
            limiting_index % state.species_count,
            current[limiting_index],
            residual[limiting_index],
            newton_steps,
            picard_steps,
        },
    );
    return error.SoluteTransportSolverDidNotConverge;
}

fn denseSpeciesNewtonDirection(
    scratch: *transport.State,
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    faces: []const transport.Face,
    conductance: []const f64,
    mobility: []const f64,
    face_parameters: transport.FaceParameters,
    options: Options,
    species: usize,
    fixed_point: []f64,
    sampled_state: []f64,
    sampled_residual: []f64,
    matrix: []f64,
    rhs: []f64,
    direction: []f64,
) !bool {
    if (species >= scratch.species_count or
        matrix.len != scratch.cell_count * scratch.cell_count or
        rhs.len != scratch.cell_count or
        direction.len != current.len)
        return error.TransportFaceParameterSizeMismatch;
    for (0..scratch.cell_count) |cell|
        rhs[cell] =
            -residual[cell * scratch.species_count + species];
    for (0..scratch.cell_count) |column| {
        const state_index =
            column * scratch.species_count + species;
        const epsilon = @sqrt(std.math.floatEps(f64)) *
            @max(options.absolute_tolerance_mol, @abs(current[state_index]));
        @memcpy(sampled_state, current);
        sampled_state[state_index] += epsilon;
        if (!std.math.isFinite(sampled_state[state_index]) or
            sampled_state[state_index] < 0) return false;
        residualSpeciesAt(
            scratch,
            base,
            sampled_state,
            faces,
            conductance,
            mobility,
            face_parameters,
            fixed_point,
            sampled_residual,
            species,
        ) catch return false;
        for (0..scratch.cell_count) |row| {
            const residual_index =
                row * scratch.species_count + species;
            matrix[row * scratch.cell_count + column] =
                (sampled_residual[residual_index] -
                    residual[residual_index]) /
                epsilon;
        }
    }
    if (!numerics.solveDenseLinearSystem(
        matrix,
        rhs,
        scratch.cell_count,
    )) return false;
    for (rhs, 0..) |value, cell|
        direction[cell * scratch.species_count + species] = value;
    return true;
}

fn residualAt(scratch: *transport.State, base: []const f64, trial: []const f64, faces: []const transport.Face, conductance: []const f64, mobility: []const f64, face_parameters: transport.FaceParameters, face_flux: []f64, fixed_point: []f64, residual: []f64) !void {
    @memcpy(scratch.amount_mol, trial);
    try scratch.validateFinite();
    @memcpy(fixed_point, base);
    for (faces, 0..) |face, face_index| {
        const start = face_index * scratch.species_count;
        try transport.calculateFaceFluxesFromValidatedInputs(scratch, face, conductance[start .. start + scratch.species_count], mobility[start .. start + scratch.species_count], face_parameters, face_flux);
        for (face_flux, 0..) |flux, species_index| {
            const first_index = face.first_cell * scratch.species_count + species_index;
            const second_index = face.second_cell * scratch.species_count + species_index;
            // TRNSFRS traverses faces against the evolving substep inventory.
            // A cell shared by several faces must not donate its original
            // inventory independently to every neighbor.
            const bounded_flux = std.math.clamp(flux, -fixed_point[second_index], fixed_point[first_index]);
            fixed_point[first_index] -= bounded_flux;
            fixed_point[second_index] += bounded_flux;
        }
    }
    for (fixed_point, trial, residual) |target, value, *difference| {
        if (!std.math.isFinite(target) or target < 0) return error.InvalidImplicitTransportCandidate;
        difference.* = target - value;
    }
}

fn residualSpeciesAt(
    scratch: *transport.State,
    base: []const f64,
    trial: []const f64,
    faces: []const transport.Face,
    conductance: []const f64,
    mobility: []const f64,
    face_parameters: transport.FaceParameters,
    fixed_point: []f64,
    residual: []f64,
    species: usize,
) !void {
    @memcpy(scratch.amount_mol, trial);
    for (0..scratch.cell_count) |cell| {
        const component = cell * scratch.species_count + species;
        fixed_point[component] = base[component];
    }
    for (faces, 0..) |face, face_index| {
        const start = face_index * scratch.species_count;
        const flux = try transport.calculateFaceFluxForSpeciesFromValidatedInputs(
            scratch,
            face,
            conductance[start..][0..scratch.species_count],
            mobility[start..][0..scratch.species_count],
            face_parameters,
            species,
        );
        const first_index = face.first_cell * scratch.species_count + species;
        const second_index = face.second_cell * scratch.species_count + species;
        const bounded_flux = std.math.clamp(
            flux,
            -fixed_point[second_index],
            fixed_point[first_index],
        );
        fixed_point[first_index] -= bounded_flux;
        fixed_point[second_index] += bounded_flux;
    }
    for (0..scratch.cell_count) |cell| {
        const component = cell * scratch.species_count + species;
        const target = fixed_point[component];
        if (!std.math.isFinite(target) or target < 0)
            return error.InvalidImplicitTransportCandidate;
        residual[component] = target - trial[component];
    }
}

fn captureAcceptedFaceFlux(
    scratch: *transport.State,
    base: []const f64,
    faces: []const transport.Face,
    conductance: []const f64,
    mobility: []const f64,
    face_parameters: transport.FaceParameters,
    face_flux: []f64,
    accumulator: []f64,
    accepted_face_flux: []f64,
) !void {
    if (accepted_face_flux.len != faces.len * scratch.species_count)
        return error.SoluteFaceFluxOutputDimensionMismatch;
    @memcpy(accumulator, base);
    @memset(accepted_face_flux, 0);
    try scratch.validateFinite();
    for (faces, 0..) |face, face_index| {
        const start = face_index * scratch.species_count;
        try transport.calculateFaceFluxesFromValidatedInputs(
            scratch,
            face,
            conductance[start..][0..scratch.species_count],
            mobility[start..][0..scratch.species_count],
            face_parameters,
            face_flux,
        );
        for (face_flux, 0..) |flux, species_index| {
            const first_index =
                face.first_cell * scratch.species_count + species_index;
            const second_index =
                face.second_cell * scratch.species_count + species_index;
            const bounded_flux = std.math.clamp(
                flux,
                -accumulator[second_index],
                accumulator[first_index],
            );
            accumulator[first_index] -= bounded_flux;
            accumulator[second_index] += bounded_flux;
            accepted_face_flux[start + species_index] = bounded_flux;
        }
    }
}

fn addDirection(current: []const f64, direction: []const f64, fraction: f64, output: []f64) !void {
    for (current, direction, output) |value, delta, *candidate| {
        candidate.* = value + fraction * delta;
        if (!std.math.isFinite(candidate.*) or candidate.* < 0) return error.InvalidImplicitTransportCandidate;
    }
}

fn scaledNorm(state: []const f64, residual: []const f64, options: Options) !f64 {
    var maximum: f64 = 0;
    for (state, residual) |value, difference| {
        if (!std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference)) return error.NonFiniteImplicitTransportState;
        maximum = @max(maximum, @abs(difference) / residualScale(value, difference, options));
    }
    return maximum;
}

fn validateInputs(state: *const transport.State, faces: []const transport.Face, conductance: []const f64, mobility: []const f64, face_parameters: transport.FaceParameters, options: Options) !void {
    const face_components = try std.math.mul(usize, faces.len, state.species_count);
    if (conductance.len != face_components or mobility.len != face_components) return error.TransportFaceParameterSizeMismatch;
    if (options.face_flux_mol_by_component) |fluxes|
        if (fluxes.len != face_components)
            return error.SoluteFaceFluxOutputDimensionMismatch;
    if (!options.anderson_recovery or !std.math.isFinite(options.absolute_tolerance_mol) or options.absolute_tolerance_mol <= 0 or !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or !std.math.isFinite(options.directional_probe_fraction) or options.directional_probe_fraction <= 0 or !std.math.isFinite(options.minimum_newton_fraction) or options.minimum_newton_fraction <= 0 or !std.math.isFinite(options.maximum_newton_fraction) or options.maximum_newton_fraction < options.minimum_newton_fraction or options.maximum_newton_fraction > 1 or options.max_iterations == 0 or options.divergence_patience == 0 or !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1) return error.InvalidSoluteTransportSolverOptions;
    if (!std.math.isFinite(face_parameters.maximum_convective_fraction) or
        face_parameters.maximum_convective_fraction < 0 or
        face_parameters.maximum_convective_fraction > 1)
        return error.InvalidTransportParameter;
    try state.validateFinite();
    for (faces) |face| {
        if (face.first_cell >= state.cell_count or face.second_cell >= state.cell_count or face.first_cell == face.second_cell)
            return error.InvalidTransportFace;
        if (!std.math.isFinite(face.water_flux_m3_per_step))
            return error.InvalidTransportParameter;
    }
    for (conductance, mobility) |value, fraction| {
        if (!std.math.isFinite(value) or value < 0 or
            !std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
            return error.InvalidTransportParameter;
    }
}

fn vectorsEqual(a: []const f64, b: []const f64) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

fn denseMatrixElements(cell_count: usize, maximum_dense_components: usize) !usize {
    if (cell_count > @min(maximum_dense_components, maximum_dense_newton_components)) return 0;
    return std.math.mul(usize, cell_count, cell_count);
}

test "solute transport omits the dense Jacobian above its threshold" {
    try std.testing.expectEqual(@as(usize, 100), try denseMatrixElements(10, 256));
    try std.testing.expectEqual(@as(usize, 0), try denseMatrixElements(257, 256));
    try std.testing.expectEqual(@as(usize, 0), try denseMatrixElements(20_000, 256));
    try std.testing.expectEqual(@as(usize, 0), try denseMatrixElements(20_000, std.math.maxInt(usize)));
}

fn worstResidualIndex(
    state: []const f64,
    residual: []const f64,
    options: Options,
) !usize {
    if (state.len == 0 or state.len != residual.len)
        return error.NonFiniteImplicitTransportState;
    var limiting_index: usize = 0;
    var limiting_norm: f64 = -1;
    for (state, residual, 0..) |value, difference, index| {
        if (!std.math.isFinite(value) or value < 0 or
            !std.math.isFinite(difference))
            return error.NonFiniteImplicitTransportState;
        const norm =
            @abs(difference) /
            residualScale(value, difference, options);
        if (norm > limiting_norm) {
            limiting_norm = norm;
            limiting_index = index;
        }
    }
    return limiting_index;
}

fn residualScale(value: f64, residual: f64, options: Options) f64 {
    const target = value + residual;
    return options.absolute_tolerance_mol +
        options.relative_tolerance * @max(@abs(value), @abs(target));
}

test "trace transport inventories do not inherit a one-mol relative floor" {
    const options: Options = .{
        .absolute_tolerance_mol = 1e-13,
        .relative_tolerance = 1e-8,
        .max_iterations = 4,
    };
    const state = [_]f64{ 1e-10, 100 };
    const residual = [_]f64{ 5e-12, 1e-7 };
    try std.testing.expect(try scaledNorm(&state, &residual, options) > 1);
    try std.testing.expectEqual(@as(usize, 0), try worstResidualIndex(&state, &residual, options));
}

test "stagnation window flags collapsed relative improvement, matching GAS-SOLVER-ZERO-AIR-VOLUME-001's fix" {
    var window = StagnationWindow{};
    // Fill the window with no stagnation flagged yet (it only ever compares
    // once it has a full trailing history).
    var norm: f64 = 1000;
    for (0..StagnationWindow.window_len) |_| {
        try std.testing.expect(!window.observe(norm, 0.01));
        norm *= 0.5; // 50% drop per step: nowhere near stagnating.
    }
    // Continuing at the same strong 50% relative-drop rate must not flag
    // stagnation: this is exactly the healthy-Newton-progress case the
    // detector must never interfere with.
    try std.testing.expect(!window.observe(norm * 0.5, 0.01));
    // Now leapfrog: each step improves the norm by far less than the 1%
    // threshold (0.05% here), the same shape as two Newton-type branches
    // trading vanishingly small strict improvements. After another full
    // window of this, cumulative relative improvement collapses below the
    // threshold and stagnation must be flagged.
    var stagnating = false;
    for (0..StagnationWindow.window_len) |_| {
        stagnating = window.observe(norm, 0.01);
        norm *= 0.9995;
    }
    try std.testing.expect(stagnating);
}

test "stagnation window never fires before its window has filled" {
    var window = StagnationWindow{};
    // Even a completely flat (zero-improvement) sequence must not flag
    // stagnation until `window_len` observations have been recorded --
    // there is no "oldest" value to compare against yet.
    for (0..StagnationWindow.window_len - 1) |_| {
        try std.testing.expect(!window.observe(5, 0.01));
    }
}

test "solute transport solver rejects degenerate divergence watch options" {
    // A patience of zero would fire on the first non-improving iteration and a
    // growth factor below one would fire on an improving one, mirroring
    // soil/gas/vapor_solver.zig and soil/water/snow_transport_solver.zig.
    var state = try transport.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    state.water_volume_m3[0] = 1;
    state.water_volume_m3[1] = 1;
    (try state.cellAmounts(0))[0] = 2;
    const faces = [_]transport.Face{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }};
    const conductance = [_]f64{0.1};
    const mobility = [_]f64{1};
    const face_parameters: transport.FaceParameters = .{ .maximum_convective_fraction = 1 };
    try std.testing.expectError(error.InvalidSoluteTransportSolverOptions, solve(std.testing.allocator, &state, &faces, &conductance, &mobility, face_parameters, .{ .max_iterations = 20, .divergence_patience = 0 }));
    try std.testing.expectError(error.InvalidSoluteTransportSolverOptions, solve(std.testing.allocator, &state, &faces, &conductance, &mobility, face_parameters, .{ .max_iterations = 20, .divergence_growth_factor = 0.5 }));
    try std.testing.expectError(error.InvalidSoluteTransportSolverOptions, solve(std.testing.allocator, &state, &faces, &conductance, &mobility, face_parameters, .{ .max_iterations = 20, .divergence_growth_factor = std.math.nan(f64) }));
    try std.testing.expectError(error.InvalidSoluteTransportSolverOptions, solve(std.testing.allocator, &state, &faces, &conductance, &mobility, face_parameters, .{ .max_iterations = 20, .anderson_recovery = false }));
    try std.testing.expectError(error.InvalidSoluteTransportSolverOptions, solve(std.testing.allocator, &state, &faces, &conductance, &mobility, face_parameters, .{ .max_iterations = 20, .maximum_newton_fraction = 1.01 }));
    // CONTROL: the same inputs with the default watch still converge, so the
    // rejections above are proving option validation rather than that these
    // inputs cannot be solved at all.
    _ = try solve(std.testing.allocator, &state, &faces, &conductance, &mobility, face_parameters, .{ .max_iterations = 20 });
    // CONTROL: an admissible non-default watch is accepted too.
    (try state.cellAmounts(0))[0] = 2;
    (try state.cellAmounts(1))[0] = 0;
    _ = try solve(std.testing.allocator, &state, &faces, &conductance, &mobility, face_parameters, .{ .max_iterations = 20, .divergence_patience = 2, .divergence_growth_factor = 10 });
}

test "implicit transport converges before NPH and conserves species" {
    var state = try transport.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    state.water_volume_m3[0] = 1;
    state.water_volume_m3[1] = 1;
    (try state.cellAmounts(0))[0] = 2;
    var accepted_face_flux_mol = [_]f64{0};
    const result = try solve(std.testing.allocator, &state, &[_]transport.Face{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }}, &[_]f64{0.1}, &[_]f64{1}, .{ .maximum_convective_fraction = 1 }, .{ .max_iterations = 20, .face_flux_mol_by_component = &accepted_face_flux_mol });
    try std.testing.expect(result.iterations < 20);
    try std.testing.expect(result.newton_raphson_steps + result.picard_steps > 0);
    try std.testing.expectEqual(result.picard_steps, result.anderson_steps);
    const first = (try state.cellAmountsConst(0))[0];
    const second = (try state.cellAmountsConst(1))[0];
    try std.testing.expectApproxEqAbs(
        second,
        accepted_face_flux_mol[0],
        1e-12,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2), first + second, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0 / 3.0), first - second, 1e-8);
}

test "solute transport verifies the conservative publication state instead of accepting raw Picard" {
    var state = try transport.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    @memset(state.water_volume_m3, 1);
    state.amount_mol[0] = 2;
    state.amount_mol[1] = 1;
    const base = [_]f64{ 2, 1 };
    const faces = [_]transport.Face{.{
        .first_cell = 0,
        .second_cell = 1,
        .water_flux_m3_per_step = 0,
    }};
    const conductance = [_]f64{0.75};
    const mobility = [_]f64{1};
    var accepted_face_flux_mol = [_]f64{0};
    const options: Options = .{
        // At the initial [2,1] iterate, ||F(x)-x|| = 0.75/0.8 < 1,
        // while the old raw publication F(x)=[1.25,1.75] has residual
        // 1.125/0.8 > 1.  A verified publication therefore requires the
        // subsequent Newton update.
        .absolute_tolerance_mol = 0.8,
        .relative_tolerance = 1e-12,
        .max_iterations = 5,
        .face_flux_mol_by_component = &accepted_face_flux_mol,
    };
    const result = try solve(
        std.testing.allocator,
        &state,
        &faces,
        &conductance,
        &mobility,
        .{ .maximum_convective_fraction = 1 },
        options,
    );
    try std.testing.expect(result.iterations > 1);
    try std.testing.expect(result.newton_raphson_steps > 0);
    try std.testing.expect(result.maximum_scaled_residual <= 1);

    var scratch = try transport.State.init(std.testing.allocator, 2, 1);
    defer scratch.deinit();
    @memcpy(scratch.water_volume_m3, state.water_volume_m3);
    var target = [_]f64{ 0, 0 };
    var residual = [_]f64{ 0, 0 };
    var face_flux = [_]f64{0};
    try residualAt(&scratch, &base, state.amount_mol, &faces, &conductance, &mobility, .{ .maximum_convective_fraction = 1 }, &face_flux, &target, &residual);
    try std.testing.expect(try scaledNorm(state.amount_mol, &residual, options) <= 1);
    try std.testing.expectApproxEqAbs(state.amount_mol[1] - base[1], accepted_face_flux_mol[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 3), state.amount_mol[0] + state.amount_mol[1], 1e-14);
}

test "one Newton iteration advances every runtime species block" {
    const species_count: usize = 40;
    var state = try transport.State.init(std.testing.allocator, 2, species_count);
    defer state.deinit();
    @memset(state.water_volume_m3, 1);
    for (0..species_count) |species| {
        state.amount_mol[species] =
            @as(f64, @floatFromInt(species + 1)) * 1e-4;
        state.amount_mol[species_count + species] = 0;
    }
    const conductance = try std.testing.allocator.alloc(f64, species_count);
    defer std.testing.allocator.free(conductance);
    @memset(conductance, 0.1);
    const mobility = try std.testing.allocator.alloc(f64, species_count);
    defer std.testing.allocator.free(mobility);
    @memset(mobility, 1);
    const before = try std.testing.allocator.dupe(f64, state.amount_mol);
    defer std.testing.allocator.free(before);
    const result = try solve(
        std.testing.allocator,
        &state,
        &.{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }},
        conductance,
        mobility,
        .{ .maximum_convective_fraction = 1 },
        .{ .max_iterations = 4 },
    );
    try std.testing.expect(result.iterations <= 4);
    for (0..species_count) |species|
        try std.testing.expectApproxEqAbs(
            before[species] + before[species_count + species],
            state.amount_mol[species] +
                state.amount_mol[species_count + species],
            1e-14,
        );
}

test "shared donor is bounded across sequential runtime faces" {
    var state = try transport.State.init(std.testing.allocator, 3, 1);
    defer state.deinit();
    @memset(state.water_volume_m3, 1);
    state.amount_mol[0] = 1;
    const result = try solve(
        std.testing.allocator,
        &state,
        &.{
            .{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 },
            .{ .first_cell = 0, .second_cell = 2, .water_flux_m3_per_step = 0 },
        },
        &.{ 10, 10 },
        &.{ 1, 1 },
        .{ .maximum_convective_fraction = 1 },
        .{ .max_iterations = 80 },
    );
    try std.testing.expect(result.iterations < 80);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.amount_mol[0] + state.amount_mol[1] + state.amount_mol[2], 1e-10);
    for (state.amount_mol) |amount| try std.testing.expect(amount >= 0);
}

test "failed implicit transport leaves state unchanged" {
    var state = try transport.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    state.water_volume_m3[0] = 1;
    state.water_volume_m3[1] = 1;
    (try state.cellAmounts(0))[0] = 2;
    const before = try std.testing.allocator.dupe(f64, state.amount_mol);
    defer std.testing.allocator.free(before);
    var unpublished_face_flux_mol = [_]f64{123};
    try std.testing.expectError(error.SoluteTransportSolverDidNotConverge, solve(std.testing.allocator, &state, &[_]transport.Face{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }}, &[_]f64{0.1}, &[_]f64{1}, .{ .maximum_convective_fraction = 1 }, .{ .absolute_tolerance_mol = 1e-20, .relative_tolerance = 1e-20, .max_iterations = 1, .face_flux_mol_by_component = &unpublished_face_flux_mol }));
    try std.testing.expectEqualSlices(f64, before, state.amount_mol);
    try std.testing.expectEqual(@as(f64, 123), unpublished_face_flux_mol[0]);
}
