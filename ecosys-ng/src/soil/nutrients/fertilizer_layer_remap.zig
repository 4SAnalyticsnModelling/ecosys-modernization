const std = @import("std");
const nitrogen_module = @import("../../management/fertilizer_nitrogen_inventory.zig");
const nitrogen_pools = @import("fertilizer_dissolution.zig");
const mineral_module = @import("../../management/mineral_fertilizer_inventory.zig");

/// REDIST ponding transaction for ZNH4FA...ZNO3FB and the mineral P/Ca/
/// ground-silicate stores. Mineral fertilizer moves only upward (L0 > L1), as
/// in the source's solid-chemistry branch. Both owners validate before mutation.
pub fn transferCellLayerFraction(
    nitrogen: *nitrogen_module.State,
    mineral: *mineral_module.State,
    cell: usize,
    boundary_layer: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    try validateCellLayerFraction(nitrogen, mineral, cell, boundary_layer, source_layer, destination_layer, fraction);
    const boundary = cell * nitrogen.layer_capacity + boundary_layer;
    const source = cell * nitrogen.layer_capacity + source_layer;
    const destination = cell * nitrogen.layer_capacity + destination_layer;
    if (fraction == 0) return;
    transferNitrogenStruct(
        &nitrogen.soil[boundary],
        &nitrogen.soil[source],
        &nitrogen.soil[destination],
        fraction,
    );
    if (source_layer > destination_layer)
        transferStruct(mineral_module.Inventory, &mineral.soil[source], &mineral.soil[destination], fraction);
}

pub fn validateCellLayerFraction(
    nitrogen: *const nitrogen_module.State,
    mineral: *const mineral_module.State,
    cell: usize,
    boundary_layer: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    if (nitrogen.cell_count != mineral.cell_count or nitrogen.layer_capacity != mineral.layer_capacity or cell >= nitrogen.cell_count or boundary_layer >= nitrogen.layer_capacity or source_layer >= nitrogen.layer_capacity or destination_layer >= nitrogen.layer_capacity or source_layer == destination_layer) return error.FertilizerLayerRemapDimensionMismatch;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidFertilizerLayerRemapFraction;
    const source = cell * nitrogen.layer_capacity + source_layer;
    const destination = cell * nitrogen.layer_capacity + destination_layer;
    const boundary = cell * nitrogen.layer_capacity + boundary_layer;
    try validateNitrogenStructTransfer(nitrogen.soil[boundary], nitrogen.soil[source], nitrogen.soil[destination], fraction);
    const mineral_fraction = if (source_layer > destination_layer) fraction else 0;
    try validateStructTransfer(mineral_module.Inventory, mineral.soil[source], mineral.soil[destination], mineral_fraction);
}

const pond_broadcast_fields = .{
    "broadcast_ammonium_mol_n",
    "broadcast_ammonia_mol_n",
    "broadcast_urea_mol_n",
    "broadcast_nitrate_mol_n",
};

/// REDIST pond-water settling carries ZNH4FA/ZNH3FA/ZNHUFA/ZNO3FA only
/// (`redist.f:436--451`). Banded fertilizer and dry mineral-fertilizer control
/// stores remain local.
pub fn transferPondParticulateLayerFraction(
    nitrogen: *nitrogen_module.State,
    cell: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    try validatePondParticulateLayerFraction(nitrogen, cell, source_layer, destination_layer, fraction);
    const source = cell * nitrogen.layer_capacity + source_layer;
    const destination = cell * nitrogen.layer_capacity + destination_layer;
    inline for (pond_broadcast_fields) |field_name| {
        const moved = fraction * @field(nitrogen.soil[source], field_name);
        @field(nitrogen.soil[source], field_name) -= moved;
        @field(nitrogen.soil[destination], field_name) += moved;
    }
}

pub fn validatePondParticulateLayerFraction(
    nitrogen: *const nitrogen_module.State,
    cell: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    if (cell >= nitrogen.cell_count or source_layer >= nitrogen.layer_capacity or destination_layer >= nitrogen.layer_capacity or source_layer == destination_layer)
        return error.FertilizerLayerRemapDimensionMismatch;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidFertilizerLayerRemapFraction;
    const source = cell * nitrogen.layer_capacity + source_layer;
    const destination = cell * nitrogen.layer_capacity + destination_layer;
    inline for (pond_broadcast_fields) |field_name| {
        const source_value = @field(nitrogen.soil[source], field_name);
        const destination_value = @field(nitrogen.soil[destination], field_name);
        const moved = fraction * source_value;
        inline for (.{ source_value, destination_value, moved, source_value - moved, destination_value + moved }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidFertilizerLayerRemapState;
    }
}

fn validateNitrogenStructTransfer(
    boundary: nitrogen_pools.FertilizerState,
    source: nitrogen_pools.FertilizerState,
    destination: nitrogen_pools.FertilizerState,
    fraction: f64,
) !void {
    inline for (@typeInfo(nitrogen_pools.FertilizerState).@"struct".fields) |field| {
        const source_value = @field(source, field.name);
        const destination_value = @field(destination, field.name);
        const moved = @min(fraction * @field(boundary, field.name), source_value);
        inline for (.{ source_value, destination_value, moved, source_value - moved, destination_value + moved }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidFertilizerLayerRemapState;
    }
}

fn transferNitrogenStruct(
    boundary: *const nitrogen_pools.FertilizerState,
    source: *nitrogen_pools.FertilizerState,
    destination: *nitrogen_pools.FertilizerState,
    fraction: f64,
) void {
    inline for (@typeInfo(nitrogen_pools.FertilizerState).@"struct".fields) |field| {
        const moved = @min(fraction * @field(boundary.*, field.name), @field(source.*, field.name));
        @field(source.*, field.name) -= moved;
        @field(destination.*, field.name) += moved;
    }
}

fn validateStructTransfer(comptime T: type, source: T, destination: T, fraction: f64) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const source_value = @field(source, field.name);
        const destination_value = @field(destination, field.name);
        const moved = fraction * source_value;
        const next_source = source_value - moved;
        const next_destination = destination_value + moved;
        inline for (.{ source_value, destination_value, next_source, next_destination }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidFertilizerLayerRemapState;
    }
}

fn transferStruct(comptime T: type, source: *T, destination: *T, fraction: f64) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const moved = fraction * @field(source, field.name);
        @field(source, field.name) -= moved;
        @field(destination, field.name) += moved;
    }
}

test "REDIST downward fertilizer ponding moves N but retains mineral inventories" {
    var nitrogen = try nitrogen_module.State.init(std.testing.allocator, 1, 3);
    defer nitrogen.deinit();
    var mineral = try mineral_module.State.init(std.testing.allocator, 1, 3);
    defer mineral.deinit();
    nitrogen.soil[0].broadcast_ammonium_mol_n = 8;
    nitrogen.soil[0].banded_urea_mol_n = 4;
    mineral.soil[0].broadcast_monocalcium_phosphate_mol = 12;
    mineral.soil[0].calcite_mol = 16;
    mineral.soil[0].potassium_ground_silicate_mol = 20;
    nitrogen.current_urease_inhibition_fraction[0] = 0.75;
    nitrogen.formulation[0] = 11;
    try transferCellLayerFraction(&nitrogen, &mineral, 0, 0, 0, 1, 0.25);
    try std.testing.expectEqual(@as(f64, 6), nitrogen.soil[0].broadcast_ammonium_mol_n);
    try std.testing.expectEqual(@as(f64, 2), nitrogen.soil[1].broadcast_ammonium_mol_n);
    try std.testing.expectEqual(@as(f64, 1), nitrogen.soil[1].banded_urea_mol_n);
    try std.testing.expectEqual(@as(f64, 12), mineral.soil[0].broadcast_monocalcium_phosphate_mol);
    try std.testing.expectEqual(@as(f64, 16), mineral.soil[0].calcite_mol);
    try std.testing.expectEqual(@as(f64, 20), mineral.soil[0].potassium_ground_silicate_mol);
    try std.testing.expectEqual(@as(f64, 0), mineral.soil[1].broadcast_monocalcium_phosphate_mol);
    try std.testing.expectEqual(@as(f64, 0), mineral.soil[1].calcite_mol);
    try std.testing.expectEqual(@as(f64, 0), mineral.soil[1].potassium_ground_silicate_mol);
    // REDIST does not move inhibitor/formulation control state.
    try std.testing.expectEqual(@as(f64, 0.75), nitrogen.current_urease_inhibition_fraction[0]);
    try std.testing.expectEqual(@as(f64, 0), nitrogen.current_urease_inhibition_fraction[1]);
    try std.testing.expectEqual(@as(u8, 11), nitrogen.formulation[0]);
}

test "REDIST pond settling carries broadcast fertilizer only" {
    var nitrogen = try nitrogen_module.State.init(std.testing.allocator, 1, 2);
    defer nitrogen.deinit();
    nitrogen.soil[0].broadcast_ammonium_mol_n = 8;
    nitrogen.soil[0].broadcast_nitrate_mol_n = 4;
    nitrogen.soil[0].banded_ammonium_mol_n = 16;
    try transferPondParticulateLayerFraction(&nitrogen, 0, 0, 1, 0.25);
    try std.testing.expectEqual(@as(f64, 6), nitrogen.soil[0].broadcast_ammonium_mol_n);
    try std.testing.expectEqual(@as(f64, 2), nitrogen.soil[1].broadcast_ammonium_mol_n);
    try std.testing.expectEqual(@as(f64, 3), nitrogen.soil[0].broadcast_nitrate_mol_n);
    try std.testing.expectEqual(@as(f64, 1), nitrogen.soil[1].broadcast_nitrate_mol_n);
    try std.testing.expectEqual(@as(f64, 16), nitrogen.soil[0].banded_ammonium_mol_n);
    try std.testing.expectEqual(@as(f64, 0), nitrogen.soil[1].banded_ammonium_mol_n);
}

test "REDIST fertilizer ponding rolls back both owners on a late invalid mineral" {
    var nitrogen = try nitrogen_module.State.init(std.testing.allocator, 1, 2);
    defer nitrogen.deinit();
    var mineral = try mineral_module.State.init(std.testing.allocator, 1, 2);
    defer mineral.deinit();
    nitrogen.soil[0].broadcast_nitrate_mol_n = 9;
    mineral.soil[0].potassium_ground_silicate_mol = std.math.nan(f64);
    try std.testing.expectError(error.InvalidFertilizerLayerRemapState, transferCellLayerFraction(&nitrogen, &mineral, 0, 0, 0, 1, 0.5));
    try std.testing.expectEqual(@as(f64, 9), nitrogen.soil[0].broadcast_nitrate_mol_n);
    try std.testing.expectEqual(@as(f64, 0), nitrogen.soil[1].broadcast_nitrate_mol_n);
}

test "REDIST upward fertilizer transfer uses boundary inventory capped by donor" {
    var nitrogen = try nitrogen_module.State.init(std.testing.allocator, 1, 2);
    defer nitrogen.deinit();
    var mineral = try mineral_module.State.init(std.testing.allocator, 1, 2);
    defer mineral.deinit();
    nitrogen.soil[0].broadcast_ammonium_mol_n = 2;
    nitrogen.soil[1].broadcast_ammonium_mol_n = 10;
    nitrogen.soil[0].banded_nitrate_mol_n = 20;
    nitrogen.soil[1].banded_nitrate_mol_n = 1;
    mineral.soil[1].calcite_mol = 10;

    try transferCellLayerFraction(&nitrogen, &mineral, 0, 0, 1, 0, 0.25);
    // REDIST: min(FX * pool[L], pool[L0]); L is recipient on upward moves.
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), nitrogen.soil[1].broadcast_ammonium_mol_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), nitrogen.soil[0].broadcast_ammonium_mol_n, 1e-15);
    try std.testing.expectEqual(@as(f64, 0), nitrogen.soil[1].banded_nitrate_mol_n);
    try std.testing.expectEqual(@as(f64, 21), nitrogen.soil[0].banded_nitrate_mol_n);
    // Mineral stores retain their source-fraction carrier.
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), mineral.soil[1].calcite_mol, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), mineral.soil[0].calcite_mol, 1e-15);
}
