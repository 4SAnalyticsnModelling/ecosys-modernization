const std = @import("std");
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");

const magic = "ECONGPLT";
const format_version: u32 = 1;

pub const CellView = struct {
    species_names: []const []const u8,
    species_alive: []const bool,
};

pub const Limits = struct {
    maximum_cells: usize,
    maximum_species_per_cell: usize,
    maximum_species_name_bytes: usize,
};

pub const OwnedCell = struct {
    species_names: [][]u8,
    species_alive: []bool,
};

pub const Metadata = struct {
    allocator: std.mem.Allocator,
    day_of_year: u16,
    year: i32,
    cells: []OwnedCell,

    pub fn deinit(self: *Metadata) void {
        for (self.cells) |cell| {
            for (cell.species_names) |name| self.allocator.free(name);
            self.allocator.free(cell.species_names);
            self.allocator.free(cell.species_alive);
        }
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

/// Versioned WOUTQ-equivalent metadata with no historical five-species cap.
pub fn write(writer: anytype, day_of_year: u16, year: i32, cells: []const CellView) !void {
    try validateDate(day_of_year, year);
    for (cells) |cell| {
        if (cell.species_names.len != cell.species_alive.len)
            return error.PlantCheckpointSpeciesDimensionMismatch;
        for (cell.species_names) |name|
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null)
                return error.InvalidPlantCheckpointSpeciesName;
    }
    try writer.writeAll(magic);
    try writer.writeInt(u32, format_version, .little);
    try writer.writeInt(u16, day_of_year, .little);
    try writer.writeInt(i32, year, .little);
    try writer.writeInt(u64, @intCast(cells.len), .little);
    for (cells) |cell| {
        try writer.writeInt(u64, @intCast(cell.species_names.len), .little);
        for (cell.species_names, cell.species_alive) |name, alive| {
            try writer.writeInt(u64, @intCast(name.len), .little);
            try writer.writeAll(name);
            try writer.writeByte(@intFromBool(alive));
        }
    }
}

pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) !Metadata {
    if (limits.maximum_cells == 0 or limits.maximum_species_per_cell == 0 or limits.maximum_species_name_bytes == 0) return error.InvalidPlantCheckpointLimits;
    const file_magic = try reader.takeArray(magic.len);
    if (!std.mem.eql(u8, file_magic, magic)) return error.InvalidPlantCheckpointMagic;
    if (try reader.takeInt(u32, .little) != format_version) return error.UnsupportedPlantCheckpointVersion;
    const day_of_year = try reader.takeInt(u16, .little);
    const year = try reader.takeInt(i32, .little);
    try validateDate(day_of_year, year);
    const cell_count_u64 = try reader.takeInt(u64, .little);
    if (cell_count_u64 > limits.maximum_cells or cell_count_u64 > std.math.maxInt(usize)) return error.PlantCheckpointCellLimitExceeded;
    const cells = try allocator.alloc(OwnedCell, @intCast(cell_count_u64));
    var initialized_cells: usize = 0;
    errdefer {
        for (cells[0..initialized_cells]) |cell| {
            for (cell.species_names) |name| allocator.free(name);
            allocator.free(cell.species_names);
            allocator.free(cell.species_alive);
        }
        allocator.free(cells);
    }
    for (cells) |*cell| {
        const species_count_u64 = try reader.takeInt(u64, .little);
        if (species_count_u64 > limits.maximum_species_per_cell or species_count_u64 > std.math.maxInt(usize)) return error.PlantCheckpointSpeciesLimitExceeded;
        const species_count: usize = @intCast(species_count_u64);
        const names = try allocator.alloc([]u8, species_count);
        var initialized_names: usize = 0;
        errdefer {
            for (names[0..initialized_names]) |name| allocator.free(name);
            allocator.free(names);
        }
        const alive = try allocator.alloc(bool, species_count);
        errdefer allocator.free(alive);
        for (names, alive) |*name, *is_alive| {
            const name_length_u64 = try reader.takeInt(u64, .little);
            if (name_length_u64 == 0 or name_length_u64 > limits.maximum_species_name_bytes or name_length_u64 > std.math.maxInt(usize)) return error.PlantCheckpointSpeciesNameLimitExceeded;
            name.* = try allocator.alloc(u8, @intCast(name_length_u64));
            initialized_names += 1;
            try reader.readSliceAll(name.*);
            if (std.mem.indexOfScalar(u8, name.*, 0) != null) return error.InvalidPlantCheckpointSpeciesName;
            is_alive.* = switch (try reader.takeByte()) {
                0 => false,
                1 => true,
                else => return error.InvalidPlantCheckpointAliveFlag,
            };
        }
        cell.* = .{ .species_names = names, .species_alive = alive };
        initialized_cells += 1;
    }
    if (reader.peekByte()) |_| return error.TrailingPlantCheckpointData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    return .{ .allocator = allocator, .day_of_year = day_of_year, .year = year, .cells = cells };
}

fn validateDate(day_of_year: u16, year: i32) !void {
    const calendar_year = std.math.cast(u16, year) orelse
        return error.InvalidPlantCheckpointDate;
    const maximum_day: u16 =
        if (execution_calendar_date.isLeapYear(calendar_year)) 366 else 365;
    if (calendar_year == 0 or day_of_year == 0 or day_of_year > maximum_day)
        return error.InvalidPlantCheckpointDate;
}

test "plant checkpoint metadata round trip supports more than five species" {
    const names = [_][]const u8{ "species_1", "species_2", "species_3", "species_4", "species_5", "species_6", "species_7" };
    const alive = [_]bool{ true, false, true, true, false, true, true };
    const cells = [_]CellView{.{ .species_names = &names, .species_alive = &alive }};
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, 123, 2004, &cells);
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{ .maximum_cells = 10, .maximum_species_per_cell = 20, .maximum_species_name_bytes = 100 });
    defer restored.deinit();
    try std.testing.expectEqual(@as(u16, 123), restored.day_of_year);
    try std.testing.expectEqual(@as(usize, 7), restored.cells[0].species_names.len);
    try std.testing.expectEqualStrings("species_7", restored.cells[0].species_names[6]);
    try std.testing.expect(restored.cells[0].species_alive[6]);
}

test "plant checkpoint metadata enforces runtime read limits" {
    const names = [_][]const u8{ "one", "two" };
    const alive = [_]bool{ true, true };
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, 1, 2001, &.{.{ .species_names = &names, .species_alive = &alive }});
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.PlantCheckpointSpeciesLimitExceeded, read(std.testing.allocator, &reader, .{ .maximum_cells = 1, .maximum_species_per_cell = 1, .maximum_species_name_bytes = 16 }));
}

test "plant checkpoint dates preserve DAY modulo-four chronology" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, 366, 1900, &.{});
    try std.testing.expect(bytes.written().len > 0);

    var invalid: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid.deinit();
    try std.testing.expectError(
        error.InvalidPlantCheckpointDate,
        write(&invalid.writer, 366, 1901, &.{}),
    );
    try std.testing.expectEqual(@as(usize, 0), invalid.written().len);
}

test "plant checkpoint write preflights all metadata before bytes" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try std.testing.expectError(
        error.PlantCheckpointSpeciesDimensionMismatch,
        write(
            &bytes.writer,
            1,
            2001,
            &.{.{ .species_names = &.{"maize"}, .species_alive = &.{} }},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), bytes.written().len);
}
