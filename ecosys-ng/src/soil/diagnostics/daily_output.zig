const std = @import("std");
const daily_gas_flux = @import("daily_gas_flux.zig");

pub const CarbonInputs = struct {
    cell_area_m2: f64,
    grid_area_m2: f64,
    residue_carbon_g: f64,
    organic_carbon_g: f64,
    organic_fertilizer_carbon_g: f64,
    carbon_sink_g: f64,
    daily_soil_carbon_dioxide_exchange_g_c: f64,
    daily_soil_oxygen_exchange_g_o: f64,
    carbon_output_g: f64,
    microbial_carbon_g: f64,
    surface_organic_carbon_g: f64,
    daily_soil_methane_exchange_g_c: f64,
    dissolved_organic_carbon_runoff_g: f64,
    dissolved_organic_carbon_drainage_g: f64,
    dissolved_inorganic_carbon_runoff_g: f64,
    dissolved_inorganic_carbon_drainage_g: f64,
    atmospheric_carbon_dioxide_umol_per_mol: f64,
    net_biome_productivity_g: f64,
    soil_fire_carbon_dioxide_emission_g_c: f64,
    root_fire_carbon_dioxide_emission_g_c: f64,
    organic_carbon_g_by_layer: []const f64,
    soil_fire_charcoal_production_g_c: f64,
    canopy_air_carbon_dioxide_exchange_g_c: f64,
    canopy_air_methane_exchange_g_c: f64,
    canopy_air_oxygen_exchange_g_o: f64,
    daily_hydrogen_flux_g_h: f64,
    harvested_carbon_g: f64,
    total_leaf_area_m2: f64,
    gross_primary_productivity_g: f64,
    autotrophic_respiration_g: f64,
    net_primary_productivity_g: f64,
    heterotrophic_respiration_total_g: f64,
    soil_fire_methane_emission_g_c: f64,
    root_fire_methane_emission_g_c: f64,
    total_inorganic_carbon_storage_g: f64,
    standing_dead_carbon_g: f64,
};

pub const Carbon = struct {
    allocator: std.mem.Allocator,
    values: []f64,
    pub fn deinit(self: *Carbon) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

/// OUTSD choice 41 (`UH2GG`) is the accepted daily H2 boundary flux. It is
/// deliberately projected from the DAY accumulator rather than reconstructed
/// from the final gaseous and dissolved H2 inventories.
pub fn dailyHydrogenFluxGPerM2(
    flux: *const daily_gas_flux.State,
    cell: usize,
    cell_area_m2: f64,
) !f64 {
    try positive(cell_area_m2);
    return (try flux.getSoilLitterBoundary(cell, .hydrogen)) / cell_area_m2;
}

/// Exact OUTSD carbon choice order. Choices 36..40 are retained as explicit
/// zeros, while the former ORGC(1..14) block expands to the runtime layer count.
pub fn carbon(allocator: std.mem.Allocator, inputs: CarbonInputs) !Carbon {
    try positive(inputs.cell_area_m2);
    try positive(inputs.grid_area_m2);
    const values = try allocator.alloc(f64, 36 + inputs.organic_carbon_g_by_layer.len);
    errdefer allocator.free(values);
    const a = 1.0 / inputs.cell_area_m2;
    var i: usize = 0;
    for ([_]f64{
        inputs.residue_carbon_g * a,                                      inputs.organic_carbon_g * a,                                                                       inputs.organic_fertilizer_carbon_g * a,
        inputs.carbon_sink_g * a,                                         inputs.daily_soil_carbon_dioxide_exchange_g_c * a,                                                 inputs.daily_soil_oxygen_exchange_g_o * a,
        inputs.carbon_output_g * a,                                       inputs.microbial_carbon_g * a,                                                                     inputs.surface_organic_carbon_g * a,
        inputs.daily_soil_methane_exchange_g_c * a,                       inputs.dissolved_organic_carbon_runoff_g / inputs.grid_area_m2,                                    inputs.dissolved_organic_carbon_drainage_g / inputs.grid_area_m2,
        inputs.dissolved_inorganic_carbon_runoff_g / inputs.grid_area_m2, inputs.dissolved_inorganic_carbon_drainage_g / inputs.grid_area_m2,                                inputs.atmospheric_carbon_dioxide_umol_per_mol,
        inputs.net_biome_productivity_g * a,                              (inputs.soil_fire_carbon_dioxide_emission_g_c + inputs.root_fire_carbon_dioxide_emission_g_c) * a,
    }) |value| {
        values[i] = value;
        i += 1;
    }
    for (inputs.organic_carbon_g_by_layer) |value| {
        values[i] = value * a;
        i += 1;
    }
    for ([_]f64{ inputs.soil_fire_charcoal_production_g_c * a, inputs.canopy_air_carbon_dioxide_exchange_g_c * a, inputs.canopy_air_methane_exchange_g_c * a, inputs.canopy_air_oxygen_exchange_g_o * a }) |value| {
        values[i] = value;
        i += 1;
    }
    @memset(values[i .. i + 5], 0.0);
    i += 5;
    for ([_]f64{
        inputs.daily_hydrogen_flux_g_h * a,           inputs.harvested_carbon_g * a,                                                       inputs.total_leaf_area_m2 * a,
        inputs.gross_primary_productivity_g * a,      inputs.autotrophic_respiration_g * a,                                                inputs.net_primary_productivity_g * a,
        inputs.heterotrophic_respiration_total_g * a, (inputs.soil_fire_methane_emission_g_c + inputs.root_fire_methane_emission_g_c) * a, inputs.total_inorganic_carbon_storage_g * a,
        inputs.standing_dead_carbon_g * a,
    }) |value| {
        values[i] = value;
        i += 1;
    }
    std.debug.assert(i == values.len);
    for (values) |value| try finite(value);
    return .{ .allocator = allocator, .values = values };
}

pub const NitrogenInputs = struct {
    cell_area_m2: f64,
    grid_area_m2: f64,
    minimum_volume_m3: f64,
    residue_nitrogen_g: f64,
    organic_nitrogen_g: f64,
    fertilizer_nitrogen_g: f64,
    nitrogen_sink_g: f64,
    ammonium_nitrogen_g: f64,
    nitrate_nitrogen_g: f64,
    dissolved_organic_nitrogen_runoff_g: f64,
    dissolved_organic_nitrogen_drainage_g: f64,
    dissolved_inorganic_nitrogen_runoff_g: f64,
    dissolved_inorganic_nitrogen_drainage_g: f64,
    daily_soil_nitrous_oxide_exchange_g_n: f64,
    daily_soil_ammonia_exchange_g_n: f64,
    dissolved_dinitrogen_storage_g_n: f64,
    total_organic_nitrogen_g: f64,
    ammonium_sorbed_g_by_layer: []const f64,
    ammonium_band_sorbed_g_by_layer: []const f64,
    aqueous_ammonium_mol_by_layer: []const f64,
    aqueous_band_ammonium_mol_by_layer: []const f64,
    nitrate_g_by_layer: []const f64,
    band_nitrate_g_by_layer: []const f64,
    nitrite_g_by_layer: []const f64,
    band_nitrite_g_by_layer: []const f64,
    bulk_volume_m3_by_layer: []const f64,
    water_volume_m3_by_layer: []const f64,
    surface_ammonium_sorbed_g: f64,
    surface_aqueous_ammonium_mol: f64,
    surface_bulk_volume_m3: f64,
    soil_fire_nitrogen_loss_g_n: f64,
    harvested_nitrogen_g: f64,
    net_microbial_nitrogen_mineralization_g_n: f64,
    soil_fire_nitrogen_emission_g_n: f64,
    root_fire_nitrogen_emission_g_n: f64,
    daily_soil_dinitrogen_exchange_g_n: f64,
};

pub const Nitrogen = struct {
    allocator: std.mem.Allocator,
    values: []f64,
    pub fn deinit(self: *Nitrogen) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub fn nitrogen(allocator: std.mem.Allocator, inputs: NitrogenInputs) !Nitrogen {
    const layer_count = inputs.bulk_volume_m3_by_layer.len;
    const values = try allocator.alloc(f64, 20 + 2 * layer_count);
    errdefer allocator.free(values);
    try calculateNitrogenInto(inputs, values);
    return .{ .allocator = allocator, .values = values };
}

pub fn calculateNitrogenInto(inputs: NitrogenInputs, values: []f64) !void {
    try positive(inputs.cell_area_m2);
    try positive(inputs.grid_area_m2);
    if (!std.math.isFinite(inputs.minimum_volume_m3) or inputs.minimum_volume_m3 < 0) return error.InvalidSoilDailyMinimumVolume;
    const layer_count = inputs.bulk_volume_m3_by_layer.len;
    if (values.len != 20 + 2 * layer_count) return error.SoilDailyNitrogenOutputDimensionMismatch;
    inline for (.{ inputs.ammonium_sorbed_g_by_layer, inputs.ammonium_band_sorbed_g_by_layer, inputs.aqueous_ammonium_mol_by_layer, inputs.aqueous_band_ammonium_mol_by_layer, inputs.nitrate_g_by_layer, inputs.band_nitrate_g_by_layer, inputs.nitrite_g_by_layer, inputs.band_nitrite_g_by_layer, inputs.water_volume_m3_by_layer }) |slice| if (slice.len != layer_count) return error.SoilDailyNitrogenDimensionMismatch;
    inline for (.{ inputs.ammonium_sorbed_g_by_layer, inputs.ammonium_band_sorbed_g_by_layer, inputs.aqueous_ammonium_mol_by_layer, inputs.aqueous_band_ammonium_mol_by_layer, inputs.nitrate_g_by_layer, inputs.band_nitrate_g_by_layer, inputs.nitrite_g_by_layer, inputs.band_nitrite_g_by_layer, inputs.bulk_volume_m3_by_layer, inputs.water_volume_m3_by_layer }) |slice| try finiteSlice(slice);
    inline for (.{ inputs.surface_ammonium_sorbed_g, inputs.surface_aqueous_ammonium_mol, inputs.surface_bulk_volume_m3 }) |value| try finite(value);
    const a = 1.0 / inputs.cell_area_m2;
    var i: usize = 0;
    for ([_]f64{ inputs.residue_nitrogen_g * a, inputs.organic_nitrogen_g * a, inputs.fertilizer_nitrogen_g * a, inputs.nitrogen_sink_g * a, inputs.ammonium_nitrogen_g * a, inputs.nitrate_nitrogen_g * a, inputs.dissolved_organic_nitrogen_runoff_g / inputs.grid_area_m2, inputs.dissolved_organic_nitrogen_drainage_g / inputs.grid_area_m2, inputs.dissolved_inorganic_nitrogen_runoff_g / inputs.grid_area_m2, inputs.dissolved_inorganic_nitrogen_drainage_g / inputs.grid_area_m2, inputs.daily_soil_nitrous_oxide_exchange_g_n * a, inputs.daily_soil_ammonia_exchange_g_n * a, inputs.dissolved_dinitrogen_storage_g_n * a, inputs.total_organic_nitrogen_g * a }) |value| {
        values[i] = value;
        i += 1;
    }
    for (0..layer_count) |layer| {
        const numerator = inputs.ammonium_sorbed_g_by_layer[layer] + inputs.ammonium_band_sorbed_g_by_layer[layer] + 14.0 * (inputs.aqueous_ammonium_mol_by_layer[layer] + inputs.aqueous_band_ammonium_mol_by_layer[layer]);
        values[i] = concentration(numerator, inputs.bulk_volume_m3_by_layer[layer], inputs.water_volume_m3_by_layer[layer], inputs.minimum_volume_m3);
        i += 1;
    }
    for (0..layer_count) |layer| {
        const numerator = inputs.nitrate_g_by_layer[layer] + inputs.band_nitrate_g_by_layer[layer] + inputs.nitrite_g_by_layer[layer] + inputs.band_nitrite_g_by_layer[layer];
        values[i] = concentration(numerator, inputs.bulk_volume_m3_by_layer[layer], inputs.water_volume_m3_by_layer[layer], inputs.minimum_volume_m3);
        i += 1;
    }
    values[i] = if (inputs.surface_bulk_volume_m3 > inputs.minimum_volume_m3) (inputs.surface_ammonium_sorbed_g + 14.0 * inputs.surface_aqueous_ammonium_mol) / inputs.surface_bulk_volume_m3 else 0;
    i += 1;
    for ([_]f64{ inputs.soil_fire_nitrogen_loss_g_n * a, inputs.harvested_nitrogen_g * a, inputs.net_microbial_nitrogen_mineralization_g_n * a, (inputs.soil_fire_nitrogen_emission_g_n + inputs.root_fire_nitrogen_emission_g_n) * a, inputs.daily_soil_dinitrogen_exchange_g_n * a }) |value| {
        values[i] = value;
        i += 1;
    }
    std.debug.assert(i == values.len);
    for (values) |value| try finite(value);
}

fn concentration(numerator: f64, bulk_volume_m3: f64, water_volume_m3: f64, minimum_volume_m3: f64) f64 {
    return if (bulk_volume_m3 > minimum_volume_m3) numerator / bulk_volume_m3 else if (water_volume_m3 > minimum_volume_m3) numerator / water_volume_m3 else 0;
}

pub const PhosphorusInputs = struct {
    cell_area_m2: f64,
    grid_area_m2: f64,
    minimum_volume_m3: f64,
    residue_phosphorus_g: f64,
    organic_phosphorus_g: f64,
    fertilizer_phosphorus_g: f64,
    phosphorus_sink_g: f64,
    phosphate_phosphorus_g: f64,
    dissolved_organic_phosphorus_runoff_g: f64,
    dissolved_organic_phosphorus_drainage_g: f64,
    dissolved_inorganic_phosphorus_runoff_g: f64,
    dissolved_inorganic_phosphorus_drainage_g: f64,
    precipitated_phosphorus_g: f64,
    total_organic_phosphorus_g: f64,
    soil_fire_phosphorus_emission_g_p: f64,
    root_fire_phosphorus_emission_g_p: f64,
    monohydrogen_phosphate_g_by_layer: []const f64,
    band_monohydrogen_phosphate_g_by_layer: []const f64,
    dihydrogen_phosphate_g_by_layer: []const f64,
    band_dihydrogen_phosphate_g_by_layer: []const f64,
    sorbed_monohydrogen_phosphate_mol_by_layer: []const f64,
    sorbed_dihydrogen_phosphate_mol_by_layer: []const f64,
    band_sorbed_monohydrogen_phosphate_mol_by_layer: []const f64,
    band_sorbed_dihydrogen_phosphate_mol_by_layer: []const f64,
    bulk_volume_m3_by_layer: []const f64,
    water_volume_m3_by_layer: []const f64,
    surface_monohydrogen_phosphate_g: f64,
    surface_dihydrogen_phosphate_g: f64,
    surface_sorbed_monohydrogen_phosphate_mol: f64,
    surface_sorbed_dihydrogen_phosphate_mol: f64,
    surface_bulk_volume_m3: f64,
    soil_fire_phosphorus_loss_g_p: f64,
    soluble_phosphate_storage_g_p: f64,
    harvested_phosphorus_g: f64,
    net_microbial_phosphate_mineralization_g_p: f64,
};

pub const Phosphorus = struct {
    allocator: std.mem.Allocator,
    values: []f64,
    pub fn deinit(self: *Phosphorus) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub fn sorbedPhosphorusConcentrationGPerM3(
    sorbed_phosphorus_mol_p_per_megagram: f64,
    dry_matter_density_megagrams_per_m3: f64,
    phosphorus_molar_mass_g_per_mol: f64,
) !f64 {
    inline for (.{
        sorbed_phosphorus_mol_p_per_megagram,
        dry_matter_density_megagrams_per_m3,
        phosphorus_molar_mass_g_per_mol,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteSorbedPhosphorusConcentrationInput;
    if (sorbed_phosphorus_mol_p_per_megagram < 0 or
        dry_matter_density_megagrams_per_m3 < 0 or
        phosphorus_molar_mass_g_per_mol <= 0)
        return error.InvalidSorbedPhosphorusConcentrationInput;
    return sorbed_phosphorus_mol_p_per_megagram *
        dry_matter_density_megagrams_per_m3 *
        phosphorus_molar_mass_g_per_mol;
}

pub fn phosphorus(allocator: std.mem.Allocator, inputs: PhosphorusInputs) !Phosphorus {
    try positive(inputs.cell_area_m2);
    try positive(inputs.grid_area_m2);
    if (!std.math.isFinite(inputs.minimum_volume_m3) or inputs.minimum_volume_m3 < 0) return error.InvalidSoilDailyMinimumVolume;
    const layer_count = inputs.bulk_volume_m3_by_layer.len;
    inline for (.{ inputs.monohydrogen_phosphate_g_by_layer, inputs.band_monohydrogen_phosphate_g_by_layer, inputs.dihydrogen_phosphate_g_by_layer, inputs.band_dihydrogen_phosphate_g_by_layer, inputs.sorbed_monohydrogen_phosphate_mol_by_layer, inputs.sorbed_dihydrogen_phosphate_mol_by_layer, inputs.band_sorbed_monohydrogen_phosphate_mol_by_layer, inputs.band_sorbed_dihydrogen_phosphate_mol_by_layer, inputs.water_volume_m3_by_layer }) |slice| if (slice.len != layer_count) return error.SoilDailyPhosphorusDimensionMismatch;
    inline for (.{ inputs.monohydrogen_phosphate_g_by_layer, inputs.band_monohydrogen_phosphate_g_by_layer, inputs.dihydrogen_phosphate_g_by_layer, inputs.band_dihydrogen_phosphate_g_by_layer, inputs.sorbed_monohydrogen_phosphate_mol_by_layer, inputs.sorbed_dihydrogen_phosphate_mol_by_layer, inputs.band_sorbed_monohydrogen_phosphate_mol_by_layer, inputs.band_sorbed_dihydrogen_phosphate_mol_by_layer, inputs.bulk_volume_m3_by_layer, inputs.water_volume_m3_by_layer }) |slice| try finiteSlice(slice);
    const values = try allocator.alloc(f64, 20 + 2 * layer_count);
    errdefer allocator.free(values);
    const a = 1.0 / inputs.cell_area_m2;
    var i: usize = 0;
    for ([_]f64{ inputs.residue_phosphorus_g * a, inputs.organic_phosphorus_g * a, inputs.fertilizer_phosphorus_g * a, inputs.phosphorus_sink_g * a, inputs.phosphate_phosphorus_g * a, inputs.dissolved_organic_phosphorus_runoff_g / inputs.grid_area_m2, inputs.dissolved_organic_phosphorus_drainage_g / inputs.grid_area_m2, inputs.dissolved_inorganic_phosphorus_runoff_g / inputs.grid_area_m2, inputs.dissolved_inorganic_phosphorus_drainage_g / inputs.grid_area_m2, inputs.precipitated_phosphorus_g * a, inputs.total_organic_phosphorus_g * a, (inputs.soil_fire_phosphorus_emission_g_p + inputs.root_fire_phosphorus_emission_g_p) * a }) |value| {
        values[i] = value;
        i += 1;
    }
    for (0..layer_count) |layer| {
        const numerator = inputs.monohydrogen_phosphate_g_by_layer[layer] + inputs.band_monohydrogen_phosphate_g_by_layer[layer] + inputs.dihydrogen_phosphate_g_by_layer[layer] + inputs.band_dihydrogen_phosphate_g_by_layer[layer];
        if (inputs.bulk_volume_m3_by_layer[layer] > inputs.minimum_volume_m3) {
            if (inputs.water_volume_m3_by_layer[layer] <= inputs.minimum_volume_m3) return error.ActiveSoilLayerHasNoWaterVolume;
            values[i] = numerator / inputs.water_volume_m3_by_layer[layer];
        } else values[i] = 0;
        i += 1;
    }
    for (0..layer_count) |layer| {
        const phosphorus_g = 31.0 * (inputs.sorbed_monohydrogen_phosphate_mol_by_layer[layer] + inputs.sorbed_dihydrogen_phosphate_mol_by_layer[layer] + inputs.band_sorbed_monohydrogen_phosphate_mol_by_layer[layer] + inputs.band_sorbed_dihydrogen_phosphate_mol_by_layer[layer]);
        values[i] = concentration(phosphorus_g, inputs.bulk_volume_m3_by_layer[layer], inputs.water_volume_m3_by_layer[layer], inputs.minimum_volume_m3);
        i += 1;
    }
    inline for (.{ inputs.surface_monohydrogen_phosphate_g, inputs.surface_dihydrogen_phosphate_g, inputs.surface_sorbed_monohydrogen_phosphate_mol, inputs.surface_sorbed_dihydrogen_phosphate_mol, inputs.surface_bulk_volume_m3 }) |value| try finite(value);
    values[i] = if (inputs.surface_bulk_volume_m3 > inputs.minimum_volume_m3) (inputs.surface_monohydrogen_phosphate_g + inputs.surface_dihydrogen_phosphate_g) / inputs.surface_bulk_volume_m3 else 0;
    i += 1;
    values[i] = if (inputs.surface_bulk_volume_m3 > inputs.minimum_volume_m3) 31.0 * (inputs.surface_sorbed_monohydrogen_phosphate_mol + inputs.surface_sorbed_dihydrogen_phosphate_mol) / inputs.surface_bulk_volume_m3 else 0;
    i += 1;
    for ([_]f64{ inputs.soil_fire_phosphorus_loss_g_p * a, inputs.soluble_phosphate_storage_g_p * a, inputs.harvested_phosphorus_g * a, inputs.net_microbial_phosphate_mineralization_g_p * a, 0, 0 }) |value| {
        values[i] = value;
        i += 1;
    }
    std.debug.assert(i == values.len);
    for (values) |value| try finite(value);
    return .{ .allocator = allocator, .values = values };
}

pub const WaterInputs = struct {
    cell_area_m2: f64,
    grid_area_m2: f64,
    rainfall_m3: f64,
    evaporation_m3: f64,
    runoff_m3: f64,
    soil_water_storage_m3: f64,
    outflow_m3: f64,
    snow_depth_m: f64,
    liquid_water_fraction_by_layer: []const f64,
    surface_excess_liquid_water_depth_m: f64,
    ice_fraction_by_layer: []const f64,
    surface_excess_ice_water_depth_m: f64,
    matric_plus_osmotic_potential_mpa_by_layer: []const f64,
    surface_matric_potential_megapascal: f64,
    lateral_water_outflow_m3: f64,
    sediment_outflow_m3: f64,
    mineral_soil_surface_depth_m: f64,
    surface_litter_thickness_m: f64,
    active_layer_bottom_depth_m: f64,
    water_table_depth_m: f64,
};

pub const Water = struct {
    allocator: std.mem.Allocator,
    values: []f64,
    pub fn deinit(self: *Water) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub fn water(allocator: std.mem.Allocator, inputs: WaterInputs) !Water {
    const count = 14 + inputs.liquid_water_fraction_by_layer.len + inputs.ice_fraction_by_layer.len + inputs.matric_plus_osmotic_potential_mpa_by_layer.len;
    const values = try allocator.alloc(f64, count);
    errdefer allocator.free(values);
    try calculateWaterInto(inputs, values);
    return .{ .allocator = allocator, .values = values };
}

pub fn calculateWaterInto(inputs: WaterInputs, values: []f64) !void {
    try positive(inputs.cell_area_m2);
    try positive(inputs.grid_area_m2);
    const count = 14 + inputs.liquid_water_fraction_by_layer.len + inputs.ice_fraction_by_layer.len + inputs.matric_plus_osmotic_potential_mpa_by_layer.len;
    if (values.len != count) return error.SoilDailyWaterOutputDimensionMismatch;
    try finiteSlice(inputs.liquid_water_fraction_by_layer);
    try finiteSlice(inputs.ice_fraction_by_layer);
    try finiteSlice(inputs.matric_plus_osmotic_potential_mpa_by_layer);
    var i: usize = 0;
    for ([_]f64{
        1000.0 * inputs.rainfall_m3 / inputs.cell_area_m2,
        1000.0 * inputs.evaporation_m3 / inputs.cell_area_m2,
        1000.0 * inputs.runoff_m3 / inputs.grid_area_m2,
        1000.0 * inputs.soil_water_storage_m3 / inputs.cell_area_m2,
        1000.0 * inputs.outflow_m3 / inputs.grid_area_m2,
        1000.0 * inputs.snow_depth_m,
    }) |value| {
        values[i] = value;
        i += 1;
    }
    for (inputs.liquid_water_fraction_by_layer) |value| {
        values[i] = value;
        i += 1;
    }
    values[i] = inputs.surface_excess_liquid_water_depth_m;
    i += 1;
    for (inputs.ice_fraction_by_layer) |value| {
        values[i] = value;
        i += 1;
    }
    values[i] = inputs.surface_excess_ice_water_depth_m;
    i += 1;
    for (inputs.matric_plus_osmotic_potential_mpa_by_layer) |value| {
        values[i] = value;
        i += 1;
    }
    values[i] = 1000.0 * inputs.lateral_water_outflow_m3 / inputs.grid_area_m2;
    i += 1;
    values[i] = 1000.0 * inputs.sediment_outflow_m3 / inputs.grid_area_m2;
    i += 1;
    values[i] = inputs.surface_matric_potential_megapascal;
    i += 1;
    // Exact OUTSD 48..50 geometry:
    //   -CDPTH(NU-1) + DLYR(3,0)
    //   -(DPTHA-CDPTH(NU-1)+DLYR(3,0))
    //   -(DPTHT-CDPTH(NU-1))
    // The litter thickness therefore affects the exposed surface and active
    // layer, but not the water table referenced to the mineral-soil surface.
    values[i] = -inputs.mineral_soil_surface_depth_m +
        inputs.surface_litter_thickness_m;
    i += 1;
    values[i] = -(inputs.active_layer_bottom_depth_m -
        inputs.mineral_soil_surface_depth_m +
        inputs.surface_litter_thickness_m);
    i += 1;
    values[i] = -(inputs.water_table_depth_m -
        inputs.mineral_soil_surface_depth_m);
    for (values) |value| try finite(value);
}

pub const HeatInputs = struct {
    total_radiation_megajoules_m2: f64,
    maximum_air_temperature_c: f64,
    minimum_air_temperature_c: f64,
    maximum_atmospheric_vapor_pressure_kpa: f64,
    minimum_atmospheric_vapor_pressure_kpa: f64,
    cumulative_wind_m: f64,
    total_precipitation_mm: f64,
    maximum_soil_temperature_c_by_layer: []const f64,
    minimum_soil_temperature_c_by_layer: []const f64,
    surface_maximum_soil_temperature_c: f64,
    surface_minimum_soil_temperature_c: f64,
    electrical_conductivity_by_layer: []const f64,
    ionic_outflow_mol: f64,
    grid_area_m2: f64,
};

pub const Heat = struct {
    allocator: std.mem.Allocator,
    values: []f64,
    pub fn deinit(self: *Heat) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub fn heat(allocator: std.mem.Allocator, inputs: HeatInputs) !Heat {
    if (inputs.maximum_soil_temperature_c_by_layer.len != inputs.minimum_soil_temperature_c_by_layer.len) return error.SoilDailyTemperatureDimensionMismatch;
    try positive(inputs.grid_area_m2);
    const values = try allocator.alloc(f64, 10 + 2 * inputs.maximum_soil_temperature_c_by_layer.len + inputs.electrical_conductivity_by_layer.len);
    errdefer allocator.free(values);
    try calculateHeatInto(inputs, values);
    return .{ .allocator = allocator, .values = values };
}

pub fn calculateHeatInto(inputs: HeatInputs, values: []f64) !void {
    if (inputs.maximum_soil_temperature_c_by_layer.len != inputs.minimum_soil_temperature_c_by_layer.len) return error.SoilDailyTemperatureDimensionMismatch;
    try positive(inputs.grid_area_m2);
    if (values.len != 10 + 2 * inputs.maximum_soil_temperature_c_by_layer.len + inputs.electrical_conductivity_by_layer.len) return error.SoilDailyHeatOutputDimensionMismatch;
    try finiteSlice(inputs.maximum_soil_temperature_c_by_layer);
    try finiteSlice(inputs.minimum_soil_temperature_c_by_layer);
    try finiteSlice(inputs.electrical_conductivity_by_layer);
    var i: usize = 0;
    for ([_]f64{ inputs.total_radiation_megajoules_m2, inputs.maximum_air_temperature_c, inputs.minimum_air_temperature_c, inputs.maximum_atmospheric_vapor_pressure_kpa, inputs.minimum_atmospheric_vapor_pressure_kpa, inputs.cumulative_wind_m * 0.001, inputs.total_precipitation_mm }) |value| {
        values[i] = value;
        i += 1;
    }
    for (inputs.maximum_soil_temperature_c_by_layer, inputs.minimum_soil_temperature_c_by_layer) |maximum, minimum| {
        values[i] = maximum;
        values[i + 1] = minimum;
        i += 2;
    }
    values[i] = inputs.surface_maximum_soil_temperature_c;
    values[i + 1] = inputs.surface_minimum_soil_temperature_c;
    i += 2;
    for (inputs.electrical_conductivity_by_layer) |value| {
        values[i] = value;
        i += 1;
    }
    values[i] = inputs.ionic_outflow_mol / inputs.grid_area_m2;
    for (values) |value| try finite(value);
}

fn positive(value: f64) !void {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidSoilDailyOutputArea;
}
fn finite(value: f64) !void {
    if (!std.math.isFinite(value)) return error.NonFiniteSoilDailyOutput;
}
fn finiteSlice(values: []const f64) !void {
    for (values) |value| try finite(value);
}

test "OUTSD carbon retains reserved zeros and runtime layer placement" {
    const layers = [_]f64{ 2, 4, 6 };
    var inputs = std.mem.zeroes(CarbonInputs);
    inputs.cell_area_m2 = 2;
    inputs.grid_area_m2 = 4;
    inputs.residue_carbon_g = 8;
    inputs.daily_soil_carbon_dioxide_exchange_g_c = -12;
    inputs.daily_soil_oxygen_exchange_g_o = 14;
    inputs.daily_soil_methane_exchange_g_c = -16;
    inputs.soil_fire_carbon_dioxide_emission_g_c = -3;
    inputs.root_fire_carbon_dioxide_emission_g_c = -1;
    inputs.soil_fire_charcoal_production_g_c = 18;
    inputs.soil_fire_methane_emission_g_c = -5;
    inputs.root_fire_methane_emission_g_c = -1;
    inputs.organic_carbon_g_by_layer = &layers;
    inputs.daily_hydrogen_flux_g_h = 10;
    inputs.atmospheric_carbon_dioxide_umol_per_mol = 425;
    var output = try carbon(std.testing.allocator, inputs);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 39), output.values.len);
    try std.testing.expectApproxEqAbs(@as(f64, 4), output.values[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -6), output.values[4], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 7), output.values[5], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -8), output.values[9], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -2), output.values[16], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), output.values[17], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), output.values[19], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 9), output.values[20], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 425), output.values[14], 1e-15);
    for (output.values[24..29]) |value| try std.testing.expectEqual(@as(f64, 0), value);
    try std.testing.expectApproxEqAbs(@as(f64, 5), output.values[29], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -3), output.values[36], 1e-15);
}

test "OUTSD UH2GG projects daily hydrogen flux rather than hydrogen storage" {
    var flux = try daily_gas_flux.State.init(std.testing.allocator, 1);
    defer flux.deinit();
    flux.soil_litter_boundary_mass_g_by_cell_and_species[
        @intFromEnum(@import("../gas/transport.zig").Species.hydrogen)
    ] = 6;
    try std.testing.expectEqual(
        @as(f64, 1.5),
        try dailyHydrogenFluxGPerM2(&flux, 0, 4),
    );
}

test "OUTSD nitrogen uses each layer water fallback and exact molar nitrogen factor" {
    const zeros = [_]f64{ 0, 0 };
    const aqueous = [_]f64{ 1, 2 };
    const nitrate = [_]f64{ 3, 6 };
    const bulk = [_]f64{ 0, 0 };
    const water_volume = [_]f64{ 2, 3 };
    var inputs = std.mem.zeroes(NitrogenInputs);
    inputs.cell_area_m2 = 2;
    inputs.grid_area_m2 = 4;
    inputs.minimum_volume_m3 = 1e-12;
    inputs.daily_soil_nitrous_oxide_exchange_g_n = -2;
    inputs.daily_soil_ammonia_exchange_g_n = 3;
    inputs.dissolved_dinitrogen_storage_g_n = 4;
    inputs.soil_fire_nitrogen_loss_g_n = -5;
    inputs.harvested_nitrogen_g = 6;
    inputs.net_microbial_nitrogen_mineralization_g_n = 7;
    inputs.soil_fire_nitrogen_emission_g_n = -8;
    inputs.root_fire_nitrogen_emission_g_n = -1;
    inputs.daily_soil_dinitrogen_exchange_g_n = -10;
    inputs.ammonium_sorbed_g_by_layer = &zeros;
    inputs.ammonium_band_sorbed_g_by_layer = &zeros;
    inputs.aqueous_ammonium_mol_by_layer = &aqueous;
    inputs.aqueous_band_ammonium_mol_by_layer = &zeros;
    inputs.nitrate_g_by_layer = &nitrate;
    inputs.band_nitrate_g_by_layer = &zeros;
    inputs.nitrite_g_by_layer = &zeros;
    inputs.band_nitrite_g_by_layer = &zeros;
    inputs.bulk_volume_m3_by_layer = &bulk;
    inputs.water_volume_m3_by_layer = &water_volume;
    var output = try nitrogen(std.testing.allocator, inputs);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 24), output.values.len);
    try std.testing.expectApproxEqAbs(@as(f64, 7), output.values[14], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 28.0 / 3.0), output.values[15], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), output.values[16], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2), output.values[17], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -1), output.values[10], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), output.values[11], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2), output.values[12], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -2.5), output.values[19], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), output.values[20], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), output.values[21], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -4.5), output.values[22], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -5), output.values[23], 1e-15);
    var allocation_free: [24]f64 = undefined;
    try calculateNitrogenInto(inputs, &allocation_free);
    try std.testing.expectEqualSlices(f64, output.values, &allocation_free);
}

test "OUTSD phosphorus keeps layer-local aqueous and sorbed pools" {
    const aqueous_a = [_]f64{ 2, 6 };
    const aqueous_b = [_]f64{ 0, 0 };
    const sorbed = [_]f64{ 1, 2 };
    const bulk = [_]f64{ 2, 4 };
    const water_volume = [_]f64{ 1, 2 };
    var inputs = std.mem.zeroes(PhosphorusInputs);
    inputs.cell_area_m2 = 2;
    inputs.grid_area_m2 = 4;
    inputs.minimum_volume_m3 = 1e-12;
    inputs.soil_fire_phosphorus_emission_g_p = -6;
    inputs.root_fire_phosphorus_emission_g_p = -2;
    inputs.soil_fire_phosphorus_loss_g_p = -10;
    inputs.soluble_phosphate_storage_g_p = 12;
    inputs.harvested_phosphorus_g = 14;
    inputs.net_microbial_phosphate_mineralization_g_p = 16;
    inputs.monohydrogen_phosphate_g_by_layer = &aqueous_a;
    inputs.band_monohydrogen_phosphate_g_by_layer = &aqueous_b;
    inputs.dihydrogen_phosphate_g_by_layer = &aqueous_b;
    inputs.band_dihydrogen_phosphate_g_by_layer = &aqueous_b;
    inputs.sorbed_monohydrogen_phosphate_mol_by_layer = &sorbed;
    inputs.sorbed_dihydrogen_phosphate_mol_by_layer = &aqueous_b;
    inputs.band_sorbed_monohydrogen_phosphate_mol_by_layer = &aqueous_b;
    inputs.band_sorbed_dihydrogen_phosphate_mol_by_layer = &aqueous_b;
    inputs.bulk_volume_m3_by_layer = &bulk;
    inputs.water_volume_m3_by_layer = &water_volume;
    var output = try phosphorus(std.testing.allocator, inputs);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 24), output.values.len);
    try std.testing.expectApproxEqAbs(@as(f64, 2), output.values[12], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), output.values[13], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 15.5), output.values[14], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 15.5), output.values[15], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -4), output.values[11], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -5), output.values[18], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 6), output.values[19], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 7), output.values[20], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 8), output.values[21], 1e-15);
}

test "OUTSD sorbed phosphate converts mol per Mg through runtime dry density" {
    try std.testing.expectEqual(
        @as(f64, 31),
        try sorbedPhosphorusConcentrationGPerM3(0.5, 2, 31),
    );
    try std.testing.expectError(
        error.InvalidSorbedPhosphorusConcentrationInput,
        sorbedPhosphorusConcentrationGPerM3(1, -1, 31),
    );
}

test "OUTSD water reproduces historical count and expands every profile" {
    const liquid = [_]f64{0.2} ** 13;
    const ice = [_]f64{0.1} ** 13;
    const potential = [_]f64{-0.5} ** 10;
    const inputs: WaterInputs = .{ .cell_area_m2 = 2, .grid_area_m2 = 4, .rainfall_m3 = 0.002, .evaporation_m3 = 0.001, .runoff_m3 = 0.004, .soil_water_storage_m3 = 0.01, .outflow_m3 = 0.002, .snow_depth_m = 0.03, .liquid_water_fraction_by_layer = &liquid, .surface_excess_liquid_water_depth_m = 0.004, .ice_fraction_by_layer = &ice, .surface_excess_ice_water_depth_m = 0.002, .matric_plus_osmotic_potential_mpa_by_layer = &potential, .surface_matric_potential_megapascal = -0.2, .lateral_water_outflow_m3 = 0.004, .sediment_outflow_m3 = 0.008, .mineral_soil_surface_depth_m = 0.1, .surface_litter_thickness_m = 0.05, .active_layer_bottom_depth_m = 1.1, .water_table_depth_m = 2.1 };
    var output = try water(std.testing.allocator, inputs);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 50), output.values.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1), output.values[0], 1e-15);
    try std.testing.expectEqual(@as(f64, -0.5), output.values[34]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.004), output.values[19], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.002), output.values[33], 1e-15);
    try std.testing.expectEqual(@as(f64, -0.2), output.values[46]);
    try std.testing.expectApproxEqAbs(@as(f64, -0.05), output.values[47], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -1.05), output.values[48], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -2.0), output.values[49], 1e-15);
    var allocation_free: [50]f64 = undefined;
    try calculateWaterInto(inputs, &allocation_free);
    try std.testing.expectEqualSlices(f64, output.values, &allocation_free);
}

test "OUTSD heat reproduces historical fifty choices without fixed ceilings" {
    const maximum = [_]f64{20} ** 14;
    const minimum = [_]f64{10} ** 14;
    const conductivity = [_]f64{1} ** 12;
    const inputs: HeatInputs = .{ .total_radiation_megajoules_m2 = 5, .maximum_air_temperature_c = 25, .minimum_air_temperature_c = 5, .maximum_atmospheric_vapor_pressure_kpa = 0.9, .minimum_atmospheric_vapor_pressure_kpa = 0.3, .cumulative_wind_m = 2000, .total_precipitation_mm = 1, .maximum_soil_temperature_c_by_layer = &maximum, .minimum_soil_temperature_c_by_layer = &minimum, .surface_maximum_soil_temperature_c = 30, .surface_minimum_soil_temperature_c = 8, .electrical_conductivity_by_layer = &conductivity, .ionic_outflow_mol = 2, .grid_area_m2 = 4 };
    var output = try heat(std.testing.allocator, inputs);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 50), output.values.len);
    try std.testing.expectApproxEqAbs(@as(f64, 2), output.values[5], 1e-15);
    var allocation_free: [50]f64 = undefined;
    try calculateHeatInto(inputs, &allocation_free);
    try std.testing.expectEqualSlices(f64, output.values, &allocation_free);
}
