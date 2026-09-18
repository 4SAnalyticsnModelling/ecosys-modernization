const std = @import("std");
const canopy_photosynthesis = @import("../../canopy/photosynthesis/photosynthesis.zig");
const PlantState = @import("../../state/grid.zig").PlantState;

pub const SeedStorage = struct {
    carbon_g: f64,
    nitrogen_g: f64,
    phosphorus_g: f64,
};

pub const ShootControlParameters = struct {
    seconds_per_hour: f64,
    co2_to_water_cuticular_resistance_ratio: f64,
    c3_intercellular_oxygen_umol_per_mol: f64,
    c4_intercellular_oxygen_umol_per_mol: f64,

    pub fn validate(self: ShootControlParameters) !void {
        inline for (@typeInfo(ShootControlParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name)) or @field(self, field.name) <= 0) return error.InvalidShootControlParameters;
    }
};

pub fn compatibilityShootControlParameters() ShootControlParameters {
    return .{ .seconds_per_hour = 3600, .co2_to_water_cuticular_resistance_ratio = 1.56, .c3_intercellular_oxygen_umol_per_mol = 2.10e5, .c4_intercellular_oxygen_umol_per_mol = 3.96e5 };
}

/// STARTQ WTRVX/WTRVC/WTRVN/WTRVP. Seed mass in the plant-trait file is
/// carbon per seed; management population is plants per square metre.
pub fn seedStorage(
    seed_carbon_g_per_plant: f64,
    population_per_m2: f64,
    cell_area_m2: f64,
    grain_nitrogen_to_carbon_g_per_g: f64,
    grain_phosphorus_to_carbon_g_per_g: f64,
) !SeedStorage {
    inline for (.{ seed_carbon_g_per_plant, population_per_m2, cell_area_m2, grain_nitrogen_to_carbon_g_per_g, grain_phosphorus_to_carbon_g_per_g }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSeedStorageInput;
    if (seed_carbon_g_per_plant < 0 or population_per_m2 < 0 or cell_area_m2 <= 0 or grain_nitrogen_to_carbon_g_per_g < 0 or grain_phosphorus_to_carbon_g_per_g < 0) return error.InvalidSeedStorageInput;
    const carbon_g = seed_carbon_g_per_plant * population_per_m2 * cell_area_m2;
    const result: SeedStorage = .{
        .carbon_g = carbon_g,
        .nitrogen_g = grain_nitrogen_to_carbon_g_per_g * carbon_g,
        .phosphorus_g = grain_phosphorus_to_carbon_g_per_g * carbon_g,
    };
    inline for (@typeInfo(SeedStorage).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteSeedStorageResult;
    return result;
}

pub fn initializeSeedStorage(state: *canopy_photosynthesis.State, plant: usize, storage: SeedStorage) !void {
    if (plant >= state.plant_seed_storage_carbon_g.len) return error.CanopyPlantIndexOutOfBounds;
    inline for (@typeInfo(SeedStorage).@"struct".fields) |field| {
        const value = @field(storage, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteSeedStorageInput;
        if (value < 0) return error.InvalidSeedStorageInput;
    }
    state.plant_seed_storage_carbon_g[plant] = storage.carbon_g;
    state.plant_seed_storage_nitrogen_g[plant] = storage.nitrogen_g;
    state.plant_seed_storage_phosphorus_g[plant] = storage.phosphorus_g;
}

/// STARTQ PP/PPZ/DPP, RSMH/RCMX and O2I initialization. Population remains
/// represented both per area and as an extensive cell count so downstream
/// kernels never infer units from an untyped scalar.
pub fn initializeShootControls(
    state: *canopy_photosynthesis.State,
    plant: usize,
    population_per_m2: f64,
    cell_area_m2: f64,
    cuticular_resistance_s_per_m: f64,
    photosynthesis_pathway: u8,
    parameters: ShootControlParameters,
) !void {
    try parameters.validate();
    inline for (.{ population_per_m2, cell_area_m2, cuticular_resistance_s_per_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteShootControlInput;
    if (plant >= state.plant_population_per_m2.len) return error.CanopyPlantIndexOutOfBounds;
    if (population_per_m2 < 0 or cell_area_m2 <= 0 or cuticular_resistance_s_per_m < 0 or (photosynthesis_pathway != 3 and photosynthesis_pathway != 4)) return error.InvalidShootControlInput;
    const population_count = population_per_m2 * cell_area_m2;
    const water_resistance_h_per_m = cuticular_resistance_s_per_m / parameters.seconds_per_hour;
    const co2_resistance_s_per_m = cuticular_resistance_s_per_m * parameters.co2_to_water_cuticular_resistance_ratio;
    inline for (.{ population_count, water_resistance_h_per_m, co2_resistance_s_per_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteShootControlResult;
    state.plant_population_per_m2[plant] = population_per_m2;
    state.plant_population_count[plant] = population_count;
    state.plant_population_change_count[plant] = population_count;
    // STARTQ initializes DPP=PP. Later harvest/mortality transactions mutate
    // this standing-dead population independently from the living population.
    state.plant_standing_dead_population_count[plant] = population_count;
    state.plant_cuticular_water_vapor_resistance_h_per_m[plant] = water_resistance_h_per_m;
    state.plant_cuticular_co2_resistance_s_per_m[plant] = co2_resistance_s_per_m;
    state.plant_intercellular_oxygen_umol_per_mol[plant] = if (photosynthesis_pathway == 3) parameters.c3_intercellular_oxygen_umol_per_mol else parameters.c4_intercellular_oxygen_umol_per_mol;
}

pub const StandingDeadStorage = struct {
    carbon_g: f64,
    nitrogen_g: f64,
    phosphorus_g: f64,
    kinetics: canopy_photosynthesis.KineticFractions,
};

pub const StandingDeadPartitionParameters = struct {
    carbon_fraction: [4]f64,
    nitrogen_weight: [4]f64,
    phosphorus_weight: [4]f64,

    pub fn validate(self: StandingDeadPartitionParameters) !void {
        var carbon_sum: f64 = 0;
        inline for (.{ self.carbon_fraction, self.nitrogen_weight, self.phosphorus_weight }) |values| for (values) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidStandingDeadPartitionParameter;
        };
        for (self.carbon_fraction) |value| carbon_sum += value;
        if (@abs(carbon_sum - 1.0) > 1.0e-12) return error.InvalidStandingDeadPartitionParameter;
        var nitrogen_denominator: f64 = 0;
        var phosphorus_denominator: f64 = 0;
        for (self.carbon_fraction, self.nitrogen_weight, self.phosphorus_weight) |carbon, nitrogen, phosphorus| {
            nitrogen_denominator += carbon * nitrogen;
            phosphorus_denominator += carbon * phosphorus;
        }
        if (!(nitrogen_denominator > 0) or !(phosphorus_denominator > 0)) return error.InvalidStandingDeadPartitionParameter;
    }
};

pub fn compatibilityStandingDeadPartitionParameters() StandingDeadPartitionParameters {
    return .{
        .carbon_fraction = .{ 0.0, 0.045, 0.660, 0.295 },
        .nitrogen_weight = .{ 0.020, 0.010, 0.010, 0.020 },
        .phosphorus_weight = .{ 0.0020, 0.0010, 0.0010, 0.0020 },
    };
}

/// STARTQ coarse-woody (CFOP*(5,*)) standing-dead initialization. Nitrogen
/// and phosphorus fractions are normalized with source CNOPC/CPOPC weights.
pub fn standingDeadStorage(
    standing_dead_carbon_g_per_m2: f64,
    cell_area_m2: f64,
    stalk_nitrogen_to_carbon_g_per_g: f64,
    stalk_phosphorus_to_carbon_g_per_g: f64,
    parameters: StandingDeadPartitionParameters,
) !StandingDeadStorage {
    inline for (.{ standing_dead_carbon_g_per_m2, cell_area_m2, stalk_nitrogen_to_carbon_g_per_g, stalk_phosphorus_to_carbon_g_per_g }) |value| if (!std.math.isFinite(value)) return error.NonFiniteStandingDeadInput;
    if (standing_dead_carbon_g_per_m2 < 0 or cell_area_m2 <= 0 or stalk_nitrogen_to_carbon_g_per_g < 0 or stalk_phosphorus_to_carbon_g_per_g < 0) return error.InvalidStandingDeadInput;
    try parameters.validate();
    const kinetics: canopy_photosynthesis.KineticFractions = .{
        .carbon = parameters.carbon_fraction,
        .nitrogen = normalizeWeightedFractions(parameters.carbon_fraction, parameters.nitrogen_weight),
        .phosphorus = normalizeWeightedFractions(parameters.carbon_fraction, parameters.phosphorus_weight),
    };
    try kinetics.validate();
    const carbon_g = standing_dead_carbon_g_per_m2 * cell_area_m2;
    const result: StandingDeadStorage = .{
        .carbon_g = carbon_g,
        .nitrogen_g = carbon_g * stalk_nitrogen_to_carbon_g_per_g,
        .phosphorus_g = carbon_g * stalk_phosphorus_to_carbon_g_per_g,
        .kinetics = kinetics,
    };
    inline for (.{ result.carbon_g, result.nitrogen_g, result.phosphorus_g }) |value| if (!std.math.isFinite(value)) return error.NonFiniteStandingDeadResult;
    return result;
}

pub fn initializeStandingDeadStorage(state: *canopy_photosynthesis.State, plant: usize, storage: StandingDeadStorage) !void {
    if (plant >= state.plant_standing_dead_carbon_g.len) return error.CanopyPlantIndexOutOfBounds;
    try storage.kinetics.validate();
    inline for (.{ storage.carbon_g, storage.nitrogen_g, storage.phosphorus_g }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteStandingDeadInput;
        if (value < 0) return error.InvalidStandingDeadInput;
    }
    state.plant_standing_dead_carbon_g[plant] = storage.carbon_g;
    state.plant_standing_dead_nitrogen_g[plant] = storage.nitrogen_g;
    state.plant_standing_dead_phosphorus_g[plant] = storage.phosphorus_g;
    const first = plant * 4;
    for (0..4) |kinetic| {
        state.plant_standing_dead_carbon_by_kinetic_g[first + kinetic] = storage.carbon_g * storage.kinetics.carbon[kinetic];
        state.plant_standing_dead_nitrogen_by_kinetic_g[first + kinetic] = storage.nitrogen_g * storage.kinetics.nitrogen[kinetic];
        state.plant_standing_dead_phosphorus_by_kinetic_g[first + kinetic] = storage.phosphorus_g * storage.kinetics.phosphorus[kinetic];
    }
}

fn normalizeWeightedFractions(base: [4]f64, weights: [4]f64) [4]f64 {
    var denominator: f64 = 0;
    for (base, weights) |fraction, weight| denominator += fraction * weight;
    var result: [4]f64 = undefined;
    for (&result, base, weights) |*fraction, source, weight| fraction.* = source * weight / denominator;
    return result;
}

pub const PlantHeatWaterParameters = struct {
    kelvin_offset_k: f64,
    vapor_pressure_numerator_kpa_k: f64,
    initial_relative_humidity: f64,
    vapor_pressure_exponent_temperature_k: f64,
    vapor_pressure_reference_inverse_temperature_per_k: f64,
    initial_total_water_potential_megapascal: f64,

    pub fn validate(self: PlantHeatWaterParameters) !void {
        inline for (@typeInfo(PlantHeatWaterParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.NonFinitePlantHeatWaterParameter;
        if (self.kelvin_offset_k <= 0 or self.vapor_pressure_numerator_kpa_k <= 0 or self.initial_relative_humidity < 0 or self.initial_relative_humidity > 1 or self.vapor_pressure_exponent_temperature_k <= 0 or self.vapor_pressure_reference_inverse_temperature_per_k <= 0 or self.initial_total_water_potential_megapascal > 0) return error.InvalidPlantHeatWaterParameter;
    }
};

pub fn compatibilityPlantHeatWaterParameters() PlantHeatWaterParameters {
    return .{
        .kelvin_offset_k = 273.15,
        .vapor_pressure_numerator_kpa_k = 2.173e-3,
        .initial_relative_humidity = 0.61,
        .vapor_pressure_exponent_temperature_k = 5360.0,
        .vapor_pressure_reference_inverse_temperature_per_k = 3.661e-3,
        .initial_total_water_potential_megapascal = -1.0e-3,
    };
}

pub fn initializePlantHeatAndWater(
    plants: *PlantState,
    canopy: *canopy_photosynthesis.State,
    plant: usize,
    mean_annual_air_temperature_c: f64,
    leaf_osmotic_potential_at_zero_total_megapascal: f64,
    parameters: PlantHeatWaterParameters,
) !void {
    try parameters.validate();
    inline for (.{ mean_annual_air_temperature_c, leaf_osmotic_potential_at_zero_total_megapascal }) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantHeatWaterInput;
    if (plant >= plants.canopy_temperature_k.len or plant >= canopy.plant_canopy_aerodynamic_temperature_k.len) return error.CanopyPlantIndexOutOfBounds;
    const temperature_k = mean_annual_air_temperature_c + parameters.kelvin_offset_k;
    if (!std.math.isFinite(temperature_k) or temperature_k <= 0) return error.InvalidPlantTemperature;
    const aerodynamic_vapor_pressure_kpa = parameters.vapor_pressure_numerator_kpa_k / temperature_k * parameters.initial_relative_humidity * @exp(parameters.vapor_pressure_exponent_temperature_k * (parameters.vapor_pressure_reference_inverse_temperature_per_k - 1.0 / temperature_k));
    if (!std.math.isFinite(aerodynamic_vapor_pressure_kpa) or aerodynamic_vapor_pressure_kpa < 0) return error.NonFinitePlantHeatWaterResult;
    const total_water_potential_megapascal = parameters.initial_total_water_potential_megapascal;
    const osmotic_potential_megapascal = leaf_osmotic_potential_at_zero_total_megapascal + total_water_potential_megapascal;
    const turgor_potential_megapascal = @max(0.0, total_water_potential_megapascal - osmotic_potential_megapascal);

    plants.canopy_temperature_k[plant] = temperature_k;
    plants.canopy_water_potential_megapascal[plant] = total_water_potential_megapascal;
    canopy.plant_canopy_aerodynamic_temperature_k[plant] = temperature_k;
    canopy.plant_canopy_aerodynamic_vapor_pressure_kpa[plant] = aerodynamic_vapor_pressure_kpa;
    canopy.plant_standing_dead_aerodynamic_temperature_k[plant] = temperature_k;
    canopy.plant_standing_dead_aerodynamic_vapor_pressure_kpa[plant] = aerodynamic_vapor_pressure_kpa;
    canopy.plant_standing_dead_surface_temperature_k[plant] = temperature_k;
    canopy.plant_phenology_temperature_k[plant] = temperature_k;
    canopy.plant_canopy_osmotic_potential_megapascal[plant] = osmotic_potential_megapascal;
    canopy.plant_canopy_turgor_potential_megapascal[plant] = turgor_potential_megapascal;
    canopy.plant_stored_energy_megajoules[plant] = 0;
    canopy.plant_transpiration_m3_per_h[plant] = 0;
}

pub const ConcurrentNodeSettings = struct {
    perennial_node_scaling: f64,
    maximum_concurrently_growing_nodes: usize,
};

pub const AdjustedPhenology = struct {
    node_initiation_per_h: f64,
    leaf_appearance_per_h: f64,
    floral_initiation_node_count_after_seed: f64,
    seed_initial_node_count: f64,
};

pub const PhenologyInitializationParameters = struct {
    perennial_input_scale: f64,
    minimum_perennial_node_scaling: f64,
    perennial_maximum_concurrently_growing_nodes: usize,
    early_maturity_group_maximum: f64,
    intermediate_maturity_group_maximum: f64,
    early_maximum_concurrently_growing_nodes: usize,
    intermediate_maximum_concurrently_growing_nodes: usize,
    late_maximum_concurrently_growing_nodes: usize,

    pub fn validate(self: PhenologyInitializationParameters) !void {
        inline for (.{ self.perennial_input_scale, self.minimum_perennial_node_scaling, self.early_maturity_group_maximum, self.intermediate_maturity_group_maximum }) |value| if (!std.math.isFinite(value)) return error.NonFinitePhenologyInitializationParameter;
        if (self.perennial_input_scale <= 0 or self.minimum_perennial_node_scaling <= 0 or self.early_maturity_group_maximum < 0 or self.intermediate_maturity_group_maximum < self.early_maturity_group_maximum or self.perennial_maximum_concurrently_growing_nodes == 0 or self.early_maximum_concurrently_growing_nodes == 0 or self.intermediate_maximum_concurrently_growing_nodes == 0 or self.late_maximum_concurrently_growing_nodes == 0) return error.InvalidPhenologyInitializationParameter;
    }
};

pub fn compatibilityPhenologyInitializationParameters() PhenologyInitializationParameters {
    return .{
        .perennial_input_scale = 0.005,
        .minimum_perennial_node_scaling = 1,
        .perennial_maximum_concurrently_growing_nodes = 24,
        .early_maturity_group_maximum = 10,
        .intermediate_maturity_group_maximum = 15,
        .early_maximum_concurrently_growing_nodes = 3,
        .intermediate_maximum_concurrently_growing_nodes = 4,
        .late_maximum_concurrently_growing_nodes = 5,
    };
}

/// READQ applies the perennial 0.005 scaling before STARTQ initializes branch
/// maturity and seed stages. Keeping this conversion explicit prevents raw PFT
/// values from entering hourly phenology.
pub fn adjustedPhenology(traits: @import("../../state/plant_traits.zig").PlantTraits, parameters: PhenologyInitializationParameters) !AdjustedPhenology {
    try parameters.validate();
    const source = traits.phenology;
    inline for (.{ source.node_initiation_per_h, source.leaf_appearance_per_h, source.floral_initiation_node_count, source.seed_initial_node_count }) |value| if (!std.math.isFinite(value)) return error.NonFinitePhenologyInput;
    const scale: f64 = if (traits.functional_type.aboveground_turnover_type != 0) parameters.perennial_input_scale else 1;
    const result: AdjustedPhenology = .{
        .node_initiation_per_h = source.node_initiation_per_h * scale,
        .leaf_appearance_per_h = source.leaf_appearance_per_h * scale,
        .floral_initiation_node_count_after_seed = (source.floral_initiation_node_count - source.seed_initial_node_count) * scale,
        .seed_initial_node_count = source.seed_initial_node_count * scale,
    };
    inline for (@typeInfo(AdjustedPhenology).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFinitePhenologyResult;
    if (result.node_initiation_per_h < 0 or result.leaf_appearance_per_h <= 0 or result.floral_initiation_node_count_after_seed < 0 or result.seed_initial_node_count < 0) return error.InvalidPhenologyResult;
    return result;
}

pub fn concurrentNodeSettings(aboveground_turnover_type: u8, leaf_appearance_per_h: f64, maturity_group: f64, parameters: PhenologyInitializationParameters) !ConcurrentNodeSettings {
    try parameters.validate();
    if (!std.math.isFinite(leaf_appearance_per_h) or !std.math.isFinite(maturity_group) or leaf_appearance_per_h <= 0) return error.InvalidConcurrentNodeInput;
    if (aboveground_turnover_type != 0) return .{ .perennial_node_scaling = @max(parameters.minimum_perennial_node_scaling, parameters.perennial_input_scale / leaf_appearance_per_h), .maximum_concurrently_growing_nodes = parameters.perennial_maximum_concurrently_growing_nodes };
    return .{
        .perennial_node_scaling = 1,
        .maximum_concurrently_growing_nodes = if (maturity_group <= parameters.early_maturity_group_maximum) parameters.early_maximum_concurrently_growing_nodes else if (maturity_group <= parameters.intermediate_maturity_group_maximum) parameters.intermediate_maximum_concurrently_growing_nodes else parameters.late_maximum_concurrently_growing_nodes,
    };
}

pub const ThermalAcclimation = struct {
    adaptation_offset_c: f64,
    leafout_threshold_c: f64,
    leafoff_threshold_c: f64,
    seed_set_high_temperature_c: f64,
    seed_set_loss_fraction_per_c_h: f64,
};

pub const ThermalAcclimationParameters = struct {
    adaptation_zone_pivot: f64,
    cold_zone_offset_per_zone_c: f64,
    warm_zone_offset_per_zone_c: f64,
    base_leafout_threshold_c: f64,
    base_leafoff_threshold_c: f64,
    maximum_leafoff_threshold_c: f64,
    soybean_c3_seed_set_base_c: f64,
    other_c3_seed_set_base_c: f64,
    c4_seed_set_base_c: f64,
    seed_set_adaptation_increment_c_per_zone: f64,
    soybean_loss_fraction_per_c_h: f64,
    other_c3_loss_fraction_per_c_h: f64,
    maize_loss_fraction_per_c_h: f64,
    other_c4_loss_fraction_per_c_h: f64,

    pub fn validate(self: ThermalAcclimationParameters) !void {
        inline for (@typeInfo(ThermalAcclimationParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.InvalidThermalAcclimationParameters;
        if (self.adaptation_zone_pivot < 0 or self.cold_zone_offset_per_zone_c < 0 or self.warm_zone_offset_per_zone_c < 0 or self.maximum_leafoff_threshold_c < self.base_leafoff_threshold_c or self.seed_set_adaptation_increment_c_per_zone < 0 or self.soybean_loss_fraction_per_c_h < 0 or self.other_c3_loss_fraction_per_c_h < 0 or self.maize_loss_fraction_per_c_h < 0 or self.other_c4_loss_fraction_per_c_h < 0) return error.InvalidThermalAcclimationParameters;
    }
};

pub fn compatibilityThermalAcclimationParameters() ThermalAcclimationParameters {
    return .{ .adaptation_zone_pivot = 3, .cold_zone_offset_per_zone_c = 2.5, .warm_zone_offset_per_zone_c = 1.25, .base_leafout_threshold_c = 5, .base_leafoff_threshold_c = 12.5, .maximum_leafoff_threshold_c = 15, .soybean_c3_seed_set_base_c = 35, .other_c3_seed_set_base_c = 27.5, .c4_seed_set_base_c = 30, .seed_set_adaptation_increment_c_per_zone = 2, .soybean_loss_fraction_per_c_h = 0.002, .other_c3_loss_fraction_per_c_h = 0.005, .maize_loss_fraction_per_c_h = 0.010, .other_c4_loss_fraction_per_c_h = 0.002 };
}

pub fn thermalAcclimation(plant_profile_name: []const u8, photosynthesis_pathway: u8, initial_adaptation_zone: f64, parameters: ThermalAcclimationParameters) !ThermalAcclimation {
    try parameters.validate();
    if (!std.math.isFinite(initial_adaptation_zone) or (photosynthesis_pathway != 3 and photosynthesis_pathway != 4)) return error.InvalidThermalAcclimationInput;
    const offset = if (initial_adaptation_zone <= parameters.adaptation_zone_pivot) parameters.cold_zone_offset_per_zone_c * (parameters.adaptation_zone_pivot - initial_adaptation_zone) else parameters.warm_zone_offset_per_zone_c * (parameters.adaptation_zone_pivot - initial_adaptation_zone);
    const is_soybean = startsWithIgnoreCase(plant_profile_name, "soyb");
    const is_maize = startsWithIgnoreCase(plant_profile_name, "maiz");
    return .{
        .adaptation_offset_c = offset,
        .leafout_threshold_c = parameters.base_leafout_threshold_c - offset,
        .leafoff_threshold_c = @min(parameters.maximum_leafoff_threshold_c, parameters.base_leafoff_threshold_c - offset),
        .seed_set_high_temperature_c = if (photosynthesis_pathway == 3) (if (is_soybean) parameters.soybean_c3_seed_set_base_c else parameters.other_c3_seed_set_base_c) + parameters.seed_set_adaptation_increment_c_per_zone * initial_adaptation_zone else parameters.c4_seed_set_base_c + parameters.seed_set_adaptation_increment_c_per_zone * initial_adaptation_zone,
        .seed_set_loss_fraction_per_c_h = if (photosynthesis_pathway == 3) (if (is_soybean) parameters.soybean_loss_fraction_per_c_h else parameters.other_c3_loss_fraction_per_c_h) else if (is_maize) parameters.maize_loss_fraction_per_c_h else parameters.other_c4_loss_fraction_per_c_h,
    };
}

pub fn initializeThermalAcclimation(state: *canopy_photosynthesis.State, plant: usize, values: ThermalAcclimation) !void {
    if (plant >= state.plant_thermal_adaptation_offset_c.len) return error.CanopyPlantIndexOutOfBounds;
    inline for (@typeInfo(ThermalAcclimation).@"struct".fields) |field| if (!std.math.isFinite(@field(values, field.name))) return error.NonFiniteThermalAcclimation;
    state.plant_thermal_adaptation_offset_c[plant] = values.adaptation_offset_c;
    state.plant_leafout_threshold_c[plant] = values.leafout_threshold_c;
    state.plant_leafoff_threshold_c[plant] = values.leafoff_threshold_c;
    state.plant_seed_set_high_temperature_c[plant] = values.seed_set_high_temperature_c;
    state.plant_seed_set_loss_fraction_per_c_h[plant] = values.seed_set_loss_fraction_per_c_h;
}

pub const SeedGeometry = struct {
    volume_m3: f64,
    length_m: f64,
    surface_area_m2: f64,
};

pub const PlantGeometryParameters = struct {
    seed_volume_m3_per_g_c: f64,
    seed_length_multiplier: f64,
    seed_shape_volume_factor: f64,
    seed_pi: f64,
    seed_length_exponent: f64,
    seed_surface_area_multiplier: f64,
    root_volume_numerator_m3_per_g_c: f64,
    root_dry_matter_fraction: f64,
    root_porosity_floor: f64,
    root_pi: f64,

    pub fn validate(self: PlantGeometryParameters) !void {
        inline for (@typeInfo(PlantGeometryParameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value <= 0) return error.InvalidPlantGeometryParameter;
        }
        if (self.root_porosity_floor > 1) return error.InvalidPlantGeometryParameter;
    }
};

pub fn compatibilityPlantGeometryParameters() PlantGeometryParameters {
    return .{
        .seed_volume_m3_per_g_c = 5.0e-6,
        .seed_length_multiplier = 2.0,
        .seed_shape_volume_factor = 0.75,
        .seed_pi = 3.1416,
        .seed_length_exponent = 0.33,
        .seed_surface_area_multiplier = 4.0,
        .root_volume_numerator_m3_per_g_c = 1.0e-6,
        .root_dry_matter_fraction = 0.05,
        .root_porosity_floor = 0.01,
        .root_pi = 3.142,
    };
}

pub fn seedGeometry(seed_carbon_g: f64, parameters: PlantGeometryParameters) !SeedGeometry {
    try parameters.validate();
    if (!std.math.isFinite(seed_carbon_g) or seed_carbon_g < 0) return error.InvalidSeedCarbon;
    const volume = seed_carbon_g * parameters.seed_volume_m3_per_g_c;
    const length = if (volume > 0) parameters.seed_length_multiplier * std.math.pow(f64, parameters.seed_shape_volume_factor * volume / parameters.seed_pi, parameters.seed_length_exponent) else 0;
    return .{ .volume_m3 = volume, .length_m = length, .surface_area_m2 = parameters.seed_surface_area_multiplier * parameters.seed_pi * std.math.pow(f64, length / parameters.seed_length_multiplier, 2) };
}

pub fn plantingLayer(seeding_depth_m: f64, layer_bottom_depth_m: []const f64) !usize {
    if (!std.math.isFinite(seeding_depth_m) or seeding_depth_m < 0 or layer_bottom_depth_m.len == 0) return error.InvalidPlantingDepth;
    var previous_bottom: f64 = 0;
    for (layer_bottom_depth_m, 0..) |bottom, layer| {
        if (!std.math.isFinite(bottom) or bottom <= previous_bottom) return error.InvalidSoilLayerDepths;
        if (seeding_depth_m >= previous_bottom and seeding_depth_m < bottom) return layer;
        previous_bottom = bottom;
    }
    return error.SeedingDepthBelowSoilProfile;
}

pub const RootGeometry = struct {
    radial_diffusion_log_path: f64,
    volume_m3_per_g_c: f64,
    primary_specific_length_m_per_g_c: f64,
    secondary_specific_length_m_per_g_c: f64,
    primary_cross_section_m2: f64,
    secondary_cross_section_m2: f64,
};

pub fn rootGeometry(porosity_fraction: f64, primary_radius_m: f64, secondary_radius_m: f64, parameters: PlantGeometryParameters) !RootGeometry {
    try parameters.validate();
    inline for (.{ porosity_fraction, primary_radius_m, secondary_radius_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootGeometryInput;
    if (porosity_fraction < 0 or porosity_fraction >= 1 or primary_radius_m <= 0 or secondary_radius_m <= 0) return error.InvalidRootGeometryInput;
    const volume_per_carbon = parameters.root_volume_numerator_m3_per_g_c / (parameters.root_dry_matter_fraction * (1.0 - porosity_fraction));
    const primary_area = parameters.root_pi * primary_radius_m * primary_radius_m;
    const secondary_area = parameters.root_pi * secondary_radius_m * secondary_radius_m;
    return .{
        .radial_diffusion_log_path = @log(1.0 / @sqrt(@max(parameters.root_porosity_floor, porosity_fraction))),
        .volume_m3_per_g_c = volume_per_carbon,
        .primary_specific_length_m_per_g_c = volume_per_carbon / primary_area,
        .secondary_specific_length_m_per_g_c = volume_per_carbon / secondary_area,
        .primary_cross_section_m2 = primary_area,
        .secondary_cross_section_m2 = secondary_area,
    };
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

test "STARTQ concurrent nodes and thermal adaptation preserve source branches" {
    const parameters = compatibilityPhenologyInitializationParameters();
    try std.testing.expectEqual(@as(usize, 24), (try concurrentNodeSettings(2, 0.0025, 20, parameters)).maximum_concurrently_growing_nodes);
    try std.testing.expectEqual(@as(usize, 3), (try concurrentNodeSettings(0, 0.01, 10, parameters)).maximum_concurrently_growing_nodes);
    try std.testing.expectEqual(@as(usize, 4), (try concurrentNodeSettings(0, 0.01, 12, parameters)).maximum_concurrently_growing_nodes);
    try std.testing.expectEqual(@as(usize, 5), (try concurrentNodeSettings(0, 0.01, 16, parameters)).maximum_concurrently_growing_nodes);
    const soybean = try thermalAcclimation("SOYB99", 3, 2, compatibilityThermalAcclimationParameters());
    try std.testing.expectApproxEqAbs(39.0, soybean.seed_set_high_temperature_c, 1e-14);
    try std.testing.expectApproxEqAbs(0.002, soybean.seed_set_loss_fraction_per_c_h, 1e-14);
    const maize = try thermalAcclimation("Maiz33", 4, 2, compatibilityThermalAcclimationParameters());
    try std.testing.expectApproxEqAbs(34.0, maize.seed_set_high_temperature_c, 1e-14);
    try std.testing.expectApproxEqAbs(0.010, maize.seed_set_loss_fraction_per_c_h, 1e-14);
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer state.deinit();
    try initializeThermalAcclimation(&state, 0, maize);
    try std.testing.expectEqual(maize.adaptation_offset_c, state.plant_thermal_adaptation_offset_c[0]);
    try std.testing.expectEqual(maize.leafoff_threshold_c, state.plant_leafoff_threshold_c[0]);
    try std.testing.expectEqual(maize.seed_set_loss_fraction_per_c_h, state.plant_seed_set_loss_fraction_per_c_h[0]);
}

test "READQ perennial scaling feeds STARTQ maturity and seed stages" {
    var traits = std.mem.zeroes(@import("../../state/plant_traits.zig").PlantTraits);
    traits.functional_type.aboveground_turnover_type = 2;
    traits.phenology.node_initiation_per_h = 2;
    traits.phenology.leaf_appearance_per_h = 4;
    traits.phenology.floral_initiation_node_count = 20;
    traits.phenology.seed_initial_node_count = 2;
    const adjusted = try adjustedPhenology(traits, compatibilityPhenologyInitializationParameters());
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), adjusted.node_initiation_per_h, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), adjusted.leaf_appearance_per_h, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.09), adjusted.floral_initiation_node_count_after_seed, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), adjusted.seed_initial_node_count, 1e-15);
}

test "runtime initial phenology controls scaling and concurrent topology" {
    var traits = std.mem.zeroes(@import("../../state/plant_traits.zig").PlantTraits);
    traits.functional_type.aboveground_turnover_type = 2;
    traits.phenology.node_initiation_per_h = 2;
    traits.phenology.leaf_appearance_per_h = 4;
    traits.phenology.floral_initiation_node_count = 20;
    traits.phenology.seed_initial_node_count = 2;
    var parameters = compatibilityPhenologyInitializationParameters();
    parameters.perennial_input_scale = 0.01;
    parameters.perennial_maximum_concurrently_growing_nodes = 36;
    const adjusted = try adjustedPhenology(traits, parameters);
    const concurrent = try concurrentNodeSettings(2, adjusted.leaf_appearance_per_h, adjusted.floral_initiation_node_count_after_seed, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), adjusted.node_initiation_per_h, 1e-15);
    try std.testing.expectEqual(@as(usize, 36), concurrent.maximum_concurrently_growing_nodes);
}

test "STARTQ seed and root geometries and planting layer retain equations" {
    const geometry_parameters = compatibilityPlantGeometryParameters();
    const seed = try seedGeometry(0.2, geometry_parameters);
    try std.testing.expectApproxEqRel(1.0e-6, seed.volume_m3, 1e-14);
    const bottoms = [_]f64{ 0.05, 0.15, 0.30 };
    try std.testing.expectEqual(@as(usize, 1), try plantingLayer(0.10, &bottoms));
    const root = try rootGeometry(0.2, 0.001, 0.0005, geometry_parameters);
    try std.testing.expectApproxEqRel(1.0e-6 / 0.04, root.volume_m3_per_g_c, 1e-14);
    try std.testing.expectApproxEqRel(3.142e-6, root.primary_cross_section_m2, 1e-14);
}

test "STARTQ runtime geometry coefficients alter seed and root dimensions" {
    var parameters = compatibilityPlantGeometryParameters();
    parameters.seed_volume_m3_per_g_c = 1.0e-5;
    parameters.root_volume_numerator_m3_per_g_c = 2.0e-6;
    parameters.root_pi = 3.0;
    const seed = try seedGeometry(0.2, parameters);
    const root = try rootGeometry(0.2, 0.001, 0.0005, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0e-6), seed.volume_m3, 1e-20);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0e-5), root.volume_m3_per_g_c, 1e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0e-6), root.primary_cross_section_m2, 1e-18);
}

test "STARTQ seed storage scales with runtime population and cell area" {
    const storage = try seedStorage(0.2, 6.0, 25.0, 0.04, 0.006);
    try std.testing.expectApproxEqAbs(30.0, storage.carbon_g, 1e-14);
    try std.testing.expectApproxEqAbs(1.2, storage.nitrogen_g, 1e-14);
    try std.testing.expectApproxEqAbs(0.18, storage.phosphorus_g, 1e-14);

    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer state.deinit();
    try initializeSeedStorage(&state, 0, storage);
    try std.testing.expectEqual(storage.carbon_g, state.plant_seed_storage_carbon_g[0]);
    try std.testing.expectEqual(storage.nitrogen_g, state.plant_seed_storage_nitrogen_g[0]);
    try std.testing.expectEqual(storage.phosphorus_g, state.plant_seed_storage_phosphorus_g[0]);
}

test "STARTQ shoot controls preserve population resistance and C3 C4 oxygen branches" {
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 7, &.{ 1, 1, 1, 1, 1, 1, 1 }, &.{ 1, 1, 1, 1, 1, 1, 1 }, &.{ 1, 1, 1, 1, 1, 1, 1 });
    defer state.deinit();
    try initializeShootControls(&state, 6, 4, 25, 3600, 4, compatibilityShootControlParameters());
    try std.testing.expectEqual(@as(f64, 4), state.plant_population_per_m2[6]);
    try std.testing.expectEqual(@as(f64, 100), state.plant_population_count[6]);
    try std.testing.expectEqual(@as(f64, 100), state.plant_population_change_count[6]);
    try std.testing.expectEqual(@as(f64, 1), state.plant_cuticular_water_vapor_resistance_h_per_m[6]);
    try std.testing.expectEqual(@as(f64, 5616), state.plant_cuticular_co2_resistance_s_per_m[6]);
    try std.testing.expectEqual(@as(f64, 3.96e5), state.plant_intercellular_oxygen_umol_per_mol[6]);
    try initializeShootControls(&state, 0, 1, 1, 1, 3, compatibilityShootControlParameters());
    try std.testing.expectEqual(@as(f64, 2.10e5), state.plant_intercellular_oxygen_umol_per_mol[0]);
}

test "STARTQ standing dead uses coarse-wood C N P kinetic partitions" {
    const storage = try standingDeadStorage(2.0, 25.0, 0.01, 0.002, compatibilityStandingDeadPartitionParameters());
    try std.testing.expectEqual(@as(f64, 50), storage.carbon_g);
    try std.testing.expectEqual(@as(f64, 0.5), storage.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 0.1), storage.phosphorus_g);
    try std.testing.expectApproxEqAbs(0.0, storage.kinetics.carbon[0], 1e-14);
    try std.testing.expectApproxEqAbs(0.045, storage.kinetics.carbon[1], 1e-14);

    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer state.deinit();
    try initializeStandingDeadStorage(&state, 0, storage);
    var carbon_sum: f64 = 0;
    var nitrogen_sum: f64 = 0;
    var phosphorus_sum: f64 = 0;
    for (0..4) |kinetic| {
        carbon_sum += state.plant_standing_dead_carbon_by_kinetic_g[kinetic];
        nitrogen_sum += state.plant_standing_dead_nitrogen_by_kinetic_g[kinetic];
        phosphorus_sum += state.plant_standing_dead_phosphorus_by_kinetic_g[kinetic];
    }
    try std.testing.expectApproxEqAbs(storage.carbon_g, carbon_sum, 1e-12);
    try std.testing.expectApproxEqAbs(storage.nitrogen_g, nitrogen_sum, 1e-12);
    try std.testing.expectApproxEqAbs(storage.phosphorus_g, phosphorus_sum, 1e-12);
}

test "STARTQ standing dead partition coefficients alter all runtime element fractions" {
    const parameters: StandingDeadPartitionParameters = .{
        .carbon_fraction = .{ 0.1, 0.2, 0.3, 0.4 },
        .nitrogen_weight = .{ 1, 2, 3, 4 },
        .phosphorus_weight = .{ 4, 3, 2, 1 },
    };
    const storage = try standingDeadStorage(1, 10, 0.1, 0.01, parameters);
    try std.testing.expectEqual(parameters.carbon_fraction, storage.kinetics.carbon);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 30.0), storage.kinetics.nitrogen[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 15.0), storage.kinetics.nitrogen[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), storage.kinetics.phosphorus[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), storage.kinetics.phosphorus[3], 1e-15);
}

test "STARTQ plant heat and water status uses mean annual air temperature" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 });
    var plants = try PlantState.init(std.testing.allocator, config);
    defer plants.deinit();
    var canopy = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    try initializePlantHeatAndWater(&plants, &canopy, 0, 10.0, -1.5, compatibilityPlantHeatWaterParameters());
    try std.testing.expectApproxEqAbs(283.15, plants.canopy_temperature_k[0], 1e-12);
    try std.testing.expectEqual(@as(f64, -0.001), plants.canopy_water_potential_megapascal[0]);
    try std.testing.expectApproxEqAbs(-1.501, canopy.plant_canopy_osmotic_potential_megapascal[0], 1e-14);
    try std.testing.expectApproxEqAbs(1.5, canopy.plant_canopy_turgor_potential_megapascal[0], 1e-14);
    try std.testing.expect(canopy.plant_canopy_aerodynamic_vapor_pressure_kpa[0] > 0);
}

test "cold start and reseed preserve divergent per-cell mean annual temperatures" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 });
    var plants = try PlantState.init(std.testing.allocator, config);
    defer plants.deinit();
    var canopy = try canopy_photosynthesis.State.init(
        std.testing.allocator,
        2,
        1,
        &.{ 1, 1 },
        &.{ 1, 1 },
        &.{ 1, 1 },
    );
    defer canopy.deinit();
    const parameters = compatibilityPlantHeatWaterParameters();

    try initializePlantHeatAndWater(&plants, &canopy, 0, -8, -1.5, parameters);
    try initializePlantHeatAndWater(&plants, &canopy, 1, 19, -1.5, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 265.15), plants.canopy_temperature_k[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 292.15), plants.canopy_temperature_k[1], 1e-12);

    // Reinitializing the second cell is the reseed path; it must not inherit
    // cell zero's site climate or overwrite cell zero's persistent state.
    try initializePlantHeatAndWater(&plants, &canopy, 1, 24, -1.5, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 265.15), plants.canopy_temperature_k[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 297.15), plants.canopy_temperature_k[1], 1e-12);
    try std.testing.expectEqual(
        plants.canopy_temperature_k[1],
        canopy.plant_canopy_aerodynamic_temperature_k[1],
    );
}

test "STARTQ runtime heat water controls determine initial canopy state" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 });
    var plants = try PlantState.init(std.testing.allocator, config);
    defer plants.deinit();
    var canopy = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{0});
    defer canopy.deinit();
    var parameters = compatibilityPlantHeatWaterParameters();
    parameters.kelvin_offset_k = 270;
    parameters.initial_total_water_potential_megapascal = -0.02;
    parameters.initial_relative_humidity = 0.7;
    try initializePlantHeatAndWater(&plants, &canopy, 0, 10, -1.5, parameters);
    try std.testing.expectEqual(@as(f64, 280), plants.canopy_temperature_k[0]);
    try std.testing.expectEqual(@as(f64, -0.02), plants.canopy_water_potential_megapascal[0]);
    try std.testing.expectApproxEqAbs(@as(f64, -1.52), canopy.plant_canopy_osmotic_potential_megapascal[0], 1e-15);
    try std.testing.expect(canopy.plant_canopy_aerodynamic_vapor_pressure_kpa[0] > 0);
}
