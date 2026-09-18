//! `litter_chemistry` declarations: activity.
//!
//! Split out of `litter_chemistry.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ledger = @import("litter_reaction_transformations.zig");
const activity_coefficients = @import("../soil/solute/activity_coefficients.zig");
const group_struct_arithmetic = @import("litter_chemistry_struct_arithmetic.zig");
const group_types = @import("litter_chemistry_types.zig");

/// HOUR1 charge classes for surface litter. Concentration state is converted
/// back to extensive mol before the shared Debye-Huckel calculation.
pub fn activityCoefficients(cell: group_types.Cell, litter_water_volume_m3: f64) !activity_coefficients.Result {
    if (!std.math.isFinite(litter_water_volume_m3) or litter_water_volume_m3 <= 0) return error.InvalidLitterWaterVolume;
    try group_struct_arithmetic.validateCell(cell);
    const water = litter_water_volume_m3;
    return activity_coefficients.calculate(.{
        .trivalent_cations_mol = (cell.aluminum_mol_per_m3 + cell.iron_mol_per_m3) * water,
        .trivalent_anions_mol = 0,
        .divalent_cations_mol = (cell.calcium_mol_per_m3 + cell.magnesium_mol_per_m3) * water,
        .divalent_anions_mol = (cell.sulfate_mol_per_m3 + cell.carbonate_mol_per_m3 + cell.hpo4_mol_p_per_m3) * water,
        .monovalent_cations_mol = (cell.ammonium_mol_per_m3 + cell.hydrogen_mol_per_m3 + cell.sodium_mol_per_m3 + cell.potassium_mol_per_m3) * water,
        .monovalent_anions_mol = (cell.hydroxide_mol_per_m3 + cell.nitrate_mol_per_m3 + cell.chloride_mol_per_m3 + cell.bicarbonate_mol_per_m3 + cell.h2po4_mol_p_per_m3) * water,
        .neutral_solutes_mol = (cell.ammonia_mol_per_m3 + cell.carbon_dioxide_mol_per_m3) * water,
    }, water);
}

pub fn hasMineralInventory(cell: group_types.Cell) bool {
    inline for (@typeInfo(@TypeOf(cell.phosphate_minerals)).@"struct".fields) |field|
        if (@field(cell.phosphate_minerals, field.name) != 0) return true;
    inline for (@typeInfo(@TypeOf(cell.salt_minerals)).@"struct".fields) |field|
        if (@field(cell.salt_minerals, field.name) != 0) return true;
    return false;
}

pub fn validateMinerals(cell: group_types.Cell) !void {
    inline for (@typeInfo(@TypeOf(cell.phosphate_minerals)).@"struct".fields) |field| {
        const value = @field(cell.phosphate_minerals, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterMineralInventory;
    }
    inline for (@typeInfo(@TypeOf(cell.salt_minerals)).@"struct".fields) |field| {
        const value = @field(cell.salt_minerals, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterMineralInventory;
    }
}

pub fn exchangeResidualsConvergedAtAqueousScale(
    cell: group_types.Cell,
    extents: ledger.ExchangeAdsorption,
    density_megagrams_per_m3: f64,
    options: group_types.Options,
) bool {
    inline for (@typeInfo(ledger.ExchangeAdsorption).@"struct".fields) |field| {
        const exchange_inventory = @field(cell.exchange, field.name);
        const exchange_scale = options.scaleMolPerMegagram(exchange_inventory);
        const aqueous_inventory = exchangeAqueousInventory(
            cell,
            field.name,
        );
        const aqueous_scale_per_megagram =
            options.scaleMolPerM3(aqueous_inventory) /
            density_megagrams_per_m3;
        if (@abs(@field(extents, field.name)) >
            @min(exchange_scale, aqueous_scale_per_megagram))
            return false;
    }
    return true;
}

fn exchangeAqueousInventory(cell: group_types.Cell, comptime field_name: []const u8) f64 {
    if (comptime std.mem.eql(u8, field_name, "ammonium_mol_per_megagram"))
        return cell.ammonium_mol_per_m3;
    if (comptime std.mem.eql(u8, field_name, "hydrogen_mol_per_megagram"))
        return cell.hydrogen_mol_per_m3;
    if (comptime std.mem.eql(u8, field_name, "aluminum_mol_per_megagram"))
        return cell.aluminum_mol_per_m3;
    if (comptime std.mem.eql(u8, field_name, "iron_mol_per_megagram"))
        return cell.iron_mol_per_m3;
    if (comptime std.mem.eql(u8, field_name, "calcium_mol_per_megagram"))
        return cell.calcium_mol_per_m3;
    if (comptime std.mem.eql(u8, field_name, "magnesium_mol_per_megagram"))
        return cell.magnesium_mol_per_m3;
    if (comptime std.mem.eql(u8, field_name, "sodium_mol_per_megagram"))
        return cell.sodium_mol_per_m3;
    if (comptime std.mem.eql(u8, field_name, "potassium_mol_per_megagram"))
        return cell.potassium_mol_per_m3;
    unreachable;
}
