//! `landscape_mass_inventory` declarations: snow.
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
const surface_aqueous = @import("../surface/aqueous_runoff_transport.zig");
const snow_surface_discharge = @import("../soil/water/snow_surface_discharge.zig");
const surface_solute_routing = @import("../soil/solute/surface_solute_routing.zig");

pub const MolarMassesGPerMol = struct {
    nitrogen: f64,
    phosphorus: f64,
    ions: snow_surface_discharge.IonMolarMassesGPerMol,
};

/// Publishes only authoritative storage fields into EXEC totals. Cumulative
/// boundary ledgers and landscape area remain owned by the caller.
/// HEAT-001 instrumentation. Per-carrier frozen water equivalent accumulated
/// by the most recent aggregation pass, printed once per census so the
/// opening and closing daily censuses can be compared carrier by carrier.
pub var diagnostic_snow_solid_water_equivalent_m3: f64 = 0;

pub var diagnostic_snow_ice_volume_water_equivalent_m3: f64 = 0;

/// Compatibility name with fully explicit thermodynamics. No silent default
/// may diverge from the current runscript.
pub fn aggregateSnow(
    state: *const snow.State,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    pure_water_melting_temperature_k: f64,
    molar_mass_g_per_mol: MolarMassesGPerMol,
) !group_support.Storage {
    return aggregateSnowEnthalpy(
        state,
        ice_density_megagrams_per_m3,
        latent_heat_of_fusion_megajoules_per_m3,
        solid_snow_heat_capacity_megajoules_per_m3_k,
        liquid_water_heat_capacity_megajoules_per_m3_k,
        ice_heat_capacity_megajoules_per_m3_k,
        pure_water_melting_temperature_k,
        molar_mass_g_per_mol,
    );
}

pub fn aggregateSnowEnthalpy(
    state: *const snow.State,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    /// HEAT-001 second layer. Needed to re-base each frozen snow carrier's
    /// sensible capacity onto its F77 carrier-specific enthalpy definition.
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    pure_water_melting_temperature_k: f64,
    molar_mass_g_per_mol: MolarMassesGPerMol,
) !group_support.Storage {
    return aggregateSnowEnthalpyRange(
        state,
        ice_density_megagrams_per_m3,
        latent_heat_of_fusion_megajoules_per_m3,
        solid_snow_heat_capacity_megajoules_per_m3_k,
        liquid_water_heat_capacity_megajoules_per_m3_k,
        ice_heat_capacity_megajoules_per_m3_k,
        pure_water_melting_temperature_k,
        molar_mass_g_per_mol,
        0,
        state.cell_count,
        true,
        null,
    );
}

pub fn aggregateSnowEnthalpyCell(
    state: *const snow.State,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    pure_water_melting_temperature_k: f64,
    molar_mass_g_per_mol: MolarMassesGPerMol,
    cell: usize,
) !group_support.Storage {
    if (cell >= state.cell_count) return error.SnowInventoryCellOutOfBounds;
    return aggregateSnowEnthalpyRange(
        state,
        ice_density_megagrams_per_m3,
        latent_heat_of_fusion_megajoules_per_m3,
        solid_snow_heat_capacity_megajoules_per_m3_k,
        liquid_water_heat_capacity_megajoules_per_m3_k,
        ice_heat_capacity_megajoules_per_m3_k,
        pure_water_melting_temperature_k,
        molar_mass_g_per_mol,
        cell,
        cell + 1,
        false,
        null,
    );
}

pub fn aggregateSnowEnthalpyLayer(
    state: *const snow.State,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    pure_water_melting_temperature_k: f64,
    molar_mass_g_per_mol: MolarMassesGPerMol,
    cell: usize,
    layer: usize,
) !group_support.Storage {
    if (cell >= state.cell_count or layer >= state.layer_capacity)
        return error.SnowInventoryCellOutOfBounds;
    return aggregateSnowEnthalpyRange(
        state,
        ice_density_megagrams_per_m3,
        latent_heat_of_fusion_megajoules_per_m3,
        solid_snow_heat_capacity_megajoules_per_m3_k,
        liquid_water_heat_capacity_megajoules_per_m3_k,
        ice_heat_capacity_megajoules_per_m3_k,
        pure_water_melting_temperature_k,
        molar_mass_g_per_mol,
        cell,
        cell + 1,
        false,
        layer,
    );
}

fn aggregateSnowEnthalpyRange(
    state: *const snow.State,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    pure_water_melting_temperature_k: f64,
    molar_mass_g_per_mol: MolarMassesGPerMol,
    first_cell: usize,
    end_cell: usize,
    publish_diagnostics: bool,
    local_layer_filter: ?usize,
) !group_support.Storage {
    inline for (.{ solid_snow_heat_capacity_megajoules_per_m3_k, liquid_water_heat_capacity_megajoules_per_m3_k, ice_heat_capacity_megajoules_per_m3_k }) |value|
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidSnowInventoryHeatCapacity;
    if (!std.math.isFinite(ice_density_megagrams_per_m3) or
        ice_density_megagrams_per_m3 <= 0 or
        ice_density_megagrams_per_m3 > 1)
        return error.InvalidSnowIceDensity;
    if (!std.math.isFinite(latent_heat_of_fusion_megajoules_per_m3) or
        latent_heat_of_fusion_megajoules_per_m3 <= 0)
        return error.InvalidLatentHeatOfFusion;
    if (!std.math.isFinite(pure_water_melting_temperature_k) or
        pure_water_melting_temperature_k <= 0)
        return error.InvalidSnowMeltingTemperature;
    inline for (.{ molar_mass_g_per_mol.nitrogen, molar_mass_g_per_mol.phosphorus }) |value|
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidSnowInventoryMolarMass;
    inline for (@typeInfo(@TypeOf(molar_mass_g_per_mol.ions)).@"struct".fields) |field| {
        const value = @field(molar_mass_g_per_mol.ions, field.name);
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidSnowInventoryMolarMass;
    }
    const layer_count = try std.math.mul(
        usize,
        state.cell_count,
        state.layer_capacity,
    );
    if (state.active.len != layer_count or
        state.solid_snow_water_equivalent_m3.len != layer_count or
        state.liquid_water_volume_m3.len != layer_count or
        state.vapor_water_equivalent_m3.len != layer_count or
        state.ice_volume_m3.len != layer_count or
        state.temperature_k.len != layer_count or
        state.heat_capacity_megajoules_per_k.len != layer_count or
        state.amount_g.len != try std.math.mul(usize, layer_count, snow.species_count) or
        state.salt_amount_mol.len != try std.math.mul(usize, layer_count, snow.salt_species_count) or
        state.dynamic_salts_by_cell.len != state.cell_count)
        return error.SnowInventoryDimensionMismatch;

    var result: group_support.Storage = .{};
    if (publish_diagnostics) {
        diagnostic_snow_solid_water_equivalent_m3 = 0;
        diagnostic_snow_ice_volume_water_equivalent_m3 = 0;
    }
    const first_layer = first_cell * state.layer_capacity + (local_layer_filter orelse 0);
    const end_layer = if (local_layer_filter) |layer|
        first_cell * state.layer_capacity + layer + 1
    else
        end_cell * state.layer_capacity;
    const ice_heat_capacity_per_water_equivalent_m3_k =
        ice_units.heatCapacityPerWaterEquivalentM3K(
            ice_heat_capacity_megajoules_per_m3_k,
            ice_density_megagrams_per_m3,
        ) catch return error.InvalidSnowInventoryHeatCapacity;
    const solid_snow_enthalpy_correction_megajoules_per_water_equivalent_m3 =
        try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
            solid_snow_heat_capacity_megajoules_per_m3_k,
            liquid_water_heat_capacity_megajoules_per_m3_k,
            latent_heat_of_fusion_megajoules_per_m3,
            pure_water_melting_temperature_k,
        );
    const physical_ice_enthalpy_correction_megajoules_per_water_equivalent_m3 =
        try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
            ice_heat_capacity_per_water_equivalent_m3_k,
            liquid_water_heat_capacity_megajoules_per_m3_k,
            latent_heat_of_fusion_megajoules_per_m3,
            pure_water_melting_temperature_k,
        );
    for (first_layer..end_layer) |layer| {
        const solid = state.solid_snow_water_equivalent_m3[layer];
        const liquid = state.liquid_water_volume_m3[layer];
        const vapor = state.vapor_water_equivalent_m3[layer];
        const ice = state.ice_volume_m3[layer];
        const temperature = state.temperature_k[layer];
        const heat_capacity = state.heat_capacity_megajoules_per_k[layer];
        inline for (.{ solid, liquid, vapor, ice, temperature, heat_capacity }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteSnowInventory;
        if (solid < 0 or liquid < 0 or vapor < 0 or ice < 0 or
            temperature < 0 or heat_capacity < 0)
            return error.NegativeSnowInventory;
        const expected_heat_capacity_megajoules_per_k =
            solid_snow_heat_capacity_megajoules_per_m3_k * solid +
            liquid_water_heat_capacity_megajoules_per_m3_k * (liquid + vapor) +
            ice_heat_capacity_megajoules_per_m3_k * ice;
        const capacity_tolerance = 128 * std.math.floatEps(f64) *
            @max(1, @max(@abs(heat_capacity), @abs(expected_heat_capacity_megajoules_per_k)));
        if (@abs(heat_capacity - expected_heat_capacity_megajoules_per_k) > capacity_tolerance)
            return error.InconsistentSnowInventoryHeatCapacity;

        result.water_m3 += solid + liquid + vapor + ice * ice_density_megagrams_per_m3;
        const ice_water_equivalent_m3 = ice * ice_density_megagrams_per_m3;
        if (publish_diagnostics) {
            diagnostic_snow_solid_water_equivalent_m3 += solid;
            diagnostic_snow_ice_volume_water_equivalent_m3 += ice_water_equivalent_m3;
        }
        // The snow owner combines unlike sensible carriers: solid snow uses
        // `C_s*WE`, while refrozen ice uses `C_i_phys*V_phys`. Rebase each one
        // independently onto the common frozen-water enthalpy per m3 WE. A
        // grouped correction silently treats solid snow as physical ice and
        // violates the WATSUB 6661 carrier definition.
        result.heat_megajoules += heat_capacity * temperature +
            solid_snow_enthalpy_correction_megajoules_per_water_equivalent_m3 * solid +
            physical_ice_enthalpy_correction_megajoules_per_water_equivalent_m3 * ice_water_equivalent_m3;
        const amounts = state.amount_g[layer * snow.species_count .. (layer + 1) * snow.species_count];
        for (amounts) |amount| {
            if (!std.math.isFinite(amount)) return error.NonFiniteSnowInventory;
            if (amount < 0) return error.NegativeSnowInventory;
        }
        const snow_cell = layer / state.layer_capacity;
        if (state.dynamic_salts_by_cell[snow_cell]) {
            for (amounts[snow.primary_species_count..]) |amount|
                if (amount != 0) return error.OverlappingSnowSaltInventory;
        }
        result.carbon_dioxide_carbon_g +=
            group_support.speciesAmount(amounts, .carbon_dioxide_carbon) +
            group_support.speciesAmount(amounts, .methane_carbon);
        result.oxygen_g += group_support.speciesAmount(amounts, .oxygen);
        result.dinitrogen_nitrogen_g +=
            group_support.speciesAmount(amounts, .dinitrogen_nitrogen) +
            group_support.speciesAmount(amounts, .nitrous_oxide_nitrogen);
        result.ammonium_nitrogen_g +=
            group_support.speciesAmount(amounts, .ammonium_nitrogen) +
            group_support.speciesAmount(amounts, .ammonia_nitrogen);
        result.nitrate_nitrogen_g += group_support.speciesAmount(amounts, .nitrate_nitrogen);
        result.phosphate_phosphorus_g +=
            group_support.speciesAmount(amounts, .hydrogen_phosphate_phosphorus) +
            group_support.speciesAmount(amounts, .dihydrogen_phosphate_phosphorus);
        const elements: group_support.ElementMoles = .{
            .aluminum = group_support.speciesAmount(amounts, .aluminum) / molar_mass_g_per_mol.ions.aluminum,
            .iron = group_support.speciesAmount(amounts, .iron) / molar_mass_g_per_mol.ions.iron,
            .calcium = group_support.speciesAmount(amounts, .calcium) / molar_mass_g_per_mol.ions.calcium,
            .magnesium = group_support.speciesAmount(amounts, .magnesium) / molar_mass_g_per_mol.ions.magnesium,
            .sodium = group_support.speciesAmount(amounts, .sodium) / molar_mass_g_per_mol.ions.sodium,
            .potassium = group_support.speciesAmount(amounts, .potassium) / molar_mass_g_per_mol.ions.potassium,
            .sulfur = group_support.speciesAmount(amounts, .sulfate_sulfur) / molar_mass_g_per_mol.ions.sulfur,
            .chloride = group_support.speciesAmount(amounts, .chloride) / molar_mass_g_per_mol.ions.chloride,
        };
        try group_support.addElementMoles(&result, elements);
        inline for (std.meta.fields(group_support.ElementMoles)) |field|
            result.ion_inventory_mol += @field(elements, field.name);

        // The primary gram carrier above owns gases, N, the two free
        // phosphate forms, and legacy static-salt cells.  Dynamic cells own
        // the complete 41-coordinate equilibrium here instead; count every
        // molecular formula exactly once, including C/P carried in pairs.
        const salt_amounts = state.salt_amount_mol[layer * snow.salt_species_count .. (layer + 1) * snow.salt_species_count];
        for (salt_amounts, 0..) |amount_mol, snow_species_index| {
            if (!std.math.isFinite(amount_mol)) return error.NonFiniteSnowInventory;
            if (amount_mol < 0) return error.NegativeSnowInventory;
            if (!state.dynamic_salts_by_cell[snow_cell] and amount_mol != 0)
                return error.OverlappingSnowSaltInventory;
            const aqueous_species = snow.aqueousSpeciesForSalt(@enumFromInt(snow_species_index));
            const formula = surface_aqueous.formula(aqueous_species);
            result.carbon_dioxide_carbon_g += amount_mol * formula.carbon_mol * 12;
            result.phosphate_phosphorus_g += amount_mol * formula.phosphorus_mol * molar_mass_g_per_mol.phosphorus;
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
            // REDIST SSS/SSH excludes formula oxygen. The shared legacy map
            // also preserves H/C/P atoms in complexes, so a molecule retains
            // the same pseudo-ion count when snow becomes surface water.
            result.ion_inventory_mol += amount_mol *
                solute_species.legacyIonCount(aqueous_species);
        }
    }
    result.diagnostic_snow_heat_megajoules = result.heat_megajoules;
    try result.validate();
    return result;
}

pub const test_molar_mass_g_per_mol: MolarMassesGPerMol = .{
    .nitrogen = 14,
    .phosphorus = 31,
    .ions = .{
        .aluminum = 27,
        .iron = 56,
        .calcium = 40,
        .magnesium = 24.3,
        .sodium = 23,
        .potassium = 39.1,
        .sulfur = 32,
        .chloride = 35.5,
    },
};

test "F77 snow census rebases solid SWE and physical ice separately onto canonical WE enthalpy" {
    const rho: f64 = 0.917;
    const solid_capacity: f64 = 2.095;
    const liquid_capacity: f64 = 4.19;
    const physical_ice_capacity: f64 = 1.9274;
    const temperature: f64 = 268.15;
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.active[0] = true;
    state.solid_snow_water_equivalent_m3[0] = 0.1;
    state.liquid_water_volume_m3[0] = 0.02;
    state.vapor_water_equivalent_m3[0] = 0.01;
    state.ice_volume_m3[0] = 0.04;
    state.temperature_k[0] = temperature;
    state.heat_capacity_megajoules_per_k[0] =
        solid_capacity * state.solid_snow_water_equivalent_m3[0] +
        liquid_capacity * (state.liquid_water_volume_m3[0] + state.vapor_water_equivalent_m3[0]) +
        physical_ice_capacity * state.ice_volume_m3[0];

    const result = try aggregateSnowEnthalpy(
        &state,
        rho,
        333,
        solid_capacity,
        liquid_capacity,
        physical_ice_capacity,
        273.15,
        test_molar_mass_g_per_mol,
    );
    const ice_capacity_we = physical_ice_capacity / rho;
    const solid_enthalpy_we = liquid_capacity * 273.15 - 333 +
        solid_capacity * (temperature - 273.15);
    const ice_enthalpy_we = liquid_capacity * 273.15 - 333 +
        ice_capacity_we * (temperature - 273.15);
    const expected = liquid_capacity * temperature * (0.02 + 0.01) +
        solid_enthalpy_we * 0.1 + ice_enthalpy_we * 0.04 * rho;
    try std.testing.expectApproxEqAbs(expected, result.heat_megajoules, 1.0e-12);
    try std.testing.expect(@abs(result.heat_megajoules -
        (liquid_capacity * temperature * (0.02 + 0.01) +
            (liquid_capacity * 273.15 - 333 + physical_ice_capacity * (temperature - 273.15)) *
                (0.1 + 0.04 * rho))) > 1.0e-3);
}

test "static snow input retention and melt share authoritative molar masses" {
    const masses: MolarMassesGPerMol = .{
        .nitrogen = 14.5,
        .phosphorus = 30.5,
        .ions = .{ .aluminum = 27.5, .iron = 57, .calcium = 41, .magnesium = 25, .sodium = 24, .potassium = 40, .sulfur = 33, .chloride = 36 },
    };
    var ion_input_g_per_m3 = [_]f64{0} ** snow.static_ion_species_count;
    inline for (@typeInfo(snow_surface_discharge.IonMolarMassesGPerMol).@"struct".fields, 0..) |field, index|
        ion_input_g_per_m3[index] = @field(masses.ions, field.name);
    const atmospheric_input = try snow.atmosphericInputG(1, 0, @splat(0), @splat(0), @splat(0), @splat(0), ion_input_g_per_m3, @splat(0));

    var snow_state = try snow.State.init(std.testing.allocator, 1, 1);
    defer snow_state.deinit();
    snow_state.active[0] = true;
    snow_state.liquid_water_volume_m3[0] = 1;
    snow_state.temperature_k[0] = 273.15;
    snow_state.heat_capacity_megajoules_per_k[0] = 4.19;
    var zero_downward_g = [_]f64{0} ** snow.species_count;
    var zero_downward_salt_mol = [_]f64{0} ** snow.salt_species_count;
    var no_discharge = [_]snow.SurfaceDischarge{.{}};
    const input_fluxes: snow.Fluxes = .{ .allocator = std.testing.allocator, .downward_g = &zero_downward_g, .downward_salt_mol = &zero_downward_salt_mol, .surface_discharge = &no_discharge };
    try snow.state_update(&snow_state, &atmospheric_input, &input_fluxes);
    const retained = try aggregateSnowEnthalpy(&snow_state, 0.917, 333, 2.095, 4.19, 1.9274, 273.15, masses);
    inline for (@typeInfo(snow_surface_discharge.IonMolarMassesGPerMol).@"struct".fields) |field|
        try std.testing.expectEqual(@as(f64, 1), @field(retained, field.name ++ "_mol"));

    var melt_fluxes = try snow.calculateFluxes(
        std.testing.allocator,
        &snow_state,
        &.{0},
        &.{1},
        &.{0},
        &.{0},
        &.{.{ .litter_cover_fraction = 1, .bare_soil_fraction = 0, .nonband_ammonium_fraction = 1, .band_ammonium_fraction = 0, .nonband_nitrate_fraction = 1, .band_nitrate_fraction = 0, .nonband_phosphate_fraction = 1, .band_phosphate_fraction = 0 }},
        .{ .water_absolute_m3 = 0, .relative = 1e-12 },
    );
    defer melt_fluxes.deinit();
    var litter_gas = try gas.State.init(std.testing.allocator, 1);
    defer litter_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 1);
    defer soil_gas.deinit();
    var litter_state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer litter_state.deinit();
    var soil_state = try soil_chemistry.State.init(std.testing.allocator, 1);
    defer soil_state.deinit();
    var surface_solutes = try surface_solute_routing.State.init(std.testing.allocator, 1, 1, solute_species.AqueousSpecies.count);
    defer surface_solutes.deinit();
    try snow_surface_discharge.state_update(std.testing.allocator, .{
        .discharge = melt_fluxes.surface_discharge,
        .litter_water_volume_m3 = &.{1},
        .topsoil_water_volume_m3 = &.{0},
        .soil_layer_capacity = 1,
        .nitrogen_molar_mass_g_per_mol = masses.nitrogen,
        .phosphorus_molar_mass_g_per_mol = masses.phosphorus,
        .ion_molar_mass_g_per_mol = masses.ions,
        .surface_aqueous = &surface_solutes,
    }, &litter_gas, &soil_gas, &litter_state, &soil_state);
    try snow.state_update(&snow_state, &([_]f64{0} ** snow.species_count), &melt_fluxes);

    const after = try aggregateSnowEnthalpy(&snow_state, 0.917, 333, 2.095, 4.19, 1.9274, 273.15, masses);
    try std.testing.expectEqual(@as(f64, 0), after.ion_inventory_mol);
    inline for (@typeInfo(snow_surface_discharge.IonMolarMassesGPerMol).@"struct".fields) |field| {
        const observed = if (comptime std.mem.eql(u8, field.name, "sulfur")) litter_state.cells[0].sulfate_mol_per_m3 else @field(litter_state.cells[0], field.name ++ "_mol_per_m3");
        try std.testing.expectEqual(@as(f64, 1), observed);
    }
}

test "all 41 snow salt species enter cell and domain elemental inventories exactly once" {
    var state = try snow.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    @memset(state.salt_amount_mol[0..snow.salt_species_count], 1);
    @memset(state.salt_amount_mol[snow.salt_species_count..], 2);
    @memset(state.dynamic_salts_by_cell, true);

    const domain = try aggregateSnowEnthalpy(
        &state,
        0.917,
        333,
        2.095,
        4.19,
        1.9274,
        273.15,
        test_molar_mass_g_per_mol,
    );
    const first = try aggregateSnowEnthalpyCell(
        &state,
        0.917,
        333,
        2.095,
        4.19,
        1.9274,
        273.15,
        test_molar_mass_g_per_mol,
        0,
    );
    const second = try aggregateSnowEnthalpyCell(
        &state,
        0.917,
        333,
        2.095,
        4.19,
        1.9274,
        273.15,
        test_molar_mass_g_per_mol,
        1,
    );
    const first_layer = try aggregateSnowEnthalpyLayer(
        &state,
        0.917,
        333,
        2.095,
        4.19,
        1.9274,
        273.15,
        test_molar_mass_g_per_mol,
        0,
        0,
    );
    try std.testing.expectEqualDeep(first, first_layer);
    inline for (std.meta.fields(group_support.Storage)) |field|
        try std.testing.expectEqual(
            @field(first, field.name) + @field(second, field.name),
            @field(domain, field.name),
        );

    // One mole of every snow salt formula contains these non-oxygen atom
    // totals. The domain has one copy in cell 0 and two in cell 1.
    try std.testing.expectEqual(@as(f64, 7 * 3 * 12), domain.carbon_dioxide_carbon_g);
    try std.testing.expectEqual(@as(f64, 8 * 3 * snow.phosphorus_g_per_mol), domain.phosphate_phosphorus_g);
    try std.testing.expectEqual(@as(f64, 6 * 3), domain.aluminum_mol);
    try std.testing.expectEqual(@as(f64, 8 * 3), domain.iron_mol);
    try std.testing.expectEqual(@as(f64, 8 * 3), domain.calcium_mol);
    try std.testing.expectEqual(@as(f64, 6 * 3), domain.magnesium_mol);
    try std.testing.expectEqual(@as(f64, 3 * 3), domain.sodium_mol);
    try std.testing.expectEqual(@as(f64, 2 * 3), domain.potassium_mol);
    try std.testing.expectEqual(@as(f64, 7 * 3), domain.sulfur_mol);
    try std.testing.expectEqual(@as(f64, 1 * 3), domain.chloride_mol);
    try std.testing.expectEqual(@as(f64, 0), domain.silicon_mol);
    try std.testing.expectEqual(@as(f64, 93 * 3), domain.ion_inventory_mol);
}

test "snow layer census rejects overlapping static and dynamic salt owners" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.dynamic_salts_by_cell[0] = true;
    state.amount_g[snow.primary_species_count] = 1;
    try std.testing.expectError(
        error.OverlappingSnowSaltInventory,
        aggregateSnowEnthalpyLayer(
            &state,
            0.917,
            333,
            2.095,
            4.19,
            1.9274,
            273.15,
            test_molar_mass_g_per_mol,
            0,
            0,
        ),
    );
    state.amount_g[snow.primary_species_count] = 0;
    state.dynamic_salts_by_cell[0] = false;
    state.salt_amount_mol[0] = 1;
    try std.testing.expectError(
        error.OverlappingSnowSaltInventory,
        aggregateSnowEnthalpyLayer(
            &state,
            0.917,
            333,
            2.095,
            4.19,
            1.9274,
            273.15,
            test_molar_mass_g_per_mol,
            0,
            0,
        ),
    );
}
