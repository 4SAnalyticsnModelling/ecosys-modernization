const std = @import("std");
const delimited_input = @import("delimited_input.zig");
const spatial_grid = @import("../../state/spatial_grid.zig");

/// Per-cell input file selection, keyed by the cell's real-world coordinate.
///
/// A record names a latitude and longitude rather than a row and column,
/// because a grid index is an internal artifact of the declared geospatial
/// extent and interval: change the extent and every index shifts, while the
/// site itself has not moved. The coordinate is resolved to a cell through
/// the same `RegularGrid` the rest of the model uses, so there is exactly one
/// definition of where a cell is.
pub const CellFiles = struct {
    allocator: std.mem.Allocator,
    column_count: usize,
    row_count: usize,
    site_file_by_cell: [][]u8,
    soil_file_by_cell: [][]u8,
    latitude_degrees_north_by_cell: []f64,
    longitude_degrees_east_by_cell: []f64,

    pub fn parse(
        allocator: std.mem.Allocator,
        source: []const u8,
        grid: spatial_grid.RegularGrid,
    ) !CellFiles {
        const column_count = grid.column_count;
        const row_count = grid.row_count;
        const cell_count = try validateDimensions(column_count, row_count);
        const site_files = try allocator.alloc([]u8, cell_count);
        errdefer allocator.free(site_files);
        const soil_files = try allocator.alloc([]u8, cell_count);
        errdefer allocator.free(soil_files);
        const latitudes = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(latitudes);
        const longitudes = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(longitudes);
        const assigned = try allocator.alloc(bool, cell_count);
        defer allocator.free(assigned);
        @memset(assigned, false);

        errdefer for (assigned, 0..) |is_assigned, cell| {
            if (is_assigned) {
                allocator.free(site_files[cell]);
                allocator.free(soil_files[cell]);
            }
        };

        var records = delimited_input.records(source);
        while (records.next()) |record| {
            if (hasEmptyExplicitField(record))
                return error.EmptyGridInputRecordValue;
            var fields = delimited_input.recordTokens(record);
            const record_name = fields.next() orelse unreachable;
            if (!std.ascii.eqlIgnoreCase(record_name, "grid_cell"))
                return error.InvalidGridCellInputRecord;
            const latitude = try degrees(&fields);
            const longitude = try degrees(&fields);
            const cell = try grid.cellIndexForCoordinate(latitude, longitude);
            if (assigned[cell]) return error.DuplicateGridCellCoordinate;
            const site_file = try duplicateFileName(allocator, &fields);
            errdefer allocator.free(site_file);
            const soil_file = try duplicateFileName(allocator, &fields);
            errdefer allocator.free(soil_file);
            try requireEnd(&fields);
            site_files[cell] = site_file;
            soil_files[cell] = soil_file;
            latitudes[cell] = latitude;
            longitudes[cell] = longitude;
            assigned[cell] = true;
        }
        for (assigned) |is_assigned| if (!is_assigned)
            return error.MissingGridCellInput;

        return .{
            .allocator = allocator,
            .column_count = column_count,
            .row_count = row_count,
            .site_file_by_cell = site_files,
            .soil_file_by_cell = soil_files,
            .latitude_degrees_north_by_cell = latitudes,
            .longitude_degrees_east_by_cell = longitudes,
        };
    }

    pub fn deinit(self: *CellFiles) void {
        for (0..self.site_file_by_cell.len) |cell| {
            self.allocator.free(self.site_file_by_cell[cell]);
            self.allocator.free(self.soil_file_by_cell[cell]);
        }
        self.allocator.free(self.site_file_by_cell);
        self.allocator.free(self.soil_file_by_cell);
        self.allocator.free(self.latitude_degrees_north_by_cell);
        self.allocator.free(self.longitude_degrees_east_by_cell);
        self.* = undefined;
    }
};

pub const WeatherFiles = struct {
    allocator: std.mem.Allocator,
    column_count: usize,
    row_count: usize,
    file_by_cell: [][]u8,

    pub fn parse(
        allocator: std.mem.Allocator,
        source: []const u8,
        grid: spatial_grid.RegularGrid,
    ) !WeatherFiles {
        const column_count = grid.column_count;
        const row_count = grid.row_count;
        const cell_count = try validateDimensions(column_count, row_count);
        const files = try allocator.alloc([]u8, cell_count);
        errdefer allocator.free(files);
        const assigned = try allocator.alloc(bool, cell_count);
        defer allocator.free(assigned);
        @memset(assigned, false);

        errdefer for (files, assigned) |file, is_assigned| {
            if (is_assigned) allocator.free(file);
        };

        var records = delimited_input.records(source);
        while (records.next()) |record| {
            if (hasEmptyExplicitField(record))
                return error.EmptyGridInputRecordValue;
            var fields = delimited_input.recordTokens(record);
            const record_name = fields.next() orelse unreachable;
            if (!std.ascii.eqlIgnoreCase(record_name, "weather_cell"))
                return error.InvalidWeatherCellInputRecord;
            const latitude = try degrees(&fields);
            const longitude = try degrees(&fields);
            const cell = try grid.cellIndexForCoordinate(latitude, longitude);
            if (assigned[cell]) return error.DuplicateWeatherCellCoordinate;
            const file = try duplicateFileName(allocator, &fields);
            errdefer allocator.free(file);
            try requireEnd(&fields);
            files[cell] = file;
            assigned[cell] = true;
        }
        for (assigned) |is_assigned| if (!is_assigned)
            return error.MissingWeatherCellInput;
        return .{
            .allocator = allocator,
            .column_count = column_count,
            .row_count = row_count,
            .file_by_cell = files,
        };
    }

    pub fn deinit(self: *WeatherFiles) void {
        for (self.file_by_cell) |file| self.allocator.free(file);
        self.allocator.free(self.file_by_cell);
        self.* = undefined;
    }
};

fn validateDimensions(column_count: usize, row_count: usize) !usize {
    if (column_count == 0 or row_count == 0) return error.InvalidGridInputDimensions;
    return std.math.mul(usize, column_count, row_count);
}

/// Reads one decimal-degree coordinate. Range checking against the declared
/// extent belongs to the grid, which owns the extent, so this only rejects
/// values that are not a finite number at all.
fn degrees(fields: *delimited_input.TokenIterator) !f64 {
    const text = fields.next() orelse return error.IncompleteGridInputRecord;
    const value = std.fmt.parseFloat(f64, text) catch
        return error.InvalidGridInputCoordinate;
    if (!std.math.isFinite(value)) return error.InvalidGridInputCoordinate;
    return value;
}

fn duplicateFileName(
    allocator: std.mem.Allocator,
    fields: *delimited_input.TokenIterator,
) ![]u8 {
    const name = fields.next() orelse return error.IncompleteGridInputRecord;
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "\r\n#") != null)
        return error.InvalidGridInputFileName;
    return allocator.dupe(u8, name);
}

fn requireEnd(fields: *delimited_input.TokenIterator) !void {
    if (fields.next() != null) return error.TrailingGridInputRecordData;
}

fn hasEmptyExplicitField(record: []const u8) bool {
    const content = if (std.mem.indexOfScalar(u8, record, '#')) |comment|
        record[0..comment]
    else
        record;
    const trimmed = std.mem.trim(u8, content, " \r");
    if (trimmed.len == 0) return false;

    var field_start: usize = 0;
    var saw_explicit_delimiter = false;
    for (trimmed, 0..) |byte, index| {
        if (byte != ',' and byte != '|' and byte != '\t') continue;
        if (std.mem.trim(u8, trimmed[field_start..index], " \r").len == 0)
            return true;
        field_start = index + 1;
        saw_explicit_delimiter = true;
    }
    return saw_explicit_delimiter and
        std.mem.trim(u8, trimmed[field_start..], " \r").len == 0;
}

/// Two cells wide, one tall: cell 0 centred at (45.5, -80.5) and cell 1 at
/// (45.5, -79.5). Coordinates in the tests below are interior points, not
/// centres, which is what a real site coordinate looks like.
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

test "runtime grid cells select inputs by coordinate not by row and column" {
    var grid = try testGrid(std.testing.allocator);
    defer grid.deinit();
    var cell_files = try CellFiles.parse(
        std.testing.allocator,
        \\# Records may repeat filenames or select distinct inputs.
        \\grid_cell,45.30,-80.70,site_a,soil_a
        \\GrId_CeLl|45.30|-79.20|site_b|soil_b # eastern cell
    ,
        grid,
    );
    defer cell_files.deinit();
    try std.testing.expectEqualStrings("site_a", cell_files.site_file_by_cell[0]);
    try std.testing.expectEqualStrings("site_b", cell_files.site_file_by_cell[1]);
    try std.testing.expectEqualStrings("soil_a", cell_files.soil_file_by_cell[0]);
    try std.testing.expectEqualStrings("soil_b", cell_files.soil_file_by_cell[1]);
    // The coordinate the user wrote is retained, not snapped to the centre.
    try std.testing.expectApproxEqAbs(
        @as(f64, -80.70),
        cell_files.longitude_degrees_east_by_cell[0],
        1.0e-12,
    );

    var weather = try WeatherFiles.parse(
        std.testing.allocator,
        \\weather_cell 45.30 -80.70 weather_shared.csv
        \\WEATHER_CELL 45.30 -79.20 weather_east
    ,
        grid,
    );
    defer weather.deinit();
    try std.testing.expectEqualStrings("weather_shared.csv", weather.file_by_cell[0]);
    try std.testing.expectEqualStrings("weather_east", weather.file_by_cell[1]);
}

test "adjacent cells may intentionally reuse every input filename" {
    var grid = try testGrid(std.testing.allocator);
    defer grid.deinit();
    var cell_files = try CellFiles.parse(
        std.testing.allocator,
        \\grid_cell 45.30 -80.70 shared_site shared_soil
        \\grid_cell 45.30 -79.20 shared_site shared_soil
    ,
        grid,
    );
    defer cell_files.deinit();
    try std.testing.expectEqualStrings(cell_files.site_file_by_cell[0], cell_files.site_file_by_cell[1]);
    try std.testing.expectEqualStrings(cell_files.soil_file_by_cell[0], cell_files.soil_file_by_cell[1]);

    var weather = try WeatherFiles.parse(
        std.testing.allocator,
        \\weather_cell 45.30 -80.70 shared_weather
        \\weather_cell 45.30 -79.20 shared_weather
    ,
        grid,
    );
    defer weather.deinit();
    try std.testing.expectEqualStrings(weather.file_by_cell[0], weather.file_by_cell[1]);
}

test "per-cell input mappings reject missing repeated coordinates and trailing values" {
    var grid = try testGrid(std.testing.allocator);
    defer grid.deinit();
    try std.testing.expectError(
        error.MissingGridCellInput,
        CellFiles.parse(
            std.testing.allocator,
            "grid_cell 45.30 -80.70 site soil\n",
            grid,
        ),
    );
    // Two coordinates inside the same cell name the same cell, which is a
    // duplicate even though the numbers differ.
    try std.testing.expectError(
        error.DuplicateWeatherCellCoordinate,
        WeatherFiles.parse(
            std.testing.allocator,
            "weather_cell 45.30 -80.70 a\nweather_cell 45.40 -80.60 b\n",
            grid,
        ),
    );
    try std.testing.expectError(
        error.TrailingGridInputRecordData,
        CellFiles.parse(
            std.testing.allocator,
            "grid_cell 45.30 -80.70 site soil extra\n",
            grid,
        ),
    );
}

test "a coordinate outside the declared extent is rejected, never clamped" {
    var grid = try testGrid(std.testing.allocator);
    defer grid.deinit();
    try std.testing.expectError(
        error.SiteCoordinateOutsideGeospatialGrid,
        CellFiles.parse(
            std.testing.allocator,
            "grid_cell 44.00 -80.70 site soil\n",
            grid,
        ),
    );
    try std.testing.expectError(
        error.InvalidGridInputCoordinate,
        CellFiles.parse(
            std.testing.allocator,
            "grid_cell north -80.70 site soil\n",
            grid,
        ),
    );
}

test "per-cell input mappings reject empty explicit delimiter fields" {
    var grid = try testGrid(std.testing.allocator);
    defer grid.deinit();
    inline for (.{
        "grid_cell,45.30,-80.70,,soil\n",
        "grid_cell|45.30|-80.70|site| \n",
        "grid_cell\t45.30\t-80.70\t\tsoil\n",
    }) |source| try std.testing.expectError(
        error.EmptyGridInputRecordValue,
        CellFiles.parse(std.testing.allocator, source, grid),
    );

    try std.testing.expectError(
        error.EmptyGridInputRecordValue,
        WeatherFiles.parse(
            std.testing.allocator,
            "weather_cell,45.30,-80.70, # missing compulsory filename\n",
            grid,
        ),
    );
}

test "grid input empty-field check preserves spacing and comments" {
    try std.testing.expect(!hasEmptyExplicitField(
        "grid_cell  45.30  -80.70  site  soil # valid spaces",
    ));
    try std.testing.expect(!hasEmptyExplicitField(
        "grid_cell, 45.30 | -80.70\tsite, soil # mixed delimiters",
    ));
    try std.testing.expect(!hasEmptyExplicitField("# comment only"));
}
