//! `landscape_mass_inventory` declarations: canopy.
//!
//! Split out of `landscape_mass_inventory.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const grid_module = @import("../state/grid.zig");
const gas = @import("../soil/gas/transport.zig");
const organic = @import("../soil/organic/initialization.zig");
const organic_transport = @import("../soil/organic/transport.zig");
const litter_chemistry = @import("../surface/litter_chemistry.zig");
const litter_fertilizer = @import("../surface/litter_fertilizer.zig");
const audit = @import("mass_balance_audit.zig");
const surface_precipitation = @import("../surface/precipitation.zig");
const canopy_retention = @import("../canopy/energy/precipitation_retention.zig");
const mineral_nitrogen = @import("../soil/biogeochemistry/mineral_nitrogen_transport.zig");
const nitrogen_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
const mineral_fertilizer = @import("../management/mineral_fertilizer_inventory.zig");
const soil_chemistry = @import("../soil/solute/chemistry_state.zig");
const solute_transport = @import("../soil/solute/transport.zig");
const solute_species = @import("../soil/solute/transport_species.zig");
const zone_classification = @import("../soil/solute/charge_classification.zig");
const plant_roots = @import("../plant/root/plant_root_system.zig");
const group_support = @import("landscape_mass_inventory_support.zig");

/// EXTRACT/REDIST `TVOLWP + TVOLWC` and `TENGYC`. Internal canopy water is
/// stored as depth per cell area and belongs to water storage. Heat follows
/// EXTRACT 643–649 exactly: `ENGYX` inventories intercepted living/dead water,
/// not internal `VOLWP`. `previous_water_energy_megajoules` is that carrier
/// after the accepted canopy surface transaction.
pub fn aggregateCanopyWaterAndHeat(
    plants: *const grid_module.PlantState,
    retention: *const canopy_retention.State,
    cell_area_m2: []const f64,
) !group_support.Storage {
    return aggregateCanopyWaterAndHeatRange(plants, retention, cell_area_m2, 0, plants.cell_count);
}

pub fn aggregateCanopyWaterAndHeatCell(
    plants: *const grid_module.PlantState,
    retention: *const canopy_retention.State,
    cell_area_m2: []const f64,
    cell: usize,
) !group_support.Storage {
    if (cell >= plants.cell_count) return error.CanopyInventoryCellOutOfBounds;
    return aggregateCanopyWaterAndHeatRange(plants, retention, cell_area_m2, cell, cell + 1);
}

fn aggregateCanopyWaterAndHeatRange(
    plants: *const grid_module.PlantState,
    retention: *const canopy_retention.State,
    cell_area_m2: []const f64,
    first_cell: usize,
    end_cell: usize,
) !group_support.Storage {
    if (plants.cell_count == 0 or plants.species_count == 0 or
        retention.cell_count != plants.cell_count or
        retention.species_count != plants.species_count or
        cell_area_m2.len != plants.cell_count)
        return error.CanopyInventoryDimensionMismatch;
    const plant_count = try std.math.mul(
        usize,
        plants.cell_count,
        plants.species_count,
    );
    inline for (.{
        plants.canopy_water_storage_m_per_m2.len,
        retention.living_surface_water_m3.len,
        retention.standing_dead_surface_water_m3.len,
        retention.previous_water_energy_megajoules.len,
    }) |length| if (length != plant_count)
        return error.CanopyInventoryDimensionMismatch;

    var result: group_support.Storage = .{};
    for (first_cell..end_cell) |cell| {
        const area = cell_area_m2[cell];
        if (!std.math.isFinite(area) or area <= 0)
            return error.InvalidCanopyInventoryCellArea;
        for (0..plants.species_count) |species| {
            const plant = cell * plants.species_count + species;
            const internal_water_depth_m =
                plants.canopy_water_storage_m_per_m2[plant];
            const living_surface_water =
                retention.living_surface_water_m3[plant];
            const dead_surface_water =
                retention.standing_dead_surface_water_m3[plant];
            const water_energy = retention.previous_water_energy_megajoules[plant];
            inline for (.{
                internal_water_depth_m,
                living_surface_water,
                dead_surface_water,
                water_energy,
            }) |value| {
                if (!std.math.isFinite(value))
                    return error.NonFiniteCanopyInventory;
                if (value < 0) return error.NegativeCanopyInventory;
            }
            result.water_m3 +=
                internal_water_depth_m * area +
                living_surface_water +
                dead_surface_water;
            result.heat_megajoules += water_energy;
        }
    }
    result.diagnostic_canopy_heat_megajoules = result.heat_megajoules;
    try result.validate();
    return result;
}
