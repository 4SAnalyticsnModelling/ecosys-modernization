const std = @import("std");
const State = @import("../../canopy/photosynthesis/photosynthesis.zig").State;
const Retention = @import("../../canopy/energy/precipitation_retention.zig").State;
const LayerDistribution = @import("../../canopy/radiation/layer_distribution.zig").State;
const magic = "ECOSCANP";
// v6 adds the coherent WTLS/WTSTK/WVSTK/ARSTP post-harvest snapshot.
const version: u32 = 6;
pub const Limits = struct {
    maximum_cells: usize,
    maximum_species: usize,
    maximum_branches: usize,
    maximum_nodes: usize,
    maximum_samples: usize,
    maximum_layers: usize,
    maximum_inclinations: usize,
    maximum_azimuths: usize,
};
pub const View = struct {
    canopy: *const State,
    retention: *const Retention,
    layer_distribution: *const LayerDistribution,
};
pub const Owned = struct {
    canopy: State,
    retention: Retention,
    layer_distribution: LayerDistribution,
    pub fn deinit(self: *Owned) void {
        self.layer_distribution.deinit();
        self.retention.deinit();
        self.canopy.deinit();
        self.* = undefined;
    }
};

pub fn write(writer: anytype, view: View) !void {
    try validate(view);
    try writeHeader(writer, view);
    try writeTopology(writer, view.canopy);
    try writePayload(writer, view);
}

noinline fn writeHeader(writer: anytype, view: View) !void {
    try writer.writeAll(magic);
    try writer.writeInt(u32, version, .little);
    try writer.writeInt(u64, @intCast(view.canopy.cell_count), .little);
    try writer.writeInt(u64, @intCast(view.canopy.species_count), .little);
    try writer.writeInt(u64, @intCast(view.layer_distribution.layer_count), .little);
    try writer.writeInt(u64, @intCast(view.layer_distribution.inclination_count), .little);
    try writer.writeInt(u64, @intCast(view.layer_distribution.azimuth_count), .little);
}

noinline fn writeTopology(writer: anytype, state: *const State) !void {
    try writeOffsets(writer, state.plant_branch_offsets);
    try writeOffsets(writer, state.branch_node_offsets);
    try writeOffsets(writer, state.node_sample_offsets);
}

noinline fn writePayload(writer: anytype, view: View) !void {
    try writeFloatFields(writer, view.canopy, &state_float_fields);
    try writeFloatFields(writer, view.retention, &retention_float_fields);
    try writeFloatFields(writer, view.layer_distribution, &layer_float_fields);
}

pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) !Owned {
    const dimensions = try readHeader(reader, limits);
    var topology = try readTopology(allocator, reader, dimensions, limits);
    defer topology.deinit(allocator);
    var result = try initOwned(allocator, dimensions, topology);
    errdefer result.deinit();
    try readPayload(reader, &result);
    try finishRead(reader, &result);
    return result;
}

const Dimensions = struct {
    cells: usize,
    species: usize,
    layers: usize,
    inclinations: usize,
    azimuths: usize,
};

noinline fn readHeader(reader: *std.Io.Reader, limits: Limits) !Dimensions {
    if (limits.maximum_cells == 0 or limits.maximum_species == 0 or limits.maximum_branches == 0 or limits.maximum_nodes == 0 or limits.maximum_samples == 0 or limits.maximum_layers == 0 or limits.maximum_inclinations == 0 or limits.maximum_azimuths == 0) return error.InvalidCanopyCheckpointLimits;
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic)) return error.InvalidCanopyCheckpointMagic;
    if (try reader.takeInt(u32, .little) != version) return error.UnsupportedCanopyCheckpointVersion;
    const cells = try bounded(reader, limits.maximum_cells, error.CanopyCheckpointCellLimitExceeded);
    const species = try bounded(reader, limits.maximum_species, error.CanopyCheckpointSpeciesLimitExceeded);
    const layers = try bounded(reader, limits.maximum_layers, error.CanopyCheckpointLayerLimitExceeded);
    const inclinations = try bounded(reader, limits.maximum_inclinations, error.CanopyCheckpointInclinationLimitExceeded);
    const azimuths = try bounded(reader, limits.maximum_azimuths, error.CanopyCheckpointAzimuthLimitExceeded);
    if (layers == 0 or inclinations == 0 or azimuths == 0)
        return error.InvalidCanopyCheckpointDimensions;
    return .{ .cells = cells, .species = species, .layers = layers, .inclinations = inclinations, .azimuths = azimuths };
}

const Topology = struct {
    branch_counts: Counts,
    node_counts: Counts,
    sample_counts: Counts,

    fn deinit(self: *Topology, allocator: std.mem.Allocator) void {
        allocator.free(self.sample_counts.counts);
        allocator.free(self.node_counts.counts);
        allocator.free(self.branch_counts.counts);
        self.* = undefined;
    }
};

noinline fn readTopology(allocator: std.mem.Allocator, reader: *std.Io.Reader, dimensions: Dimensions, limits: Limits) !Topology {
    const plants = try std.math.mul(usize, dimensions.cells, dimensions.species);
    const branch_counts = try readCounts(allocator, reader, plants, limits.maximum_branches);
    errdefer allocator.free(branch_counts.counts);
    const node_counts = try readCounts(allocator, reader, branch_counts.total, limits.maximum_nodes);
    errdefer allocator.free(node_counts.counts);
    const sample_counts = try readCounts(allocator, reader, node_counts.total, limits.maximum_samples);
    return .{ .branch_counts = branch_counts, .node_counts = node_counts, .sample_counts = sample_counts };
}

noinline fn initOwned(allocator: std.mem.Allocator, dimensions: Dimensions, topology: Topology) !Owned {
    var state = try State.init(allocator, dimensions.cells, dimensions.species, topology.branch_counts.counts, topology.node_counts.counts, topology.sample_counts.counts);
    errdefer state.deinit();
    var retention = try Retention.init(allocator, dimensions.cells, dimensions.species);
    errdefer retention.deinit();
    const layer_distribution = try LayerDistribution.init(
        allocator,
        dimensions.cells,
        dimensions.species,
        dimensions.layers,
        dimensions.inclinations,
        dimensions.azimuths,
        &state,
    );
    return .{ .canopy = state, .retention = retention, .layer_distribution = layer_distribution };
}

noinline fn readPayload(reader: *std.Io.Reader, result: *Owned) !void {
    try readFloatFields(reader, &result.canopy, &state_float_fields);
    try readFloatFields(reader, &result.retention, &retention_float_fields);
    try readFloatFields(reader, &result.layer_distribution, &layer_float_fields);
}

noinline fn finishRead(reader: *std.Io.Reader, result: *Owned) !void {
    if (reader.peekByte()) |_| return error.TrailingCanopyCheckpointData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try validate(.{ .canopy = &result.canopy, .retention = &result.retention, .layer_distribution = &result.layer_distribution });
}

const Counts = struct { counts: []usize, total: usize };
fn readCounts(allocator: std.mem.Allocator, reader: *std.Io.Reader, parent_count: usize, maximum_total: usize) !Counts {
    const stored_parent = try bounded(reader, parent_count, error.InvalidCanopyCheckpointOffsets);
    if (stored_parent != parent_count) return error.InvalidCanopyCheckpointOffsets;
    const total = try bounded(reader, maximum_total, error.CanopyCheckpointTopologyLimitExceeded);
    if (parent_count == 0 or total == 0) return error.InvalidCanopyCheckpointOffsets;
    const counts = try allocator.alloc(usize, parent_count);
    errdefer allocator.free(counts);
    var previous: usize = 0;
    for (0..parent_count + 1) |index| {
        const offset = try readUsize(reader);
        if (index == 0) {
            if (offset != 0) return error.InvalidCanopyCheckpointOffsets;
        } else {
            if (offset < previous or offset > total) return error.InvalidCanopyCheckpointOffsets;
            counts[index - 1] = offset - previous;
        }
        previous = offset;
    }
    if (previous != total) return error.InvalidCanopyCheckpointOffsets;
    return .{ .counts = counts, .total = total };
}
fn writeOffsets(writer: anytype, offsets: []const usize) !void {
    if (offsets.len < 2) return error.InvalidCanopyCheckpointOffsets;
    try writer.writeInt(u64, @intCast(offsets.len - 1), .little);
    try writer.writeInt(u64, @intCast(offsets[offsets.len - 1]), .little);
    for (offsets) |value| try writer.writeInt(u64, @intCast(value), .little);
}
fn validate(view: View) !void {
    const state = view.canopy.*;
    const plants = try std.math.mul(usize, state.cell_count, state.species_count);
    if (state.plant_branch_offsets.len != plants + 1) return error.InvalidCanopyCheckpointOffsets;
    inline for (.{ state.plant_branch_offsets, state.branch_node_offsets, state.node_sample_offsets }) |offsets| {
        if (offsets.len < 2 or offsets[0] != 0) return error.InvalidCanopyCheckpointOffsets;
        for (0..offsets.len - 1) |i| if (offsets[i] > offsets[i + 1]) return error.InvalidCanopyCheckpointOffsets;
    }
    try state.validateFinite();
    if (view.retention.cell_count != state.cell_count or view.retention.species_count != state.species_count) return error.CanopyCheckpointRetentionDimensionMismatch;
    try validateNonnegativeFloatFields(view.retention, &retention_float_fields, error.InvalidCanopyCheckpointRetention);
    const layers = view.layer_distribution;
    if (layers.cell_count != state.cell_count or
        layers.species_count != state.species_count or
        layers.node_count != state.node_sample_offsets.len - 1 or
        layers.branch_count != state.branch_node_offsets.len - 1 or
        layers.layer_count == 0 or layers.inclination_count == 0 or
        layers.azimuth_count == 0)
        return error.CanopyCheckpointLayerDimensionMismatch;
    try validateNonnegativeFloatFields(layers, &layer_float_fields, error.InvalidCanopyCheckpointLayerState);
}
fn bounded(reader: *std.Io.Reader, limit: usize, too_large: anyerror) !usize {
    const value = try reader.takeInt(u64, .little);
    if (value > limit or value > std.math.maxInt(usize)) return too_large;
    return @intCast(value);
}
fn readUsize(reader: *std.Io.Reader) !usize {
    const value = try reader.takeInt(u64, .little);
    if (value > std.math.maxInt(usize)) return error.CanopyCheckpointIntegerOverflow;
    return @intCast(value);
}
fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteCanopyCheckpoint;
        try writer.writeInt(u64, @bitCast(value), .little);
    }
}
fn readF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| {
        value.* = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(value.*)) return error.NonFiniteCanopyCheckpoint;
    }
}

const FloatField = struct {
    offset: usize,
};

fn floatFieldCount(comptime T: type) usize {
    var count: usize = 0;
    for (@typeInfo(T).@"struct".fields) |field| if (field.type == []f64) {
        count += 1;
    };
    return count;
}

fn floatFields(comptime T: type) [floatFieldCount(T)]FloatField {
    var result: [floatFieldCount(T)]FloatField = undefined;
    var index: usize = 0;
    for (@typeInfo(T).@"struct".fields) |field| if (field.type == []f64) {
        result[index] = .{ .offset = @offsetOf(T, field.name) };
        index += 1;
    };
    return result;
}

const state_float_fields = floatFields(State);
const retention_float_fields = floatFields(Retention);
const layer_float_fields = floatFields(LayerDistribution);

fn constFloatSliceAt(base: *const anyopaque, field: FloatField) []const f64 {
    const bytes: [*]const u8 = @ptrCast(base);
    const slot: *const []f64 = @ptrCast(@alignCast(bytes + field.offset));
    return slot.*;
}

fn floatSliceAt(base: *anyopaque, field: FloatField) []f64 {
    const bytes: [*]u8 = @ptrCast(base);
    const slot: *const []f64 = @ptrCast(@alignCast(bytes + field.offset));
    return slot.*;
}

noinline fn writeFloatFields(writer: anytype, base: *const anyopaque, fields: []const FloatField) !void {
    for (fields) |field| try writeF64Slice(writer, constFloatSliceAt(base, field));
}

noinline fn readFloatFields(reader: *std.Io.Reader, base: *anyopaque, fields: []const FloatField) !void {
    for (fields) |field| try readF64Slice(reader, floatSliceAt(base, field));
}

noinline fn validateNonnegativeFloatFields(base: *const anyopaque, fields: []const FloatField, invalid: anyerror) !void {
    for (fields) |field| for (constFloatSliceAt(base, field)) |value| {
        if (!std.math.isFinite(value) or value < -1e-14) return invalid;
    };
}

fn fillFloatFieldsForTest(base: *anyopaque, fields: []const FloatField) void {
    for (fields, 0..) |field, field_index| for (floatSliceAt(base, field), 0..) |*value, value_index| {
        value.* = @floatFromInt((field_index + 1) * 100_000 + value_index + 1);
    };
}

fn expectFloatFieldsEqual(expected: *const anyopaque, actual: *const anyopaque, fields: []const FloatField) !void {
    for (fields) |field| try std.testing.expectEqualSlices(
        f64,
        constFloatSliceAt(expected, field),
        constFloatSliceAt(actual, field),
    );
}

const generous_test_limits: Limits = .{
    .maximum_cells = 2,
    .maximum_species = 20,
    .maximum_branches = 100,
    .maximum_nodes = 200,
    .maximum_samples = 300,
    .maximum_layers = 20,
    .maximum_inclinations = 10,
    .maximum_azimuths = 10,
};

fn readValidCheckpointWithAllocator(allocator: std.mem.Allocator, checkpoint_bytes: []const u8) !void {
    var reader: std.Io.Reader = .fixed(checkpoint_bytes);
    var restored = try read(allocator, &reader, generous_test_limits);
    restored.deinit();
}

test "canopy checkpoint reconstructs arbitrary species branch node sample topology" {
    const branch_counts = [_]usize{ 1, 2, 1, 1, 3, 1, 1 };
    const node_counts = [_]usize{ 1, 2, 1, 1, 1, 2, 1, 1, 1, 1 };
    const sample_counts = [_]usize{ 1, 2, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1 };
    var source = try State.init(std.testing.allocator, 1, 7, &branch_counts, &node_counts, &sample_counts);
    defer source.deinit();
    var retention = try Retention.init(std.testing.allocator, 1, 7);
    defer retention.deinit();
    var layers = try LayerDistribution.init(
        std.testing.allocator,
        1,
        7,
        6,
        3,
        4,
        &source,
    );
    defer layers.deinit();
    fillFloatFieldsForTest(&source, &state_float_fields);
    fillFloatFieldsForTest(&retention, &retention_float_fields);
    fillFloatFieldsForTest(&layers, &layer_float_fields);
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .canopy = &source, .retention = &retention, .layer_distribution = &layers });
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, generous_test_limits);
    defer restored.deinit();
    try std.testing.expectEqualSlices(usize, source.plant_branch_offsets, restored.canopy.plant_branch_offsets);
    try std.testing.expectEqualSlices(usize, source.branch_node_offsets, restored.canopy.branch_node_offsets);
    try std.testing.expectEqualSlices(usize, source.node_sample_offsets, restored.canopy.node_sample_offsets);
    try expectFloatFieldsEqual(&source, &restored.canopy, &state_float_fields);
    try expectFloatFieldsEqual(&retention, &restored.retention, &retention_float_fields);
    try expectFloatFieldsEqual(&layers, &restored.layer_distribution, &layer_float_fields);

    const truncation_points = [_]usize{ 0, magic.len - 1, magic.len + @sizeOf(u32) - 1, bytes.written().len / 2, bytes.written().len - 1 };
    for (truncation_points) |end| {
        var truncated: std.Io.Reader = .fixed(bytes.written()[0..end]);
        try std.testing.expectError(error.EndOfStream, read(std.testing.allocator, &truncated, generous_test_limits));
    }
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        readValidCheckpointWithAllocator,
        .{bytes.written()},
    );

    var nonfinite = try std.testing.allocator.dupe(u8, bytes.written());
    defer std.testing.allocator.free(nonfinite);
    std.mem.writeInt(u64, nonfinite[nonfinite.len - @sizeOf(u64) ..][0..@sizeOf(u64)], @bitCast(std.math.nan(f64)), .little);
    var nonfinite_reader: std.Io.Reader = .fixed(nonfinite);
    try std.testing.expectError(
        error.NonFiniteCanopyCheckpoint,
        read(std.testing.allocator, &nonfinite_reader, generous_test_limits),
    );

    var invalid_topology = try std.testing.allocator.dupe(u8, bytes.written());
    defer std.testing.allocator.free(invalid_topology);
    const first_branch_offset = magic.len + @sizeOf(u32) + 7 * @sizeOf(u64);
    std.mem.writeInt(u64, invalid_topology[first_branch_offset..][0..@sizeOf(u64)], 1, .little);
    var invalid_topology_reader: std.Io.Reader = .fixed(invalid_topology);
    try std.testing.expectError(
        error.InvalidCanopyCheckpointOffsets,
        read(std.testing.allocator, &invalid_topology_reader, generous_test_limits),
    );

    try bytes.writer.writeByte(0xff);
    var trailing: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(
        error.TrailingCanopyCheckpointData,
        read(std.testing.allocator, &trailing, generous_test_limits),
    );
}
