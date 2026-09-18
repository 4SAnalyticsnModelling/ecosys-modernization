//! `coupled_gas_solver` declarations: directions.
//!
//! Split out of `coupled_gas_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const gas = @import("transport.zig");
const atmosphere = @import("atmosphere_exchange.zig");
const numerics = @import("../../core/numerics.zig");
const group_diagnostics = @import("coupled_gas_solver_diagnostics.zig");
const group_misc = @import("coupled_gas_solver_misc.zig");
const group_residual = @import("coupled_gas_solver_residual.zig");
const group_solve = @import("coupled_gas_solver_solve.zig");

/// Scale the finite-difference perturbation to the represented species mass,
/// with its unit-aware nonlinear floor as the zero-inventory reference.
pub fn gasJacobianProbeG(mass_g: f64, absolute_tolerance_g: f64) f64 {
    return std.math.cbrt(std.math.floatEps(f64)) *
        @max(absolute_tolerance_g, @abs(mass_g));
}

pub const DenseFullNewtonWorkspace = struct {
    allocator: std.mem.Allocator,
    active_indices: []usize,
    matrix: []f64,
    jacobian_backup: []f64,
    rhs: []f64,
    rhs_backup: []f64,
    normal_rhs: []f64,
    opposite_state: []f64,
    opposite_residual: []f64,
    assemblies: u16 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        unknown_count: usize,
    ) !DenseFullNewtonWorkspace {
        const capacity = if (unknown_count <= 256) unknown_count else 0;
        const matrix_capacity = try std.math.mul(usize, capacity, capacity);
        const active_indices = try allocator.alloc(usize, capacity);
        errdefer allocator.free(active_indices);
        const matrix = try allocator.alloc(f64, matrix_capacity);
        errdefer allocator.free(matrix);
        const jacobian_backup = try allocator.alloc(f64, matrix_capacity);
        errdefer allocator.free(jacobian_backup);
        const rhs = try allocator.alloc(f64, capacity);
        errdefer allocator.free(rhs);
        const rhs_backup = try allocator.alloc(f64, capacity);
        errdefer allocator.free(rhs_backup);
        const normal_rhs = try allocator.alloc(f64, capacity);
        errdefer allocator.free(normal_rhs);
        const opposite_state = try allocator.alloc(f64, capacity);
        errdefer allocator.free(opposite_state);
        const opposite_residual = try allocator.alloc(f64, capacity);
        errdefer allocator.free(opposite_residual);
        return .{
            .allocator = allocator,
            .active_indices = active_indices,
            .matrix = matrix,
            .jacobian_backup = jacobian_backup,
            .rhs = rhs,
            .rhs_backup = rhs_backup,
            .normal_rhs = normal_rhs,
            .opposite_state = opposite_state,
            .opposite_residual = opposite_residual,
        };
    }

    pub fn deinit(self: *DenseFullNewtonWorkspace) void {
        self.allocator.free(self.opposite_residual);
        self.allocator.free(self.opposite_state);
        self.allocator.free(self.normal_rhs);
        self.allocator.free(self.rhs_backup);
        self.allocator.free(self.rhs);
        self.allocator.free(self.jacobian_backup);
        self.allocator.free(self.matrix);
        self.allocator.free(self.active_indices);
        self.* = undefined;
    }
};

pub const KrylovNewtonWorkspace = struct {
    allocator: std.mem.Allocator,
    storage: []f64,
    unknown_count: usize,
    restart_capacity: usize,
    direction_calls: u16 = 0,
    iterations: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        unknown_count: usize,
        restart_capacity: usize,
    ) !KrylovNewtonWorkspace {
        const bounded_restart = @min(
            restart_capacity,
            group_misc.maximum_krylov_restart,
        );
        return .{
            .allocator = allocator,
            .storage = try allocator.alloc(
                f64,
                try krylovStorageCount(unknown_count, bounded_restart),
            ),
            .unknown_count = unknown_count,
            .restart_capacity = bounded_restart,
        };
    }

    pub fn deinit(self: *KrylovNewtonWorkspace) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

pub fn denseFullNewtonDirection(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    target: []f64,
    sampled_residual: []f64,
    sampled_state: []f64,
    direction: []f64,
) !bool {
    var workspace = try DenseFullNewtonWorkspace.init(allocator, current.len);
    defer workspace.deinit();
    return denseFullNewtonDirectionWithWorkspace(
        allocator,
        scratch,
        base,
        current,
        residual,
        inputs,
        options,
        target,
        sampled_residual,
        sampled_state,
        direction,
        &workspace,
    );
}

pub fn denseFullNewtonDirectionWithWorkspace(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    target: []f64,
    sampled_residual: []f64,
    sampled_state: []f64,
    direction: []f64,
    workspace: *DenseFullNewtonWorkspace,
) !bool {
    if (current.len == 0) return false;
    if (current.len > workspace.active_indices.len) return false;
    var dimension: usize = 0;
    // Zero inventories with zero targets are complementarity-fixed
    // coordinates, not Newton unknowns. Retaining their zero Jacobian rows
    // makes the complete dense system singular and repeatedly diverts the
    // production solve into a scalar species path. Positive inventories are
    // the smooth manifold on which pressure displacement is differentiable;
    // zero bounds with an incoming target are released separately by
    // `activeSetGasNewtonStep`.
    const inventory_count = current.len / 3;
    for (0..scratch.cell_count) |cell| {
        for (0..3) |phase| {
            for (0..gas.species_count) |species| {
                const index = phase * inventory_count +
                    cell * gas.species_count + species;
                if (current[index] > 0) {
                    workspace.active_indices[dimension] = index;
                    dimension += 1;
                }
            }
        }
    }
    if (dimension == 0 or dimension > 256) return false;
    const matrix_length = try std.math.mul(usize, dimension, dimension);
    const matrix = workspace.matrix[0..matrix_length];
    const rhs = workspace.rhs[0..dimension];
    const jacobian_backup = workspace.jacobian_backup[0..matrix_length];
    const rhs_backup = workspace.rhs_backup[0..dimension];
    const normal_rhs = workspace.normal_rhs[0..dimension];
    const opposite_state = workspace.opposite_state[0..current.len];
    const opposite_residual = workspace.opposite_residual[0..current.len];
    const active_indices = workspace.active_indices[0..dimension];
    for (0..dimension) |column| {
        const state_index = active_indices[column];
        const epsilon = gasJacobianProbeG(
            current[state_index],
            group_misc.absoluteToleranceForCoordinate(
                options,
                state_index,
                current.len / 3,
            ),
        );
        @memcpy(sampled_state, current);
        sampled_state[state_index] += epsilon;
        group_residual.residualAt(allocator, scratch, base, sampled_state, inputs, options.transport_iteration_fraction, target, sampled_residual) catch return false;
        const central = current[state_index] >= epsilon;
        if (central) {
            @memcpy(opposite_state, current);
            opposite_state[state_index] -= epsilon;
            group_residual.residualAt(allocator, scratch, base, opposite_state, inputs, options.transport_iteration_fraction, target, opposite_residual) catch return false;
        }
        for (0..dimension) |row| {
            const residual_index = active_indices[row];
            matrix[row * dimension + column] = if (central)
                (sampled_residual[residual_index] -
                    opposite_residual[residual_index]) / (2 * epsilon)
            else
                (sampled_residual[residual_index] -
                    residual[residual_index]) / epsilon;
        }
    }
    workspace.assemblies +|= 1;
    // Solve in dimensionless coordinates. A profile can legitimately pair a
    // 1 g gaseous inventory with more than 1e8 g dissolved mass. Row scaling
    // alone protects the merit norm but leaves the direct Jacobian severely
    // column-ill-conditioned, allowing pivoting to report success with an
    // unusable trace-gas correction. Scale residual rows by their requested
    // tolerance and state columns by their inventory magnitude before the
    // direct group_solve.solve, then convert the correction back to grams.
    for (0..dimension) |row| {
        const residual_index = active_indices[row];
        const residual_scale =
            group_misc.absoluteToleranceForCoordinate(
                options,
                residual_index,
                current.len / 3,
            ) +
            options.relative_tolerance *
                @max(1.0, @abs(current[residual_index]));
        rhs[row] = -residual[residual_index] / residual_scale;
        for (0..dimension) |column| {
            const state_scale =
                @max(1.0, @abs(current[active_indices[column]]));
            matrix[row * dimension + column] *=
                state_scale / residual_scale;
        }
    }
    // Preserve the scaled system before the direct solve mutates it. Build
    // the much more expensive damped normal equations only when pivoting
    // actually reports a rank-deficient semismooth Jacobian; the ordinary
    // successful path must not pay an unused O(n^3) matrix product.
    @memcpy(jacobian_backup, matrix);
    @memcpy(rhs_backup, rhs);
    if (!numerics.solveDenseLinearSystem(matrix, rhs, dimension)) {
        @memset(matrix, 0);
        @memset(normal_rhs, 0);
        for (0..dimension) |row| {
            for (0..dimension) |column| {
                const weighted_jacobian =
                    jacobian_backup[row * dimension + column];
                normal_rhs[column] += weighted_jacobian * rhs_backup[row];
                for (0..dimension) |other_column| {
                    matrix[column * dimension + other_column] +=
                        weighted_jacobian *
                        jacobian_backup[row * dimension + other_column];
                }
            }
        }
        var maximum_normal_diagonal: f64 = 0;
        for (0..dimension) |index|
            maximum_normal_diagonal = @max(
                maximum_normal_diagonal,
                @abs(matrix[index * dimension + index]),
            );
        const damping =
            1.0e-10 * @max(1.0, maximum_normal_diagonal);
        for (0..dimension) |index|
            matrix[index * dimension + index] += damping;
        if (!numerics.solveDenseLinearSystem(
            matrix,
            normal_rhs,
            dimension,
        )) return false;
        @memcpy(rhs, normal_rhs);
    }
    @memset(direction, 0);
    for (rhs, active_indices[0..dimension]) |scaled_component, index|
        direction[index] = scaled_component *
            @max(1.0, @abs(current[index]));
    for (direction) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

pub fn denseSpeciesNewtonDirection(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    target: []f64,
    sampled_residual: []f64,
    sampled_state: []f64,
    direction: []f64,
    species: usize,
) !bool {
    const inventory_count = scratch.gaseous_mass_g.len;
    const dimension = try std.math.mul(usize, scratch.cell_count, 3);
    // Dense pivoting is a precision-oriented tail group_solve.solve, not the large-grid
    // path. Above this bound retain the O(n) matrix-free Krylov storage.
    if (dimension == 0 or dimension > 256) return false;
    const matrix = try allocator.alloc(f64, try std.math.mul(usize, dimension, dimension));
    defer allocator.free(matrix);
    const rhs = try allocator.alloc(f64, dimension);
    defer allocator.free(rhs);
    const opposite_state = try allocator.alloc(f64, current.len);
    defer allocator.free(opposite_state);
    const opposite_residual = try allocator.alloc(f64, current.len);
    defer allocator.free(opposite_residual);
    for (0..dimension) |row| rhs[row] = -residual[speciesVectorIndex(row, scratch.cell_count, inventory_count, species)];
    for (0..dimension) |column| {
        const state_index = speciesVectorIndex(column, scratch.cell_count, inventory_count, species);
        const epsilon = gasJacobianProbeG(
            current[state_index],
            group_misc.absoluteToleranceForSpecies(options, species),
        );
        @memcpy(sampled_state, current);
        sampled_state[state_index] += epsilon;
        group_residual.residualAt(allocator, scratch, base, sampled_state, inputs, options.transport_iteration_fraction, target, sampled_residual) catch return false;
        const central = current[state_index] >= epsilon;
        if (central) {
            @memcpy(opposite_state, current);
            opposite_state[state_index] -= epsilon;
            group_residual.residualAt(allocator, scratch, base, opposite_state, inputs, options.transport_iteration_fraction, target, opposite_residual) catch return false;
        }
        for (0..dimension) |row| {
            const residual_index = speciesVectorIndex(row, scratch.cell_count, inventory_count, species);
            matrix[row * dimension + column] = if (central)
                (sampled_residual[residual_index] - opposite_residual[residual_index]) / (2 * epsilon)
            else
                (sampled_residual[residual_index] - residual[residual_index]) / epsilon;
        }
    }
    if (!numerics.solveDenseLinearSystem(matrix, rhs, dimension)) return false;
    for (rhs, 0..) |value, compact_index| direction[speciesVectorIndex(compact_index, scratch.cell_count, inventory_count, species)] = value;
    return true;
}

pub fn denseAllSpeciesNewtonDirection(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    target: []f64,
    sampled_residual: []f64,
    sampled_state: []f64,
    direction: []f64,
) !bool {
    const inventory_count = scratch.gaseous_mass_g.len;
    const dimension = try std.math.mul(usize, scratch.cell_count, 3);
    if (dimension == 0 or dimension > 256) return false;
    const matrix_elements = try std.math.mul(usize, dimension, dimension);
    const matrices = try allocator.alloc(f64, try std.math.mul(usize, gas.species_count, matrix_elements));
    defer allocator.free(matrices);
    const right_hand_sides = try allocator.alloc(f64, try std.math.mul(usize, gas.species_count, dimension));
    defer allocator.free(right_hand_sides);
    @memset(direction, 0);

    // Diffusion and phase exchange are species-local, but TRNSFR pressure
    // displacement depends on total gas pressure and therefore couples the
    // seven species. Simultaneously perturbing all species aliases those
    // cross derivatives into every diagonal block, most severely for the
    // small H2 inventory. Form each diagonal block with its own perturbation;
    // the subsequent line search/global residual retains the pressure
    // coupling while avoiding the aliased Jacobian.
    for (0..gas.species_count) |species| {
        for (0..dimension) |column| {
            @memcpy(sampled_state, current);
            const state_index = speciesVectorIndex(column, scratch.cell_count, inventory_count, species);
            const epsilon = gasJacobianProbeG(
                current[state_index],
                group_misc.absoluteToleranceForSpecies(options, species),
            );
            sampled_state[state_index] += epsilon;
            group_residual.residualAt(allocator, scratch, base, sampled_state, inputs, options.transport_iteration_fraction, target, sampled_residual) catch return false;
            for (0..dimension) |row| {
                const residual_index = speciesVectorIndex(row, scratch.cell_count, inventory_count, species);
                matrices[species * matrix_elements + row * dimension + column] =
                    (sampled_residual[residual_index] - residual[residual_index]) / epsilon;
            }
        }
    }
    var solved_newton_block = false;
    for (0..gas.species_count) |species| {
        const matrix = matrices[species * matrix_elements ..][0..matrix_elements];
        const rhs = right_hand_sides[species * dimension ..][0..dimension];
        for (0..dimension) |row| rhs[row] = -residual[speciesVectorIndex(row, scratch.cell_count, inventory_count, species)];
        if (numerics.solveDenseLinearSystem(matrix, rhs, dimension)) {
            solved_newton_block = true;
            for (rhs, 0..) |component, compact_index| direction[speciesVectorIndex(compact_index, scratch.cell_count, inventory_count, species)] = component;
        } else {
            // A bound-inactive phase can make one numerical block singular.
            // Do not let that block throttle the shared line search; preserve
            // every solvable Newton correction and leave this species for the
            // local Newton/Anderson/Picard path.
            for (0..dimension) |compact_index| {
                const index = speciesVectorIndex(compact_index, scratch.cell_count, inventory_count, species);
                direction[index] = 0;
            }
        }
    }
    return solved_newton_block;
}

pub fn filterIndependentSpeciesDirections(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    target: []f64,
    candidate_residual: []f64,
    candidate: []f64,
    direction: []f64,
) !bool {
    const inventory_count = scratch.gaseous_mass_g.len;
    var accepted_any = false;
    for (0..gas.species_count) |species| {
        const current_norm = try group_diagnostics.scaledSpeciesNorm(current, residual, options, inventory_count, species);
        var fraction: f64 = 1;
        var accepted = false;
        var search: u8 = 0;
        while (search < 20) : (search += 1) {
            @memcpy(candidate, current);
            var admissible = true;
            for (candidate, current, direction, 0..) |*next, value, component, index| {
                if ((index % inventory_count) % gas.species_count == species) {
                    next.* = value + fraction * component;
                    if (!std.math.isFinite(next.*) or next.* < 0) admissible = false;
                }
            }
            if (!admissible) {
                fraction *= 0.5;
                continue;
            }
            if (group_residual.residualAt(allocator, scratch, base, candidate, inputs, options.transport_iteration_fraction, target, candidate_residual)) |_| {
                if (try group_diagnostics.scaledSpeciesNorm(candidate, candidate_residual, options, inventory_count, species) < current_norm) {
                    accepted = true;
                    accepted_any = true;
                    break;
                }
            } else |_| {}
            fraction *= 0.5;
        }
        for (direction, 0..) |*component, index| {
            if ((index % inventory_count) % gas.species_count == species) component.* *= if (accepted) fraction else 0;
        }
    }
    return accepted_any;
}

fn speciesVectorIndex(compact_index: usize, cell_count: usize, inventory_count: usize, species: usize) usize {
    const phase = compact_index / cell_count;
    const cell = compact_index % cell_count;
    return phase * inventory_count + cell * gas.species_count + species;
}

pub fn krylovNewtonDirection(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    target: []f64,
    sampled_residual: []f64,
    direction: []f64,
    active_species: ?usize,
) !bool {
    const n = current.len;
    const restart = try krylovRestartLength(
        n,
        scratch.cell_count,
        active_species != null,
        options.krylov_restart_max,
    );
    if (restart == 0) return false;
    var workspace = try KrylovNewtonWorkspace.init(allocator, n, restart);
    defer workspace.deinit();
    return krylovNewtonDirectionWithWorkspace(
        allocator,
        scratch,
        base,
        current,
        residual,
        inputs,
        options,
        target,
        sampled_residual,
        direction,
        active_species,
        &workspace,
    );
}

pub fn krylovNewtonDirectionWithWorkspace(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    target: []f64,
    sampled_residual: []f64,
    direction: []f64,
    active_species: ?usize,
    workspace: *KrylovNewtonWorkspace,
) !bool {
    const n = current.len;
    const restart = try krylovRestartLength(
        n,
        scratch.cell_count,
        active_species != null,
        options.krylov_restart_max,
    );
    if (restart == 0 or n != workspace.unknown_count or
        restart > workspace.restart_capacity)
        return false;
    workspace.direction_calls +|= 1;
    const hessenberg_rows = try std.math.add(usize, restart, 1);
    const basis_count = try std.math.mul(usize, hessenberg_rows, n);
    const hessenberg_count = try std.math.mul(usize, hessenberg_rows, restart);
    const scalar_count = try krylovStorageCount(n, restart);
    const storage = workspace.storage[0..scalar_count];
    var cursor: usize = 0;
    const basis = storage[cursor..][0..basis_count];
    cursor += basis_count;
    const hessenberg = storage[cursor..][0..hessenberg_count];
    cursor += hessenberg_count;
    const cosine = storage[cursor..][0..restart];
    cursor += restart;
    const sine = storage[cursor..][0..restart];
    cursor += restart;
    const projected_rhs = storage[cursor..][0..hessenberg_rows];
    cursor += hessenberg_rows;
    const work = storage[cursor..][0..n];
    cursor += n;
    const sampled_state = storage[cursor..][0..n];
    cursor += n;
    const state_scale = storage[cursor..][0..n];
    cursor += n;
    const residual_scale = storage[cursor..][0..n];
    cursor += n;
    const local_preconditioner = storage[cursor..][0..n];
    cursor += n;
    const preconditioner_scratch = storage[cursor..][0..n];
    cursor += n;
    std.debug.assert(cursor == storage.len);
    @memset(hessenberg, 0);
    @memset(projected_rhs, 0);
    @memset(direction, 0);

    const inventory_count = scratch.gaseous_mass_g.len;
    for (current, state_scale, residual_scale, 0..) |value, *column_scale, *row_scale, index| {
        const coordinate_scales = krylovCoordinateScales(
            value,
            group_misc.absoluteToleranceForCoordinate(
                options,
                index,
                inventory_count,
            ),
            options.relative_tolerance,
        );
        column_scale.* = coordinate_scales.state_g;
        row_scale.* = coordinate_scales.residual_g;
        if (!std.math.isFinite(column_scale.*) or column_scale.* <= 0 or
            !std.math.isFinite(row_scale.*) or row_scale.* <= 0)
            return false;
    }
    const use_local_preconditioner = options.use_local_krylov_preconditioner and
        workspace.direction_calls <= 2 and
        prepareLocalKrylovPreconditioner(
            scratch,
            inputs,
            options.transport_iteration_fraction,
            local_preconditioner,
        );
    const first_basis = basis[0..n];
    for (residual, work, 0..) |value, *entry, index| {
        entry.* = if (active_species == null or
            (index % inventory_count) % gas.species_count == active_species.?)
            -(value / residual_scale[index])
        else
            0;
    }
    if (use_local_preconditioner and
        !applyLocalKrylovPreconditioner(
            work,
            residual_scale,
            state_scale,
            local_preconditioner,
            preconditioner_scratch,
            scratch,
            inputs,
            options.transport_iteration_fraction,
        )) return false;
    var beta_squared: f64 = 0;
    for (work, first_basis) |value, *entry| {
        beta_squared += value * value;
        entry.* = value;
    }
    const beta = @sqrt(beta_squared);
    if (!std.math.isFinite(beta) or beta <= std.math.floatEps(f64)) return false;
    for (first_basis) |*entry| entry.* /= beta;
    projected_rhs[0] = beta;

    var used: usize = 0;
    for (0..restart) |column| {
        const vector = basis[column * n ..][0..n];
        var epsilon = jacobianProbeMagnitude(1, beta);
        // The Krylov vector is expressed in dimensionless column-scaled
        // coordinates. Backtrack only the finite-difference probe enough to
        // remain on the nonnegative inventory manifold; the Newton direction
        // itself still receives the ordinary exact line search in the caller.
        for (current, state_scale, vector) |value, scale, component| {
            const scaled_component = scale * component;
            if (scaled_component < 0)
                epsilon = @min(epsilon, 0.5 * value / -scaled_component);
        }
        if (!std.math.isFinite(epsilon) or epsilon <= 0) return false;
        for (current, state_scale, vector, sampled_state) |value, scale, component, *sampled| {
            sampled.* = value + epsilon * scale * component;
            // A clipped finite-difference probe changes the Jacobian and can
            // manufacture mass at an active boundary. Abandon this Krylov
            // direction; a damped feasible Newton/Anderson path remains.
            if (!std.math.isFinite(sampled.*) or sampled.* < 0) return false;
        }
        group_residual.residualAt(allocator, scratch, base, sampled_state, inputs, options.transport_iteration_fraction, target, sampled_residual) catch return false;
        for (sampled_residual, residual, work, 0..) |sampled, original, *entry, index| {
            entry.* = if (active_species == null or (index % inventory_count) % gas.species_count == active_species.?)
                (sampled - original) / (epsilon * residual_scale[index])
            else
                0;
        }
        if (use_local_preconditioner and
            !applyLocalKrylovPreconditioner(
                work,
                residual_scale,
                state_scale,
                local_preconditioner,
                preconditioner_scratch,
                scratch,
                inputs,
                options.transport_iteration_fraction,
            )) return false;

        for (0..column + 1) |row| {
            const row_basis = basis[row * n ..][0..n];
            var projection: f64 = 0;
            for (work, row_basis) |value, basis_value| projection += value * basis_value;
            hessenberg[row * restart + column] = projection;
            for (work, row_basis) |*value, basis_value| value.* -= projection * basis_value;
        }
        var work_norm_squared: f64 = 0;
        for (work) |value| work_norm_squared += value * value;
        const work_norm = @sqrt(work_norm_squared);
        hessenberg[(column + 1) * restart + column] = work_norm;
        if (work_norm > std.math.floatEps(f64) and column + 1 < restart + 1) {
            const next_basis = basis[(column + 1) * n ..][0..n];
            for (work, next_basis) |value, *entry| entry.* = value / work_norm;
        }

        for (0..column) |row| {
            const upper_index = row * restart + column;
            const lower_index = (row + 1) * restart + column;
            const upper = hessenberg[upper_index];
            const lower = hessenberg[lower_index];
            hessenberg[upper_index] = cosine[row] * upper + sine[row] * lower;
            hessenberg[lower_index] = -sine[row] * upper + cosine[row] * lower;
        }
        const diagonal_index = column * restart + column;
        const subdiagonal_index = (column + 1) * restart + column;
        const diagonal = hessenberg[diagonal_index];
        const subdiagonal = hessenberg[subdiagonal_index];
        const magnitude = @sqrt(diagonal * diagonal + subdiagonal * subdiagonal);
        if (!std.math.isFinite(magnitude) or magnitude <= std.math.floatEps(f64)) break;
        cosine[column] = diagonal / magnitude;
        sine[column] = subdiagonal / magnitude;
        hessenberg[diagonal_index] = magnitude;
        hessenberg[subdiagonal_index] = 0;
        const rhs = projected_rhs[column];
        projected_rhs[column] = cosine[column] * rhs;
        projected_rhs[column + 1] = -sine[column] * rhs;
        used = column + 1;
        if (@abs(projected_rhs[column + 1]) <= options.krylov_relative_tolerance * beta) break;
    }
    if (used == 0) return false;
    workspace.iterations +|= @intCast(used);
    var row = used;
    while (row > 0) {
        row -= 1;
        var rhs = projected_rhs[row];
        for (row + 1..used) |column| rhs -= hessenberg[row * restart + column] * projected_rhs[column];
        const diagonal = hessenberg[row * restart + row];
        if (!std.math.isFinite(diagonal) or @abs(diagonal) <= std.math.floatEps(f64)) return false;
        projected_rhs[row] = rhs / diagonal;
    }
    for (0..used) |column| {
        const vector = basis[column * n ..][0..n];
        for (direction, vector) |*value, component| value.* += projected_rhs[column] * component;
    }
    for (direction, state_scale) |*value, scale| value.* *= scale;
    for (direction) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

fn prepareLocalKrylovPreconditioner(
    scratch: *const gas.State,
    inputs: group_misc.Inputs,
    transport_iteration_fraction: f64,
    coefficients: []f64,
) bool {
    const inventory_count = scratch.gaseous_mass_g.len;
    if (coefficients.len != 3 * inventory_count) return false;
    const gas_diagonal = coefficients[0..inventory_count];
    const nonband_phase_derivative = coefficients[inventory_count .. 2 * inventory_count];
    const band_phase_derivative = coefficients[2 * inventory_count .. 3 * inventory_count];
    @memset(gas_diagonal, -1);
    @memset(nonband_phase_derivative, 0);
    @memset(band_phase_derivative, 0);

    for (0..scratch.cell_count) |cell| {
        const start = cell * gas.species_count;
        const nonband_air_volume_m3 = if (inputs.nonband_air_volume_m3.len == 0)
            scratch.air_volume_m3[cell]
        else
            inputs.nonband_air_volume_m3[cell];
        const band_air_volume_m3 = if (inputs.band_air_volume_m3.len == 0)
            scratch.air_volume_m3[cell]
        else
            inputs.band_air_volume_m3[cell];
        for (0..gas.species_count) |species| {
            const index = start + species;
            const is_ammonia = species == @intFromEnum(gas.Species.ammonia);
            const primary_air_volume_m3 = if (is_ammonia)
                nonband_air_volume_m3
            else
                scratch.air_volume_m3[cell];
            const primary_water_volume_m3 = if (is_ammonia)
                inputs.water_volume_m3[cell] - inputs.band_water_volume_m3[cell]
            else
                inputs.water_volume_m3[cell];
            const nonband_derivative = phaseExchangeGasDerivative(
                primary_air_volume_m3,
                primary_water_volume_m3,
                inputs.mass_solubility_ratio[index],
                inputs.gas_water_exchange_rate_per_step[index],
            );
            const band_derivative = phaseExchangeGasDerivative(
                band_air_volume_m3,
                inputs.band_water_volume_m3[cell],
                inputs.mass_solubility_ratio[index],
                inputs.band_gas_water_exchange_rate_per_step[index],
            );
            if (!std.math.isFinite(nonband_derivative) or
                !std.math.isFinite(band_derivative)) return false;
            nonband_phase_derivative[index] = nonband_derivative;
            band_phase_derivative[index] = band_derivative;
            gas_diagonal[index] -= nonband_derivative + band_derivative;
        }
    }

    for (inputs.faces, 0..) |face, face_index| {
        // Must agree exactly with `group_residual.gaseousFace`: a face that
        // moves no gas in the residual contributes no Jacobian diagonal here.
        // Before the legacy `VOLPM > ZEROS2` floor of `trnsfr.f:5303-5306` was
        // applied, a face admitted at assembly on the dimensionless
        // `THETPM > THETX` test alone could still hold an air volume of order
        // 1e-35, making `conductance / air` ~1e12 or non-finite. The
        // finite-diagonal check below then abandoned the whole preconditioner
        // and returned `false` with no error surfaced anywhere.
        if (!group_residual.gaseousFace(scratch, inputs, face)) continue;
        const first_air_volume_m3 = scratch.air_volume_m3[face.first_cell];
        const second_air_volume_m3 = scratch.air_volume_m3[face.second_cell];
        for (0..gas.species_count) |species| {
            const conductance_m3 = inputs.face_conductance_m3_per_step[
                face_index * gas.species_count + species
            ] * transport_iteration_fraction;
            gas_diagonal[face.first_cell * gas.species_count + species] -=
                conductance_m3 / first_air_volume_m3;
            gas_diagonal[face.second_cell * gas.species_count + species] -=
                conductance_m3 / second_air_volume_m3;
        }
    }
    addBoundaryDiffusionDiagonal(
        gas_diagonal,
        scratch,
        inputs,
        inputs.atmospheric_boundaries,
        transport_iteration_fraction,
    );
    addBoundaryDiffusionDiagonal(
        gas_diagonal,
        scratch,
        inputs,
        inputs.subsurface_boundaries,
        transport_iteration_fraction,
    );
    for (gas_diagonal) |diagonal|
        if (!std.math.isFinite(diagonal) or diagonal >= -std.math.floatEps(f64))
            return false;
    return true;
}

fn phaseExchangeGasDerivative(
    air_volume_m3: f64,
    water_volume_m3: f64,
    mass_solubility_ratio: f64,
    exchange_rate_per_step: f64,
) f64 {
    const equivalent_water_volume_m3 = water_volume_m3 * mass_solubility_ratio;
    const total_equivalent_volume_m3 = equivalent_water_volume_m3 + air_volume_m3;
    if (total_equivalent_volume_m3 <= 0) return 0;
    return std.math.clamp(
        exchange_rate_per_step * equivalent_water_volume_m3 /
            total_equivalent_volume_m3,
        0,
        1,
    );
}

fn addBoundaryDiffusionDiagonal(
    gas_diagonal: []f64,
    scratch: *const gas.State,
    inputs: group_misc.Inputs,
    boundaries: []const atmosphere.Boundary,
    transport_iteration_fraction: f64,
) void {
    for (boundaries) |boundary| {
        const air_volume_m3 = scratch.air_volume_m3[boundary.cell_index];
        // `trnsfr.f:3436-3438` requires `VOLT > ZEROS2`, `VOLPM > ZEROS2` and
        // `VOLWM > ZEROS2` before the surface boundary exchange is evaluated
        // at all, so the same floor applies to its linearization.
        if (air_volume_m3 <= group_misc.minimumCarrierVolumeM3(inputs, boundary.cell_index)) continue;
        for (0..gas.species_count) |species| {
            const multiplier = gas.atmospheric_boundary_multiplier[species];
            const boundary_conductance_m3 = if (multiplier == 0)
                0
            else if (boundary.aerodynamic_conductance_m3_per_step >
                std.math.floatMax(f64) / multiplier)
                std.math.floatMax(f64)
            else
                boundary.aerodynamic_conductance_m3_per_step * multiplier;
            const effective_conductance_m3 = gas.seriesConductanceFromValidatedInputs(
                boundary.interior_conductance_m3_per_step[species],
                boundary_conductance_m3,
            );
            gas_diagonal[boundary.cell_index * gas.species_count + species] -=
                @min(
                    transport_iteration_fraction,
                    effective_conductance_m3 * transport_iteration_fraction /
                        air_volume_m3,
                );
        }
    }
}

fn applyLocalKrylovPreconditioner(
    vector: []f64,
    residual_scale: []const f64,
    state_scale: []const f64,
    coefficients: []const f64,
    physical_rhs: []f64,
    gas_state: *const gas.State,
    inputs: group_misc.Inputs,
    transport_iteration_fraction: f64,
) bool {
    if (vector.len % 3 != 0 or
        residual_scale.len != vector.len or
        state_scale.len != vector.len or
        coefficients.len != vector.len or
        physical_rhs.len != vector.len) return false;
    const inventory_count = vector.len / 3;
    const gas_diagonal = coefficients[0..inventory_count];
    const nonband_phase_derivative = coefficients[inventory_count .. 2 * inventory_count];
    const band_phase_derivative = coefficients[2 * inventory_count .. 3 * inventory_count];
    for (vector, residual_scale, physical_rhs) |value, scale, *rhs|
        rhs.* = value * scale;
    for (0..inventory_count) |index| {
        vector[index] = physical_rhs[index] / gas_diagonal[index];
    }
    for (0..2) |_| {
        @memcpy(
            vector[inventory_count .. 2 * inventory_count],
            physical_rhs[0..inventory_count],
        );
        for (inputs.faces, 0..) |face, face_index| {
            // Same `trnsfr.f:5303-5306` floor as the diagonal assembly and the
            // residual. An unresolvable air volume here amplified the Krylov
            // trial vector by `conductance / air`, of order 1e12 on real
            // production state, and the whole direction was then discarded.
            if (!group_residual.gaseousFace(gas_state, inputs, face)) continue;
            const first_air_volume_m3 = gas_state.air_volume_m3[face.first_cell];
            const second_air_volume_m3 = gas_state.air_volume_m3[face.second_cell];
            for (0..gas.species_count) |species| {
                const conductance_m3 = inputs.face_conductance_m3_per_step[
                    face_index * gas.species_count + species
                ] * transport_iteration_fraction;
                const first_index = face.first_cell * gas.species_count + species;
                const second_index = face.second_cell * gas.species_count + species;
                vector[inventory_count + first_index] -=
                    conductance_m3 / second_air_volume_m3 * vector[second_index];
                vector[inventory_count + second_index] -=
                    conductance_m3 / first_air_volume_m3 * vector[first_index];
            }
        }
        for (0..inventory_count) |index|
            vector[index] = vector[inventory_count + index] / gas_diagonal[index];
    }
    for (0..inventory_count) |index| {
        const gas_index = index;
        const dissolved_index = inventory_count + index;
        const band_index = 2 * inventory_count + index;
        const gas_change_g = vector[gas_index];
        const dissolved_change_g = nonband_phase_derivative[index] * gas_change_g -
            physical_rhs[dissolved_index];
        const band_change_g = band_phase_derivative[index] * gas_change_g -
            physical_rhs[band_index];
        vector[gas_index] = gas_change_g / state_scale[gas_index];
        vector[dissolved_index] = dissolved_change_g / state_scale[dissolved_index];
        vector[band_index] = band_change_g / state_scale[band_index];
        inline for (.{ gas_index, dissolved_index, band_index }) |coordinate|
            if (!std.math.isFinite(vector[coordinate])) return false;
    }
    return true;
}

fn krylovStorageCount(unknown_count: usize, restart: usize) !usize {
    const hessenberg_rows = try std.math.add(usize, restart, 1);
    const basis_count = try std.math.mul(usize, hessenberg_rows, unknown_count);
    const hessenberg_count = try std.math.mul(usize, hessenberg_rows, restart);
    const six_vectors_count = try std.math.mul(usize, 6, unknown_count);
    const two_rotations_count = try std.math.mul(usize, 2, restart);
    return std.math.add(
        usize,
        try std.math.add(usize, basis_count, hessenberg_count),
        try std.math.add(
            usize,
            six_vectors_count,
            try std.math.add(usize, two_rotations_count, hessenberg_rows),
        ),
    );
}

pub const KrylovCoordinateScales = struct {
    state_g: f64,
    residual_g: f64,
};

/// Uses the same species-specific tolerance scale as nonlinear acceptance.
/// Dividing that residual scale by the relative tolerance gives a matching
/// state coordinate without imposing an arbitrary one-gram floor on trace gas.
pub fn krylovCoordinateScales(
    state_g: f64,
    absolute_tolerance_g: f64,
    relative_tolerance: f64,
) KrylovCoordinateScales {
    const residual_g = absolute_tolerance_g +
        relative_tolerance * @abs(state_g);
    return .{
        .state_g = residual_g / relative_tolerance,
        .residual_g = residual_g,
    };
}

pub fn jacobianProbeMagnitude(state_scale: f64, residual_norm: f64) f64 {
    _ = residual_norm;
    return @sqrt(std.math.floatEps(f64)) * @max(1.0, state_scale);
}

pub fn krylovRestartLength(
    unknown_count: usize,
    cell_count: usize,
    species_local: bool,
    maximum_restart: usize,
) !usize {
    const active_dimension = if (species_local)
        try std.math.mul(usize, cell_count, 3)
    else
        unknown_count;
    return @min(
        @min(maximum_restart, group_misc.maximum_krylov_restart),
        @min(unknown_count, active_dimension),
    );
}

// Settles whether the near-zero air volume is reachable *during* a solve or is
// masked by face assembly. `face_assembly.zig:97,111` gates face CONSTRUCTION
// on the dimensionless `minimum_air_filled_porosity_m3_per_m3` (`THETX`), but
// `coupled_gas_solver_solve.zig` copies `state.air_volume_m3` into `scratch`
// once and receives `inputs.faces` as a fixed set, so a face admitted at
// assembly keeps its identity for the whole solve regardless of the volume
// behind it. It is not masked for a second reason: the dimensionless test says
// nothing about volume. The production Ottawa deck sets
// `subsurface_state,1e-3,...` (THETX = 1e-3) and
// `soil_geometry,...,1e-9` (minimum layer thickness 1e-9 m), so a layer can
// hold air_filled_porosity = 0.4 -- four hundred times over THETX -- over an
// air volume of 4e-10 * plan_area, which is 2500x BELOW
// `ZEROS2 = 1e-6 * plan_area`. Legacy `trnsfr.f:5305-5306` rejects exactly
// that face; the Zig tree tested only for positivity.
//
// This test builds a face set that is entirely healthy by the porosity test,
// then plants that volume directly in the state the solve actually reads.
fn preconditionerSurvivesSubFloorAirVolume(minimum_carrier_volume_m3: []const f64) !bool {
    var scratch = try gas.State.init(std.testing.allocator, 2);
    defer scratch.deinit();
    // Cell 0 is the unresolvable one; cell 1 is ordinary.
    scratch.air_volume_m3[0] = 1.43e-35;
    scratch.air_volume_m3[1] = 0.4;
    scratch.temperature_k[0] = 271.15;
    scratch.temperature_k[1] = 275.15;
    for (0..gas.species_count) |species| {
        scratch.gaseous_mass_g[species] = 0.25;
        scratch.gaseous_mass_g[gas.species_count + species] = 0.25;
    }

    const faces = [_]gas.Face{.{ .first_cell = 0, .second_cell = 1 }};
    const conductance = [_]f64{2.497e-3} ** gas.species_count;
    const inputs: group_misc.Inputs = .{
        .faces = &faces,
        .face_conductance_m3_per_step = &conductance,
        .atmospheric_boundaries = &.{},
        .water_volume_m3 = &.{ 0.2, 0.2 },
        .band_water_volume_m3 = &.{ 0, 0 },
        .mass_solubility_ratio = &([_]f64{1} ** (2 * gas.species_count)),
        .gas_water_exchange_rate_per_step = &([_]f64{0.1} ** (2 * gas.species_count)),
        .band_gas_water_exchange_rate_per_step = &([_]f64{0} ** (2 * gas.species_count)),
        .bubbling_enabled = &.{ false, false },
        .minimum_carrier_volume_m3 = minimum_carrier_volume_m3,
    };
    var coefficients = [_]f64{0} ** (3 * 2 * gas.species_count);
    const prepared = prepareLocalKrylovPreconditioner(&scratch, inputs, 1, &coefficients);
    if (!prepared) return false;
    for (coefficients[0 .. 2 * gas.species_count]) |diagonal| {
        // A finite diagonal is not enough: `conductance / 1.43e-35` is finite
        // but is a ~1e32 coefficient that destroys the preconditioner's
        // usefulness and the subsequent Krylov trial vector.
        if (!std.math.isFinite(diagonal) or @abs(diagonal) > 1.0e3) return false;
    }
    return true;
}

test "gas preconditioner rejects a mid-solve sub-ZEROS2 air volume" {
    // Without the floor the defect reproduces: the face is retained, the
    // diagonal picks up `conductance / 1.43e-35`, and the preconditioner is
    // unusable. This is the pre-fix behaviour, reproduced by supplying no
    // floor, and it is what `coupled_gas_solver_directions.zig:786` did.
    try std.testing.expect(!try preconditionerSurvivesSubFloorAirVolume(&.{}));

    // With the legacy `ZEROS2 = 1e-6 * DH * DV` for a 1 m2 cell the face is
    // absent, exactly as `trnsfr.f:5305-5306` requires, and the diagonal
    // retains only its own -1 plus the bounded phase-exchange derivatives.
    try std.testing.expect(try preconditionerSurvivesSubFloorAirVolume(&.{ 1e-6, 1e-6 }));
}
