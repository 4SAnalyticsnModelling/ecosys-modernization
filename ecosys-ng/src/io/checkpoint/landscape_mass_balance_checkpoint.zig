const std = @import("std");
const audit = @import("../../validation/mass_balance_audit.zig");
const boundary = @import("../../validation/landscape_boundary_balance.zig");
const hourly_cell_conservation = @import("../../validation/hourly_cell_conservation.zig");
const accumulated_cell_conservation = @import("../../validation/accumulated_cell_conservation.zig");
const layer_local_conservation = @import("../../validation/layer_local_conservation.zig");
const inventory = @import("../../validation/landscape_mass_inventory.zig");

const magic = "ECOSMBAL";
// Version 2 added H2. Version 3 added scaled interval activity. Version 4
// replaced the dimensionally invalid universal absolute threshold. Version 5
// separates internal H2 production/consumption from external boundary fluxes.
// Version 6 makes the accumulated C/N/P monitor an all-storage ecosystem
// identity by including authoritative living plant pools and external plant
// exchange. A v5 baseline has soil-only semantics despite the same binary
// shape and therefore cannot be resumed conservatively.
// Version 7 replaces non-conserved pseudo-ion acceptance with independent
// Al/Fe/Ca/Mg/Na/K/S/Cl/Si accumulated balances. A v6 checkpoint has neither
// their boundary history nor their monitor baselines.
// Version 8 adds explicit GROSUB WTNDI inoculum C/N/P boundary history. A v7
// checkpoint cannot distinguish that external input from unexplained plant
// storage creation and is therefore not conservatively resumable.
// Version 9 separates biochemical/fire O2 production and consumption from
// actual external oxygen exchange. A v8 checkpoint cannot reconstruct that
// provenance without fabricating conservation history.
// Version 10 persists accepted hourly per-cell closure diagnostics and their
// accumulated maxima, so restart cannot silently reset the local audit trail.
// Version 11 adds sand/silt/clay mass and source-defined additive ROCK to the
// hourly and accumulated conservation coordinates.
// Version 12 adds signed internal CEC/AEC production and consumption so
// charcoal-derived exchange sites survive restart without becoming a
// fabricated external fertilizer input.
// Version 13 separates internal heat production/consumption from true
// landscape thermal boundaries. A v12 history cannot reconstruct this split.
// Version 14 persists baseline/latest storage and every direction-separated
// activity term independently for each cell. A v13 checkpoint retained only
// maxima, so accumulated local closure cannot be reconstructed from it.
// Version 15 adds the exact soil-layer, snow-layer, surface and canopy layout,
// hourly closure history, and accumulated local storage/activity state. A v14
// checkpoint can hide equal-and-opposite within-column defects and therefore
// cannot be resumed as a production-conservative history.
// Version 16 persists accepted upstream water-update arithmetic provenance in
// every accumulated local activity. A v15 checkpoint cannot reconstruct that
// history and could reject a conserved restart solely from binary64 roundoff.
// Version 17 adds authoritative water-normalized immobile-phosphate and
// geochemistry-solid carrier-rebase arithmetic provenance. A v16 history
// cannot reconstruct those accepted IEEE-754 bounds across restart.
// Version 18 records the distinct CaCO3 fertilizer-carbon boundary. Earlier
// histories cannot distinguish an applied amendment from unexplained C gain.
// Version 19 counts organic amendments once. A v18 accumulated boundary may
// include its NBP diagnostic again; that history cannot be recovered from the
// summed credit without the original events.
const version: u32 = 19;

pub const ExpectedShape = struct {
    cell_count: usize,
    soil_layer_capacity: usize,
    snow_layer_capacity: usize,

    pub fn layout(self: ExpectedShape) !layer_local_conservation.Layout {
        return layer_local_conservation.Layout.init(
            self.cell_count,
            self.soil_layer_capacity,
            self.snow_layer_capacity,
        );
    }
};

pub const HourlyCellClosureHistory = struct {
    last_maximum_absolute: [hourly_cell_conservation.quantity_count]f64 = @splat(0),
    last_maximum_normalized_relative: [hourly_cell_conservation.quantity_count]f64 = @splat(0),
    accumulated_maximum_absolute: [hourly_cell_conservation.quantity_count]f64 = @splat(0),
    accumulated_maximum_normalized_relative: [hourly_cell_conservation.quantity_count]f64 = @splat(0),
    accepted_hour_count: u64 = 0,

    pub fn recordAccepted(self: *HourlyCellClosureHistory, report: hourly_cell_conservation.Report) !void {
        if (!report.accepted()) return error.CannotRecordFailedHourlyCellClosure;
        var next = self.*;
        for (
            report.maximum_absolute,
            report.maximum_normalized_relative,
            0..,
        ) |absolute, normalized, quantity| {
            if (!std.math.isFinite(absolute) or absolute < 0 or
                !std.math.isFinite(normalized) or normalized < 0)
                return error.InvalidHourlyCellClosureHistory;
            next.last_maximum_absolute[quantity] = absolute;
            next.last_maximum_normalized_relative[quantity] = normalized;
            next.accumulated_maximum_absolute[quantity] = @max(
                next.accumulated_maximum_absolute[quantity],
                absolute,
            );
            next.accumulated_maximum_normalized_relative[quantity] = @max(
                next.accumulated_maximum_normalized_relative[quantity],
                normalized,
            );
        }
        next.accepted_hour_count = try std.math.add(u64, next.accepted_hour_count, 1);
        self.* = next;
    }
};

pub const State = struct {
    boundary_ledger: boundary.State,
    monitor: ?audit.Monitor,
    hourly_cell_closure: HourlyCellClosureHistory = .{},
    accumulated_cell_closure: ?accumulated_cell_conservation.State = null,
    hourly_layer_closure: HourlyCellClosureHistory = .{},
    accumulated_layer_closure: ?layer_local_conservation.AccumulatedState = null,

    pub fn deinit(self: *State) void {
        if (self.accumulated_layer_closure) |*value| value.deinit();
        if (self.accumulated_cell_closure) |*value| value.deinit();
        self.* = undefined;
    }
};

pub fn write(writer: *std.Io.Writer, state: State) !void {
    try validate(state);
    try writeHeaderAndLedger(writer, state);
    try writeAccumulatedClosures(writer, state);
    try writeMonitor(writer, state.monitor);
}

noinline fn writeHeaderAndLedger(writer: *std.Io.Writer, state: State) !void {
    try writer.writeAll(magic);
    try writer.writeInt(u32, version, .little);
    try writeNumericStruct(writer, state.boundary_ledger.cumulative);
    try writeNumericStruct(writer, state.boundary_ledger.cumulative_internal);
    try writeClosureHistory(writer, state.hourly_cell_closure);
    try writeClosureHistory(writer, state.hourly_layer_closure);
}

noinline fn writeAccumulatedClosures(writer: *std.Io.Writer, state: State) !void {
    try writer.writeByte(@intFromBool(state.accumulated_cell_closure != null));
    if (state.accumulated_cell_closure) |accumulated| {
        try writer.writeInt(u64, @intCast(accumulated.baseline_storage.len), .little);
        try writer.writeInt(u64, accumulated.accepted_hour_count, .little);
        for (accumulated.baseline_storage) |storage|
            try writeNumericStruct(writer, storage);
        for (accumulated.latest_storage) |storage|
            try writeNumericStruct(writer, storage);
        for (accumulated.cumulative_activity) |activity|
            try writeNumericStruct(writer, activity);
    }
    try writer.writeByte(@intFromBool(state.accumulated_layer_closure != null));
    if (state.accumulated_layer_closure) |accumulated| {
        try writer.writeInt(u64, @intCast(accumulated.layout.cell_count), .little);
        try writer.writeInt(u64, @intCast(accumulated.layout.soil_layer_capacity), .little);
        try writer.writeInt(u64, @intCast(accumulated.layout.snow_layer_capacity), .little);
        try writer.writeInt(u64, accumulated.accepted_hour_count, .little);
        for (accumulated.baseline_storage) |storage|
            try writeNumericStruct(writer, storage);
        for (accumulated.latest_storage) |storage|
            try writeNumericStruct(writer, storage);
        for (accumulated.cumulative_activity) |activity|
            try writeNumericStruct(writer, activity);
    }
}

noinline fn writeMonitor(writer: *std.Io.Writer, maybe_monitor: ?audit.Monitor) !void {
    try writer.writeByte(@intFromBool(maybe_monitor != null));
    if (maybe_monitor) |monitor| {
        try writeNumericStruct(writer, monitor.baseline);
        try writeNumericStruct(writer, monitor.activity_baseline);
        try writeNumericStruct(writer, monitor.cancellation_scale_baseline);
        try writeNumericStruct(writer, monitor.absolute_tolerance_per_area);
        try writer.writeInt(
            u64,
            @bitCast(monitor.relative_tolerance),
            .little,
        );
    }
}

pub fn read(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    expected_shape: ExpectedShape,
) !State {
    const expected_layout = expected_shape.layout() catch
        return error.InvalidLandscapeMassBalanceCheckpointCellCount;
    var result: State = .{ .boundary_ledger = .{}, .monitor = null };
    errdefer result.deinit();
    try readHeaderAndLedger(reader, &result);
    result.accumulated_cell_closure = try readAccumulatedCellClosure(
        allocator,
        reader,
        expected_shape,
    );
    result.accumulated_layer_closure = try readAccumulatedLayerClosure(
        allocator,
        reader,
        expected_shape,
        expected_layout,
    );
    result.monitor = try readMonitor(reader);
    try finishRead(reader, result);
    return result;
}

noinline fn readHeaderAndLedger(reader: *std.Io.Reader, result: *State) !void {
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic))
        return error.InvalidLandscapeMassBalanceCheckpointMagic;
    const encoded_version = try reader.takeInt(u32, .little);
    // A v1 monitor has no H2 storage baseline and its boundary ledger omitted
    // accepted atmospheric H2. Silently filling either value would make a
    // resumed run reproducible but non-conservative. Reject it explicitly;
    // v1.0 production checkpoints are written as version 2 below.
    if (encoded_version == 1)
        return error.LegacyCheckpointMissingHydrogenConservationState;
    if (encoded_version == 2)
        return error.LegacyCheckpointMissingScaledConservationState;
    if (encoded_version == 3)
        return error.LegacyCheckpointUsesUniversalConservationTolerance;
    if (encoded_version == 4)
        return error.LegacyCheckpointMissingInternalHydrogenConservationState;
    if (encoded_version == 5)
        return error.LegacyCheckpointMissingPlantConservationState;
    if (encoded_version == 6)
        return error.LegacyCheckpointMissingElementConservationState;
    if (encoded_version == 7)
        return error.LegacyCheckpointMissingSymbioticInoculumConservationState;
    if (encoded_version == 8)
        return error.LegacyCheckpointMissingInternalOxygenConservationState;
    if (encoded_version == 9)
        return error.LegacyCheckpointMissingHourlyCellClosureHistory;
    if (encoded_version == 11)
        return error.LegacyCheckpointMissingInternalExchangeCapacityConservationState;
    if (encoded_version == 12)
        return error.LegacyCheckpointMissingInternalHeatConservationState;
    if (encoded_version == 13)
        return error.LegacyCheckpointMissingAccumulatedCellClosureState;
    if (encoded_version == 14)
        return error.LegacyCheckpointMissingLayerLocalConservationState;
    if (encoded_version == 15)
        return error.LegacyCheckpointMissingWaterUpdateArithmeticProvenance;
    if (encoded_version == 17)
        return error.LegacyCheckpointMissingMineralFertilizerCarbonHistory;
    if (encoded_version == 18)
        return error.LegacyCheckpointAmbiguousOrganicFertilizerCarbonHistory;
    if (encoded_version != version)
        return error.UnsupportedLandscapeMassBalanceCheckpointVersion;
    result.boundary_ledger.cumulative = try readNumericStruct(boundary.Fluxes, reader);
    result.boundary_ledger.cumulative_internal = try readNumericStruct(
        boundary.InternalProcesses,
        reader,
    );
    result.hourly_cell_closure = try readClosureHistory(reader);
    result.hourly_layer_closure = try readClosureHistory(reader);
}

noinline fn readAccumulatedCellClosure(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    expected_shape: ExpectedShape,
) !?accumulated_cell_conservation.State {
    return switch (try reader.takeByte()) {
        0 => null,
        1 => accumulated: {
            const encoded_cell_count = try reader.takeInt(u64, .little);
            const cell_count = std.math.cast(usize, encoded_cell_count) orelse
                return error.InvalidLandscapeMassBalanceCheckpointCellCount;
            if (cell_count != expected_shape.cell_count)
                return error.LandscapeMassBalanceCheckpointCellCountMismatch;
            var state = try accumulated_cell_conservation.State.initEmpty(
                allocator,
                cell_count,
            );
            errdefer state.deinit();
            state.accepted_hour_count = try reader.takeInt(u64, .little);
            for (state.baseline_storage) |*storage|
                storage.* = try readNumericStruct(inventory.Storage, reader);
            for (state.latest_storage) |*storage|
                storage.* = try readNumericStruct(inventory.Storage, reader);
            for (state.cumulative_activity) |*activity|
                activity.* = try readNumericStruct(
                    hourly_cell_conservation.BoundaryActivity,
                    reader,
                );
            break :accumulated state;
        },
        else => return error.InvalidAccumulatedCellClosureTag,
    };
}

noinline fn readAccumulatedLayerClosure(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    expected_shape: ExpectedShape,
    expected_layout: layer_local_conservation.Layout,
) !?layer_local_conservation.AccumulatedState {
    return switch (try reader.takeByte()) {
        0 => null,
        1 => accumulated: {
            const encoded_cell_count = try reader.takeInt(u64, .little);
            const encoded_soil_layer_capacity = try reader.takeInt(u64, .little);
            const encoded_snow_layer_capacity = try reader.takeInt(u64, .little);
            const cell_count = std.math.cast(usize, encoded_cell_count) orelse
                return error.InvalidLandscapeMassBalanceCheckpointCellCount;
            const soil_layer_capacity = std.math.cast(usize, encoded_soil_layer_capacity) orelse
                return error.InvalidLandscapeMassBalanceCheckpointLayerCount;
            const snow_layer_capacity = std.math.cast(usize, encoded_snow_layer_capacity) orelse
                return error.InvalidLandscapeMassBalanceCheckpointLayerCount;
            if (cell_count != expected_shape.cell_count or
                soil_layer_capacity != expected_shape.soil_layer_capacity or
                snow_layer_capacity != expected_shape.snow_layer_capacity)
                return error.LandscapeMassBalanceCheckpointShapeMismatch;
            const layout = layer_local_conservation.Layout.init(
                cell_count,
                soil_layer_capacity,
                snow_layer_capacity,
            ) catch return error.InvalidLandscapeMassBalanceCheckpointLayerCount;
            if (!std.meta.eql(layout, expected_layout))
                return error.LandscapeMassBalanceCheckpointShapeMismatch;
            var state = try layer_local_conservation.AccumulatedState.initEmpty(
                allocator,
                layout,
            );
            errdefer state.deinit();
            state.accepted_hour_count = try reader.takeInt(u64, .little);
            for (state.baseline_storage) |*storage|
                storage.* = try readNumericStruct(inventory.Storage, reader);
            for (state.latest_storage) |*storage|
                storage.* = try readNumericStruct(inventory.Storage, reader);
            for (state.cumulative_activity) |*activity|
                activity.* = try readNumericStruct(
                    hourly_cell_conservation.BoundaryActivity,
                    reader,
                );
            break :accumulated state;
        },
        else => return error.InvalidAccumulatedLayerClosureTag,
    };
}

noinline fn readMonitor(reader: *std.Io.Reader) !?audit.Monitor {
    return switch (try reader.takeByte()) {
        0 => null,
        1 => monitor: {
            break :monitor .{
                .baseline = try readNumericStruct(audit.Balance, reader),
                .activity_baseline = try readNumericStruct(audit.BoundaryActivity, reader),
                .cancellation_scale_baseline = try readNumericStruct(audit.BoundaryActivity, reader),
                .absolute_tolerance_per_area = try readNumericStruct(
                    audit.AbsoluteTolerancePerArea,
                    reader,
                ),
                .relative_tolerance = @bitCast(try reader.takeInt(u64, .little)),
            };
        },
        else => return error.InvalidLandscapeMassBalanceMonitorTag,
    };
}

noinline fn finishRead(reader: *std.Io.Reader, result: State) !void {
    if (reader.peekByte()) |_|
        return error.TrailingLandscapeMassBalanceCheckpointData
    else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try validate(result);
}

noinline fn writeClosureHistory(writer: *std.Io.Writer, history: HourlyCellClosureHistory) !void {
    inline for (.{
        history.last_maximum_absolute,
        history.last_maximum_normalized_relative,
        history.accumulated_maximum_absolute,
        history.accumulated_maximum_normalized_relative,
    }) |values| for (values) |value|
        try writer.writeInt(u64, @bitCast(value), .little);
    try writer.writeInt(u64, history.accepted_hour_count, .little);
}

noinline fn readClosureHistory(reader: *std.Io.Reader) !HourlyCellClosureHistory {
    var result: HourlyCellClosureHistory = .{};
    inline for (.{
        &result.last_maximum_absolute,
        &result.last_maximum_normalized_relative,
        &result.accumulated_maximum_absolute,
        &result.accumulated_maximum_normalized_relative,
    }) |values| {
        for (values) |*value|
            value.* = @bitCast(try reader.takeInt(u64, .little));
    }
    result.accepted_hour_count = try reader.takeInt(u64, .little);
    return result;
}

fn NumericFieldMetadata(comptime T: type) type {
    const fields = std.meta.fields(T);
    return struct {
        const offsets: [fields.len]usize = offsets: {
            var result: [fields.len]usize = undefined;
            for (fields, 0..) |field, index| {
                if (field.type != f64)
                    @compileError("checkpoint numeric structs must contain only f64 fields");
                result[index] = @offsetOf(T, field.name);
            }
            break :offsets result;
        };
    };
}

noinline fn writeNumericFields(
    writer: *std.Io.Writer,
    bytes: [*]const u8,
    offsets: []const usize,
) !void {
    for (offsets) |offset| {
        const field: *align(1) const f64 = @ptrCast(bytes + offset);
        try writer.writeInt(u64, @bitCast(field.*), .little);
    }
}

noinline fn writeNumericStruct(writer: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    try writeNumericFields(
        writer,
        @ptrCast(&value),
        &NumericFieldMetadata(T).offsets,
    );
}

noinline fn readNumericStruct(comptime T: type, reader: *std.Io.Reader) !T {
    var result: T = undefined;
    try readNumericFields(
        reader,
        @ptrCast(&result),
        &NumericFieldMetadata(T).offsets,
    );
    return result;
}

noinline fn readNumericFields(
    reader: *std.Io.Reader,
    bytes: [*]u8,
    offsets: []const usize,
) !void {
    for (offsets) |offset| {
        const field: *align(1) f64 = @ptrCast(bytes + offset);
        field.* = @bitCast(try reader.takeInt(u64, .little));
    }
}

noinline fn validateFiniteFields(bytes: [*]const u8, offsets: []const usize) !void {
    for (offsets) |offset| {
        const field: *align(1) const f64 = @ptrCast(bytes + offset);
        if (!std.math.isFinite(field.*))
            return error.InvalidLandscapeMassBalanceCheckpointValue;
    }
}

noinline fn validateFiniteNonnegativeFields(
    bytes: [*]const u8,
    offsets: []const usize,
) !void {
    for (offsets) |offset| {
        const field: *align(1) const f64 = @ptrCast(bytes + offset);
        if (!std.math.isFinite(field.*) or field.* < 0)
            return error.InvalidLandscapeMassBalanceCheckpointValue;
    }
}

fn validateFiniteStruct(value: anytype) !void {
    const T = @TypeOf(value);
    try validateFiniteFields(
        @ptrCast(&value),
        &NumericFieldMetadata(T).offsets,
    );
}

fn validateFiniteNonnegativeStruct(value: anytype) !void {
    const T = @TypeOf(value);
    try validateFiniteNonnegativeFields(
        @ptrCast(&value),
        &NumericFieldMetadata(T).offsets,
    );
}

pub fn validateShape(state: State, expected_shape: ExpectedShape) !void {
    const expected_layout = expected_shape.layout() catch
        return error.InvalidLandscapeMassBalanceCheckpointCellCount;
    if (state.accumulated_cell_closure) |accumulated| {
        if (accumulated.baseline_storage.len != expected_shape.cell_count or
            accumulated.latest_storage.len != expected_shape.cell_count or
            accumulated.cumulative_activity.len != expected_shape.cell_count)
            return error.LandscapeMassBalanceCheckpointCellCountMismatch;
    }
    if (state.accumulated_layer_closure) |accumulated|
        if (!std.meta.eql(accumulated.layout, expected_layout))
            return error.LandscapeMassBalanceCheckpointShapeMismatch;
}

fn validate(state: State) !void {
    state.boundary_ledger.validateCheckpointState() catch
        return error.InvalidLandscapeMassBalanceCheckpointValue;
    inline for (.{
        state.hourly_cell_closure.last_maximum_absolute,
        state.hourly_cell_closure.last_maximum_normalized_relative,
        state.hourly_cell_closure.accumulated_maximum_absolute,
        state.hourly_cell_closure.accumulated_maximum_normalized_relative,
        state.hourly_layer_closure.last_maximum_absolute,
        state.hourly_layer_closure.last_maximum_normalized_relative,
        state.hourly_layer_closure.accumulated_maximum_absolute,
        state.hourly_layer_closure.accumulated_maximum_normalized_relative,
    }) |values| for (values) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidHourlyCellClosureHistory;
    if (state.accumulated_cell_closure) |accumulated| {
        accumulated.validate() catch
            return error.InvalidAccumulatedCellClosureState;
        if (accumulated.accepted_hour_count !=
            state.hourly_cell_closure.accepted_hour_count)
            return error.InvalidAccumulatedCellClosureHistory;
    } else if (state.hourly_cell_closure.accepted_hour_count != 0) {
        return error.InvalidAccumulatedCellClosureHistory;
    }
    if (state.accumulated_layer_closure) |accumulated| {
        accumulated.validate() catch
            return error.InvalidAccumulatedLayerClosureState;
        if (accumulated.accepted_hour_count !=
            state.hourly_layer_closure.accepted_hour_count)
            return error.InvalidAccumulatedLayerClosureHistory;
    } else if (state.hourly_layer_closure.accepted_hour_count != 0) {
        return error.InvalidAccumulatedLayerClosureHistory;
    }
    if (state.hourly_layer_closure.accepted_hour_count !=
        state.hourly_cell_closure.accepted_hour_count)
        return error.InvalidCellLayerClosureHistory;
    if (state.monitor) |monitor| {
        try validateFiniteStruct(monitor.baseline);
        try validateFiniteNonnegativeStruct(monitor.activity_baseline);
        try validateFiniteNonnegativeStruct(monitor.cancellation_scale_baseline);
        monitor.absolute_tolerance_per_area.validate() catch
            return error.InvalidLandscapeMassBalanceCheckpointValue;
        if (!std.math.isFinite(monitor.relative_tolerance) or
            monitor.relative_tolerance < 0)
            return error.InvalidLandscapeMassBalanceCheckpointValue;
    }
}

const checkpoint_test_shape: ExpectedShape = .{
    .cell_count = 1,
    .soil_layer_capacity = 1,
    .snow_layer_capacity = 1,
};

fn readValidCheckpointWithAllocator(
    allocator: std.mem.Allocator,
    checkpoint_bytes: []const u8,
) !void {
    var reader = std.Io.Reader.fixed(checkpoint_bytes);
    var restored = try read(allocator, &reader, checkpoint_test_shape);
    restored.deinit();
}

test "accepted hourly cell closure history records atomically" {
    var no_cells: [0]hourly_cell_conservation.CellReport = .{};
    var report: hourly_cell_conservation.Report = .{
        .cells = &no_cells,
        .maximum_absolute = @splat(0),
        .maximum_normalized_relative = @splat(0),
        .failing_cell_count = @splat(0),
    };
    const water = @intFromEnum(hourly_cell_conservation.Quantity.water);
    report.maximum_absolute[water] = 3e-8;
    report.maximum_normalized_relative[water] = 4e-10;
    var history: HourlyCellClosureHistory = .{};
    try history.recordAccepted(report);
    try std.testing.expectEqual(@as(u64, 1), history.accepted_hour_count);
    try std.testing.expectEqual(@as(f64, 3e-8), history.last_maximum_absolute[water]);
    const before = history;
    report.failing_cell_count[water] = 1;
    try std.testing.expectError(error.CannotRecordFailedHourlyCellClosure, history.recordAccepted(report));
    try std.testing.expectEqualDeep(before, history);
}

test "landscape mass balance checkpoint round trips cumulative history and monitor" {
    var bytes: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var boundary_state: boundary.State = .{};
    try boundary_state.accumulateAccepted(.{
        .rain_m3 = 2.5,
        .heat_input_megajoules = 4,
        .heat_output_megajoules = 1.25,
        .carbon_output_g_c = 2.5,
        .nitrogen_output_g_n = 3.75,
        .phosphorus_output_g_p = 0.625,
        .dinitrogen_input_g_n = 0.3,
        .ion_output_mol = 0.02,
        .hydrogen_output_g = 0.4,
        .symbiotic_inoculum_carbon_input_g_c = 0.2,
        .mineral_fertilizer_carbon_g_c = 108,
        .symbiotic_inoculum_nitrogen_input_g_n = 0.02,
        .symbiotic_inoculum_phosphorus_input_g_p = 0.004,
    });
    try boundary_state.accumulateAcceptedHydrogenTransformations(
        &.{0.3},
        &.{0.1},
        &.{0.2},
    );
    try boundary_state.accumulateAcceptedOxygenConsumptionTotal(0.75);
    try boundary_state.accumulateAcceptedHeatTransformationTotals(3.5, 0.25);
    try boundary_state.accumulateAcceptedPlantFireNutrientEmissionTotals(0.5, 0.25);
    var closure_history: HourlyCellClosureHistory = .{};
    closure_history.last_maximum_absolute[@intFromEnum(hourly_cell_conservation.Quantity.water)] = 2.5e-8;
    closure_history.last_maximum_normalized_relative[@intFromEnum(hourly_cell_conservation.Quantity.water)] = 4e-10;
    closure_history.accumulated_maximum_absolute[@intFromEnum(hourly_cell_conservation.Quantity.water)] = 7.5e-8;
    closure_history.accumulated_maximum_normalized_relative[@intFromEnum(hourly_cell_conservation.Quantity.water)] = 9e-10;
    closure_history.accepted_hour_count = 23;
    var accumulated = try accumulated_cell_conservation.State.initEmpty(
        std.testing.allocator,
        1,
    );
    @memset(accumulated.baseline_storage, .{});
    @memset(accumulated.latest_storage, .{});
    @memset(accumulated.cumulative_activity, .{});
    accumulated.baseline_storage[0].water_m3 = 10;
    accumulated.latest_storage[0].water_m3 = 12.5;
    accumulated.cumulative_activity[0].water_input_m3 = 2.5;
    accumulated.cumulative_activity[0].water_storage_update_roundoff_allowance_m3 = 1.25e-15;
    accumulated.cumulative_activity[0].phosphorus_storage_update_roundoff_allowance_g = 2.5e-15;
    accumulated.cumulative_activity[0].magnesium_storage_update_roundoff_allowance_mol = 3.25e-15;
    accumulated.cumulative_activity[0].phosphorus_input_g = 0.75;
    accumulated.cumulative_activity[0].calcium_input_mol = 0.25;
    accumulated.cumulative_activity[0].cation_exchange_capacity_internal_production_mol = 0.125;
    accumulated.accepted_hour_count = 23;
    var layer_closure_history = closure_history;
    layer_closure_history.last_maximum_absolute[@intFromEnum(hourly_cell_conservation.Quantity.water)] = 5e-8;
    const layer_layout = try checkpoint_test_shape.layout();
    var accumulated_layer = try layer_local_conservation.AccumulatedState.initEmpty(
        std.testing.allocator,
        layer_layout,
    );
    @memset(accumulated_layer.baseline_storage, .{});
    @memset(accumulated_layer.latest_storage, .{});
    @memset(accumulated_layer.cumulative_activity, .{});
    const soil_scope = try layer_layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    accumulated_layer.baseline_storage[soil_scope].rock_additive = 0.75;
    accumulated_layer.latest_storage[soil_scope].rock_additive = 0.5;
    accumulated_layer.cumulative_activity[soil_scope].rock_additive_output = 0.25;
    accumulated_layer.cumulative_activity[soil_scope].water_storage_update_roundoff_allowance_m3 = 7.5e-16;
    accumulated_layer.cumulative_activity[soil_scope].aluminum_storage_update_roundoff_allowance_mol = 3.75e-15;
    accumulated_layer.cumulative_activity[soil_scope].silicon_storage_update_roundoff_allowance_mol = 4.75e-15;
    accumulated_layer.accepted_hour_count = 23;
    var state: State = .{
        .boundary_ledger = boundary_state,
        .hourly_cell_closure = closure_history,
        .accumulated_cell_closure = accumulated,
        .hourly_layer_closure = layer_closure_history,
        .accumulated_layer_closure = accumulated_layer,
        .monitor = .{
            .baseline = .{
                .water_m3 = -2.5,
                .heat_megajoules = -4,
                .oxygen_g = 0,
                .carbon_g = 0,
                .nitrogen_g = -0.3,
                .phosphorus_g = 0,
                .ions_mol = 0.02,
                .hydrogen_g = -0.4,
            },
            .activity_baseline = .{
                .water_m3 = 2.5,
                .heat_megajoules = 4,
                .oxygen_g = 0,
                .carbon_g = 0,
                .nitrogen_g = 0.3,
                .phosphorus_g = 0,
                .ions_mol = 0.02,
                .hydrogen_g = 0.4,
            },
            .cancellation_scale_baseline = .{
                .water_m3 = 2.5,
                .heat_megajoules = 4,
                .oxygen_g = 0,
                .carbon_g = 0,
                .nitrogen_g = 0.3,
                .phosphorus_g = 0,
                .ions_mol = 0.02,
                .hydrogen_g = 0.4,
            },
            .absolute_tolerance_per_area = .{
                .water_m = 1e-7,
                .heat_megajoules_m2 = 2e-6,
            },
            .relative_tolerance = 1e-9,
        },
    };
    defer state.deinit();
    try write(&writer, state);
    var reader = std.Io.Reader.fixed(writer.buffered());
    var restored = try read(std.testing.allocator, &reader, checkpoint_test_shape);
    defer restored.deinit();
    try std.testing.expectEqual(
        @as(f64, 2.5),
        restored.boundary_ledger.cumulative.rain_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 0.3),
        restored.boundary_ledger.cumulative.dinitrogen_input_g_n,
    );
    try std.testing.expectEqual(
        @as(f64, 0.4),
        restored.boundary_ledger.cumulative.hydrogen_output_g,
    );
    try std.testing.expectEqual(@as(f64, 1.25), restored.boundary_ledger.cumulative.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 2.5), restored.boundary_ledger.cumulative.carbon_output_g_c);
    try std.testing.expectEqual(@as(f64, 4.25), restored.boundary_ledger.cumulative.nitrogen_output_g_n);
    try std.testing.expectEqual(@as(f64, 0.875), restored.boundary_ledger.cumulative.phosphorus_output_g_p);
    try std.testing.expectEqual(@as(f64, 0.2), restored.boundary_ledger.cumulative.symbiotic_inoculum_carbon_input_g_c);
    try std.testing.expectEqual(@as(f64, 108), restored.boundary_ledger.cumulative.mineral_fertilizer_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0.02), restored.boundary_ledger.cumulative.symbiotic_inoculum_nitrogen_input_g_n);
    try std.testing.expectEqual(@as(f64, 0.004), restored.boundary_ledger.cumulative.symbiotic_inoculum_phosphorus_input_g_p);
    try std.testing.expectEqual(
        @as(f64, 0.5),
        restored.boundary_ledger.cumulative_internal.hydrogen_production_g_h,
    );
    try std.testing.expectEqual(
        @as(f64, 0.1),
        restored.boundary_ledger.cumulative_internal.hydrogen_consumption_g_h,
    );
    try std.testing.expectEqual(
        @as(f64, 0.75),
        restored.boundary_ledger.cumulative_internal.oxygen_consumption_g_o,
    );
    try std.testing.expectEqual(
        @as(f64, 3.5),
        restored.boundary_ledger.cumulative_internal.heat_production_megajoules,
    );
    try std.testing.expectEqual(
        @as(f64, 0.25),
        restored.boundary_ledger.cumulative_internal.heat_consumption_megajoules,
    );
    try std.testing.expectEqual(
        @as(f64, -4),
        restored.monitor.?.baseline.heat_megajoules,
    );
    try std.testing.expectEqual(
        @as(f64, -0.4),
        restored.monitor.?.baseline.hydrogen_g,
    );
    try std.testing.expectEqual(@as(f64, 1e-7), restored.monitor.?.absolute_tolerance_per_area.water_m);
    try std.testing.expectEqual(@as(f64, 2e-6), restored.monitor.?.absolute_tolerance_per_area.heat_megajoules_m2);
    try std.testing.expectEqual(
        @as(f64, 2.5),
        restored.monitor.?.activity_baseline.water_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 1e-9),
        restored.monitor.?.relative_tolerance,
    );
    try std.testing.expectEqual(@as(f64, 2.5e-8), restored.hourly_cell_closure.last_maximum_absolute[@intFromEnum(hourly_cell_conservation.Quantity.water)]);
    try std.testing.expectEqual(@as(f64, 4e-10), restored.hourly_cell_closure.last_maximum_normalized_relative[@intFromEnum(hourly_cell_conservation.Quantity.water)]);
    try std.testing.expectEqual(@as(f64, 7.5e-8), restored.hourly_cell_closure.accumulated_maximum_absolute[@intFromEnum(hourly_cell_conservation.Quantity.water)]);
    try std.testing.expectEqual(@as(f64, 9e-10), restored.hourly_cell_closure.accumulated_maximum_normalized_relative[@intFromEnum(hourly_cell_conservation.Quantity.water)]);
    try std.testing.expectEqual(@as(u64, 23), restored.hourly_cell_closure.accepted_hour_count);
    try std.testing.expectEqual(@as(f64, 10), restored.accumulated_cell_closure.?.baseline_storage[0].water_m3);
    try std.testing.expectEqual(@as(f64, 12.5), restored.accumulated_cell_closure.?.latest_storage[0].water_m3);
    try std.testing.expectEqual(@as(f64, 2.5), restored.accumulated_cell_closure.?.cumulative_activity[0].water_input_m3);
    try std.testing.expectEqual(@as(f64, 1.25e-15), restored.accumulated_cell_closure.?.cumulative_activity[0].water_storage_update_roundoff_allowance_m3);
    try std.testing.expectEqual(@as(f64, 2.5e-15), restored.accumulated_cell_closure.?.cumulative_activity[0].phosphorus_storage_update_roundoff_allowance_g);
    try std.testing.expectEqual(@as(f64, 3.25e-15), restored.accumulated_cell_closure.?.cumulative_activity[0].magnesium_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 0.75), restored.accumulated_cell_closure.?.cumulative_activity[0].phosphorus_input_g);
    try std.testing.expectEqual(@as(f64, 0.25), restored.accumulated_cell_closure.?.cumulative_activity[0].calcium_input_mol);
    try std.testing.expectEqual(@as(f64, 0.125), restored.accumulated_cell_closure.?.cumulative_activity[0].cation_exchange_capacity_internal_production_mol);
    try std.testing.expectEqual(@as(u64, 23), restored.accumulated_cell_closure.?.accepted_hour_count);
    try std.testing.expectEqual(@as(f64, 5e-8), restored.hourly_layer_closure.last_maximum_absolute[@intFromEnum(hourly_cell_conservation.Quantity.water)]);
    try std.testing.expectEqualDeep(layer_layout, restored.accumulated_layer_closure.?.layout);
    try std.testing.expectEqual(@as(f64, 0.75), restored.accumulated_layer_closure.?.baseline_storage[soil_scope].rock_additive);
    try std.testing.expectEqual(@as(f64, 0.5), restored.accumulated_layer_closure.?.latest_storage[soil_scope].rock_additive);
    try std.testing.expectEqual(@as(f64, 0.25), restored.accumulated_layer_closure.?.cumulative_activity[soil_scope].rock_additive_output);
    try std.testing.expectEqual(@as(f64, 7.5e-16), restored.accumulated_layer_closure.?.cumulative_activity[soil_scope].water_storage_update_roundoff_allowance_m3);
    try std.testing.expectEqual(@as(f64, 3.75e-15), restored.accumulated_layer_closure.?.cumulative_activity[soil_scope].aluminum_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 4.75e-15), restored.accumulated_layer_closure.?.cumulative_activity[soil_scope].silicon_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(u64, 23), restored.accumulated_layer_closure.?.accepted_hour_count);
    var wrong_shape_reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LandscapeMassBalanceCheckpointShapeMismatch,
        read(std.testing.allocator, &wrong_shape_reader, .{
            .cell_count = 1,
            .soil_layer_capacity = 2,
            .snow_layer_capacity = 1,
        }),
    );
}

test "landscape mass balance checkpoint preserves bytes and cleans every failed read" {
    var accumulated_cell = try accumulated_cell_conservation.State.initEmpty(
        std.testing.allocator,
        1,
    );
    @memset(accumulated_cell.baseline_storage, .{});
    @memset(accumulated_cell.latest_storage, .{});
    @memset(accumulated_cell.cumulative_activity, .{});
    accumulated_cell.baseline_storage[0].water_m3 = 1.25;
    accumulated_cell.latest_storage[0].water_m3 = 2.5;
    accumulated_cell.cumulative_activity[0].water_input_m3 = 1.25;
    accumulated_cell.accepted_hour_count = 1;

    const layout = try checkpoint_test_shape.layout();
    var accumulated_layer = try layer_local_conservation.AccumulatedState.initEmpty(
        std.testing.allocator,
        layout,
    );
    @memset(accumulated_layer.baseline_storage, .{});
    @memset(accumulated_layer.latest_storage, .{});
    @memset(accumulated_layer.cumulative_activity, .{});
    const soil_scope = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    accumulated_layer.baseline_storage[soil_scope].water_m3 = 3.75;
    accumulated_layer.latest_storage[soil_scope].water_m3 = 5;
    accumulated_layer.cumulative_activity[soil_scope].water_input_m3 = 1.25;
    accumulated_layer.accepted_hour_count = 1;

    var state: State = .{
        .boundary_ledger = .{},
        .monitor = null,
        .accumulated_cell_closure = accumulated_cell,
        .accumulated_layer_closure = accumulated_layer,
    };
    defer state.deinit();
    state.hourly_cell_closure.accepted_hour_count = 1;
    state.hourly_layer_closure.accepted_hour_count = 1;
    state.boundary_ledger.cumulative.rain_m3 = 1.25;
    state.boundary_ledger.cumulative_internal.heat_production_megajoules = 2.5;

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try write(&encoded.writer, state);
    const valid_checkpoint = encoded.written();

    for (0..valid_checkpoint.len) |end| {
        var truncated = std.Io.Reader.fixed(valid_checkpoint[0..end]);
        try std.testing.expectError(
            error.EndOfStream,
            read(std.testing.allocator, &truncated, checkpoint_test_shape),
        );
    }
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        readValidCheckpointWithAllocator,
        .{valid_checkpoint},
    );

    var reader = std.Io.Reader.fixed(valid_checkpoint);
    var restored = try read(std.testing.allocator, &reader, checkpoint_test_shape);
    defer restored.deinit();
    var reencoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer reencoded.deinit();
    try write(&reencoded.writer, restored);
    try std.testing.expectEqualSlices(u8, valid_checkpoint, reencoded.written());
}

test "failed-hour checkpoint rollback restores shoot-fire nutrient boundary history" {
    var live: State = .{ .boundary_ledger = .{}, .monitor = null };
    try live.boundary_ledger.accumulateAcceptedPlantFireNutrientEmissionTotals(2, 0.5);
    var bytes: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try write(&writer, live);

    // Simulate a failed retry that published the same hour before rollback.
    try live.boundary_ledger.accumulateAcceptedPlantFireNutrientEmissionTotals(7, 3);
    var reader = std.Io.Reader.fixed(writer.buffered());
    live = try read(std.testing.allocator, &reader, checkpoint_test_shape);
    try std.testing.expectEqual(@as(f64, 2), live.boundary_ledger.cumulative.nitrogen_output_g_n);
    try std.testing.expectEqual(@as(f64, 0.5), live.boundary_ledger.cumulative.phosphorus_output_g_p);
}

test "landscape mass balance checkpoint rejects invalid and trailing state" {
    var invalid: State = .{ .boundary_ledger = .{}, .monitor = null };
    invalid.boundary_ledger.cumulative.rain_m3 = -1;
    var bytes: [8192]u8 = undefined;
    var invalid_writer = std.Io.Writer.fixed(&bytes);
    try std.testing.expectError(
        error.InvalidLandscapeMassBalanceCheckpointValue,
        write(&invalid_writer, invalid),
    );

    var writer = std.Io.Writer.fixed(&bytes);
    try write(&writer, .{ .boundary_ledger = .{}, .monitor = null });
    try writer.writeByte(99);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.TrailingLandscapeMassBalanceCheckpointData,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "landscape mass balance checkpoint preserves signed REDIST diagnostics" {
    var state: State = .{ .boundary_ledger = .{}, .monitor = null };
    state.boundary_ledger.cumulative.redist_carbon_surface_input_g_c = -1.25;
    state.boundary_ledger.cumulative.redist_carbon_subsurface_output_g_c = 2.5;
    state.boundary_ledger.cumulative.redist_oxygen_surface_input_g_o = -3.75;
    state.boundary_ledger.cumulative.redist_oxygen_subsurface_output_g_o = 5;
    state.boundary_ledger.cumulative.redist_hydrogen_surface_input_g_h = -6.25;
    state.boundary_ledger.cumulative.redist_hydrogen_subsurface_output_g_h = 7.5;

    var bytes: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try write(&writer, state);

    var reader = std.Io.Reader.fixed(writer.buffered());
    var restored = try read(std.testing.allocator, &reader, checkpoint_test_shape);
    defer restored.deinit();
    try std.testing.expectEqualDeep(
        state.boundary_ledger.cumulative,
        restored.boundary_ledger.cumulative,
    );
}

test "pre-hydrogen checkpoint is rejected rather than fabricating a baseline" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 1, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingHydrogenConservationState,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "pre-scaled-closure checkpoint is rejected rather than losing interval activity" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 2, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingScaledConservationState,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "universal-tolerance checkpoint is rejected rather than mixing physical units" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 3, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointUsesUniversalConservationTolerance,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "pre-internal-hydrogen checkpoint is rejected rather than fabricating transformations" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 4, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingInternalHydrogenConservationState,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "soil-only checkpoint is rejected rather than fabricating plant conservation baseline" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 5, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingPlantConservationState,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "pseudo-ion-only checkpoint is rejected rather than fabricating element baselines" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 6, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingElementConservationState,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "pre-inoculum checkpoint is rejected rather than fabricating WTNDI history" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 7, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingSymbioticInoculumConservationState,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "external-only oxygen checkpoint is rejected rather than fabricating reaction provenance" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 8, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingInternalOxygenConservationState,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "external-only heat checkpoint is rejected rather than fabricating internal provenance" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 12, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingInternalHeatConservationState,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "maxima-only checkpoint is rejected rather than resetting accumulated local closure" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 13, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingAccumulatedCellClosureState,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "cell-only checkpoint is rejected rather than fabricating layer-local history" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 14, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingLayerLocalConservationState,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "pre-mineral-carbon checkpoint is rejected rather than fabricating amendment history" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 17, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingMineralFertilizerCarbonHistory,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "duplicate-organic-carbon checkpoint history cannot be resumed" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 18, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointAmbiguousOrganicFertilizerCarbonHistory,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}

test "pre-provenance checkpoint is rejected rather than resetting arithmetic history" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, 15, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.LegacyCheckpointMissingWaterUpdateArithmeticProvenance,
        read(std.testing.allocator, &reader, checkpoint_test_shape),
    );
}
