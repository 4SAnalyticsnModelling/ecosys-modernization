const std = @import("std");
const DailyFlux = @import("../../plant/accounting/daily_flux.zig").State;
const RootSoilExchange = @import("../../plant/root/plant_root_soil_exchange_accumulation.zig").State;
const salt_count = @import("../../plant/salt/harvest.zig").salt_count;

const magic = "ECOSPACT";
const version: u32 = 3;

const daily_array_count = countArrays(DailyFlux);
const exchange_array_count = countArrays(RootSoilExchange);
const daily_schema_fingerprint = schemaFingerprint(DailyFlux);
const exchange_schema_fingerprint = schemaFingerprint(RootSoilExchange);

pub const View = struct {
    daily_flux: *const DailyFlux,
    root_soil_exchange: *const RootSoilExchange,
    cumulative_harvest_salt_mol_by_plant: []const f64,
    cumulative_water_source_m3_by_plant: []const f64,
};

pub const Owned = struct {
    allocator: std.mem.Allocator,
    daily_flux: DailyFlux,
    root_soil_exchange: RootSoilExchange,
    cumulative_harvest_salt_mol_by_plant: []f64,
    cumulative_water_source_m3_by_plant: []f64,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.cumulative_water_source_m3_by_plant);
        self.allocator.free(self.cumulative_harvest_salt_mol_by_plant);
        self.root_soil_exchange.deinit();
        self.daily_flux.deinit();
        self.* = undefined;
    }
};

pub fn write(writer: anytype, view: View) !void {
    try validateView(view, view.daily_flux.plant_count);
    try writer.writeAll(magic);
    try writer.writeInt(u32, version, .little);
    try writer.writeInt(u64, @intCast(view.daily_flux.plant_count), .little);
    try writer.writeInt(u16, daily_array_count, .little);
    try writer.writeInt(u16, exchange_array_count, .little);
    try writer.writeInt(u64, daily_schema_fingerprint, .little);
    try writer.writeInt(u64, exchange_schema_fingerprint, .little);
    inline for (@typeInfo(DailyFlux).@"struct".fields) |field|
        if (field.type == []f64) try writeValues(writer, @field(view.daily_flux, field.name));
    inline for (@typeInfo(RootSoilExchange).@"struct".fields) |field|
        if (field.type == []f64) try writeValues(writer, @field(view.root_soil_exchange, field.name));
    try writeValues(writer, view.cumulative_harvest_salt_mol_by_plant);
    try writeValues(writer, view.cumulative_water_source_m3_by_plant);
}

pub fn read(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    maximum_plants: usize,
) !Owned {
    if (maximum_plants == 0) return error.InvalidPlantAccountingCheckpointLimit;
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic))
        return error.InvalidPlantAccountingCheckpointMagic;
    if (try reader.takeInt(u32, .little) != version)
        return error.UnsupportedPlantAccountingCheckpointVersion;
    const plant_count_u64 = try reader.takeInt(u64, .little);
    if (plant_count_u64 == 0 or plant_count_u64 > maximum_plants or
        plant_count_u64 > std.math.maxInt(usize))
        return error.PlantAccountingCheckpointPlantLimitExceeded;
    if (try reader.takeInt(u16, .little) != daily_array_count or
        try reader.takeInt(u16, .little) != exchange_array_count)
        return error.PlantAccountingCheckpointSchemaMismatch;
    if (try reader.takeInt(u64, .little) != daily_schema_fingerprint or
        try reader.takeInt(u64, .little) != exchange_schema_fingerprint)
        return error.PlantAccountingCheckpointSchemaMismatch;
    const plant_count: usize = @intCast(plant_count_u64);

    var daily_flux = try DailyFlux.init(allocator, plant_count);
    errdefer daily_flux.deinit();
    var root_soil_exchange = try RootSoilExchange.init(allocator, plant_count);
    errdefer root_soil_exchange.deinit();
    const salt_values = std.math.mul(usize, plant_count, salt_count) catch
        return error.PlantAccountingCheckpointPlantLimitExceeded;
    const cumulative_harvest_salt_mol_by_plant = try allocator.alloc(f64, salt_values);
    errdefer allocator.free(cumulative_harvest_salt_mol_by_plant);
    const cumulative_water_source_m3_by_plant = try allocator.alloc(f64, plant_count);
    errdefer allocator.free(cumulative_water_source_m3_by_plant);

    inline for (@typeInfo(DailyFlux).@"struct".fields) |field|
        if (field.type == []f64) try readValues(reader, @field(daily_flux, field.name));
    inline for (@typeInfo(RootSoilExchange).@"struct".fields) |field|
        if (field.type == []f64) try readValues(reader, @field(root_soil_exchange, field.name));
    try readValues(reader, cumulative_harvest_salt_mol_by_plant);
    try readValues(reader, cumulative_water_source_m3_by_plant);
    if (reader.peekByte()) |_| return error.TrailingPlantAccountingCheckpointData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    var result: Owned = .{
        .allocator = allocator,
        .daily_flux = daily_flux,
        .root_soil_exchange = root_soil_exchange,
        .cumulative_harvest_salt_mol_by_plant = cumulative_harvest_salt_mol_by_plant,
        .cumulative_water_source_m3_by_plant = cumulative_water_source_m3_by_plant,
    };
    errdefer result.deinit();
    try validateOwned(result, plant_count);
    return result;
}

pub fn validateView(view: View, expected_plants: usize) !void {
    try validateTargetLayout(view, expected_plants);
    try validateStateSlices(DailyFlux, view.daily_flux, expected_plants);
    try validateStateSlices(RootSoilExchange, view.root_soil_exchange, expected_plants);
    for (view.cumulative_water_source_m3_by_plant) |value|
        if (!std.math.isFinite(value)) return error.InvalidPlantAccountingCheckpointValue;
    for (view.cumulative_harvest_salt_mol_by_plant) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPlantAccountingCheckpointValue;
}

/// Checks only the destination allocation/layout needed for an owner swap or
/// overwrite. Failed-attempt values are deliberately not inspected.
pub fn validateTargetLayout(view: View, expected_plants: usize) !void {
    if (expected_plants == 0 or view.daily_flux.plant_count != expected_plants or
        view.root_soil_exchange.plant_count != expected_plants)
        return error.PlantAccountingCheckpointShapeMismatch;
    try validateStateSliceDimensions(DailyFlux, view.daily_flux, expected_plants);
    try validateStateSliceDimensions(RootSoilExchange, view.root_soil_exchange, expected_plants);
    const expected_salts = std.math.mul(usize, expected_plants, salt_count) catch
        return error.PlantAccountingCheckpointShapeMismatch;
    if (view.cumulative_harvest_salt_mol_by_plant.len != expected_salts)
        return error.PlantAccountingCheckpointShapeMismatch;
    if (view.cumulative_water_source_m3_by_plant.len != expected_plants)
        return error.PlantAccountingCheckpointShapeMismatch;
}

pub fn validateOwned(owned: Owned, expected_plants: usize) !void {
    try validateView(.{
        .daily_flux = &owned.daily_flux,
        .root_soil_exchange = &owned.root_soil_exchange,
        .cumulative_harvest_salt_mol_by_plant = owned.cumulative_harvest_salt_mol_by_plant,
        .cumulative_water_source_m3_by_plant = owned.cumulative_water_source_m3_by_plant,
    }, expected_plants);
}

fn countArrays(comptime T: type) u16 {
    var result: u16 = 0;
    for (@typeInfo(T).@"struct".fields) |field| if (field.type == []f64) {
        result += 1;
    };
    return result;
}

fn schemaFingerprint(comptime T: type) u64 {
    var hash: u64 = 14695981039346656037;
    for (@typeInfo(T).@"struct".fields) |field| {
        for (field.name) |byte| {
            hash = (hash ^ byte) *% 1099511628211;
        }
        hash = (hash ^ ':') *% 1099511628211;
        for (@typeName(field.type)) |byte| {
            hash = (hash ^ byte) *% 1099511628211;
        }
        hash = (hash ^ ';') *% 1099511628211;
    }
    return hash;
}

fn validateStateSlices(comptime T: type, state: *const T, plant_count: usize) !void {
    try validateStateSliceDimensions(T, state, plant_count);
    inline for (@typeInfo(T).@"struct".fields) |field| if (field.type == []f64) {
        const values = @field(state, field.name);
        for (values) |value| if (!std.math.isFinite(value))
            return error.InvalidPlantAccountingCheckpointValue;
    };
}

fn validateStateSliceDimensions(comptime T: type, state: *const T, plant_count: usize) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| if (field.type == []f64) {
        if (@field(state, field.name).len != plant_count)
            return error.PlantAccountingCheckpointShapeMismatch;
    };
}

fn writeValues(writer: anytype, values: []const f64) !void {
    for (values) |value| try writer.writeInt(u64, @bitCast(value), .little);
}

fn readValues(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| value.* = @bitCast(try reader.takeInt(u64, .little));
}

test "plant accounting checkpoint round trips every annual carrier" {
    const plant_count = 3;
    var daily_flux = try DailyFlux.init(std.testing.allocator, plant_count);
    defer daily_flux.deinit();
    var root_soil_exchange = try RootSoilExchange.init(std.testing.allocator, plant_count);
    defer root_soil_exchange.deinit();
    var salts: [plant_count * salt_count]f64 = undefined;
    var cumulative_water_source_m3_by_plant: [plant_count]f64 = undefined;

    var seed: f64 = -17.25;
    inline for (@typeInfo(DailyFlux).@"struct".fields) |field| if (field.type == []f64) {
        for (@field(daily_flux, field.name)) |*value| {
            value.* = seed;
            seed += 0.25;
        }
    };
    inline for (@typeInfo(RootSoilExchange).@"struct".fields) |field| if (field.type == []f64) {
        for (@field(root_soil_exchange, field.name)) |*value| {
            value.* = seed;
            seed += 0.25;
        }
    };
    for (&salts, 0..) |*value, index| value.* = @as(f64, @floatFromInt(index)) / 8.0;
    for (&cumulative_water_source_m3_by_plant, 0..) |*value, index|
        value.* = -0.125 * @as(f64, @floatFromInt(index + 1));

    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{
        .daily_flux = &daily_flux,
        .root_soil_exchange = &root_soil_exchange,
        .cumulative_harvest_salt_mol_by_plant = &salts,
        .cumulative_water_source_m3_by_plant = &cumulative_water_source_m3_by_plant,
    });
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, plant_count);
    defer restored.deinit();

    inline for (@typeInfo(DailyFlux).@"struct".fields) |field| if (field.type == []f64)
        try std.testing.expectEqualSlices(f64, @field(daily_flux, field.name), @field(restored.daily_flux, field.name));
    inline for (@typeInfo(RootSoilExchange).@"struct".fields) |field| if (field.type == []f64)
        try std.testing.expectEqualSlices(f64, @field(root_soil_exchange, field.name), @field(restored.root_soil_exchange, field.name));
    try std.testing.expectEqualSlices(f64, &salts, restored.cumulative_harvest_salt_mol_by_plant);
    try std.testing.expectEqualSlices(f64, &cumulative_water_source_m3_by_plant, restored.cumulative_water_source_m3_by_plant);
    try std.testing.expectEqual(@as(u16, 27), daily_array_count);
    try std.testing.expectEqual(@as(u16, 8), exchange_array_count);
}

test "plant accounting checkpoint rejects invalid shape non-finite and negative salt" {
    var daily_flux = try DailyFlux.init(std.testing.allocator, 2);
    defer daily_flux.deinit();
    var root_soil_exchange = try RootSoilExchange.init(std.testing.allocator, 2);
    defer root_soil_exchange.deinit();
    var salts = [_]f64{0} ** (2 * salt_count);
    var water = [_]f64{ 0, -0.25 };
    const view: View = .{
        .daily_flux = &daily_flux,
        .root_soil_exchange = &root_soil_exchange,
        .cumulative_harvest_salt_mol_by_plant = &salts,
        .cumulative_water_source_m3_by_plant = &water,
    };
    try std.testing.expectError(error.PlantAccountingCheckpointShapeMismatch, validateView(view, 3));
    daily_flux.net_carbon_change_g[1] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidPlantAccountingCheckpointValue, validateView(view, 2));
    daily_flux.net_carbon_change_g[1] = 0;
    water[1] = std.math.inf(f64);
    try std.testing.expectError(error.InvalidPlantAccountingCheckpointValue, validateView(view, 2));
    water[1] = -0.25;
    salts[9] = -0.1;
    try std.testing.expectError(error.InvalidPlantAccountingCheckpointValue, validateView(view, 2));
}

test "plant accounting rollback layout accepts failed values and next hour proceeds" {
    const plants = 1;
    var live_daily = try DailyFlux.init(std.testing.allocator, plants);
    defer live_daily.deinit();
    var live_exchange = try RootSoilExchange.init(std.testing.allocator, plants);
    defer live_exchange.deinit();
    const live_salts = try std.testing.allocator.alloc(f64, salt_count);
    defer std.testing.allocator.free(live_salts);
    @memset(live_salts, 0);
    var live_water = [_]f64{-0.125};

    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{
        .daily_flux = &live_daily,
        .root_soil_exchange = &live_exchange,
        .cumulative_harvest_salt_mol_by_plant = live_salts,
        .cumulative_water_source_m3_by_plant = &live_water,
    });
    var reader = std.Io.Reader.fixed(bytes.written());
    var backup = try read(std.testing.allocator, &reader, plants);
    defer backup.deinit();

    live_daily.net_carbon_change_g[0] = std.math.nan(f64);
    live_exchange.current_nitrogen_exchange_g_n[0] = std.math.inf(f64);
    live_salts[0] = -1;
    live_water[0] = std.math.nan(f64);
    const live_view: View = .{
        .daily_flux = &live_daily,
        .root_soil_exchange = &live_exchange,
        .cumulative_harvest_salt_mol_by_plant = live_salts,
        .cumulative_water_source_m3_by_plant = &live_water,
    };
    try std.testing.expectError(
        error.InvalidPlantAccountingCheckpointValue,
        validateView(live_view, plants),
    );
    try validateTargetLayout(live_view, plants);

    std.mem.swap(DailyFlux, &backup.daily_flux, &live_daily);
    std.mem.swap(RootSoilExchange, &backup.root_soil_exchange, &live_exchange);
    @memcpy(live_salts, backup.cumulative_harvest_salt_mol_by_plant);
    @memcpy(&live_water, backup.cumulative_water_source_m3_by_plant);
    try validateView(.{
        .daily_flux = &live_daily,
        .root_soil_exchange = &live_exchange,
        .cumulative_harvest_salt_mol_by_plant = live_salts,
        .cumulative_water_source_m3_by_plant = &live_water,
    }, plants);
    try live_daily.accumulateHourlyExchange(0, .{
        .net_canopy_carbon_g = 1,
        .gross_primary_productivity_g = 2,
        .signed_total_respiration_carbon_g = -0.5,
        .signed_aboveground_respiration_carbon_g = -0.25,
    });
    try std.testing.expectEqual(@as(f64, 1), live_daily.net_carbon_change_g[0]);
}

test "plant accounting checkpoint enforces read limits and exact schema" {
    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(magic);
    try writer.writeInt(u32, version, .little);
    try writer.writeInt(u64, 2, .little);
    try writer.writeInt(u16, daily_array_count, .little);
    try writer.writeInt(u16, exchange_array_count, .little);
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.PlantAccountingCheckpointPlantLimitExceeded,
        read(std.testing.allocator, &reader, 1),
    );

    var schema_writer = std.Io.Writer.fixed(&bytes);
    try schema_writer.writeAll(magic);
    try schema_writer.writeInt(u32, version, .little);
    try schema_writer.writeInt(u64, 1, .little);
    try schema_writer.writeInt(u16, daily_array_count - 1, .little);
    try schema_writer.writeInt(u16, exchange_array_count, .little);
    var schema_reader = std.Io.Reader.fixed(schema_writer.buffered());
    try std.testing.expectError(
        error.PlantAccountingCheckpointSchemaMismatch,
        read(std.testing.allocator, &schema_reader, 1),
    );

    var fingerprint_writer = std.Io.Writer.fixed(&bytes);
    try fingerprint_writer.writeAll(magic);
    try fingerprint_writer.writeInt(u32, version, .little);
    try fingerprint_writer.writeInt(u64, 1, .little);
    try fingerprint_writer.writeInt(u16, daily_array_count, .little);
    try fingerprint_writer.writeInt(u16, exchange_array_count, .little);
    try fingerprint_writer.writeInt(u64, daily_schema_fingerprint ^ 1, .little);
    try fingerprint_writer.writeInt(u64, exchange_schema_fingerprint, .little);
    var fingerprint_reader = std.Io.Reader.fixed(fingerprint_writer.buffered());
    try std.testing.expectError(
        error.PlantAccountingCheckpointSchemaMismatch,
        read(std.testing.allocator, &fingerprint_reader, 1),
    );
}
