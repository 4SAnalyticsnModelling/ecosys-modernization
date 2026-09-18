const std = @import("std");
const Topology = @import("../../soil/profile/boundary_topology.zig");

const magic = "ECWTBL";
pub const schema_version: u32 = 1;
const cell_field_count: usize = 9;
const face_field_count: usize = 5;

pub const View = struct {
    topology: *const Topology.State,
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    face_count: usize,
    topology_fingerprint: u64,
    water_table_mode: []u8,
    cell_fields: [cell_field_count][]f64,
    face_fields: [face_field_count][]f64,

    pub fn deinit(self: *Snapshot) void {
        for (self.face_fields) |values| self.allocator.free(values);
        for (self.cell_fields) |values| self.allocator.free(values);
        self.allocator.free(self.water_table_mode);
        self.* = undefined;
    }

    pub fn validate(self: Snapshot) !void {
        if (self.cell_count == 0 or self.water_table_mode.len != self.cell_count)
            return error.WaterTableCheckpointDimensionMismatch;
        for (self.cell_fields) |values| {
            if (values.len != self.cell_count)
                return error.WaterTableCheckpointDimensionMismatch;
            try validateFinite(values);
        }
        for (self.face_fields) |values| {
            if (values.len != self.face_count)
                return error.WaterTableCheckpointDimensionMismatch;
            try validateFinite(values);
        }
        try validateValues(
            self.water_table_mode,
            self.cell_fields,
            self.face_fields,
        );
    }

    /// Validation, including the immutable face-layout fingerprint, completes
    /// before the first write so a corrupt or wrong-grid restart is atomic.
    pub fn restoreInto(self: Snapshot, target: *Topology.State) !void {
        try self.validate();
        try validateTarget(target);
        try self.restoreIntoLayoutValidated(target);
    }

    /// Rollback variant: the failed live values may be NaN, negative, or out
    /// of range. Only allocation layout and immutable topology are trusted;
    /// the fully validated snapshot overwrites every mutable checkpoint field.
    pub fn restoreIntoForRollback(self: Snapshot, target: *Topology.State) !void {
        try self.validate();
        try validateTargetLayout(target);
        try self.restoreIntoLayoutValidated(target);
    }

    fn restoreIntoLayoutValidated(self: Snapshot, target: *Topology.State) !void {
        if (target.water_table_mode.len != self.cell_count or
            target.faces.len != self.face_count)
            return error.WaterTableCheckpointDimensionMismatch;
        if (topologyFingerprint(target) != self.topology_fingerprint)
            return error.WaterTableCheckpointTopologyMismatch;
        @memcpy(target.water_table_mode, self.water_table_mode);
        inline for (cellFields(target), self.cell_fields) |destination, source|
            @memcpy(destination, source);
        for (target.faces, 0..) |*face, index| {
            face.natural_water_table_distance_m = self.face_fields[0][index];
            face.natural_exchange_fraction = self.face_fields[1][index];
            face.artificial_water_table_distance_m = self.face_fields[2][index];
            face.artificial_exchange_fraction = self.face_fields[3][index];
            face.surface_runoff_fraction = self.face_fields[4][index];
        }
    }
};

pub fn write(writer: anytype, view: View) !void {
    try validateView(view);
    const topology = view.topology;
    try writer.writeAll(magic);
    try writer.writeInt(u32, schema_version, .little);
    try writer.writeInt(u64, @intCast(topology.water_table_mode.len), .little);
    try writer.writeInt(u64, @intCast(topology.faces.len), .little);
    try writer.writeInt(u64, topologyFingerprint(topology), .little);
    try writer.writeAll(topology.water_table_mode);
    inline for (cellConstFields(topology)) |values|
        try writeF64Slice(writer, values);
    for (topology.faces) |face| inline for (.{
        face.natural_water_table_distance_m,
        face.natural_exchange_fraction,
        face.artificial_water_table_distance_m,
        face.artificial_exchange_fraction,
        face.surface_runoff_fraction,
    }) |value| try writeF64(writer, value);
}

pub fn read(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    expected_cell_count: usize,
) !Snapshot {
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic))
        return error.InvalidWaterTableCheckpointMagic;
    if (try reader.takeInt(u32, .little) != schema_version)
        return error.UnsupportedWaterTableCheckpointVersion;
    const cell_count_u64 = try reader.takeInt(u64, .little);
    if (cell_count_u64 != expected_cell_count)
        return error.WaterTableCheckpointDimensionMismatch;
    const face_count_u64 = try reader.takeInt(u64, .little);
    if (face_count_u64 > std.math.maxInt(usize))
        return error.WaterTableCheckpointDimensionMismatch;
    const face_count: usize = @intCast(face_count_u64);
    const fingerprint = try reader.takeInt(u64, .little);
    var result: Snapshot = .{
        .allocator = allocator,
        .cell_count = expected_cell_count,
        .face_count = face_count,
        .topology_fingerprint = fingerprint,
        .water_table_mode = undefined,
        .cell_fields = undefined,
        .face_fields = undefined,
    };
    var cell_allocated: usize = 0;
    var face_allocated: usize = 0;
    var modes_allocated = false;
    errdefer {
        for (result.face_fields[0..face_allocated]) |values| allocator.free(values);
        for (result.cell_fields[0..cell_allocated]) |values| allocator.free(values);
        if (modes_allocated) allocator.free(result.water_table_mode);
    }
    result.water_table_mode = try allocator.alloc(u8, expected_cell_count);
    modes_allocated = true;
    try reader.readSliceAll(result.water_table_mode);
    for (&result.cell_fields) |*values| {
        values.* = try allocator.alloc(f64, expected_cell_count);
        cell_allocated += 1;
        try readF64Slice(reader, values.*);
    }
    for (&result.face_fields) |*values| {
        values.* = try allocator.alloc(f64, face_count);
        face_allocated += 1;
    }
    for (0..face_count) |face| {
        for (&result.face_fields) |values| {
            values[face] = try readF64(reader);
        }
    }
    try result.validate();
    return result;
}

pub fn validateView(view: View) !void {
    try validateTarget(view.topology);
}

/// Checks only allocation dimensions and immutable indexing needed to safely
/// overwrite a failed live water-table owner.
pub fn validateTargetLayout(topology: *const Topology.State) !void {
    const cells = topology.water_table_mode.len;
    if (cells == 0) return error.WaterTableCheckpointDimensionMismatch;
    inline for (cellConstFields(topology)) |values|
        if (values.len != cells) return error.WaterTableCheckpointDimensionMismatch;
    for (topology.faces) |face|
        if (face.cell_index >= cells) return error.WaterTableCheckpointTopologyMismatch;
}

pub fn topologyFingerprint(topology: *const Topology.State) u64 {
    var hash: u64 = 14695981039346656037;
    fingerprintMix(&hash, topology.water_table_mode.len);
    fingerprintMix(&hash, topology.faces.len);
    for (topology.faces) |face| {
        fingerprintMix(&hash, face.cell_index);
        fingerprintMix(&hash, face.layer_index);
        fingerprintMix(&hash, @intFromEnum(face.direction));
        fingerprintMix(&hash, @as(u64, @bitCast(face.direction_sign)));
        fingerprintMix(&hash, @as(u64, @bitCast(face.directional_layer_width_m)));
        fingerprintMix(&hash, @as(u64, @bitCast(face.slope_sine)));
        fingerprintMix(&hash, @intFromBool(face.is_lower_boundary));
    }
    return hash;
}

fn validateTarget(topology: *const Topology.State) !void {
    try validateTargetLayout(topology);
    const cells = topology.water_table_mode.len;
    for (topology.water_table_mode) |mode|
        if (mode > 4) return error.InvalidWaterTableCheckpointMode;
    inline for (cellConstFields(topology)) |values| try validateFinite(values);
    for (topology.natural_water_table_surface_slope, topology.artificial_water_table_surface_slope) |natural_slope, artificial_slope| {
        if (natural_slope < 0 or natural_slope > 1 or
            artificial_slope < 0 or artificial_slope > 1)
            return error.InvalidWaterTableCheckpointSlope;
    }
    for (topology.faces) |face| {
        if (face.cell_index >= cells) return error.WaterTableCheckpointTopologyMismatch;
        inline for (.{ face.direction_sign, face.directional_layer_width_m, face.slope_sine }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteWaterTableCheckpoint;
        inline for (.{
            face.natural_water_table_distance_m,
            face.natural_exchange_fraction,
            face.artificial_water_table_distance_m,
            face.artificial_exchange_fraction,
            face.surface_runoff_fraction,
        }) |value| if (!std.math.isFinite(value))
            return error.NonFiniteWaterTableCheckpoint;
        if (face.natural_water_table_distance_m < 0 or
            face.artificial_water_table_distance_m < 0 or
            face.natural_exchange_fraction < 0 or face.natural_exchange_fraction > 1 or
            face.artificial_exchange_fraction < 0 or face.artificial_exchange_fraction > 1 or
            face.surface_runoff_fraction < 0 or face.surface_runoff_fraction > 1)
            return error.InvalidWaterTableCheckpointBoundary;
    }
}

fn validateValues(
    modes: []const u8,
    cell_fields: anytype,
    face_fields: anytype,
) !void {
    for (modes) |mode| if (mode > 4) return error.InvalidWaterTableCheckpointMode;
    for (cell_fields) |values| try validateFinite(values);
    for (face_fields) |values| try validateFinite(values);
    for (cell_fields[7], cell_fields[8]) |natural_slope, artificial_slope| {
        if (natural_slope < 0 or natural_slope > 1 or
            artificial_slope < 0 or artificial_slope > 1)
            return error.InvalidWaterTableCheckpointSlope;
    }
    for (0..face_fields[0].len) |face| {
        if (face_fields[0][face] < 0 or face_fields[2][face] < 0 or
            face_fields[1][face] < 0 or face_fields[1][face] > 1 or
            face_fields[3][face] < 0 or face_fields[3][face] > 1 or
            face_fields[4][face] < 0 or face_fields[4][face] > 1)
            return error.InvalidWaterTableCheckpointBoundary;
    }
}

fn cellConstFields(topology: *const Topology.State) [cell_field_count][]const f64 {
    return .{
        topology.natural_water_table_reference_depth_m,
        topology.natural_water_table_depth_m,
        topology.internal_water_table_depth_m,
        topology.active_layer_depth_m,
        topology.artificial_water_table_depth_m,
        topology.artificial_water_table_reference_depth_m,
        topology.initial_surface_boundary_depth_m,
        topology.natural_water_table_surface_slope,
        topology.artificial_water_table_surface_slope,
    };
}

fn cellFields(topology: *Topology.State) [cell_field_count][]f64 {
    return .{
        topology.natural_water_table_reference_depth_m,
        topology.natural_water_table_depth_m,
        topology.internal_water_table_depth_m,
        topology.active_layer_depth_m,
        topology.artificial_water_table_depth_m,
        topology.artificial_water_table_reference_depth_m,
        topology.initial_surface_boundary_depth_m,
        topology.natural_water_table_surface_slope,
        topology.artificial_water_table_surface_slope,
    };
}

fn fingerprintMix(hash: *u64, value: anytype) void {
    hash.* ^= @as(u64, @intCast(value));
    hash.* *%= 1099511628211;
}

fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| try writeF64(writer, value);
}

fn writeF64(writer: anytype, value: f64) !void {
    if (!std.math.isFinite(value)) return error.NonFiniteWaterTableCheckpoint;
    try writer.writeInt(u64, @bitCast(value), .little);
}

fn readF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| value.* = try readF64(reader);
}

fn readF64(reader: *std.Io.Reader) !f64 {
    const value: f64 = @bitCast(try reader.takeInt(u64, .little));
    if (!std.math.isFinite(value)) return error.NonFiniteWaterTableCheckpoint;
    return value;
}

fn validateFinite(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value))
        return error.NonFiniteWaterTableCheckpoint;
}

fn testTopology(allocator: std.mem.Allocator) !Topology.State {
    const modes = try allocator.alloc(u8, 1);
    modes[0] = 2;
    const natural_reference = try testF64(allocator, 1.0);
    const natural_current = try testF64(allocator, 1.0);
    const internal = try testF64(allocator, 1.0);
    const active = try testF64(allocator, 9999.0);
    const artificial_current = try testF64(allocator, 0.0);
    const artificial_reference = try testF64(allocator, 0.0);
    const initial_surface = try testF64(allocator, 0.0);
    const natural_slope = try testF64(allocator, 0.25);
    const artificial_slope = try testF64(allocator, 0.5);
    const faces = try allocator.alloc(Topology.Face, 2);
    faces[0] = .{
        .cell_index = 0,
        .layer_index = 0,
        .direction = .north,
        .direction_sign = 1,
        .directional_layer_width_m = 10,
        .slope_sine = 0.1,
        .natural_water_table_distance_m = 20,
        .natural_exchange_fraction = 0.5,
        .artificial_water_table_distance_m = 0,
        .artificial_exchange_fraction = 0,
        .surface_runoff_fraction = 0.2,
        .is_lower_boundary = false,
    };
    faces[1] = .{
        .cell_index = 0,
        .layer_index = 0,
        .direction = .lower,
        .direction_sign = -1,
        .directional_layer_width_m = 1,
        .slope_sine = 1,
        .natural_water_table_distance_m = 1,
        .natural_exchange_fraction = 0.1,
        .artificial_water_table_distance_m = 0,
        .artificial_exchange_fraction = 0,
        .surface_runoff_fraction = 0,
        .is_lower_boundary = true,
    };
    return .{
        .allocator = allocator,
        .faces = faces,
        .water_table_mode = modes,
        .natural_water_table_reference_depth_m = natural_reference,
        .natural_water_table_depth_m = natural_current,
        .internal_water_table_depth_m = internal,
        .active_layer_depth_m = active,
        .artificial_water_table_depth_m = artificial_current,
        .artificial_water_table_reference_depth_m = artificial_reference,
        .initial_surface_boundary_depth_m = initial_surface,
        .natural_water_table_surface_slope = natural_slope,
        .artificial_water_table_surface_slope = artificial_slope,
    };
}

fn testF64(allocator: std.mem.Allocator, value: f64) ![]f64 {
    const values = try allocator.alloc(f64, 1);
    values[0] = value;
    return values;
}

test "WTBL checkpoint resumes a mobile artificial-drainage event exactly" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    var target_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer target_arena.deinit();
    var source = try testTopology(source_arena.allocator());
    var target = try testTopology(target_arena.allocator());

    // Representative post-operations 23/24 state at a mid-day checkpoint.
    source.water_table_mode[0] = 4;
    source.natural_water_table_reference_depth_m[0] = 3.2;
    source.natural_water_table_depth_m[0] = 3.7;
    source.internal_water_table_depth_m[0] = 3.65;
    source.active_layer_depth_m[0] = 0.9;
    source.artificial_water_table_reference_depth_m[0] = 2.4;
    source.artificial_water_table_depth_m[0] = 2.55;
    source.initial_surface_boundary_depth_m[0] = 0.2;
    source.faces[0].natural_water_table_distance_m = 31;
    source.faces[0].natural_exchange_fraction = 0.75;
    source.faces[0].artificial_water_table_distance_m = 12;
    source.faces[0].artificial_exchange_fraction = 1;
    source.faces[0].surface_runoff_fraction = 0.4;

    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .topology = &source });
    var reader: std.Io.Reader = .fixed(bytes.written());
    var snapshot = try read(std.testing.allocator, &reader, 1);
    defer snapshot.deinit();
    try snapshot.restoreInto(&target);
    try std.testing.expectEqualDeep(source.faces, target.faces);
    try std.testing.expectEqualSlices(u8, source.water_table_mode, target.water_table_mode);
    inline for (cellConstFields(&source), cellConstFields(&target)) |expected, actual|
        try std.testing.expectEqualSlices(f64, expected, actual);

    // Both uninterrupted and resumed states produce exactly the same next
    // REDIST solar-noon mobile-table update.
    try std.testing.expect(try source.advanceMobileTablesAtSolarNoon(0, 0.2, 1.5, 10));
    try std.testing.expect(try target.advanceMobileTablesAtSolarNoon(0, 0.2, 1.5, 10));
    inline for (cellConstFields(&source), cellConstFields(&target)) |expected, actual|
        try std.testing.expectEqualSlices(f64, expected, actual);
}

test "WTBL checkpoint rejects schema and topology fingerprint mismatches atomically" {
    var invalid_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid_bytes.deinit();
    try invalid_bytes.writer.writeAll(magic);
    try invalid_bytes.writer.writeInt(u32, schema_version + 1, .little);
    var invalid_reader: std.Io.Reader = .fixed(invalid_bytes.written());
    try std.testing.expectError(
        error.UnsupportedWaterTableCheckpointVersion,
        read(std.testing.allocator, &invalid_reader, 1),
    );

    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    var target_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer target_arena.deinit();
    var source = try testTopology(source_arena.allocator());
    var target = try testTopology(target_arena.allocator());
    source.water_table_mode[0] = 4;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .topology = &source });
    var reader: std.Io.Reader = .fixed(bytes.written());
    var snapshot = try read(std.testing.allocator, &reader, 1);
    defer snapshot.deinit();
    target.faces[0].directional_layer_width_m = 11;
    const before_mode = target.water_table_mode[0];
    const before_natural_depth = target.natural_water_table_depth_m[0];
    try std.testing.expectError(
        error.WaterTableCheckpointTopologyMismatch,
        snapshot.restoreInto(&target),
    );
    try std.testing.expectEqual(before_mode, target.water_table_mode[0]);
    try std.testing.expectEqual(before_natural_depth, target.natural_water_table_depth_m[0]);
}

test "WTBL rollback overwrites invalid failed values and next hour proceeds" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    var target_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer target_arena.deinit();
    var source = try testTopology(source_arena.allocator());
    var target = try testTopology(target_arena.allocator());
    source.water_table_mode[0] = 4;
    source.natural_water_table_depth_m[0] = 3;

    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .topology = &source });
    var reader = std.Io.Reader.fixed(bytes.written());
    var snapshot = try read(std.testing.allocator, &reader, 1);
    defer snapshot.deinit();

    target.water_table_mode[0] = 255;
    target.natural_water_table_depth_m[0] = std.math.nan(f64);
    target.faces[0].natural_exchange_fraction = 2;
    try std.testing.expectError(
        error.InvalidWaterTableCheckpointMode,
        snapshot.restoreInto(&target),
    );
    try snapshot.restoreIntoForRollback(&target);
    try validateView(.{ .topology = &target });
    try std.testing.expectEqual(@as(u8, 4), target.water_table_mode[0]);
    try std.testing.expectEqual(@as(f64, 3), target.natural_water_table_depth_m[0]);
    try std.testing.expect(try target.advanceMobileTablesAtSolarNoon(0, 0.2, 1.5, 10));
}
