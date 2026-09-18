//! Tests for `cell_grid_file.zig`.

const std = @import("std");
const cell_grid_file = @import("cell_grid_file.zig");
const spatial_grid = @import("../../state/spatial_grid.zig");

/// Two one-degree cells side by side: cell 0 covers 81W to 80W, cell 1 covers
/// 80W to 79W, both between 45N and 46N.
fn testGrid(allocator: std.mem.Allocator) !spatial_grid.RegularGrid {
    return spatial_grid.RegularGrid.init(allocator, .{
        .minimum_latitude_degrees_north = 45,
        .maximum_latitude_degrees_north = 46,
        .minimum_longitude_degrees_east = -81,
        .maximum_longitude_degrees_east = -79,
        .latitude_interval_degrees = 1,
        .longitude_interval_degrees = 1,
    });
}

test "records resolve to cells by coordinate and carry their filenames" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator);
    defer grid.deinit();
    // Tab separated, as the production files are written.
    var reader = try cell_grid_file.Reader.init(
        allocator,
        "# record, latitude, longitude, first, second\n" ++
            "management_cell\t45.30\t-80.70\tfertilizer_west\tNO\n" ++
            "MANAGEMENT_CELL,45.80,-79.20,fertilizer_east,irrigation_east\n",
        grid,
        "management_cell",
        2,
    );
    defer reader.deinit(allocator);

    const west = (try reader.next()).?;
    try std.testing.expectEqual(@as(usize, 0), west.cell);
    try std.testing.expectEqualStrings("fertilizer_west", west.names[0]);
    try std.testing.expectEqualStrings("NO", west.names[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 45.30), west.latitude_degrees_north, 1.0e-12);

    const east = (try reader.next()).?;
    try std.testing.expectEqual(@as(usize, 1), east.cell);
    try std.testing.expectEqualStrings("irrigation_east", east.names[1]);

    try std.testing.expectEqual(@as(?cell_grid_file.Record, null), try reader.next());
    try reader.requireCompleteCoverage();
}

test "a cell the file never mentions is reported rather than defaulted" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator);
    defer grid.deinit();
    var reader = try cell_grid_file.Reader.init(
        allocator,
        "climate_cell 45.30 -80.70 options\n",
        grid,
        "climate_cell",
        1,
    );
    defer reader.deinit(allocator);
    _ = try reader.next();
    try std.testing.expectEqual(@as(?cell_grid_file.Record, null), try reader.next());
    try std.testing.expectError(error.MissingGridRecord, reader.requireCompleteCoverage());
}

test "two coordinates inside one cell are a duplicate, not an override" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator);
    defer grid.deinit();
    var reader = try cell_grid_file.Reader.init(
        allocator,
        // Both points fall in cell 0, so the second record is rejected even
        // though the numbers differ.
        "plant 45.30 -80.70 maize\nplant 45.80 -80.20 soybean\n",
        grid,
        "plant",
        1,
    );
    defer reader.deinit(allocator);
    _ = try reader.next();
    try std.testing.expectError(error.DuplicateGridRecordCoordinate, reader.next());
}

test "malformed records are rejected with the specific defect named" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator);
    defer grid.deinit();
    const cases = .{
        .{ "wrong_tag 45.30 -80.70 a b\n", error.InvalidGridRecordName },
        .{ "management_cell 44.00 -80.70 a b\n", error.SiteCoordinateOutsideGeospatialGrid },
        .{ "management_cell north -80.70 a b\n", error.InvalidGridCoordinate },
        .{ "management_cell 45.30 -80.70 a\n", error.IncompleteGridRecord },
        .{ "management_cell 45.30 -80.70 a b extra\n", error.TrailingGridRecordData },
        .{ "management_cell,45.30,-80.70,,b\n", error.EmptyGridRecordValue },
    };
    inline for (cases) |case| {
        var reader = try cell_grid_file.Reader.init(
            allocator,
            case[0],
            grid,
            "management_cell",
            2,
        );
        defer reader.deinit(allocator);
        try std.testing.expectError(case[1], reader.next());
    }
}

test "record arity outside the supported range is refused at construction" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator);
    defer grid.deinit();
    try std.testing.expectError(
        error.UnsupportedGridRecordArity,
        cell_grid_file.Reader.init(allocator, "", grid, "cell", 0),
    );
    try std.testing.expectError(
        error.UnsupportedGridRecordArity,
        cell_grid_file.Reader.init(allocator, "", grid, "cell", 9),
    );
}
