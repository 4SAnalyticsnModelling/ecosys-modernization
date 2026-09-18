const std = @import("std");
const output_record = @import("record.zig");
const output_selection = @import("selection.zig");
const output_stream_rotation = @import("stream_rotation.zig");
const output_hour_transaction = @import("hour_transaction.zig");

/// Runtime-sized, fixed-memory storage for one output editor family.
/// Disabled families allocate nothing. Enabled families own one reusable
/// scientific row and one bounded rotating stream per grid cell.
pub const Bank = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    variable_count: usize,
    values: []f64,
    streams: []output_stream_rotation.RotatingStream,
    enabled: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: std.Io.Dir,
        enabled: bool,
        cell_count: usize,
        variable_count: usize,
        stream_buffer_bytes: usize,
        delimiter: output_record.Delimiter,
    ) !Bank {
        return initInternal(allocator, io, directory, enabled, cell_count, variable_count, stream_buffer_bytes, delimiter, null, null);
    }

    pub fn initTransactional(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: std.Io.Dir,
        enabled: bool,
        cell_count: usize,
        variable_count: usize,
        stream_buffer_bytes: usize,
        delimiter: output_record.Delimiter,
        coordinator: *output_hour_transaction.Coordinator,
        category: output_hour_transaction.Category,
    ) !Bank {
        return initInternal(allocator, io, directory, enabled, cell_count, variable_count, stream_buffer_bytes, delimiter, coordinator, category);
    }

    fn initInternal(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: std.Io.Dir,
        enabled: bool,
        cell_count: usize,
        variable_count: usize,
        stream_buffer_bytes: usize,
        delimiter: output_record.Delimiter,
        coordinator: ?*output_hour_transaction.Coordinator,
        category: ?output_hour_transaction.Category,
    ) !Bank {
        if (cell_count == 0 or variable_count == 0) return error.InvalidOutputStreamBankDimensions;
        if (enabled and stream_buffer_bytes == 0)
            return error.InvalidOutputBufferSize;
        if (!enabled) return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .variable_count = variable_count,
            .values = @constCast(&.{}),
            .streams = @constCast(&.{}),
            .enabled = false,
        };
        const value_count = std.math.mul(
            usize,
            cell_count,
            variable_count,
        ) catch return error.OutputStreamBankSizeOverflow;
        const values = try allocator.alloc(f64, value_count);
        errdefer allocator.free(values);
        @memset(values, 0);
        const streams = try allocator.alloc(output_stream_rotation.RotatingStream, cell_count);
        var initialized: usize = 0;
        errdefer {
            for (streams[0..initialized]) |*stream| stream.deinit();
            allocator.free(streams);
        }
        for (streams) |*stream| {
            stream.* = if (coordinator) |resolved_coordinator|
                try output_stream_rotation.RotatingStream.initTransactional(allocator, io, directory, stream_buffer_bytes, delimiter, resolved_coordinator, category orelse return error.MissingOutputTransactionCategory)
            else
                try output_stream_rotation.RotatingStream.init(allocator, io, directory, stream_buffer_bytes, delimiter);
            initialized += 1;
        }
        return .{ .allocator = allocator, .cell_count = cell_count, .variable_count = variable_count, .values = values, .streams = streams, .enabled = true };
    }

    pub fn deinit(self: *Bank) void {
        if (self.enabled) {
            for (self.streams) |*stream| stream.deinit();
            self.allocator.free(self.streams);
            self.allocator.free(self.values);
        }
        self.* = undefined;
    }

    pub fn row(self: *Bank, cell: usize) ![]f64 {
        if (!self.enabled) return error.OutputStreamBankDisabled;
        if (cell >= self.cell_count) return error.OutputStreamBankCellOutOfBounds;
        return self.values[cell * self.variable_count ..][0..self.variable_count];
    }

    pub fn finish(self: *Bank) !void {
        if (!self.enabled) return;
        for (self.streams) |*stream| try stream.finish();
    }
};

test "disabled output bank owns no per-cell storage" {
    var bank = try Bank.init(std.testing.allocator, std.testing.io, undefined, false, 1_000_000, 500, 64, .comma);
    defer bank.deinit();
    try std.testing.expect(!bank.enabled);
    try std.testing.expectEqual(@as(usize, 0), bank.values.len);
    try std.testing.expectEqual(@as(usize, 0), bank.streams.len);
    try std.testing.expectError(error.OutputStreamBankDisabled, bank.row(0));
    try bank.finish();
}

test "enabled output bank exposes stable runtime rows" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var bank = try Bank.init(std.testing.allocator, std.testing.io, temporary.dir, true, 3, 4, 32, .pipe);
    defer bank.deinit();
    const second = try bank.row(1);
    second[2] = 7;
    try std.testing.expectEqual(@as(f64, 7), bank.values[6]);
    try std.testing.expectError(error.OutputStreamBankCellOutOfBounds, bank.row(3));
    try bank.finish();
}

test "enabled output bank rejects invalid runtime size before allocation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try std.testing.expectError(
        error.InvalidOutputBufferSize,
        Bank.init(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            true,
            1,
            1,
            0,
            .tab,
        ),
    );
    try std.testing.expectError(
        error.OutputStreamBankSizeOverflow,
        Bank.init(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            true,
            std.math.maxInt(usize),
            2,
            64,
            .tab,
        ),
    );
}

test "disabled output bank permits zero buffer without allocating" {
    var bank = try Bank.init(
        std.testing.allocator,
        std.testing.io,
        undefined,
        false,
        2,
        3,
        0,
        .tab,
    );
    defer bank.deinit();
    try std.testing.expectEqual(@as(usize, 0), bank.values.len);
    try std.testing.expectEqual(@as(usize, 0), bank.streams.len);
}

test "transactional bank stages rotating rows until the hour cursor commits" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var coordinator = try output_hour_transaction.Coordinator.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        .{
            .carbon = temporary.dir,
            .water = temporary.dir,
            .nitrogen = temporary.dir,
            .heat_energy = temporary.dir,
            .phosphorus = temporary.dir,
        },
        0x1122_3344,
        128,
        .{},
    );
    defer coordinator.deinit();
    try coordinator.reconcile(.fresh);
    var bank = try Bank.initTransactional(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        true,
        1,
        1,
        64,
        .comma,
        &coordinator,
        .carbon,
    );
    defer bank.deinit();
    var selection = try output_selection.parse(std.testing.allocator, "0101\n3112\nyes\n");
    defer selection.deinit();
    try coordinator.beginHour(1, .{
        .year = 2001,
        .day_of_year = 1,
        .hour = 0,
        .completed_scene_hours = 1,
    });
    try std.testing.expect(try bank.streams[0].write(
        "transactional.csv",
        &.{.{ .name = "runoff", .unit = "mm" }},
        selection,
        &.{true},
        .{
            .timestamp = .{ .year = 2001, .day_of_year = 1, .month = 1, .day = 1, .hour = 0 },
            .longitude_degrees_east = -75.7,
            .latitude_degrees_north = 45.3,
            .values = &.{2},
        },
    ));
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(std.testing.io, "transactional.csv", .{}),
    );
    try coordinator.commitHour();
    const bytes = try temporary.dir.readFileAlloc(std.testing.io, "transactional.csv", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "year,day_of_year,month,day,hour,longitude,latitude,runoff[mm]\n2001,1,1,1,0,-75.7,45.3,2e0\n",
        bytes,
    );
}

test "transactional output identity separates close cells same species and repeated calendar scenes" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var coordinator = try output_hour_transaction.Coordinator.init(allocator, std.testing.io, temporary.dir, .{ .carbon = temporary.dir, .water = temporary.dir, .nitrogen = temporary.dir, .heat_energy = temporary.dir, .phosphorus = temporary.dir }, 0x1122_3344, 128, .{});
    defer coordinator.deinit();
    try coordinator.reconcile(.fresh);
    var bank = try Bank.initTransactional(allocator, std.testing.io, temporary.dir, true, 4, 1, 64, .comma, &coordinator, .carbon);
    defer bank.deinit();
    var selection = try output_selection.parse(allocator, "0101\n3112\nyes\n");
    defer selection.deinit();
    const passes = [_]output_record.PassOrdinals{
        .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 },
        .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 2 },
        .{ .execution_number = 1, .scenario_number = 2, .repeat_number = 1, .scene_number = 2 },
    };
    for (passes, 0..) |pass, pass_index| {
        try coordinator.beginHour(pass_index + 1, .{
            .year = 2001,
            .day_of_year = 1,
            .hour = 0,
            .scenario_index = pass.scenario_number - 1,
            .scene_index = pass.scene_number - 1,
            .completed_scene_hours = 1,
        });
        for (0..4) |plant| {
            const cell = plant / 2;
            const latitude = 45.300 + @as(f64, @floatFromInt(cell)) * 0.001;
            const name = try output_record.buildOutputFileName(allocator, latitude, -75.7, .{ .species = .{ .name = "maize", .population_number = plant % 2 + 1 } }, 2001, pass, cell + 1, "hourly");
            defer allocator.free(name);
            try std.testing.expect(try bank.streams[plant].write(name, &.{.{ .name = "runoff", .unit = "mm" }}, selection, &.{true}, .{
                .timestamp = .{ .year = 2001, .day_of_year = 1, .month = 1, .day = 1, .hour = 0 },
                .longitude_degrees_east = -75.7,
                .latitude_degrees_north = latitude,
                .values = &.{@floatFromInt(pass_index * 10 + plant + 1)},
            }));
        }
        try coordinator.commitHour();
    }
    try bank.finish();
    for (passes, 0..) |pass, pass_index| for (0..4) |plant| {
        const cell = plant / 2;
        const latitude = 45.300 + @as(f64, @floatFromInt(cell)) * 0.001;
        const name = try output_record.buildOutputFileName(allocator, latitude, -75.7, .{ .species = .{ .name = "maize", .population_number = plant % 2 + 1 } }, 2001, pass, cell + 1, "hourly");
        defer allocator.free(name);
        const bytes = try temporary.dir.readFileAlloc(std.testing.io, name, allocator, .limited(1024));
        defer allocator.free(bytes);
        const expected = try std.fmt.allocPrint(allocator, "year,day_of_year,month,day,hour,longitude,latitude,runoff[mm]\n2001,1,1,1,0,-75.7,{d},{e}\n", .{ latitude, @as(f64, @floatFromInt(pass_index * 10 + plant + 1)) });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, bytes);
    };
}
