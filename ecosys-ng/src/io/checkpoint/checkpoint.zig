const std = @import("std");
const builtin = @import("builtin");
const GridState = @import("../../state/grid.zig").GridState;
const PlantState = @import("../../state/grid.zig").PlantState;

const magic = "ECOSYSNG";
// Version 5 adds `maximum_rooting_layer_count` for parity with the production
// coupled checkpoint. The standalone streamed form must not widen NJ either.
const format_version: u32 = 5;
const coupled_magic = "ECOSCPST";
// Version 2 adds `maximum_rooting_layer_count`. Omitting NJ made a restart
// silently expand every root-zone-bounded disturbance to the full NL profile.
const coupled_format_version: u32 = 2;

/// Streams the currently authoritative coupled grid/plant state. Species and
/// soil axes are runtime dimensions, so this format has no historical five-
/// species or fixed-layer ceiling.
pub fn writeCoupled(writer: anytype, grid: GridState, plants: PlantState) !void {
    try validateCoupledDimensions(grid, plants);
    try grid.validateFinite();
    try plants.validateFinite();
    try writer.writeAll(coupled_magic);
    try writer.writeInt(u32, coupled_format_version, .little);
    try writer.writeInt(u64, @intCast(grid.cell_count), .little);
    try writer.writeInt(u64, @intCast(grid.soil_layer_capacity), .little);
    try writer.writeInt(u64, @intCast(plants.species_count), .little);
    for (grid.active_soil_layer_count) |count| try writer.writeInt(u64, @intCast(count), .little);
    for (grid.maximum_rooting_layer_count) |count| try writer.writeInt(u64, @intCast(count), .little);
    inline for (.{ grid.soil_temperature_k, grid.liquid_water_m3, grid.ice_water_m3, grid.matrix_liquid_water_m3, grid.macropore_liquid_water_m3, grid.matrix_ice_water_m3, grid.macropore_ice_water_m3, grid.matrix_pore_capacity_m3, grid.macropore_pore_capacity_m3, grid.matrix_air_volume_m3, grid.macropore_air_volume_m3, grid.air_volume_m3, grid.water_vapor_volume_m3, grid.matric_potential_megapascal, grid.surface_temperature_k, plants.canopy_temperature_k, plants.canopy_water_potential_megapascal, plants.canopy_water_storage_m_per_m2, plants.leaf_area_index_m2_m2, plants.shoot_carbon_g_m2, plants.root_carbon_g_m2 }) |values| try writeF64Slice(writer, values);
}

pub fn readCoupledInto(reader: *std.Io.Reader, grid: *GridState, plants: *PlantState) !void {
    const file_magic = try reader.takeArray(coupled_magic.len);
    if (!std.mem.eql(u8, file_magic, coupled_magic)) return error.InvalidCoupledCheckpointMagic;
    if (try reader.takeInt(u32, .little) != coupled_format_version) return error.UnsupportedCoupledCheckpointVersion;
    const cells = try reader.takeInt(u64, .little);
    const layers = try reader.takeInt(u64, .little);
    const species = try reader.takeInt(u64, .little);
    try validateCoupledDimensions(grid.*, plants.*);
    if (cells != grid.cell_count or layers != grid.soil_layer_capacity or species != plants.species_count) return error.CoupledCheckpointDimensionMismatch;
    for (grid.active_soil_layer_count) |*count| {
        const stored = try reader.takeInt(u64, .little);
        if (stored == 0 or stored > grid.soil_layer_capacity) return error.InvalidCheckpointActiveLayerCount;
        count.* = @intCast(stored);
    }
    for (grid.maximum_rooting_layer_count, grid.active_soil_layer_count) |*count, active_count| {
        const stored = try reader.takeInt(u64, .little);
        if (stored == 0 or stored > active_count)
            return error.InvalidCheckpointMaximumRootingLayerCount;
        count.* = @intCast(stored);
    }
    try readF64Slice(reader, "soil_temperature_k", grid.soil_temperature_k);
    try readF64Slice(reader, "liquid_water_m3", grid.liquid_water_m3);
    try readF64Slice(reader, "ice_water_m3", grid.ice_water_m3);
    try readF64Slice(reader, "matrix_liquid_water_m3", grid.matrix_liquid_water_m3);
    try readF64Slice(reader, "macropore_liquid_water_m3", grid.macropore_liquid_water_m3);
    try readF64Slice(reader, "matrix_ice_water_m3", grid.matrix_ice_water_m3);
    try readF64Slice(reader, "macropore_ice_water_m3", grid.macropore_ice_water_m3);
    try readF64Slice(reader, "matrix_pore_capacity_m3", grid.matrix_pore_capacity_m3);
    try readF64Slice(reader, "macropore_pore_capacity_m3", grid.macropore_pore_capacity_m3);
    try readF64Slice(reader, "matrix_air_volume_m3", grid.matrix_air_volume_m3);
    try readF64Slice(reader, "macropore_air_volume_m3", grid.macropore_air_volume_m3);
    try readF64Slice(reader, "air_volume_m3", grid.air_volume_m3);
    try readF64Slice(reader, "water_vapor_volume_m3", grid.water_vapor_volume_m3);
    try readF64Slice(reader, "matric_potential_megapascal", grid.matric_potential_megapascal);
    try readF64Slice(reader, "surface_temperature_k", grid.surface_temperature_k);
    try readF64Slice(reader, "canopy_temperature_k", plants.canopy_temperature_k);
    try readF64Slice(reader, "canopy_water_potential_megapascal", plants.canopy_water_potential_megapascal);
    try readF64Slice(reader, "canopy_water_storage_m_per_m2", plants.canopy_water_storage_m_per_m2);
    try readF64Slice(reader, "leaf_area_index_m2_m2", plants.leaf_area_index_m2_m2);
    try readF64Slice(reader, "shoot_carbon_g_m2", plants.shoot_carbon_g_m2);
    try readF64Slice(reader, "root_carbon_g_m2", plants.root_carbon_g_m2);
    if (reader.peekByte()) |_| return error.TrailingCoupledCheckpointData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try grid.validateFinite();
    try plants.validateFinite();
}

fn validateCoupledDimensions(grid: GridState, plants: PlantState) !void {
    if (grid.cell_count != plants.cell_count or
        grid.soil_layer_capacity != plants.soil_layer_count)
        return error.CoupledStateDimensionMismatch;
    try validateGridTopology(grid);
}

fn validateGridTopology(grid: GridState) !void {
    if (grid.active_soil_layer_count.len != grid.cell_count or
        grid.maximum_rooting_layer_count.len != grid.cell_count)
        return error.GridCheckpointTopologyDimensionMismatch;
    for (grid.active_soil_layer_count, grid.maximum_rooting_layer_count) |active, rooting| {
        if (active == 0 or active > grid.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        if (rooting == 0 or rooting > active)
            return error.InvalidMaximumRootingLayerCount;
    }
}

/// A deliberately simple, versioned tile checkpoint. Fields are streamed and
/// never assembled into a second full-grid buffer, forming the out-of-core I/O
/// boundary for later asynchronous tile scheduling.
pub fn write(writer: anytype, state: GridState) !void {
    try validateGridTopology(state);
    try state.validateFinite();
    try writer.writeAll(magic);
    try writer.writeInt(u32, format_version, .little);
    try writer.writeInt(u64, @intCast(state.cell_count), .little);
    try writer.writeInt(u64, @intCast(state.layer_count), .little);
    for (state.active_soil_layer_count) |active_layers| try writer.writeInt(u64, @intCast(active_layers), .little);
    for (state.maximum_rooting_layer_count) |rooting_layers| try writer.writeInt(u64, @intCast(rooting_layers), .little);
    try writeF64Slice(writer, state.soil_temperature_k);
    try writeF64Slice(writer, state.liquid_water_m3);
    try writeF64Slice(writer, state.ice_water_m3);
    try writeF64Slice(writer, state.matrix_liquid_water_m3);
    try writeF64Slice(writer, state.macropore_liquid_water_m3);
    try writeF64Slice(writer, state.matrix_ice_water_m3);
    try writeF64Slice(writer, state.macropore_ice_water_m3);
    try writeF64Slice(writer, state.matrix_pore_capacity_m3);
    try writeF64Slice(writer, state.macropore_pore_capacity_m3);
    try writeF64Slice(writer, state.matrix_air_volume_m3);
    try writeF64Slice(writer, state.macropore_air_volume_m3);
    try writeF64Slice(writer, state.air_volume_m3);
    try writeF64Slice(writer, state.water_vapor_volume_m3);
    try writeF64Slice(writer, state.matric_potential_megapascal);
    try writeF64Slice(writer, state.surface_temperature_k);
}

/// Streams a checkpoint directly into already allocated model buffers. No
/// second full-grid copy is created, which keeps restart memory bounded for
/// out-of-core domains.
pub fn readInto(reader: *std.Io.Reader, state: *GridState) !void {
    const file_magic = try reader.takeArray(magic.len);
    if (!std.mem.eql(u8, file_magic, magic)) return error.InvalidCheckpointMagic;
    const version = try reader.takeInt(u32, .little);
    if (version != format_version) return error.UnsupportedCheckpointVersion;
    const cell_count = try reader.takeInt(u64, .little);
    const layer_count = try reader.takeInt(u64, .little);
    if (cell_count != state.cell_count or layer_count != state.layer_count) {
        if (!builtin.is_test) {
            std.log.err("checkpoint dimensions do not match allocated state: file_cells={d} state_cells={d} file_layers={d} state_layers={d}", .{
                cell_count, state.cell_count, layer_count, state.layer_count,
            });
        }
        return error.CheckpointDimensionMismatch;
    }
    for (state.active_soil_layer_count, 0..) |*active_layers, cell_index| {
        const stored_count = try reader.takeInt(u64, .little);
        if (stored_count == 0 or stored_count > state.soil_layer_capacity) {
            if (!builtin.is_test) std.log.err("invalid active soil-layer count in checkpoint: cell={d} layers={d} capacity={d}", .{ cell_index, stored_count, state.soil_layer_capacity });
            return error.InvalidCheckpointActiveLayerCount;
        }
        active_layers.* = @intCast(stored_count);
    }
    for (state.maximum_rooting_layer_count, state.active_soil_layer_count, 0..) |*rooting_layers, active_layers, cell_index| {
        const stored_count = try reader.takeInt(u64, .little);
        if (stored_count == 0 or stored_count > active_layers) {
            if (!builtin.is_test) std.log.err("invalid maximum rooting-layer count in checkpoint: cell={d} rooting_layers={d} active_layers={d}", .{ cell_index, stored_count, active_layers });
            return error.InvalidCheckpointMaximumRootingLayerCount;
        }
        rooting_layers.* = @intCast(stored_count);
    }
    try readF64Slice(reader, "soil_temperature_k", state.soil_temperature_k);
    try readF64Slice(reader, "liquid_water_m3", state.liquid_water_m3);
    try readF64Slice(reader, "ice_water_m3", state.ice_water_m3);
    try readF64Slice(reader, "matrix_liquid_water_m3", state.matrix_liquid_water_m3);
    try readF64Slice(reader, "macropore_liquid_water_m3", state.macropore_liquid_water_m3);
    try readF64Slice(reader, "matrix_ice_water_m3", state.matrix_ice_water_m3);
    try readF64Slice(reader, "macropore_ice_water_m3", state.macropore_ice_water_m3);
    try readF64Slice(reader, "matrix_pore_capacity_m3", state.matrix_pore_capacity_m3);
    try readF64Slice(reader, "macropore_pore_capacity_m3", state.macropore_pore_capacity_m3);
    try readF64Slice(reader, "matrix_air_volume_m3", state.matrix_air_volume_m3);
    try readF64Slice(reader, "macropore_air_volume_m3", state.macropore_air_volume_m3);
    try readF64Slice(reader, "air_volume_m3", state.air_volume_m3);
    try readF64Slice(reader, "water_vapor_volume_m3", state.water_vapor_volume_m3);
    try readF64Slice(reader, "matric_potential_megapascal", state.matric_potential_megapascal);
    try readF64Slice(reader, "surface_temperature_k", state.surface_temperature_k);
    if (reader.peekByte()) |_| return error.TrailingCheckpointData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try state.validateFinite();
    try validateGridTopology(state.*);
}

fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteCheckpointValue;
        try writer.writeInt(u64, @bitCast(value), .little);
    }
}

fn readF64Slice(reader: *std.Io.Reader, comptime field_name: []const u8, values: []f64) !void {
    for (values, 0..) |*value, index| {
        value.* = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(value.*)) {
            std.log.err("non-finite checkpoint value: field={s} index={d} value={e}", .{ field_name, index, value.* });
            return error.NonFiniteCheckpointValue;
        }
    }
}

test "checkpoint serialization is versioned" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 3, .soil_layers = 4, .plant_populations = 7 },
        .{ .worker_threads = 1, .tile_cells = 8 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    var state = try GridState.init(std.testing.allocator, cfg);
    defer state.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, state);
    try std.testing.expect(std.mem.startsWith(u8, bytes.written(), magic));
}

test "checkpoint round trip streams into preallocated state" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 3, .lat_count = 2, .soil_layers = 4, .plant_populations = 9 },
        .{ .worker_threads = 2, .tile_cells = 3 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    var source = try GridState.init(std.testing.allocator, cfg);
    defer source.deinit();
    for (source.liquid_water_m3, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    for (source.matrix_pore_capacity_m3, 0..) |*value, index| value.* = @as(f64, @floatFromInt(index + 1)) * 2;
    source.active_soil_layer_count[0] = 3;
    source.maximum_rooting_layer_count[0] = 2;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, source);

    var destination = try GridState.init(std.testing.allocator, cfg);
    defer destination.deinit();
    var reader: std.Io.Reader = .fixed(bytes.written());
    try readInto(&reader, &destination);
    try std.testing.expectEqualSlices(f64, source.liquid_water_m3, destination.liquid_water_m3);
    try std.testing.expectEqualSlices(f64, source.matrix_pore_capacity_m3, destination.matrix_pore_capacity_m3);
    try std.testing.expectEqualSlices(usize, source.active_soil_layer_count, destination.active_soil_layer_count);
    try std.testing.expectEqualSlices(usize, source.maximum_rooting_layer_count, destination.maximum_rooting_layer_count);
}

test "checkpoint dimension mismatch fails before field data" {
    const small_cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    var source = try GridState.init(std.testing.allocator, small_cfg);
    defer source.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, source);

    var other_cfg = small_cfg;
    other_cfg.soil_layers = 3;
    var destination = try GridState.init(std.testing.allocator, other_cfg);
    defer destination.deinit();
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.CheckpointDimensionMismatch, readInto(&reader, &destination));
}

test "coupled checkpoint round trip includes arbitrary runtime plant species" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 2, .soil_layers = 3, .plant_populations = 7 }, .{ .worker_threads = 1, .tile_cells = 4 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 });
    var source_grid = try GridState.init(std.testing.allocator, cfg);
    defer source_grid.deinit();
    var source_plants = try PlantState.init(std.testing.allocator, cfg);
    defer source_plants.deinit();
    for (source_grid.soil_temperature_k, 0..) |*value, index| value.* = 270.0 + @as(f64, @floatFromInt(index));
    for (source_plants.shoot_carbon_g_m2, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    for (source_plants.root_carbon_g_m2, 0..) |*value, index| value.* = @as(f64, @floatFromInt(index + 1)) * 0.25;
    source_grid.active_soil_layer_count[0] = 2;
    source_grid.maximum_rooting_layer_count[0] = 1;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writeCoupled(&bytes.writer, source_grid, source_plants);
    var destination_grid = try GridState.init(std.testing.allocator, cfg);
    defer destination_grid.deinit();
    var destination_plants = try PlantState.init(std.testing.allocator, cfg);
    defer destination_plants.deinit();
    var reader: std.Io.Reader = .fixed(bytes.written());
    try readCoupledInto(&reader, &destination_grid, &destination_plants);
    try std.testing.expectEqualSlices(f64, source_grid.soil_temperature_k, destination_grid.soil_temperature_k);
    try std.testing.expectEqualSlices(f64, source_plants.shoot_carbon_g_m2, destination_plants.shoot_carbon_g_m2);
    try std.testing.expectEqualSlices(f64, source_plants.root_carbon_g_m2, destination_plants.root_carbon_g_m2);
    try std.testing.expectEqualSlices(usize, source_grid.active_soil_layer_count, destination_grid.active_soil_layer_count);
    try std.testing.expectEqualSlices(usize, source_grid.maximum_rooting_layer_count, destination_grid.maximum_rooting_layer_count);
}

test "coupled checkpoint rejects impossible maximum rooting depth" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 });
    var grid = try GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    var plants = try PlantState.init(std.testing.allocator, cfg);
    defer plants.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.maximum_rooting_layer_count[0] = 2;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try std.testing.expectError(
        error.InvalidMaximumRootingLayerCount,
        writeCoupled(&bytes.writer, grid, plants),
    );
}

test "coupled checkpoint rejects species dimension mismatch before state arrays" {
    const base = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 7 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 });
    var grid = try GridState.init(std.testing.allocator, base);
    defer grid.deinit();
    var plants = try PlantState.init(std.testing.allocator, base);
    defer plants.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writeCoupled(&bytes.writer, grid, plants);
    var other = base;
    other.plant_populations = 8;
    var other_grid = try GridState.init(std.testing.allocator, other);
    defer other_grid.deinit();
    var other_plants = try PlantState.init(std.testing.allocator, other);
    defer other_plants.deinit();
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.CoupledCheckpointDimensionMismatch, readCoupledInto(&reader, &other_grid, &other_plants));
}
