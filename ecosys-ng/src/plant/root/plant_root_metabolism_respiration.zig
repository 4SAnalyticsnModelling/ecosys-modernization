//! `plant_root_metabolism` declarations: respiration.
//!
//! Split out of `plant_root_metabolism.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const RootState = @import("plant_root_system.zig").State;
const NutrientResult = @import("plant_root_nutrient_uptake.zig").Result;
const root_domain_count = @import("plant_root_system.zig").biological_domain_count;
const group_growth = @import("plant_root_metabolism_growth.zig");

pub const Respiration = struct {
    actual_g_c: f64,
    oxygen_unlimited_g_c: f64,
    carbon_unlimited_g_c: f64,
};

/// GROSUB `RGFNP` with STARTQ `CNRTS=CNRT*DMRT` and
/// `CPRTS=CPRT*DMRT`. The returned quantity is growth respiration, not
/// structural root growth.
pub fn nutrientLimitedRootGrowthRespiration(
    nonstructural_nitrogen_g_n: f64,
    nonstructural_phosphorus_g_p: f64,
    active_root_fraction: f64,
    respiration_fraction: f64,
    growth_yield_g_c_per_g_c: f64,
    nitrogen_to_carbon_g_n_per_g_c: f64,
    phosphorus_to_carbon_g_p_per_g_c: f64,
) !f64 {
    inline for (.{
        nonstructural_nitrogen_g_n,
        nonstructural_phosphorus_g_p,
        active_root_fraction,
        respiration_fraction,
        growth_yield_g_c_per_g_c,
        nitrogen_to_carbon_g_n_per_g_c,
        phosphorus_to_carbon_g_p_per_g_c,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootGrowthNutrientLimitInput;
    if (nonstructural_nitrogen_g_n < 0 or nonstructural_phosphorus_g_p < 0 or active_root_fraction < 0 or active_root_fraction > 1 or respiration_fraction <= 0 or growth_yield_g_c_per_g_c <= 0 or nitrogen_to_carbon_g_n_per_g_c <= 0 or phosphorus_to_carbon_g_p_per_g_c <= 0) return error.InvalidRootGrowthNutrientLimitInput;
    const result = @min(
        nonstructural_nitrogen_g_n * respiration_fraction * active_root_fraction /
            (nitrogen_to_carbon_g_n_per_g_c * growth_yield_g_c_per_g_c),
        nonstructural_phosphorus_g_p * respiration_fraction * active_root_fraction /
            (phosphorus_to_carbon_g_p_per_g_c * growth_yield_g_c_per_g_c),
    );
    if (!std.math.isFinite(result)) return error.NonFiniteRootGrowthNutrientLimitResult;
    return result;
}

pub const RootEnvironmentResponses = struct {
    maintenance_temperature: f64,
    acidity: f64,
    growth_water: f64,
    maintenance_water: f64,
    extension_water: f64,
    scaled_penetration_resistance_megapascal: f64,
};

/// GROSUB 5985--5995 lower-layer scan. Layers at or below the minimum
/// thickness are skipped, except that the bottom layer is always selected.
pub fn nextLowerRootLayer(
    layer_thickness_m: []const f64,
    current_layer: usize,
    minimum_active_layer_thickness_m: f64,
) !usize {
    if (layer_thickness_m.len == 0 or current_layer >= layer_thickness_m.len)
        return error.RootLayerIndexOutOfBounds;
    if (!std.math.isFinite(minimum_active_layer_thickness_m) or minimum_active_layer_thickness_m < 0)
        return error.InvalidRootLayerThickness;
    for (layer_thickness_m) |thickness_m|
        if (!std.math.isFinite(thickness_m) or thickness_m < 0)
            return error.InvalidRootLayerThickness;
    if (current_layer + 1 >= layer_thickness_m.len) return error.NoLowerRootLayer;
    const bottom_layer = layer_thickness_m.len - 1;
    for (current_layer + 1..layer_thickness_m.len) |candidate| {
        if (layer_thickness_m[candidate] > minimum_active_layer_thickness_m or candidate == bottom_layer)
            return candidate;
    }
    unreachable;
}

/// GROSUB TFN6, WFNRT, WFNRG/WFNRR and HOUR1 FPH derived directly from
/// live dimensional soil/root state.
pub fn rootEnvironmentResponses(
    parameters: group_growth.SecondaryRootParameters,
    soil_temperature_k: f64,
    thermal_adaptation_offset_k: f64,
    soil_ph: f64,
    root_total_water_potential_megapascal: f64,
    root_turgor_water_potential_megapascal: f64,
    minimum_extension_water_potential_megapascal: f64,
    soil_penetration_resistance_megapascal: f64,
    secondary_root_radius_m: f64,
    shallow_root_profile: bool,
) !RootEnvironmentResponses {
    try parameters.validate();
    inline for (.{ soil_temperature_k, thermal_adaptation_offset_k, soil_ph, root_total_water_potential_megapascal, root_turgor_water_potential_megapascal, minimum_extension_water_potential_megapascal, soil_penetration_resistance_megapascal, secondary_root_radius_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootEnvironmentInput;
    if (soil_temperature_k <= 0 or soil_penetration_resistance_megapascal < 0 or secondary_root_radius_m < 0) return error.InvalidRootEnvironmentInput;
    const adjusted_temperature_k = soil_temperature_k + thermal_adaptation_offset_k;
    if (adjusted_temperature_k <= 0) return error.InvalidRootEnvironmentInput;
    const gas_temperature_j_per_mol = parameters.maintenance_gas_constant_j_per_mol_k * adjusted_temperature_k;
    const enthalpy_temperature_j_per_mol = parameters.maintenance_enthalpy_j_per_mol_k * adjusted_temperature_k;
    const inactivation = 1 + std.math.exp((parameters.maintenance_low_temperature_inactivation_energy_j_per_mol - enthalpy_temperature_j_per_mol) / gas_temperature_j_per_mol);
    const maintenance_temperature = @min(
        parameters.maximum_maintenance_temperature_response,
        std.math.exp(parameters.maintenance_normalization_log_intercept - parameters.maintenance_activation_energy_j_per_mol / gas_temperature_j_per_mol) / inactivation,
    );
    const hydrogen_activity_mol_per_m3 = 1.0e3 * std.math.pow(f64, 10, -soil_ph);
    const acidity = 1 + @min(parameters.maximum_acidity_enhancement, hydrogen_activity_mol_per_m3 / parameters.acidity_half_effect_hydrogen_activity_mol_per_m3);
    const water_coefficient = if (shallow_root_profile) parameters.shallow_root_water_response_per_megapascal else parameters.deep_root_water_response_per_megapascal;
    const growth_water = std.math.exp(water_coefficient * root_total_water_potential_megapascal);
    const maintenance_water = std.math.pow(f64, growth_water, parameters.maintenance_water_response_exponent);
    const radius_ratio = secondary_root_radius_m / parameters.root_penetration_reference_radius_m;
    const scaled_resistance = soil_penetration_resistance_megapascal * radius_ratio * radius_ratio;
    const extension_water = std.math.clamp(root_turgor_water_potential_megapascal - minimum_extension_water_potential_megapascal - scaled_resistance, 0, 1);
    const result: RootEnvironmentResponses = .{
        .maintenance_temperature = maintenance_temperature,
        .acidity = acidity,
        .growth_water = growth_water,
        .maintenance_water = maintenance_water,
        .extension_water = extension_water,
        .scaled_penetration_resistance_megapascal = scaled_resistance,
    };
    inline for (@typeInfo(RootEnvironmentResponses).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFiniteRootEnvironmentResponse;
    return result;
}

/// STOMATE FDBKX consumed by both shoot carboxylation and GROSUB root
/// substrate respiration.
pub fn annualTerminationFeedback(growth_habit: u8, hours_without_grain_fill: f64, termination_hours: f64) !f64 {
    inline for (.{ hours_without_grain_fill, termination_hours }) |value| if (!std.math.isFinite(value)) return error.NonFiniteAnnualTerminationInput;
    if (hours_without_grain_fill < 0 or termination_hours <= 0) return error.InvalidAnnualTerminationInput;
    return if (growth_habit == 0 and hours_without_grain_fill > 0)
        @max(0, 1 - hours_without_grain_fill / termination_hours)
    else
        1;
}

/// GROSUB 6112--6129 annual physiological-maturity gate.
pub fn rootRespirationActive(
    perennial_growth_habit: bool,
    physiological_maturity_date_is_set: bool,
) bool {
    return perennial_growth_habit or !physiological_maturity_date_is_set;
}

pub const RootRespirationWaterResponses = struct {
    substrate: f64,
    maintenance: f64,
};

/// GROSUB 6115--6125 uses WFNRG for substrate respiration in every PFT.
/// Only maintenance switches to WFNRR outside shallow and drought-deciduous
/// plants.
pub fn sourceRootRespirationWaterResponses(
    root_profile_type: u8,
    leaf_phenology_type: u8,
    growth_water_response: f64,
    maintenance_water_response: f64,
) !RootRespirationWaterResponses {
    if (root_profile_type > 3 or leaf_phenology_type > 5)
        return error.InvalidRootMetabolismPlantCode;
    inline for (.{ growth_water_response, maintenance_water_response }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidRootEnvironmentResponse;
    return .{
        .substrate = growth_water_response,
        .maintenance = if (root_profile_type == 0 or leaf_phenology_type == 2)
            growth_water_response
        else
            maintenance_water_response,
    };
}

/// GROSUB CUPRL/CUPRO/CUPRC. Results are the eight NH4, NO3, H2PO4,
/// and HPO4 band/non-band uptake pools for one root domain and layer.
pub fn nutrientUptakeRespiration(results: []const NutrientResult, respiration_g_c_per_g_element: f64) !Respiration {
    if (results.len != @import("plant_root_nutrient_uptake.zig").nutrient_pool_count) return error.RootNutrientPoolCountMismatch;
    if (!std.math.isFinite(respiration_g_c_per_g_element) or respiration_g_c_per_g_element < 0) return error.InvalidRootNutrientRespirationCoefficient;
    var actual: f64 = 0;
    var oxygen_unlimited: f64 = 0;
    var carbon_unlimited: f64 = 0;
    for (results) |result| {
        inline for (@typeInfo(NutrientResult).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.InvalidRootNutrientRespirationInput;
        actual += result.uptake_g_element;
        oxygen_unlimited += result.oxygen_unlimited_uptake_g_element;
        carbon_unlimited += result.carbon_unlimited_uptake_g_element;
    }
    return .{
        .actual_g_c = respiration_g_c_per_g_element * actual,
        .oxygen_unlimited_g_c = respiration_g_c_per_g_element * oxygen_unlimited,
        .carbon_unlimited_g_c = respiration_g_c_per_g_element * carbon_unlimited,
    };
}
