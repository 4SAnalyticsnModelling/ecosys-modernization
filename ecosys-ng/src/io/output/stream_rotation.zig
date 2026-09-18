const std = @import("std");
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");
const output_record = @import("record.zig");
const output_selection = @import("selection.zig");
const output_stream = @import("stream.zig");
const output_hour_transaction = @import("hour_transaction.zig");

/// Owns one bounded output stream and rotates it when the simulation year or
/// generated filename changes. Simulation duration never increases memory.
pub const RotatingStream = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    buffer_bytes: usize,
    delimiter: output_record.Delimiter,
    stream: ?output_stream.Stream = null,
    active_year: ?i32 = null,
    active_file_name: ?[]u8 = null,
    coordinator: ?*output_hour_transaction.Coordinator = null,
    category: ?output_hour_transaction.Category = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, buffer_bytes: usize, delimiter: output_record.Delimiter) !RotatingStream {
        return initInternal(allocator, io, directory, buffer_bytes, delimiter, null, null);
    }

    pub fn initTransactional(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: std.Io.Dir,
        buffer_bytes: usize,
        delimiter: output_record.Delimiter,
        coordinator: *output_hour_transaction.Coordinator,
        category: output_hour_transaction.Category,
    ) !RotatingStream {
        return initInternal(allocator, io, directory, buffer_bytes, delimiter, coordinator, category);
    }

    fn initInternal(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: std.Io.Dir,
        buffer_bytes: usize,
        delimiter: output_record.Delimiter,
        coordinator: ?*output_hour_transaction.Coordinator,
        category: ?output_hour_transaction.Category,
    ) !RotatingStream {
        if (buffer_bytes == 0) return error.InvalidOutputBufferSize;
        return .{ .allocator = allocator, .io = io, .directory = directory, .buffer_bytes = buffer_bytes, .delimiter = delimiter, .coordinator = coordinator, .category = category };
    }

    pub fn deinit(self: *RotatingStream) void {
        self.close();
        self.* = undefined;
    }

    pub fn write(
        self: *RotatingStream,
        file_name: []const u8,
        variables: []const output_record.Variable,
        selection: output_selection.Selection,
        enabled_variables: []const bool,
        record: output_record.Record,
    ) !bool {
        if (!safeFileName(file_name)) return error.InvalidOutputFileName;
        if (variables.len != enabled_variables.len or record.values.len != variables.len) return error.OutputSelectionDimensionMismatch;
        try validateTimestamp(record.timestamp);
        if (self.coordinator) |coordinator| {
            if (!try selection.includesDate(record.timestamp.day, record.timestamp.month, record.timestamp.year)) return false;
            var header: std.Io.Writer.Allocating = .init(self.allocator);
            defer header.deinit();
            try output_record.writeHeader(&header.writer, variables, enabled_variables, self.delimiter);
            var row: std.Io.Writer.Allocating = .init(self.allocator);
            defer row.deinit();
            try output_record.writeRecord(&row.writer, record, enabled_variables, self.delimiter);
            try coordinator.record(self.category orelse return error.MissingOutputTransactionCategory, file_name, header.written(), row.written());
            try self.rememberActive(file_name, record.timestamp.year);
            return true;
        }
        if (self.stream == null or self.active_year == null or self.active_year.? != record.timestamp.year or !std.mem.eql(u8, self.active_file_name.?, file_name)) {
            self.close();
            const owned_name = try self.allocator.dupe(u8, file_name);
            errdefer self.allocator.free(owned_name);
            self.stream = try output_stream.Stream.create(self.allocator, self.io, self.directory, file_name, self.buffer_bytes, variables, enabled_variables, self.delimiter);
            self.active_year = record.timestamp.year;
            self.active_file_name = owned_name;
        }
        const resolved_selection: output_selection.Selection = .{
            .allocator = selection.allocator,
            .first_date = selection.first_date,
            .last_date = selection.last_date,
            .enabled_variables = @constCast(enabled_variables),
        };
        return self.stream.?.writeIfScheduled(resolved_selection, record);
    }

    fn rememberActive(self: *RotatingStream, file_name: []const u8, year: i32) !void {
        if (self.active_year != null and self.active_year.? == year and
            self.active_file_name != null and std.mem.eql(u8, self.active_file_name.?, file_name)) return;
        const owned_name = try self.allocator.dupe(u8, file_name);
        if (self.active_file_name) |name| self.allocator.free(name);
        self.active_file_name = owned_name;
        self.active_year = year;
    }

    pub fn finish(self: *RotatingStream) !void {
        if (self.stream) |*stream| {
            try stream.finish();
            stream.deinit();
        }
        if (self.active_file_name) |name| self.allocator.free(name);
        self.stream = null;
        self.active_file_name = null;
        self.active_year = null;
    }

    fn close(self: *RotatingStream) void {
        if (self.stream) |*stream| stream.deinit();
        if (self.active_file_name) |name| self.allocator.free(name);
        self.stream = null;
        self.active_file_name = null;
        self.active_year = null;
    }
};

fn validateTimestamp(timestamp: output_record.Timestamp) !void {
    if (timestamp.year <= 0 or timestamp.year > 9999 or timestamp.hour > 23)
        return error.InvalidOutputTimestamp;
    const date = execution_calendar_date.fromDayOfYear(
        timestamp.day_of_year,
        @intCast(timestamp.year),
    ) catch return error.InvalidOutputTimestamp;
    if (date.month != timestamp.month or date.day != timestamp.day)
        return error.InvalidOutputTimestamp;
}

fn safeFileName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
        return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (name[0] == ' ' or name[name.len - 1] == ' ' or name[name.len - 1] == '.')
        return false;
    for (name) |byte| {
        if (byte == 0 or byte < 0x20 or
            std.mem.indexOfScalar(u8, "/\\<>:\"|?*", byte) != null)
            return false;
    }
    return true;
}

test "rotating stream closes yearly files with bounded memory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var selection = try output_selection.parse(
        std.testing.allocator,
        "0101\n3112\nyes\n",
    );
    defer selection.deinit();
    var rotation = try RotatingStream.init(std.testing.allocator, std.testing.io, temporary.dir, 48, .comma);
    defer rotation.deinit();
    const variables = [_]output_record.Variable{.{ .name = "runoff", .unit = "mm" }};
    try std.testing.expect(try rotation.write("2001.csv", &variables, selection, &.{true}, .{ .timestamp = .{ .year = 2001, .day_of_year = 1, .month = 1, .day = 1, .hour = 1 }, .longitude_degrees_east = -75.7, .latitude_degrees_north = 45.3, .values = &.{2} }));
    try std.testing.expect(try rotation.write("2002.csv", &variables, selection, &.{true}, .{ .timestamp = .{ .year = 2002, .day_of_year = 1, .month = 1, .day = 1, .hour = 1 }, .longitude_degrees_east = -75.7, .latitude_degrees_north = 45.3, .values = &.{3} }));
    try rotation.finish();
    const first = try temporary.dir.readFileAlloc(std.testing.io, "2001.csv", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(first);
    const second = try temporary.dir.readFileAlloc(std.testing.io, "2002.csv", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, first, "2e0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "3e0") != null);
}

test "invalid rotation name fails before closing active output" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var selection = try output_selection.parse(
        std.testing.allocator,
        "0101\n3112\nyes\n",
    );
    defer selection.deinit();
    var rotation = try RotatingStream.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        48,
        .tab,
    );
    defer rotation.deinit();
    const variables = [_]output_record.Variable{
        .{ .name = "runoff", .unit = "mm" },
    };
    const first_record: output_record.Record = .{
        .timestamp = .{
            .year = 2001,
            .day_of_year = 1,
            .month = 1,
            .day = 1,
            .hour = 1,
        },
        .longitude_degrees_east = -75.7,
        .latitude_degrees_north = 45.3,
        .values = &.{2},
    };
    try std.testing.expect(try rotation.write(
        "2001.txt",
        &variables,
        selection,
        &.{true},
        first_record,
    ));
    inline for (.{
        "../2002.txt",
        "subdir/2002.txt",
        "2002|hourly.txt",
        "2002.txt ",
    }) |name| {
        try std.testing.expectError(
            error.InvalidOutputFileName,
            rotation.write(name, &variables, selection, &.{true}, first_record),
        );
        try std.testing.expectEqualStrings(
            "2001.txt",
            rotation.active_file_name.?,
        );
        try std.testing.expect(rotation.stream != null);
    }

    const invalid_date_record: output_record.Record = .{
        .timestamp = .{
            .year = 1901,
            .day_of_year = 366,
            .month = 12,
            .day = 31,
            .hour = 1,
        },
        .longitude_degrees_east = -75.7,
        .latitude_degrees_north = 45.3,
        .values = &.{2},
    };
    try std.testing.expectError(
        error.InvalidOutputTimestamp,
        rotation.write(
            "1901.txt",
            &variables,
            selection,
            &.{true},
            invalid_date_record,
        ),
    );
    try std.testing.expectEqualStrings("2001.txt", rotation.active_file_name.?);
    try std.testing.expect(rotation.stream != null);
}

test "rotating output accepts portable text file names" {
    try std.testing.expect(safeFileName("2001"));
    try std.testing.expect(safeFileName("hourly-2001.txt"));
    try std.testing.expect(safeFileName("hourly.2001.txt"));
}

test "rotation timestamp preflight preserves DAY modulo-four chronology" {
    try validateTimestamp(.{
        .year = 1900,
        .day_of_year = 366,
        .month = 12,
        .day = 31,
        .hour = 23,
    });
    try std.testing.expectError(
        error.InvalidOutputTimestamp,
        validateTimestamp(.{
            .year = 1901,
            .day_of_year = 366,
            .month = 12,
            .day = 31,
            .hour = 23,
        }),
    );
}
