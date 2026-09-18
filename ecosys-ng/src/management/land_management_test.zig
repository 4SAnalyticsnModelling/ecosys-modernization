//! Tests for `land_management.zig`.

const std = @import("std");
const land_management = @import("land_management.zig");
const spatial_grid = @import("../state/spatial_grid.zig");

/// Two one-degree cells side by side between 45N and 46N.
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

test "each cell selects its own fertilizer irrigation and tillage files" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator);
    defer grid.deinit();
    var assignments = try land_management.parse(
        allocator,
        "# record, latitude, longitude, fertilizer, irrigation, tillage\n" ++
            "management_cell\t45.30\t-80.70\tfert_west\tNO\ttill_west\n" ++
            "management_cell\t45.30\t-79.30\tfert_east\tirrig_east\tNO\n",
        grid,
    );
    defer assignments.deinit();

    try std.testing.expectEqual(@as(usize, 2), assignments.units.len);
    try std.testing.expectEqualStrings("fert_west", assignments.units[0].fertilizer_file);
    try std.testing.expectEqualStrings("NO", assignments.units[0].irrigation_file);
    try std.testing.expectEqualStrings("till_west", assignments.units[0].tillage_file);
    try std.testing.expectEqualStrings("fert_east", assignments.units[1].fertilizer_file);
    try std.testing.expectEqualStrings("irrig_east", assignments.units[1].irrigation_file);
    try std.testing.expectEqualStrings("NO", assignments.units[1].tillage_file);

    const map = try assignments.buildCellUnitMap(allocator);
    defer allocator.free(map);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, map);
}

test "a cell with no management record is reported" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator);
    defer grid.deinit();
    try std.testing.expectError(
        error.MissingGridRecord,
        land_management.parse(
            allocator,
            "management_cell 45.30 -80.70 fert NO till\n",
            grid,
        ),
    );
}

test "management records accept comma and pipe delimiters" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator);
    defer grid.deinit();
    var assignments = try land_management.parse(
        allocator,
        "management_cell,45.30,-80.70,fert,NO,till\n" ++
            "management_cell|45.30|-79.30|fert|NO|till\n",
        grid,
    );
    defer assignments.deinit();
    try std.testing.expectEqualStrings("fert", assignments.units[1].fertilizer_file);
}
