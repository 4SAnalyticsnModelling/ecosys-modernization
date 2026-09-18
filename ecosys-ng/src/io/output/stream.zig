const std = @import("std");
const output_record = @import("record.zig");
const output_selection = @import("selection.zig");

/// Buffered per-cell output stream. Rows are emitted directly to the file;
/// memory use is fixed by `buffer_bytes` and independent of simulation length.
pub const Stream = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    file_writer: std.Io.File.Writer,
    buffer: []u8,
    delimiter: output_record.Delimiter,
    is_open: bool = true,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, file_name: []const u8, buffer_bytes: usize, variables: []const output_record.Variable, enabled: []const bool, delimiter: output_record.Delimiter) !Stream {
        if (buffer_bytes == 0) return error.InvalidOutputBufferSize;
        if (!safeFileName(file_name)) return error.InvalidOutputFileName;
        const buffer = try allocator.alloc(u8, buffer_bytes);
        errdefer allocator.free(buffer);
        const file = try directory.createFile(io, file_name, .{});
        errdefer file.close(io);
        var result: Stream = .{ .allocator = allocator, .io = io, .file = file, .file_writer = file.writerStreaming(io, buffer), .buffer = buffer, .delimiter = delimiter };
        try output_record.writeHeader(&result.file_writer.interface, variables, enabled, delimiter);
        return result;
    }

    /// Returns true only when a row was written inside the editor's recurring
    /// date window. The enabled slice is checked against the record at write.
    pub fn writeIfScheduled(self: *Stream, selection: output_selection.Selection, record: output_record.Record) !bool {
        if (!self.is_open) return error.OutputStreamClosed;
        if (!try selection.includesDate(record.timestamp.day, record.timestamp.month, record.timestamp.year)) return false;
        try output_record.writeRecord(&self.file_writer.interface, record, selection.enabled_variables, self.delimiter);
        return true;
    }

    pub fn flush(self: *Stream) !void {
        if (!self.is_open) return error.OutputStreamClosed;
        try self.file_writer.interface.flush();
    }

    pub fn finish(self: *Stream) !void {
        if (!self.is_open) return;
        try self.file_writer.interface.flush();
        self.file.close(self.io);
        self.is_open = false;
    }

    pub fn deinit(self: *Stream) void {
        if (self.is_open) {
            self.file_writer.interface.flush() catch |err| std.log.err("failed to flush output stream during close: {s}", .{@errorName(err)});
            self.file.close(self.io);
        }
        self.allocator.free(self.buffer);
        self.* = undefined;
    }
};

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

test "output stream writes one heading and scheduled rows to bounded file buffer" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var selection = try output_selection.parse(
        std.testing.allocator,
        "0106\n3006\nyes\nno\nyes\n",
    );
    defer selection.deinit();
    const variables = [_]output_record.Variable{
        .{ .name = "runoff", .unit = "mm" },
        .{ .name = "temperature", .unit = "degC" },
        .{ .name = "water_table", .unit = "m" },
    };
    var stream = try Stream.create(std.testing.allocator, std.testing.io, temporary.dir, "hourly.txt", 64, &variables, selection.enabled_variables, .comma);
    defer stream.deinit();
    try std.testing.expect(!try stream.writeIfScheduled(selection, .{ .timestamp = .{ .year = 2001, .day_of_year = 121, .month = 5, .day = 1, .hour = 0 }, .longitude_degrees_east = -75.7, .latitude_degrees_north = 45.3, .values = &.{ 9, 8, 7 } }));
    try std.testing.expect(try stream.writeIfScheduled(selection, .{ .timestamp = .{ .year = 2001, .day_of_year = 152, .month = 6, .day = 1, .hour = 3 }, .longitude_degrees_east = -75.7, .latitude_degrees_north = 45.3, .values = &.{ 1.5, 20, 2.5 } }));
    try stream.finish();

    const contents = try temporary.dir.readFileAlloc(std.testing.io, "hourly.txt", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("year,day_of_year,month,day,hour,longitude,latitude,runoff[mm],water_table[m]\n2001,152,6,1,3,-75.7,45.3,1.5e0,2.5e0\n", contents);
}

test "closed output stream rejects additional records" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var selection = try output_selection.parse(
        std.testing.allocator,
        "0101\n3112\nyes\n",
    );
    defer selection.deinit();
    const variables = [_]output_record.Variable{.{ .name = "runoff", .unit = "mm" }};
    var stream = try Stream.create(std.testing.allocator, std.testing.io, temporary.dir, "closed.txt", 32, &variables, selection.enabled_variables, .space);
    defer stream.deinit();
    try stream.finish();
    try std.testing.expectError(error.OutputStreamClosed, stream.writeIfScheduled(selection, .{ .timestamp = .{ .year = 2001, .day_of_year = 1, .month = 1, .day = 1, .hour = 0 }, .longitude_degrees_east = -75.7, .latitude_degrees_north = 45.3, .values = &.{1} }));
}

test "output stream rejects unsafe runtime file names before allocation or I/O" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    inline for (.{
        "",
        ".",
        "..",
        "../hourly.txt",
        "subdir/hourly.txt",
        "subdir\\hourly.txt",
        " hourly.txt",
        "hourly.txt ",
        "hourly.",
        "hourly:1.txt",
        "hourly|1.txt",
        "hourly?1.txt",
    }) |name| try std.testing.expectError(
        error.InvalidOutputFileName,
        Stream.create(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            name,
            64,
            &.{.{ .name = "runoff", .unit = "mm" }},
            &.{true},
            .tab,
        ),
    );
}

test "output stream accepts portable extensionless and text file names" {
    try std.testing.expect(safeFileName("hourly"));
    try std.testing.expect(safeFileName("hourly-1.txt"));
    try std.testing.expect(safeFileName("hourly.1.txt"));
}
