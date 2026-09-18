const std = @import("std");
const topography_module = @import("topography.zig");
const soil_geometry_module = @import("../soil/profile/layer_geometry.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    columns: usize,
    rows: usize,
    slope_m_per_m: []f64,
    east_west_slope_m_per_m: []f64,
    north_south_slope_m_per_m: []f64,
    east_west_runoff_fraction: []f64,
    north_south_runoff_fraction: []f64,
    flow_width_m: []f64,
    relative_surface_elevation_m: []f64,
    initial_surface_elevation_m: []f64,
    current_surface_elevation_m: []f64,
    runoff_to_west: []bool,
    runoff_to_east: []bool,
    runoff_to_north: []bool,
    runoff_to_south: []bool,
    minimum_surface_elevation_m: f64,
    minimum_current_surface_elevation_m: f64,

    /// Exact STARTS terrain construction, with the apparent `DV(NY,N)` typo
    /// interpreted as the current cell's north-south width `DV(NY,NX)`.
    pub fn initMapped(
        allocator: std.mem.Allocator,
        topography: topography_module.Topography,
        unit_by_cell: []const usize,
        horizontal_cell_width_m: []const f64,
        vertical_cell_width_m: []const f64,
        columns: usize,
        rows: usize,
    ) !State {
        const count = try std.math.mul(usize, columns, rows);
        if (columns == 0 or rows == 0 or unit_by_cell.len != count or
            horizontal_cell_width_m.len != count or vertical_cell_width_m.len != count)
            return error.TerrainHydrologyDimensionMismatch;
        var result: State = undefined;
        result.allocator = allocator;
        result.columns = columns;
        result.rows = rows;
        var allocated: usize = 0;
        errdefer result.freeAllocated(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                @field(result, field.name) = try allocator.alloc(f64, count);
                allocated += 1;
            } else if (field.type == []bool) {
                @field(result, field.name) = try allocator.alloc(bool, count);
                allocated += 1;
            }
        }
        var maximum_elevation_m: f64 = 0;
        for (0..columns) |column| for (0..rows) |row| {
            const cell = row * columns + column;
            const unit_index = unit_by_cell[cell];
            if (unit_index >= topography.units.len) return error.TopographyUnitOutOfBounds;
            const unit = topography.units[unit_index];
            if (!std.math.isFinite(unit.slope_degrees) or unit.slope_degrees < 0 or unit.slope_degrees > 90 or !std.math.isFinite(unit.compass_aspect_degrees) or unit.compass_aspect_degrees < 0 or unit.compass_aspect_degrees > 360) return error.InvalidTerrainHydrologyInput;
            const slope = @max(1.745e-3, @sin(unit.slope_degrees * std.math.pi / 180));
            const aspect = unit.compass_aspect_degrees;
            const radians = aspect * std.math.pi / 180;
            var x_slope: f64 = undefined;
            var y_slope: f64 = undefined;
            result.runoff_to_west[cell] = false;
            result.runoff_to_east[cell] = false;
            result.runoff_to_north[cell] = false;
            result.runoff_to_south[cell] = false;
            if (aspect < 90) {
                x_slope = -slope * @cos(radians);
                y_slope = slope * @sin(radians);
                result.runoff_to_west[cell] = true;
                result.runoff_to_south[cell] = true;
            } else if (aspect < 180) {
                x_slope = slope * @sin(radians - std.math.pi / 2.0);
                y_slope = slope * @cos(radians - std.math.pi / 2.0);
                result.runoff_to_east[cell] = true;
                result.runoff_to_south[cell] = true;
            } else if (aspect < 270) {
                x_slope = slope * @cos(radians - std.math.pi);
                y_slope = -slope * @sin(radians - std.math.pi);
                result.runoff_to_east[cell] = true;
                result.runoff_to_north[cell] = true;
            } else {
                x_slope = -slope * @sin(radians - 3.0 * std.math.pi / 2.0);
                y_slope = -slope * @cos(radians - 3.0 * std.math.pi / 2.0);
                result.runoff_to_west[cell] = true;
                result.runoff_to_north[cell] = true;
            }
            result.slope_m_per_m[cell] = slope;
            result.east_west_slope_m_per_m[cell] = x_slope;
            result.north_south_slope_m_per_m[cell] = y_slope;
            const slope_sum = @abs(x_slope) + @abs(y_slope);
            result.east_west_runoff_fraction[cell] = if (slope_sum > 0) @abs(x_slope) / slope_sum else 0.5;
            result.north_south_runoff_fraction[cell] = if (slope_sum > 0) @abs(y_slope) / slope_sum else 0.5;
            const x_width = horizontal_cell_width_m[cell];
            const y_width = vertical_cell_width_m[cell];
            if (!std.math.isFinite(x_width) or x_width <= 0 or
                !std.math.isFinite(y_width) or y_width <= 0)
                return error.InvalidTerrainHydrologyInput;
            result.flow_width_m[cell] = result.east_west_runoff_fraction[cell] * y_width + result.north_south_runoff_fraction[cell] * x_width;
            if (column == 0 and row == 0) {
                result.relative_surface_elevation_m[cell] = 0.5 * x_width * x_slope + 0.5 * y_width * y_slope;
            } else if (column == 0) {
                const north = cell - columns;
                const north_y_width = vertical_cell_width_m[north];
                result.relative_surface_elevation_m[cell] = result.relative_surface_elevation_m[north] + x_width * x_slope + 0.5 * north_y_width * result.north_south_slope_m_per_m[north] + 0.5 * y_width * y_slope;
            } else if (row == 0) {
                const west = cell - 1;
                const west_x_width = horizontal_cell_width_m[west];
                result.relative_surface_elevation_m[cell] = result.relative_surface_elevation_m[west] + 0.5 * west_x_width * result.east_west_slope_m_per_m[west] + 0.5 * x_width * x_slope + 0.5 * y_width * result.north_south_slope_m_per_m[west] + 0.5 * y_width * y_slope;
            } else {
                const west = cell - 1;
                const north = cell - columns;
                const west_x_width = horizontal_cell_width_m[west];
                const north_y_width = vertical_cell_width_m[north];
                const from_west = result.relative_surface_elevation_m[west] + 0.5 * west_x_width * result.east_west_slope_m_per_m[west] + 0.5 * x_width * x_slope;
                const from_north = result.relative_surface_elevation_m[north] + 0.5 * north_y_width * result.north_south_slope_m_per_m[north] + 0.5 * y_width * y_slope;
                result.relative_surface_elevation_m[cell] = 0.5 * (from_west + from_north);
            }
            maximum_elevation_m = if (cell == 0) result.relative_surface_elevation_m[cell] else @max(maximum_elevation_m, result.relative_surface_elevation_m[cell]);
        };
        result.minimum_surface_elevation_m = 0;
        for (result.relative_surface_elevation_m) |*elevation| {
            elevation.* -= maximum_elevation_m;
            result.minimum_surface_elevation_m = @min(result.minimum_surface_elevation_m, elevation.*);
        }
        @memcpy(result.initial_surface_elevation_m, result.relative_surface_elevation_m);
        @memcpy(result.current_surface_elevation_m, result.relative_surface_elevation_m);
        result.minimum_current_surface_elevation_m = result.minimum_surface_elevation_m;
        try result.validateFinite();
        return result;
    }

    /// Binds WATSUB `ALT`, the immutable initial ground elevation, from each
    /// runtime cell's compulsory site input. Geographic cell dimensions remain
    /// owned by the spatial grid and are not inferred from elevation.
    pub fn bindInitialSurfaceElevations(self: *State, elevation_m_by_cell: []const f64) !void {
        if (elevation_m_by_cell.len != self.relative_surface_elevation_m.len) return error.TerrainHydrologyDimensionMismatch;
        for (elevation_m_by_cell) |elevation_m| if (!std.math.isFinite(elevation_m)) return error.InvalidTerrainHydrologyInput;
        @memcpy(self.initial_surface_elevation_m, elevation_m_by_cell);
        @memcpy(self.current_surface_elevation_m, elevation_m_by_cell);
        try self.refreshMinimumCurrentSurfaceElevation();
    }

    /// Exact WATSUB line 137:
    /// `ALTG(NY,NX) = ALT(NY,NX) - CDPTH(NUM(NY,NX)-1,NY,NX)`.
    /// The explicit Zig boundary at `first_active_layer[cell]` is the source
    /// `NUM-1` surface boundary. All cells validate before any elevation is
    /// state_updateted.
    pub fn refreshCurrentSurfaceElevations(self: *State, geometry: *const soil_geometry_module.State) !void {
        if (geometry.cell_count != self.current_surface_elevation_m.len) return error.TerrainHydrologyDimensionMismatch;
        for (0..geometry.cell_count) |cell| {
            const first = geometry.first_active_layer[cell];
            if (geometry.active_layer_count[cell] == 0 or first >= geometry.layer_capacity) return error.InvalidActiveSoilLayerRange;
            const surface_boundary = geometry.boundary_depth_m[try geometry.boundaryIndex(cell, first)];
            const current = self.initial_surface_elevation_m[cell] - surface_boundary;
            if (!std.math.isFinite(surface_boundary) or !std.math.isFinite(current)) return error.NonFiniteTerrainHydrology;
        }
        for (0..geometry.cell_count) |cell| {
            const first = geometry.first_active_layer[cell];
            const surface_boundary = geometry.boundary_depth_m[try geometry.boundaryIndex(cell, first)];
            self.current_surface_elevation_m[cell] = self.initial_surface_elevation_m[cell] - surface_boundary;
        }
        try self.refreshMinimumCurrentSurfaceElevation();
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64 or field.type == []bool) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn validateFinite(self: *const State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name)) |value| if (!std.math.isFinite(value)) return error.NonFiniteTerrainHydrology;
    }

    fn freeAllocated(self: *State, count: usize) void {
        var visited: usize = 0;
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64 or field.type == []bool) {
            if (visited < count) self.allocator.free(@field(self, field.name));
            visited += 1;
        };
    }

    fn refreshMinimumCurrentSurfaceElevation(self: *State) !void {
        if (self.current_surface_elevation_m.len == 0) return error.TerrainHydrologyDimensionMismatch;
        var minimum = self.current_surface_elevation_m[0];
        for (self.current_surface_elevation_m) |elevation| {
            if (!std.math.isFinite(elevation)) return error.NonFiniteTerrainHydrology;
            minimum = @min(minimum, elevation);
        }
        self.minimum_current_surface_elevation_m = minimum;
    }
};

test "terrain hydrology reconstructs STARTS slopes routing and relative elevation" {
    // Two cells facing opposite ways: north-east at 45 degrees and
    // south-west at 225, both on a 10 degree slope.
    var topography = try topography_module.fromUnits(std.testing.allocator, &.{
        .{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1, .compass_aspect_degrees = 45, .slope_degrees = 10 },
        .{ .west_column = 2, .north_row = 1, .east_column = 2, .south_row = 1, .compass_aspect_degrees = 225, .slope_degrees = 10 },
    });
    defer topography.deinit();
    var state = try State.initMapped(std.testing.allocator, topography, &.{ 0, 1 }, &.{ 10, 20 }, &.{ 5, 5 }, 2, 1);
    defer state.deinit();
    try std.testing.expect(state.runoff_to_west[0]);
    try std.testing.expect(state.runoff_to_south[0]);
    try std.testing.expect(state.runoff_to_east[1]);
    try std.testing.expect(state.runoff_to_north[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.east_west_runoff_fraction[0] + state.north_south_runoff_fraction[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), @max(state.relative_surface_elevation_m[0], state.relative_surface_elevation_m[1]), 1e-12);
}

test "WATSUB current surface elevation follows runtime geometry atomically" {
    var topography = try topography_module.fromUnits(std.testing.allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 2, .south_row = 1, .compass_aspect_degrees = 90 }});
    defer topography.deinit();
    var state = try State.initMapped(std.testing.allocator, topography, &.{ 0, 0 }, &.{ 10, 10 }, &.{ 5, 5 }, 2, 1);
    defer state.deinit();
    try state.bindInitialSurfaceElevations(&.{ 100, 90 });

    var geometry = try soil_geometry_module.State.init(std.testing.allocator, 2, 2);
    defer geometry.deinit();
    try soil_geometry_module.initializeCell(&geometry, 0, 0, &.{ 0.2, 0.3 }, 0.2, 1.0e-9);
    try soil_geometry_module.initializeCell(&geometry, 1, 1, &.{0.4}, -0.1, 1.0e-9);
    try state.refreshCurrentSurfaceElevations(&geometry);
    try std.testing.expectApproxEqAbs(@as(f64, 99.8), state.current_surface_elevation_m[0], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 90.1), state.current_surface_elevation_m[1], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 90.1), state.minimum_current_surface_elevation_m, 1.0e-14);

    const before = state.current_surface_elevation_m[0];
    geometry.boundary_depth_m[try geometry.boundaryIndex(1, 1)] = std.math.nan(f64);
    try std.testing.expectError(error.NonFiniteTerrainHydrology, state.refreshCurrentSurfaceElevations(&geometry));
    try std.testing.expectEqual(before, state.current_surface_elevation_m[0]);
}
