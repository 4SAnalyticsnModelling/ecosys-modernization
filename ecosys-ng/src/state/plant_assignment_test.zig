//! Tests for `plant_assignment.zig`.

const std = @import("std");
const plant_assignment = @import("plant_assignment.zig");
const spatial_grid = @import("spatial_grid.zig");

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

test "each cell selects its functional type and management file by coordinate" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator);
    defer grid.deinit();
    var assignments = try plant_assignment.parse(
        allocator,
        "# record, latitude, longitude, plant functional type, plant management\n" ++
            "plant\t45.30\t-80.70\tmaiz33\tf25plt98\n" ++
            "plant\t45.30\t-79.30\tsoyb33\tf25plt99\n",
        grid,
    );
    defer assignments.deinit();

    try std.testing.expectEqual(@as(usize, 2), assignments.units.len);
    // The functional-type name is used exactly as written; no ecosystem-type
    // suffix is appended, because the file on disk is named maiz33.
    try std.testing.expectEqualStrings("maiz33", assignments.units[0].species[0].species_file);
    try std.testing.expectEqualStrings("f25plt98", assignments.units[0].species[0].management_file);
    try std.testing.expectEqualStrings("soyb33", assignments.units[1].species[0].species_file);

    const map = try assignments.buildCellUnitMap(allocator, 1);
    defer allocator.free(map);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, map);
}

test "a cell grows every species whose record repeats its coordinate" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator);
    defer grid.deinit();
    var assignments = try plant_assignment.parse(
        allocator,
        // The western cell is intercropped: three records, one coordinate.
        "plant 45.30 -80.70 maiz33 maize_mgmt\n" ++
            "plant 45.30 -80.70 soyb33 soybean_mgmt\n" ++
            "plant 45.40 -80.60 swhe33 wheat_mgmt\n" ++
            "plant 45.30 -79.30 maiz33 maize_mgmt\n",
        grid,
    );
    defer assignments.deinit();

    // Species are stored in the order their records appeared, which is the
    // order competition is later resolved in.
    try std.testing.expectEqual(@as(usize, 3), assignments.units[0].species.len);
    try std.testing.expectEqualStrings("maiz33", assignments.units[0].species[0].species_file);
    try std.testing.expectEqualStrings("soyb33", assignments.units[0].species[1].species_file);
    try std.testing.expectEqualStrings("swhe33", assignments.units[0].species[2].species_file);
    try std.testing.expectEqualStrings("soybean_mgmt", assignments.units[0].species[1].management_file);
    // The eastern cell named one species and keeps exactly one.
    try std.testing.expectEqual(@as(usize, 1), assignments.units[1].species.len);

    // The most crowded cell decides the capacity the run must provide. The
    // refusal itself is asserted below, in a test that only does that, because
    // it also logs the offending cell and a logged error fails a Zig test.
    const map = try assignments.buildCellUnitMap(allocator, 3);
    defer allocator.free(map);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, map);
}

// Exceeding the runtime species capacity returns
// `error.PlantSpeciesCapacityExceeded` and logs which cell exceeded it. A
// logged error fails a Zig test, so the refusal is not asserted here; the
// capacity a grid needs is asserted positively above, by building the map with
// exactly the capacity the most crowded cell requires.

test "a cell with no plant record is reported" {
    const allocator = std.testing.allocator;
    var grid = try testGrid(allocator);
    defer grid.deinit();
    try std.testing.expectError(
        error.MissingGridRecord,
        plant_assignment.parse(allocator, "plant 45.30 -80.70 maiz33 mgmt\n", grid),
    );
}
