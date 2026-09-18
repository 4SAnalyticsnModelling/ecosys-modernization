//! `plant_root_metabolism` declarations: growth.
//!
//! Split out of `plant_root_metabolism.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const RootState = @import("plant_root_system.zig").State;
const NutrientResult = @import("plant_root_nutrient_uptake.zig").Result;
const root_domain_count = @import("plant_root_system.zig").biological_domain_count;
const group_respiration = @import("plant_root_metabolism_respiration.zig");

pub const Components = struct {
    maintenance_demand_g_c: f64,
    substrate_respiration_actual_g_c: f64,
    substrate_respiration_oxygen_unlimited_g_c: f64,
    growth_respiration_actual_g_c: f64,
    growth_respiration_oxygen_unlimited_g_c: f64,
    senescence_respiration_actual_g_c: f64,
    senescence_respiration_oxygen_unlimited_g_c: f64,
    nitrogen_assimilation_respiration_actual_g_c: f64,
    nitrogen_assimilation_respiration_oxygen_unlimited_g_c: f64,
};

pub const SecondaryRootParameters = struct {
    maximum_substrate_respiration_fraction_per_h: f64,
    substrate_respiration_half_saturation_g_c_per_g_c: f64,
    nitrogen_feedback_half_saturation_g_n_per_g_c: f64,
    phosphorus_feedback_half_saturation_g_p_per_g_c: f64,
    maintenance_respiration_g_c_per_g_n_h: f64,
    nitrogen_assimilation_respiration_g_c_per_g_n: f64,
    minimum_carbon_recycling_fraction: f64,
    responsive_carbon_recycling_fraction: f64,
    maximum_nitrogen_recycling_fraction: f64,
    maximum_phosphorus_recycling_fraction: f64,
    storage_exchange_fraction_per_h: f64,
    nonwoody_root_fraction_exponent: f64,
    maintenance_gas_constant_j_per_mol_k: f64,
    maintenance_enthalpy_j_per_mol_k: f64,
    maintenance_activation_energy_j_per_mol: f64,
    maintenance_low_temperature_inactivation_energy_j_per_mol: f64,
    maintenance_normalization_log_intercept: f64,
    maximum_maintenance_temperature_response: f64,
    shallow_root_water_response_per_megapascal: f64,
    deep_root_water_response_per_megapascal: f64,
    maintenance_water_response_exponent: f64,
    root_penetration_reference_radius_m: f64,
    acidity_half_effect_hydrogen_activity_mol_per_m3: f64,
    maximum_acidity_enhancement: f64,
    shallow_primary_root_sink_multiplier: f64,
    intermediate_primary_root_sink_multiplier: f64,
    deep_primary_root_sink_multiplier: f64,
    deeper_primary_root_sink_multiplier: f64,
    annual_termination_hours_without_grain_fill: f64,
    root_protein_carbon_per_nitrogen_g_c_per_g_n: f64,
    root_protein_carbon_per_phosphorus_g_c_per_g_p: f64,
    nutrient_uptake_respiration_g_c_per_g_element: f64,
    evergreen_leafoff_remobilization_start_fraction: f64,
    deciduous_leafoff_remobilization_start_fraction: f64,
    full_senescence_duration_h: f64,

    pub fn validate(self: SecondaryRootParameters) !void {
        inline for (@typeInfo(SecondaryRootParameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSecondaryRootMetabolismParameter;
        }
        if (self.substrate_respiration_half_saturation_g_c_per_g_c == 0) return error.InvalidSecondaryRootMetabolismParameter;
        if (self.nitrogen_feedback_half_saturation_g_n_per_g_c == 0) return error.InvalidSecondaryRootMetabolismParameter;
        if (self.phosphorus_feedback_half_saturation_g_p_per_g_c == 0) return error.InvalidSecondaryRootMetabolismParameter;
        if (self.minimum_carbon_recycling_fraction > 1 or self.responsive_carbon_recycling_fraction > 1 or
            self.minimum_carbon_recycling_fraction + self.responsive_carbon_recycling_fraction > 1 or
            self.maximum_nitrogen_recycling_fraction > 1 or self.maximum_phosphorus_recycling_fraction > 1 or
            self.evergreen_leafoff_remobilization_start_fraction > 1 or self.deciduous_leafoff_remobilization_start_fraction > 1)
            return error.InvalidSecondaryRootMetabolismParameter;
        if (self.maintenance_gas_constant_j_per_mol_k == 0 or self.root_penetration_reference_radius_m == 0 or
            self.acidity_half_effect_hydrogen_activity_mol_per_m3 == 0)
            return error.InvalidSecondaryRootMetabolismParameter;
        if (self.full_senescence_duration_h == 0) return error.InvalidSecondaryRootMetabolismParameter;
    }
};

/// Historical GROSUB values, selected at runtime only when an older runscript
/// has not yet supplied the root_metabolism record.
pub fn compatibilitySecondaryRootParameters() SecondaryRootParameters {
    return .{
        .maximum_substrate_respiration_fraction_per_h = 0.015,
        .substrate_respiration_half_saturation_g_c_per_g_c = 0.025,
        .nitrogen_feedback_half_saturation_g_n_per_g_c = 0.1,
        .phosphorus_feedback_half_saturation_g_p_per_g_c = 0.01,
        .maintenance_respiration_g_c_per_g_n_h = 0.010,
        .nitrogen_assimilation_respiration_g_c_per_g_n = 1.70,
        .minimum_carbon_recycling_fraction = 0.167,
        .responsive_carbon_recycling_fraction = 0.333,
        .maximum_nitrogen_recycling_fraction = 0.667,
        .maximum_phosphorus_recycling_fraction = 0.667,
        .storage_exchange_fraction_per_h = 2.5e-5,
        .nonwoody_root_fraction_exponent = 0.167,
        .maintenance_gas_constant_j_per_mol_k = 8.3143,
        .maintenance_enthalpy_j_per_mol_k = 710,
        .maintenance_activation_energy_j_per_mol = 62500,
        .maintenance_low_temperature_inactivation_energy_j_per_mol = 197500,
        .maintenance_normalization_log_intercept = 25.216,
        .maximum_maintenance_temperature_response = 1.0e3,
        .shallow_root_water_response_per_megapascal = 0.05,
        .deep_root_water_response_per_megapascal = 0.10,
        .maintenance_water_response_exponent = 0.25,
        .root_penetration_reference_radius_m = 1.0e-3,
        .acidity_half_effect_hydrogen_activity_mol_per_m3 = 1,
        .maximum_acidity_enhancement = 4,
        .shallow_primary_root_sink_multiplier = 0.25,
        .intermediate_primary_root_sink_multiplier = 1,
        .deep_primary_root_sink_multiplier = 2,
        .deeper_primary_root_sink_multiplier = 4,
        .annual_termination_hours_without_grain_fill = 336,
        .root_protein_carbon_per_nitrogen_g_c_per_g_n = 2.5,
        .root_protein_carbon_per_phosphorus_g_c_per_g_p = 25,
        .nutrient_uptake_respiration_g_c_per_g_element = 0.86,
        .evergreen_leafoff_remobilization_start_fraction = 0.75,
        .deciduous_leafoff_remobilization_start_fraction = 0.5,
        .full_senescence_duration_h = 480,
    };
}

pub const SecondaryRootInputs = struct {
    mobile_carbon_g_c: f64,
    nonstructural_nitrogen_g_n: f64,
    nonstructural_phosphorus_g_p: f64,
    root_carbon_g_c: f64,
    root_nitrogen_g_n: f64,
    root_nitrogen_to_carbon_ratio_g_n_per_g_c: f64,
    root_phosphorus_to_carbon_ratio_g_p_per_g_c: f64,
    root_growth_yield_g_c_per_g_c: f64,
    active_root_fraction: f64,
    biological_timestep_h: f64,
    substrate_temperature_response: f64,
    maintenance_temperature_response: f64,
    acidity_response: f64,
    substrate_feedback: f64,
    oxygen_limitation: f64,
    substrate_water_response: f64,
    maintenance_water_response: f64,
};

/// Per-PFT values needed by the live GROSUB root kernel. These are copied
/// from the runtime plant catalog once, so hourly tiles never parse or retain
/// dependencies on input files.
pub const RuntimePlantParameters = struct {
    root_profile_type: u8,
    mycorrhizal_type: u8,
    growth_habit: u8,
    leaf_phenology_type: u8,
    root_growth_yield_g_c_per_g_c: f64,
    root_nitrogen_to_carbon_g_n_per_g_c: f64,
    root_phosphorus_to_carbon_g_p_per_g_c: f64,
    stalk_nitrogen_to_carbon_g_n_per_g_c: f64,
    stalk_phosphorus_to_carbon_g_p_per_g_c: f64,
    primary_root_radius_m: f64,
    secondary_root_radius_m: f64,
    primary_specific_length_m_per_g_c: f64,
    secondary_specific_length_m_per_g_c: f64,
    secondary_root_branching_per_m: f64,
    shoot_root_equilibration_fraction_per_h: f64,

    pub fn validate(self: RuntimePlantParameters) !void {
        if (self.root_profile_type > 3 or self.mycorrhizal_type > 2 or self.growth_habit > 1 or self.leaf_phenology_type > 5) return error.InvalidRootMetabolismPlantCode;
        inline for (@typeInfo(RuntimePlantParameters).@"struct".fields) |field| {
            if (field.type == u8) continue;
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0 or
                (value == 0 and !std.mem.eql(u8, field.name, "shoot_root_equilibration_fraction_per_h")))
                return error.InvalidRootMetabolismPlantParameter;
        }
        if (self.root_growth_yield_g_c_per_g_c >= 1) return error.InvalidRootMetabolismPlantParameter;
    }

    /// READQ MY is the source upper bound for every `DO N=1,MY` root loop.
    pub fn biologicalDomainCount(self: RuntimePlantParameters) usize {
        return if (self.mycorrhizal_type == 2) 2 else 1;
    }
};

pub const SecondaryRootResult = struct {
    nutrient_feedback: f64,
    substrate_respiration_oxygen_unlimited_g_c_per_h: f64,
    maintenance_respiration_g_c_per_h: f64,
    substrate_respiration_actual_g_c_per_h: f64,
    growth_respiration_oxygen_unlimited_g_c_per_h: f64,
    growth_respiration_actual_g_c_per_h: f64,
    growth_and_respiration_carbon_oxygen_unlimited_g_c_per_h: f64,
    growth_and_respiration_carbon_actual_g_c_per_h: f64,
    root_growth_oxygen_unlimited_g_c_per_h: f64,
    root_growth_actual_g_c_per_h: f64,
    nitrogen_growth_demand_g_n_per_h: f64,
    nitrogen_growth_actual_g_n_per_h: f64,
    phosphorus_growth_actual_g_p_per_h: f64,
    nitrogen_assimilation_respiration_oxygen_unlimited_g_c_per_h: f64,
    nitrogen_assimilation_respiration_actual_g_c_per_h: f64,
};

pub const PrimaryRootInputs = struct {
    shared: SecondaryRootInputs,
    primary_tip_at_or_below_profile_bottom: bool,
};

/// Exact GROSUB secondary-root CNPG through CNRDM/CNRDA equations. The
/// caller supplies the source model's dimensionless temperature, water,
/// acidity, oxygen, and feedback responses so this kernel remains reusable.
fn rootMetabolism(parameters: SecondaryRootParameters, inputs: SecondaryRootInputs, cap_substrate_to_current_maintenance: bool) !SecondaryRootResult {
    try parameters.validate();
    inline for (@typeInfo(SecondaryRootInputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSecondaryRootMetabolismInput;
    }
    if (inputs.root_growth_yield_g_c_per_g_c <= 0 or inputs.root_growth_yield_g_c_per_g_c >= 1) return error.InvalidSecondaryRootMetabolismInput;
    if (inputs.root_nitrogen_to_carbon_ratio_g_n_per_g_c == 0 or inputs.root_phosphorus_to_carbon_ratio_g_p_per_g_c == 0) return error.InvalidSecondaryRootMetabolismInput;

    const nutrient_feedback = if (inputs.mobile_carbon_g_c > 0)
        @min(
            inputs.nonstructural_nitrogen_g_n /
                (inputs.nonstructural_nitrogen_g_n + inputs.mobile_carbon_g_c * parameters.nitrogen_feedback_half_saturation_g_n_per_g_c),
            inputs.nonstructural_phosphorus_g_p /
                (inputs.nonstructural_phosphorus_g_p + inputs.mobile_carbon_g_c * parameters.phosphorus_feedback_half_saturation_g_p_per_g_c),
        )
    else
        1.0;
    const mobile_carbon_concentration_g_c_per_g_c = if (inputs.root_carbon_g_c > 0)
        inputs.mobile_carbon_g_c / inputs.root_carbon_g_c
    else
        1;
    var substrate_respiration_oxygen_unlimited = @max(0, parameters.maximum_substrate_respiration_fraction_per_h *
        inputs.active_root_fraction * inputs.mobile_carbon_g_c * inputs.substrate_temperature_response *
        nutrient_feedback * inputs.substrate_feedback * inputs.substrate_water_response * inputs.biological_timestep_h) *
        mobile_carbon_concentration_g_c_per_g_c /
        (mobile_carbon_concentration_g_c_per_g_c + parameters.substrate_respiration_half_saturation_g_c_per_g_c);
    const maintenance_respiration = @max(0, parameters.maintenance_respiration_g_c_per_g_n_h *
        inputs.root_nitrogen_g_n * inputs.maintenance_temperature_response * inputs.acidity_response *
        inputs.biological_timestep_h * inputs.maintenance_water_response);
    // GROSUB places the bottom-tip cap before assigning RMNCR, which reuses a
    // stale loop value. Use the current axis maintenance demand: this is the
    // intended AMIN1 relation and removes traversal-order dependence.
    if (cap_substrate_to_current_maintenance) substrate_respiration_oxygen_unlimited = @min(substrate_respiration_oxygen_unlimited, maintenance_respiration);
    const substrate_respiration_actual = substrate_respiration_oxygen_unlimited * inputs.oxygen_limitation;
    const growth_energy_oxygen_unlimited = @max(0, substrate_respiration_oxygen_unlimited - maintenance_respiration);
    const growth_energy_actual = @max(0, substrate_respiration_actual - maintenance_respiration);
    const root_respiration_fraction = 1.0 - inputs.root_growth_yield_g_c_per_g_c;
    const nutrient_limited_growth_respiration = try group_respiration.nutrientLimitedRootGrowthRespiration(
        inputs.nonstructural_nitrogen_g_n,
        inputs.nonstructural_phosphorus_g_p,
        inputs.active_root_fraction,
        root_respiration_fraction,
        inputs.root_growth_yield_g_c_per_g_c,
        inputs.root_nitrogen_to_carbon_ratio_g_n_per_g_c,
        inputs.root_phosphorus_to_carbon_ratio_g_p_per_g_c,
    );
    const growth_respiration_oxygen_unlimited = @min(growth_energy_oxygen_unlimited, nutrient_limited_growth_respiration);
    const growth_respiration_actual = @min(growth_energy_actual, nutrient_limited_growth_respiration * inputs.oxygen_limitation);
    const root_growth_oxygen_unlimited = growth_respiration_oxygen_unlimited / root_respiration_fraction * inputs.root_growth_yield_g_c_per_g_c;
    const root_growth_actual = growth_respiration_actual / root_respiration_fraction * inputs.root_growth_yield_g_c_per_g_c;
    const nitrogen_growth_demand = @max(0, root_growth_oxygen_unlimited * inputs.root_nitrogen_to_carbon_ratio_g_n_per_g_c);
    const nitrogen_growth_actual = @max(0, @min(inputs.active_root_fraction * inputs.nonstructural_nitrogen_g_n, root_growth_actual * inputs.root_nitrogen_to_carbon_ratio_g_n_per_g_c));
    const phosphorus_growth_actual = @max(0, @min(inputs.active_root_fraction * inputs.nonstructural_phosphorus_g_p, root_growth_actual * inputs.root_phosphorus_to_carbon_ratio_g_p_per_g_c));
    const result: SecondaryRootResult = .{
        .nutrient_feedback = nutrient_feedback,
        .substrate_respiration_oxygen_unlimited_g_c_per_h = substrate_respiration_oxygen_unlimited,
        .maintenance_respiration_g_c_per_h = maintenance_respiration,
        .substrate_respiration_actual_g_c_per_h = substrate_respiration_actual,
        .growth_respiration_oxygen_unlimited_g_c_per_h = growth_respiration_oxygen_unlimited,
        .growth_respiration_actual_g_c_per_h = growth_respiration_actual,
        .growth_and_respiration_carbon_oxygen_unlimited_g_c_per_h = growth_respiration_oxygen_unlimited / root_respiration_fraction,
        .growth_and_respiration_carbon_actual_g_c_per_h = growth_respiration_actual / root_respiration_fraction,
        .root_growth_oxygen_unlimited_g_c_per_h = root_growth_oxygen_unlimited,
        .root_growth_actual_g_c_per_h = root_growth_actual,
        .nitrogen_growth_demand_g_n_per_h = nitrogen_growth_demand,
        .nitrogen_growth_actual_g_n_per_h = nitrogen_growth_actual,
        .phosphorus_growth_actual_g_p_per_h = phosphorus_growth_actual,
        .nitrogen_assimilation_respiration_oxygen_unlimited_g_c_per_h = parameters.nitrogen_assimilation_respiration_g_c_per_g_n * nitrogen_growth_demand,
        .nitrogen_assimilation_respiration_actual_g_c_per_h = parameters.nitrogen_assimilation_respiration_g_c_per_g_n * nitrogen_growth_actual,
    };
    inline for (@typeInfo(SecondaryRootResult).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteSecondaryRootMetabolism;
    return result;
}

pub fn secondaryRootMetabolism(parameters: SecondaryRootParameters, inputs: SecondaryRootInputs) !SecondaryRootResult {
    return rootMetabolism(parameters, inputs, false);
}

/// GROSUB primary-root RCO2RM through CNRDM/CNRDA. Primary and secondary
/// axes share the biochemical equations; only a primary tip at/below the
/// profile bottom receives the source respiration cap.
pub fn primaryRootMetabolism(parameters: SecondaryRootParameters, inputs: PrimaryRootInputs) !SecondaryRootResult {
    return rootMetabolism(parameters, inputs.shared, inputs.primary_tip_at_or_below_profile_bottom);
}
