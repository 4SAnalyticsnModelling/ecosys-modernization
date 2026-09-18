const std = @import("std");
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");
const simulation_timeline = @import("../../core/simulation_timeline.zig");

pub const Delimiter = enum {
    comma,
    tab,
    space,
    pipe,

    pub fn byte(self: Delimiter) u8 {
        return switch (self) {
            .comma => ',',
            .tab => '\t',
            .space => ' ',
            .pipe => '|',
        };
    }
};

pub const Variable = struct {
    name: []const u8,
    unit: []const u8,
};

pub const Timestamp = struct {
    year: i32,
    day_of_year: u16,
    month: u8,
    day: u8,
    hour: u8,
};

pub const Record = struct {
    timestamp: Timestamp,
    /// Site longitude in degrees east, from the site file's
    /// `longitude_degrees_east`. This is the physical coordinate the user
    /// entered, not a grid index: an output row must be locatable on the earth
    /// without knowing the grid layout.
    longitude_degrees_east: f64,
    /// Site latitude in degrees north, from `latitude_degrees_north`.
    latitude_degrees_north: f64,
    values: []const f64,
};

/// Writes a stable, allocation-free heading for only the variables selected
/// by the runtime output editor.
pub fn writeHeader(writer: *std.Io.Writer, variables: []const Variable, enabled: []const bool, delimiter: Delimiter) !void {
    if (variables.len != enabled.len) return error.OutputSelectionDimensionMismatch;
    const separator = delimiter.byte();
    const fixed = [_][]const u8{ "year", "day_of_year", "month", "day", "hour", "longitude", "latitude" };
    for (fixed, 0..) |heading, index| {
        if (index != 0) try writer.writeByte(separator);
        try writer.writeAll(heading);
    }
    for (variables, enabled) |variable, selected| {
        if (!selected) continue;
        try validateLabel(variable.name, separator);
        try validateLabel(variable.unit, separator);
        try writer.writeByte(separator);
        try writer.print("{s}[{s}]", .{ variable.name, variable.unit });
    }
    try writer.writeByte('\n');
}

/// Streams one selected record without assembling a second output row. Any
/// NaN or infinity aborts before that value can silently enter an output file.
pub fn writeRecord(writer: *std.Io.Writer, record: Record, enabled: []const bool, delimiter: Delimiter) !void {
    if (record.values.len != enabled.len) return error.OutputSelectionDimensionMismatch;
    try validateTimestamp(record.timestamp);
    // Physical coordinate ranges, matching `site.zig`'s own validation. A grid
    // index could only be zero-checked; a real coordinate can be checked against
    // the earth, which also catches a caller still passing an index.
    if (!std.math.isFinite(record.longitude_degrees_east) or
        record.longitude_degrees_east < -180 or record.longitude_degrees_east > 180 or
        !std.math.isFinite(record.latitude_degrees_north) or
        record.latitude_degrees_north < -90 or record.latitude_degrees_north > 90)
        return error.InvalidOutputSiteCoordinate;
    for (record.values, enabled) |value, selected|
        if (selected and !std.math.isFinite(value))
            return error.NonFiniteOutputValue;
    const separator = delimiter.byte();
    try writer.print("{d}{c}{d}{c}{d}{c}{d}{c}{d}{c}{d}{c}{d}", .{ record.timestamp.year, separator, record.timestamp.day_of_year, separator, record.timestamp.month, separator, record.timestamp.day, separator, record.timestamp.hour, separator, record.longitude_degrees_east, separator, record.latitude_degrees_north });
    for (record.values, enabled) |value, selected| {
        if (!selected) continue;
        try writer.writeByte(separator);
        try writer.print("{e}", .{value});
    }
    try writer.writeByte('\n');
}

/// Subject of an output file: the whole soil/ecosystem column, or one plant
/// species. The source model encoded this as a digit in the file name, `0` for
/// FOUTS soil output and `1..5` for FOUTP per-plant output.
pub const Subject = union(enum) {
    /// Whole-column soil and ecosystem output, the source model's `0`.
    soil_or_eco,
    /// The label is descriptive; the 1-based population slot is the unique key.
    /// Two assigned populations may share a species input file or differ only
    /// in case, which is not a distinct filename on every supported platform.
    species: struct { name: []const u8, population_number: usize },
};

/// Which pass of the run produced a row set.
///
/// A runscript may replay the same forcing years many times with continuous
/// state, so CALENDAR YEAR ALONE DOES NOT IDENTIFY A YEAR OF SIMULATION. The
/// production Ottawa deck is 6 forcing years x 5 repeats: calendar 1998 occurs
/// five times, and without these ordinals all five write the same file name.
/// Since the writer reopens with `truncate = false`
/// (`io/output/hour_transaction.zig:300`), the later passes APPEND into the
/// earlier pass's rows rather than replacing them, leaving one file whose rows
/// cannot be attributed to a pass. 24 of that deck's 30 simulated years were
/// unrecoverable that way.
///
/// All ordinals are 1-based and match the execution-evidence journal. Scene
/// numbers are global runscript scene indices, not offsets within a scenario.
/// Scenario and scene are required even when their calendar years coincide.
pub const PassOrdinals = struct {
    execution_number: u32,
    scenario_number: u32,
    repeat_number: u32,
    scene_number: u32,

    pub fn fromScenePass(pass: simulation_timeline.ScenePass) !PassOrdinals {
        return .{
            .execution_number = try oneBased(pass.execution_iteration),
            .scenario_number = try oneBased(pass.scenario_index),
            .repeat_number = try oneBased(pass.scenario_iteration),
            .scene_number = try oneBased(pass.scene_index),
        };
    }

    fn oneBased(index: usize) !u32 {
        const narrowed = std.math.cast(u32, index) orelse return error.InvalidOutputFileName;
        return std.math.add(u32, narrowed, 1) catch error.InvalidOutputFileName;
    }
};

/// Bind restart/output cursors to this naming contract as well as the deck.
/// Reusing a cursor from the former execution/repeat-only filenames would
/// otherwise append new-contract files alongside incomplete old-contract files.
pub fn runIdentity(runscript_source: []const u8) u64 {
    var hash = std.hash.Wyhash.init(0x45434f5359534e47);
    hash.update("ecosys-output-full-identity-model-hour-v3\x00");
    hash.update(runscript_source);
    return hash.final() | 1;
}

/// Builds a self-describing output file name:
///
///     lat_<lat>_lon_<lon>_<subject>_<year>_exec<n>_scenario<n>_rep<n>_scene<n>_cell<n>_pop<n>_<editor>.txt
///
/// Cell numbers are the 1-based global cell storage index, independent of tile
/// scheduling and worker count. Population zero denotes soil/ecosystem output;
/// assigned plant populations use their 1-based slot within the cell.
///
/// This replaces the source model's positional stem (`010101998f25ed1.txt`), whose
/// leading digits were grid column, grid row and a species digit. That encoding
/// could not be read without knowing the grid layout, capped species at one digit,
/// and gave no hint of the site's real location. Coordinates and species labels
/// remain human-readable, but are not uniqueness keys. Rounded or identical
/// coordinates and repeated species names cannot merge distinct storage slots.
/// Every (execution, scenario, repeat, scene, cell, population, year, editor)
/// row set has a distinct name within its output category. Rows retain the
/// unrounded physical coordinates.
pub fn buildOutputFileName(
    allocator: std.mem.Allocator,
    latitude_degrees_north: f64,
    longitude_degrees_east: f64,
    subject: Subject,
    year: i32,
    pass: PassOrdinals,
    cell_number: usize,
    editor_name: []const u8,
) ![]u8 {
    // 1-based by contract: a zero would mean the caller passed a raw loop index
    // and every pass would share the name of a pass that does not exist.
    if (pass.execution_number == 0 or pass.scenario_number == 0 or
        pass.repeat_number == 0 or pass.scene_number == 0 or cell_number == 0)
        return error.InvalidOutputFileName;
    // A runscript may select an editor by path, since the selection files can
    // be filed in their own directory. The output name identifies which editor
    // produced the rows, not where its selection file was kept, so only the
    // final component is used.
    const editor_base = std.fs.path.basename(editor_name);
    if (year <= 0 or year > 9999 or !safeEditorName(editor_base))
        return error.InvalidOutputFileName;
    if (!std.math.isFinite(latitude_degrees_north) or
        latitude_degrees_north < -90 or latitude_degrees_north > 90 or
        !std.math.isFinite(longitude_degrees_east) or
        longitude_degrees_east < -180 or longitude_degrees_east > 180)
        return error.InvalidOutputFileName;
    const subject_text = switch (subject) {
        .soil_or_eco => "soil_or_eco",
        .species => |plant| plant.name,
    };
    const population_number = switch (subject) {
        .soil_or_eco => @as(usize, 0),
        .species => |plant| if (plant.population_number != 0) plant.population_number else return error.InvalidOutputFileName,
    };
    // A species name becomes a path component, so it needs the same safety check
    // as the editor name: no separators, no parent traversal, no empty name.
    if (!safeEditorName(subject_text)) return error.InvalidOutputFileName;
    const stem = trimTextExtension(editor_base);
    if (stem.len == 0) return error.InvalidOutputFileName;
    return std.fmt.allocPrint(
        allocator,
        "lat_{d:.2}_lon_{d:.2}_{s}_{d:0>4}_exec{d:0>2}_scenario{d:0>2}_rep{d:0>2}_scene{d:0>2}_cell{d:0>2}_pop{d:0>2}_{s}.txt",
        .{
            latitude_degrees_north,
            longitude_degrees_east,
            subject_text,
            @as(u32, @intCast(year)),
            pass.execution_number,
            pass.scenario_number,
            pass.repeat_number,
            pass.scene_number,
            cell_number,
            population_number,
            stem,
        },
    );
}

/// Drops a trailing `.txt` so an editor name that already carries one does not
/// produce `..._f25ed1.txt.txt`.
fn trimTextExtension(name: []const u8) []const u8 {
    return if (hasTextExtension(name)) name[0 .. name.len - 4] else name;
}

fn hasTextExtension(name: []const u8) bool {
    return name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".txt");
}

fn safeEditorName(name: []const u8) bool {
    if (name.len == 0 or std.mem.indexOf(u8, name, "..") != null) return false;
    if (name[0] == ' ' or name[name.len - 1] == ' ' or name[name.len - 1] == '.')
        return false;
    for (name) |byte| {
        if (byte == 0 or byte < 0x20 or
            std.mem.indexOfScalar(u8, "/\\<>:\"|?*", byte) != null)
            return false;
    }
    return true;
}

fn validateTimestamp(timestamp: Timestamp) !void {
    if (timestamp.year <= 0 or timestamp.year > 9999 or timestamp.month == 0 or
        timestamp.month > 12 or timestamp.hour > 23)
        return error.InvalidOutputTimestamp;
    const expected = execution_calendar_date.dayOfYear(.{
        .day = timestamp.day,
        .month = timestamp.month,
        .year = @intCast(timestamp.year),
    }) catch return error.InvalidOutputTimestamp;
    if (expected != timestamp.day_of_year)
        return error.InvalidOutputTimestamp;
}

fn validateLabel(label: []const u8, delimiter: u8) !void {
    if (label.len == 0 or std.mem.indexOfScalar(u8, label, delimiter) != null or std.mem.indexOfAny(u8, label, "\r\n[]") != null) return error.InvalidOutputLabel;
}

test "selected output record streams headings units and finite values" {
    const variables = [_]Variable{
        .{ .name = "runoff", .unit = "mm" },
        .{ .name = "soil_temperature", .unit = "degC" },
        .{ .name = "water_table_depth", .unit = "m" },
    };
    const enabled = [_]bool{ true, false, true };
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writeHeader(&bytes.writer, &variables, &enabled, .pipe);
    try writeRecord(&bytes.writer, .{ .timestamp = .{ .year = 2001, .day_of_year = 32, .month = 2, .day = 1, .hour = 5 }, .longitude_degrees_east = -75.7, .latitude_degrees_north = 45.3, .values = &.{ 1.25, 99, 2.5 } }, &enabled, .pipe);
    try std.testing.expectEqualStrings("year|day_of_year|month|day|hour|longitude|latitude|runoff[mm]|water_table_depth[m]\n2001|32|2|1|5|-75.7|45.3|1.25e0|2.5e0\n", bytes.written());
}

test "SI unit labels with spaces stream under tab and are rejected under space" {
    const variables = [_]Variable{
        .{ .name = "litter_water_vapor_density", .unit = "g m-3" },
        .{ .name = "nitrous_oxide_emission", .unit = "g N m-2 h-1" },
    };
    const enabled = [_]bool{ true, true };
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writeHeader(&bytes.writer, &variables, &enabled, .tab);
    try std.testing.expectEqualStrings(
        "year\tday_of_year\tmonth\tday\thour\tlongitude\tlatitude\tlitter_water_vapor_density[g m-3]\tnitrous_oxide_emission[g N m-2 h-1]\n",
        bytes.written(),
    );

    // A space-delimited stream cannot carry a unit that contains spaces, so the
    // heading is rejected instead of producing ambiguous columns.
    var space_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer space_bytes.deinit();
    try std.testing.expectError(
        error.InvalidOutputLabel,
        writeHeader(&space_bytes.writer, &variables, &enabled, .space),
    );
}

test "output writer rejects nonfinite selected values" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try std.testing.expectError(error.NonFiniteOutputValue, writeRecord(&bytes.writer, .{ .timestamp = .{ .year = 2001, .day_of_year = 1, .month = 1, .day = 1, .hour = 0 }, .longitude_degrees_east = -75.7, .latitude_degrees_north = 45.3, .values = &.{std.math.nan(f64)} }, &.{true}, .comma));
}

test "output name is self describing: lat, lon, subject, year, editor" {
    const name = try buildOutputFileName(std.testing.allocator, 45.3, -75.7, .soil_or_eco, 1998, .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 }, 1, "f25ed1");
    defer std.testing.allocator.free(name);
    // Replaces the source model's positional stem `010101998f25ed1.txt`, whose
    // leading digits were grid column, grid row and a species digit.
    try std.testing.expectEqualStrings("lat_45.30_lon_-75.70_soil_or_eco_1998_exec01_scenario01_rep01_scene01_cell01_pop00_f25ed1.txt", name);
}

test "an editor name that already ends in .txt does not double the extension" {
    const name = try buildOutputFileName(std.testing.allocator, 45.3, -75.7, .soil_or_eco, 1998, .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 }, 1, "f25ed1.txt");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("lat_45.30_lon_-75.70_soil_or_eco_1998_exec01_scenario01_rep01_scene01_cell01_pop00_f25ed1.txt", name);
}

test "plant output names carry the species name rather than a digit" {
    const maize = try buildOutputFileName(std.testing.allocator, 45.3, -75.7, .{ .species = .{ .name = "maize", .population_number = 1 } }, 1998, .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 }, 1, "f25ch1");
    defer std.testing.allocator.free(maize);
    try std.testing.expectEqualStrings("lat_45.30_lon_-75.70_maize_1998_exec01_scenario01_rep01_scene01_cell01_pop01_f25ch1.txt", maize);
    // Species are no longer limited to one digit's worth of populations, and two
    // species at the same site and year get distinct files.
    const soybean = try buildOutputFileName(std.testing.allocator, 45.3, -75.7, .{ .species = .{ .name = "soybean", .population_number = 1 } }, 1998, .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 }, 1, "f25ch1");
    defer std.testing.allocator.free(soybean);
    try std.testing.expectEqualStrings("lat_45.30_lon_-75.70_soybean_1998_exec01_scenario01_rep01_scene01_cell01_pop01_f25ch1.txt", soybean);
}

test "southern and western sites keep their coordinate signs" {
    const name = try buildOutputFileName(std.testing.allocator, -33.87, 151.21, .soil_or_eco, 2001, .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 }, 1, "hourly_water");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("lat_-33.87_lon_151.21_soil_or_eco_2001_exec01_scenario01_rep01_scene01_cell01_pop00_hourly_water.txt", name);
}

test "each subject, year and editor combination yields a distinct file" {
    // The name is the complete key for the row set it contains, so varying any
    // one component must change it.
    const base = try buildOutputFileName(std.testing.allocator, 45.3, -75.7, .soil_or_eco, 1998, .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 }, 1, "f25ch1");
    defer std.testing.allocator.free(base);
    inline for (.{
        .{ 45.3, -75.7, Subject.soil_or_eco, 1999, "f25ch1" },
        .{ 45.3, -75.7, Subject.soil_or_eco, 1998, "f25wh1" },
        .{ 46.0, -75.7, Subject.soil_or_eco, 1998, "f25ch1" },
        .{ 45.3, -74.0, Subject.soil_or_eco, 1998, "f25ch1" },
    }) |variant| {
        const other = try buildOutputFileName(std.testing.allocator, variant[0], variant[1], variant[2], variant[3], .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 }, 1, variant[4]);
        defer std.testing.allocator.free(other);
        try std.testing.expect(!std.mem.eql(u8, base, other));
    }
}

test "output file names reject unsafe editor names, species and coordinates" {
    inline for (.{
        "",
        " hourly",
        "hourly ",
        "hourly.",
        "hourly:data",
        "hourly|data",
        "hourly?data",
    }) |name| {
        // Unsafe as an editor name.
        try std.testing.expectError(
            error.InvalidOutputFileName,
            buildOutputFileName(std.testing.allocator, 45.3, -75.7, .soil_or_eco, 2001, .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 }, 1, name),
        );
        // And equally unsafe as a species name, since both become path components.
        try std.testing.expectError(
            error.InvalidOutputFileName,
            buildOutputFileName(std.testing.allocator, 45.3, -75.7, .{ .species = .{ .name = name, .population_number = 1 } }, 2001, .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 }, 1, "hourly"),
        );
    }
    // Coordinates must be real, which also catches a caller still passing an index
    // for longitude only if it is out of range; the year bounds are unchanged.
    inline for (.{
        .{ 91.0, 0.0 },
        .{ -91.0, 0.0 },
        .{ 0.0, 181.0 },
        .{ 0.0, -181.0 },
    }) |pair| try std.testing.expectError(
        error.InvalidOutputFileName,
        buildOutputFileName(std.testing.allocator, pair[0], pair[1], .soil_or_eco, 2001, .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 }, 1, "hourly"),
    );
    try std.testing.expectError(
        error.InvalidOutputFileName,
        buildOutputFileName(std.testing.allocator, 45.3, -75.7, .soil_or_eco, 0, .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 }, 1, "hourly"),
    );
}

test "repeats of one calendar year get distinct output file names" {
    // The whole point of PassOrdinals. The production deck replays 6 forcing
    // years 5 times with continuous state, so calendar 1998 is simulated five
    // separate times. Before these ordinals all five produced one name, and
    // because the writer reopens with `truncate = false` the passes appended
    // into each other -- 24 of 30 simulated years became unattributable.
    const allocator = std.testing.allocator;
    var seen: [5][]u8 = undefined;
    for (0..5) |index| {
        seen[index] = try buildOutputFileName(
            allocator,
            45.3,
            -75.7,
            .soil_or_eco,
            1998,
            .{ .execution_number = 1, .scenario_number = 1, .repeat_number = @intCast(index + 1), .scene_number = 1 },
            1,
            "f25ed1",
        );
    }
    defer for (seen) |name| allocator.free(name);
    for (seen, 0..) |name, outer| {
        for (seen, 0..) |other, inner| {
            if (outer == inner) continue;
            try std.testing.expect(!std.mem.eql(u8, name, other));
        }
    }
    try std.testing.expectEqualStrings(
        "lat_45.30_lon_-75.70_soil_or_eco_1998_exec01_scenario01_rep03_scene01_cell01_pop00_f25ed1.txt",
        seen[2],
    );
    // A different execution of the same repeat is also distinct, so nesting the
    // deck inside an outer execution loop cannot collide either.
    const other_execution = try buildOutputFileName(
        allocator,
        45.3,
        -75.7,
        .soil_or_eco,
        1998,
        .{ .execution_number = 2, .scenario_number = 1, .repeat_number = 3, .scene_number = 1 },
        1,
        "f25ed1",
    );
    defer allocator.free(other_execution);
    try std.testing.expect(!std.mem.eql(u8, seen[2], other_execution));
}

test "a zero pass ordinal is rejected rather than naming a pass that does not exist" {
    // 1-based by contract. A caller forwarding a raw loop index would otherwise
    // produce `exec00`/`rep00` for the first pass and silently shift every
    // subsequent name by one.
    for ([_]PassOrdinals{
        .{ .execution_number = 0, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 },
        .{ .execution_number = 1, .scenario_number = 0, .repeat_number = 1, .scene_number = 1 },
        .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 0, .scene_number = 1 },
        .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 0 },
        .{ .execution_number = 0, .scenario_number = 1, .repeat_number = 0, .scene_number = 1 },
    }) |pass| try std.testing.expectError(
        error.InvalidOutputFileName,
        buildOutputFileName(std.testing.allocator, 45.3, -75.7, .soil_or_eco, 1998, pass, 1, "f25ed1"),
    );
}

test "output identity preserves every nested pass and distinct cell and population" {
    const allocator = std.testing.allocator;
    var seen: std.StringHashMap(void) = .init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    var iterator = try simulation_timeline.PassIterator.init(&.{
        .{ .first_scene_index = 0, .scene_count = 2, .repeat_count = 2 },
        .{ .first_scene_index = 2, .scene_count = 2, .repeat_count = 2 },
    }, 2);
    while (iterator.next()) |pass| {
        const ordinals = try PassOrdinals.fromScenePass(pass);
        for (0..2) |cell| for (0..2) |population| {
            // Both cells round to lat_45.30; both populations use the same
            // species label; every scene deliberately uses the same year.
            const name = try buildOutputFileName(allocator, 45.300 + @as(f64, @floatFromInt(cell)) * 0.001, -75.7, .{ .species = .{ .name = "maize", .population_number = population + 1 } }, 1998, ordinals, cell + 1, "f25ch1");
            errdefer allocator.free(name);
            try std.testing.expect(!seen.contains(name));
            try seen.put(name, {});
        };
    }
    try std.testing.expectEqual(@as(u32, 64), seen.count());
    // Hold all other pass fields constant: scenario is a key in its own right,
    // even if a future deck references the same global scene in two scenarios.
    const base = try PassOrdinals.fromScenePass(.{ .execution_iteration = 0, .scenario_index = 0, .scenario_iteration = 0, .scene_index = 0 });
    var other = base;
    other.scenario_number = 2;
    const a = try buildOutputFileName(allocator, 45.3, -75.7, .soil_or_eco, 1998, base, 1, "f25ch1");
    defer allocator.free(a);
    const b = try buildOutputFileName(allocator, 45.3, -75.7, .soil_or_eco, 1998, other, 1, "f25ch1");
    defer allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "output identity rejects zero storage slots and overflowing pass indices" {
    const pass = try PassOrdinals.fromScenePass(.{ .execution_iteration = 0, .scenario_index = 0, .scenario_iteration = 0, .scene_index = 0 });
    try std.testing.expectError(error.InvalidOutputFileName, buildOutputFileName(std.testing.allocator, 45.3, -75.7, .soil_or_eco, 1998, pass, 0, "hourly"));
    try std.testing.expectError(error.InvalidOutputFileName, buildOutputFileName(std.testing.allocator, 45.3, -75.7, .{ .species = .{ .name = "maize", .population_number = 0 } }, 1998, pass, 1, "hourly"));
    inline for (std.meta.fields(simulation_timeline.ScenePass)) |field| {
        var source: simulation_timeline.ScenePass = .{ .execution_iteration = 0, .scenario_index = 0, .scenario_iteration = 0, .scene_index = 0 };
        @field(source, field.name) = std.math.maxInt(u32);
        try std.testing.expectError(error.InvalidOutputFileName, PassOrdinals.fromScenePass(source));
    }
}

test "output identity invalidates old naming contract restart cursors" {
    const source = "same immutable runscript";
    const legacy_identity = std.hash.Wyhash.hash(0x45434f5359534e47, source) | 1;
    try std.testing.expect(runIdentity(source) != legacy_identity);
    var previous_clock_identity = std.hash.Wyhash.init(0x45434f5359534e47);
    previous_clock_identity.update("ecosys-output-full-identity-v2\x00");
    previous_clock_identity.update(source);
    try std.testing.expect(runIdentity(source) != (previous_clock_identity.final() | 1));
    try std.testing.expectEqual(runIdentity(source), runIdentity(source));
    try std.testing.expect(runIdentity(source) != runIdentity("different runscript"));
}

test "an editor selected by path contributes only its final component" {
    // Selection files may be filed in their own directory, so the runscript
    // names one by path. The output identifies which editor produced the rows,
    // not where its selection file was kept.
    inline for (.{
        "f25ed1",
        "write_output_options/f25ed1",
        "runottawa_output_files/write_output_options/f25ed1",
        "runottawa_output_files\\write_output_options\\f25ed1",
    }) |editor_name| {
        const name = try buildOutputFileName(
            std.testing.allocator,
            45.3,
            -75.7,
            .soil_or_eco,
            1998,
            .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 },
            1,
            editor_name,
        );
        defer std.testing.allocator.free(name);
        try std.testing.expectEqualStrings(
            "lat_45.30_lon_-75.70_soil_or_eco_1998_exec01_scenario01_rep01_scene01_cell01_pop00_f25ed1.txt",
            name,
        );
    }
}

test "a species name may not carry a path, since it is not a selection file" {
    // Unlike an editor name, a species name is never a path in any input: it
    // names a plant. A separator there means the value is wrong, so stripping
    // it would hide the defect.
    inline for (.{ "../maize", "subdir/maize", "subdir\\maize" }) |species|
        try std.testing.expectError(
            error.InvalidOutputFileName,
            buildOutputFileName(
                std.testing.allocator,
                45.3,
                -75.7,
                .{ .species = .{ .name = species, .population_number = 1 } },
                2001,
                .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 },
                1,
                "hourly",
            ),
        );
}

test "output timestamps reject impossible or inconsistent calendar values" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    inline for (.{
        Timestamp{ .year = 2001, .day_of_year = 60, .month = 2, .day = 29, .hour = 0 },
        Timestamp{ .year = 2001, .day_of_year = 121, .month = 4, .day = 31, .hour = 0 },
        Timestamp{ .year = 2001, .day_of_year = 2, .month = 1, .day = 1, .hour = 0 },
        Timestamp{ .year = 0, .day_of_year = 1, .month = 1, .day = 1, .hour = 0 },
    }) |timestamp| try std.testing.expectError(
        error.InvalidOutputTimestamp,
        writeRecord(
            &bytes.writer,
            .{
                .timestamp = timestamp,
                .longitude_degrees_east = -75.7,
                .latitude_degrees_north = 45.3,
                .values = &.{1},
            },
            &.{true},
            .tab,
        ),
    );
    try validateTimestamp(.{
        .year = 2000,
        .day_of_year = 60,
        .month = 2,
        .day = 29,
        .hour = 23,
    });
    try validateTimestamp(.{
        .year = 1900,
        .day_of_year = 60,
        .month = 2,
        .day = 29,
        .hour = 23,
    });
}
