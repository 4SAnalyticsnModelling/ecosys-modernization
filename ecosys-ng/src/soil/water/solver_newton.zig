//! `solver` declarations: newton.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const numerics = @import("../../core/numerics.zig");
const grid_module = @import("../../state/grid.zig");
const retention = @import("retention.zig");
const water_flux = @import("flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const water_boundary = @import("boundary.zig");
const boundary_topology = @import("../profile/boundary_topology.zig");
const group_residual = @import("solver_residual.zig");
const group_flux = @import("solver_flux.zig");
const group_types = @import("solver_types.zig");

pub const DifferenceStencil = enum { central, one_sided };

/// Storage coordinates are extensive m3 values, so a fixed absolute probe is
/// not scale invariant. Use the standard roundoff/truncation balance for the
/// stencil and retain 1e-6 m3 only as a coordinate *scale* near a dry bound.
pub fn finiteDifferenceProbeM3(storage_scale_m3: f64, stencil: DifferenceStencil) f64 {
    const relative_step = switch (stencil) {
        .central => std.math.cbrt(std.math.floatEps(f64)),
        .one_sided => std.math.sqrt(std.math.floatEps(f64)),
    };
    return relative_step * @max(1.0e-6, @abs(storage_scale_m3));
}

test "Richards finite-difference probe scales below the schedule-32 storage" {
    const storage_m3 = 2.630886951811673e-3;
    const central = finiteDifferenceProbeM3(storage_m3, .central);
    const one_sided = finiteDifferenceProbeM3(storage_m3, .one_sided);

    // The former fixed 1e-6 m3 central probe was about 380 ppm of this
    // layer's storage and left an O(h^2) residual floor. The scale-aware
    // probe is about 6 ppm and the one-sided fallback is finer still.
    try std.testing.expect(central < 2.0e-8);
    try std.testing.expect(1.0e-6 / central > 60);
    try std.testing.expect(one_sided < central);
}

test "Richards finite-difference probe is storage-scale covariant" {
    const small = finiteDifferenceProbeM3(2.5e-3, .central);
    const large = finiteDifferenceProbeM3(2.5, .central);
    try std.testing.expectApproxEqRel(@as(f64, 1000), large / small, 8 * std.math.floatEps(f64));

    // At a dry active bound the minimum is a scale floor, not a fixed 1e-6
    // perturbation in the physical coordinate.
    try std.testing.expectEqual(
        std.math.cbrt(std.math.floatEps(f64)) * 1.0e-6,
        finiteDifferenceProbeM3(0, .central),
    );
}

/// Resolves one dual-domain layer in well-scaled physical coordinates:
/// coordinate 0 changes total layer water through the matrix store, while
/// coordinate 1 transfers water conservatively from matrix to macropore.
/// The residual rows are total-water closure and macropore partition closure.
pub fn dualDomainTotalPartitionNewton(
    grid: *const grid_module.GridState,
    faces: []const group_types.Face,
    properties: group_types.Properties,
    options: group_types.Options,
    base: []const f64,
    current: []const f64,
    target: []f64,
    residual: []const f64,
    scratch: []f64,
    trial_micro_flux: []f64,
    trial_macro_flux: []f64,
    cell: usize,
    accepted_state: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    probe: []f64,
    probe_residual: []f64,
    jacobian_workspace: []f64,
    delta_workspace: []f64,
) !bool {
    const cells = grid.layer_count;
    const matrix_index = cell;
    const macropore_index = cells + cell;
    const matrix_capacity = try group_flux.physicalLiquidCapacityM3(
        grid.matrix_pore_capacity_m3[cell],
        grid.matrix_ice_water_m3[cell],
        properties.ice_density_megagrams_per_m3,
    );
    const macropore_capacity = try group_flux.physicalLiquidCapacityM3(
        grid.macropore_pore_capacity_m3[cell],
        grid.macropore_ice_water_m3[cell],
        properties.ice_density_megagrams_per_m3,
    );
    const matrix_water = current[matrix_index];
    const macropore_water = current[macropore_index];
    const total_residual =
        residual[matrix_index] + residual[macropore_index];
    const partition_residual = residual[macropore_index];
    const jacobian = jacobian_workspace[0..4];
    const delta = delta_workspace[0..2];

    const total_positive_room = @max(0.0, matrix_capacity - matrix_water);
    const total_negative_room = @max(0.0, matrix_water);
    const total_nominal = std.math.sqrt(std.math.floatEps(f64)) *
        @max(1.0, matrix_water + macropore_water);
    const total_step = @min(
        total_nominal,
        @min(0.5 * total_positive_room, 0.5 * total_negative_room),
    );
    if (total_step <= 1.0e-20) return false;
    @memcpy(probe, current);
    probe[matrix_index] += total_step;
    group_residual.residualAt(
        grid,
        faces,
        properties,
        base,
        probe,
        target,
        probe_residual,
        scratch,
        trial_micro_flux,
        trial_macro_flux,
    ) catch return false;
    @memcpy(candidate, current);
    candidate[matrix_index] -= total_step;
    group_residual.residualAt(
        grid,
        faces,
        properties,
        base,
        candidate,
        target,
        candidate_residual,
        scratch,
        trial_micro_flux,
        trial_macro_flux,
    ) catch return false;
    jacobian[0] =
        (probe_residual[matrix_index] + probe_residual[macropore_index] -
            candidate_residual[matrix_index] -
            candidate_residual[macropore_index]) / (2.0 * total_step);
    jacobian[2] =
        (probe_residual[macropore_index] -
            candidate_residual[macropore_index]) / (2.0 * total_step);

    const partition_positive_room = @min(
        @max(0.0, matrix_water),
        @max(0.0, macropore_capacity - macropore_water),
    );
    const partition_negative_room = @min(
        @max(0.0, macropore_water),
        @max(0.0, matrix_capacity - matrix_water),
    );
    const partition_nominal = std.math.sqrt(std.math.floatEps(f64)) *
        @max(1.0, macropore_water);
    const partition_step = @min(
        partition_nominal,
        @min(0.5 * partition_positive_room, 0.5 * partition_negative_room),
    );
    if (partition_step <= 1.0e-20) return false;
    @memcpy(probe, current);
    probe[matrix_index] -= partition_step;
    probe[macropore_index] += partition_step;
    group_residual.residualAt(
        grid,
        faces,
        properties,
        base,
        probe,
        target,
        probe_residual,
        scratch,
        trial_micro_flux,
        trial_macro_flux,
    ) catch return false;
    @memcpy(candidate, current);
    candidate[matrix_index] += partition_step;
    candidate[macropore_index] -= partition_step;
    group_residual.residualAt(
        grid,
        faces,
        properties,
        base,
        candidate,
        target,
        candidate_residual,
        scratch,
        trial_micro_flux,
        trial_macro_flux,
    ) catch return false;
    jacobian[1] =
        (probe_residual[matrix_index] + probe_residual[macropore_index] -
            candidate_residual[matrix_index] -
            candidate_residual[macropore_index]) / (2.0 * partition_step);
    jacobian[3] =
        (probe_residual[macropore_index] -
            candidate_residual[macropore_index]) / (2.0 * partition_step);
    delta[0] = -total_residual;
    delta[1] = -partition_residual;
    if (!numerics.solveDenseLinearSystem(jacobian, delta, 2)) return false;

    const current_norm = try group_residual.scaledNorm(current, residual, options);
    var fraction: f64 = 1;
    var line: u8 = 0;
    while (line < 24) : (line += 1) {
        @memcpy(candidate, current);
        candidate[matrix_index] =
            matrix_water + fraction * (delta[0] - delta[1]);
        candidate[macropore_index] =
            macropore_water + fraction * delta[1];
        if (candidate[matrix_index] >= 0 and
            candidate[matrix_index] <= matrix_capacity and
            candidate[macropore_index] >= 0 and
            candidate[macropore_index] <= macropore_capacity)
        {
            if (group_residual.residualAt(
                grid,
                faces,
                properties,
                base,
                candidate,
                target,
                candidate_residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
            )) |_| {
                const norm =
                    try group_residual.scaledNorm(candidate, candidate_residual, options);
                if (norm < current_norm) {
                    @memcpy(accepted_state, candidate);
                    return true;
                }
            } else |_| {}
        }
        fraction *= 0.5;
    }
    return false;
}

/// Newton correction for one complete pore domain. It avoids contaminating a
/// well-conditioned matrix Richards column with inactive, bound-constrained
/// macropore coordinates while evaluating acceptance against the full
/// dual-domain nonlinear residual.
pub fn domainBlockNewton(
    grid: *const grid_module.GridState,
    faces: []const group_types.Face,
    properties: group_types.Properties,
    options: group_types.Options,
    base: []const f64,
    current: []const f64,
    target: []f64,
    residual: []const f64,
    scratch: []f64,
    trial_micro_flux: []f64,
    trial_macro_flux: []f64,
    domain_offset: usize,
    fine_active_set_probe: bool,
    accepted_state: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    probe: []f64,
    probe_residual: []f64,
    jacobian_workspace: []f64,
    delta_workspace: []f64,
) !bool {
    const cells = grid.layer_count;
    if (domain_offset != 0 and domain_offset != cells)
        return error.InvalidSoilWaterDomainOffset;
    if (cells > delta_workspace.len) return false;
    const matrix_elements = std.math.mul(usize, cells, cells) catch return false;
    if (matrix_elements > jacobian_workspace.len) return false;
    const jacobian = jacobian_workspace[0..matrix_elements];
    const delta = delta_workspace[0..cells];
    for (0..cells) |column_cell| {
        const column = domain_offset + column_cell;
        const capacity = if (domain_offset == 0)
            try group_flux.physicalLiquidCapacityM3(grid.matrix_pore_capacity_m3[column_cell], grid.matrix_ice_water_m3[column_cell], properties.ice_density_megagrams_per_m3)
        else
            try group_flux.physicalLiquidCapacityM3(grid.macropore_pore_capacity_m3[column_cell], grid.macropore_ice_water_m3[column_cell], properties.ice_density_megagrams_per_m3);
        const upward_room = @max(0.0, capacity - current[column]);
        const downward_room = @max(0.0, current[column]);
        const nominal = finiteDifferenceProbeM3(
            current[column],
            if (fine_active_set_probe) .one_sided else .central,
        );
        const central_step =
            @min(nominal, @min(0.5 * upward_room, 0.5 * downward_room));
        if (central_step > 1.0e-20) {
            @memcpy(probe, current);
            probe[column] += central_step;
            group_residual.residualAt(
                grid,
                faces,
                properties,
                base,
                probe,
                target,
                probe_residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
            ) catch return false;
            @memcpy(candidate, current);
            candidate[column] -= central_step;
            group_residual.residualAt(
                grid,
                faces,
                properties,
                base,
                candidate,
                target,
                candidate_residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
            ) catch return false;
            for (0..cells) |row_cell|
                jacobian[row_cell * cells + column_cell] =
                    (probe_residual[domain_offset + row_cell] -
                        candidate_residual[domain_offset + row_cell]) /
                    (2.0 * central_step);
        } else {
            const step =
                if (upward_room >= downward_room)
                    @min(nominal, 0.5 * upward_room)
                else
                    -@min(nominal, 0.5 * downward_room);
            if (@abs(step) <= 1.0e-20) return false;
            @memcpy(probe, current);
            probe[column] += step;
            group_residual.residualAt(
                grid,
                faces,
                properties,
                base,
                probe,
                target,
                probe_residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
            ) catch return false;
            for (0..cells) |row_cell|
                jacobian[row_cell * cells + column_cell] =
                    (probe_residual[domain_offset + row_cell] -
                        residual[domain_offset + row_cell]) / step;
        }
    }
    for (0..cells) |row_cell|
        delta[row_cell] = -residual[domain_offset + row_cell];
    if (!numerics.solveDenseLinearSystem(jacobian, delta, cells)) return false;

    const current_norm = try group_residual.scaledNorm(current, residual, options);
    var fraction: f64 = 1;
    var line: u8 = 0;
    while (line < 20) : (line += 1) {
        @memcpy(candidate, current);
        var valid = true;
        for (0..cells) |cell| {
            const index = domain_offset + cell;
            const capacity = if (domain_offset == 0)
                try group_flux.physicalLiquidCapacityM3(grid.matrix_pore_capacity_m3[cell], grid.matrix_ice_water_m3[cell], properties.ice_density_megagrams_per_m3)
            else
                try group_flux.physicalLiquidCapacityM3(grid.macropore_pore_capacity_m3[cell], grid.macropore_ice_water_m3[cell], properties.ice_density_megagrams_per_m3);
            candidate[index] = current[index] + fraction * delta[cell];
            if (!std.math.isFinite(candidate[index]) or
                candidate[index] < 0 or candidate[index] > capacity)
                valid = false;
        }
        if (valid) {
            if (group_residual.residualAt(
                grid,
                faces,
                properties,
                base,
                candidate,
                target,
                candidate_residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
            )) |_| {
                const norm =
                    try group_residual.scaledNorm(candidate, candidate_residual, options);
                if (norm < current_norm) {
                    @memcpy(accepted_state, candidate);
                    return true;
                }
            } else |_| {}
        }
        fraction *= 0.5;
    }
    return false;
}

/// Resolves the Richards coupling across every face incident on one storage
/// cell as a single bounded Newton block. This is the spatial counterpart of
/// `dualDomainCellNewton`: scalar coordinates cannot reliably cross a
/// donor/receiver active-set change because changing the centre storage also
/// changes both neighboring residual equations.
pub fn spatialDomainCellNewton(
    grid: *const grid_module.GridState,
    faces: []const group_types.Face,
    properties: group_types.Properties,
    base: []const f64,
    current: []f64,
    target: []f64,
    residual: []f64,
    scratch: []f64,
    trial_micro_flux: []f64,
    trial_macro_flux: []f64,
    component: usize,
    candidate: []f64,
    candidate_residual: []f64,
    probe: []f64,
    probe_residual: []f64,
    indices_workspace: []usize,
    jacobian_workspace: []f64,
    right_hand_side_workspace: []f64,
    options: group_types.Options,
    include_dual_domain: bool,
) !bool {
    const cells = grid.layer_count;
    const domain_offset = if (component < cells) @as(usize, 0) else cells;
    const cell = component - domain_offset;
    var local_count: usize = 1;
    indices_workspace[0] = component;
    for (faces) |face| {
        const neighbor =
            if (face.source_cell == cell)
                face.destination_cell
            else if (face.destination_cell == cell)
                face.source_cell
            else
                continue;
        const neighbor_component = domain_offset + neighbor;
        var duplicate = false;
        for (indices_workspace[0..local_count]) |index|
            if (index == neighbor_component) {
                duplicate = true;
                break;
            };
        if (!duplicate) {
            indices_workspace[local_count] = neighbor_component;
            local_count += 1;
        }
    }
    // Close one additional face ring so changing an immediate neighbor does
    // not leave its outward Richards face outside the Newton block.
    const first_ring_count = local_count;
    for (faces) |face| {
        const source_component = domain_offset + face.source_cell;
        const destination_component = domain_offset + face.destination_cell;
        var source_in_first_ring = false;
        var destination_in_first_ring = false;
        for (indices_workspace[0..first_ring_count]) |index| {
            source_in_first_ring = source_in_first_ring or index == source_component;
            destination_in_first_ring =
                destination_in_first_ring or index == destination_component;
        }
        const outward_component =
            if (source_in_first_ring and !destination_in_first_ring)
                destination_component
            else if (destination_in_first_ring and !source_in_first_ring)
                source_component
            else
                continue;
        var duplicate = false;
        for (indices_workspace[0..local_count]) |index|
            if (index == outward_component) {
                duplicate = true;
                break;
            };
        if (!duplicate) {
            indices_workspace[local_count] = outward_component;
            local_count += 1;
        }
    }
    if (include_dual_domain and
        properties.dual_domain_exchange_enabled.len != 0)
    {
        const spatial_count = local_count;
        for (indices_workspace[0..spatial_count]) |spatial_index| {
            const spatial_cell = spatial_index - domain_offset;
            if (!properties.dual_domain_exchange_enabled[spatial_cell] or
                grid.macropore_pore_capacity_m3[spatial_cell] <= 0)
                continue;
            indices_workspace[local_count] =
                if (domain_offset == 0)
                    cells + spatial_cell
                else
                    spatial_cell;
            local_count += 1;
        }
    }
    if (local_count < 2) return false;

    if (local_count > right_hand_side_workspace.len) return false;
    const matrix_elements = std.math.mul(usize, local_count, local_count) catch return false;
    if (matrix_elements > jacobian_workspace.len) return false;

    const indices = indices_workspace[0..local_count];
    const local_jacobian = jacobian_workspace[0..matrix_elements];
    const local_delta = right_hand_side_workspace[0..local_count];
    for (indices, 0..) |column_index, column| {
        const column_is_macro = column_index >= cells;
        const column_cell =
            if (column_is_macro) column_index - cells else column_index;
        const capacity = if (!column_is_macro)
            try group_flux.physicalLiquidCapacityM3(grid.matrix_pore_capacity_m3[column_cell], grid.matrix_ice_water_m3[column_cell], properties.ice_density_megagrams_per_m3)
        else
            try group_flux.physicalLiquidCapacityM3(grid.macropore_pore_capacity_m3[column_cell], grid.macropore_ice_water_m3[column_cell], properties.ice_density_megagrams_per_m3);
        const upward_room = @max(0.0, capacity - current[column_index]);
        const downward_room = @max(0.0, current[column_index]);
        const nominal = finiteDifferenceProbeM3(current[column_index], .central);
        const central_step = @min(
            nominal,
            @min(0.5 * upward_room, 0.5 * downward_room),
        );
        if (central_step > 1.0e-20) {
            @memcpy(probe, current);
            probe[column_index] += central_step;
            group_residual.residualAt(
                grid,
                faces,
                properties,
                base,
                probe,
                target,
                probe_residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
            ) catch return false;
            @memcpy(candidate, current);
            candidate[column_index] -= central_step;
            group_residual.residualAt(
                grid,
                faces,
                properties,
                base,
                candidate,
                target,
                candidate_residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
            ) catch return false;
            for (indices, 0..) |row_index, row|
                local_jacobian[row * local_count + column] =
                    (probe_residual[row_index] -
                        candidate_residual[row_index]) / (2.0 * central_step);
            continue;
        }
        const step =
            if (upward_room >= downward_room)
                @min(nominal, 0.5 * upward_room)
            else
                -@min(nominal, 0.5 * downward_room);
        if (@abs(step) <= 1.0e-20) return false;
        @memcpy(probe, current);
        probe[column_index] += step;
        group_residual.residualAt(
            grid,
            faces,
            properties,
            base,
            probe,
            target,
            probe_residual,
            scratch,
            trial_micro_flux,
            trial_macro_flux,
        ) catch return false;
        for (indices, 0..) |row_index, row|
            local_jacobian[row * local_count + column] =
                (probe_residual[row_index] - residual[row_index]) / step;
    }
    for (indices, 0..) |index, row|
        local_delta[row] = -residual[index];
    if (!numerics.solveDenseLinearSystem(local_jacobian, local_delta, local_count))
        return false;

    const current_norm = try group_residual.scaledNorm(current, residual, options);
    var fraction: f64 = 1;
    var line: u8 = 0;
    while (line < 20) : (line += 1) {
        @memcpy(candidate, current);
        var valid = true;
        for (indices, local_delta) |index, delta| {
            const index_is_macro = index >= cells;
            const index_cell = if (index_is_macro) index - cells else index;
            const capacity = if (!index_is_macro)
                try group_flux.physicalLiquidCapacityM3(grid.matrix_pore_capacity_m3[index_cell], grid.matrix_ice_water_m3[index_cell], properties.ice_density_megagrams_per_m3)
            else
                try group_flux.physicalLiquidCapacityM3(grid.macropore_pore_capacity_m3[index_cell], grid.macropore_ice_water_m3[index_cell], properties.ice_density_megagrams_per_m3);
            candidate[index] = current[index] + fraction * delta;
            if (!std.math.isFinite(candidate[index]) or
                candidate[index] < 0 or candidate[index] > capacity)
                valid = false;
        }
        if (valid) {
            if (group_residual.residualAt(
                grid,
                faces,
                properties,
                base,
                candidate,
                target,
                candidate_residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
            )) |_| {
                const global_norm = try group_residual.scaledNorm(candidate, candidate_residual, options);
                if (global_norm < current_norm) {
                    @memcpy(current, candidate);
                    @memcpy(residual, candidate_residual);
                    return true;
                }
            } else |_| {}
        }
        fraction *= 0.5;
    }
    return false;
}

pub fn dualDomainCellNewton(
    grid: *const grid_module.GridState,
    faces: []const group_types.Face,
    properties: group_types.Properties,
    base: []const f64,
    current: []f64,
    target: []f64,
    residual: []f64,
    scratch: []f64,
    trial_micro_flux: []f64,
    trial_macro_flux: []f64,
    cell: usize,
    candidate: []f64,
    candidate_residual: []f64,
    probe: []f64,
    probe_residual: []f64,
) !bool {
    const cells = grid.layer_count;
    const indices = [2]usize{ cell, cells + cell };
    var local_jacobian: [4]f64 = undefined;
    for (indices, 0..) |column_index, column| {
        const capacity = if (column == 0)
            try group_flux.physicalLiquidCapacityM3(grid.matrix_pore_capacity_m3[cell], grid.matrix_ice_water_m3[cell], properties.ice_density_megagrams_per_m3)
        else
            try group_flux.physicalLiquidCapacityM3(grid.macropore_pore_capacity_m3[cell], grid.macropore_ice_water_m3[cell], properties.ice_density_megagrams_per_m3);
        const upward_room = @max(0.0, capacity - current[column_index]);
        const downward_room = @max(0.0, current[column_index]);
        const nominal = finiteDifferenceProbeM3(current[column_index], .central);
        const central_step = @min(
            nominal,
            @min(0.5 * upward_room, 0.5 * downward_room),
        );
        if (central_step > 1.0e-20) {
            @memcpy(probe, current);
            probe[column_index] += central_step;
            group_residual.residualAt(
                grid,
                faces,
                properties,
                base,
                probe,
                target,
                probe_residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
            ) catch return false;
            @memcpy(candidate, current);
            candidate[column_index] -= central_step;
            group_residual.residualAt(
                grid,
                faces,
                properties,
                base,
                candidate,
                target,
                candidate_residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
            ) catch return false;
            for (indices, 0..) |row_index, row|
                local_jacobian[row * 2 + column] =
                    (probe_residual[row_index] -
                        candidate_residual[row_index]) / (2 * central_step);
            continue;
        }
        const step =
            if (upward_room >= downward_room)
                @min(nominal, 0.5 * upward_room)
            else
                -@min(nominal, 0.5 * downward_room);
        if (@abs(step) <= 1.0e-20) return false;
        @memcpy(probe, current);
        probe[column_index] += step;
        group_residual.residualAt(
            grid,
            faces,
            properties,
            base,
            probe,
            target,
            probe_residual,
            scratch,
            trial_micro_flux,
            trial_macro_flux,
        ) catch return false;
        for (indices, 0..) |row_index, row|
            local_jacobian[row * 2 + column] =
                (probe_residual[row_index] - residual[row_index]) / step;
    }
    var local_delta = [2]f64{
        -residual[indices[0]],
        -residual[indices[1]],
    };
    if (!numerics.solveDenseLinearSystem(&local_jacobian, &local_delta, 2))
        return false;
    const current_pair_norm =
        @max(@abs(residual[indices[0]]), @abs(residual[indices[1]]));
    var fraction: f64 = 1;
    var line: u8 = 0;
    while (line < 20) : (line += 1) {
        @memcpy(candidate, current);
        var valid = true;
        for (indices, local_delta, 0..) |index, delta, domain| {
            const capacity = if (domain == 0)
                try group_flux.physicalLiquidCapacityM3(grid.matrix_pore_capacity_m3[cell], grid.matrix_ice_water_m3[cell], properties.ice_density_megagrams_per_m3)
            else
                try group_flux.physicalLiquidCapacityM3(grid.macropore_pore_capacity_m3[cell], grid.macropore_ice_water_m3[cell], properties.ice_density_megagrams_per_m3);
            candidate[index] = current[index] + fraction * delta;
            if (!std.math.isFinite(candidate[index]) or
                candidate[index] < 0 or candidate[index] > capacity)
                valid = false;
        }
        if (valid) {
            if (group_residual.residualAt(
                grid,
                faces,
                properties,
                base,
                candidate,
                target,
                candidate_residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
            )) |_| {
                const pair_norm = @max(
                    @abs(candidate_residual[indices[0]]),
                    @abs(candidate_residual[indices[1]]),
                );
                if (pair_norm < current_pair_norm) {
                    @memcpy(current, candidate);
                    @memcpy(residual, candidate_residual);
                    return true;
                }
            } else |_| {}
        }
        fraction *= 0.5;
    }
    return false;
}
