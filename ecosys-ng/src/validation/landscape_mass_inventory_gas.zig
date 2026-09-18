//! `landscape_mass_inventory` declarations: gas.
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
const group_misc = @import("landscape_mass_inventory_misc.zig");
const group_support = @import("landscape_mass_inventory_support.zig");
const ice_units = @import("../core/ice_units.zig");

/// REDIST profile physical and gas inventory. The current grid stores ice in
/// water-equivalent m3 already, so volumes are not density-scaled again; the
/// F77 physical-ice heat-capacity coefficient is converted to a WE coefficient.
/// Root gas pools are intentionally not accepted here: their authoritative
/// owner is aggregated separately before the final EXEC reduction.
pub fn aggregateSoilPhysicalAndGas(
    grid: *const grid_module.GridState,
    dry_solid_heat_capacity_megajoules_per_m3_k: []const f64,
    layer_volume_m3: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    gas_state: *const gas.State,
) !group_support.Storage {
    return aggregateSoilPhysicalAndGasRange(
        grid,
        dry_solid_heat_capacity_megajoules_per_m3_k,
        layer_volume_m3,
        liquid_water_heat_capacity_megajoules_per_m3_k,
        ice_heat_capacity_megajoules_per_m3_k,
        ice_density_megagrams_per_m3,
        latent_heat_of_fusion_megajoules_per_m3,
        pure_water_melting_temperature_k,
        gas_state,
        0,
        grid.cell_count,
        true,
        null,
    );
}

pub fn aggregateSoilPhysicalAndGasCell(
    grid: *const grid_module.GridState,
    dry_solid_heat_capacity_megajoules_per_m3_k: []const f64,
    layer_volume_m3: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    gas_state: *const gas.State,
    cell: usize,
) !group_support.Storage {
    if (cell >= grid.cell_count) return error.SoilInventoryCellOutOfBounds;
    return aggregateSoilPhysicalAndGasRange(
        grid,
        dry_solid_heat_capacity_megajoules_per_m3_k,
        layer_volume_m3,
        liquid_water_heat_capacity_megajoules_per_m3_k,
        ice_heat_capacity_megajoules_per_m3_k,
        ice_density_megagrams_per_m3,
        latent_heat_of_fusion_megajoules_per_m3,
        pure_water_melting_temperature_k,
        gas_state,
        cell,
        cell + 1,
        false,
        null,
    );
}

/// Authoritative physical/gas inventory for one local soil-layer scope. An
/// inactive layer returns zero, exactly matching the whole-cell census.
pub fn aggregateSoilPhysicalAndGasLayer(
    grid: *const grid_module.GridState,
    dry_solid_heat_capacity_megajoules_per_m3_k: []const f64,
    layer_volume_m3: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    gas_state: *const gas.State,
    cell: usize,
    layer: usize,
) !group_support.Storage {
    if (cell >= grid.cell_count or layer >= grid.soil_layer_capacity)
        return error.SoilInventoryCellOutOfBounds;
    return aggregateSoilPhysicalAndGasRange(
        grid,
        dry_solid_heat_capacity_megajoules_per_m3_k,
        layer_volume_m3,
        liquid_water_heat_capacity_megajoules_per_m3_k,
        ice_heat_capacity_megajoules_per_m3_k,
        ice_density_megagrams_per_m3,
        latent_heat_of_fusion_megajoules_per_m3,
        pure_water_melting_temperature_k,
        gas_state,
        cell,
        cell + 1,
        false,
        layer,
    );
}

fn aggregateSoilPhysicalAndGasRange(
    grid: *const grid_module.GridState,
    dry_solid_heat_capacity_megajoules_per_m3_k: []const f64,
    layer_volume_m3: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    gas_state: *const gas.State,
    first_cell: usize,
    end_cell: usize,
    publish_diagnostics: bool,
    local_layer_filter: ?usize,
) !group_support.Storage {
    if (grid.layer_count !=
        try std.math.mul(usize, grid.cell_count, grid.soil_layer_capacity) or
        grid.active_soil_layer_count.len != grid.cell_count or
        dry_solid_heat_capacity_megajoules_per_m3_k.len != grid.layer_count or
        layer_volume_m3.len != grid.layer_count or
        gas_state.cell_count != grid.layer_count)
        return error.SoilInventoryDimensionMismatch;
    inline for (.{ liquid_water_heat_capacity_megajoules_per_m3_k, ice_heat_capacity_megajoules_per_m3_k }) |value|
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidSoilInventoryHeatCapacity;
    const ice_heat_capacity_per_water_equivalent_m3_k =
        ice_units.heatCapacityPerWaterEquivalentM3K(
            ice_heat_capacity_megajoules_per_m3_k,
            ice_density_megagrams_per_m3,
        ) catch return error.InvalidSoilInventoryHeatCapacity;
    if (!std.math.isFinite(latent_heat_of_fusion_megajoules_per_m3) or
        latent_heat_of_fusion_megajoules_per_m3 <= 0)
        return error.InvalidLatentHeatOfFusion;
    if (!std.math.isFinite(pure_water_melting_temperature_k) or
        pure_water_melting_temperature_k <= 0)
        return error.InvalidSoilMeltingTemperature;
    inline for (.{
        grid.matrix_liquid_water_m3.len,
        grid.macropore_liquid_water_m3.len,
        grid.matrix_ice_water_m3.len,
        grid.macropore_ice_water_m3.len,
        grid.water_vapor_volume_m3.len,
        grid.soil_temperature_k.len,
    }) |length| if (length != grid.layer_count)
        return error.SoilInventoryDimensionMismatch;

    var result: group_support.Storage = .{};
    if (publish_diagnostics) {
        group_misc.diagnostic_soil_matrix_ice_water_equivalent_m3 = 0;
        group_misc.diagnostic_soil_macropore_ice_water_equivalent_m3 = 0;
        group_misc.diagnostic_soil_vapor_water_equivalent_m3 = 0;
        group_misc.diagnostic_soil_dry_solid_extensive_heat_capacity = 0;
    }
    for (first_cell..end_cell) |cell| {
        const active_layers = grid.active_soil_layer_count[cell];
        if (active_layers > grid.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        const first_layer = if (local_layer_filter) |layer| @min(layer, active_layers) else 0;
        const end_layer = if (local_layer_filter) |layer| @min(layer + 1, active_layers) else active_layers;
        for (first_layer..end_layer) |layer| {
            const index = cell * grid.soil_layer_capacity + layer;
            const matrix_liquid = grid.matrix_liquid_water_m3[index];
            const macropore_liquid = grid.macropore_liquid_water_m3[index];
            const matrix_ice_water_equivalent = grid.matrix_ice_water_m3[index];
            const macropore_ice_water_equivalent = grid.macropore_ice_water_m3[index];
            const vapor_water_equivalent = grid.water_vapor_volume_m3[index];
            const temperature = grid.soil_temperature_k[index];
            const dry_solid_heat_capacity = dry_solid_heat_capacity_megajoules_per_m3_k[index];
            const volume = layer_volume_m3[index];
            inline for (.{
                matrix_liquid,
                macropore_liquid,
                matrix_ice_water_equivalent,
                macropore_ice_water_equivalent,
                vapor_water_equivalent,
                temperature,
                dry_solid_heat_capacity,
                volume,
            }) |value| {
                if (!std.math.isFinite(value)) return error.NonFiniteSoilInventory;
                if (value < 0) return error.NegativeSoilInventory;
            }
            result.water_m3 +=
                matrix_liquid +
                macropore_liquid +
                matrix_ice_water_equivalent +
                macropore_ice_water_equivalent +
                vapor_water_equivalent;
            // Reconstruct from authoritative live carriers. Using the cached
            // soil-thermal total here made EXEC heat storage depend on whether
            // its derived table had been refreshed after water and phase
            // transactions.
            // HEAT-001 resolution A: enthalpy, not sensible heat, with the
            // reference state liquid water at 0 K.
            //
            // Frozen water does NOT sit exactly one latent heat below liquid
            // water at the same temperature. Following the liquid branch up to
            // the melting point and the ice branch back down gives
            // `C_l*Tm - L + C_i*(T - Tm)` per cubic metre. The earlier form
            // `C_i*T - L` omitted `(C_l - C_i_WE)*Tm`; using the physical
            // coefficient here additionally mismatched the WE storage
            // carrier. Freeze/thaw therefore did not cancel in the census:
            // it leaked that reference offset per cubic metre converted.
            //
            // The sensible term below therefore carries only the *liquid*
            // carriers, and each frozen carrier carries its whole enthalpy.
            // Written this way the census agrees term for term with
            // `soil_enthalpy_balance.stateAtTemperature`, which is the function
            // the soil solver actually conserves.
            const frozen_water_equivalent_m3 =
                matrix_ice_water_equivalent + macropore_ice_water_equivalent;
            const liquid_extensive_heat_capacity_megajoules_per_k =
                dry_solid_heat_capacity * volume +
                liquid_water_heat_capacity_megajoules_per_m3_k *
                    (matrix_liquid + macropore_liquid + vapor_water_equivalent);
            if (publish_diagnostics)
                group_misc.diagnostic_soil_dry_solid_extensive_heat_capacity += dry_solid_heat_capacity * volume;
            result.heat_megajoules +=
                liquid_extensive_heat_capacity_megajoules_per_k * temperature +
                try group_support.frozenWaterEnthalpyPerM3(
                    temperature,
                    liquid_water_heat_capacity_megajoules_per_m3_k,
                    ice_heat_capacity_per_water_equivalent_m3_k,
                    latent_heat_of_fusion_megajoules_per_m3,
                    pure_water_melting_temperature_k,
                ) * frozen_water_equivalent_m3;
            if (publish_diagnostics) {
                group_misc.diagnostic_soil_matrix_ice_water_equivalent_m3 += matrix_ice_water_equivalent;
                group_misc.diagnostic_soil_vapor_water_equivalent_m3 += vapor_water_equivalent;
                group_misc.diagnostic_soil_macropore_ice_water_equivalent_m3 += macropore_ice_water_equivalent;
            }

            const first = index * gas.species_count;
            const end = first + gas.species_count;
            const gaseous = gas_state.gaseous_mass_g[first..end];
            const dissolved = gas_state.dissolved_mass_g[first..end];
            const macropore = gas_state.macropore_dissolved_mass_g[first..end];
            const band = gas_state.band_dissolved_mass_g[first..end];
            inline for (0..gas.species_count) |species_index| {
                inline for (.{
                    gaseous[species_index],
                    dissolved[species_index],
                    macropore[species_index],
                    band[species_index],
                }) |value| {
                    if (!std.math.isFinite(value)) return error.NonFiniteSoilInventory;
                    if (value < 0) return error.NegativeSoilInventory;
                }
            }
            const carbon_g =
                group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .carbon_dioxide) +
                group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .methane);
            result.carbon_dioxide_carbon_g += carbon_g;
            result.diagnostic_soil_gas_carbon_g += carbon_g;
            result.oxygen_g +=
                group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .oxygen);
            result.hydrogen_g +=
                group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .hydrogen);
            result.dinitrogen_nitrogen_g +=
                group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .nitrogen) +
                group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .nitrous_oxide);
            // ZNH3S/ZNH3B/ZNH3SH/ZNH3BH are inventoried once by the
            // mineral-N owner. Gas aqueous slots are transient solver mirrors;
            // only ZNH3G is an authoritative gas inventory.
            result.ammonium_nitrogen_g += gaseous[@intFromEnum(gas.Species.ammonia)];
        }
    }
    result.diagnostic_soil_heat_megajoules = result.heat_megajoules;
    try result.validate();
    return result;
}

/// REDIST `TLCO2P/TLOXYP/TLCH4P/TLN2OP/TLNH3P`: gaseous and aqueous
/// root/mycorrhizal gas storage. Root carbon biomass is a plant owner, but gas
/// already produced into these pools is part of the EXEC soil-system census.
pub fn aggregateRootGas(state: *const plant_roots.State) !group_support.Storage {
    return aggregateRootGasRange(state, 0, state.plant_count, null);
}

pub fn aggregateRootGasCell(
    state: *const plant_roots.State,
    plant_populations_per_cell: usize,
    cell: usize,
) !group_support.Storage {
    if (plant_populations_per_cell == 0) return error.RootGasInventoryDimensionMismatch;
    const first_plant = try std.math.mul(usize, cell, plant_populations_per_cell);
    const end_plant = try std.math.add(usize, first_plant, plant_populations_per_cell);
    if (end_plant > state.plant_count) return error.RootGasInventoryCellOutOfBounds;
    return aggregateRootGasRange(state, first_plant, end_plant, null);
}

pub fn aggregateRootGasLayer(
    state: *const plant_roots.State,
    plant_populations_per_cell: usize,
    cell: usize,
    layer: usize,
) !group_support.Storage {
    if (plant_populations_per_cell == 0 or layer >= state.soil_layer_count)
        return error.RootGasInventoryDimensionMismatch;
    const first_plant = try std.math.mul(usize, cell, plant_populations_per_cell);
    const end_plant = try std.math.add(usize, first_plant, plant_populations_per_cell);
    if (end_plant > state.plant_count) return error.RootGasInventoryCellOutOfBounds;
    return aggregateRootGasRange(state, first_plant, end_plant, layer);
}

fn aggregateRootGasRange(
    state: *const plant_roots.State,
    first_plant: usize,
    end_plant: usize,
    local_layer_filter: ?usize,
) !group_support.Storage {
    const expected = try group_support.product(&.{
        state.plant_count,
        plant_roots.biological_domain_count,
        state.soil_layer_count,
    });
    if (expected == 0 or
        state.gaseous_carbon_dioxide_g_c.len != expected or
        state.aqueous_carbon_dioxide_g_c.len != expected or
        state.gaseous_oxygen_g_o.len != expected or
        state.aqueous_oxygen_g_o.len != expected or
        state.gaseous_methane_g_c.len != expected or
        state.aqueous_methane_g_c.len != expected or
        state.gaseous_nitrous_oxide_g_n.len != expected or
        state.aqueous_nitrous_oxide_g_n.len != expected or
        state.gaseous_ammonia_g_n.len != expected or
        state.aqueous_ammonia_g_n.len != expected)
        return error.RootGasInventoryDimensionMismatch;
    if (state.gaseous_hydrogen_g_h.len != expected or
        state.aqueous_hydrogen_g_h.len != expected)
        return error.RootGasInventoryDimensionMismatch;

    var result: group_support.Storage = .{};
    for (first_plant..end_plant) |plant| {
        for (0..plant_roots.biological_domain_count) |domain| {
            const first_layer = local_layer_filter orelse 0;
            const end_layer = if (local_layer_filter) |layer| layer + 1 else state.soil_layer_count;
            for (first_layer..end_layer) |layer| {
                const index = try state.layerIndex(plant, domain, layer);
                inline for (.{
                    state.gaseous_carbon_dioxide_g_c[index],
                    state.aqueous_carbon_dioxide_g_c[index],
                    state.gaseous_oxygen_g_o[index],
                    state.aqueous_oxygen_g_o[index],
                    state.gaseous_methane_g_c[index],
                    state.aqueous_methane_g_c[index],
                    state.gaseous_nitrous_oxide_g_n[index],
                    state.aqueous_nitrous_oxide_g_n[index],
                    state.gaseous_ammonia_g_n[index],
                    state.aqueous_ammonia_g_n[index],
                    state.gaseous_hydrogen_g_h[index],
                    state.aqueous_hydrogen_g_h[index],
                }) |value| if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidRootGasInventory;
                result.carbon_dioxide_carbon_g +=
                    state.gaseous_carbon_dioxide_g_c[index] +
                    state.aqueous_carbon_dioxide_g_c[index] +
                    state.gaseous_methane_g_c[index] +
                    state.aqueous_methane_g_c[index];
                result.oxygen_g += state.gaseous_oxygen_g_o[index] +
                    state.aqueous_oxygen_g_o[index];
                result.hydrogen_g += state.gaseous_hydrogen_g_h[index] +
                    state.aqueous_hydrogen_g_h[index];
                result.dinitrogen_nitrogen_g +=
                    state.gaseous_nitrous_oxide_g_n[index] +
                    state.aqueous_nitrous_oxide_g_n[index];
                result.ammonium_nitrogen_g += state.gaseous_ammonia_g_n[index] +
                    state.aqueous_ammonia_g_n[index];
            }
        }
    }
    try result.validate();
    return result;
}

test "root gas layer partition equals authoritative whole root census" {
    var roots = try plant_roots.State.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    roots.gaseous_oxygen_g_o[try roots.layerIndex(0, 0, 0)] = 2;
    roots.gaseous_oxygen_g_o[try roots.layerIndex(0, 0, 1)] = 3;
    const all = try aggregateRootGas(&roots);
    var partition: group_support.Storage = .{};
    try partition.add(try aggregateRootGasLayer(&roots, 1, 0, 0));
    try partition.add(try aggregateRootGasLayer(&roots, 1, 0, 1));
    try std.testing.expectEqualDeep(all, partition);
}
