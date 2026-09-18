//! Required input-layout tests use the authorized byte-identical packaged
//! Ottawa inputs. Missing files are failures, never clean-checkout skips.
//! PROVENANCE.json independently pins every copied file to the immutable deck.

const std = @import("std");
const cell_grid_file = @import("../io/input/cell_grid_file.zig");
const grid_input_files = @import("../io/input/grid_input_files.zig");
const grid_environment = @import("../state/grid_environment.zig");
const land_management = @import("../management/land_management.zig");
const plant_assignment = @import("../state/plant_assignment.zig");
const runscript_module = @import("../driver/runscript.zig");
const site_catalog = @import("../state/site_catalog.zig");
const site_module = @import("../state/site.zig");
const spatial_grid = @import("../state/spatial_grid.zig");
const execution_evidence = @import("../core/execution_evidence.zig");
const simulation_timeline = @import("../core/simulation_timeline.zig");
const scene_options = @import("../core/options.zig");
const weather = @import("../io/input/weather.zig");
const hourly_weather = @import("../io/input/hourly_weather_stream.zig");

const example_root = "src/validation/testdata/ottawa";
const input_root = example_root ++ "/runottawa_input_files";

fn readExample(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ input_root, relative_path });
    defer allocator.free(path);
    return readRequired(allocator, path);
}

fn readRequired(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(4 * 1024 * 1024));
}

/// The grid the production runscript declares: a single 0.10 degree cell
/// centred on the Ottawa site.
fn ottawaGrid(allocator: std.mem.Allocator) !spatial_grid.RegularGrid {
    return spatial_grid.RegularGrid.init(allocator, .{
        .minimum_latitude_degrees_north = 45.25,
        .maximum_latitude_degrees_north = 45.35,
        .minimum_longitude_degrees_east = -75.75,
        .maximum_longitude_degrees_east = -75.65,
        .latitude_interval_degrees = 0.10,
        .longitude_interval_degrees = 0.10,
    });
}

test "the shipped site file parses and yields its terrain values" {
    const allocator = std.testing.allocator;
    const source = try readExample(allocator, "landscape/f25si98");
    defer allocator.free(source);

    var site = try site_module.parse(allocator, source, 1, 1);
    defer site.deinit();
    // Record 1 of the shipped file is `92 5.4 3 94.6 0.23 0.00`.
    try std.testing.expectApproxEqAbs(@as(f64, 92), site.elevation_m, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5.4), site.mean_annual_air_temperature_c, 1.0e-12);
    try std.testing.expectEqual(@as(u8, 3), site.water_table_mode);
    try std.testing.expectApproxEqAbs(@as(f64, 94.6), site.compass_aspect_degrees, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.23), site.slope_degrees, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00), site.initial_snowpack_depth_m, 1.0e-12);
}

test "the shipped grid mapping resolves its coordinate to the declared cell" {
    const allocator = std.testing.allocator;
    const source = try readExample(allocator, "landscape/grid_cell_inputs.txt");
    defer allocator.free(source);

    var grid = try ottawaGrid(allocator);
    defer grid.deinit();
    var files = try grid_input_files.CellFiles.parse(allocator, source, grid);
    defer files.deinit();

    try std.testing.expectEqual(@as(usize, 1), files.site_file_by_cell.len);
    try std.testing.expectEqualStrings("f25si98", files.site_file_by_cell[0]);
    try std.testing.expectEqualStrings("f25sol98", files.soil_file_by_cell[0]);
    // The coordinate the user wrote is retained for output naming and solar
    // geometry, not replaced by the cell centre.
    try std.testing.expectApproxEqAbs(
        @as(f64, 45.30),
        files.latitude_degrees_north_by_cell[0],
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, -75.70),
        files.longitude_degrees_east_by_cell[0],
        1.0e-12,
    );
}

test "the shipped management grid parses in fertilizer irrigation tillage order" {
    const allocator = std.testing.allocator;
    const source = try readExample(allocator, "management/soil/management_grid_1998.txt");
    defer allocator.free(source);

    var grid = try ottawaGrid(allocator);
    defer grid.deinit();
    var assignments = try land_management.parse(allocator, source, grid);
    defer assignments.deinit();
    // The shipped record is `management_cell 45.30 -75.70 f25fr98 NO f25til98`.
    try std.testing.expectEqualStrings("f25fr98", assignments.units[0].fertilizer_file);
    try std.testing.expectEqualStrings("NO", assignments.units[0].irrigation_file);
    try std.testing.expectEqualStrings("f25til98", assignments.units[0].tillage_file);
}

test "the shipped plant grid parses and its functional type is used verbatim" {
    const allocator = std.testing.allocator;
    const source = try readExample(allocator, "management/plant/plant_grid_1998.txt");
    defer allocator.free(source);

    var grid = try ottawaGrid(allocator);
    defer grid.deinit();
    var assignments = try plant_assignment.parse(allocator, source, grid);
    defer assignments.deinit();
    try std.testing.expectEqual(@as(usize, 1), assignments.units[0].species.len);
    // `maiz33` names the file on disk, so no ecosystem-type suffix is derived.
    try std.testing.expectEqualStrings("maiz33", assignments.units[0].species[0].species_file);
    try std.testing.expectEqualStrings("f25plt98", assignments.units[0].species[0].management_file);
}

test "adding a second plant record to the shipped grid grows that cell to two species" {
    const allocator = std.testing.allocator;
    const source = try readExample(allocator, "management/plant/plant_grid_1998.txt");
    defer allocator.free(source);

    // The production file has one plant. Appending a second record at the same
    // coordinate is how a user states an intercropped cell, so that path is
    // exercised against the real file rather than only against a fixture.
    const intercropped = try std.mem.concat(allocator, u8, &.{
        source,
        "\nplant\t45.30\t-75.70\tsoyb33\tf25plt99\n",
    });
    defer allocator.free(intercropped);

    var grid = try ottawaGrid(allocator);
    defer grid.deinit();
    var assignments = try plant_assignment.parse(allocator, intercropped, grid);
    defer assignments.deinit();
    try std.testing.expectEqual(@as(usize, 2), assignments.units[0].species.len);
    try std.testing.expectEqualStrings("maiz33", assignments.units[0].species[0].species_file);
    try std.testing.expectEqualStrings("soyb33", assignments.units[0].species[1].species_file);
}

test "the shipped weather grid resolves its coordinate to the declared cell" {
    const allocator = std.testing.allocator;
    const source = try readExample(allocator, "weather/weather_grid_1998.txt");
    defer allocator.free(source);

    var grid = try ottawaGrid(allocator);
    defer grid.deinit();
    var files = try grid_input_files.WeatherFiles.parse(allocator, source, grid);
    defer files.deinit();
    // The shipped record is `weather_cell 45.30 -75.70 gbf98h`.
    try std.testing.expectEqual(@as(usize, 1), files.file_by_cell.len);
    try std.testing.expectEqualStrings("gbf98h", files.file_by_cell[0]);
}

test "the shipped climate grid names one forcing file for every cell" {
    const allocator = std.testing.allocator;
    const source = try readExample(
        allocator,
        "climate_forcing_and_simulation_controls/climate_grid_1998.txt",
    );
    defer allocator.free(source);

    var grid = try ottawaGrid(allocator);
    defer grid.deinit();
    const shared = try cell_grid_file.readSharedName(allocator, source, grid, "climate_cell");
    defer allocator.free(shared);
    try std.testing.expectEqualStrings("f25y98", shared);
}

test "the single shipped cell takes both dimensions from its site file" {
    const allocator = std.testing.allocator;
    const site_source = try readExample(allocator, "landscape/f25si98");
    defer allocator.free(site_source);
    const mapping_source = try readExample(allocator, "landscape/grid_cell_inputs.txt");
    defer allocator.free(mapping_source);

    var sites = site_catalog.Catalog.init(allocator);
    defer sites.deinit();
    _ = try sites.appendFromSource("f25si98", site_source, 1, 1);
    var grid = try ottawaGrid(allocator);
    defer grid.deinit();
    var files = try grid_input_files.CellFiles.parse(allocator, mapping_source, grid);
    defer files.deinit();

    var assignments = try grid_environment.Assignments.init(allocator, files, sites, grid);
    defer assignments.deinit();

    // The shipped run is one cell, so it has no neighbour on either axis and
    // both widths come from the site file's own trailing records, which are
    // 1.0 m by 1.0 m. A 0.10 degree cell would be several kilometres wide, so
    // the two sources are not confusable.
    const site = sites.entries.items[0].site;
    try std.testing.expectApproxEqAbs(
        site.horizontal_cell_widths_m[0],
        assignments.horizontal_cell_width_m[0],
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        site.vertical_cell_widths_m[0],
        assignments.vertical_cell_width_m[0],
        1.0e-12,
    );
    try std.testing.expect(assignments.horizontal_cell_width_m[0] < 1000);
    try std.testing.expect(grid.east_west_cell_width_m[0] > 5000);
}

test "the shipped snowpack depth reaches the topography that ground radiation reads" {
    const allocator = std.testing.allocator;
    const site_source = try readExample(allocator, "landscape/f25si98");
    defer allocator.free(site_source);
    const mapping_source = try readExample(allocator, "landscape/grid_cell_inputs.txt");
    defer allocator.free(mapping_source);

    var sites = site_catalog.Catalog.init(allocator);
    defer sites.deinit();
    _ = try sites.appendFromSource("f25si98", site_source, 1, 1);
    var grid = try ottawaGrid(allocator);
    defer grid.deinit();
    var files = try grid_input_files.CellFiles.parse(allocator, mapping_source, grid);
    defer files.deinit();
    var assignments = try grid_environment.Assignments.init(allocator, files, sites, grid);
    defer assignments.deinit();

    const domain: runscript_module.Domain = .{
        .west_column = 1,
        .north_row = 1,
        .east_column = 1,
        .south_row = 1,
    };
    var topography = try assignments.buildDomainTopography(domain, files, sites);
    defer topography.deinit();

    // `ground_radiation.State.initMapped` reads exactly this field to set the
    // initial surface albedo, so carrying the shipped 0.00 m through to here is
    // what makes record 1's sixth field load-bearing rather than merely parsed.
    // The three terrain fields are checked together, since they travel as one
    // group from the site file into the landscape unit.
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.00),
        topography.units[0].initial_snowpack_depth_m,
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.23),
        topography.units[0].slope_degrees,
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 94.6),
        topography.units[0].compass_aspect_degrees,
        1.0e-12,
    );
    // 450 - 94.6, the convention the radiation consumers expect.
    try std.testing.expectApproxEqAbs(
        @as(f64, 355.4),
        topography.units[0].geometric_aspect_degrees,
        1.0e-12,
    );
    // The soil filename comes from the grid mapping, not the site file.
    try std.testing.expectEqualStrings("f25sol98", topography.units[0].soil_profile_file);
}

test "the shipped runscript declares the input and output roots" {
    const allocator = std.testing.allocator;
    const source = try readRequired(allocator, example_root ++ "/runottawa");
    defer allocator.free(source);

    var parsed = try runscript_module.parse(allocator, source);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("runottawa_input_files", parsed.input_root);
    try std.testing.expectEqualStrings("runottawa_output_files", parsed.output_root);
    // The geospatial record is what turns a coordinate into a cell index.
    const bounds = parsed.geospatial_bounds orelse return error.MissingGeospatialGridRecord;
    try std.testing.expectApproxEqAbs(@as(f64, 0.10), bounds.latitude_interval_degrees, 1.0e-12);
}

test "required Ottawa inputs match immutable byte provenance" {
    const allocator = std.testing.allocator;
    const metadata = try readRequired(allocator, example_root ++ "/PROVENANCE.json");
    defer allocator.free(metadata);
    const File = struct { path: []const u8, bytes: usize, sha256: []const u8 };
    const Manifest = struct { source: []const u8, files: []const File };
    const manifest = try std.json.parseFromSlice(Manifest, allocator, metadata, .{});
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 78), manifest.value.files.len);
    for (manifest.value.files) |file| {
        const path = try std.fs.path.join(allocator, &.{ example_root, file.path });
        defer allocator.free(path);
        const bytes = try readRequired(allocator, path);
        defer allocator.free(bytes);
        try std.testing.expectEqual(file.bytes, bytes.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hexadecimal = std.fmt.bytesToHex(digest, .upper);
        try std.testing.expectEqualStrings(file.sha256, &hexadecimal);
    }
}

test "missing required Ottawa input is an error instead of a skipped assertion" {
    try std.testing.expectError(error.FileNotFound, readRequired(std.testing.allocator, example_root ++ "/nonexistent-required-input"));
}

test "model hour journals all actual Ottawa forcing endpoints across thirty passes" {
    const allocator = std.testing.allocator;
    const files = [_][]const u8{ "gbf98h", "gbf99h", "gbf00h", "gbf01h", "gbf02h", "gbf97h" };
    var scenes: [6]scene_options.SceneOptions = undefined;
    for (&scenes, 0..) |*scene, index| {
        scene.start_date = .{ .year = @intCast(1998 + index), .month = 1, .day = 1 };
        scene.end_date = .{ .year = @intCast(1998 + index), .month = 12, .day = 31 };
    }
    const scenarios = [_]runscript_module.Scenario{.{ .first_scene_index = 0, .scene_count = 6, .repeat_count = 5 }};
    var plan = try execution_evidence.Plan.init(allocator, &scenes, &scenarios, 1);
    defer plan.deinit(allocator);
    var iterator = try simulation_timeline.PassIterator.init(&scenarios, 1);
    var buffer: [4096]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&buffer);
    var journal = try execution_evidence.Journal.start(&plan, &sink.writer, "actual-weather-clock-fixture", 0, true);
    var total_hour: usize = 0;
    var pass_index: usize = 0;
    while (iterator.next()) |pass| : (pass_index += 1) {
        const path = try std.fs.path.join(allocator, &.{ input_root, "weather", files[pass.scene_index] });
        defer allocator.free(path);
        const source = try weather.WeatherStream.init(allocator, std.testing.io, path, 4096);
        defer source.deinit();
        var stream = try hourly_weather.Stream.init(source, 92, 45.30, false, .{});
        var slots: u32 = 0;
        for (1..plan.passes[pass_index].hours + 1) |scene_hour| {
            const observation = try stream.next() orelse return error.RequiredOttawaWeatherTruncated;
            const timestamp = try observation.timestamp.modelHour(scenes[pass.scene_index].start_date.year);
            total_hour += 1;
            // The observed identity comes solely from the actual reader and
            // traversal counters, never Plan.identityAt. Journal checks it.
            try journal.attempt(.{
                .execution = pass.execution_iteration + 1,
                .scenario = pass.scenario_index + 1,
                .repeat = pass.scenario_iteration + 1,
                .scene = pass.scene_index + 1,
                .scene_hour = scene_hour,
                .total_hour = total_hour,
                .year = timestamp.year.?,
                .day = timestamp.day_of_year.?,
                .hour = timestamp.hour,
            });
            const slot = try timestamp.modelHourIndex();
            const bit = @as(u32, 1) << @as(u5, @intCast(slot));
            try std.testing.expectEqual(@as(u32, 0), slots & bit);
            slots |= bit;
            if (scene_hour % 24 == 0) {
                try std.testing.expectEqual(@as(u32, 0xffffff), slots);
                slots = 0;
            }
            try journal.commit();
            try journal.accept();
        }
    }
    try std.testing.expectEqual(@as(usize, 262920), total_hour);
    try std.testing.expectEqual(@as(usize, 30), pass_index);
    try journal.finish();
}
