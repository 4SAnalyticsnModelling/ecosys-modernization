//! `solver` declarations: conserved.
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
const scoped_conservation = @import("../../validation/scoped_conservation.zig");
const group_types = @import("solver_types.zig");

/// Evaluate the exact combined matrix+macropore liquid-water identity used by
/// both the Richards publication gate and its independent post-solve audit.
/// Standing storage contributes only to the floating-point representation
/// floor; the relative tolerance remains scaled to interval activity.
pub const LayerClosureWithProvenance = struct {
    closure: scoped_conservation.Closure,
    /// Source-certified representation bound used by this local gate. This is
    /// an a-priori floating-point bound, never the observed closure residual.
    producer_roundoff_allowance_m3: f64,
};

pub fn richardsLayerClosureWithProvenance(
    storage_before_m3: f64,
    storage_after_m3: f64,
    internal_input_m3: f64,
    internal_output_m3: f64,
    source_m3: f64,
    boundary_input_m3: f64,
    boundary_output_m3: f64,
    physical_absolute_tolerance_m3: f64,
    relative_tolerance: f64,
) !LayerClosureWithProvenance {
    const expected_gain_m3 = internal_input_m3 - internal_output_m3 +
        source_m3 + boundary_input_m3 - boundary_output_m3;
    const throughput_m3 = internal_input_m3 + internal_output_m3 +
        source_m3 + boundary_input_m3 + boundary_output_m3;
    const activity_scale_m3 = @max(
        @max(@abs(expected_gain_m3), throughput_m3),
        @max(@abs(storage_before_m3), @abs(storage_after_m3)),
    );
    const representation_floor_m3 =
        2048 * std.math.floatEps(f64) * activity_scale_m3;
    const closure = try scoped_conservation.evaluate(.{
        .storage_before = storage_before_m3,
        .storage_after = storage_after_m3,
        // A layer is the local scope, so every incident face is an external
        // transfer for this transaction. Preserve the two directions instead
        // of reducing them to one signed net: a wetting front can carry a
        // large inflow and outflow while changing storage only slightly, and
        // the relative conservation criterion is defined by that transported
        // activity rather than by the near-zero net.
        .external_inputs = internal_input_m3 + source_m3 + boundary_input_m3,
        .external_outputs = internal_output_m3 + boundary_output_m3,
    }, .{
        .absolute = physical_absolute_tolerance_m3,
        .relative = relative_tolerance,
        .upstream_arithmetic_roundoff_allowance = representation_floor_m3,
    });
    return .{
        .closure = closure,
        .producer_roundoff_allowance_m3 = representation_floor_m3,
    };
}

pub fn richardsLayerClosure(
    storage_before_m3: f64,
    storage_after_m3: f64,
    internal_input_m3: f64,
    internal_output_m3: f64,
    source_m3: f64,
    boundary_input_m3: f64,
    boundary_output_m3: f64,
    physical_absolute_tolerance_m3: f64,
    relative_tolerance: f64,
) !scoped_conservation.Closure {
    return (try richardsLayerClosureWithProvenance(
        storage_before_m3,
        storage_after_m3,
        internal_input_m3,
        internal_output_m3,
        source_m3,
        boundary_input_m3,
        boundary_output_m3,
        physical_absolute_tolerance_m3,
        relative_tolerance,
    )).closure;
}

test "Richards layer closure cannot hide equal and opposite local defects" {
    const positive = try richardsLayerClosure(0.014, 0.014, 0, 1.0e-10, 0, 0, 0, 0, 1.0e-9);
    const negative = try richardsLayerClosure(0.014, 0.014, 1.0e-10, 0, 0, 0, 0, 0, 1.0e-9);
    try std.testing.expect(!positive.accepted);
    try std.testing.expect(!negative.accepted);
    try std.testing.expectEqual(@as(f64, 0), positive.residual + negative.residual);
}

test "Richards layer relative closure retains opposing face throughput" {
    // Two 1000 m3 face transfers almost cancel in storage. Reducing them to
    // their signed net would give a 5e-7 m3 mismatch a normalization scale of
    // only 5e-7; the physical transaction carried 2000 m3 and the mismatch is
    // 0.25 ppb of that activity.
    const within = try richardsLayerClosure(
        1,
        1 + 5.0e-7,
        1000,
        1000,
        0,
        0,
        0,
        0,
        1.0e-9,
    );
    try std.testing.expect(within.accepted);
    try std.testing.expectApproxEqAbs(@as(f64, 2000), within.normalization_scale, 0);

    // The same scale remains an acceptance test, not an exemption: 2.5 ppb
    // of the transported amount is outside the configured one-ppb limit.
    const outside = try richardsLayerClosure(
        1,
        1 + 5.0e-6,
        1000,
        1000,
        0,
        0,
        0,
        0,
        1.0e-9,
    );
    try std.testing.expect(!outside.accepted);
    try std.testing.expect(outside.absolute > outside.acceptance_limit);
}

test "Richards layer closure preserves directional source and boundary provenance" {
    const closure = try richardsLayerClosure(
        4,
        7,
        7,
        5,
        3,
        11,
        13,
        0,
        1.0e-9,
    );
    try std.testing.expect(closure.accepted);
    try std.testing.expectEqual(@as(f64, 0), closure.residual);
    try std.testing.expectEqual(@as(f64, 39), closure.normalization_scale);
}

pub fn componentRoot(parent: []usize, cell: usize) usize {
    var root = cell;
    while (parent[root] != root) root = parent[root];
    var current = cell;
    while (parent[current] != current) {
        const next = parent[current];
        parent[current] = root;
        current = next;
    }
    return root;
}

pub fn unionComponents(parent: []usize, component_size: []usize, first: usize, second: usize) void {
    var first_root = componentRoot(parent, first);
    var second_root = componentRoot(parent, second);
    if (first_root == second_root) return;
    if (component_size[first_root] < component_size[second_root]) std.mem.swap(usize, &first_root, &second_root);
    parent[second_root] = first_root;
    component_size[first_root] += component_size[second_root];
}

pub fn releaseIndependentStorageCoordinates(parent: []usize, component_size: []usize) void {
    // The whole-step residual is target - trial, so every storage contributes
    // a -1 identity derivative. Unlike a flux-only Laplacian, this system has
    // no mass nullspace: solving every storage coordinate is nonsingular and
    // the conservative target equations themselves enforce water balance.
    for (0..parent.len) |cell| component_size[componentRoot(parent, cell)] = 1;
}

pub fn solveConservedNewtonSystem(full_jacobian: []const f64, residual: []const f64, expanded_delta: []f64, reduced_jacobian: []f64, reduced_right_hand_side: []f64, reduced_index_by_component: []usize, dimension: usize, cells: usize, micropore_parent: []usize, micropore_component_size: []const usize, macropore_parent: []usize, macropore_component_size: []const usize) bool {
    const excluded = std.math.maxInt(usize);
    @memset(reduced_index_by_component, excluded);
    var reduced_dimension: usize = 0;
    for (0..dimension) |full_index| {
        const domain_offset = if (full_index < cells) @as(usize, 0) else cells;
        const cell = full_index - domain_offset;
        const parent = if (domain_offset == 0) micropore_parent else macropore_parent;
        const component_size = if (domain_offset == 0) micropore_component_size else macropore_component_size;
        const root = componentRoot(parent, cell);
        if (component_size[root] > 1 and cell == root) continue;
        reduced_index_by_component[full_index] = reduced_dimension;
        reduced_dimension += 1;
    }
    if (reduced_dimension == 0) {
        @memset(expanded_delta, 0);
        return true;
    }
    for (0..dimension) |full_row| {
        const reduced_row = reduced_index_by_component[full_row];
        if (reduced_row == excluded) continue;
        reduced_right_hand_side[reduced_row] = -residual[full_row];
        for (0..dimension) |full_column| {
            const reduced_column = reduced_index_by_component[full_column];
            if (reduced_column == excluded) continue;
            const domain_offset = if (full_column < cells) @as(usize, 0) else cells;
            const cell = full_column - domain_offset;
            const parent = if (domain_offset == 0) micropore_parent else macropore_parent;
            const component_size = if (domain_offset == 0) micropore_component_size else macropore_component_size;
            const root = componentRoot(parent, cell);
            const anchor_column = domain_offset + root;
            const anchor_coefficient = if (component_size[root] > 1) full_jacobian[full_row * dimension + anchor_column] else 0;
            reduced_jacobian[reduced_row * reduced_dimension + reduced_column] = full_jacobian[full_row * dimension + full_column] - anchor_coefficient;
        }
    }
    if (!numerics.solveDenseLinearSystem(reduced_jacobian[0 .. reduced_dimension * reduced_dimension], reduced_right_hand_side[0..reduced_dimension], reduced_dimension)) return false;
    @memset(expanded_delta, 0);
    for (0..dimension) |full_index| {
        const reduced_index = reduced_index_by_component[full_index];
        if (reduced_index != excluded) expanded_delta[full_index] = reduced_right_hand_side[reduced_index];
    }
    for (0..2) |domain_index| {
        const domain_offset = if (domain_index == 0) @as(usize, 0) else cells;
        const parent = if (domain_offset == 0) micropore_parent else macropore_parent;
        const component_size = if (domain_offset == 0) micropore_component_size else macropore_component_size;
        for (0..cells) |cell| {
            const root = componentRoot(parent, cell);
            if (cell != root or component_size[root] <= 1) continue;
            var sum: f64 = 0;
            for (0..cells) |member| {
                if (componentRoot(parent, member) == root and member != root) sum += expanded_delta[domain_offset + member];
            }
            expanded_delta[domain_offset + root] = -sum;
        }
    }
    return true;
}

pub fn solveConservedTrustRegionSystem(full_jacobian: []const f64, residual: []const f64, state: []const f64, options: group_types.Options, expanded_delta: []f64, normal_matrix: []f64, reduced_right_hand_side: []f64, reduced_index_by_component: []usize, dimension: usize, cells: usize, micropore_parent: []usize, micropore_component_size: []const usize, macropore_parent: []usize, macropore_component_size: []const usize, damping: f64) bool {
    if (!std.math.isFinite(damping) or damping <= 0) return false;
    const excluded = std.math.maxInt(usize);
    @memset(reduced_index_by_component, excluded);
    var reduced_dimension: usize = 0;
    for (0..dimension) |full_index| {
        const domain_offset = if (full_index < cells) @as(usize, 0) else cells;
        const cell = full_index - domain_offset;
        const parent = if (domain_offset == 0) micropore_parent else macropore_parent;
        const component_size = if (domain_offset == 0) micropore_component_size else macropore_component_size;
        const root = componentRoot(parent, cell);
        if (component_size[root] > 1 and cell == root) continue;
        reduced_index_by_component[full_index] = reduced_dimension;
        reduced_dimension += 1;
    }
    if (reduced_dimension == 0) {
        @memset(expanded_delta, 0);
        return true;
    }
    @memset(normal_matrix[0 .. reduced_dimension * reduced_dimension], 0);
    @memset(reduced_right_hand_side[0..reduced_dimension], 0);
    for (0..dimension) |full_row| {
        const residual_scale = nonlinearResidualScale(state[full_row], options);
        const scaled_residual = residual[full_row] / residual_scale;
        for (0..dimension) |first_full_column| {
            const first_reduced_column = reduced_index_by_component[first_full_column];
            if (first_reduced_column == excluded) continue;
            const first_variable_scale = nonlinearVariableScale(
                state[first_full_column],
                options,
            );
            const first_coefficient = conservedCoordinateCoefficient(full_jacobian, full_row, first_full_column, dimension, cells, micropore_parent, micropore_component_size, macropore_parent, macropore_component_size) *
                first_variable_scale / residual_scale;
            reduced_right_hand_side[first_reduced_column] -= first_coefficient * scaled_residual;
            for (0..dimension) |second_full_column| {
                const second_reduced_column = reduced_index_by_component[second_full_column];
                if (second_reduced_column == excluded) continue;
                const second_variable_scale = nonlinearVariableScale(
                    state[second_full_column],
                    options,
                );
                const second_coefficient = conservedCoordinateCoefficient(full_jacobian, full_row, second_full_column, dimension, cells, micropore_parent, micropore_component_size, macropore_parent, macropore_component_size) *
                    second_variable_scale / residual_scale;
                normal_matrix[first_reduced_column * reduced_dimension + second_reduced_column] += first_coefficient * second_coefficient;
            }
        }
    }
    for (0..reduced_dimension) |index| {
        const diagonal_index = index * reduced_dimension + index;
        normal_matrix[diagonal_index] += damping * @max(1.0e-18, normal_matrix[diagonal_index]);
    }
    if (!numerics.solveDenseLinearSystem(normal_matrix[0 .. reduced_dimension * reduced_dimension], reduced_right_hand_side[0..reduced_dimension], reduced_dimension)) return false;
    @memset(expanded_delta, 0);
    for (0..dimension) |full_index| {
        const reduced_index = reduced_index_by_component[full_index];
        if (reduced_index != excluded)
            expanded_delta[full_index] = reduced_right_hand_side[reduced_index] *
                nonlinearVariableScale(state[full_index], options);
    }
    for (0..2) |domain_index| {
        const domain_offset = if (domain_index == 0) @as(usize, 0) else cells;
        const parent = if (domain_offset == 0) micropore_parent else macropore_parent;
        const component_size = if (domain_offset == 0) micropore_component_size else macropore_component_size;
        for (0..cells) |cell| {
            const root = componentRoot(parent, cell);
            if (cell != root or component_size[root] <= 1) continue;
            var sum: f64 = 0;
            for (0..cells) |member| {
                if (componentRoot(parent, member) == root and member != root)
                    sum += expanded_delta[domain_offset + member];
            }
            expanded_delta[domain_offset + root] = -sum;
        }
    }
    return true;
}

fn nonlinearResidualScale(state: f64, options: group_types.Options) f64 {
    return options.absolute_tolerance_m3 + options.relative_tolerance * @abs(state);
}

fn nonlinearVariableScale(state: f64, options: group_types.Options) f64 {
    return nonlinearResidualScale(state, options) / options.relative_tolerance;
}

test "Richards trust scaling matches the nonlinear trace-store tolerance" {
    const options: group_types.Options = .{
        .max_iterations = 2,
        .absolute_tolerance_m3 = 1.0e-13,
        .relative_tolerance = 1.0e-8,
    };
    const expected_residual_scale = 1.000001e-13;
    try std.testing.expectApproxEqAbs(
        expected_residual_scale,
        nonlinearResidualScale(1.0e-11, options),
        4 * std.math.floatEps(f64) * expected_residual_scale,
    );
    const expected_variable_scale = 1.000001e-5;
    try std.testing.expectApproxEqAbs(
        expected_variable_scale,
        nonlinearVariableScale(1.0e-11, options),
        4 * std.math.floatEps(f64) * expected_variable_scale,
    );
}

test "scaled Richards trust direction preserves connected-domain water" {
    const dimension: usize = 4;
    const cells: usize = 2;
    const jacobian = [_]f64{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    const residual = [_]f64{ 1.0e-8, -1.0e-8, 0, 0 };
    const state = [_]f64{ 1.0e-11, 0.5, 0.2, 0.3 };
    var micropore_parent = [_]usize{ 0, 0 };
    const micropore_component_size = [_]usize{ 2, 1 };
    var macropore_parent = [_]usize{ 0, 1 };
    const macropore_component_size = [_]usize{ 1, 1 };
    var delta: [dimension]f64 = undefined;
    var normal_matrix: [dimension * dimension]f64 = undefined;
    var right_hand_side: [dimension]f64 = undefined;
    var reduced_index: [dimension]usize = undefined;
    try std.testing.expect(solveConservedTrustRegionSystem(
        &jacobian,
        &residual,
        &state,
        .{
            .max_iterations = 2,
            .absolute_tolerance_m3 = 1.0e-13,
            .relative_tolerance = 1.0e-8,
        },
        &delta,
        &normal_matrix,
        &right_hand_side,
        &reduced_index,
        dimension,
        cells,
        &micropore_parent,
        &micropore_component_size,
        &macropore_parent,
        &macropore_component_size,
        1.0e-4,
    ));
    try std.testing.expectApproxEqAbs(@as(f64, 0), delta[0] + delta[1], 0);
}

fn solveProjectedTrustRegionSystem(jacobian: []const f64, residual: []const f64, delta: []f64, normal_matrix: []f64, right_hand_side: []f64, dimension: usize, cells: usize, micropore_parent: []usize, micropore_component_size: []const usize, macropore_parent: []usize, macropore_component_size: []const usize, damping: f64) bool {
    if (!std.math.isFinite(damping) or damping <= 0) return false;
    @memset(normal_matrix[0 .. dimension * dimension], 0);
    @memset(right_hand_side[0..dimension], 0);
    for (0..dimension) |row| for (0..dimension) |first_column| {
        const first = jacobian[row * dimension + first_column];
        right_hand_side[first_column] -= first * residual[row];
        for (0..dimension) |second_column| normal_matrix[first_column * dimension + second_column] += first * jacobian[row * dimension + second_column];
    };
    for (0..dimension) |index| {
        const diagonal = index * dimension + index;
        normal_matrix[diagonal] += damping * @max(1.0e-18, normal_matrix[diagonal]);
    }
    if (!numerics.solveDenseLinearSystem(normal_matrix[0 .. dimension * dimension], right_hand_side[0..dimension], dimension)) return false;
    @memcpy(delta, right_hand_side[0..dimension]);
    // Orthogonally project onto each numerically connected domain's
    // conservative subspace rather than eliminating an anchor coordinate.
    for (0..2) |domain_index| {
        const offset = if (domain_index == 0) @as(usize, 0) else cells;
        const parent = if (domain_index == 0) micropore_parent else macropore_parent;
        const component_size = if (domain_index == 0) micropore_component_size else macropore_component_size;
        for (0..cells) |root_candidate| {
            const root = componentRoot(parent, root_candidate);
            if (root != root_candidate or component_size[root] <= 1) continue;
            var sum: f64 = 0;
            for (0..cells) |member| {
                if (componentRoot(parent, member) == root) sum += delta[offset + member];
            }
            const mean = sum / @as(f64, @floatFromInt(component_size[root]));
            for (0..cells) |member| {
                if (componentRoot(parent, member) == root) delta[offset + member] -= mean;
            }
        }
    }
    for (delta) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

fn conservedCoordinateCoefficient(full_jacobian: []const f64, full_row: usize, full_column: usize, dimension: usize, cells: usize, micropore_parent: []usize, micropore_component_size: []const usize, macropore_parent: []usize, macropore_component_size: []const usize) f64 {
    const domain_offset = if (full_column < cells) @as(usize, 0) else cells;
    const cell = full_column - domain_offset;
    const parent = if (domain_offset == 0) micropore_parent else macropore_parent;
    const component_size = if (domain_offset == 0) micropore_component_size else macropore_component_size;
    const root = componentRoot(parent, cell);
    const anchor_coefficient = if (component_size[root] > 1) full_jacobian[full_row * dimension + domain_offset + root] else 0;
    return full_jacobian[full_row * dimension + full_column] - anchor_coefficient;
}

fn expandConservedDelta(expanded_delta: []f64, reduced_delta: []const f64, reduced_index_by_component: []const usize, dimension: usize, cells: usize, micropore_parent: []usize, micropore_component_size: []const usize, macropore_parent: []usize, macropore_component_size: []const usize) void {
    const excluded = std.math.maxInt(usize);
    @memset(expanded_delta, 0);
    for (0..dimension) |full_index| {
        const reduced_index = reduced_index_by_component[full_index];
        if (reduced_index != excluded) expanded_delta[full_index] = reduced_delta[reduced_index];
    }
    for (0..2) |domain_index| {
        const domain_offset = if (domain_index == 0) @as(usize, 0) else cells;
        const parent = if (domain_offset == 0) micropore_parent else macropore_parent;
        const component_size = if (domain_offset == 0) micropore_component_size else macropore_component_size;
        for (0..cells) |cell| {
            const root = componentRoot(parent, cell);
            if (cell != root or component_size[root] <= 1) continue;
            var sum: f64 = 0;
            for (0..cells) |member| {
                if (componentRoot(parent, member) == root and member != root) sum += expanded_delta[domain_offset + member];
            }
            expanded_delta[domain_offset + root] = -sum;
        }
    }
}
