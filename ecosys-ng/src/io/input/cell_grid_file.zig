//! Reading of the per-cell grid files that select a cell's inputs.
//!
//! Every one of these files has the same shape: one record per grid cell,
//! tagged with a record name, then the cell's latitude and longitude, then the
//! filenames that apply there. The coordinate is what identifies the cell: a
//! row and column index is an artifact of the declared geospatial extent and
//! interval, so it changes when the extent changes even though the site has
//! not moved.
//!
//! This module owns the shared record shape so the climate, management, plant,
//! and landscape grid readers cannot drift apart in how they interpret a
//! coordinate or report a malformed record.

const std = @import("std");
const delimited_input = @import("delimited_input.zig");
const spatial_grid = @import("../../state/spatial_grid.zig");

/// One record's cell and the filenames it selected, borrowed from the source.
pub const Record = struct {
    cell: usize,
    latitude_degrees_north: f64,
    longitude_degrees_east: f64,
    names: [][]const u8,
};

/// Iterates the records of a coordinate-keyed grid file.
///
/// `name_count` names are required after the coordinate. A record naming a
/// cell outside the grid, or a second record naming a cell already seen, is an
/// error rather than a last-one-wins overwrite, because either means the user
/// believes they configured a cell that they did not.
///
/// Some files legitimately repeat a coordinate: a cell growing several plants
/// gets one record per plant. Those readers set `repeats_allowed`, which turns
/// a repeat from a defect into an additional entry for that cell.
pub const Reader = struct {
    records: delimited_input.RecordIterator,
    grid: spatial_grid.RegularGrid,
    record_name: []const u8,
    name_count: usize,
    repeats_allowed: bool,
    name_storage: [8][]const u8 = undefined,
    seen: []bool,

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        grid: spatial_grid.RegularGrid,
        record_name: []const u8,
        name_count: usize,
    ) !Reader {
        return initWithRepeats(allocator, source, grid, record_name, name_count, false);
    }

    /// As `init`, but a coordinate may appear on more than one record.
    pub fn initWithRepeats(
        allocator: std.mem.Allocator,
        source: []const u8,
        grid: spatial_grid.RegularGrid,
        record_name: []const u8,
        name_count: usize,
        repeats_allowed: bool,
    ) !Reader {
        if (name_count == 0 or name_count > 8) return error.UnsupportedGridRecordArity;
        const seen = try allocator.alloc(bool, try grid.cellCount());
        @memset(seen, false);
        return .{
            .records = delimited_input.records(source),
            .grid = grid,
            .record_name = record_name,
            .name_count = name_count,
            .repeats_allowed = repeats_allowed,
            .seen = seen,
        };
    }

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        allocator.free(self.seen);
        self.* = undefined;
    }

    pub fn next(self: *Reader) !?Record {
        const record = self.records.next() orelse return null;
        if (hasEmptyExplicitField(record)) return error.EmptyGridRecordValue;
        var fields = delimited_input.recordTokens(record);
        const tag = fields.next() orelse unreachable;
        if (!std.ascii.eqlIgnoreCase(tag, self.record_name)) return error.InvalidGridRecordName;
        const latitude = try degrees(&fields);
        const longitude = try degrees(&fields);
        const cell = try self.grid.cellIndexForCoordinate(latitude, longitude);
        if (self.seen[cell] and !self.repeats_allowed)
            return error.DuplicateGridRecordCoordinate;
        self.seen[cell] = true;
        for (0..self.name_count) |index| {
            const name = fields.next() orelse return error.IncompleteGridRecord;
            if (name.len == 0 or std.mem.indexOfAny(u8, name, "\r\n#") != null)
                return error.InvalidGridRecordFileName;
            self.name_storage[index] = name;
        }
        if (fields.next() != null) return error.TrailingGridRecordData;
        return .{
            .cell = cell,
            .latitude_degrees_north = latitude,
            .longitude_degrees_east = longitude,
            .names = self.name_storage[0..self.name_count],
        };
    }

    /// Every cell must be configured. A cell the file never mentions would
    /// otherwise run with whatever the zero value happens to mean.
    pub fn requireCompleteCoverage(self: Reader) !void {
        for (self.seen) |is_seen| if (!is_seen) return error.MissingGridRecord;
    }
};

/// Reads one decimal-degree coordinate. Range checking belongs to the grid,
/// which owns the extent, so this only rejects values that are not numbers.
pub fn degrees(fields: *delimited_input.TokenIterator) !f64 {
    const text = fields.next() orelse return error.IncompleteGridRecord;
    const value = std.fmt.parseFloat(f64, text) catch return error.InvalidGridCoordinate;
    if (!std.math.isFinite(value)) return error.InvalidGridCoordinate;
    return value;
}

/// Reads a grid file whose records each name one file, and returns that name
/// when every cell named the same one.
///
/// Some inputs are consumed once per scene rather than once per cell, so the
/// model holds a single value for the whole grid. Cells disagreeing about such
/// a file is reported as `GridRecordsDisagree` rather than resolved by taking
/// the first record, because silently ignoring a cell's stated input would
/// produce a run that does not match what the user configured.
///
/// The returned slice is owned by the caller.
pub fn readSharedName(
    allocator: std.mem.Allocator,
    source: []const u8,
    grid: spatial_grid.RegularGrid,
    record_name: []const u8,
) ![]u8 {
    var reader = try Reader.init(allocator, source, grid, record_name, 1);
    defer reader.deinit(allocator);
    var shared: ?[]u8 = null;
    errdefer if (shared) |name| allocator.free(name);
    while (try reader.next()) |record| {
        if (shared) |name| {
            if (!std.mem.eql(u8, name, record.names[0])) return error.GridRecordsDisagree;
        } else {
            shared = try allocator.dupe(u8, record.names[0]);
        }
    }
    try reader.requireCompleteCoverage();
    return shared orelse error.MissingGridRecord;
}
/// True when an explicit delimiter surrounds a field with no content, which
/// means the user left a compulsory value blank rather than omitting it.
pub fn hasEmptyExplicitField(record: []const u8) bool {
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

test {
    _ = @import("cell_grid_file_test.zig");
}
