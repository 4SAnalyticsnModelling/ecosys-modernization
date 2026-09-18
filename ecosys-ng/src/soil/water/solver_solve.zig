//! `solver` declarations: solve.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const numerics = @import("../../core/numerics.zig");
const grid_module = @import("../../state/grid.zig");
const retention = @import("retention.zig");
const kirchhoff = @import("kirchhoff.zig");
const richards_face_cache = @import("richards_face_cache.zig");
const water_flux = @import("flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const water_boundary = @import("boundary.zig");
const boundary_topology = @import("../profile/boundary_topology.zig");
const group_conserved = @import("solver_conserved.zig");
const group_flux = @import("solver_flux.zig");
const group_hydraulics = @import("solver_hydraulics.zig");
const group_newton = @import("solver_newton.zig");
const group_residual = @import("solver_residual.zig");
const group_types = @import("solver_types.zig");

/// Conservative whole-hour dual-domain Richards solve. Every face evaluates
/// one common nonlinear trial state, while an order-independent conservative
/// target accumulator enforces aggregate donor and receiver bounds. The
/// Newton/Anderson hybrid replaces repetition of the full sub-hour model. Grid
/// storage and output fluxes are state_updateted only after convergence.
pub fn solve(
    allocator: std.mem.Allocator,
    grid: *grid_module.GridState,
    faces: []const group_types.Face,
    properties: group_types.Properties,
    micropore_face_flux_m3_per_step: []f64,
    macropore_face_flux_m3_per_step: []f64,
    options: group_types.Options,
) !group_types.Result {
    return solveControlled(
        allocator,
        grid,
        faces,
        properties,
        micropore_face_flux_m3_per_step,
        macropore_face_flux_m3_per_step,
        options,
        .{},
    );
}

const MethodEvent = enum {
    newton_attempt,
    anderson_accept,
    anderson_rejected_no_retry,
    publish,
};

const MethodTrace = struct {
    events: [16]MethodEvent = undefined,
    len: usize = 0,

    fn record(self: *MethodTrace, event: MethodEvent) void {
        if (self.len < self.events.len) {
            self.events[self.len] = event;
            self.len += 1;
        }
    }
};

const TestControl = struct {
    forced_initial_newton_failures: u16 = 0,
    trace: ?*MethodTrace = null,
    dense_jacobian_assemblies: ?*u16 = null,
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

/// Uses only accepted Newton merits to determine whether the measured
/// logarithmic contraction can reach the unchanged `norm <= 1` acceptance
/// gate before the hard ceiling. Recovery is considered only while an
/// Anderson update and its mandatory Newton retry still fit.
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

const DenseJacobianPhase = struct {
    grid: *grid_module.GridState,
    faces: []const group_types.Face,
    active_properties: group_types.Properties,
    properties: group_types.Properties,
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    target: []f64,
    probe: []f64,
    probe_residual: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    scratch: []f64,
    trial_micro_flux: []f64,
    trial_macro_flux: []f64,
    jacobian: []f64,
    micropore_parent: []usize,
    macropore_parent: []usize,
    micropore_component_size: []usize,
    macropore_component_size: []usize,
    cells: usize,
    components: usize,
};

const DenseProbeMode = enum {
    identity,
    central,
    one_sided,
};

fn colorDenseJacobianCells(
    faces: []const group_types.Face,
    cells: usize,
    adjacency: []f64,
    colors: []usize,
) ?usize {
    if (cells == 0 or colors.len < cells or adjacency.len < cells * cells)
        return null;
    @memset(adjacency[0 .. cells * cells], 0);
    for (0..cells) |cell| adjacency[cell * cells + cell] = 1;
    for (faces) |face| {
        if (!face.active) continue;
        adjacency[face.source_cell * cells + face.destination_cell] = 1;
        adjacency[face.destination_cell * cells + face.source_cell] = 1;
    }

    var color_count: usize = 0;
    for (0..cells) |cell| {
        var forbidden = [_]bool{false} ** (group_types.maximum_dense_newton_components / 2);
        for (0..cell) |prior| {
            var shares_row = false;
            for (0..cells) |row| {
                if (adjacency[row * cells + cell] != 0 and
                    adjacency[row * cells + prior] != 0)
                {
                    shares_row = true;
                    break;
                }
            }
            if (shares_row) forbidden[colors[prior]] = true;
        }
        var color: usize = 0;
        while (color < color_count and forbidden[color]) : (color += 1) {}
        colors[cell] = color;
        if (color == color_count) color_count += 1;
    }
    return color_count;
}

fn denseColumnAffectsRow(
    faces: []const group_types.Face,
    column_cell: usize,
    row_cell: usize,
) bool {
    if (column_cell == row_cell) return true;
    for (faces) |face| {
        if (!face.active) continue;
        if ((face.source_cell == column_cell and face.destination_cell == row_cell) or
            (face.destination_cell == column_cell and face.source_cell == row_cell))
            return true;
    }
    return false;
}

fn coloredDenseProbeSafe(phase: DenseJacobianPhase) bool {
    if (phase.active_properties.richards_face_flux_cache) |cache|
        return !cache.assembled_target_limit_observed;
    for (phase.faces) |face| if (face.active) return false;
    return true;
}

fn tryAssembleColoredDenseJacobian(phase: DenseJacobianPhase) !bool {
    if (phase.components != 2 * phase.cells or
        phase.components > group_types.maximum_dense_newton_components or
        !coloredDenseProbeSafe(phase))
        return false;

    const color_count = colorDenseJacobianCells(
        phase.faces,
        phase.cells,
        phase.jacobian,
        phase.micropore_parent,
    ) orelse return false;
    var modes: [group_types.maximum_dense_newton_components]DenseProbeMode = undefined;
    var perturbations: [group_types.maximum_dense_newton_components]f64 = undefined;
    @memset(phase.jacobian[0 .. phase.components * phase.components], 0);

    for (0..phase.components) |column| {
        const column_cell = if (column < phase.cells)
            column
        else
            column - phase.cells;
        const pore_capacity = if (column < phase.cells)
            phase.grid.matrix_pore_capacity_m3[column_cell]
        else
            phase.grid.macropore_pore_capacity_m3[column_cell];
        const ice_volume = if (column < phase.cells)
            phase.grid.matrix_ice_water_m3[column_cell]
        else
            phase.grid.macropore_ice_water_m3[column_cell];
        const available_capacity = try group_flux.physicalLiquidCapacityM3(
            pore_capacity,
            ice_volume,
            phase.properties.ice_density_megagrams_per_m3,
        );
        if (available_capacity <= 1.0e-18) {
            modes[column] = .identity;
            perturbations[column] = 0;
            phase.jacobian[column * phase.components + column] = 1;
            continue;
        }
        const central_probe_m3 = group_newton.finiteDifferenceProbeM3(
            phase.current[column],
            .central,
        );
        const upward_room = @max(
            0.0,
            available_capacity - phase.current[column],
        );
        const downward_room = @max(0.0, phase.current[column]);
        const central_perturbation = @min(
            central_probe_m3,
            @min(0.5 * upward_room, 0.5 * downward_room),
        );
        if (central_perturbation > 1.0e-20) {
            modes[column] = .central;
            perturbations[column] = central_perturbation;
            continue;
        }
        const one_sided_probe_m3 = group_newton.finiteDifferenceProbeM3(
            phase.current[column],
            .one_sided,
        );
        const perturbation = @min(
            one_sided_probe_m3,
            0.5 * @max(upward_room, downward_room),
        );
        if (perturbation <= 1.0e-20) {
            modes[column] = .identity;
            perturbations[column] = 0;
            phase.jacobian[column * phase.components + column] = 1;
            continue;
        }
        modes[column] = .one_sided;
        perturbations[column] = if (upward_room >= downward_room)
            perturbation
        else
            -perturbation;
    }

    const group_count = 2 * color_count;
    for (0..group_count) |group| {
        @memcpy(phase.probe, phase.current);
        var has_central = false;
        for (0..phase.components) |column| {
            const column_cell = if (column < phase.cells)
                column
            else
                column - phase.cells;
            const domain: usize = if (column < phase.cells) 0 else 1;
            if (2 * phase.micropore_parent[column_cell] + domain != group or
                modes[column] != .central)
                continue;
            phase.probe[column] += perturbations[column];
            has_central = true;
        }
        if (has_central) {
            group_residual.residualAt(
                phase.grid,
                phase.faces,
                phase.active_properties,
                phase.base,
                phase.probe,
                phase.target,
                phase.probe_residual,
                phase.scratch,
                phase.trial_micro_flux,
                phase.trial_macro_flux,
            ) catch return false;
            if (!coloredDenseProbeSafe(phase)) return false;

            @memcpy(phase.candidate, phase.current);
            for (0..phase.components) |column| {
                const column_cell = if (column < phase.cells)
                    column
                else
                    column - phase.cells;
                const domain: usize = if (column < phase.cells) 0 else 1;
                if (2 * phase.micropore_parent[column_cell] + domain == group and
                    modes[column] == .central)
                    phase.candidate[column] -= perturbations[column];
            }
            group_residual.residualAt(
                phase.grid,
                phase.faces,
                phase.active_properties,
                phase.base,
                phase.candidate,
                phase.target,
                phase.candidate_residual,
                phase.scratch,
                phase.trial_micro_flux,
                phase.trial_macro_flux,
            ) catch return false;
            if (!coloredDenseProbeSafe(phase)) return false;

            for (0..phase.components) |column| {
                const column_cell = if (column < phase.cells)
                    column
                else
                    column - phase.cells;
                const domain: usize = if (column < phase.cells) 0 else 1;
                if (2 * phase.micropore_parent[column_cell] + domain != group or
                    modes[column] != .central)
                    continue;
                for (0..phase.components) |row| {
                    const row_cell = if (row < phase.cells) row else row - phase.cells;
                    if (denseColumnAffectsRow(phase.faces, column_cell, row_cell)) {
                        phase.jacobian[row * phase.components + column] =
                            (phase.probe_residual[row] -
                                phase.candidate_residual[row]) /
                            (2.0 * perturbations[column]);
                    }
                }
            }
        }

        @memcpy(phase.probe, phase.current);
        var has_one_sided = false;
        for (0..phase.components) |column| {
            const column_cell = if (column < phase.cells)
                column
            else
                column - phase.cells;
            const domain: usize = if (column < phase.cells) 0 else 1;
            if (2 * phase.micropore_parent[column_cell] + domain != group or
                modes[column] != .one_sided)
                continue;
            phase.probe[column] += perturbations[column];
            has_one_sided = true;
        }
        if (has_one_sided) {
            group_residual.residualAt(
                phase.grid,
                phase.faces,
                phase.active_properties,
                phase.base,
                phase.probe,
                phase.target,
                phase.probe_residual,
                phase.scratch,
                phase.trial_micro_flux,
                phase.trial_macro_flux,
            ) catch return false;
            if (!coloredDenseProbeSafe(phase)) return false;

            for (0..phase.components) |column| {
                const column_cell = if (column < phase.cells)
                    column
                else
                    column - phase.cells;
                const domain: usize = if (column < phase.cells) 0 else 1;
                if (2 * phase.micropore_parent[column_cell] + domain != group or
                    modes[column] != .one_sided)
                    continue;
                for (0..phase.components) |row| {
                    const row_cell = if (row < phase.cells) row else row - phase.cells;
                    if (denseColumnAffectsRow(phase.faces, column_cell, row_cell)) {
                        phase.jacobian[row * phase.components + column] =
                            (phase.probe_residual[row] - phase.residual[row]) /
                            perturbations[column];
                    }
                }
            }
        }
    }
    return true;
}

/// Builds the dense Richards derivative and its exact conservative coordinate
/// topology. This is deliberately a noinline phase: the residual probes and
/// source-ordered arithmetic remain unchanged, while LLVM need not optimize
/// their large control-flow graph together with Newton/Anderson arbitration.
noinline fn assembleDenseConservedJacobian(phase: DenseJacobianPhase) !bool {
    var dense_jacobian_valid = true;
    if (!try tryAssembleColoredDenseJacobian(phase)) for (0..phase.components) |column| {
        const column_cell = if (column < phase.cells)
            column
        else
            column - phase.cells;
        const pore_capacity = if (column < phase.cells)
            phase.grid.matrix_pore_capacity_m3[column_cell]
        else
            phase.grid.macropore_pore_capacity_m3[column_cell];
        const ice_volume = if (column < phase.cells)
            phase.grid.matrix_ice_water_m3[column_cell]
        else
            phase.grid.macropore_ice_water_m3[column_cell];
        const available_capacity = try group_flux.physicalLiquidCapacityM3(
            pore_capacity,
            ice_volume,
            phase.properties.ice_density_megagrams_per_m3,
        );
        if (available_capacity <= 1.0e-18) {
            for (0..phase.components) |row|
                phase.jacobian[row * phase.components + column] =
                    if (row == column) 1 else 0;
            continue;
        }
        const central_probe_m3 = group_newton.finiteDifferenceProbeM3(
            phase.current[column],
            .central,
        );
        const one_sided_probe_m3 = group_newton.finiteDifferenceProbeM3(
            phase.current[column],
            .one_sided,
        );
        const upward_room = @max(
            0.0,
            available_capacity - phase.current[column],
        );
        const downward_room = @max(0.0, phase.current[column]);
        const central_perturbation = @min(
            central_probe_m3,
            @min(0.5 * upward_room, 0.5 * downward_room),
        );
        if (central_perturbation > 1.0e-20) {
            @memcpy(phase.probe, phase.current);
            phase.probe[column] += central_perturbation;
            if (group_residual.residualAt(
                phase.grid,
                phase.faces,
                phase.active_properties,
                phase.base,
                phase.probe,
                phase.target,
                phase.probe_residual,
                phase.scratch,
                phase.trial_micro_flux,
                phase.trial_macro_flux,
            )) |_| {
                @memcpy(phase.candidate, phase.current);
                phase.candidate[column] -= central_perturbation;
                if (group_residual.residualAt(
                    phase.grid,
                    phase.faces,
                    phase.active_properties,
                    phase.base,
                    phase.candidate,
                    phase.target,
                    phase.candidate_residual,
                    phase.scratch,
                    phase.trial_micro_flux,
                    phase.trial_macro_flux,
                )) |_| {
                    for (0..phase.components) |row|
                        phase.jacobian[row * phase.components + column] =
                            (phase.probe_residual[row] -
                                phase.candidate_residual[row]) /
                            (2.0 * central_perturbation);
                    continue;
                } else |_| {}
            } else |_| {}
        }
        const use_upward = upward_room >= downward_room;
        const perturbation = @min(
            one_sided_probe_m3,
            0.5 * @max(upward_room, downward_room),
        );
        if (perturbation <= 1.0e-20) {
            for (0..phase.components) |row|
                phase.jacobian[row * phase.components + column] =
                    if (row == column) 1 else 0;
            continue;
        }
        var signed_perturbation = if (use_upward)
            perturbation
        else
            -perturbation;
        var probe_attempt: u8 = 0;
        while (true) : (probe_attempt += 1) {
            @memcpy(phase.probe, phase.current);
            phase.probe[column] += signed_perturbation;
            if (group_residual.residualAt(
                phase.grid,
                phase.faces,
                phase.active_properties,
                phase.base,
                phase.probe,
                phase.target,
                phase.probe_residual,
                phase.scratch,
                phase.trial_micro_flux,
                phase.trial_macro_flux,
            )) |_| break else |_| {
                if (probe_attempt >= 15) {
                    dense_jacobian_valid = false;
                    break;
                }
                signed_perturbation *= 0.5;
            }
        }
        if (!dense_jacobian_valid) break;
        for (0..phase.components) |row|
            phase.jacobian[row * phase.components + column] =
                (phase.probe_residual[row] - phase.residual[row]) /
                signed_perturbation;
    };
    if (!dense_jacobian_valid) return false;

    // Determine components from current numerical couplings rather than
    // geometric faces: donor limiting or zero conductance can split one
    // geometric component into independent Jacobian blocks.
    for (0..phase.cells) |cell| {
        phase.micropore_parent[cell] = cell;
        phase.macropore_parent[cell] = cell;
        phase.micropore_component_size[cell] = 1;
        phase.macropore_component_size[cell] = 1;
    }
    for (0..phase.cells) |first| {
        for (first + 1..phase.cells) |second| {
            if (@abs(phase.jacobian[first * phase.components + second]) >
                1.0e-20 or
                @abs(phase.jacobian[second * phase.components + first]) >
                    1.0e-20)
            {
                group_conserved.unionComponents(
                    phase.micropore_parent,
                    phase.micropore_component_size,
                    first,
                    second,
                );
            }
            const macro_first = phase.cells + first;
            const macro_second = phase.cells + second;
            if (@abs(phase.jacobian[
                macro_first * phase.components + macro_second
            ]) > 1.0e-20 or
                @abs(phase.jacobian[
                    macro_second * phase.components + macro_first
                ]) > 1.0e-20)
            {
                group_conserved.unionComponents(
                    phase.macropore_parent,
                    phase.macropore_component_size,
                    first,
                    second,
                );
            }
        }
    }
    // Release a component's total-storage coordinate only when the current
    // Jacobian actually contains an external source/sink. A configured
    // boundary can be inactive at a donor or water-table clip and must then
    // remain exactly mass-conserving.
    group_conserved.releaseIndependentStorageCoordinates(
        phase.micropore_parent,
        phase.micropore_component_size,
    );
    group_conserved.releaseIndependentStorageCoordinates(
        phase.macropore_parent,
        phase.macropore_component_size,
    );
    // Re-evaluate closed-component columns in the coordinates that the linear
    // solve actually uses. A direct member-to-anchor transfer preserves total
    // water during residual evaluation and gives the exact reduced derivative.
    for (0..phase.components) |column| {
        const domain_offset = if (column < phase.cells)
            @as(usize, 0)
        else
            phase.cells;
        const column_cell = column - domain_offset;
        const parent = if (domain_offset == 0)
            phase.micropore_parent
        else
            phase.macropore_parent;
        const component_size = if (domain_offset == 0)
            phase.micropore_component_size
        else
            phase.macropore_component_size;
        const root = group_conserved.componentRoot(parent, column_cell);
        if (component_size[root] <= 1) continue;
        const anchor = domain_offset + root;
        if (column == anchor) {
            for (0..phase.components) |row|
                phase.jacobian[row * phase.components + column] = 0;
            continue;
        }
        const column_capacity = if (domain_offset == 0)
            try group_flux.physicalLiquidCapacityM3(
                phase.grid.matrix_pore_capacity_m3[column_cell],
                phase.grid.matrix_ice_water_m3[column_cell],
                phase.properties.ice_density_megagrams_per_m3,
            )
        else
            try group_flux.physicalLiquidCapacityM3(
                phase.grid.macropore_pore_capacity_m3[column_cell],
                phase.grid.macropore_ice_water_m3[column_cell],
                phase.properties.ice_density_megagrams_per_m3,
            );
        const anchor_capacity = if (domain_offset == 0)
            try group_flux.physicalLiquidCapacityM3(
                phase.grid.matrix_pore_capacity_m3[root],
                phase.grid.matrix_ice_water_m3[root],
                phase.properties.ice_density_megagrams_per_m3,
            )
        else
            try group_flux.physicalLiquidCapacityM3(
                phase.grid.macropore_pore_capacity_m3[root],
                phase.grid.macropore_ice_water_m3[root],
                phase.properties.ice_density_megagrams_per_m3,
            );
        const positive_room = @min(
            @max(0, column_capacity - phase.current[column]),
            @max(0, phase.current[anchor]),
        );
        const negative_room = @min(
            @max(0, phase.current[column]),
            @max(0, anchor_capacity - phase.current[anchor]),
        );
        const nominal = group_newton.finiteDifferenceProbeM3(
            @max(
                @abs(phase.current[column]),
                @abs(phase.current[anchor]),
            ),
            .one_sided,
        );
        var signed_perturbation = if (positive_room >= negative_room)
            @min(nominal, 0.5 * positive_room)
        else
            -@min(nominal, 0.5 * negative_room);
        if (@abs(signed_perturbation) <= 1.0e-20) return false;
        var probe_attempt: u8 = 0;
        while (true) : (probe_attempt += 1) {
            @memcpy(phase.probe, phase.current);
            phase.probe[column] += signed_perturbation;
            phase.probe[anchor] -= signed_perturbation;
            if (group_residual.residualAt(
                phase.grid,
                phase.faces,
                phase.active_properties,
                phase.base,
                phase.probe,
                phase.target,
                phase.probe_residual,
                phase.scratch,
                phase.trial_micro_flux,
                phase.trial_macro_flux,
            )) |_| break else |_| {
                if (probe_attempt >= 15) return false;
                signed_perturbation *= 0.5;
            }
        }
        for (0..phase.components) |row|
            phase.jacobian[row * phase.components + column] =
                (phase.probe_residual[row] - phase.residual[row]) /
                signed_perturbation;
    }
    return true;
}

const maximum_broyden_reuses: u8 = 6;

fn updateDenseJacobianBroyden(
    jacobian: []f64,
    previous_state: []const f64,
    next_state: []const f64,
    previous_residual: []const f64,
    next_residual: []const f64,
    options: group_types.Options,
) bool {
    const dimension = previous_state.len;
    if (next_state.len != dimension or previous_residual.len != dimension or
        next_residual.len != dimension or jacobian.len < dimension * dimension)
        return false;

    var normalized_step_norm_squared: f64 = 0;
    for (previous_state, next_state) |old_value, new_value| {
        const scale = options.absolute_tolerance_m3 + options.relative_tolerance *
            @max(@abs(old_value), @abs(new_value));
        const normalized_step = (new_value - old_value) / scale;
        normalized_step_norm_squared += normalized_step * normalized_step;
    }
    if (!std.math.isFinite(normalized_step_norm_squared) or
        normalized_step_norm_squared <= std.math.floatEps(f64))
        return false;

    for (0..dimension) |row| {
        var predicted_residual_change: f64 = 0;
        for (0..dimension) |column|
            predicted_residual_change += jacobian[row * dimension + column] *
                (next_state[column] - previous_state[column]);
        const secant_defect = next_residual[row] - previous_residual[row] -
            predicted_residual_change;
        if (!std.math.isFinite(secant_defect)) return false;
        for (0..dimension) |column| {
            const scale = options.absolute_tolerance_m3 + options.relative_tolerance *
                @max(@abs(previous_state[column]), @abs(next_state[column]));
            const weight = (next_state[column] - previous_state[column]) /
                (scale * scale * normalized_step_norm_squared);
            const updated = jacobian[row * dimension + column] + secant_defect * weight;
            if (!std.math.isFinite(updated)) return false;
            jacobian[row * dimension + column] = updated;
        }
    }
    return true;
}

fn publishDenseJacobianCache(
    cache: ?*group_types.DenseJacobianCache,
    jacobian: []const f64,
    dimension: usize,
    valid: bool,
    reuse_age: u8,
) void {
    const destination = cache orelse return;
    const element_count = dimension * dimension;
    if (!valid or jacobian.len < element_count or destination.values.len < element_count) {
        destination.invalidate();
        return;
    }
    @memcpy(destination.values[0..element_count], jacobian[0..element_count]);
    destination.dimension = dimension;
    destination.reuse_age = reuse_age;
    destination.valid = true;
}

test "soil water Broyden update satisfies the accepted secant" {
    var jacobian = [_]f64{
        2, 0,
        0, 3,
    };
    const previous_state = [_]f64{ 1, 2 };
    const next_state = [_]f64{ 1.25, 1.5 };
    const previous_residual = [_]f64{ 0.4, -0.3 };
    const next_residual = [_]f64{ 1.1, 0.2 };
    try std.testing.expect(updateDenseJacobianBroyden(
        &jacobian,
        &previous_state,
        &next_state,
        &previous_residual,
        &next_residual,
        .{ .max_iterations = 2 },
    ));
    for (0..2) |row| {
        var projected_change: f64 = 0;
        for (0..2) |column|
            projected_change += jacobian[row * 2 + column] *
                (next_state[column] - previous_state[column]);
        try std.testing.expectApproxEqAbs(
            next_residual[row] - previous_residual[row],
            projected_change,
            16 * std.math.floatEps(f64),
        );
    }
}

fn solveControlled(
    allocator: std.mem.Allocator,
    grid: *grid_module.GridState,
    faces: []const group_types.Face,
    properties: group_types.Properties,
    micropore_face_flux_m3_per_step: []f64,
    macropore_face_flux_m3_per_step: []f64,
    options: group_types.Options,
    control: TestControl,
) !group_types.Result {
    try validateInputs(grid, faces, properties, micropore_face_flux_m3_per_step, macropore_face_flux_m3_per_step, options);
    const cells = grid.layer_count;
    const components = try std.math.mul(usize, cells, 2);
    // Boundary ledgers are publication outputs, not nonlinear scratch. Residual
    // evaluation clears and repopulates them for every trial, so point trials at
    // private buffers and copy the accepted image only after state publication.
    // A failed solve must leave every caller-owned scientific output untouched.
    var trial_artificial_drainage: ?[]f64 = null;
    defer if (trial_artificial_drainage) |values| allocator.free(values);
    var trial_boundary_exchange: ?[]f64 = null;
    defer if (trial_boundary_exchange) |values| allocator.free(values);
    var trial_boundary_exchange_by_layer: ?[]f64 = null;
    defer if (trial_boundary_exchange_by_layer) |values| allocator.free(values);
    var active_properties = properties;
    var kirchhoff_cache: kirchhoff.Cache = .{};
    active_properties.kirchhoff_cache = &kirchhoff_cache;
    const face_flux_cache_enabled = denseNewtonEligible(
        components,
        options.dense_newton_max_components,
    );
    var face_flux_cache = try richards_face_cache.Cache.init(
        allocator,
        if (face_flux_cache_enabled) faces.len else 0,
    );
    defer face_flux_cache.deinit(allocator);
    if (face_flux_cache_enabled)
        active_properties.richards_face_flux_cache = &face_flux_cache;
    if (properties.artificial_drainage_outflow_m3_per_step != null) {
        trial_artificial_drainage = try allocator.alloc(f64, grid.cell_count);
        active_properties.artificial_drainage_outflow_m3_per_step = trial_artificial_drainage.?;
    }
    if (properties.boundary_water_exchange_m3_per_step != null) {
        trial_boundary_exchange = try allocator.alloc(f64, grid.cell_count);
        active_properties.boundary_water_exchange_m3_per_step = trial_boundary_exchange.?;
    }
    if (properties.boundary_water_exchange_m3_per_layer_per_step != null) {
        trial_boundary_exchange_by_layer = try allocator.alloc(f64, grid.layer_count);
        active_properties.boundary_water_exchange_m3_per_layer_per_step = trial_boundary_exchange_by_layer.?;
    }
    const base = try allocator.alloc(f64, components);
    defer allocator.free(base);
    @memcpy(base[0..cells], grid.matrix_liquid_water_m3);
    @memcpy(base[cells..], grid.macropore_liquid_water_m3);
    const current = try allocator.dupe(f64, base);
    defer allocator.free(current);
    const residual = try allocator.alloc(f64, components);
    defer allocator.free(residual);
    const target = try allocator.alloc(f64, components);
    defer allocator.free(target);
    const probe = try allocator.alloc(f64, components);
    defer allocator.free(probe);
    const probe_residual = try allocator.alloc(f64, components);
    defer allocator.free(probe_residual);
    const candidate = try allocator.alloc(f64, components);
    defer allocator.free(candidate);
    const candidate_residual = try allocator.alloc(f64, components);
    defer allocator.free(candidate_residual);
    const best_candidate = try allocator.alloc(f64, components);
    defer allocator.free(best_candidate);
    const previous_state = try allocator.alloc(f64, components);
    defer allocator.free(previous_state);
    const previous_residual = try allocator.alloc(f64, components);
    defer allocator.free(previous_residual);
    const previous_previous_state = try allocator.alloc(f64, components);
    defer allocator.free(previous_previous_state);
    const previous_previous_residual = try allocator.alloc(f64, components);
    defer allocator.free(previous_previous_residual);
    const scratch = try allocator.alloc(f64, components);
    defer allocator.free(scratch);
    const trial_micro_flux = try allocator.alloc(f64, faces.len);
    defer allocator.free(trial_micro_flux);
    const trial_macro_flux = try allocator.alloc(f64, faces.len);
    defer allocator.free(trial_macro_flux);
    const layer_internal_input_m3 = try allocator.alloc(f64, cells);
    defer allocator.free(layer_internal_input_m3);
    const layer_internal_output_m3 = try allocator.alloc(f64, cells);
    defer allocator.free(layer_internal_output_m3);
    const cell_internal_input_m3 = try allocator.alloc(f64, grid.cell_count);
    defer allocator.free(cell_internal_input_m3);
    const cell_internal_output_m3 = try allocator.alloc(f64, grid.cell_count);
    defer allocator.free(cell_internal_output_m3);
    const dense_workspace_elements = try boundedDenseWorkspaceElements(
        components,
        options.dense_newton_max_components,
    );
    const jacobian = try allocator.alloc(f64, dense_workspace_elements);
    defer allocator.free(jacobian);
    const newton_delta = try allocator.alloc(f64, components);
    defer allocator.free(newton_delta);
    const reduced_jacobian = try allocator.alloc(f64, dense_workspace_elements);
    defer allocator.free(reduced_jacobian);
    const reduced_right_hand_side = try allocator.alloc(f64, components);
    defer allocator.free(reduced_right_hand_side);
    const reduced_index_by_component = try allocator.alloc(usize, components);
    defer allocator.free(reduced_index_by_component);
    const micropore_parent = try allocator.alloc(usize, cells);
    defer allocator.free(micropore_parent);
    const macropore_parent = try allocator.alloc(usize, cells);
    defer allocator.free(macropore_parent);
    const micropore_component_size = try allocator.alloc(usize, cells);
    defer allocator.free(micropore_component_size);
    const macropore_component_size = try allocator.alloc(usize, cells);
    defer allocator.free(macropore_component_size);
    for (0..cells) |cell| {
        micropore_parent[cell] = cell;
        macropore_parent[cell] = cell;
        micropore_component_size[cell] = 1;
        macropore_component_size[cell] = 1;
    }

    var newton_steps: u16 = 0;
    var picard_steps: u16 = 0;
    var history_count: u8 = 0;
    // Divergence/oscillation watch, mirroring `core/numerics.zig` and
    // `soil/heat/solver_solve.zig`. `max_iterations` is a hard safety
    // ceiling, not a target: a trajectory provably running away from the
    // best point it has found should say so instead of spending the rest of
    // the NPH budget to report mere non-convergence. Per-solve state, so a
    // retry starts clean.
    var best_divergence_watch_norm = std.math.inf(f64);
    var non_improving_steps: u16 = 0;
    var best_progress_watch_norm = std.math.inf(f64);
    var insufficient_progress_steps: u16 = 0;
    var oscillation_steps: u16 = 0;
    var slow_newton_norm_history: [slow_newton_progress_history_length]f64 = undefined;
    var slow_newton_norm_count: u8 = 0;
    var slow_newton_last_recorded_step: u16 = 0;
    var rejected_forecast_recovery_step: ?u16 = null;
    // TEMP_DIAGNOSTIC: Retain a bounded failure-only trace while the Ottawa
    // production deck's hour-530 Richards frontier is being diagnosed. This
    // does not participate in method selection or publication.
    var failure_norm_trace: [64]f64 = undefined;
    var failure_norm_trace_len: usize = 0;
    var dense_line_steps: u16 = 0;
    var dense_trust_steps: u16 = 0;
    var domain_block_steps: u16 = 0;
    var spatial_block_steps: u16 = 0;
    var diagonal_steps: u16 = 0;
    var directional_steps: u16 = 0;
    var dense_jacobian_assemblies: u16 = 0;
    var dense_jacobian_reuses: u16 = 0;
    var dense_jacobian_ready = false;
    var dense_jacobian_reuse_age: u8 = 0;
    if (properties.dense_jacobian_cache) |cache| {
        if (dense_workspace_elements != 0 and
            cache.valid and cache.dimension == components and
            cache.reuse_age < maximum_broyden_reuses)
        {
            @memcpy(jacobian[0..dense_workspace_elements], cache.values[0..dense_workspace_elements]);
            dense_jacobian_ready = true;
            dense_jacobian_reuse_age = cache.reuse_age;
        }
    }
    var forced_newton_failures_remaining = control.forced_initial_newton_failures;
    const dense_jacobian_cache_loaded = dense_jacobian_ready;
    // An accepted Anderson recovery is not a publication candidate. The next
    // counted outer iteration must retry Newton before convergence may publish.
    var newton_retry_required = false;
    var iteration: u16 = 0;
    while (iteration < options.max_iterations) : (iteration += 1) {
        // Every counted iteration solves the actual whole-hour WATSUB
        // residual. Invalid accepted state is terminal; damping is confined to
        // private Newton trials and can never repair `current` out of band.
        try group_residual.residualAt(grid, faces, active_properties, base, current, target, residual, scratch, trial_micro_flux, trial_macro_flux);
        const current_norm = try group_residual.scaledNorm(current, residual, options);
        if (failure_norm_trace_len < failure_norm_trace.len) {
            failure_norm_trace[failure_norm_trace_len] = current_norm;
            failure_norm_trace_len += 1;
        }
        // Only accepted Newton promotions extend the contraction history.
        // Anderson states reset it, while a rejected speculative recovery is
        // prevented from being repriced until Newton has made a new update.
        const accepted_newton_since_forecast = slow_newton_norm_count != 0 and
            newton_steps != slow_newton_last_recorded_step;
        if (slow_newton_norm_count == 0 or accepted_newton_since_forecast) {
            rememberNewtonNorm(
                &slow_newton_norm_history,
                &slow_newton_norm_count,
                current_norm,
            );
            slow_newton_last_recorded_step = newton_steps;
        }
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        if (!retrying_newton_after_anderson and current_norm <= 1) {
            var publication_state: []const f64 = current;
            var conservation_accepted = try localConservationAccepted(grid, faces, active_properties, base, current, residual, trial_micro_flux, trial_macro_flux, layer_internal_input_m3, layer_internal_output_m3, cell_internal_input_m3, cell_internal_output_m3, options, null);
            if (!conservation_accepted and boundedConservativeMapCorrection(current, target, options)) {
                @memset(candidate, 0);
                conservation_accepted = try localConservationAccepted(grid, faces, active_properties, base, target, candidate, trial_micro_flux, trial_macro_flux, layer_internal_input_m3, layer_internal_output_m3, cell_internal_input_m3, cell_internal_output_m3, options, null);
                if (conservation_accepted) publication_state = target;
            }
            if (conservation_accepted) {
                try group_flux.state_update(grid, properties, publication_state);
                @memcpy(micropore_face_flux_m3_per_step, trial_micro_flux);
                @memcpy(macropore_face_flux_m3_per_step, trial_macro_flux);
                if (properties.artificial_drainage_outflow_m3_per_step) |published|
                    @memcpy(published, trial_artificial_drainage.?);
                if (properties.boundary_water_exchange_m3_per_step) |published|
                    @memcpy(published, trial_boundary_exchange.?);
                if (properties.boundary_water_exchange_m3_per_layer_per_step) |published|
                    @memcpy(published, trial_boundary_exchange_by_layer.?);
                publishDenseJacobianCache(
                    properties.dense_jacobian_cache,
                    jacobian,
                    components,
                    // The conservative correction is already bounded by the
                    // nonlinear band and independently closes local mass.
                    // This matrix is an approximate next-step predictor, not
                    // a certificate attached to the published inventory.
                    // Retain it through the correction; a rejected warm
                    // direction still triggers a fresh Jacobian this iteration.
                    dense_jacobian_ready,
                    dense_jacobian_reuse_age,
                );
                if (control.trace) |trace| trace.record(.publish);
                return .{ .iterations = iteration + 1, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = picard_steps, .maximum_scaled_residual = current_norm, .dense_jacobian_assemblies = dense_jacobian_assemblies, .dense_jacobian_reuses = dense_jacobian_reuses, .dense_jacobian_cache_supplied = properties.dense_jacobian_cache != null, .dense_jacobian_cache_loaded = dense_jacobian_cache_loaded, .dense_jacobian_ready_at_publication = dense_jacobian_ready, .conservative_map_publication = publication_state.ptr != current.ptr, .dense_jacobian_cache_published = if (properties.dense_jacobian_cache) |cache| cache.valid else false, .richards_face_flux_cache_hits = face_flux_cache.hits, .richards_face_flux_cache_misses = face_flux_cache.misses };
            }
        }
        // Divergence/oscillation watch. Defaults match `core/numerics.zig`
        // and `soil/heat/solver_solve.zig` (patience 8, growth factor 1e3),
        // so any solve that converged before still converges on the same
        // trajectory; this can only newly reject trajectories that are
        // provably running away from their own best point.
        if (current_norm < best_divergence_watch_norm) {
            best_divergence_watch_norm = current_norm;
            non_improving_steps = 0;
        } else if (current_norm > options.divergence_growth_factor * best_divergence_watch_norm) {
            non_improving_steps += 1;
            if (non_improving_steps >= options.divergence_patience) {
                if (!builtin.is_test) std.log.warn("soil water solver diverging: iteration={d} scaled_residual={e} best_scaled_residual={e} growth_factor={e} patience={d}", .{ iteration + 1, current_norm, best_divergence_watch_norm, options.divergence_growth_factor, options.divergence_patience });
                return error.SoilWaterSolverDiverged;
            }
        } else {
            non_improving_steps = 0;
        }
        // The scaled norm is dimensionless. A decrease smaller than
        // sqrt(machine epsilon) times its current scale is numerically
        // indistinguishable from no progress; after finite patience, route
        // Newton stagnation to the mandatory Anderson recovery.
        if (std.math.isInf(best_progress_watch_norm)) {
            best_progress_watch_norm = current_norm;
        } else {
            if (scaledProgressIsInsufficient(best_progress_watch_norm, current_norm)) {
                insufficient_progress_steps +|= 1;
            } else {
                insufficient_progress_steps = 0;
            }
            best_progress_watch_norm = @min(best_progress_watch_norm, current_norm);
        }
        if (history_count > 0 and scaledResidualDirectionsReverse(
            current,
            residual,
            previous_state,
            previous_residual,
            options,
        )) {
            oscillation_steps +|= 1;
        } else {
            oscillation_steps = 0;
        }
        const stagnation_requires_anderson = !retrying_newton_after_anderson and
            (insufficient_progress_steps >= options.stagnation_patience or
                oscillation_steps >= options.oscillation_patience);
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
        const progress_requires_anderson =
            stagnation_requires_anderson or forecast_requires_anderson;

        var limiting_component: usize = 0;
        var limiting_component_norm: f64 = -1;
        for (current, residual, 0..) |state, difference, component| {
            const norm = group_residual.scaledComponentResidual(state, difference, options);
            if (norm > limiting_component_norm) {
                limiting_component_norm = norm;
                limiting_component = component;
            }
        }
        newton_primary: {
            if (progress_requires_anderson) break :newton_primary;
            if (control.trace) |trace| trace.record(.newton_attempt);
            if (forced_newton_failures_remaining > 0) {
                forced_newton_failures_remaining -= 1;
                break :newton_primary;
            }
            var accepted_newton = false;
            // Start with the spatially coupled Richards Jacobian. Large
            // geospatial cells expose wetting fronts for which a diagonal Newton
            // correction cannot propagate information through the column quickly
            // enough.
            // A caller's iteration count is a hard ceiling, not a schedule for
            // when the strongest Newton family is allowed to start. Delaying
            // this fully coupled step until the last eight slots made a larger
            // ceiling delay Newton further (20 -> iteration 12, 100 -> 92),
            // while difficult Richards fronts spent the early budget on weaker
            // directional/local corrections. Use coupled Newton from the first
            // iterate whenever the bounded workspace admits it; all existing
            // line-search, validity, and strict-merit gates remain unchanged.
            const dense_jacobian_eligible = denseNewtonEligible(
                components,
                options.dense_newton_max_components,
            );
            if (dense_jacobian_reuse_age >= maximum_broyden_reuses) {
                dense_jacobian_ready = false;
                dense_jacobian_reuse_age = 0;
            }
            var accepted_dense_trust_region = false;
            if (dense_jacobian_eligible) {
                var dense_attempt: u8 = 0;
                while (dense_attempt < 2 and !accepted_newton) : (dense_attempt += 1) {
                    const reused_jacobian = dense_jacobian_ready;
                    if (!dense_jacobian_ready) {
                        dense_jacobian_ready = try assembleDenseConservedJacobian(.{
                            .grid = grid,
                            .faces = faces,
                            .active_properties = active_properties,
                            .properties = properties,
                            .base = base,
                            .current = current,
                            .residual = residual,
                            .target = target,
                            .probe = probe,
                            .probe_residual = probe_residual,
                            .candidate = candidate,
                            .candidate_residual = candidate_residual,
                            .scratch = scratch,
                            .trial_micro_flux = trial_micro_flux,
                            .trial_macro_flux = trial_macro_flux,
                            .jacobian = jacobian,
                            .micropore_parent = micropore_parent,
                            .macropore_parent = macropore_parent,
                            .micropore_component_size = micropore_component_size,
                            .macropore_component_size = macropore_component_size,
                            .cells = cells,
                            .components = components,
                        });
                        dense_jacobian_assemblies +|= 1;
                        if (control.dense_jacobian_assemblies) |count| count.* +|= 1;
                    } else {
                        dense_jacobian_reuses +|= 1;
                    }
                    if (!dense_jacobian_ready) break;

                    for (residual, newton_delta) |value, *right_hand_side|
                        right_hand_side.* = -value;
                    if (group_conserved.solveConservedNewtonSystem(jacobian, residual, newton_delta, reduced_jacobian, reduced_right_hand_side, reduced_index_by_component, components, cells, micropore_parent, micropore_component_size, macropore_parent, macropore_component_size)) {
                        var line_fraction: f64 = 1;
                        var line_search: u8 = 0;
                        while (line_search < 6) : (line_search += 1) {
                            const valid_candidate = group_residual.projectStorageStep(grid, current, newton_delta, line_fraction, properties.ice_density_megagrams_per_m3, candidate);
                            if (valid_candidate) {
                                if (group_residual.residualAt(grid, faces, active_properties, base, candidate, target, candidate_residual, scratch, trial_micro_flux, trial_macro_flux)) |_| {
                                    const candidate_norm = try group_residual.scaledNorm(candidate, candidate_residual, options);
                                    if (candidate_norm < current_norm) {
                                        @memcpy(best_candidate, candidate);
                                        @memcpy(probe_residual, candidate_residual);
                                        accepted_newton = true;
                                        break;
                                    }
                                } else |_| {}
                            }
                            line_fraction *= 0.5;
                        }
                    }
                    if (!accepted_newton) {
                        var damping_index: u8 = 0;
                        trust_region_search: while (damping_index < 11) : (damping_index += 1) {
                            const damping = std.math.pow(f64, 10.0, -8.0 + @as(f64, @floatFromInt(damping_index)));
                            if (!group_conserved.solveConservedTrustRegionSystem(jacobian, residual, current, options, newton_delta, reduced_jacobian, reduced_right_hand_side, reduced_index_by_component, components, cells, micropore_parent, micropore_component_size, macropore_parent, macropore_component_size, damping)) continue;
                            var line_fraction: f64 = 1;
                            var line_search: u8 = 0;
                            while (line_search < 8) : (line_search += 1) {
                                const valid_candidate = group_residual.projectStorageStep(grid, current, newton_delta, line_fraction, properties.ice_density_megagrams_per_m3, candidate);
                                if (valid_candidate) {
                                    if (group_residual.residualAt(grid, faces, active_properties, base, candidate, target, candidate_residual, scratch, trial_micro_flux, trial_macro_flux)) |_| {
                                        const candidate_norm = try group_residual.scaledNorm(candidate, candidate_residual, options);
                                        if (candidate_norm < current_norm) {
                                            @memcpy(best_candidate, candidate);
                                            @memcpy(probe_residual, candidate_residual);
                                            accepted_newton = true;
                                            accepted_dense_trust_region = true;
                                            break :trust_region_search;
                                        }
                                    } else |_| {}
                                }
                                line_fraction *= 0.5;
                            }
                        }
                    }
                    if (accepted_newton) {
                        dense_jacobian_ready = updateDenseJacobianBroyden(
                            jacobian,
                            current,
                            best_candidate,
                            residual,
                            probe_residual,
                            options,
                        );
                        if (dense_jacobian_ready)
                            dense_jacobian_reuse_age +|= 1
                        else
                            dense_jacobian_reuse_age = 0;
                        group_residual.rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
                        @memcpy(current, best_candidate);
                        newton_steps += 1;
                        if (accepted_dense_trust_region)
                            dense_trust_steps += 1
                        else
                            dense_line_steps += 1;
                        break;
                    }

                    dense_jacobian_ready = false;
                    dense_jacobian_reuse_age = 0;
                    if (!reused_jacobian) break;
                }
            }
            if (accepted_newton) continue;
            // If the fully coupled matrix is ill-conditioned because a nearly
            // empty macropore coordinate is on a bound, solve the complete
            // micropore Richards column as one Newton block. This is still one
            // NPH iteration and retains the full residual (including dual-domain
            // exchange) in its line-search merit function.
            if (try group_newton.domainBlockNewton(
                grid,
                faces,
                active_properties,
                options,
                base,
                current,
                target,
                residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
                0,
                false,
                best_candidate,
                candidate,
                candidate_residual,
                probe,
                probe_residual,
                reduced_jacobian,
                reduced_right_hand_side,
            )) {
                group_residual.rememberIteration(
                    current,
                    residual,
                    previous_state,
                    previous_residual,
                    previous_previous_state,
                    previous_previous_residual,
                    &history_count,
                );
                @memcpy(current, best_candidate);
                dense_jacobian_ready = false;
                dense_jacobian_reuse_age = 0;
                newton_steps += 1;
                domain_block_steps += 1;
                continue;
            }
            // When the complete domain step is rejected at a semismooth donor
            // transition, resolve the limiting cell and two incident face rings
            // as one coupled Newton block. This consumes the current NPH
            // iteration; it is not deferred to an uncounted post-loop sweep.
            @memcpy(best_candidate, current);
            @memcpy(newton_delta, residual);
            var spatial_block_changed = try group_newton.spatialDomainCellNewton(
                grid,
                faces,
                active_properties,
                base,
                current,
                target,
                residual,
                scratch,
                trial_micro_flux,
                trial_macro_flux,
                limiting_component,
                candidate,
                candidate_residual,
                probe,
                probe_residual,
                reduced_index_by_component,
                reduced_jacobian,
                reduced_right_hand_side,
                options,
                true,
            );
            // A dry macropore active set can make the combined
            // matrix/macropore block singular even though the macropore-only
            // Richards block is well conditioned. Matrix coordinates already
            // received this domain-only retry; apply the same Newton fallback
            // to a limiting macropore coordinate instead of routing it
            // directly to Anderson.
            if (!spatial_block_changed)
                spatial_block_changed = try group_newton.spatialDomainCellNewton(
                    grid,
                    faces,
                    active_properties,
                    base,
                    current,
                    target,
                    residual,
                    scratch,
                    trial_micro_flux,
                    trial_macro_flux,
                    limiting_component,
                    candidate,
                    candidate_residual,
                    probe,
                    probe_residual,
                    reduced_index_by_component,
                    reduced_jacobian,
                    reduced_right_hand_side,
                    options,
                    false,
                );
            if (spatial_block_changed) {
                dense_jacobian_ready = false;
                dense_jacobian_reuse_age = 0;
                @memcpy(previous_state, best_candidate);
                @memcpy(previous_residual, newton_delta);
                history_count = 1;
                newton_steps += 1;
                spatial_block_steps += 1;
                continue;
            }
            if (group_residual.addDirection(current, residual, options.directional_probe_fraction, probe)) |_| {
                if (group_residual.residualAt(grid, faces, active_properties, base, probe, target, probe_residual, scratch, trial_micro_flux, trial_macro_flux)) |_| {
                    var numerator: f64 = 0;
                    var denominator: f64 = 0;
                    for (residual, probe_residual) |base_residual, sampled_residual| {
                        const derivative = (sampled_residual - base_residual) / options.directional_probe_fraction;
                        numerator += base_residual * derivative;
                        denominator += derivative * derivative;
                    }
                    // Diagonal secant Newton step. Each runtime water store can
                    // have a very different stiffness near saturation; a single
                    // global line fraction leaves the slowest component far from
                    // convergence within NPH.
                    var diagonal_candidate_valid = true;
                    for (current, residual, probe_residual, candidate) |value, base_residual, sampled_residual, *next| {
                        const derivative = (sampled_residual - base_residual) / options.directional_probe_fraction;
                        if (!std.math.isFinite(derivative) or @abs(derivative) <= std.math.floatEps(f64)) {
                            if (group_residual.scaledComponentResidual(
                                value,
                                base_residual,
                                options,
                            ) > 1) {
                                diagonal_candidate_valid = false;
                                break;
                            }
                            next.* = value;
                            continue;
                        }
                        const fraction = std.math.clamp(-base_residual / derivative, options.minimum_newton_fraction, options.maximum_newton_fraction);
                        next.* = value + fraction * base_residual;
                        if (!std.math.isFinite(next.*) or next.* < 0) diagonal_candidate_valid = false;
                    }
                    if (diagonal_candidate_valid) {
                        if (group_residual.residualAt(grid, faces, active_properties, base, candidate, target, candidate_residual, scratch, trial_micro_flux, trial_macro_flux)) |_| {
                            if (try group_residual.scaledNorm(candidate, candidate_residual, options) < current_norm) {
                                group_residual.rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
                                @memcpy(current, candidate);
                                dense_jacobian_ready = false;
                                dense_jacobian_reuse_age = 0;
                                newton_steps += 1;
                                diagonal_steps += 1;
                                accepted_newton = true;
                            }
                        } else |_| {}
                    }
                    if (accepted_newton) continue;
                    if (std.math.isFinite(denominator) and denominator > std.math.floatEps(f64)) {
                        const fraction = std.math.clamp(-numerator / denominator, options.minimum_newton_fraction, options.maximum_newton_fraction);
                        if (group_residual.addDirection(current, residual, fraction, candidate)) |_| {
                            if (group_residual.residualAt(grid, faces, active_properties, base, candidate, target, candidate_residual, scratch, trial_micro_flux, trial_macro_flux)) |_| {
                                if (try group_residual.scaledNorm(candidate, candidate_residual, options) < current_norm) {
                                    group_residual.rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
                                    @memcpy(current, candidate);
                                    dense_jacobian_ready = false;
                                    dense_jacobian_reuse_age = 0;
                                    newton_steps += 1;
                                    directional_steps += 1;
                                    accepted_newton = true;
                                }
                            } else |_| {}
                        } else |_| {}
                    }
                } else |_| {}
            } else |_| {}
            if (accepted_newton) continue;
        }
        // The iteration immediately following an accepted Anderson candidate
        // is reserved for this Newton retry. If Newton cannot improve an
        // already-converged candidate, the next convergence gate (or the
        // post-ceiling gate) may publish it; a second recovery cannot replace
        // the required retry.
        if (retrying_newton_after_anderson) continue;
        // RECOVERY. Relaxed fixed-point images are evaluated only as seeds for
        // Anderson acceleration and are never committed directly. A
        // semismooth dry-bound map can put the first seed exactly on its root,
        // making depth-one Anderson return that seed unchanged. Restarting
        // with smaller uncommitted seed fractions makes the accelerated
        // candidate distinct while retaining the same fixed point.
        var picard_seed_evaluated = false;
        // Anderson acceleration (depth 1) over the Picard map `g(x) = x +
        // R(x)`, whose fixed-point defect is exactly the residual. This is
        // the sole recovery path after every Newton family has failed.
        // Adoption requires a strictly smaller fully recomputed scaled
        // residual than the accepted current iterate. The relaxed seed is
        // private secant history and never becomes an acceptance incumbent.
        // `probe`/`probe_residual`
        // are free scratch here: every earlier use of them this iteration
        // belongs to a branch that either `continue`d on acceptance or has
        // already been fully consumed.
        var used_anderson = false;
        var seed_fraction = options.picard_relaxation;
        var seed_attempt: u8 = 0;
        while (seed_attempt < 8 and !used_anderson) : (seed_attempt += 1) {
            var picard_seed_valid = true;
            group_residual.addDirection(current, residual, seed_fraction, candidate) catch {
                picard_seed_valid = false;
            };
            if (!picard_seed_valid) {
                seed_fraction *= 0.5;
                continue;
            }
            if (group_residual.residualAt(grid, faces, active_properties, base, candidate, target, candidate_residual, scratch, trial_micro_flux, trial_macro_flux)) |_| {
                picard_seed_evaluated = true;
                if (numerics.andersonDepthOneCandidate(current, residual, candidate, candidate_residual, probe)) {
                    // The full Anderson extrapolate can cross a dry/saturated
                    // active bound by roundoff. Backtrack along the Anderson
                    // direction with one common fraction; this is a damped
                    // accelerated update, never component clipping or a raw
                    // fixed-point publication.
                    var fraction: f64 = 1;
                    var line: u8 = 0;
                    while (line < 16) : (line += 1) {
                        if (dampedAndersonStorageCandidate(grid, base, current, probe, fraction, best_candidate)) {
                            if (group_residual.residualAt(grid, faces, active_properties, base, best_candidate, target, probe_residual, scratch, trial_micro_flux, trial_macro_flux)) |_| {
                                const accelerated_norm = try group_residual.scaledNorm(best_candidate, probe_residual, options);
                                if (numerics.andersonImprovesAcceptedMerit(accelerated_norm, current_norm)) {
                                    @memcpy(candidate, best_candidate);
                                    used_anderson = true;
                                    break;
                                }
                            } else |_| {}
                        }
                        fraction *= 0.75;
                    }
                }
            } else |_| {}
            seed_fraction *= 0.5;
        }
        if (!used_anderson and options.anderson_recovery and history_count > 0 and picard_seed_evaluated) priced: {
            // The private Picard sample must be evaluable before its secant can
            // be used, but its merit never competes with a publishable state.
            var numerator: f64 = 0;
            var denominator: f64 = 0;
            for (residual, previous_residual) |current_value, previous_value| {
                const change = current_value - previous_value;
                numerator += current_value * change;
                denominator += change * change;
            }
            if (!std.math.isFinite(denominator) or denominator <= std.math.floatEps(f64)) break :priced;
            const mixing = numerator / denominator;
            if (!std.math.isFinite(mixing)) break :priced;
            for (current, residual, previous_state, previous_residual, probe) |value, value_residual, old_value, old_residual, *next| {
                const fixed_point = value + value_residual;
                const old_fixed_point = old_value + old_residual;
                next.* = fixed_point - mixing * (fixed_point - old_fixed_point);
            }
            var fraction: f64 = 1;
            var line: u8 = 0;
            while (line < 16) : (line += 1) {
                if (dampedAndersonStorageCandidate(grid, base, current, probe, fraction, best_candidate)) {
                    if (group_residual.residualAt(grid, faces, active_properties, base, best_candidate, target, probe_residual, scratch, trial_micro_flux, trial_macro_flux)) |_| {
                        const accelerated_norm = group_residual.scaledNorm(best_candidate, probe_residual, options) catch break :priced;
                        if (numerics.andersonImprovesAcceptedMerit(accelerated_norm, current_norm)) {
                            @memcpy(candidate, best_candidate);
                            used_anderson = true;
                            break;
                        }
                    } else |_| {}
                }
                fraction *= 0.75;
            }
        }
        if (!used_anderson) {
            if (forecast_requires_anderson and
                !stagnation_requires_anderson)
            {
                // The forecast only prices recovery; it does not prove that
                // Newton is invalid. A rejected Anderson probe consumes this
                // counted slot, then the next slot retries Newton. Reprice only
                // after that accepted Newton state changes the trajectory.
                rejected_forecast_recovery_step = newton_steps;
                continue;
            }
            if (!builtin.is_test) {
                const domain: []const u8 = if (limiting_component < cells)
                    "matrix"
                else
                    "macropore";
                const cell = limiting_component % cells;
                std.log.warn(
                    "soil water solver stagnated: iteration={d} scaled_residual={e} limiting_domain={s} limiting_cell={d} state_m3={e} residual_m3={e} nonlinear_time_fraction={e} newton_steps={d} anderson_steps={d}",
                    .{
                        iteration + 1,
                        current_norm,
                        domain,
                        cell,
                        current[limiting_component],
                        residual[limiting_component],
                        properties.nonlinear_time_fraction,
                        newton_steps,
                        picard_steps,
                    },
                );
            }
            return error.SoilWaterSolverStagnated;
        }
        // Recovery consumes this counted iteration and also requires one
        // remaining counted iteration for the mandatory Newton retry.
        if (iteration + 1 >= options.max_iterations) {
            if (control.trace) |trace| trace.record(.anderson_rejected_no_retry);
            return error.SoilWaterSolverDidNotConverge;
        }
        group_residual.rememberIteration(current, residual, previous_state, previous_residual, previous_previous_state, previous_previous_residual, &history_count);
        @memcpy(current, candidate);
        dense_jacobian_ready = false;
        dense_jacobian_reuse_age = 0;
        newton_retry_required = true;
        slow_newton_norm_count = 0;
        rejected_forecast_recovery_step = null;
        if (control.trace) |trace| trace.record(.anderson_accept);
        // Compatibility counter: every increment represents an accepted
        // Anderson candidate; no unaccelerated fixed-point state is accepted.
        picard_steps += 1;
    }
    // Fail closed if future loop edits ever bypass the explicit retry-budget
    // guard above; an Anderson state cannot reach the publication gate while
    // it still owns a pending Newton retry.
    if (newton_retry_required) return error.SoilWaterSolverDidNotConverge;
    try group_residual.residualAt(grid, faces, active_properties, base, current, target, residual, scratch, trial_micro_flux, trial_macro_flux);
    const final_norm = try group_residual.scaledNorm(current, residual, options);
    if (failure_norm_trace_len < failure_norm_trace.len) {
        failure_norm_trace[failure_norm_trace_len] = final_norm;
        failure_norm_trace_len += 1;
    }
    var final_conservation_diagnostic: LocalConservationDiagnostic = .{};
    var final_publication_state: []const f64 = current;
    var final_conservation_accepted = final_norm <= 1 and try localConservationAccepted(grid, faces, active_properties, base, current, residual, trial_micro_flux, trial_macro_flux, layer_internal_input_m3, layer_internal_output_m3, cell_internal_input_m3, cell_internal_output_m3, options, &final_conservation_diagnostic);
    if (final_norm <= 1 and !final_conservation_accepted and boundedConservativeMapCorrection(current, target, options)) {
        @memset(candidate, 0);
        final_conservation_accepted = try localConservationAccepted(grid, faces, active_properties, base, target, candidate, trial_micro_flux, trial_macro_flux, layer_internal_input_m3, layer_internal_output_m3, cell_internal_input_m3, cell_internal_output_m3, options, null);
        if (final_conservation_accepted) final_publication_state = target;
    }
    if (final_conservation_accepted) {
        try group_flux.state_update(grid, properties, final_publication_state);
        @memcpy(micropore_face_flux_m3_per_step, trial_micro_flux);
        @memcpy(macropore_face_flux_m3_per_step, trial_macro_flux);
        if (properties.artificial_drainage_outflow_m3_per_step) |published|
            @memcpy(published, trial_artificial_drainage.?);
        if (properties.boundary_water_exchange_m3_per_step) |published|
            @memcpy(published, trial_boundary_exchange.?);
        if (properties.boundary_water_exchange_m3_per_layer_per_step) |published|
            @memcpy(published, trial_boundary_exchange_by_layer.?);
        publishDenseJacobianCache(
            properties.dense_jacobian_cache,
            jacobian,
            components,
            dense_jacobian_ready,
            dense_jacobian_reuse_age,
        );
        if (control.trace) |trace| trace.record(.publish);
        return .{ .iterations = options.max_iterations, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = picard_steps, .maximum_scaled_residual = final_norm, .dense_jacobian_assemblies = dense_jacobian_assemblies, .dense_jacobian_reuses = dense_jacobian_reuses, .dense_jacobian_cache_supplied = properties.dense_jacobian_cache != null, .dense_jacobian_cache_loaded = dense_jacobian_cache_loaded, .dense_jacobian_ready_at_publication = dense_jacobian_ready, .conservative_map_publication = final_publication_state.ptr != current.ptr, .dense_jacobian_cache_published = if (properties.dense_jacobian_cache) |cache| cache.valid else false, .richards_face_flux_cache_hits = face_flux_cache.hits, .richards_face_flux_cache_misses = face_flux_cache.misses };
    }
    // The runtime ceiling counts nonlinear state updates, not merely outer
    // loop labels. Historical post-loop coordinate/trust-region sweeps below
    // could perform hundreds of hidden updates while still reporting
    // `iterations = max_iterations`. Once the final permitted update has not
    // converged, fail atomically so the hourly transaction can retry using a
    // scientifically scaled internal substep.
    if (!builtin.is_test) {
        switch (final_conservation_diagnostic.kind) {
            .none => {},
            .layer => std.log.err(
                "soil water local conservation rejected after nonlinear convergence: cell={d} layer={d} layer_index={d} storage_before_m3={e} storage_after_m3={e} internal_input_m3={e} internal_output_m3={e} source_m3={e} boundary_gain_m3={e} matrix_residual_m3={e} macropore_residual_m3={e} closure_residual_m3={e} ledger_identity_residual_m3={e} ledger_identity_limit_m3={e} normalized_relative={e} acceptance_limit_m3={e} provenance={s}",
                .{
                    final_conservation_diagnostic.cell,
                    final_conservation_diagnostic.layer_offset,
                    final_conservation_diagnostic.layer,
                    final_conservation_diagnostic.storage_before_m3,
                    final_conservation_diagnostic.storage_after_m3,
                    final_conservation_diagnostic.internal_input_m3,
                    final_conservation_diagnostic.internal_output_m3,
                    final_conservation_diagnostic.source_m3,
                    final_conservation_diagnostic.boundary_gain_m3,
                    final_conservation_diagnostic.matrix_residual_m3,
                    final_conservation_diagnostic.macropore_residual_m3,
                    final_conservation_diagnostic.closure_residual_m3,
                    final_conservation_diagnostic.ledger_identity_residual_m3,
                    final_conservation_diagnostic.ledger_identity_limit_m3,
                    final_conservation_diagnostic.normalized_relative,
                    final_conservation_diagnostic.acceptance_limit_m3,
                    if (@abs(final_conservation_diagnostic.ledger_identity_residual_m3) > final_conservation_diagnostic.ledger_identity_limit_m3)
                        "ledger_identity_mismatch"
                    else
                        "nonlinear_residual",
                },
            ),
            .cell => std.log.err(
                "soil water cell conservation rejected after nonlinear convergence: cell={d} storage_before_m3={e} storage_after_m3={e} cross_cell_input_m3={e} cross_cell_output_m3={e} source_m3={e} boundary_gain_m3={e} closure_residual_m3={e} ledger_identity_residual_m3={e} ledger_identity_limit_m3={e} normalized_relative={e} acceptance_limit_m3={e} provenance={s}",
                .{
                    final_conservation_diagnostic.cell,
                    final_conservation_diagnostic.storage_before_m3,
                    final_conservation_diagnostic.storage_after_m3,
                    final_conservation_diagnostic.internal_input_m3,
                    final_conservation_diagnostic.internal_output_m3,
                    final_conservation_diagnostic.source_m3,
                    final_conservation_diagnostic.boundary_gain_m3,
                    final_conservation_diagnostic.closure_residual_m3,
                    final_conservation_diagnostic.ledger_identity_residual_m3,
                    final_conservation_diagnostic.ledger_identity_limit_m3,
                    final_conservation_diagnostic.normalized_relative,
                    final_conservation_diagnostic.acceptance_limit_m3,
                    if (@abs(final_conservation_diagnostic.ledger_identity_residual_m3) > final_conservation_diagnostic.ledger_identity_limit_m3)
                        "ledger_identity_mismatch"
                    else
                        "nonlinear_residual",
                },
            ),
        }
        std.log.err(
            "soil water nonlinear ceiling exhausted: max_iterations={d} scaled_residual={e} nonlinear_time_fraction={e} newton_steps={d} anderson_steps={d} dense_line_steps={d} dense_trust_steps={d} domain_block_steps={d} spatial_block_steps={d} diagonal_steps={d} directional_steps={d} norm_trace={any}",
            .{
                options.max_iterations,
                final_norm,
                properties.nonlinear_time_fraction,
                newton_steps,
                picard_steps,
                dense_line_steps,
                dense_trust_steps,
                domain_block_steps,
                spatial_block_steps,
                diagonal_steps,
                directional_steps,
                failure_norm_trace[0..failure_norm_trace_len],
            },
        );
        var limiting_component: usize = 0;
        var limiting_component_norm: f64 = -1;
        for (current, residual, 0..) |state, difference, component| {
            const norm = group_residual.scaledComponentResidual(state, difference, options);
            if (norm > limiting_component_norm) {
                limiting_component_norm = norm;
                limiting_component = component;
            }
        }
        const limiting_cell = limiting_component % cells;
        const limiting_is_matrix = limiting_component < cells;
        std.log.err(
            "TEMP_DIAGNOSTIC soil water ceiling coordinate: domain={s} cell={d} component={d} component_scaled_residual={e} state_m3={e} base_m3={e} target_m3={e} residual_m3={e} tolerance_scale_m3={e} pore_capacity_m3={e} ice_water_m3={e}",
            .{
                if (limiting_is_matrix) "matrix" else "macropore",
                limiting_cell,
                limiting_component,
                limiting_component_norm,
                current[limiting_component],
                base[limiting_component],
                target[limiting_component],
                residual[limiting_component],
                options.absolute_tolerance_m3 + options.relative_tolerance * @abs(current[limiting_component]),
                if (limiting_is_matrix)
                    grid.matrix_pore_capacity_m3[limiting_cell]
                else
                    grid.macropore_pore_capacity_m3[limiting_cell],
                if (limiting_is_matrix)
                    grid.matrix_ice_water_m3[limiting_cell]
                else
                    grid.macropore_ice_water_m3[limiting_cell],
            },
        );
    }
    return error.SoilWaterSolverDidNotConverge;
}

fn boundedConservativeMapCorrection(
    current: []const f64,
    target: []const f64,
    options: group_types.Options,
) bool {
    if (current.len != target.len) return false;
    for (current, target) |value, mapped| {
        if (!std.math.isFinite(value) or value < 0 or
            !std.math.isFinite(mapped) or mapped < 0 or
            group_residual.scaledComponentResidual(value, mapped - value, options) > 1)
            return false;
    }
    return true;
}

test "conservative water map correction is bounded by nonlinear tolerance" {
    const options: group_types.Options = .{
        .max_iterations = 20,
        .absolute_tolerance_m3 = 1.0e-13,
        .relative_tolerance = 1.0e-8,
    };
    try std.testing.expect(boundedConservativeMapCorrection(
        &.{2.0514824628670227e-14},
        &.{5.841896965627101e-14},
        options,
    ));
    try std.testing.expect(!boundedConservativeMapCorrection(
        &.{2.0514824628670227e-14},
        &.{2.0e-13},
        options,
    ));
    try std.testing.expect(!boundedConservativeMapCorrection(
        &.{2.0514824628670227e-14},
        &.{-1.0e-14},
        options,
    ));
}

fn boundedDenseWorkspaceElements(
    component_count: usize,
    maximum_dense_components: usize,
) !usize {
    const dimension = @min(
        component_count,
        @min(maximum_dense_components, group_types.maximum_dense_newton_components),
    );
    return std.math.mul(usize, dimension, dimension);
}

fn denseNewtonEligible(
    component_count: usize,
    maximum_dense_components: usize,
) bool {
    return component_count <= @min(
        maximum_dense_components,
        group_types.maximum_dense_newton_components,
    );
}

test "soil water dense Newton eligibility is independent of iteration ceiling" {
    // The production solver used to add `iteration + 8 >= max_iterations` to
    // this predicate. That made a hard safety ceiling control algorithm order:
    // the same 24-component problem started coupled Newton at iteration 12
    // under a 20 ceiling but at iteration 92 under a 100 ceiling.
    try std.testing.expect(denseNewtonEligible(24, 256));
    try std.testing.expect(denseNewtonEligible(256, 256));
    try std.testing.expect(!denseNewtonEligible(257, 256));
    try std.testing.expect(!denseNewtonEligible(24, 0));
}

test "soil water dense workspaces stay bounded above the configured threshold" {
    try std.testing.expectEqual(
        @as(usize, 100),
        try boundedDenseWorkspaceElements(10, 256),
    );
    const at_large_grid = try boundedDenseWorkspaceElements(20_000, 256);
    const at_twice_large_grid = try boundedDenseWorkspaceElements(40_000, 256);
    try std.testing.expectEqual(@as(usize, 256 * 256), at_large_grid);
    try std.testing.expectEqual(at_large_grid, at_twice_large_grid);
    try std.testing.expectEqual(
        at_large_grid,
        try boundedDenseWorkspaceElements(40_000, std.math.maxInt(usize)),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try boundedDenseWorkspaceElements(20_000, 0),
    );
}

test "colored dense Richards Jacobian matches independent columns exactly" {
    const cell_count: usize = 4;
    const component_count: usize = 2 * cell_count;
    const config = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = cell_count, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-12, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    const matrix_water = [_]f64{ 0.35, 0.30, 0.25, 0.20 };
    const macropore_water = [_]f64{ 0.08, 0.06, 0.04, 0.02 };
    @memcpy(grid.matrix_liquid_water_m3, &matrix_water);
    @memcpy(grid.macropore_liquid_water_m3, &macropore_water);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_pore_capacity_m3, 0.1);

    const fixtures = @import("solver_fixtures.zig");
    const curves = [_]retention.ResolvedCurve{fixtures.testCurve()} ** cell_count;
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{fixtures.testMatrixMualemVanGenuchten()} ** cell_count;
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{fixtures.testMacroporeMualemVanGenuchten()} ** cell_count;
    const bulk = [_]f64{1} ** cell_count;
    const zero = [_]f64{0} ** cell_count;
    const thickness = [_]f64{0.1} ** cell_count;
    const spacing = [_]f64{0.2} ** cell_count;
    const radius = [_]f64{0.001} ** cell_count;
    const exchange_enabled = [_]bool{true} ** cell_count;
    const faces = [_]group_types.Face{
        .{ .source_cell = 0, .destination_cell = 1, .axis = .z, .direction = .vertical, .source_path_length_m = 0.05, .destination_path_length_m = 0.05, .face_area_m2 = 0.01 },
        .{ .source_cell = 1, .destination_cell = 2, .axis = .z, .direction = .vertical, .source_path_length_m = 0.05, .destination_path_length_m = 0.05, .face_area_m2 = 0.01 },
        .{ .source_cell = 2, .destination_cell = 3, .axis = .z, .direction = .vertical, .source_path_length_m = 0.05, .destination_path_length_m = 0.05, .face_area_m2 = 0.01 },
    };
    const properties: group_types.Properties = .{
        .matrix_bulk_volume_m3 = &bulk,
        .retention_curve = &curves,
        .mualem_van_genuchten_parameters = &matrix_parameters,
        .macropore_mualem_van_genuchten_parameters = &macropore_parameters,
        .macropore_spacing_m = &spacing,
        .macropore_radius_m = &radius,
        .dual_domain_exchange_enabled = &exchange_enabled,
        .gravitational_potential_megapascal = &zero,
        .osmotic_potential_megapascal = &zero,
        .vertical_thickness_m = &thickness,
        .osmotic_potential_multiplier = 1,
        .nonlinear_time_fraction = 0.25,
    };
    var cache = try richards_face_cache.Cache.init(std.testing.allocator, faces.len);
    defer cache.deinit(std.testing.allocator);
    var active_properties = properties;
    active_properties.richards_face_flux_cache = &cache;

    var base: [component_count]f64 = undefined;
    @memcpy(base[0..cell_count], &matrix_water);
    @memcpy(base[cell_count..], &macropore_water);
    const current = base;
    var residual: [component_count]f64 = undefined;
    var target: [component_count]f64 = undefined;
    var probe: [component_count]f64 = undefined;
    var probe_residual: [component_count]f64 = undefined;
    var candidate: [component_count]f64 = undefined;
    var candidate_residual: [component_count]f64 = undefined;
    var scratch: [component_count]f64 = undefined;
    var trial_micro_flux: [faces.len]f64 = undefined;
    var trial_macro_flux: [faces.len]f64 = undefined;
    try group_residual.residualAt(&grid, &faces, active_properties, &base, &current, &target, &residual, &scratch, &trial_micro_flux, &trial_macro_flux);
    try std.testing.expect(!cache.assembled_target_limit_observed);

    var colored_jacobian: [component_count * component_count]f64 = undefined;
    var micropore_parent: [cell_count]usize = undefined;
    var macropore_parent: [cell_count]usize = undefined;
    var micropore_component_size: [cell_count]usize = undefined;
    var macropore_component_size: [cell_count]usize = undefined;
    const phase: DenseJacobianPhase = .{
        .grid = &grid,
        .faces = &faces,
        .active_properties = active_properties,
        .properties = properties,
        .base = &base,
        .current = &current,
        .residual = &residual,
        .target = &target,
        .probe = &probe,
        .probe_residual = &probe_residual,
        .candidate = &candidate,
        .candidate_residual = &candidate_residual,
        .scratch = &scratch,
        .trial_micro_flux = &trial_micro_flux,
        .trial_macro_flux = &trial_macro_flux,
        .jacobian = &colored_jacobian,
        .micropore_parent = &micropore_parent,
        .macropore_parent = &macropore_parent,
        .micropore_component_size = &micropore_component_size,
        .macropore_component_size = &macropore_component_size,
        .cells = cell_count,
        .components = component_count,
    };
    try std.testing.expect(try tryAssembleColoredDenseJacobian(phase));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 0 }, &micropore_parent);

    var independent_jacobian: [component_count * component_count]f64 = undefined;
    for (0..component_count) |column| {
        const perturbation = group_newton.finiteDifferenceProbeM3(current[column], .central);
        @memcpy(&probe, &current);
        probe[column] += perturbation;
        try group_residual.residualAt(&grid, &faces, active_properties, &base, &probe, &target, &probe_residual, &scratch, &trial_micro_flux, &trial_macro_flux);
        @memcpy(&candidate, &current);
        candidate[column] -= perturbation;
        try group_residual.residualAt(&grid, &faces, active_properties, &base, &candidate, &target, &candidate_residual, &scratch, &trial_micro_flux, &trial_macro_flux);
        for (0..component_count) |row|
            independent_jacobian[row * component_count + column] =
                (probe_residual[row] - candidate_residual[row]) /
                (2 * perturbation);
    }
    try std.testing.expectEqualSlices(f64, &independent_jacobian, &colored_jacobian);
    cache.assembled_target_limit_observed = true;
    try std.testing.expect(!try tryAssembleColoredDenseJacobian(phase));
}

fn dampedAndersonStorageCandidate(
    grid: *const grid_module.GridState,
    base: []const f64,
    current: []const f64,
    accelerated: []const f64,
    fraction: f64,
    output: []f64,
) bool {
    const cells = grid.layer_count;
    if (base.len != 2 * cells or current.len != 2 * cells or accelerated.len != current.len or output.len != current.len or
        !std.math.isFinite(fraction) or fraction <= 0 or fraction > 1) return false;
    for (current, accelerated, output, 0..) |value, extrapolate, *candidate, component| {
        const cell = component % cells;
        const ceiling = if (component < cells)
            group_flux.acceptedEntryLiquidCeilingM3(grid.matrix_pore_capacity_m3[cell], base[component], grid.matrix_ice_water_m3[cell]) catch return false
        else
            group_flux.acceptedEntryLiquidCeilingM3(grid.macropore_pore_capacity_m3[cell], base[component], grid.macropore_ice_water_m3[cell]) catch return false;
        candidate.* = value + fraction * (extrapolate - value);
        if (!std.math.isFinite(candidate.*) or candidate.* < 0 or candidate.* > ceiling) return false;
    }
    return true;
}

fn scaledProgressIsInsufficient(best_norm: f64, current_norm: f64) bool {
    const progress_floor = std.math.sqrt(std.math.floatEps(f64)) * @max(1.0, best_norm);
    return !std.math.isFinite(best_norm) or !std.math.isFinite(current_norm) or
        best_norm - current_norm <= progress_floor;
}

fn scaledResidualDirectionsReverse(
    current: []const f64,
    residual: []const f64,
    previous: []const f64,
    previous_residual: []const f64,
    options: group_types.Options,
) bool {
    if (current.len == 0 or residual.len != current.len or previous.len != current.len or previous_residual.len != current.len) return false;
    var current_scale: f64 = 0;
    var previous_scale: f64 = 0;
    for (current, residual, previous, previous_residual) |state, value, old_state, old_value| {
        const scaled = value / (options.absolute_tolerance_m3 + options.relative_tolerance * @abs(state));
        const old_scaled = old_value / (options.absolute_tolerance_m3 + options.relative_tolerance * @abs(old_state));
        if (!std.math.isFinite(scaled) or !std.math.isFinite(old_scaled)) return false;
        current_scale = @max(current_scale, @abs(scaled));
        previous_scale = @max(previous_scale, @abs(old_scaled));
    }
    if (current_scale == 0 or previous_scale == 0) return false;
    var dot: f64 = 0;
    var current_norm_squared: f64 = 0;
    var previous_norm_squared: f64 = 0;
    for (current, residual, previous, previous_residual) |state, value, old_state, old_value| {
        const scaled = value /
            (options.absolute_tolerance_m3 + options.relative_tolerance * @abs(state)) /
            current_scale;
        const old_scaled = old_value /
            (options.absolute_tolerance_m3 + options.relative_tolerance * @abs(old_state)) /
            previous_scale;
        dot += scaled * old_scaled;
        current_norm_squared += scaled * scaled;
        previous_norm_squared += old_scaled * old_scaled;
    }
    const direction_scale = std.math.sqrt(current_norm_squared * previous_norm_squared);
    return std.math.isFinite(direction_scale) and direction_scale > 0 and
        dot < -std.math.sqrt(std.math.floatEps(f64)) * direction_scale;
}

test "soil water Anderson acceptance ignores private seed merit" {
    try std.testing.expect(numerics.andersonImprovesAcceptedMerit(0.8, 1.0));
    try std.testing.expect(!numerics.andersonImprovesAcceptedMerit(0.8, 0.75));
    try std.testing.expect(!numerics.andersonImprovesAcceptedMerit(std.math.nan(f64), 1.0));
    const options: group_types.Options = .{ .max_iterations = 2 };
    try std.testing.expect(scaledResidualDirectionsReverse(&.{ 1, 1 }, &.{ 1, -2 }, &.{ 1, 1 }, &.{ -1, 2 }, options));
    try std.testing.expect(!scaledResidualDirectionsReverse(&.{ 1, 1 }, &.{ 1, -2 }, &.{ 1, 1 }, &.{ 1, -2 }, options));
}

test "soil water slow-Newton forecast preserves the hard acceptance gate" {
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

test "soil water spatial Newton merit rejects raw improvement that worsens scaled norm" {
    const options: group_types.Options = .{
        .max_iterations = 2,
        .absolute_tolerance_m3 = 1.0e-12,
        .relative_tolerance = 1.0e-8,
    };
    const state = [_]f64{ 1.0e9, 1.0e-6 };
    const before = [_]f64{ 10.0, 1.0e-10 };
    const after = [_]f64{ 9.0, 2.0e-10 };
    const raw_before = @max(@abs(before[0]), @abs(before[1]));
    const raw_after = @max(@abs(after[0]), @abs(after[1]));
    const scaled_before = try group_residual.scaledNorm(&state, &before, options);
    const scaled_after = try group_residual.scaledNorm(&state, &after, options);
    try std.testing.expect(raw_after < raw_before);
    try std.testing.expect(scaled_after > scaled_before);
}

test "macropore dry-bound spatial retry is a strict Newton update" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-12, .max_nonlinear_iterations = 4 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.matrix_liquid_water_m3, 0.2);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_pore_capacity_m3, 0.1);

    const fixtures = @import("solver_fixtures.zig");
    const matrix_bulk = [_]f64{ 1, 1 };
    const curves = [_]@TypeOf(fixtures.testCurve()){ fixtures.testCurve(), fixtures.testCurve() };
    const matrix_parameters = [_]@TypeOf(fixtures.testMatrixMualemVanGenuchten()){
        fixtures.testMatrixMualemVanGenuchten(),
        fixtures.testMatrixMualemVanGenuchten(),
    };
    const macropore_parameters = [_]@TypeOf(fixtures.testMacroporeMualemVanGenuchten()){
        fixtures.testMacroporeMualemVanGenuchten(),
        fixtures.testMacroporeMualemVanGenuchten(),
    };
    const one = [_]f64{ 1, 1 };
    const zero = [_]f64{ 0, 0 };
    const disabled = [_]bool{ false, false };
    const properties: group_types.Properties = .{
        .matrix_bulk_volume_m3 = &matrix_bulk,
        .retention_curve = &curves,
        .mualem_van_genuchten_parameters = &matrix_parameters,
        .macropore_mualem_van_genuchten_parameters = &macropore_parameters,
        .macropore_spacing_m = &one,
        .macropore_radius_m = &zero,
        .dual_domain_exchange_enabled = &disabled,
        .gravitational_potential_megapascal = &zero,
        .osmotic_potential_megapascal = &zero,
        .vertical_thickness_m = &one,
        .osmotic_potential_multiplier = 1,
    };
    const faces = [_]group_types.Face{.{
        .source_cell = 0,
        .destination_cell = 1,
        .axis = .x,
        .direction = .horizontal,
        .source_path_length_m = 1,
        .destination_path_length_m = 1,
        // The zero-area face supplies the production spatial stencil while
        // isolating the dry-bound Newton coordinate from transport physics.
        .face_area_m2 = 0,
    }};
    const base = [_]f64{ 0.2, 0.2, 0, 0 };
    var current = [_]f64{ 0.2, 0.2, 3.232076435329251e-5, 0 };
    var target: [4]f64 = undefined;
    var residual: [4]f64 = undefined;
    var scratch: [4]f64 = undefined;
    var micro_flux = [_]f64{0};
    var macro_flux = [_]f64{0};
    try group_residual.residualAt(&grid, &faces, properties, &base, &current, &target, &residual, &scratch, &micro_flux, &macro_flux);
    try std.testing.expectApproxEqAbs(-current[2], residual[2], 0);
    const before_norm = try group_residual.scaledNorm(&current, &residual, .{ .max_iterations = 4 });

    var candidate: [4]f64 = undefined;
    var candidate_residual: [4]f64 = undefined;
    var probe: [4]f64 = undefined;
    var probe_residual: [4]f64 = undefined;
    var indices: [4]usize = undefined;
    var jacobian: [16]f64 = undefined;
    var right_hand_side: [4]f64 = undefined;
    try std.testing.expect(try group_newton.spatialDomainCellNewton(
        &grid,
        &faces,
        properties,
        &base,
        &current,
        &target,
        &residual,
        &scratch,
        &micro_flux,
        &macro_flux,
        2,
        &candidate,
        &candidate_residual,
        &probe,
        &probe_residual,
        &indices,
        &jacobian,
        &right_hand_side,
        .{ .max_iterations = 4 },
        false,
    ));
    try group_residual.residualAt(&grid, &faces, properties, &base, &current, &target, &residual, &scratch, &micro_flux, &macro_flux);
    const after_norm = try group_residual.scaledNorm(&current, &residual, .{ .max_iterations = 4 });
    try std.testing.expect(after_norm < before_norm);
    try std.testing.expect(current[2] >= 0);
    try std.testing.expect(current[2] < 3.232076435329251e-5);
}

test "soil water dimensionless slow-progress watch routes after finite patience" {
    const best_norm = 1.0e6;
    const floor = std.math.sqrt(std.math.floatEps(f64)) * best_norm;
    try std.testing.expect(scaledProgressIsInsufficient(best_norm, best_norm - 0.5 * floor));
    try std.testing.expect(!scaledProgressIsInsufficient(best_norm, best_norm - 2.0 * floor));
    const patience: u16 = 4;
    var insufficient_steps: u16 = 0;
    while (insufficient_steps < patience) {
        try std.testing.expect(scaledProgressIsInsufficient(best_norm, best_norm - 0.5 * floor));
        insufficient_steps += 1;
    }
    try std.testing.expectEqual(patience, insufficient_steps);
}

test "Anderson candidate admits accepted HOUR1 contraction but no added overfill" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-12, .max_nonlinear_iterations = 4 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.matrix_pore_capacity_m3[0] = 0.1;
    grid.macropore_pore_capacity_m3[0] = 0.1;
    const base = [_]f64{ 0.2, 0.05 };
    const current = base;
    var candidate: [2]f64 = undefined;
    try std.testing.expect(dampedAndersonStorageCandidate(&grid, &base, &current, &.{ 0.15, 0.05 }, 1, &candidate));
    try std.testing.expectEqual(@as(f64, 0.15), candidate[0]);
    try std.testing.expect(!dampedAndersonStorageCandidate(&grid, &base, &current, &.{ 0.21, 0.05 }, 1, &candidate));
}

test "soil water forced Newton failure follows Newton Anderson Newton with hard ceiling" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-12, .max_nonlinear_iterations = 2 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.2;
    grid.matrix_pore_capacity_m3[0] = 0.5;
    grid.macropore_liquid_water_m3[0] = 0;
    grid.macropore_pore_capacity_m3[0] = 0.1;
    // Exact production-shaped dry-bound regression: the full Anderson
    // extrapolate is negative only by roundoff, while a common 0.75 damping
    // remains inside the bound and improves on the relaxed half-step seed.
    const dry_current = [_]f64{ 0.2, 3.232076435329251e-5 };
    const dry_accelerated = [_]f64{ 0.2, -1.0e-18 };
    var dry_candidate: [2]f64 = undefined;
    try std.testing.expect(!dampedAndersonStorageCandidate(&grid, &dry_current, &dry_current, &dry_accelerated, 1, &dry_candidate));
    try std.testing.expect(dampedAndersonStorageCandidate(&grid, &dry_current, &dry_current, &dry_accelerated, 0.75, &dry_candidate));
    try std.testing.expect(dry_candidate[1] > 0);
    try std.testing.expect(dry_candidate[1] < 0.5 * dry_current[1]);
    const fixtures = @import("solver_fixtures.zig");
    const properties: group_types.Properties = .{
        .matrix_bulk_volume_m3 = &.{1},
        .retention_curve = &.{fixtures.testCurve()},
        .mualem_van_genuchten_parameters = &.{fixtures.testMatrixMualemVanGenuchten()},
        .macropore_mualem_van_genuchten_parameters = &.{fixtures.testMacroporeMualemVanGenuchten()},
        .macropore_spacing_m = &.{1},
        .macropore_radius_m = &.{0},
        .dual_domain_exchange_enabled = &.{false},
        .gravitational_potential_megapascal = &.{0},
        .osmotic_potential_megapascal = &.{0},
        .matrix_external_source_m3_per_step = &.{0.03},
        .vertical_thickness_m = &.{1},
        .osmotic_potential_multiplier = 1,
    };
    var no_retry_trace: MethodTrace = .{};
    try std.testing.expectError(error.SoilWaterSolverDidNotConverge, solveControlled(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        &.{},
        &.{},
        .{ .max_iterations = 1 },
        .{ .forced_initial_newton_failures = 1, .trace = &no_retry_trace },
    ));
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), grid.matrix_liquid_water_m3[0], 0);
    try std.testing.expectEqualSlices(MethodEvent, &.{ .newton_attempt, .anderson_rejected_no_retry }, no_retry_trace.events[0..no_retry_trace.len]);

    var retry_trace: MethodTrace = .{};
    const result = try solveControlled(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        &.{},
        &.{},
        .{ .max_iterations = 2 },
        .{ .forced_initial_newton_failures = 1, .trace = &retry_trace },
    );
    try std.testing.expectEqual(@as(u16, 2), result.iterations);
    try std.testing.expectEqual(@as(u16, 1), result.anderson_steps);
    try std.testing.expectEqual(result.anderson_steps, result.picard_steps);
    try std.testing.expect(result.newton_raphson_steps + result.anderson_steps <= result.iterations);
    try std.testing.expectApproxEqAbs(@as(f64, 0.23), grid.matrix_liquid_water_m3[0], 1.0e-12);
    try std.testing.expectEqualSlices(MethodEvent, &.{ .newton_attempt, .anderson_accept, .newton_attempt, .publish }, retry_trace.events[0..retry_trace.len]);

    // Production-shaped lower-bound case: a free-draining dry macropore is
    // donor-limited to exactly its current store, reproducing residual=-state.
    var site = try @import("../../state/site.zig").parse(std.testing.allocator, @import("../../core/test_fixtures.zig").site_source, 1, 1);
    defer site.deinit();
    var topography = try @import("../../state/topography.zig").fromUnits(std.testing.allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1 }});
    defer topography.deinit();
    var terrain = try @import("../../state/terrain_hydrology.zig").State.initMapped(std.testing.allocator, topography, &.{0}, &.{1}, &.{1}, 1, 1);
    defer terrain.deinit();
    var topology = try boundary_topology.State.initMapped(std.testing.allocator, &grid, &terrain, 1, 1, &.{1}, &.{1}, &.{site});
    defer topology.deinit();
    for (topology.faces) |*boundary_face|
        boundary_face.natural_exchange_fraction = if (boundary_face.is_lower_boundary) 1 else 0;
    grid.matrix_liquid_water_m3[0] = 0.2;
    grid.macropore_liquid_water_m3[0] = 3.232076435329251e-5;
    const one = [_]f64{1};
    const zero = [_]f64{0};
    const thickness = [_]f64{0.1};
    var rejected_artificial_drainage = [_]f64{37};
    var rejected_boundary_exchange = [_]f64{42};
    var bound_properties = properties;
    bound_properties.matrix_external_source_m3_per_step = &zero;
    bound_properties.boundary_topology = &topology;
    bound_properties.boundary_face_area_m2 = &one;
    bound_properties.boundary_macropore_hydraulic_conductivity_m2_per_h_megapascal = &one;
    bound_properties.boundary_layer_volume_m3 = &one;
    bound_properties.boundary_layer_midpoint_depth_m = &thickness;
    bound_properties.boundary_layer_bottom_depth_m = &one;
    bound_properties.artificial_drainage_outflow_m3_per_step = &rejected_artificial_drainage;
    bound_properties.boundary_water_exchange_m3_per_step = &rejected_boundary_exchange;
    var dry_no_retry_trace: MethodTrace = .{};
    try std.testing.expectError(error.SoilWaterSolverDidNotConverge, solveControlled(
        std.testing.allocator,
        &grid,
        &.{},
        bound_properties,
        &.{},
        &.{},
        .{ .max_iterations = 1 },
        .{ .forced_initial_newton_failures = 1, .trace = &dry_no_retry_trace },
    ));
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), grid.matrix_liquid_water_m3[0], 0);
    try std.testing.expectApproxEqAbs(@as(f64, 3.232076435329251e-5), grid.macropore_liquid_water_m3[0], 0);
    try std.testing.expectEqual(@as(f64, 37), rejected_artificial_drainage[0]);
    try std.testing.expectEqual(@as(f64, 42), rejected_boundary_exchange[0]);
    try std.testing.expectEqualSlices(MethodEvent, &.{ .newton_attempt, .anderson_rejected_no_retry }, dry_no_retry_trace.events[0..dry_no_retry_trace.len]);

    var dry_trace: MethodTrace = .{};
    const dry_result = try solveControlled(
        std.testing.allocator,
        &grid,
        &.{},
        bound_properties,
        &.{},
        &.{},
        .{ .max_iterations = 2 },
        .{ .forced_initial_newton_failures = 1, .trace = &dry_trace },
    );
    try std.testing.expectEqual(@as(u16, 1), dry_result.anderson_steps);
    try std.testing.expectEqual(dry_result.anderson_steps, dry_result.picard_steps);
    try std.testing.expect(grid.macropore_liquid_water_m3[0] >= 0);
    try std.testing.expect(grid.macropore_liquid_water_m3[0] < 3.232076435329251e-5);
    try std.testing.expectEqualSlices(MethodEvent, &.{ .newton_attempt, .anderson_accept, .newton_attempt, .publish }, dry_trace.events[0..dry_trace.len]);
}

/// Solves the shared runtime topology and publishes converged FLWM/FLWHM
/// directly to the water and solute transport views.
pub fn solveAndBindTransportFaces(allocator: std.mem.Allocator, grid: *grid_module.GridState, hydrology: *transport_hydrology.State, shared_faces: *transport_hydrology.SoilFaces, geometry: group_types.FaceGeometry, properties: group_types.Properties, options: group_types.Options) !group_types.Result {
    const count = shared_faces.micropore_faces.len;
    if (shared_faces.macropore_faces.len != count or shared_faces.direction_axis.len != count or geometry.source_path_length_m.len != count or geometry.destination_path_length_m.len != count or geometry.face_area_m2.len != count) return error.SoilWaterFaceGeometryDimensionMismatch;
    const faces = try allocator.alloc(group_types.Face, count);
    defer allocator.free(faces);
    for (faces, 0..) |*face, index| {
        const axis: group_types.Axis = @enumFromInt(shared_faces.direction_axis[index]);
        face.* = .{ .active = shared_faces.active_by_face[index], .source_cell = shared_faces.micropore_faces[index].first_cell, .destination_cell = shared_faces.micropore_faces[index].second_cell, .axis = axis, .direction = if (axis == .z) .vertical else .horizontal, .source_path_length_m = geometry.source_path_length_m[index], .destination_path_length_m = geometry.destination_path_length_m[index], .face_area_m2 = geometry.face_area_m2[index] };
    }
    const artificial_drainage = try allocator.alloc(f64, grid.cell_count);
    defer allocator.free(artificial_drainage);
    @memset(artificial_drainage, 0);
    const boundary_water_exchange = try allocator.alloc(f64, grid.cell_count);
    defer allocator.free(boundary_water_exchange);
    @memset(boundary_water_exchange, 0);
    const boundary_water_exchange_by_layer = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(boundary_water_exchange_by_layer);
    @memset(boundary_water_exchange_by_layer, 0);
    var active_properties = properties;
    active_properties.active_by_layer = shared_faces.active_by_layer;
    active_properties.artificial_drainage_outflow_m3_per_step = artificial_drainage;
    active_properties.boundary_water_exchange_m3_per_step = boundary_water_exchange;
    active_properties.boundary_water_exchange_m3_per_layer_per_step = boundary_water_exchange_by_layer;
    const result = try solve(allocator, grid, faces, active_properties, shared_faces.micropore_water_flux_m3_per_step, shared_faces.macropore_water_flux_m3_per_step, options);
    @memcpy(hydrology.micropore_water_volume_m3, grid.matrix_liquid_water_m3);
    @memcpy(hydrology.macropore_water_volume_m3, grid.macropore_liquid_water_m3);
    @memcpy(hydrology.matrix_air_volume_m3, grid.matrix_air_volume_m3);
    @memcpy(hydrology.macropore_air_volume_m3, grid.macropore_air_volume_m3);
    @memcpy(hydrology.air_volume_m3, grid.air_volume_m3);
    @memcpy(hydrology.artificial_drainage_outflow_m3_per_step, artificial_drainage);
    @memcpy(hydrology.boundary_water_exchange_m3_per_step, boundary_water_exchange);
    @memcpy(hydrology.boundary_water_exchange_m3_per_layer_per_step, boundary_water_exchange_by_layer);
    @memset(hydrology.micropore_face_flux_m3_per_step, 0);
    @memset(hydrology.macropore_face_flux_m3_per_step, 0);
    for (shared_faces.micropore_faces, shared_faces.macropore_faces, shared_faces.direction_axis, shared_faces.active_by_face, shared_faces.micropore_water_flux_m3_per_step, shared_faces.macropore_water_flux_m3_per_step) |*micro_face, *macro_face, axis, active, micro, macro| {
        const published_micro = if (active) micro else 0;
        const published_macro = if (active) macro else 0;
        micro_face.water_flux_m3_per_step = published_micro;
        macro_face.water_flux_m3_per_step = published_macro;
        hydrology.micropore_face_flux_m3_per_step[micro_face.first_cell * 3 + axis] = published_micro;
        hydrology.macropore_face_flux_m3_per_step[macro_face.first_cell * 3 + axis] = published_macro;
    }
    try hydrology.validateFinite();
    return result;
}

const LocalConservationFailureKind = enum { none, layer, cell };

const LocalConservationDiagnostic = struct {
    kind: LocalConservationFailureKind = .none,
    cell: usize = 0,
    layer_offset: usize = 0,
    layer: usize = 0,
    storage_before_m3: f64 = 0,
    storage_after_m3: f64 = 0,
    internal_input_m3: f64 = 0,
    internal_output_m3: f64 = 0,
    source_m3: f64 = 0,
    boundary_gain_m3: f64 = 0,
    matrix_residual_m3: f64 = 0,
    macropore_residual_m3: f64 = 0,
    closure_residual_m3: f64 = 0,
    ledger_identity_residual_m3: f64 = 0,
    ledger_identity_limit_m3: f64 = 0,
    normalized_relative: f64 = 0,
    acceptance_limit_m3: f64 = 0,
};

fn recordLocalConservationFaceFlux(
    layer_internal_input_m3: []f64,
    layer_internal_output_m3: []f64,
    cell_internal_input_m3: []f64,
    cell_internal_output_m3: []f64,
    soil_layer_capacity: usize,
    source_layer: usize,
    destination_layer: usize,
    flux_m3: f64,
) !void {
    if (soil_layer_capacity == 0 or
        source_layer >= layer_internal_input_m3.len or
        source_layer >= layer_internal_output_m3.len or
        destination_layer >= layer_internal_input_m3.len or
        destination_layer >= layer_internal_output_m3.len or
        !std.math.isFinite(flux_m3))
        return error.InvalidSoilWaterConservationFace;
    const source_cell = source_layer / soil_layer_capacity;
    const destination_cell = destination_layer / soil_layer_capacity;
    if (source_cell >= cell_internal_input_m3.len or
        source_cell >= cell_internal_output_m3.len or
        destination_cell >= cell_internal_input_m3.len or
        destination_cell >= cell_internal_output_m3.len)
        return error.InvalidSoilWaterConservationFace;

    if (flux_m3 >= 0) {
        layer_internal_output_m3[source_layer] += flux_m3;
        layer_internal_input_m3[destination_layer] += flux_m3;
        if (source_cell != destination_cell) {
            cell_internal_output_m3[source_cell] += flux_m3;
            cell_internal_input_m3[destination_cell] += flux_m3;
        }
    } else {
        layer_internal_input_m3[source_layer] -= flux_m3;
        layer_internal_output_m3[destination_layer] -= flux_m3;
        if (source_cell != destination_cell) {
            cell_internal_input_m3[source_cell] -= flux_m3;
            cell_internal_output_m3[destination_cell] -= flux_m3;
        }
    }
}

test "soil water cell conservation keeps gross cross-cell activity and excludes vertical faces" {
    var layer_input = [_]f64{ 0, 0, 0, 0 };
    var layer_output = [_]f64{ 0, 0, 0, 0 };
    var cell_input = [_]f64{ 0, 0 };
    var cell_output = [_]f64{ 0, 0 };

    // Same-column vertical transport is external to each layer but internal
    // to the owning grid cell.
    try recordLocalConservationFaceFlux(&layer_input, &layer_output, &cell_input, &cell_output, 2, 0, 1, 1000);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, &cell_input);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, &cell_output);

    // Opposing lateral pore-domain transfers nearly cancel in cell storage,
    // but both directions remain part of the cell transaction throughput.
    try recordLocalConservationFaceFlux(&layer_input, &layer_output, &cell_input, &cell_output, 2, 1, 3, 600);
    try recordLocalConservationFaceFlux(&layer_input, &layer_output, &cell_input, &cell_output, 2, 1, 3, -590);
    try std.testing.expectEqualSlices(f64, &.{ 590, 600 }, &cell_input);
    try std.testing.expectEqualSlices(f64, &.{ 600, 590 }, &cell_output);

    const within = try group_conserved.richardsLayerClosure(100, 90 + 5.0e-7, cell_input[0], cell_output[0], 0, 0, 0, 0, 1.0e-9);
    try std.testing.expect(within.accepted);
    try std.testing.expectApproxEqAbs(@as(f64, 1190), within.normalization_scale, 0);
    const outside = try group_conserved.richardsLayerClosure(100, 90 + 5.0e-6, cell_input[0], cell_output[0], 0, 0, 0, 0, 1.0e-9);
    try std.testing.expect(!outside.accepted);
}

fn localConservationAccepted(
    grid: *const grid_module.GridState,
    faces: []const group_types.Face,
    properties: group_types.Properties,
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    micropore_face_flux_m3_per_step: []const f64,
    macropore_face_flux_m3_per_step: []const f64,
    layer_internal_input_m3: []f64,
    layer_internal_output_m3: []f64,
    cell_internal_input_m3: []f64,
    cell_internal_output_m3: []f64,
    options: group_types.Options,
    diagnostic: ?*LocalConservationDiagnostic,
) !bool {
    if (diagnostic) |value| value.* = .{};
    if (options.cell_area_m2.len == 0) return true;
    const cells = grid.layer_count;
    const exchange = properties.boundary_water_exchange_m3_per_step orelse
        return error.MissingBoundaryWaterExchangeForConvergence;
    const exchange_by_layer = properties.boundary_water_exchange_m3_per_layer_per_step orelse
        return error.MissingBoundaryWaterExchangeLayerForConvergence;
    if (layer_internal_input_m3.len != cells or
        layer_internal_output_m3.len != cells or
        cell_internal_input_m3.len != grid.cell_count or
        cell_internal_output_m3.len != grid.cell_count)
        return error.SoilWaterConservationLayerDimensionMismatch;
    @memset(layer_internal_input_m3, 0);
    @memset(layer_internal_output_m3, 0);
    @memset(cell_internal_input_m3, 0);
    @memset(cell_internal_output_m3, 0);
    for (faces, micropore_face_flux_m3_per_step, macropore_face_flux_m3_per_step) |face, micro, macro| {
        if (!face.active) continue;
        inline for (.{ micro, macro }) |flux_m3| {
            try recordLocalConservationFaceFlux(
                layer_internal_input_m3,
                layer_internal_output_m3,
                cell_internal_input_m3,
                cell_internal_output_m3,
                grid.soil_layer_capacity,
                face.source_cell,
                face.destination_cell,
                flux_m3,
            );
        }
    }
    for (0..grid.cell_count) |cell| {
        var cell_storage_before_m3: f64 = 0;
        var cell_storage_after_m3: f64 = 0;
        var cell_source_m3: f64 = 0;
        var cell_boundary_input_m3: f64 = 0;
        var cell_boundary_output_m3: f64 = 0;
        var combined_nonlinear_residual_m3: f64 = 0;
        for (0..grid.active_soil_layer_count[cell]) |layer_offset| {
            const layer = try grid.layerIndex(cell, layer_offset);
            const source_m3 = if ((properties.active_by_layer.len == 0 or properties.active_by_layer[layer]) and
                properties.matrix_external_source_m3_per_step.len != 0)
                properties.matrix_external_source_m3_per_step[layer]
            else
                0;
            const before_m3 = base[layer] + base[cells + layer];
            const after_m3 = current[layer] + current[cells + layer];
            const layer_closure = try group_conserved.richardsLayerClosure(
                before_m3,
                after_m3,
                layer_internal_input_m3[layer],
                layer_internal_output_m3[layer],
                source_m3,
                @max(0, exchange_by_layer[layer]),
                @max(0, -exchange_by_layer[layer]),
                options.conservation_absolute_tolerance_m * options.cell_area_m2[cell],
                options.conservation_relative_tolerance,
            );
            // The residual identity is checked independently at every layer
            // before the cell reduction below. This prevents equal and
            // opposite nonlinear truncation errors from reaching publication.
            if (!layer_closure.accepted) {
                if (diagnostic) |value| {
                    const matrix_residual_m3 = residual[layer];
                    const macropore_residual_m3 = residual[cells + layer];
                    const ledger_identity_residual_m3 = layer_closure.residual +
                        matrix_residual_m3 + macropore_residual_m3;
                    const identity_scale_m3 = @max(
                        @max(
                            @max(@abs(before_m3), @abs(after_m3)),
                            @max(layer_internal_input_m3[layer], layer_internal_output_m3[layer]),
                        ),
                        @max(
                            @max(@abs(source_m3), @abs(exchange_by_layer[layer])),
                            @max(@abs(matrix_residual_m3), @abs(macropore_residual_m3)),
                        ),
                    );
                    value.* = .{
                        .kind = .layer,
                        .cell = cell,
                        .layer_offset = layer_offset,
                        .layer = layer,
                        .storage_before_m3 = before_m3,
                        .storage_after_m3 = after_m3,
                        .internal_input_m3 = layer_internal_input_m3[layer],
                        .internal_output_m3 = layer_internal_output_m3[layer],
                        .source_m3 = source_m3,
                        .boundary_gain_m3 = exchange_by_layer[layer],
                        .matrix_residual_m3 = matrix_residual_m3,
                        .macropore_residual_m3 = macropore_residual_m3,
                        .closure_residual_m3 = layer_closure.residual,
                        .ledger_identity_residual_m3 = ledger_identity_residual_m3,
                        .ledger_identity_limit_m3 = 4096 * std.math.floatEps(f64) * identity_scale_m3,
                        .normalized_relative = layer_closure.normalized_relative,
                        .acceptance_limit_m3 = layer_closure.acceptance_limit,
                    };
                }
                return false;
            }
            cell_storage_before_m3 += before_m3;
            cell_storage_after_m3 += after_m3;
            cell_source_m3 += source_m3;
            cell_boundary_input_m3 += @max(0, exchange_by_layer[layer]);
            cell_boundary_output_m3 += @max(0, -exchange_by_layer[layer]);
            combined_nonlinear_residual_m3 += residual[layer] + residual[cells + layer];
        }
        const boundary_gain_m3 = cell_boundary_input_m3 - cell_boundary_output_m3;
        const partition_scale_m3 = @max(
            @abs(exchange[cell]),
            @max(cell_boundary_input_m3, cell_boundary_output_m3),
        );
        if (@abs(boundary_gain_m3 - exchange[cell]) >
            128 * std.math.floatEps(f64) * partition_scale_m3)
        {
            if (!builtin.is_test) std.log.err("Richards solver boundary partition mismatch: cell={d} layer_net_m3={e} cell_aggregate_m3={e} input_m3={e} output_m3={e} difference_m3={e} arithmetic_limit_m3={e}", .{ cell, boundary_gain_m3, exchange[cell], cell_boundary_input_m3, cell_boundary_output_m3, boundary_gain_m3 - exchange[cell], 128 * std.math.floatEps(f64) * partition_scale_m3 });
            return error.BoundaryWaterLayerPartitionMismatch;
        }
        const cell_closure = try group_conserved.richardsLayerClosure(
            cell_storage_before_m3,
            cell_storage_after_m3,
            cell_internal_input_m3[cell],
            cell_internal_output_m3[cell],
            cell_source_m3,
            cell_boundary_input_m3,
            cell_boundary_output_m3,
            options.conservation_absolute_tolerance_m * options.cell_area_m2[cell],
            options.conservation_relative_tolerance,
        );
        if (!cell_closure.accepted) {
            if (diagnostic) |value| {
                const ledger_identity_residual_m3 = cell_closure.residual +
                    combined_nonlinear_residual_m3;
                const identity_scale_m3 = @max(
                    @max(@abs(cell_storage_before_m3), @abs(cell_storage_after_m3)),
                    @max(
                        @max(cell_internal_input_m3[cell], cell_internal_output_m3[cell]),
                        @max(
                            @max(cell_source_m3, cell_boundary_input_m3),
                            @max(cell_boundary_output_m3, @abs(combined_nonlinear_residual_m3)),
                        ),
                    ),
                );
                value.* = .{
                    .kind = .cell,
                    .cell = cell,
                    .storage_before_m3 = cell_storage_before_m3,
                    .storage_after_m3 = cell_storage_after_m3,
                    .internal_input_m3 = cell_internal_input_m3[cell],
                    .internal_output_m3 = cell_internal_output_m3[cell],
                    .source_m3 = cell_source_m3,
                    .boundary_gain_m3 = boundary_gain_m3,
                    .closure_residual_m3 = cell_closure.residual,
                    .ledger_identity_residual_m3 = ledger_identity_residual_m3,
                    .ledger_identity_limit_m3 = 4096 * std.math.floatEps(f64) * identity_scale_m3,
                    .normalized_relative = cell_closure.normalized_relative,
                    .acceptance_limit_m3 = cell_closure.acceptance_limit,
                };
            }
            return false;
        }
    }
    return true;
}

fn validateInputs(grid: *const grid_module.GridState, faces: []const group_types.Face, properties: group_types.Properties, micro_flux: []const f64, macro_flux: []const f64, options: group_types.Options) !void {
    const cells = grid.layer_count;
    if (properties.matrix_bulk_volume_m3.len != cells or properties.retention_curve.len != cells or properties.mualem_van_genuchten_parameters.len != cells or properties.macropore_mualem_van_genuchten_parameters.len != cells or (properties.dual_domain_exchange_enabled.len != 0 and properties.dual_domain_exchange_enabled.len != cells) or properties.macropore_spacing_m.len != cells or properties.macropore_radius_m.len != cells or properties.gravitational_potential_megapascal.len != cells or properties.osmotic_potential_megapascal.len != cells or properties.vertical_thickness_m.len != cells or (properties.active_by_layer.len != 0 and properties.active_by_layer.len != cells) or (properties.rainfall_conductivity_multiplier.len != 0 and properties.rainfall_conductivity_multiplier.len != cells) or (properties.matrix_external_source_m3_per_step.len != 0 and properties.matrix_external_source_m3_per_step.len != cells) or micro_flux.len != faces.len or macro_flux.len != faces.len) return error.SoilWaterSolverDimensionMismatch;
    for (properties.mualem_van_genuchten_parameters) |parameters| try parameters.validate();
    for (properties.macropore_mualem_van_genuchten_parameters) |parameters| try parameters.validate();
    if (!std.math.isFinite(properties.frozen_hydraulic_impedance_exponent) or properties.frozen_hydraulic_impedance_exponent < 0 or !std.math.isFinite(properties.ice_density_megagrams_per_m3) or properties.ice_density_megagrams_per_m3 <= 0 or properties.ice_density_megagrams_per_m3 > 1 or !std.math.isFinite(properties.gravitational_water_potential_mpa_per_m) or properties.gravitational_water_potential_mpa_per_m <= 0) return error.InvalidSoilWaterSolverProperty;
    if (properties.boundary_topology != null and (properties.boundary_face_area_m2.len != cells or properties.boundary_macropore_hydraulic_conductivity_m2_per_h_megapascal.len != cells or properties.boundary_layer_volume_m3.len != cells or properties.boundary_layer_midpoint_depth_m.len != cells or properties.boundary_layer_bottom_depth_m.len != cells)) return error.SoilWaterBoundaryDimensionMismatch;
    if (properties.artificial_drainage_outflow_m3_per_step) |outflow|
        if (outflow.len != grid.cell_count) return error.ArtificialDrainageDimensionMismatch;
    if (properties.boundary_water_exchange_m3_per_step) |exchange|
        if (exchange.len != grid.cell_count) return error.BoundaryWaterExchangeDimensionMismatch;
    if (properties.boundary_water_exchange_m3_per_layer_per_step) |exchange|
        if (exchange.len != grid.layer_count) return error.BoundaryWaterExchangeLayerDimensionMismatch;
    if (properties.dense_jacobian_cache) |cache| {
        const components = try std.math.mul(usize, cells, 2);
        const required_elements = try boundedDenseWorkspaceElements(
            components,
            options.dense_newton_max_components,
        );
        if (cache.values.len < required_elements)
            return error.SoilWaterDenseJacobianCacheDimensionMismatch;
    }
    if (!options.anderson_recovery or options.max_iterations == 0 or !std.math.isFinite(options.absolute_tolerance_m3) or options.absolute_tolerance_m3 <= 0 or !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or !std.math.isFinite(options.conservation_absolute_tolerance_m) or options.conservation_absolute_tolerance_m < 0 or !std.math.isFinite(options.conservation_relative_tolerance) or options.conservation_relative_tolerance < 0 or !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or !std.math.isFinite(options.directional_probe_fraction) or options.directional_probe_fraction <= 0 or !std.math.isFinite(options.minimum_newton_fraction) or options.minimum_newton_fraction <= 0 or !std.math.isFinite(options.maximum_newton_fraction) or options.maximum_newton_fraction < options.minimum_newton_fraction or options.maximum_newton_fraction > 1 or !std.math.isFinite(properties.osmotic_potential_multiplier) or !std.math.isFinite(properties.dual_domain_geometry_factor) or properties.dual_domain_geometry_factor <= 0 or !std.math.isFinite(properties.dual_domain_scaling_coefficient) or properties.dual_domain_scaling_coefficient <= 0) return error.InvalidSoilWaterSolverOptions;
    if (options.cell_area_m2.len != 0) {
        if (options.cell_area_m2.len != grid.cell_count or options.conservation_relative_tolerance <= 0)
            return error.InvalidSoilWaterConservationOptions;
        for (options.cell_area_m2) |area|
            if (!std.math.isFinite(area) or area <= 0)
                return error.InvalidSoilWaterConservationOptions;
    }
    // Divergence/oscillation-watch knobs, validated here alongside the rest of
    // `Options` for a single option-fault vocabulary. A patience of zero would
    // fire on the first non-improving iteration and a growth factor below one
    // would fire on an improving one, so neither can be accepted: a detector
    // that a nonsense value silently disables (or turns into a spurious
    // failure) is worse than no detector. Mirrors
    // `soil/heat/solver_solve.zig`'s `validateRecoveryOptions`.
    if (options.divergence_patience == 0 or options.stagnation_patience == 0 or options.oscillation_patience == 0 or !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1) return error.InvalidSoilWaterSolverOptions;
    for (0..cells) |cell| {
        if (!std.math.isFinite(properties.matrix_bulk_volume_m3[cell]) or properties.matrix_bulk_volume_m3[cell] <= 0 or !std.math.isFinite(properties.vertical_thickness_m[cell]) or properties.vertical_thickness_m[cell] <= 0 or grid.matrix_liquid_water_m3[cell] < 0 or grid.macropore_liquid_water_m3[cell] < 0) {
            if (!builtin.is_test) std.log.err("invalid soil water input: layer_cell={d} bulk_m3={e} thickness_m={e} matrix_water_m3={e} matrix_ice_m3={e} matrix_capacity_m3={e} macropore_water_m3={e} macropore_ice_m3={e} macropore_capacity_m3={e}", .{ cell, properties.matrix_bulk_volume_m3[cell], properties.vertical_thickness_m[cell], grid.matrix_liquid_water_m3[cell], grid.matrix_ice_water_m3[cell], grid.matrix_pore_capacity_m3[cell], grid.macropore_liquid_water_m3[cell], grid.macropore_ice_water_m3[cell], grid.macropore_pore_capacity_m3[cell] });
            return error.InvalidSoilWaterSolverInput;
        }
        // A negative value is an explicit displacement demand, not an invalid
        // carrier. These calls still validate finiteness, nonnegativity of all
        // conserved inputs, and ice-density units before the residual routes it.
        _ = try group_flux.physicalPoreSpaceM3(grid.matrix_pore_capacity_m3[cell], grid.matrix_liquid_water_m3[cell], grid.matrix_ice_water_m3[cell], properties.ice_density_megagrams_per_m3);
        _ = try group_flux.physicalPoreSpaceM3(grid.macropore_pore_capacity_m3[cell], grid.macropore_liquid_water_m3[cell], grid.macropore_ice_water_m3[cell], properties.ice_density_megagrams_per_m3);
    }
    for (faces) |face| if (face.source_cell >= cells or face.destination_cell >= cells or face.source_cell == face.destination_cell or !std.math.isFinite(face.source_path_length_m) or face.source_path_length_m <= 0 or !std.math.isFinite(face.destination_path_length_m) or face.destination_path_length_m <= 0 or !std.math.isFinite(face.face_area_m2) or face.face_area_m2 < 0) return error.InvalidSoilWaterFace;
}
