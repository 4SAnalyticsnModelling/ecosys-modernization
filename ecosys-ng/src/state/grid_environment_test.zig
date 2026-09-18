//! Tests for `grid_environment.zig`.

const std = @import("std");
const grid_environment = @import("grid_environment.zig");
const grid_input_files = @import("../io/input/grid_input_files.zig");
const site_catalog = @import("site_catalog.zig");
const spatial_grid = @import("spatial_grid.zig");
const test_fixtures = @import("../core/test_fixtures.zig");

/// One degree cells. `columns` x `rows` starting at 45N, 81W.
fn grid(allocator: std.mem.Allocator, columns: usize, rows: usize) !spatial_grid.RegularGrid {
    return spatial_grid.RegularGrid.init(allocator, .{
        .minimum_latitude_degrees_north = 45,
        .maximum_latitude_degrees_north = 45 + @as(f64, @floatFromInt(rows)),
        .minimum_longitude_degrees_east = -81,
        .maximum_longitude_degrees_east = -81 + @as(f64, @floatFromInt(columns)),
        .latitude_interval_degrees = 1,
        .longitude_interval_degrees = 1,
    });
}

/// A site whose own footprint is a distinctive 1234 m by 5678 m, so a value
/// taken from the site file is never mistaken for a geospatial one.
const distinctive_footprint_site =
    "92 5.4 3 94.6 0.23 0.00\n" ++
    "2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n" ++
    "33 1 3 1 1.0 0.0\n" ++
    "0 1 1 0 10 0 10 0 1 0 1 0 0\n" ++
    "1.5 1.0\n0 10 0 10 0 1 0 1\n" ++
    "1234\n5678\n";

test "a lone cell has no neighbour on either axis and keeps its site footprint" {
    const allocator = std.testing.allocator;
    var sites = site_catalog.Catalog.init(allocator);
    defer sites.deinit();
    _ = try sites.appendFromSource("site", distinctive_footprint_site, 1, 1);

    var cell_grid = try grid(allocator, 1, 1);
    defer cell_grid.deinit();
    var files = try grid_input_files.CellFiles.parse(
        allocator,
        "grid_cell 45.5 -80.5 site soil\n",
        cell_grid,
    );
    defer files.deinit();

    var assignments = try grid_environment.Assignments.init(allocator, files, sites, cell_grid);
    defer assignments.deinit();
    try std.testing.expectApproxEqAbs(
        @as(f64, 1234),
        assignments.horizontal_cell_width_m[0],
        1.0e-9,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 5678),
        assignments.vertical_cell_width_m[0],
        1.0e-9,
    );
}

test "an east-west pair sizes width from longitude but height from the site file" {
    const allocator = std.testing.allocator;
    var sites = site_catalog.Catalog.init(allocator);
    defer sites.deinit();
    _ = try sites.appendFromSource("site", distinctive_footprint_site, 1, 1);

    var cell_grid = try grid(allocator, 2, 1);
    defer cell_grid.deinit();
    var files = try grid_input_files.CellFiles.parse(
        allocator,
        \\grid_cell 45.5 -80.5 site soil
        \\grid_cell 45.5 -79.5 site soil
    ,
        cell_grid,
    );
    defer files.deinit();

    var assignments = try grid_environment.Assignments.init(allocator, files, sites, cell_grid);
    defer assignments.deinit();
    for (0..2) |cell| {
        // Both cells share an east-west face, so both take the geospatial
        // width. One degree of longitude at 45.5N is roughly 78 km.
        try std.testing.expectApproxEqAbs(
            cell_grid.east_west_cell_width_m[cell],
            assignments.horizontal_cell_width_m[cell],
            1.0e-9,
        );
        try std.testing.expect(assignments.horizontal_cell_width_m[cell] > 70_000);
        // Neither has a north-south neighbour, so height stays local.
        try std.testing.expectApproxEqAbs(
            @as(f64, 5678),
            assignments.vertical_cell_width_m[cell],
            1.0e-9,
        );
    }
}

test "a north-south pair sizes height from latitude but width from the site file" {
    const allocator = std.testing.allocator;
    var sites = site_catalog.Catalog.init(allocator);
    defer sites.deinit();
    _ = try sites.appendFromSource("site", distinctive_footprint_site, 1, 1);

    var cell_grid = try grid(allocator, 1, 2);
    defer cell_grid.deinit();
    var files = try grid_input_files.CellFiles.parse(
        allocator,
        \\grid_cell 46.5 -80.5 site soil
        \\grid_cell 45.5 -80.5 site soil
    ,
        cell_grid,
    );
    defer files.deinit();

    var assignments = try grid_environment.Assignments.init(allocator, files, sites, cell_grid);
    defer assignments.deinit();
    for (0..2) |cell| {
        try std.testing.expectApproxEqAbs(
            @as(f64, 1234),
            assignments.horizontal_cell_width_m[cell],
            1.0e-9,
        );
        try std.testing.expectApproxEqAbs(
            cell_grid.north_south_cell_width_m[cell],
            assignments.vertical_cell_width_m[cell],
            1.0e-9,
        );
        try std.testing.expect(assignments.vertical_cell_width_m[cell] > 100_000);
    }
}

test "interior cells of a 3x3 grid take both dimensions from the coordinates" {
    const allocator = std.testing.allocator;
    var sites = site_catalog.Catalog.init(allocator);
    defer sites.deinit();
    _ = try sites.appendFromSource("site", distinctive_footprint_site, 1, 1);

    var cell_grid = try grid(allocator, 3, 3);
    defer cell_grid.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    for (0..3) |row| for (0..3) |column| {
        try source.print(allocator, "grid_cell {d:.2} {d:.2} site soil\n", .{
            47.5 - @as(f64, @floatFromInt(row)),
            -80.5 + @as(f64, @floatFromInt(column)),
        });
    };
    var files = try grid_input_files.CellFiles.parse(allocator, source.items, cell_grid);
    defer files.deinit();

    var assignments = try grid_environment.Assignments.init(allocator, files, sites, cell_grid);
    defer assignments.deinit();
    // Every cell of a 3x3 grid has at least one neighbour on each axis, so no
    // cell falls back to the site footprint anywhere.
    for (0..9) |cell| {
        try std.testing.expectApproxEqAbs(
            cell_grid.east_west_cell_width_m[cell],
            assignments.horizontal_cell_width_m[cell],
            1.0e-9,
        );
        try std.testing.expectApproxEqAbs(
            cell_grid.north_south_cell_width_m[cell],
            assignments.vertical_cell_width_m[cell],
            1.0e-9,
        );
    }
}

test "neighbour detection marks exactly the interior faces" {
    // Corner of a 2x2 grid: cell 0 is north-west, so it has east and south
    // neighbours only.
    const north_west = grid_environment.neighborsOfCell(0, 2, 2);
    try std.testing.expect(!north_west.north and !north_west.west);
    try std.testing.expect(north_west.east and north_west.south);
    // Centre of a 3x3 grid has all four.
    const centre = grid_environment.neighborsOfCell(4, 3, 3);
    try std.testing.expect(centre.north and centre.east and centre.south and centre.west);
    // A single cell has none.
    const lone = grid_environment.neighborsOfCell(0, 1, 1);
    try std.testing.expect(!lone.north and !lone.east and !lone.south and !lone.west);
}

test "domain topography carries the site file's terrain values" {
    const allocator = std.testing.allocator;
    var sites = site_catalog.Catalog.init(allocator);
    defer sites.deinit();
    _ = try sites.appendFromSource("site", test_fixtures.site_source, 1, 1);

    var cell_grid = try grid(allocator, 1, 1);
    defer cell_grid.deinit();
    var files = try grid_input_files.CellFiles.parse(
        allocator,
        "grid_cell 45.5 -80.5 site authoritative_soil\n",
        cell_grid,
    );
    defer files.deinit();
    var assignments = try grid_environment.Assignments.init(allocator, files, sites, cell_grid);
    defer assignments.deinit();

    const domain: @import("../driver/runscript.zig").Domain = .{
        .west_column = 1,
        .north_row = 1,
        .east_column = 1,
        .south_row = 1,
    };
    var combined = try assignments.buildDomainTopography(domain, files, sites);
    defer combined.deinit();
    const site = sites.entries.items[0].site;
    try std.testing.expectEqualStrings("authoritative_soil", combined.units[0].soil_profile_file);
    try std.testing.expectEqual(site.compass_aspect_degrees, combined.units[0].compass_aspect_degrees);
    try std.testing.expectEqual(site.slope_degrees, combined.units[0].slope_degrees);
    try std.testing.expectEqual(site.initial_snowpack_depth_m, combined.units[0].initial_snowpack_depth_m);
    try std.testing.expectEqual(site.geometricAspectDegrees(), combined.units[0].geometric_aspect_degrees);
}

test "environment assignment requires every referenced site file" {
    const allocator = std.testing.allocator;
    var sites = site_catalog.Catalog.init(allocator);
    defer sites.deinit();
    var cell_grid = try grid(allocator, 1, 1);
    defer cell_grid.deinit();
    var files = try grid_input_files.CellFiles.parse(
        allocator,
        "grid_cell 45.5 -80.5 absent_site soil\n",
        cell_grid,
    );
    defer files.deinit();
    try std.testing.expectError(
        error.SiteFileNotLoaded,
        grid_environment.Assignments.init(allocator, files, sites, cell_grid),
    );
}
