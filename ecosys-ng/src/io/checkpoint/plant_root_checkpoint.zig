const std = @import("std");
const RootState = @import("../../plant/root/plant_root_system.zig").State;
const magic = "ECOSROOT";
/// Version 10 adds exact per-root/layer provenance for the six source-signed
/// GROSUB root-gas withdrawal totals. These hourly sidecars participate in
/// outer-hour rollback, so silently reading a version-9 byte layout as the
/// longer current layout would desynchronise every later field.
const version: u32 = 10;
/// Version 9 adds the distinct per-domain/layer GROSUB `RTNL` carrier. It
/// cannot be collapsed into per-axis `RTN2`: withdrawal moves RTNL upward but
/// clears RTN2 without adding it to the destination RTN2.
const without_root_gas_withdrawal_provenance_version: u32 = 9;
/// Version 8 adds per-axis `NINR`, the persistent deepest-layer gate used by
/// GROSUB secondary-root admission, extension, and withdrawal.
const without_secondary_axis_count_total_version: u32 = 8;
const without_axis_deepest_layer_version: u32 = 7;
/// Version 7 adds `retained_root_carbon_g_c_per_plant` (GROSUB 507 `WTRTA`),
/// the persistent per-plant recurrence that `BIND-GROSUB-506` introduced.
/// Because `WTRTA` is a recurrence on its own previous value, it MUST be
/// serialized or a checkpoint-resume run diverges from a continuous one, which
/// is exactly the Wave 2 `RESTART-EQUIVALENCE` obligation.
const without_retained_root_carbon_version: u32 = 6;
const previous_version: u32 = 5;
const compressed_porosity_version: u32 = 4;

pub const Limits = struct { maximum_plants: usize, maximum_soil_layers: usize, maximum_root_axes: usize };

const SerializedFieldKind = enum { float, unsigned, boolean };
const SerializedField = struct {
    offset: usize,
    kind: SerializedFieldKind,
};
const serialized_field_count = count: {
    var result: usize = 0;
    for (@typeInfo(RootState).@"struct".fields) |field| switch (field.type) {
        []f64, []usize, []bool => result += 1,
        else => {},
    };
    break :count result;
};
/// Runtime metadata keeps checkpoint traversal in declaration order without
/// cloning a write/error path for every reflected `RootState` slice. Offsets
/// are derived from the same fields the former `inline for` visited, so schema
/// additions remain explicit in the serialized stream and in the fingerprint
/// regression below.
const serialized_fields: [serialized_field_count]SerializedField = fields: {
    var result: [serialized_field_count]SerializedField = undefined;
    var index: usize = 0;
    for (@typeInfo(RootState).@"struct".fields) |field| {
        const kind: ?SerializedFieldKind = switch (field.type) {
            []f64 => .float,
            []usize => .unsigned,
            []bool => .boolean,
            else => null,
        };
        if (kind) |value| {
            result[index] = .{ .offset = @offsetOf(RootState, field.name), .kind = value };
            index += 1;
        }
    }
    break :fields result;
};

pub fn write(writer: anytype, state: RootState) !void {
    try validate(state);
    try writer.writeAll(magic);
    try writer.writeInt(u32, version, .little);
    try writer.writeInt(u64, @intCast(state.plant_count), .little);
    try writer.writeInt(u64, @intCast(state.soil_layer_count), .little);
    try writer.writeInt(u64, @intCast(state.root_axis_count), .little);
    try writeSerializedFields(writer, &state);
}

noinline fn writeSerializedFields(writer: anytype, state: *const RootState) !void {
    for (serialized_fields) |field| switch (field.kind) {
        .float => try writeF64Slice(writer, serializedSliceAt(f64, state, field.offset)),
        .unsigned => try writeUsizeSlice(writer, serializedSliceAt(usize, state, field.offset)),
        .boolean => try writeBoolSlice(writer, serializedSliceAt(bool, state, field.offset)),
    };
}

fn serializedSliceAt(comptime Element: type, state: *const RootState, offset: usize) []const Element {
    const bytes: [*]const u8 = @ptrCast(state);
    const field: *const []Element = @ptrCast(@alignCast(bytes + offset));
    return field.*;
}

pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) !RootState {
    @setEvalBranchQuota(2000);
    if (limits.maximum_plants == 0 or limits.maximum_soil_layers == 0 or limits.maximum_root_axes == 0) return error.InvalidPlantRootCheckpointLimits;
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic)) return error.InvalidPlantRootCheckpointMagic;
    const stored_version = try reader.takeInt(u32, .little);
    if (stored_version != version and
        stored_version != without_root_gas_withdrawal_provenance_version and
        stored_version != without_secondary_axis_count_total_version and
        stored_version != without_axis_deepest_layer_version and
        stored_version != without_retained_root_carbon_version and
        stored_version != previous_version and
        stored_version != compressed_porosity_version)
        return error.UnsupportedPlantRootCheckpointVersion;
    const plants = try bounded(reader, limits.maximum_plants, error.PlantRootCheckpointPlantLimitExceeded);
    const layers = try bounded(reader, limits.maximum_soil_layers, error.PlantRootCheckpointLayerLimitExceeded);
    const axes = try bounded(reader, limits.maximum_root_axes, error.PlantRootCheckpointAxisLimitExceeded);
    if (plants == 0 or layers == 0 or axes == 0) return error.InvalidPlantRootCheckpointDimensions;
    var state = try RootState.init(allocator, plants, layers, axes);
    errdefer state.deinit();
    inline for (@typeInfo(RootState).@"struct".fields) |field| switch (field.type) {
        []f64 => if (comptime isRootGasWithdrawalProvenance(field.name)) {
            if (stored_version >= version)
                try readF64Slice(reader, @field(state, field.name));
        } else if (comptime std.mem.eql(u8, field.name, "secondary_axis_count_total")) {
            if (stored_version >= without_root_gas_withdrawal_provenance_version)
                try readF64Slice(reader, @field(state, field.name));
        } else if (comptime std.mem.eql(u8, field.name, "retained_root_carbon_g_c_per_plant")) {
            // Absent before version 7. A pre-7 checkpoint has no `WTRTA`
            // history to restore, so it stays at the `State.init` zero and the
            // recurrence re-seeds itself on the first resumed hour from the
            // `WTRT/PP` branch of GROSUB 507--508, which is the same branch a
            // fresh planting takes. That is a defined restart, not silent
            // corruption, and it is stated here so nobody reads a pre-7 resume
            // as evidence for or against restart equivalence.
            if (stored_version >= without_axis_deepest_layer_version)
                try readF64Slice(reader, @field(state, field.name));
        } else if (stored_version == compressed_porosity_version and
            (comptime std.mem.eql(u8, field.name, "current_porosity_fraction_by_domain") or
                std.mem.eql(u8, field.name, "initial_porosity_fraction_by_domain")))
        {
            const per_plant = try allocator.alloc(f64, plants);
            defer allocator.free(per_plant);
            try readF64Slice(reader, per_plant);
            for (per_plant, 0..) |value, plant| {
                for (0..@import("../../plant/root/plant_root_system.zig").biological_domain_count) |domain| {
                    @field(state, field.name)[try state.domainIndex(plant, domain)] = value;
                }
            }
        } else try readF64Slice(reader, @field(state, field.name)),
        []usize => if (stored_version < without_secondary_axis_count_total_version and
            (comptime std.mem.eql(u8, field.name, "deepest_rooted_layer_by_axis")))
        {
            for (0..state.plant_count) |plant|
                @memset(
                    state.deepest_rooted_layer_by_axis[plant * state.root_axis_count .. (plant + 1) * state.root_axis_count],
                    state.planting_layer_by_plant[plant],
                );
        } else if (stored_version < without_axis_deepest_layer_version and
            (comptime isPlantRootedLayerBound(field.name)))
        {
            @memcpy(@field(state, field.name), state.planting_layer_by_plant);
        } else try readUsizeSlice(reader, @field(state, field.name)),
        []bool => try readBoolSlice(reader, @field(state, field.name)),
        else => {},
    };
    if (stored_version < without_root_gas_withdrawal_provenance_version)
        try rebuildLegacySecondaryAxisCountTotals(&state);
    if (reader.peekByte()) |_| return error.TrailingPlantRootCheckpointData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try validate(state);
    return state;
}

noinline fn validate(state: RootState) !void {
    if (state.plant_count == 0 or state.soil_layer_count == 0 or state.root_axis_count == 0 or state.planting_layer_by_plant.len != state.plant_count or state.deepest_rooted_layer_by_axis.len != state.plant_count * state.root_axis_count or state.active_root_axis_count.len != state.plant_count or state.roots_dead.len != state.plant_count) return error.InvalidPlantRootCheckpointDimensions;
    for (state.planting_layer_by_plant) |layer| if (layer >= state.soil_layer_count) return error.InvalidCheckpointPlantingLayer;
    for (state.deepest_rooted_layer_by_axis) |layer| if (layer >= state.soil_layer_count) return error.InvalidCheckpointRootAxisLayer;
    for (state.active_root_axis_count) |count| if (count > state.root_axis_count) return error.InvalidCheckpointActiveRootAxisCount;
    try state.validateFinite();
}

fn rebuildLegacySecondaryAxisCountTotals(state: *RootState) !void {
    @memset(state.secondary_axis_count_total, 0);
    for (0..state.plant_count) |plant| for (0..@import("../../plant/root/plant_root_system.zig").biological_domain_count) |domain| for (0..state.soil_layer_count) |layer| {
        const root = try state.layerIndex(plant, domain, layer);
        for (0..state.root_axis_count) |axis| {
            const value = state.axis_secondary_count[try state.layerAxisIndex(plant, domain, layer, axis)];
            if (!std.math.isFinite(value) or value < 0) return error.InvalidLegacySecondaryRootAxisCount;
            state.secondary_axis_count_total[root] += value;
            if (!std.math.isFinite(state.secondary_axis_count_total[root])) return error.InvalidLegacySecondaryRootAxisCount;
        }
    };
}
fn bounded(reader: *std.Io.Reader, limit: usize, comptime too_large: anyerror) !usize {
    const value = try reader.takeInt(u64, .little);
    if (value > limit or value > std.math.maxInt(usize)) return too_large;
    return @intCast(value);
}
fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFinitePlantRootCheckpoint;
        try writer.writeInt(u64, @bitCast(value), .little);
    }
}
fn readF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| {
        value.* = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(value.*)) return error.NonFinitePlantRootCheckpoint;
    }
}
fn writeUsizeSlice(writer: anytype, values: []const usize) !void {
    for (values) |value| try writer.writeInt(u64, @intCast(value), .little);
}
fn readUsizeSlice(reader: *std.Io.Reader, values: []usize) !void {
    for (values) |*value| {
        const stored = try reader.takeInt(u64, .little);
        if (stored > std.math.maxInt(usize)) return error.PlantRootCheckpointIntegerOverflow;
        value.* = @intCast(stored);
    }
}
fn writeBoolSlice(writer: anytype, values: []const bool) !void {
    for (values) |value| try writer.writeByte(@intFromBool(value));
}
fn readBoolSlice(reader: *std.Io.Reader, values: []bool) !void {
    for (values) |*value| value.* = switch (try reader.takeByte()) {
        0 => false,
        1 => true,
        else => return error.InvalidPlantRootCheckpointBoolean,
    };
}

test "root checkpoint round trip preserves runtime plants layers axes and every field" {
    var source = try RootState.init(std.testing.allocator, 7, 4, 12);
    defer source.deinit();
    source.planting_layer_by_plant[6] = 3;
    @memset(
        source.deepest_rooted_layer_by_axis[6 * source.root_axis_count .. 7 * source.root_axis_count],
        3,
    );
    source.current_deepest_rooted_layer_by_plant[6] = 3;
    source.next_deepest_rooted_layer_by_plant[6] = 3;
    source.deepest_rooted_layer_by_axis[try source.rootAxisIndex(5, 7)] = 2;
    try source.includeNextDeepestRootedLayer(5, 2);
    source.active_root_axis_count[6] = 11;
    source.roots_dead[6] = false;
    source.total_carbon_g[source.total_carbon_g.len - 1] = 42;
    source.axis_secondary_phosphorus_g[source.axis_secondary_phosphorus_g.len - 1] = 0.25;
    source.axis_secondary_count[source.axis_secondary_count.len - 1] = 2;
    source.secondary_axis_count_total[source.secondary_axis_count_total.len - 1] = 17;
    source.salt_content_mol[source.salt_content_mol.len - 1] = 3.5;
    source.exudate_carbon_exchange_g_c_per_h[source.exudate_carbon_exchange_g_c_per_h.len - 1] = -0.1;
    source.withdrawal_hydrogen_loss_g_h_per_h_by_root[
        source.withdrawal_hydrogen_loss_g_h_per_h_by_root.len - 1
    ] = -0.125;
    source.current_porosity_fraction_by_domain[try source.domainIndex(6, 0)] = 0.21;
    source.current_porosity_fraction_by_domain[try source.domainIndex(6, 1)] = 0.47;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, source);
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{ .maximum_plants = 20, .maximum_soil_layers = 30, .maximum_root_axes = 40 });
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 7), restored.plant_count);
    try std.testing.expectEqual(@as(usize, 12), restored.root_axis_count);
    try std.testing.expectEqual(@as(usize, 11), restored.active_root_axis_count[6]);
    try std.testing.expect(!restored.roots_dead[6]);
    try std.testing.expectEqualSlices(f64, source.total_carbon_g, restored.total_carbon_g);
    try std.testing.expectEqualSlices(f64, source.axis_secondary_phosphorus_g, restored.axis_secondary_phosphorus_g);
    try std.testing.expectEqualSlices(f64, source.secondary_axis_count_total, restored.secondary_axis_count_total);
    try std.testing.expectEqualSlices(f64, source.salt_content_mol, restored.salt_content_mol);
    try std.testing.expectEqualSlices(f64, source.exudate_carbon_exchange_g_c_per_h, restored.exudate_carbon_exchange_g_c_per_h);
    try std.testing.expectEqualSlices(
        f64,
        source.withdrawal_hydrogen_loss_g_h_per_h_by_root,
        restored.withdrawal_hydrogen_loss_g_h_per_h_by_root,
    );
    try std.testing.expectEqualSlices(f64, source.current_porosity_fraction_by_domain, restored.current_porosity_fraction_by_domain);
    try std.testing.expectEqualSlices(usize, source.current_deepest_rooted_layer_by_plant, restored.current_deepest_rooted_layer_by_plant);
    try std.testing.expectEqualSlices(usize, source.next_deepest_rooted_layer_by_plant, restored.next_deepest_rooted_layer_by_plant);
    try std.testing.expectEqualSlices(usize, source.deepest_rooted_layer_by_axis, restored.deepest_rooted_layer_by_axis);
}

test "version nine root checkpoint initializes missing root gas withdrawal provenance" {
    var source = try RootState.init(std.testing.allocator, 1, 2, 1);
    defer source.deinit();
    source.withdrawal_carbon_dioxide_loss_g_c_per_h[0] = -2;
    source.withdrawal_carbon_dioxide_loss_g_c_per_h_by_root[0] = -1;
    source.withdrawal_carbon_dioxide_loss_g_c_per_h_by_root[1] = -1;

    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writePriorVersionForTest(
        &bytes.writer,
        source,
        without_root_gas_withdrawal_provenance_version,
    );
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{
        .maximum_plants = 1,
        .maximum_soil_layers = 2,
        .maximum_root_axes = 1,
    });
    defer restored.deinit();

    try std.testing.expectEqual(
        @as(f64, -2),
        restored.withdrawal_carbon_dioxide_loss_g_c_per_h[0],
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 0, 0, 0, 0 },
        restored.withdrawal_carbon_dioxide_loss_g_c_per_h_by_root,
    );
}

test "version seven root checkpoint initializes missing axis NINR at planting layer" {
    var source = try RootState.init(std.testing.allocator, 2, 4, 3);
    defer source.deinit();
    source.planting_layer_by_plant[0] = 1;
    source.planting_layer_by_plant[1] = 2;
    @memset(source.deepest_rooted_layer_by_axis[0..3], 1);
    @memset(source.deepest_rooted_layer_by_axis[3..6], 2);
    source.current_deepest_rooted_layer_by_plant[0] = 3;
    source.current_deepest_rooted_layer_by_plant[1] = 2;
    source.next_deepest_rooted_layer_by_plant[0] = 3;
    source.next_deepest_rooted_layer_by_plant[1] = 2;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writePriorVersionForTest(
        &bytes.writer,
        source,
        without_axis_deepest_layer_version,
    );
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{
        .maximum_plants = 2,
        .maximum_soil_layers = 4,
        .maximum_root_axes = 3,
    });
    defer restored.deinit();
    try std.testing.expectEqualSlices(
        usize,
        &.{ 1, 1, 1, 2, 2, 2 },
        restored.deepest_rooted_layer_by_axis,
    );
    try std.testing.expectEqualSlices(
        usize,
        source.current_deepest_rooted_layer_by_plant,
        restored.current_deepest_rooted_layer_by_plant,
    );
}

test "version eight root checkpoint reconstructs missing RTNL from persisted RTN2" {
    var source = try RootState.init(std.testing.allocator, 2, 3, 4);
    defer source.deinit();
    source.axis_secondary_count[try source.layerAxisIndex(1, 0, 2, 0)] = 2;
    source.axis_secondary_count[try source.layerAxisIndex(1, 0, 2, 3)] = 5;
    source.secondary_axis_count_total[try source.layerIndex(1, 0, 2)] = 99;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writePriorVersionForTest(
        &bytes.writer,
        source,
        without_secondary_axis_count_total_version,
    );
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{
        .maximum_plants = 2,
        .maximum_soil_layers = 3,
        .maximum_root_axes = 4,
    });
    defer restored.deinit();
    try std.testing.expectEqual(
        @as(f64, 7),
        restored.secondary_axis_count_total[try restored.layerIndex(1, 0, 2)],
    );
    try std.testing.expectEqualSlices(
        usize,
        source.deepest_rooted_layer_by_axis,
        restored.deepest_rooted_layer_by_axis,
    );
}

fn isPlantRootedLayerBound(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "current_deepest_rooted_layer_by_plant") or
        std.mem.eql(u8, name, "next_deepest_rooted_layer_by_plant");
}

fn isRootedLayerBound(comptime name: []const u8) bool {
    return isPlantRootedLayerBound(name) or
        std.mem.eql(u8, name, "deepest_rooted_layer_by_axis");
}

fn isRootGasWithdrawalProvenance(comptime name: []const u8) bool {
    return std.mem.startsWith(u8, name, "withdrawal_") and
        std.mem.endsWith(u8, name, "_per_h_by_root");
}

fn isPlantRootedLayerBoundOffset(offset: usize) bool {
    return offset == @offsetOf(RootState, "current_deepest_rooted_layer_by_plant") or
        offset == @offsetOf(RootState, "next_deepest_rooted_layer_by_plant");
}

fn isRootGasWithdrawalProvenanceOffset(offset: usize) bool {
    return offset == @offsetOf(RootState, "withdrawal_carbon_dioxide_loss_g_c_per_h_by_root") or
        offset == @offsetOf(RootState, "withdrawal_oxygen_loss_g_o_per_h_by_root") or
        offset == @offsetOf(RootState, "withdrawal_methane_loss_g_c_per_h_by_root") or
        offset == @offsetOf(RootState, "withdrawal_nitrous_oxide_loss_g_n_per_h_by_root") or
        offset == @offsetOf(RootState, "withdrawal_ammonia_loss_g_n_per_h_by_root") or
        offset == @offsetOf(RootState, "withdrawal_hydrogen_loss_g_h_per_h_by_root");
}

fn writePriorVersionForTest(writer: anytype, state: RootState, stored_version: u32) !void {
    @setEvalBranchQuota(2000);
    try validate(state);
    try writer.writeAll(magic);
    if (stored_version != without_root_gas_withdrawal_provenance_version and
        stored_version != without_secondary_axis_count_total_version and
        stored_version != without_axis_deepest_layer_version and
        stored_version != compressed_porosity_version and
        stored_version != previous_version)
        return error.UnsupportedPlantRootCheckpointVersion;
    try writer.writeInt(u32, stored_version, .little);
    try writer.writeInt(u64, @intCast(state.plant_count), .little);
    try writer.writeInt(u64, @intCast(state.soil_layer_count), .little);
    try writer.writeInt(u64, @intCast(state.root_axis_count), .little);
    try writePriorVersionSerializedFields(writer, &state, stored_version);
}

noinline fn writePriorVersionSerializedFields(writer: anytype, state: *const RootState, stored_version: u32) !void {
    for (serialized_fields) |field| switch (field.kind) {
        .float => if (isRootGasWithdrawalProvenanceOffset(field.offset)) {
            if (stored_version >= version)
                try writeF64Slice(writer, serializedSliceAt(f64, state, field.offset));
        } else if (field.offset == @offsetOf(RootState, "secondary_axis_count_total")) {
            if (stored_version >= without_root_gas_withdrawal_provenance_version)
                try writeF64Slice(writer, serializedSliceAt(f64, state, field.offset));
        } else if (field.offset == @offsetOf(RootState, "retained_root_carbon_g_c_per_plant")) {
            // Version 7 field. A pre-7 stream does not contain it, so this
            // fixture writer must not emit it either or the reflective reader
            // walk desynchronises and the read reports
            // `TrailingPlantRootCheckpointData` on a stream that is actually
            // well formed. Found by lane A7b against the in-flight tree, and
            // it is the correct failure: these two fixtures are precisely the
            // regression guard for reader/writer field-set drift, so they
            // caught a real asymmetry rather than a spurious one.
            if (stored_version >= without_axis_deepest_layer_version)
                try writeF64Slice(writer, serializedSliceAt(f64, state, field.offset));
        } else if (stored_version == compressed_porosity_version and
            (field.offset == @offsetOf(RootState, "current_porosity_fraction_by_domain") or
                field.offset == @offsetOf(RootState, "initial_porosity_fraction_by_domain")))
        {
            const values = serializedSliceAt(f64, state, field.offset);
            for (0..state.plant_count) |plant| {
                const domain = try state.domainIndex(plant, 0);
                try writeF64Slice(writer, values[domain..][0..1]);
            }
        } else try writeF64Slice(writer, serializedSliceAt(f64, state, field.offset)),
        .unsigned => if (field.offset == @offsetOf(RootState, "deepest_rooted_layer_by_axis")) {
            if (stored_version >= without_secondary_axis_count_total_version)
                try writeUsizeSlice(writer, serializedSliceAt(usize, state, field.offset));
        } else if (stored_version >= without_axis_deepest_layer_version or
            !isPlantRootedLayerBoundOffset(field.offset))
            try writeUsizeSlice(writer, serializedSliceAt(usize, state, field.offset)),
        .boolean => try writeBoolSlice(writer, serializedSliceAt(bool, state, field.offset)),
    };
}

test "version four root checkpoint expands plant porosity into every biological domain" {
    var source = try RootState.init(std.testing.allocator, 2, 2, 3);
    defer source.deinit();
    source.current_porosity_fraction_by_domain[try source.domainIndex(0, 0)] = 0.23;
    source.initial_porosity_fraction_by_domain[try source.domainIndex(0, 0)] = 0.19;
    source.current_porosity_fraction_by_domain[try source.domainIndex(0, 1)] = 0.61;
    source.initial_porosity_fraction_by_domain[try source.domainIndex(0, 1)] = 0.62;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writePriorVersionForTest(&bytes.writer, source, compressed_porosity_version);
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{ .maximum_plants = 2, .maximum_soil_layers = 2, .maximum_root_axes = 3 });
    defer restored.deinit();
    try std.testing.expectEqual(@as(f64, 0.23), restored.current_porosity_fraction_by_domain[try restored.domainIndex(0, 0)]);
    try std.testing.expectEqual(@as(f64, 0.23), restored.current_porosity_fraction_by_domain[try restored.domainIndex(0, 1)]);
    try std.testing.expectEqual(@as(f64, 0.19), restored.initial_porosity_fraction_by_domain[try restored.domainIndex(0, 1)]);
}

test "version five root checkpoint initializes NI and NIX from planting layer" {
    var source = try RootState.init(std.testing.allocator, 2, 4, 3);
    defer source.deinit();
    source.planting_layer_by_plant[0] = 1;
    source.planting_layer_by_plant[1] = 2;
    @memset(source.deepest_rooted_layer_by_axis[0..3], 1);
    @memset(source.deepest_rooted_layer_by_axis[3..6], 2);
    source.current_deepest_rooted_layer_by_plant[0] = 3;
    source.next_deepest_rooted_layer_by_plant[0] = 3;
    source.current_deepest_rooted_layer_by_plant[1] = 3;
    source.next_deepest_rooted_layer_by_plant[1] = 3;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writePriorVersionForTest(&bytes.writer, source, previous_version);
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{ .maximum_plants = 2, .maximum_soil_layers = 4, .maximum_root_axes = 3 });
    defer restored.deinit();
    try std.testing.expectEqualSlices(usize, source.planting_layer_by_plant, restored.current_deepest_rooted_layer_by_plant);
    try std.testing.expectEqualSlices(usize, source.planting_layer_by_plant, restored.next_deepest_rooted_layer_by_plant);
}

test "BIND-GROSUB-506 version seven round trips the WTRTA recurrence and pre-seven defaults it" {
    // Restart-equivalence evidence for the persistent `WTRTA` field added with
    // `BIND-GROSUB-506`. `WTRTA` is a recurrence on its OWN previous value
    // (`grosub.f` 507), so unlike a per-hour flux it cannot be rebuilt from the
    // resumed state, and an unserialized copy would make a resumed run diverge
    // from a continuous one. That is the Wave 2 `RESTART-EQUIVALENCE`
    // obligation, so it is proven here rather than assumed.
    var source = try RootState.init(std.testing.allocator, 3, 2, 4);
    defer source.deinit();
    source.retained_root_carbon_g_c_per_plant[0] = 0.125;
    source.retained_root_carbon_g_c_per_plant[2] = 17.5;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, source);
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{ .maximum_plants = 3, .maximum_soil_layers = 2, .maximum_root_axes = 4 });
    defer restored.deinit();
    try std.testing.expectEqualSlices(
        f64,
        source.retained_root_carbon_g_c_per_plant,
        restored.retained_root_carbon_g_c_per_plant,
    );

    // A pre-7 stream carries no `WTRTA` history. It must default to zero
    // rather than desynchronise the reflective walk: on the first resumed hour
    // the recurrence re-seeds itself from the `WTRT/PP` branch of 507--508,
    // which is the same branch a fresh planting takes. Stated as a defined
    // restart so nobody reads a pre-7 resume as restart-equivalence evidence.
    var legacy_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer legacy_bytes.deinit();
    try writePriorVersionForTest(&legacy_bytes.writer, source, previous_version);
    var legacy_reader: std.Io.Reader = .fixed(legacy_bytes.written());
    var legacy_restored = try read(std.testing.allocator, &legacy_reader, .{ .maximum_plants = 3, .maximum_soil_layers = 2, .maximum_root_axes = 4 });
    defer legacy_restored.deinit();
    for (legacy_restored.retained_root_carbon_g_c_per_plant) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
}

test "root checkpoint enforces runtime axis limit before allocation" {
    var source = try RootState.init(std.testing.allocator, 1, 2, 12);
    defer source.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, source);
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.PlantRootCheckpointAxisLimitExceeded, read(std.testing.allocator, &reader, .{ .maximum_plants = 1, .maximum_soil_layers = 2, .maximum_root_axes = 10 }));
}

test "root checkpoint canonical byte layout remains stable" {
    var state = try RootState.init(std.testing.allocator, 1, 2, 2);
    defer state.deinit();
    state.planting_layer_by_plant[0] = 1;
    state.current_deepest_rooted_layer_by_plant[0] = 1;
    state.next_deepest_rooted_layer_by_plant[0] = 1;
    state.deepest_rooted_layer_by_axis[0] = 1;
    state.deepest_rooted_layer_by_axis[1] = 1;
    state.active_root_axis_count[0] = 2;
    state.roots_dead[0] = false;
    var float_field_index: usize = 0;
    for (serialized_fields) |field| if (field.kind == .float) {
        const bytes: [*]u8 = @ptrCast(&state);
        const values: *[]f64 = @ptrCast(@alignCast(bytes + field.offset));
        for (values.*, 0..) |*value, value_index| {
            value.* = @as(f64, @floatFromInt(float_field_index + 1)) +
                @as(f64, @floatFromInt(value_index + 1)) / 1024.0;
        }
        float_field_index += 1;
    };
    @memset(state.current_porosity_fraction_by_domain, 0.25);
    @memset(state.initial_porosity_fraction_by_domain, 0.5);
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, state);
    try std.testing.expectEqual(@as(usize, 6429), bytes.written().len);
    try std.testing.expectEqual(
        @as(u64, 0x7250e4667daefe29),
        std.hash.Wyhash.hash(0, bytes.written()),
    );
}
