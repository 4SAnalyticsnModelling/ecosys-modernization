const std = @import("std");

pub const BoundaryConditions = struct {
    east_open: []const bool,
    west_open: []const bool,
    south_open: []const bool,
    north_open: []const bool,
    /// Site-file NCNG semantics. Mode 1 connects a cell to a geographic
    /// neighbor; mode 3 keeps the cell standalone. An empty slice retains the
    /// source EROSION behavior for callers whose topology is already filtered.
    lateral_connection_mode_by_cell: []const u8 = &.{},
};

pub const RunoffDirections = struct {
    east_m3: []const f64,
    west_m3: []const f64,
    south_m3: []const f64,
    north_m3: []const f64,
};

pub const RoutingState = struct {
    allocator: std.mem.Allocator,
    columns: usize,
    rows: usize,
    east_flux_megagrams: []f64,
    west_flux_megagrams: []f64,
    south_flux_megagrams: []f64,
    north_flux_megagrams: []f64,
    sediment_change_megagrams: []f64,
    sediment_export_megagrams: []f64,

    pub fn init(allocator: std.mem.Allocator, columns: usize, rows: usize) !RoutingState {
        if (columns == 0 or rows == 0) return error.InvalidSedimentGridDimensions;
        const count = try std.math.mul(usize, columns, rows);
        var result: RoutingState = undefined;
        result.allocator = allocator;
        result.columns = columns;
        result.rows = rows;
        var allocated: usize = 0;
        errdefer freeAllocated(&result, allocated);
        inline for (@typeInfo(RoutingState).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };
        return result;
    }

    pub fn deinit(self: *RoutingState) void {
        inline for (@typeInfo(RoutingState).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

/// Ports EROSION's RERSED/XSEDER directional partition and TERSED balance.
/// Face fluxes are computed before accumulation, making the kernel suitable
/// for parallel tile generation followed by a deterministic reduction.
pub fn route(state: *RoutingState, transportable_sediment_megagrams: []const f64, total_downslope_runoff_m3: []const f64, directions: RunoffDirections, boundaries: BoundaryConditions, negligible_runoff_m3: f64) !void {
    const count = try std.math.mul(usize, state.columns, state.rows);
    try validateLengths(count, transportable_sediment_megagrams, total_downslope_runoff_m3, directions, boundaries);
    if (!std.math.isFinite(negligible_runoff_m3) or negligible_runoff_m3 < 0) return error.InvalidSedimentRoutingThreshold;
    inline for (.{ state.east_flux_megagrams, state.west_flux_megagrams, state.south_flux_megagrams, state.north_flux_megagrams, state.sediment_change_megagrams, state.sediment_export_megagrams }) |values| @memset(values, 0);

    // Generation phase: each cell writes only its own four face slots.
    for (0..state.rows) |row| for (0..state.columns) |column| {
        const index = row * state.columns + column;
        const total_sediment_megagrams = transportable_sediment_megagrams[index];
        const total_runoff_m3 = total_downslope_runoff_m3[index];
        const directional = [_]f64{ directions.east_m3[index], directions.west_m3[index], directions.south_m3[index], directions.north_m3[index] };
        if (!std.math.isFinite(total_sediment_megagrams) or total_sediment_megagrams < 0 or !std.math.isFinite(total_runoff_m3) or total_runoff_m3 < 0) return error.InvalidSedimentRoutingInput;
        var directional_sum_m3: f64 = 0;
        for (directional) |runoff_m3| {
            if (!std.math.isFinite(runoff_m3) or runoff_m3 < 0) return error.InvalidSedimentRoutingInput;
            directional_sum_m3 += runoff_m3;
        }
        if (total_runoff_m3 <= negligible_runoff_m3 or total_sediment_megagrams == 0) continue;
        const rounding_tolerance = 64 * std.math.floatEps(f64) * @max(1, total_runoff_m3);
        if (directional_sum_m3 > total_runoff_m3 + rounding_tolerance) return error.DirectionalRunoffExceedsTotal;
        state.east_flux_megagrams[index] = if (column + 1 < state.columns)
            if (cellsExchange(index, index + 1, boundaries.lateral_connection_mode_by_cell)) total_sediment_megagrams * directional[0] / total_runoff_m3 else 0
        else if (boundaries.east_open[index]) total_sediment_megagrams * directional[0] / total_runoff_m3 else 0;
        state.west_flux_megagrams[index] = if (column > 0)
            if (cellsExchange(index, index - 1, boundaries.lateral_connection_mode_by_cell)) total_sediment_megagrams * directional[1] / total_runoff_m3 else 0
        else if (boundaries.west_open[index]) total_sediment_megagrams * directional[1] / total_runoff_m3 else 0;
        state.south_flux_megagrams[index] = if (row + 1 < state.rows)
            if (cellsExchange(index, index + state.columns, boundaries.lateral_connection_mode_by_cell)) total_sediment_megagrams * directional[2] / total_runoff_m3 else 0
        else if (boundaries.south_open[index]) total_sediment_megagrams * directional[2] / total_runoff_m3 else 0;
        state.north_flux_megagrams[index] = if (row > 0)
            if (cellsExchange(index, index - state.columns, boundaries.lateral_connection_mode_by_cell)) total_sediment_megagrams * directional[3] / total_runoff_m3 else 0
        else if (boundaries.north_open[index]) total_sediment_megagrams * directional[3] / total_runoff_m3 else 0;
    };

    // Reduction phase: deterministic source order, conservative internally.
    for (0..state.rows) |row| for (0..state.columns) |column| {
        const source = row * state.columns + column;
        const fluxes = [_]f64{ state.east_flux_megagrams[source], state.west_flux_megagrams[source], state.south_flux_megagrams[source], state.north_flux_megagrams[source] };
        for (fluxes) |flux_megagrams| state.sediment_change_megagrams[source] -= flux_megagrams;
        if (column + 1 < state.columns) state.sediment_change_megagrams[source + 1] += fluxes[0] else state.sediment_export_megagrams[source] += fluxes[0];
        if (column > 0) state.sediment_change_megagrams[source - 1] += fluxes[1] else state.sediment_export_megagrams[source] += fluxes[1];
        if (row + 1 < state.rows) state.sediment_change_megagrams[source + state.columns] += fluxes[2] else state.sediment_export_megagrams[source] += fluxes[2];
        if (row > 0) state.sediment_change_megagrams[source - state.columns] += fluxes[3] else state.sediment_export_megagrams[source] += fluxes[3];
    };
}

/// StateUpdates EROSION's `SED = SED + TERSED + RDTSED` after all cells have been
/// validated, preventing a failed tile from leaving a partially changed grid.
pub fn state_updateSurfaceSediment(surface_sediment_megagrams: []f64, local_detachment_megagrams: []const f64, routing_change_megagrams: []const f64) !void {
    if (surface_sediment_megagrams.len != local_detachment_megagrams.len or surface_sediment_megagrams.len != routing_change_megagrams.len) return error.SedimentRoutingDimensionMismatch;
    for (surface_sediment_megagrams, local_detachment_megagrams, routing_change_megagrams) |sediment, local, routed| {
        if (!std.math.isFinite(sediment) or sediment < 0 or !std.math.isFinite(local) or !std.math.isFinite(routed)) return error.InvalidSurfaceSedimentStateUpdate;
        const updated = sediment + local + routed;
        if (!std.math.isFinite(updated) or updated < 0) return error.NegativeSurfaceSediment;
    }
    for (surface_sediment_megagrams, local_detachment_megagrams, routing_change_megagrams) |*sediment, local, routed| sediment.* += local + routed;
}

fn validateLengths(count: usize, sediment: []const f64, runoff: []const f64, directions: RunoffDirections, boundaries: BoundaryConditions) !void {
    if (sediment.len != count or runoff.len != count or directions.east_m3.len != count or directions.west_m3.len != count or directions.south_m3.len != count or directions.north_m3.len != count or boundaries.east_open.len != count or boundaries.west_open.len != count or boundaries.south_open.len != count or boundaries.north_open.len != count) return error.SedimentRoutingDimensionMismatch;
    if (boundaries.lateral_connection_mode_by_cell.len != 0 and boundaries.lateral_connection_mode_by_cell.len != count) return error.SedimentRoutingDimensionMismatch;
    for (boundaries.lateral_connection_mode_by_cell) |mode| if (mode != 1 and mode != 3) return error.InvalidLateralConnectionMode;
}

fn cellsExchange(first: usize, second: usize, modes: []const u8) bool {
    return modes.len == 0 or (modes[first] == 1 and modes[second] == 1);
}

fn freeAllocated(state: *RoutingState, count: usize) void {
    var visited: usize = 0;
    inline for (@typeInfo(RoutingState).@"struct".fields) |field| if (field.type == []f64) {
        if (visited < count) state.allocator.free(@field(state, field.name));
        visited += 1;
    };
}

test "internal sediment routing conserves mass across runtime grid" {
    var state = try RoutingState.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    const closed = [_]bool{ false, false };
    try route(&state, &.{ 1, 0 }, &.{ 2, 0 }, .{ .east_m3 = &.{ 2, 0 }, .west_m3 = &.{ 0, 0 }, .south_m3 = &.{ 0, 0 }, .north_m3 = &.{ 0, 0 } }, .{ .east_open = &closed, .west_open = &closed, .south_open = &closed, .north_open = &closed }, 1e-12);
    try std.testing.expectEqual(@as(f64, -1), state.sediment_change_megagrams[0]);
    try std.testing.expectEqual(@as(f64, 1), state.sediment_change_megagrams[1]);
    try std.testing.expectEqual(@as(f64, 0), state.sediment_change_megagrams[0] + state.sediment_change_megagrams[1]);
}

test "open external boundary records exported sediment" {
    var state = try RoutingState.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    const open = [_]bool{true};
    const closed = [_]bool{false};
    try route(&state, &.{2}, &.{4}, .{ .east_m3 = &.{1}, .west_m3 = &.{0}, .south_m3 = &.{0}, .north_m3 = &.{0} }, .{ .east_open = &open, .west_open = &closed, .south_open = &closed, .north_open = &closed }, 1e-12);
    try std.testing.expectEqual(@as(f64, -0.5), state.sediment_change_megagrams[0]);
    try std.testing.expectEqual(@as(f64, 0.5), state.sediment_export_megagrams[0]);
}

test "closed external boundary blocks sediment even when runoff is present" {
    var state = try RoutingState.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    const closed = [_]bool{false};
    try route(&state, &.{2}, &.{4}, .{ .east_m3 = &.{1}, .west_m3 = &.{0}, .south_m3 = &.{0}, .north_m3 = &.{0} }, .{ .east_open = &closed, .west_open = &closed, .south_open = &closed, .north_open = &closed }, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), state.sediment_change_megagrams[0]);
}

test "NCNG standalone neighbor blocks internal sediment exchange" {
    var state = try RoutingState.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    const closed = [_]bool{ false, false };
    try route(
        &state,
        &.{ 2, 0 },
        &.{ 2, 0 },
        .{ .east_m3 = &.{ 2, 0 }, .west_m3 = &.{ 0, 0 }, .south_m3 = &.{ 0, 0 }, .north_m3 = &.{ 0, 0 } },
        .{
            .east_open = &closed,
            .west_open = &closed,
            .south_open = &closed,
            .north_open = &closed,
            .lateral_connection_mode_by_cell = &.{ 1, 3 },
        },
        1e-12,
    );
    try std.testing.expectEqual(@as(f64, 0), state.east_flux_megagrams[0]);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, state.sediment_change_megagrams);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, state.sediment_export_megagrams);
}

test "NCNG requires both neighboring cells connected for sediment exchange" {
    var state = try RoutingState.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    const closed = [_]bool{ false, false };
    try route(
        &state,
        &.{ 2, 0 },
        &.{ 2, 0 },
        .{ .east_m3 = &.{ 2, 0 }, .west_m3 = &.{ 0, 0 }, .south_m3 = &.{ 0, 0 }, .north_m3 = &.{ 0, 0 } },
        .{
            .east_open = &closed,
            .west_open = &closed,
            .south_open = &closed,
            .north_open = &closed,
            .lateral_connection_mode_by_cell = &.{ 1, 1 },
        },
        1e-12,
    );
    try std.testing.expectEqualSlices(f64, &.{ -2, 2 }, state.sediment_change_megagrams);
    try std.testing.expectEqual(@as(f64, 0), state.sediment_change_megagrams[0] + state.sediment_change_megagrams[1]);
}

test "invalid NCNG topology fails before routing state mutation" {
    var state = try RoutingState.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.sediment_change_megagrams[0] = 7;
    const closed = [_]bool{false};
    try std.testing.expectError(
        error.InvalidLateralConnectionMode,
        route(
            &state,
            &.{1},
            &.{1},
            .{ .east_m3 = &.{0}, .west_m3 = &.{0}, .south_m3 = &.{0}, .north_m3 = &.{0} },
            .{
                .east_open = &closed,
                .west_open = &closed,
                .south_open = &closed,
                .north_open = &closed,
                .lateral_connection_mode_by_cell = &.{2},
            },
            1e-12,
        ),
    );
    try std.testing.expectEqual(@as(f64, 7), state.sediment_change_megagrams[0]);
}

test "surface sediment state_update is transactional and conservative" {
    var sediment = [_]f64{ 1, 2 };
    try state_updateSurfaceSediment(&sediment, &.{ 0.2, -0.1 }, &.{ -0.5, 0.5 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), sediment[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), sediment[1], 1e-14);
}

test "invalid sediment state_update leaves every cell unchanged" {
    var sediment = [_]f64{ 1, 2 };
    try std.testing.expectError(error.NegativeSurfaceSediment, state_updateSurfaceSediment(&sediment, &.{ 0, -3 }, &.{ 0, 0 }));
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, &sediment);
}

test "sediment state update rejects sub-legacy-tolerance overdraw atomically" {
    var sediment = [_]f64{ 1, 2 };
    try std.testing.expectError(error.NegativeSurfaceSediment, state_updateSurfaceSediment(&sediment, &.{ 0, -2.0000000000001 }, &.{ 0, 0 }));
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, &sediment);
}
