const std = @import("std");
const grid_input_files = @import("grid_input_files.zig");
const spatial_grid = @import("../../state/spatial_grid.zig");

pub const ForcingGeometry = struct {
    altitude_m: f64,
    latitude_degrees_north: f64,
    longitude_degrees_east: f64,
    phytotron: bool,

    pub fn validate(self: ForcingGeometry) !void {
        if (!std.math.isFinite(self.altitude_m)) return error.InvalidWeatherGridAltitude;
        if (!std.math.isFinite(self.latitude_degrees_north) or
            self.latitude_degrees_north < -90 or self.latitude_degrees_north > 90)
            return error.InvalidWeatherGridLatitude;
        if (!std.math.isFinite(self.longitude_degrees_east) or
            self.longitude_degrees_east < -180 or self.longitude_degrees_east > 180)
            return error.InvalidWeatherGridLongitude;
    }

    fn eql(left: ForcingGeometry, right: ForcingGeometry) bool {
        return left.altitude_m == right.altitude_m and
            left.latitude_degrees_north == right.latitude_degrees_north and
            left.longitude_degrees_east == right.longitude_degrees_east and
            left.phytotron == right.phytotron;
    }
};

/// Deduplicates scientifically identical per-cell weather streams. A stream
/// may be shared only when both its filename and all geometry used during
/// normalization/disaggregation are identical.
pub const Assignments = struct {
    allocator: std.mem.Allocator,
    unique_file_names: [][]u8,
    forcing_geometry_by_stream: []ForcingGeometry,
    stream_index_by_cell: []usize,

    pub fn init(
        allocator: std.mem.Allocator,
        files: grid_input_files.WeatherFiles,
        forcing_geometry_by_cell: []const ForcingGeometry,
    ) !Assignments {
        if (forcing_geometry_by_cell.len != files.file_by_cell.len)
            return error.WeatherGridDimensionMismatch;
        const stream_index_by_cell = try allocator.alloc(usize, files.file_by_cell.len);
        errdefer allocator.free(stream_index_by_cell);
        var unique_names: std.ArrayList([]u8) = .empty;
        defer unique_names.deinit(allocator);
        errdefer for (unique_names.items) |name| allocator.free(name);
        var unique_geometry: std.ArrayList(ForcingGeometry) = .empty;
        defer unique_geometry.deinit(allocator);

        for (files.file_by_cell, 0..) |file_name, cell| {
            const geometry = forcing_geometry_by_cell[cell];
            try geometry.validate();
            var found: ?usize = null;
            for (unique_names.items, 0..) |unique_name, index| {
                if (std.mem.eql(u8, file_name, unique_name) and
                    geometry.eql(unique_geometry.items[index]))
                {
                    found = index;
                    break;
                }
            }
            if (found) |index| {
                stream_index_by_cell[cell] = index;
            } else {
                const owned_name = try allocator.dupe(u8, file_name);
                errdefer allocator.free(owned_name);
                stream_index_by_cell[cell] = unique_names.items.len;
                try unique_names.append(allocator, owned_name);
                errdefer _ = unique_names.pop();
                try unique_geometry.append(allocator, geometry);
            }
        }
        if (unique_names.items.len == 0) return error.EmptyWeatherGrid;
        const owned_names = try unique_names.toOwnedSlice(allocator);
        errdefer {
            for (owned_names) |name| allocator.free(name);
            allocator.free(owned_names);
        }
        const owned_geometry = try unique_geometry.toOwnedSlice(allocator);
        errdefer allocator.free(owned_geometry);
        return .{
            .allocator = allocator,
            .unique_file_names = owned_names,
            .forcing_geometry_by_stream = owned_geometry,
            .stream_index_by_cell = stream_index_by_cell,
        };
    }

    pub fn deinit(self: *Assignments) void {
        for (self.unique_file_names) |name| self.allocator.free(name);
        self.allocator.free(self.unique_file_names);
        self.allocator.free(self.forcing_geometry_by_stream);
        self.allocator.free(self.stream_index_by_cell);
        self.* = undefined;
    }
};

/// `columns` one-degree cells in a single row, the westmost centred at
/// (45.5, -80.5). Weather records below name a point inside a cell.
fn testGrid(allocator: std.mem.Allocator, columns: usize) !spatial_grid.RegularGrid {
    return spatial_grid.RegularGrid.init(allocator, .{
        .minimum_latitude_degrees_north = 45,
        .maximum_latitude_degrees_north = 46,
        .minimum_longitude_degrees_east = -81,
        .maximum_longitude_degrees_east = -81 + @as(f64, @floatFromInt(columns)),
        .latitude_interval_degrees = 1,
        .longitude_interval_degrees = 1,
    });
}

test "weather assignments share only scientifically identical streams" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator, 3);
    defer grid.deinit();
    var files = try grid_input_files.WeatherFiles.parse(
        allocator,
        \\weather_cell 45.50 -80.50 shared_weather
        \\weather_cell 45.50 -79.50 east_weather
        \\weather_cell 45.50 -78.50 shared_weather
    ,
        grid,
    );
    defer files.deinit();
    const geometry = [_]ForcingGeometry{
        .{ .altitude_m = 100, .latitude_degrees_north = 50, .longitude_degrees_east = -110, .phytotron = false },
        .{ .altitude_m = 100, .latitude_degrees_north = 50, .longitude_degrees_east = -110, .phytotron = false },
        .{ .altitude_m = 100, .latitude_degrees_north = 50, .longitude_degrees_east = -110, .phytotron = false },
    };
    var assignments = try Assignments.init(allocator, files, &geometry);
    defer assignments.deinit();

    try std.testing.expectEqual(@as(usize, 2), assignments.unique_file_names.len);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 1, 0 },
        assignments.stream_index_by_cell,
    );
}

test "same weather filename with different site geometry uses distinct streams" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator, 2);
    defer grid.deinit();
    var files = try grid_input_files.WeatherFiles.parse(
        allocator,
        \\weather_cell 45.50 -80.50 shared_weather
        \\weather_cell 45.50 -79.50 shared_weather
    ,
        grid,
    );
    defer files.deinit();
    const geometry = [_]ForcingGeometry{
        .{ .altitude_m = 100, .latitude_degrees_north = 50, .longitude_degrees_east = -110, .phytotron = false },
        .{ .altitude_m = 101, .latitude_degrees_north = 50, .longitude_degrees_east = -110, .phytotron = false },
    };
    var assignments = try Assignments.init(allocator, files, &geometry);
    defer assignments.deinit();
    try std.testing.expectEqual(@as(usize, 2), assignments.unique_file_names.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, assignments.stream_index_by_cell);
}
