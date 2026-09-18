//! Single-owner bridge for aqueous surface-litter ammonia.
//!
//! The oracle stores litter aqueous NH3 as `ZNH3S(0)` and gaseous NH3 as
//! `ZNH3G(0)` (`hour1.f:4494-4603`).  `litter_chemistry` owns the former in
//! mol N/m3.  The gas state's aqueous NH3 slot is therefore only a transient
//! g-N mirror used by the coupled gas/water phase equation; it is not a second
//! inventory or runoff-transport owner.

const std = @import("std");
const chemistry = @import("litter_chemistry.zig");
const gas = @import("../soil/gas/transport.zig");

pub fn refreshTransientFromChemistry(
    chemistry_state: *const chemistry.State,
    gas_state: *gas.State,
    litter_water_m3: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
) !void {
    try validateDimensions(chemistry_state, gas_state, litter_water_m3, nitrogen_molar_mass_g_per_mol);
    for (chemistry_state.cells, litter_water_m3) |cell, water| {
        if (!std.math.isFinite(cell.ammonia_mol_per_m3) or cell.ammonia_mol_per_m3 < 0)
            return error.InvalidLitterAmmoniaInventory;
        const mass = if (water > 0)
            cell.ammonia_mol_per_m3 * water * nitrogen_molar_mass_g_per_mol
        else
            0;
        if (!std.math.isFinite(mass) or mass < 0)
            return error.InvalidLitterAmmoniaInventory;
    }
    for (chemistry_state.cells, litter_water_m3, 0..) |cell, water, cell_index| {
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        gas_state.dissolved_mass_g[index] = if (water > 0)
            cell.ammonia_mol_per_m3 * water * nitrogen_molar_mass_g_per_mol
        else
            0;
        gas_state.macropore_dissolved_mass_g[index] = 0;
        gas_state.band_dissolved_mass_g[index] = 0;
    }
}

pub fn publishTransientToChemistry(
    chemistry_state: *chemistry.State,
    gas_state: *const gas.State,
    litter_water_m3: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
    absolute_tolerance_g_n: f64,
    relative_tolerance: f64,
) !void {
    try validateDimensions(chemistry_state, gas_state, litter_water_m3, nitrogen_molar_mass_g_per_mol);
    if (!std.math.isFinite(absolute_tolerance_g_n) or absolute_tolerance_g_n < 0 or
        !std.math.isFinite(relative_tolerance) or relative_tolerance < 0)
        return error.InvalidLitterAmmoniaBridgeTolerance;
    for (litter_water_m3, 0..) |water, cell_index| {
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        const dissolved = gas_state.dissolved_mass_g[index];
        if (!std.math.isFinite(dissolved) or dissolved < 0)
            return error.InvalidTransientLitterAmmoniaInventory;
        if (!std.math.isFinite(gas_state.macropore_dissolved_mass_g[index]) or
            gas_state.macropore_dissolved_mass_g[index] != 0 or
            !std.math.isFinite(gas_state.band_dissolved_mass_g[index]) or
            gas_state.band_dissolved_mass_g[index] != 0)
            return error.NoncanonicalTransientLitterAmmonia;
        if (water == 0) {
            const scale = @max(1.0, dissolved);
            if (dissolved > absolute_tolerance_g_n + relative_tolerance * scale)
                return error.LitterAmmoniaWithoutWaterCarrier;
        }
    }
    for (litter_water_m3, 0..) |water, cell_index| {
        if (water == 0) continue;
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        chemistry_state.cells[cell_index].ammonia_mol_per_m3 =
            gas_state.dissolved_mass_g[index] / nitrogen_molar_mass_g_per_mol / water;
    }
}

/// Removes restart-stale transient litter NH3 without touching gaseous NH3.
pub fn clearTransient(gas_state: *gas.State) !void {
    try gas_state.validateShape();
    for (0..gas_state.cell_count) |cell| {
        const index = cell * gas.species_count + @intFromEnum(gas.Species.ammonia);
        gas_state.dissolved_mass_g[index] = 0;
        gas_state.macropore_dissolved_mass_g[index] = 0;
        gas_state.band_dissolved_mass_g[index] = 0;
    }
}

fn validateDimensions(
    chemistry_state: *const chemistry.State,
    gas_state: *const gas.State,
    litter_water_m3: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
) !void {
    if (!std.math.isFinite(nitrogen_molar_mass_g_per_mol) or nitrogen_molar_mass_g_per_mol <= 0)
        return error.InvalidNitrogenMolarMass;
    if (chemistry_state.cells.len == 0 or
        chemistry_state.dry_reference_water_m3.len != chemistry_state.cells.len or
        gas_state.cell_count != chemistry_state.cells.len or
        litter_water_m3.len != chemistry_state.cells.len)
        return error.LitterAmmoniaPhaseBridgeDimensionMismatch;
    try gas_state.validateShape();
    for (litter_water_m3, chemistry_state.dry_reference_water_m3) |water, dry_reference| {
        if (!std.math.isFinite(water) or water < 0 or
            !std.math.isFinite(dry_reference) or dry_reference < 0)
            return error.InvalidLitterAmmoniaWaterCarrier;
    }
}

test "litter chemistry ammonia is sole aqueous owner and transient round trip is exact" {
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 2);
    defer chemistry_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 2;
    chemistry_state.cells[1].ammonia_mol_per_m3 = 5;
    try refreshTransientFromChemistry(&chemistry_state, &gas_state, &.{ 3, 4 }, 14.01);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    try std.testing.expectApproxEqAbs(@as(f64, 84.06), gas_state.dissolved_mass_g[ammonia], 1e-13);
    gas_state.dissolved_mass_g[ammonia] -= 14.01;
    gas_state.dissolved_mass_g[gas.species_count + ammonia] += 14.01;
    try publishTransientToChemistry(&chemistry_state, &gas_state, &.{ 3, 4 }, 14.01, 1e-12, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0 / 3.0), chemistry_state.cells[0].ammonia_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 5.25), chemistry_state.cells[1].ammonia_mol_per_m3, 1e-14);
}

test "dry retained ammonia remains chemistry owned and never enters gas mirror" {
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 4;
    chemistry_state.dry_reference_water_m3[0] = 2;
    try refreshTransientFromChemistry(&chemistry_state, &gas_state, &.{0}, 14);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    try std.testing.expectEqual(@as(f64, 0), gas_state.dissolved_mass_g[ammonia]);
    try publishTransientToChemistry(&chemistry_state, &gas_state, &.{0}, 14, 1e-12, 1e-9);
    try std.testing.expectEqual(@as(f64, 4), chemistry_state.cells[0].ammonia_mol_per_m3);
}

test "invalid later transient leaves all litter chemistry owners unchanged" {
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 2);
    defer chemistry_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 2;
    chemistry_state.cells[1].ammonia_mol_per_m3 = 5;
    try refreshTransientFromChemistry(&chemistry_state, &gas_state, &.{ 1, 1 }, 14);
    gas_state.dissolved_mass_g[gas.species_count + @intFromEnum(gas.Species.ammonia)] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidTransientLitterAmmoniaInventory, publishTransientToChemistry(&chemistry_state, &gas_state, &.{ 1, 1 }, 14, 1e-12, 1e-9));
    try std.testing.expectEqual(@as(f64, 2), chemistry_state.cells[0].ammonia_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 5), chemistry_state.cells[1].ammonia_mol_per_m3);
}
