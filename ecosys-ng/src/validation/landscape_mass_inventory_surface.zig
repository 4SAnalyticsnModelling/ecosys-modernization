//! `landscape_mass_inventory` declarations: surface.
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
const ice_units = @import("../core/ice_units.zig");
const surface_solute_routing = @import("../soil/solute/surface_solute_routing.zig");
const surface_aqueous = @import("../surface/aqueous_runoff_transport.zig");
const daily_litter_salt = @import("../redistribution/inventory/daily_litter_salt.zig");
const fire_exchange = @import("../soil/biogeochemistry/organic_matter_fire_exchange.zig");

pub var diagnostic_surface_ice_water_equivalent_m3: f64 = 0;

/// HEAT-001 measurement instrumentation (temporary): see the soil-side sibling
/// `landscape_mass_inventory_misc.diagnostic_soil_vapor_water_equivalent_m3`.
pub var diagnostic_surface_vapor_water_equivalent_m3: f64 = 0;

/// Counts the extensive surface complexes that are not mirrored by the
/// litter chemistry owners. Coordinates 0..11 are already in
/// `aggregateSurfaceChemistry`, 34/35 uniquely own PO4/H3PO4, and 42..49 are
/// soil-only band coordinates. Surface mineral transport separately owns
/// HPO4/H2PO4 and therefore does not duplicate 34/35.
pub fn aggregateSurfaceTransportComplexes(
    state: *const surface_solute_routing.State,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !group_support.Storage {
    return aggregateSurfaceTransportComplexesRange(
        state,
        carbon_g_per_mol,
        phosphorus_g_per_mol,
        0,
        state.carrier_volume_m3.len,
    );
}

/// Persistent dry-surface products awaiting dissolution are scientific
/// storage, not diagnostics. Shoot fire is deliberately evaluated after the
/// main surface finalizer, so omitting these owners loses current-hour N, P,
/// and all eight salt elements until the next wet-hour finalization.
pub fn aggregatePendingSurfaceFire(
    state: *const fire_exchange.State,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !group_support.Storage {
    return aggregatePendingSurfaceFireRange(state, nitrogen_g_per_mol, phosphorus_g_per_mol, 0, state.layer_count);
}

pub fn aggregatePendingSurfaceFireCell(
    state: *const fire_exchange.State,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    cell: usize,
) !group_support.Storage {
    if (cell >= state.layer_count) return error.PendingSurfaceFireCellOutOfBounds;
    return aggregatePendingSurfaceFireRange(state, nitrogen_g_per_mol, phosphorus_g_per_mol, cell, cell + 1);
}

fn aggregatePendingSurfaceFireRange(
    state: *const fire_exchange.State,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    first_cell: usize,
    end_cell: usize,
) !group_support.Storage {
    if (state.layer_count == 0 or first_cell > end_cell or end_cell > state.layer_count or
        state.pending_surface_ammonium_mol_n.len != state.layer_count or
        state.pending_surface_phosphate_mol_p.len != state.layer_count or
        state.pending_surface_salt_mol.len != state.layer_count * fire_exchange.salt_species_count or
        !std.math.isFinite(nitrogen_g_per_mol) or nitrogen_g_per_mol <= 0 or
        !std.math.isFinite(phosphorus_g_per_mol) or phosphorus_g_per_mol <= 0)
        return error.PendingSurfaceFireInventoryDimensionMismatch;
    var result: group_support.Storage = .{};
    for (first_cell..end_cell) |cell| {
        const ammonium = state.pending_surface_ammonium_mol_n[cell];
        const phosphate = state.pending_surface_phosphate_mol_p[cell];
        if (!std.math.isFinite(ammonium) or ammonium < 0 or
            !std.math.isFinite(phosphate) or phosphate < 0)
            return error.InvalidPendingSurfaceFireInventory;
        result.ammonium_nitrogen_g += ammonium * nitrogen_g_per_mol;
        result.phosphate_phosphorus_g += phosphate * phosphorus_g_per_mol;
        result.ion_inventory_mol += 2 * ammonium + 3 * phosphate;
        const first = cell * fire_exchange.salt_species_count;
        inline for (.{
            &result.aluminum_mol,
            &result.iron_mol,
            &result.calcium_mol,
            &result.magnesium_mol,
            &result.sodium_mol,
            &result.potassium_mol,
            &result.sulfur_mol,
            &result.chloride_mol,
        }, 0..) |destination, salt| {
            const amount = state.pending_surface_salt_mol[first + salt];
            if (!std.math.isFinite(amount) or amount < 0)
                return error.InvalidPendingSurfaceFireInventory;
            destination.* += amount;
            result.ion_inventory_mol += amount;
        }
    }
    try result.validate();
    return result;
}

pub fn aggregateSurfaceTransportComplexesCell(
    state: *const surface_solute_routing.State,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    cell: usize,
) !group_support.Storage {
    if (cell >= state.carrier_volume_m3.len)
        return error.SurfaceTransportInventoryCellOutOfBounds;
    return aggregateSurfaceTransportComplexesRange(
        state,
        carbon_g_per_mol,
        phosphorus_g_per_mol,
        cell,
        cell + 1,
    );
}

fn aggregateSurfaceTransportComplexesRange(
    state: *const surface_solute_routing.State,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    first_cell: usize,
    end_cell: usize,
) !group_support.Storage {
    const cells = std.math.mul(usize, state.columns, state.rows) catch
        return error.SurfaceTransportInventoryDimensionOverflow;
    const amount_count = std.math.mul(usize, cells, state.species_count) catch
        return error.SurfaceTransportInventoryDimensionOverflow;
    if (cells == 0 or state.carrier_volume_m3.len != cells or
        state.species_count != surface_aqueous.species_count or
        state.amount_mol.len != amount_count or
        first_cell > end_cell or end_cell > cells)
        return error.SurfaceTransportInventoryDimensionMismatch;
    inline for (.{ carbon_g_per_mol, phosphorus_g_per_mol }) |molar_mass|
        if (!std.math.isFinite(molar_mass) or molar_mass <= 0)
            return error.InvalidInventoryMolarMass;

    var result: group_support.Storage = .{};
    for (first_cell..end_cell) |cell| {
        for (12..42) |species_index| {
            const amount_mol = state.amount_mol[cell * state.species_count + species_index];
            if (!std.math.isFinite(amount_mol) or amount_mol < 0)
                return error.InvalidSurfaceTransportInventory;
            const species: surface_aqueous.Species = @enumFromInt(species_index);
            const formula = surface_aqueous.formula(species);
            result.carbon_dioxide_carbon_g +=
                amount_mol * formula.carbon_mol * carbon_g_per_mol;
            result.phosphate_phosphorus_g +=
                amount_mol * formula.phosphorus_mol * phosphorus_g_per_mol;
            try group_support.addElementMoles(&result, .{
                .aluminum = amount_mol * formula.aluminum_mol,
                .iron = amount_mol * formula.iron_mol,
                .calcium = amount_mol * formula.calcium_mol,
                .magnesium = amount_mol * formula.magnesium_mol,
                .sodium = amount_mol * formula.sodium_mol,
                .potassium = amount_mol * formula.potassium_mol,
                .sulfur = amount_mol * formula.sulfur_mol,
                .chloride = amount_mol * formula.chloride_mol,
                .silicon = amount_mol * formula.silicon_mol,
            });
            result.ion_inventory_mol += amount_mol *
                try daily_litter_salt.aqueousIonCount(species);
        }
    }
    try result.validate();
    return result;
}

/// REDIST surface mineral N/P and `SST=SSS+SSF+SSX+SSP` inventory expressed
/// through the modern free-ion, exchange-site, fertilizer, and mineral owners.
/// Concentrations are made extensive with litter water; exchange values use
/// dry litter mass. Molecular coefficients retain the source's atom-count
/// convention for TION rather than charge equivalents.
pub fn aggregateSurfaceChemistry(
    chemistry: *const litter_chemistry.State,
    fertilizer: *const litter_fertilizer.State,
    denitrification_nitrite_g_n: []const f64,
    litter_water_m3: []const f64,
    litter_dry_mass_megagrams: []const f64,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !group_support.Storage {
    return aggregateSurfaceChemistryRange(
        chemistry,
        fertilizer,
        denitrification_nitrite_g_n,
        litter_water_m3,
        litter_dry_mass_megagrams,
        carbon_g_per_mol,
        nitrogen_g_per_mol,
        phosphorus_g_per_mol,
        0,
        chemistry.cells.len,
    );
}

pub fn aggregateSurfaceChemistryCell(
    chemistry: *const litter_chemistry.State,
    fertilizer: *const litter_fertilizer.State,
    denitrification_nitrite_g_n: []const f64,
    litter_water_m3: []const f64,
    litter_dry_mass_megagrams: []const f64,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    cell: usize,
) !group_support.Storage {
    if (cell >= chemistry.cells.len) return error.SurfaceChemistryInventoryCellOutOfBounds;
    return aggregateSurfaceChemistryRange(
        chemistry,
        fertilizer,
        denitrification_nitrite_g_n,
        litter_water_m3,
        litter_dry_mass_megagrams,
        carbon_g_per_mol,
        nitrogen_g_per_mol,
        phosphorus_g_per_mol,
        cell,
        cell + 1,
    );
}

fn aggregateSurfaceChemistryRange(
    chemistry: *const litter_chemistry.State,
    fertilizer: *const litter_fertilizer.State,
    denitrification_nitrite_g_n: []const f64,
    litter_water_m3: []const f64,
    litter_dry_mass_megagrams: []const f64,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    first_cell: usize,
    end_cell: usize,
) !group_support.Storage {
    const cells = chemistry.cells.len;
    if (cells == 0 or chemistry.mineral_reference_water_m3.len != cells or
        chemistry.dry_reference_water_m3.len != cells or fertilizer.cells.len != cells or
        fertilizer.formulation.len != cells or litter_water_m3.len != cells or
        litter_dry_mass_megagrams.len != cells or
        denitrification_nitrite_g_n.len != cells)
        return error.SurfaceChemistryInventoryDimensionMismatch;
    inline for (.{ carbon_g_per_mol, nitrogen_g_per_mol, phosphorus_g_per_mol }) |molar_mass|
        if (!std.math.isFinite(molar_mass) or molar_mass <= 0)
            return error.InvalidInventoryMolarMass;

    var result: group_support.Storage = .{};
    for (first_cell..end_cell) |cell_index| {
        const water = litter_water_m3[cell_index];
        const dry_reference_water = chemistry.dry_reference_water_m3[cell_index];
        const mineral_reference_water = chemistry.mineral_reference_water_m3[cell_index];
        const dry_mass = litter_dry_mass_megagrams[cell_index];
        const nitrite_g_n = denitrification_nitrite_g_n[cell_index];
        if (!std.math.isFinite(water) or !std.math.isFinite(dry_reference_water) or
            !std.math.isFinite(mineral_reference_water) or !std.math.isFinite(dry_mass))
            return error.NonFiniteSurfaceChemistryInventory;
        if (!std.math.isFinite(nitrite_g_n))
            return error.NonFiniteSurfaceChemistryInventory;
        if (water < 0 or dry_reference_water < 0 or mineral_reference_water < 0 or dry_mass < 0 or nitrite_g_n < 0)
            return error.NegativeSurfaceChemistryInventory;
        const aqueous_carrier = if (water > 0) water else dry_reference_water;
        const cell = chemistry.cells[cell_index];
        try group_support.validateNumericStruct(cell);
        const solid_fertilizer = fertilizer.cells[cell_index];
        inline for (std.meta.fields(litter_fertilizer.Inventory)) |field| {
            const value = @field(solid_fertilizer, field.name);
            if (!std.math.isFinite(value))
                return error.NonFiniteSurfaceChemistryInventory;
            if (value < 0) return error.NegativeSurfaceChemistryInventory;
        }

        result.ammonium_nitrogen_g += nitrogen_g_per_mol * (aqueous_carrier * (cell.ammonium_mol_per_m3 + cell.ammonia_mol_per_m3) +
            dry_mass * cell.exchange.ammonium_mol_per_megagram +
            solid_fertilizer.ammonium_mol_n +
            solid_fertilizer.ammonia_mol_n +
            solid_fertilizer.urea_mol_n);
        result.nitrate_nitrogen_g += nitrogen_g_per_mol * (aqueous_carrier * cell.nitrate_mol_per_m3 +
            solid_fertilizer.nitrate_mol_n) + nitrite_g_n;
        result.carbon_dioxide_carbon_g += carbon_g_per_mol *
            (aqueous_carrier * (cell.carbonate_mol_per_m3 + cell.bicarbonate_mol_per_m3) +
                mineral_reference_water * cell.salt_minerals.calcite_mol_per_m3);
        result.phosphate_phosphorus_g += phosphorus_g_per_mol * (aqueous_carrier * (cell.hpo4_mol_p_per_m3 +
            cell.h2po4_mol_p_per_m3) + mineral_reference_water * (cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 +
            cell.phosphate_minerals.iron_phosphate_mol_per_m3 +
            cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3 +
            2 * cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3 +
            3 * cell.phosphate_minerals.hydroxyapatite_mol_per_m3) +
            dry_mass * (cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram +
                cell.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram));

        const dissolved_ion_atoms_mol_per_m3 =
            cell.aluminum_mol_per_m3 +
            cell.iron_mol_per_m3 +
            cell.hydrogen_mol_per_m3 +
            cell.calcium_mol_per_m3 +
            cell.magnesium_mol_per_m3 +
            cell.sodium_mol_per_m3 +
            cell.potassium_mol_per_m3 +
            cell.hydroxide_mol_per_m3 +
            cell.sulfate_mol_per_m3 +
            cell.chloride_mol_per_m3 +
            cell.carbonate_mol_per_m3 +
            2 * cell.bicarbonate_mol_per_m3 +
            2 * cell.hpo4_mol_p_per_m3 +
            3 * cell.h2po4_mol_p_per_m3;
        const exchange_ion_atoms_mol_per_megagram =
            cell.exchange.hydrogen_mol_per_megagram +
            cell.exchange.aluminum_mol_per_megagram +
            cell.exchange.iron_mol_per_megagram +
            cell.exchange.calcium_mol_per_megagram +
            cell.exchange.magnesium_mol_per_megagram +
            cell.exchange.sodium_mol_per_megagram +
            cell.exchange.potassium_mol_per_megagram +
            cell.carboxyl_hydrogen_mol_per_megagram +
            2 * cell.exchange.ammonium_mol_per_megagram +
            cell.phosphate_surface.deprotonated_site_mol_per_megagram +
            2 * cell.phosphate_surface.hydroxyl_site_mol_per_megagram +
            // Literal REDIST SSX counts XOH2 twice.
            6 * cell.phosphate_surface.protonated_site_mol_per_megagram +
            3 * cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram +
            4 * cell.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram;
        const mineral_ion_atoms_mol_per_m3 =
            2 * (cell.salt_minerals.calcite_mol_per_m3 +
                cell.salt_minerals.gypsum_mol_per_m3 +
                cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 +
                cell.phosphate_minerals.iron_phosphate_mol_per_m3) +
            3 * cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3 +
            4 * (cell.salt_minerals.gibbsite_mol_per_m3 +
                cell.salt_minerals.iron_hydroxide_mol_per_m3) +
            7 * cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3 +
            9 * cell.phosphate_minerals.hydroxyapatite_mol_per_m3;
        const fertilizer_ion_atoms_mol =
            2 * solid_fertilizer.ammonium_mol_n +
            solid_fertilizer.ammonia_mol_n +
            solid_fertilizer.urea_mol_n +
            solid_fertilizer.nitrate_mol_n;
        result.ion_inventory_mol +=
            aqueous_carrier * dissolved_ion_atoms_mol_per_m3 +
            mineral_reference_water * mineral_ion_atoms_mol_per_m3 +
            dry_mass * exchange_ion_atoms_mol_per_megagram +
            fertilizer_ion_atoms_mol;
        try group_support.addElementMoles(&result, .{
            .aluminum = aqueous_carrier * cell.aluminum_mol_per_m3 +
                dry_mass * cell.exchange.aluminum_mol_per_megagram +
                mineral_reference_water *
                    (cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 +
                        cell.salt_minerals.gibbsite_mol_per_m3),
            .iron = aqueous_carrier * cell.iron_mol_per_m3 +
                dry_mass * cell.exchange.iron_mol_per_megagram +
                mineral_reference_water *
                    (cell.phosphate_minerals.iron_phosphate_mol_per_m3 +
                        cell.salt_minerals.iron_hydroxide_mol_per_m3),
            .calcium = aqueous_carrier * cell.calcium_mol_per_m3 +
                dry_mass * cell.exchange.calcium_mol_per_megagram +
                mineral_reference_water *
                    (cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3 +
                        5 * cell.phosphate_minerals.hydroxyapatite_mol_per_m3 +
                        cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3 +
                        cell.salt_minerals.calcite_mol_per_m3 +
                        cell.salt_minerals.gypsum_mol_per_m3),
            .magnesium = aqueous_carrier * cell.magnesium_mol_per_m3 +
                dry_mass * cell.exchange.magnesium_mol_per_megagram,
            .sodium = aqueous_carrier * cell.sodium_mol_per_m3 +
                dry_mass * cell.exchange.sodium_mol_per_megagram,
            .potassium = aqueous_carrier * cell.potassium_mol_per_m3 +
                dry_mass * cell.exchange.potassium_mol_per_megagram,
            .sulfur = aqueous_carrier * cell.sulfate_mol_per_m3 +
                mineral_reference_water * cell.salt_minerals.gypsum_mol_per_m3,
            .chloride = aqueous_carrier * cell.chloride_mol_per_m3,
        });
    }
    try result.validate();
    return result;
}

pub const SurfacePhysicalParameters = struct {
    dry_organic_heat_capacity_megajoules_per_g_c_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
    /// HEAT-001 resolution A. See
    /// `docs/binding_requests/heat_001_landscape_enthalpy.md`: the default is
    /// a temporary bridge because `src/ecosys_ng.zig` builds this struct and
    /// is owned by the Integrator lane. It equals the value every shipped
    /// runscript carries and must be deleted once the binding request lands.
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    water_molar_mass_g_per_mol: f64,
    liquid_water_density_g_per_m3: f64,
};

/// REDIST surface `WSS`, `TENGYC`, and litter gas inventory. The modern ice
/// carrier is explicitly water-equivalent m3, so it is added directly to
/// water storage. Water vapor is held as mol by the gas owner and converted
/// to its liquid-water-equivalent volume for both storage and heat capacity.
pub fn aggregateSurfacePhysicalAndGas(
    surface: *const surface_precipitation.RuntimeState,
    surface_ice_water_equivalent_m3: []const f64,
    grid: *const grid_module.GridState,
    gas_state: *const gas.State,
    surface_organic: *const organic.State,
    parameters: SurfacePhysicalParameters,
) !group_support.Storage {
    return aggregateSurfacePhysicalAndGasRange(
        surface,
        surface_ice_water_equivalent_m3,
        grid,
        gas_state,
        surface_organic,
        parameters,
        0,
        surface.cell_count,
        true,
    );
}

pub fn aggregateSurfacePhysicalAndGasCell(
    surface: *const surface_precipitation.RuntimeState,
    surface_ice_water_equivalent_m3: []const f64,
    grid: *const grid_module.GridState,
    gas_state: *const gas.State,
    surface_organic: *const organic.State,
    parameters: SurfacePhysicalParameters,
    cell: usize,
) !group_support.Storage {
    if (cell >= surface.cell_count) return error.SurfacePhysicalInventoryCellOutOfBounds;
    return aggregateSurfacePhysicalAndGasRange(
        surface,
        surface_ice_water_equivalent_m3,
        grid,
        gas_state,
        surface_organic,
        parameters,
        cell,
        cell + 1,
        false,
    );
}

fn aggregateSurfacePhysicalAndGasRange(
    surface: *const surface_precipitation.RuntimeState,
    surface_ice_water_equivalent_m3: []const f64,
    grid: *const grid_module.GridState,
    gas_state: *const gas.State,
    surface_organic: *const organic.State,
    parameters: SurfacePhysicalParameters,
    first_cell: usize,
    end_cell: usize,
    publish_diagnostics: bool,
) !group_support.Storage {
    const cells = surface.cell_count;
    if (cells == 0 or surface.litter_water_m3.len != cells or
        surface_ice_water_equivalent_m3.len != cells or
        grid.cell_count != cells or grid.surface_temperature_k.len != cells or
        gas_state.cell_count != cells or surface_organic.layer_count != cells)
        return error.SurfacePhysicalInventoryDimensionMismatch;
    inline for (std.meta.fields(SurfacePhysicalParameters)) |field| {
        const value = @field(parameters, field.name);
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidSurfacePhysicalInventoryParameter;
    }

    var result: group_support.Storage = .{};
    const ice_heat_capacity_per_water_equivalent_m3_k =
        ice_units.heatCapacityPerWaterEquivalentM3K(
            parameters.ice_heat_capacity_megajoules_per_m3_k,
            parameters.ice_density_megagrams_per_m3,
        ) catch return error.InvalidSurfacePhysicalInventoryParameter;
    if (publish_diagnostics) {
        diagnostic_surface_ice_water_equivalent_m3 = 0;
        diagnostic_surface_vapor_water_equivalent_m3 = 0;
    }
    for (first_cell..end_cell) |cell| {
        const liquid = surface.litter_water_m3[cell];
        const ice_water_equivalent = surface_ice_water_equivalent_m3[cell];
        const temperature = grid.surface_temperature_k[cell];
        const vapor_mol = gas_state.water_vapor_mol[cell];
        inline for (.{ liquid, ice_water_equivalent, temperature, vapor_mol }) |value| {
            if (!std.math.isFinite(value))
                return error.NonFiniteSurfacePhysicalInventory;
            if (value < 0) return error.NegativeSurfacePhysicalInventory;
        }
        if (temperature <= 0) return error.InvalidSurfaceTemperature;
        const vapor_water_equivalent_m3 =
            vapor_mol * parameters.water_molar_mass_g_per_mol /
            parameters.liquid_water_density_g_per_m3;
        const organic_carbon_g_c = try surface_organic.totalCarbon_g_c(cell);
        const liquid_heat_capacity_megajoules_per_k =
            parameters.dry_organic_heat_capacity_megajoules_per_g_c_k *
            organic_carbon_g_c +
            parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
                (liquid + vapor_water_equivalent_m3);
        result.water_m3 +=
            liquid + vapor_water_equivalent_m3 + ice_water_equivalent;
        // HEAT-001 resolution A. `surface_ice_water_equivalent_m3` is the one
        // authoritative carrier for both surface litter ice and pond ice, so a
        // single latent term covers both. Its latent contribution makes the
        // surface solver's freeze/thaw repartition internal to the census.
        //
        // HEAT-001 second layer: the frozen enthalpy is
        // `C_l*Tm - L + C_i*(T - Tm)`, not `C_i*T - L`. Same correction and
        // same reasoning as the soil carriers above; see
        // `group_support.frozenWaterEnthalpyPerM3`. Applying it to only some carriers would
        // make the pond_domain_transaction surface-to-soil ice transfer stop
        // cancelling, and that transfer is measured at `1.34e4 m3` on Ottawa
        // day one, so all carriers must use the one definition.
        result.heat_megajoules +=
            liquid_heat_capacity_megajoules_per_k * temperature +
            try group_support.frozenWaterEnthalpyPerM3(
                temperature,
                parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                ice_heat_capacity_per_water_equivalent_m3_k,
                parameters.latent_heat_of_fusion_megajoules_per_m3,
                parameters.pure_water_melting_temperature_k,
            ) * ice_water_equivalent;
        if (publish_diagnostics) {
            diagnostic_surface_ice_water_equivalent_m3 += ice_water_equivalent;
            diagnostic_surface_vapor_water_equivalent_m3 += vapor_water_equivalent_m3;
        }

        const first = cell * gas.species_count;
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
                if (!std.math.isFinite(value))
                    return error.NonFiniteSurfacePhysicalInventory;
                if (value < 0) return error.NegativeSurfacePhysicalInventory;
            }
        }
        const carbon_g =
            group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .carbon_dioxide) +
            group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .methane);
        result.carbon_dioxide_carbon_g += carbon_g;
        result.diagnostic_surface_gas_carbon_g += carbon_g;
        result.oxygen_g +=
            group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .oxygen);
        result.hydrogen_g +=
            group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .hydrogen);
        result.dinitrogen_nitrogen_g +=
            group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .nitrogen) +
            group_support.fourPhaseGas(gaseous, dissolved, macropore, band, .nitrous_oxide);
        // Aqueous litter NH3 is already counted from the authoritative
        // chemistry owner above. Only `ZNH3G(0)` is gas-owned storage.
        result.ammonium_nitrogen_g += gaseous[@intFromEnum(gas.Species.ammonia)];
    }
    result.diagnostic_surface_heat_megajoules = result.heat_megajoules;
    try result.validate();
    return result;
}

test "pending surface fire inventory preserves cell element and legacy pseudo-ion storage" {
    var state = try fire_exchange.State.init(
        std.testing.allocator,
        2,
        organic.microbial_substrate_count,
    );
    defer state.deinit();

    state.pending_surface_ammonium_mol_n[0] = 1;
    state.pending_surface_ammonium_mol_n[1] = 3;
    state.pending_surface_phosphate_mol_p[0] = 2;
    state.pending_surface_phosphate_mol_p[1] = 4;
    for (0..fire_exchange.salt_species_count) |salt| {
        state.pending_surface_salt_mol[salt] = @floatFromInt(salt + 1);
        state.pending_surface_salt_mol[fire_exchange.salt_species_count + salt] =
            @floatFromInt(10 * (salt + 1));
    }

    const first = try aggregatePendingSurfaceFireCell(&state, 14, 31, 0);
    try std.testing.expectEqual(@as(f64, 14), first.ammonium_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 62), first.phosphate_phosphorus_g);
    try std.testing.expectEqual(@as(f64, 44), first.ion_inventory_mol);
    try std.testing.expectEqual(@as(f64, 1), first.aluminum_mol);
    try std.testing.expectEqual(@as(f64, 8), first.chloride_mol);

    const domain = try aggregatePendingSurfaceFire(&state, 14, 31);
    try std.testing.expectEqual(@as(f64, 56), domain.ammonium_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 186), domain.phosphate_phosphorus_g);
    try std.testing.expectEqual(@as(f64, 422), domain.ion_inventory_mol);
    try std.testing.expectEqual(@as(f64, 11), domain.aluminum_mol);
    try std.testing.expectEqual(@as(f64, 88), domain.chloride_mol);
}
