const std = @import("std");
const partition_module = @import("../partition/organ.zig");
const nutrient_limitation = @import("shoot_growth_nutrient_limitation.zig");

pub const Parameters = struct {
    maximum_mobile_carbon_oxidation_per_h: f64,
    mobile_carbon_respiration_half_saturation_g_c_per_g_c: f64,
    maintenance_respiration_g_c_per_g_n_h: f64,
    minimum_leaf_nutrient_fraction: f64,
    nitrogen_assimilation_respiration_g_c_per_g_n: f64,
    fixation_respiration_credit_g_c_per_g_fixed_c: f64,
    mobile_nitrogen_inhibition_g_n_per_g_c: f64,
    mobile_phosphorus_inhibition_g_p_per_g_c: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name)) or @field(self, field.name) < 0) return error.InvalidShootGrowthMetabolismParameter;
        if (self.mobile_carbon_respiration_half_saturation_g_c_per_g_c <= 0 or self.minimum_leaf_nutrient_fraction > 1) return error.InvalidShootGrowthMetabolismParameter;
    }
};

pub fn compatibilityParameters() Parameters {
    return .{
        .maximum_mobile_carbon_oxidation_per_h = 0.015,
        .mobile_carbon_respiration_half_saturation_g_c_per_g_c = 0.025,
        .maintenance_respiration_g_c_per_g_n_h = 0.010,
        .minimum_leaf_nutrient_fraction = 0.333,
        .nitrogen_assimilation_respiration_g_c_per_g_n = 1.70,
        .fixation_respiration_credit_g_c_per_g_fixed_c = 0.025,
        .mobile_nitrogen_inhibition_g_n_per_g_c = 0.1,
        .mobile_phosphorus_inhibition_g_p_per_g_c = 0.01,
    };
}

/// GROSUB TFN5 canopy-maintenance Arrhenius response (25 C ≈ 1).
pub fn maintenanceTemperatureFraction(canopy_temperature_k: f64, thermal_adaptation_offset_k: f64) !f64 {
    if (!std.math.isFinite(canopy_temperature_k) or !std.math.isFinite(thermal_adaptation_offset_k) or canopy_temperature_k <= 0 or canopy_temperature_k + thermal_adaptation_offset_k <= 0) return error.InvalidShootMaintenanceTemperature;
    const adapted_temperature_k = canopy_temperature_k + thermal_adaptation_offset_k;
    const rt = 8.3143 * adapted_temperature_k;
    const st = 710.0 * adapted_temperature_k;
    const inactivation = 1 + @exp((197_500 - st) / rt);
    const result = @min(1.0e3, @exp(25.216 - 62_500 / rt) / inactivation);
    if (!std.math.isFinite(result) or result < 0) return error.NonFiniteShootMaintenanceTemperature;
    return result;
}

pub const ShootWoodComposition = struct {
    stalk_carbon_fraction: [2]f64,
    stalk_nitrogen_fraction: [2]f64,
    stalk_phosphorus_fraction: [2]f64,
    leaf_growth_nitrogen_to_carbon_g_n_per_g_c: f64,
    leaf_growth_phosphorus_to_carbon_g_p_per_g_c: f64,
    sheath_growth_nitrogen_to_carbon_g_n_per_g_c: f64,
    sheath_growth_phosphorus_to_carbon_g_p_per_g_c: f64,
};

pub const ShootWoodCompositionInputs = struct {
    biomass_turnover_type: u8,
    root_profile_type: u8,
    stalk_carbon_g_c: f64,
    sapwood_carbon_g_c: f64,
    structural_presence_threshold_g_c: f64,
    stalk_nitrogen_to_carbon_g_n_per_g_c: f64,
    leaf_nitrogen_to_carbon_g_n_per_g_c: f64,
    sheath_nitrogen_to_carbon_g_n_per_g_c: f64,
    stalk_phosphorus_to_carbon_g_p_per_g_c: f64,
    leaf_phosphorus_to_carbon_g_p_per_g_c: f64,
    sheath_phosphorus_to_carbon_g_p_per_g_c: f64,
};

/// GROSUB FWODB/FWOOD and CNLFW/CPLFW/CNSHW/CPSHW. Category zero is
/// woody and category one is nonwoody, matching the source arrays.
pub fn shootWoodComposition(inputs: ShootWoodCompositionInputs) !ShootWoodComposition {
    inline for (.{ inputs.stalk_carbon_g_c, inputs.sapwood_carbon_g_c, inputs.structural_presence_threshold_g_c, inputs.stalk_nitrogen_to_carbon_g_n_per_g_c, inputs.leaf_nitrogen_to_carbon_g_n_per_g_c, inputs.sheath_nitrogen_to_carbon_g_n_per_g_c, inputs.stalk_phosphorus_to_carbon_g_p_per_g_c, inputs.leaf_phosphorus_to_carbon_g_p_per_g_c, inputs.sheath_phosphorus_to_carbon_g_p_per_g_c }) |value| {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidShootWoodCompositionInput;
    }
    if (inputs.biomass_turnover_type > 5 or inputs.root_profile_type > 3 or inputs.sapwood_carbon_g_c > inputs.stalk_carbon_g_c + 1.0e-12) return error.InvalidShootWoodCompositionInput;

    const stalk_nonwoody_fraction = if (inputs.biomass_turnover_type == 0 or
        inputs.root_profile_type <= 1 or
        inputs.stalk_carbon_g_c <= inputs.structural_presence_threshold_g_c)
        1.0
    else
        inputs.sapwood_carbon_g_c / inputs.stalk_carbon_g_c;
    const stalk_fraction = [2]f64{ 1.0 - stalk_nonwoody_fraction, stalk_nonwoody_fraction };
    // FWODB(1) is assigned one on both source branches.
    const other_organ_fraction = [2]f64{ 0.0, 1.0 };
    return .{
        .stalk_carbon_fraction = stalk_fraction,
        .stalk_nitrogen_fraction = stalk_fraction,
        .stalk_phosphorus_fraction = stalk_fraction,
        .leaf_growth_nitrogen_to_carbon_g_n_per_g_c = other_organ_fraction[0] * inputs.stalk_nitrogen_to_carbon_g_n_per_g_c + other_organ_fraction[1] * inputs.leaf_nitrogen_to_carbon_g_n_per_g_c,
        .leaf_growth_phosphorus_to_carbon_g_p_per_g_c = other_organ_fraction[0] * inputs.stalk_phosphorus_to_carbon_g_p_per_g_c + other_organ_fraction[1] * inputs.leaf_phosphorus_to_carbon_g_p_per_g_c,
        .sheath_growth_nitrogen_to_carbon_g_n_per_g_c = other_organ_fraction[0] * inputs.stalk_nitrogen_to_carbon_g_n_per_g_c + other_organ_fraction[1] * inputs.sheath_nitrogen_to_carbon_g_n_per_g_c,
        .sheath_growth_phosphorus_to_carbon_g_p_per_g_c = other_organ_fraction[0] * inputs.stalk_phosphorus_to_carbon_g_p_per_g_c + other_organ_fraction[1] * inputs.sheath_phosphorus_to_carbon_g_p_per_g_c,
    };
}

pub const Coefficients = struct {
    shoot_growth_yield_g_c_per_g_c: f64,
    respiration_fraction_g_c_per_g_c: f64,
    minimum_leaf_nitrogen_g_n_per_g_c_consumed: f64,
    variable_leaf_nitrogen_g_n_per_g_c_consumed: f64,
    other_shoot_nitrogen_g_n_per_g_c_consumed: f64,
    minimum_leaf_phosphorus_g_p_per_g_c_consumed: f64,
    variable_leaf_phosphorus_g_p_per_g_c_consumed: f64,
    other_shoot_phosphorus_g_p_per_g_c_consumed: f64,
};

pub const GrowthNutrientRatios = struct {
    nitrogen_to_carbon_g_n_per_g_c: [partition_module.organ_count]f64,
    phosphorus_to_carbon_g_p_per_g_c: [partition_module.organ_count]f64,
};

/// GROSUB growth-ratio mapping in PART order: leaf, sheath, stalk, reserve,
/// husk, ear, grain. Grain deliberately copies the reserve N:C and P:C.
pub fn growthNutrientRatios(
    organ_nitrogen_to_carbon_g_n_per_g_c: [partition_module.organ_count]f64,
    organ_phosphorus_to_carbon_g_p_per_g_c: [partition_module.organ_count]f64,
) !GrowthNutrientRatios {
    for (organ_nitrogen_to_carbon_g_n_per_g_c, organ_phosphorus_to_carbon_g_p_per_g_c) |nitrogen, phosphorus| {
        if (!std.math.isFinite(nitrogen) or nitrogen < 0 or !std.math.isFinite(phosphorus) or phosphorus < 0) return error.InvalidShootGrowthNutrientRatio;
    }
    var nitrogen = organ_nitrogen_to_carbon_g_n_per_g_c;
    var phosphorus = organ_phosphorus_to_carbon_g_p_per_g_c;
    const reserve = 3;
    const grain = 6;
    nitrogen[grain] = nitrogen[reserve];
    phosphorus[grain] = phosphorus[reserve];
    return .{
        .nitrogen_to_carbon_g_n_per_g_c = nitrogen,
        .phosphorus_to_carbon_g_p_per_g_c = phosphorus,
    };
}

pub fn coefficients(
    partition: [partition_module.organ_count]f64,
    growth_yield_g_c_per_g_c: [partition_module.organ_count]f64,
    nitrogen_to_carbon_g_n_per_g_c: [partition_module.organ_count]f64,
    phosphorus_to_carbon_g_p_per_g_c: [partition_module.organ_count]f64,
    minimum_leaf_nutrient_fraction: f64,
) !Coefficients {
    if (!std.math.isFinite(minimum_leaf_nutrient_fraction) or minimum_leaf_nutrient_fraction < 0 or minimum_leaf_nutrient_fraction > 1) return error.InvalidShootGrowthCoefficient;
    var yield: f64 = 0;
    var other_n: f64 = 0;
    var other_p: f64 = 0;
    for (0..partition_module.organ_count) |organ| {
        inline for (.{ partition[organ], growth_yield_g_c_per_g_c[organ], nitrogen_to_carbon_g_n_per_g_c[organ], phosphorus_to_carbon_g_p_per_g_c[organ] }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidShootGrowthCoefficient;
        yield += partition[organ] * growth_yield_g_c_per_g_c[organ];
        if (organ != 0)
            other_n += partition[organ] * growth_yield_g_c_per_g_c[organ] * nitrogen_to_carbon_g_n_per_g_c[organ];
        if (organ != 0)
            other_p += partition[organ] * growth_yield_g_c_per_g_c[organ] * phosphorus_to_carbon_g_p_per_g_c[organ];
    }
    if (yield > 1) return error.InvalidShootGrowthYield;
    const leaf = 0;
    const leaf_n = partition[leaf] * growth_yield_g_c_per_g_c[leaf] * nitrogen_to_carbon_g_n_per_g_c[leaf];
    const leaf_p = partition[leaf] * growth_yield_g_c_per_g_c[leaf] * phosphorus_to_carbon_g_p_per_g_c[leaf];
    return .{
        .shoot_growth_yield_g_c_per_g_c = yield,
        .respiration_fraction_g_c_per_g_c = 1 - yield,
        .minimum_leaf_nitrogen_g_n_per_g_c_consumed = minimum_leaf_nutrient_fraction * leaf_n,
        .variable_leaf_nitrogen_g_n_per_g_c_consumed = (1 - minimum_leaf_nutrient_fraction) * leaf_n,
        .other_shoot_nitrogen_g_n_per_g_c_consumed = other_n,
        .minimum_leaf_phosphorus_g_p_per_g_c_consumed = minimum_leaf_nutrient_fraction * leaf_p,
        .variable_leaf_phosphorus_g_p_per_g_c_consumed = (1 - minimum_leaf_nutrient_fraction) * leaf_p,
        .other_shoot_phosphorus_g_p_per_g_c_consumed = other_p,
    };
}

pub const StructuralNitrogenInputs = struct {
    leaf_nitrogen_g_n: f64,
    sheath_or_petiole_nitrogen_g_n: f64,
    sapwood_carbon_g_c: f64,
    stalk_nitrogen_per_carbon_g_n_per_g_c: f64,
    husk_nitrogen_g_n: f64,
    ear_nitrogen_g_n: f64,
    grain_nitrogen_g_n: f64,
    physiological_maturity_reached: bool,
};

/// GROSUB 904-918 structural N basis for branch maintenance respiration.
/// Stalk contribution is CNSTK times sapwood C, not total stalk N.
pub fn structuralNitrogenForMaintenance(inputs: StructuralNitrogenInputs) !f64 {
    inline for (@typeInfo(StructuralNitrogenInputs).@"struct".fields) |field| {
        if (field.type == f64) {
            const value = @field(inputs, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidShootStructuralNitrogenInput;
        }
    }
    var structural_nitrogen_g_n = @max(0, inputs.leaf_nitrogen_g_n +
        inputs.sheath_or_petiole_nitrogen_g_n +
        inputs.stalk_nitrogen_per_carbon_g_n_per_g_c * inputs.sapwood_carbon_g_c);
    if (!inputs.physiological_maturity_reached) {
        structural_nitrogen_g_n += @max(0, inputs.husk_nitrogen_g_n +
            inputs.ear_nitrogen_g_n +
            inputs.grain_nitrogen_g_n);
    }
    if (!std.math.isFinite(structural_nitrogen_g_n)) return error.NonFiniteShootStructuralNitrogen;
    return structural_nitrogen_g_n;
}

pub const Inputs = struct {
    mobile_carbon_g_c: f64,
    mobile_nitrogen_g_n: f64,
    mobile_phosphorus_g_p: f64,
    mobile_carbon_concentration_g_c_per_g_c: f64,
    mobile_nitrogen_concentration_g_n_per_g_c: f64,
    mobile_phosphorus_concentration_g_p_per_g_c: f64,
    structural_nitrogen_g_n: f64,
    fixed_carbon_g_c: f64,
    growth_temperature_fraction: f64,
    maintenance_temperature_fraction: f64,
    growth_water_fraction: f64,
    maintenance_water_fraction: f64,
    termination_fraction: f64,
    nutrient_growth_fraction: f64,
    metabolically_active: bool,
    timestep_h: f64,
};

pub const Fluxes = struct {
    substrate_respiration_g_c: f64,
    maintenance_respiration_g_c: f64,
    growth_respiration_g_c: f64,
    excess_maintenance_respiration_g_c: f64,
    growth_carbon_consumption_g_c: f64,
    assimilated_nitrogen_g_n: f64,
    assimilated_phosphorus_g_p: f64,
    nitrogen_assimilation_respiration_g_c: f64,
    total_respiration_g_c: f64,
};

pub const PreEmergenceInputs = struct {
    mobile_carbon_g_c: f64,
    mobile_nitrogen_g_n: f64,
    mobile_phosphorus_g_p: f64,
    mobile_carbon_concentration_g_c_per_g_c: f64,
    mobile_nitrogen_concentration_g_n_per_g_c: f64,
    mobile_phosphorus_concentration_g_p_per_g_c: f64,
    structural_nitrogen_g_n: f64,
    growth_temperature_fraction: f64,
    maintenance_temperature_fraction: f64,
    growth_water_fraction: f64,
    maintenance_water_fraction: f64,
    termination_fraction: f64,
    nutrient_growth_fraction: f64,
    oxygen_limitation_fraction: f64,
    timestep_h: f64,
};

pub const PreEmergenceFluxes = struct {
    substrate_respiration_oxygen_unlimited_g_c: f64,
    substrate_respiration_actual_g_c: f64,
    growth_respiration_oxygen_unlimited_g_c: f64,
    growth_respiration_actual_g_c: f64,
    excess_maintenance_oxygen_unlimited_g_c: f64,
    excess_maintenance_actual_g_c: f64,
    growth_carbon_consumption_oxygen_unlimited_g_c: f64,
    growth_carbon_consumption_actual_g_c: f64,
    assimilated_nitrogen_oxygen_unlimited_g_n: f64,
    assimilated_nitrogen_actual_g_n: f64,
    assimilated_phosphorus_actual_g_p: f64,
    nitrogen_assimilation_respiration_oxygen_unlimited_g_c: f64,
    nitrogen_assimilation_respiration_actual_g_c: f64,
    total_respiration_oxygen_unlimited_g_c: f64,
    total_respiration_actual_g_c: f64,
};

/// GROSUB CNPG/CCE: an N,P constraint on branch growth and etoliation
/// computed from nonstructural C:N:P *concentrations* (HFUNC CZPOLB,
/// CCPOLB, CPPOLB -- each pool divided by branch structural mass plus
/// that same pool), not from raw mobile-pool masses.
pub fn nutrientConstraint(parameters: Parameters, mobile_carbon_concentration_g_c_per_g_c: f64, mobile_nitrogen_concentration_g_n_per_g_c: f64, mobile_phosphorus_concentration_g_p_per_g_c: f64) !f64 {
    try parameters.validate();
    inline for (.{ mobile_carbon_concentration_g_c_per_g_c, mobile_nitrogen_concentration_g_n_per_g_c, mobile_phosphorus_concentration_g_p_per_g_c }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidShootGrowthMetabolismInput;
    if (mobile_carbon_concentration_g_c_per_g_c <= 0) return 1;
    return @min(
        mobile_nitrogen_concentration_g_n_per_g_c / (mobile_nitrogen_concentration_g_n_per_g_c + mobile_carbon_concentration_g_c_per_g_c * parameters.mobile_nitrogen_inhibition_g_n_per_g_c),
        mobile_phosphorus_concentration_g_p_per_g_c / (mobile_phosphorus_concentration_g_p_per_g_c + mobile_carbon_concentration_g_c_per_g_c * parameters.mobile_phosphorus_inhibition_g_p_per_g_c),
    );
}

/// grosub.f lines 1866-2063 pre-emergence branch metabolism. The source
/// retains parallel oxygen-unlimited (`M`) and oxygen-limited paths.
pub fn calculatePreEmergence(
    parameters: Parameters,
    growth: Coefficients,
    inputs: PreEmergenceInputs,
) !PreEmergenceFluxes {
    try parameters.validate();
    inline for (@typeInfo(Coefficients).@"struct".fields) |field| if (!std.math.isFinite(@field(growth, field.name)) or @field(growth, field.name) < 0) return error.InvalidPreEmergenceMetabolismInput;
    inline for (@typeInfo(PreEmergenceInputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0) return error.InvalidPreEmergenceMetabolismInput;
    // TFN4 and TFN6 are Arrhenius responses, not [0, 1] fractions.
    inline for (.{ inputs.growth_water_fraction, inputs.maintenance_water_fraction, inputs.termination_fraction, inputs.nutrient_growth_fraction, inputs.oxygen_limitation_fraction }) |fraction| if (fraction > 1) return error.InvalidPreEmergenceMetabolismInput;
    if (inputs.maintenance_temperature_fraction > 1.0e3) return error.InvalidPreEmergenceMetabolismInput;
    if (inputs.timestep_h <= 0 or growth.respiration_fraction_g_c_per_g_c <= 0) return error.InvalidPreEmergenceMetabolismInput;

    const nutrient = try nutrientConstraint(parameters, inputs.mobile_carbon_concentration_g_c_per_g_c, inputs.mobile_nitrogen_concentration_g_n_per_g_c, inputs.mobile_phosphorus_concentration_g_p_per_g_c);
    const substrate_unlimited = @max(0, parameters.maximum_mobile_carbon_oxidation_per_h * inputs.mobile_carbon_g_c * inputs.growth_temperature_fraction * nutrient * inputs.growth_water_fraction * inputs.termination_fraction * inputs.timestep_h) *
        inputs.mobile_carbon_concentration_g_c_per_g_c / (inputs.mobile_carbon_concentration_g_c_per_g_c + parameters.mobile_carbon_respiration_half_saturation_g_c_per_g_c);
    const substrate_actual = substrate_unlimited * inputs.oxygen_limitation_fraction;
    const maintenance = @max(0, parameters.maintenance_respiration_g_c_per_g_n_h * inputs.maintenance_temperature_fraction * inputs.structural_nitrogen_g_n * inputs.timestep_h) * inputs.maintenance_water_fraction;
    const growth_unlimited = @max(0, substrate_unlimited - maintenance);
    const growth_actual = @max(0, substrate_actual - maintenance);
    const maintenance_deficit_unlimited = @max(0, maintenance - substrate_unlimited);
    const maintenance_deficit_actual = @max(0, maintenance - substrate_actual);
    const nitrogen_demand = growth.other_shoot_nitrogen_g_n_per_g_c_consumed + growth.minimum_leaf_nitrogen_g_n_per_g_c_consumed + growth.variable_leaf_nitrogen_g_n_per_g_c_consumed * inputs.nutrient_growth_fraction;
    const phosphorus_demand = growth.other_shoot_phosphorus_g_p_per_g_c_consumed + growth.minimum_leaf_phosphorus_g_p_per_g_c_consumed + growth.variable_leaf_phosphorus_g_p_per_g_c_consumed * inputs.nutrient_growth_fraction;
    // Source gate is CNSHX > 0 OR CNLFX > 0, not the combined demand.
    const nutrient_cap = if (growth.other_shoot_nitrogen_g_n_per_g_c_consumed > 0 or
        growth.variable_leaf_nitrogen_g_n_per_g_c_consumed > 0)
        @min(inputs.mobile_nitrogen_g_n * growth.respiration_fraction_g_c_per_g_c / nitrogen_demand, inputs.mobile_phosphorus_g_p * growth.respiration_fraction_g_c_per_g_c / phosphorus_demand)
    else
        0;
    const limited_growth_unlimited = if (growth_unlimited > 0) @min(growth_unlimited, nutrient_cap) else 0;
    const limited_growth_actual = if (growth_actual > 0) @min(growth_actual, nutrient_cap * inputs.oxygen_limitation_fraction) else 0;
    const carbon_unlimited = limited_growth_unlimited / growth.respiration_fraction_g_c_per_g_c;
    const carbon_actual = limited_growth_actual / growth.respiration_fraction_g_c_per_g_c;
    const nitrogen_unlimited = @max(0, carbon_unlimited * nitrogen_demand);
    const nitrogen_actual = @max(0, carbon_actual * nitrogen_demand);
    const phosphorus_actual = @max(0, carbon_actual * phosphorus_demand);
    const nitrogen_respiration_unlimited = @max(0, parameters.nitrogen_assimilation_respiration_g_c_per_g_n * nitrogen_unlimited);
    const nitrogen_respiration_actual = @max(0, parameters.nitrogen_assimilation_respiration_g_c_per_g_n * nitrogen_actual);
    const result: PreEmergenceFluxes = .{
        .substrate_respiration_oxygen_unlimited_g_c = substrate_unlimited,
        .substrate_respiration_actual_g_c = substrate_actual,
        .growth_respiration_oxygen_unlimited_g_c = limited_growth_unlimited,
        .growth_respiration_actual_g_c = limited_growth_actual,
        .excess_maintenance_oxygen_unlimited_g_c = maintenance_deficit_unlimited,
        .excess_maintenance_actual_g_c = maintenance_deficit_actual,
        .growth_carbon_consumption_oxygen_unlimited_g_c = carbon_unlimited,
        .growth_carbon_consumption_actual_g_c = carbon_actual,
        .assimilated_nitrogen_oxygen_unlimited_g_n = nitrogen_unlimited,
        .assimilated_nitrogen_actual_g_n = nitrogen_actual,
        .assimilated_phosphorus_actual_g_p = phosphorus_actual,
        .nitrogen_assimilation_respiration_oxygen_unlimited_g_c = nitrogen_respiration_unlimited,
        .nitrogen_assimilation_respiration_actual_g_c = nitrogen_respiration_actual,
        .total_respiration_oxygen_unlimited_g_c = maintenance + limited_growth_unlimited + maintenance_deficit_unlimited + nitrogen_respiration_unlimited,
        .total_respiration_actual_g_c = maintenance + limited_growth_actual + maintenance_deficit_actual + nitrogen_respiration_actual,
    };
    inline for (@typeInfo(PreEmergenceFluxes).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFinitePreEmergenceMetabolism;
    return result;
}

/// GROSUB RMNCS maintenance-water selector. IGTYP=0 and drought-deciduous
/// IWTYP=2 use WFNSG; every other case uses WFNSR=WFNSG**0.25.
pub fn maintenanceWaterFraction(
    root_profile_type: u8,
    leaf_phenology_type: u8,
    growth_water_fraction: f64,
) !f64 {
    if (root_profile_type > 3 or leaf_phenology_type > 3 or
        !std.math.isFinite(growth_water_fraction) or
        growth_water_fraction < 0 or growth_water_fraction > 1)
        return error.InvalidShootMaintenanceWaterInput;
    return if (root_profile_type == 0 or leaf_phenology_type == 2)
        growth_water_fraction
    else
        std.math.pow(f64, growth_water_fraction, 0.25);
}

/// GROSUB GROLM selector: nonvascular IRTYP=0 uses TFN3; vascular root
/// profiles use planting-layer TFN4, independently of emergence.
pub fn grainFillTemperatureResponse(
    root_profile_type: u8,
    canopy_growth_temperature_response: f64,
    planting_root_growth_temperature_response: f64,
) !f64 {
    if (root_profile_type > 3 or
        !std.math.isFinite(canopy_growth_temperature_response) or
        canopy_growth_temperature_response < 0 or
        !std.math.isFinite(planting_root_growth_temperature_response) or
        planting_root_growth_temperature_response < 0)
        return error.InvalidGrainFillTemperatureResponse;
    return if (root_profile_type == 0)
        canopy_growth_temperature_response
    else
        planting_root_growth_temperature_response;
}

/// GROSUB winter-annual termination after physiological maturity.
pub fn shouldForceAnnualLeafoff(
    growth_habit: u8,
    leaf_phenology_type: u8,
    hours_without_grain_fill: f64,
    physiological_maturity_no_fill_h: f64,
    annual_leafoff_delay_h_by_phenology: [4]f64,
) !bool {
    if (growth_habit > 1 or leaf_phenology_type > 3 or
        !std.math.isFinite(hours_without_grain_fill) or hours_without_grain_fill < 0 or
        !std.math.isFinite(physiological_maturity_no_fill_h) or physiological_maturity_no_fill_h <= 0)
        return error.InvalidAnnualLeafoffInput;
    for (annual_leafoff_delay_h_by_phenology) |delay|
        if (!std.math.isFinite(delay) or delay < 0) return error.InvalidAnnualLeafoffInput;
    return growth_habit == 0 and leaf_phenology_type != 0 and
        hours_without_grain_fill >
            physiological_maturity_no_fill_h + annual_leafoff_delay_h_by_phenology[leaf_phenology_type];
}

test "GROSUB deciduous annual forces leafoff only after FLG4X plus FLG4Y" {
    const delays = [4]f64{ 360, 1440, 720, 720 };
    try std.testing.expect(!try shouldForceAnnualLeafoff(0, 1, 1512, 72, delays));
    try std.testing.expect(try shouldForceAnnualLeafoff(0, 1, 1512.5, 72, delays));
    try std.testing.expect(!try shouldForceAnnualLeafoff(1, 1, 2000, 72, delays));
    try std.testing.expect(!try shouldForceAnnualLeafoff(0, 0, 2000, 72, delays));
}

test "GROSUB grain fill selects TFN3 or planting-layer TFN4 by root profile" {
    try std.testing.expectEqual(
        @as(f64, 0.8),
        try grainFillTemperatureResponse(0, 0.8, 0.3),
    );
    try std.testing.expectEqual(
        @as(f64, 0.3),
        try grainFillTemperatureResponse(1, 0.8, 0.3),
    );
    try std.testing.expectEqual(
        @as(f64, 0.3),
        try grainFillTemperatureResponse(3, 0.8, 0.3),
    );
}

pub const StemDiameterRefreshInputs = struct {
    day_of_year: u16,
    hour_of_day: u8,
    integer_solar_noon_hour: u8,
    biological_iteration: usize,
    branch_index: usize,
    main_branch_index: usize,
    biomass_turnover_type: u8,
    root_profile_type: u8,
};

/// GROSUB DSTK refresh selector in the stalk-growth loop. A selected update
/// still requires a positive internode-height increment; otherwise the
/// source retains the previous DSTK value.
pub fn shouldRefreshStemDiameter(inputs: StemDiameterRefreshInputs) !bool {
    if (inputs.day_of_year == 0 or inputs.day_of_year > 366 or
        inputs.hour_of_day > 23 or inputs.integer_solar_noon_hour > 23 or
        inputs.biological_iteration == 0 or inputs.biomass_turnover_type > 5 or
        inputs.root_profile_type > 3)
        return error.InvalidStemDiameterRefreshInput;
    return inputs.day_of_year % 30 == 0 and
        inputs.hour_of_day == inputs.integer_solar_noon_hour and
        inputs.biological_iteration == 1 and
        inputs.branch_index == inputs.main_branch_index and
        inputs.biomass_turnover_type != 0 and
        inputs.root_profile_type != 0;
}

/// Exact GROSUB lateral-branch eligibility gate before pairwise reserve
/// equilibration. `minimum_active_sapwood_g_c` is the runtime cell `ZEROP`
/// threshold; equality does not qualify.
pub fn shouldEquilibrateLateralBranchReserves(
    lateral_sapwood_g_c: f64,
    minimum_active_sapwood_g_c: f64,
) !bool {
    if (!std.math.isFinite(lateral_sapwood_g_c) or
        !std.math.isFinite(minimum_active_sapwood_g_c) or
        lateral_sapwood_g_c < 0 or
        minimum_active_sapwood_g_c < 0)
    {
        return error.InvalidBranchReserveEquilibrationInput;
    }
    return lateral_sapwood_g_c > minimum_active_sapwood_g_c;
}

/// Exact GROSUB gate for N/P reserve exchange after the C exchange has been
/// state_updateted. The source compares the pre-exchange pair-total reserve C.
pub fn shouldEquilibrateBranchReserveNutrients(
    initial_pair_reserve_carbon_g_c: f64,
    minimum_active_reserve_carbon_g_c: f64,
) !bool {
    if (!std.math.isFinite(initial_pair_reserve_carbon_g_c) or
        !std.math.isFinite(minimum_active_reserve_carbon_g_c) or
        initial_pair_reserve_carbon_g_c < 0 or
        minimum_active_reserve_carbon_g_c < 0)
    {
        return error.InvalidBranchReserveEquilibrationInput;
    }
    return initial_pair_reserve_carbon_g_c > minimum_active_reserve_carbon_g_c;
}

/// Runtime replacement for GROSUB `ZEROP = ZERO * PP`. The per-plant
/// threshold is configuration, while population is mutable plant state.
pub fn plantScaledPresenceThresholdG(
    presence_threshold_g_per_plant: f64,
    plant_population_count: f64,
) !f64 {
    if (!std.math.isFinite(presence_threshold_g_per_plant) or
        !std.math.isFinite(plant_population_count) or
        presence_threshold_g_per_plant < 0 or
        plant_population_count < 0)
    {
        return error.InvalidPlantPresenceThresholdInput;
    }
    const threshold_g = presence_threshold_g_per_plant * plant_population_count;
    if (!std.math.isFinite(threshold_g)) return error.InvalidPlantPresenceThresholdInput;
    return threshold_g;
}

pub fn calculate(parameters: Parameters, growth: Coefficients, inputs: Inputs) !Fluxes {
    try parameters.validate();
    inline for (@typeInfo(Coefficients).@"struct".fields) |field| if (!std.math.isFinite(@field(growth, field.name)) or @field(growth, field.name) < 0) return error.InvalidShootGrowthCoefficient;
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0)) return error.InvalidShootGrowthMetabolismInput;
    inline for (.{ inputs.growth_temperature_fraction, inputs.maintenance_temperature_fraction, inputs.growth_water_fraction, inputs.maintenance_water_fraction, inputs.termination_fraction, inputs.nutrient_growth_fraction }) |fraction| if (fraction > 1) return error.InvalidShootGrowthMetabolismInput;
    if (inputs.timestep_h <= 0 or growth.respiration_fraction_g_c_per_g_c <= 0) return error.InvalidShootGrowthMetabolismInput;
    if (!inputs.metabolically_active) return std.mem.zeroes(Fluxes);

    const nutrient_constraint = try nutrientConstraint(parameters, inputs.mobile_carbon_concentration_g_c_per_g_c, inputs.mobile_nitrogen_concentration_g_n_per_g_c, inputs.mobile_phosphorus_concentration_g_p_per_g_c);
    const substrate_respiration = parameters.maximum_mobile_carbon_oxidation_per_h * inputs.mobile_carbon_g_c * inputs.growth_temperature_fraction * nutrient_constraint * inputs.termination_fraction * inputs.growth_water_fraction * inputs.timestep_h *
        inputs.mobile_carbon_concentration_g_c_per_g_c / (inputs.mobile_carbon_concentration_g_c_per_g_c + parameters.mobile_carbon_respiration_half_saturation_g_c_per_g_c);
    const maintenance = parameters.maintenance_respiration_g_c_per_g_n_h * inputs.maintenance_temperature_fraction * inputs.structural_nitrogen_g_n * inputs.maintenance_water_fraction * inputs.timestep_h;
    const excess_growth_respiration = @max(0, substrate_respiration - maintenance);
    const excess_maintenance = @max(0, maintenance - substrate_respiration);
    const nitrogen_demand = growth.other_shoot_nitrogen_g_n_per_g_c_consumed + growth.minimum_leaf_nitrogen_g_n_per_g_c_consumed + growth.variable_leaf_nitrogen_g_n_per_g_c_consumed * inputs.nutrient_growth_fraction;
    const phosphorus_demand = growth.other_shoot_phosphorus_g_p_per_g_c_consumed + growth.minimum_leaf_phosphorus_g_p_per_g_c_consumed + growth.variable_leaf_phosphorus_g_p_per_g_c_consumed * inputs.nutrient_growth_fraction;
    const growth_respiration = try nutrient_limitation.limit(.{
        .growth_respiration_unlimited_g_c = excess_growth_respiration,
        .mobile_nitrogen_g_n = inputs.mobile_nitrogen_g_n,
        .mobile_phosphorus_g_p = inputs.mobile_phosphorus_g_p,
        .respiration_fraction_g_c_per_g_c_consumed = growth.respiration_fraction_g_c_per_g_c,
        .other_shoot_nitrogen_g_n_per_g_c_consumed = growth.other_shoot_nitrogen_g_n_per_g_c_consumed,
        .minimum_leaf_nitrogen_g_n_per_g_c_consumed = growth.minimum_leaf_nitrogen_g_n_per_g_c_consumed,
        .variable_leaf_nitrogen_g_n_per_g_c_consumed = growth.variable_leaf_nitrogen_g_n_per_g_c_consumed,
        .other_shoot_phosphorus_g_p_per_g_c_consumed = growth.other_shoot_phosphorus_g_p_per_g_c_consumed,
        .minimum_leaf_phosphorus_g_p_per_g_c_consumed = growth.minimum_leaf_phosphorus_g_p_per_g_c_consumed,
        .variable_leaf_phosphorus_g_p_per_g_c_consumed = growth.variable_leaf_phosphorus_g_p_per_g_c_consumed,
        .nutrient_growth_fraction = inputs.nutrient_growth_fraction,
    });
    const carbon_consumption = growth_respiration / growth.respiration_fraction_g_c_per_g_c;
    const assimilated_n = @max(0, @min(inputs.mobile_nitrogen_g_n, carbon_consumption * nitrogen_demand));
    const assimilated_p = @max(0, @min(inputs.mobile_phosphorus_g_p, carbon_consumption * phosphorus_demand));
    const nitrogen_respiration = @max(0, parameters.nitrogen_assimilation_respiration_g_c_per_g_n * assimilated_n - parameters.fixation_respiration_credit_g_c_per_g_fixed_c * inputs.fixed_carbon_g_c);
    const total_respiration = @min(maintenance, substrate_respiration) + growth_respiration + excess_maintenance + nitrogen_respiration;
    const result: Fluxes = .{
        .substrate_respiration_g_c = substrate_respiration,
        .maintenance_respiration_g_c = maintenance,
        .growth_respiration_g_c = growth_respiration,
        .excess_maintenance_respiration_g_c = excess_maintenance,
        .growth_carbon_consumption_g_c = carbon_consumption,
        .assimilated_nitrogen_g_n = assimilated_n,
        .assimilated_phosphorus_g_p = assimilated_p,
        .nitrogen_assimilation_respiration_g_c = nitrogen_respiration,
        .total_respiration_g_c = total_respiration,
    };
    inline for (@typeInfo(Fluxes).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFiniteShootGrowthMetabolismResult;
    return result;
}

test "GROSUB shoot respiration and nutrient limitation preserve source equations" {
    const parameters = compatibilityParameters();
    const partition = [_]f64{ 0.5, 0.2, 0.1, 0.1, 0.05, 0.05, 0 };
    const yields = [_]f64{0.8} ** partition_module.organ_count;
    const n = [_]f64{0.04} ** partition_module.organ_count;
    const p = [_]f64{0.004} ** partition_module.organ_count;
    const growth = try coefficients(partition, yields, n, p, parameters.minimum_leaf_nutrient_fraction);
    const result = try calculate(parameters, growth, .{
        .mobile_carbon_g_c = 100,
        .mobile_nitrogen_g_n = 10,
        .mobile_phosphorus_g_p = 1,
        .mobile_carbon_concentration_g_c_per_g_c = 0.05,
        .mobile_nitrogen_concentration_g_n_per_g_c = 0.05,
        .mobile_phosphorus_concentration_g_p_per_g_c = 0.01,
        .structural_nitrogen_g_n = 1,
        .fixed_carbon_g_c = 0.2,
        .growth_temperature_fraction = 1,
        .maintenance_temperature_fraction = 1,
        .growth_water_fraction = 1,
        .maintenance_water_fraction = 1,
        .termination_fraction = 1,
        .nutrient_growth_fraction = 1,
        .metabolically_active = true,
        .timestep_h = 1,
    });
    try std.testing.expect(result.substrate_respiration_g_c > result.maintenance_respiration_g_c);
    try std.testing.expectApproxEqAbs(result.growth_respiration_g_c / growth.respiration_fraction_g_c_per_g_c, result.growth_carbon_consumption_g_c, 1e-14);
    try std.testing.expect(result.assimilated_nitrogen_g_n <= 10);
    try std.testing.expect(result.assimilated_phosphorus_g_p <= 1);
    try std.testing.expectApproxEqRel(@as(f64, 1), try maintenanceTemperatureFraction(298.15, 0), 0.01);
}

test "post-emergence production path preserves the source N-only growth admission gate" {
    const parameters = compatibilityParameters();
    const result = try calculate(parameters, .{
        .shoot_growth_yield_g_c_per_g_c = 0.8,
        .respiration_fraction_g_c_per_g_c = 0.2,
        .minimum_leaf_nitrogen_g_n_per_g_c_consumed = 0.01,
        .variable_leaf_nitrogen_g_n_per_g_c_consumed = 0,
        .other_shoot_nitrogen_g_n_per_g_c_consumed = 0,
        .minimum_leaf_phosphorus_g_p_per_g_c_consumed = 0.001,
        .variable_leaf_phosphorus_g_p_per_g_c_consumed = 0,
        .other_shoot_phosphorus_g_p_per_g_c_consumed = 0,
    }, .{
        .mobile_carbon_g_c = 100,
        .mobile_nitrogen_g_n = 10,
        .mobile_phosphorus_g_p = 1,
        .mobile_carbon_concentration_g_c_per_g_c = 0.05,
        .mobile_nitrogen_concentration_g_n_per_g_c = 0.05,
        .mobile_phosphorus_concentration_g_p_per_g_c = 0.01,
        .structural_nitrogen_g_n = 0,
        .fixed_carbon_g_c = 0,
        .growth_temperature_fraction = 1,
        .maintenance_temperature_fraction = 1,
        .growth_water_fraction = 1,
        .maintenance_water_fraction = 1,
        .termination_fraction = 1,
        .nutrient_growth_fraction = 1,
        .metabolically_active = true,
        .timestep_h = 1,
    });
    try std.testing.expect(result.substrate_respiration_g_c > 0);
    try std.testing.expectEqual(@as(f64, 0), result.growth_respiration_g_c);
    try std.testing.expectEqual(@as(f64, 0), result.growth_carbon_consumption_g_c);
}

test "GROSUB maintenance structural nitrogen uses sapwood and prematurity organs" {
    const before_maturity = try structuralNitrogenForMaintenance(.{
        .leaf_nitrogen_g_n = 1,
        .sheath_or_petiole_nitrogen_g_n = 2,
        .sapwood_carbon_g_c = 10,
        .stalk_nitrogen_per_carbon_g_n_per_g_c = 0.05,
        .husk_nitrogen_g_n = 0.2,
        .ear_nitrogen_g_n = 0.3,
        .grain_nitrogen_g_n = 0.4,
        .physiological_maturity_reached = false,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 4.4), before_maturity, 1.0e-15);

    const after_maturity = try structuralNitrogenForMaintenance(.{
        .leaf_nitrogen_g_n = 1,
        .sheath_or_petiole_nitrogen_g_n = 2,
        .sapwood_carbon_g_c = 10,
        .stalk_nitrogen_per_carbon_g_n_per_g_c = 0.05,
        .husk_nitrogen_g_n = 0.2,
        .ear_nitrogen_g_n = 0.3,
        .grain_nitrogen_g_n = 0.4,
        .physiological_maturity_reached = true,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), after_maturity, 1.0e-15);
}

test "GROSUB maintenance structural nitrogen rejects invalid runtime state" {
    try std.testing.expectError(error.InvalidShootStructuralNitrogenInput, structuralNitrogenForMaintenance(.{
        .leaf_nitrogen_g_n = -1,
        .sheath_or_petiole_nitrogen_g_n = 0,
        .sapwood_carbon_g_c = 0,
        .stalk_nitrogen_per_carbon_g_n_per_g_c = 0,
        .husk_nitrogen_g_n = 0,
        .ear_nitrogen_g_n = 0,
        .grain_nitrogen_g_n = 0,
        .physiological_maturity_reached = false,
    }));
}

fn testShootWoodInputs() ShootWoodCompositionInputs {
    return .{
        .biomass_turnover_type = 3,
        .root_profile_type = 2,
        .stalk_carbon_g_c = 10,
        .sapwood_carbon_g_c = 4,
        .structural_presence_threshold_g_c = 1.0e-9,
        .stalk_nitrogen_to_carbon_g_n_per_g_c = 0.01,
        .leaf_nitrogen_to_carbon_g_n_per_g_c = 0.03,
        .sheath_nitrogen_to_carbon_g_n_per_g_c = 0.02,
        .stalk_phosphorus_to_carbon_g_p_per_g_c = 0.001,
        .leaf_phosphorus_to_carbon_g_p_per_g_c = 0.003,
        .sheath_phosphorus_to_carbon_g_p_per_g_c = 0.002,
    };
}

test "GROSUB shoot wood composition preserves woody and weighted branches" {
    const woody = try shootWoodComposition(testShootWoodInputs());
    try std.testing.expectEqual([2]f64{ 0.6, 0.4 }, woody.stalk_carbon_fraction);
    try std.testing.expectEqual(woody.stalk_carbon_fraction, woody.stalk_nitrogen_fraction);
    try std.testing.expectEqual(woody.stalk_carbon_fraction, woody.stalk_phosphorus_fraction);
    try std.testing.expectEqual(@as(f64, 0.03), woody.leaf_growth_nitrogen_to_carbon_g_n_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.002), woody.sheath_growth_phosphorus_to_carbon_g_p_per_g_c);
}

test "GROSUB shoot wood composition forces source nonwoody cases" {
    var inputs = testShootWoodInputs();
    inputs.biomass_turnover_type = 0;
    inputs.root_profile_type = 3;
    const deciduous = try shootWoodComposition(inputs);
    try std.testing.expectEqual([2]f64{ 0, 1 }, deciduous.stalk_carbon_fraction);
    inputs = testShootWoodInputs();
    inputs.root_profile_type = 1;
    const shallow = try shootWoodComposition(inputs);
    try std.testing.expectEqual([2]f64{ 0, 1 }, shallow.stalk_carbon_fraction);
    inputs = testShootWoodInputs();
    inputs.root_profile_type = 3;
    inputs.stalk_carbon_g_c = 1.0e-9;
    inputs.sapwood_carbon_g_c = 1.0e-9;
    const absent = try shootWoodComposition(inputs);
    try std.testing.expectEqual([2]f64{ 0, 1 }, absent.stalk_carbon_fraction);
}

test "GROSUB shoot wood composition rejects invalid source domains" {
    var inputs = testShootWoodInputs();
    inputs.biomass_turnover_type = 6;
    try std.testing.expectError(error.InvalidShootWoodCompositionInput, shootWoodComposition(inputs));
    inputs = testShootWoodInputs();
    inputs.sapwood_carbon_g_c = 11;
    try std.testing.expectError(error.InvalidShootWoodCompositionInput, shootWoodComposition(inputs));
    inputs = testShootWoodInputs();
    inputs.stalk_nitrogen_to_carbon_g_n_per_g_c = std.math.nan(f64);
    try std.testing.expectError(error.InvalidShootWoodCompositionInput, shootWoodComposition(inputs));
}

test "GROSUB shoot maintenance water preserves profile and phenology gates" {
    try std.testing.expectEqual(@as(f64, 0.0625), try maintenanceWaterFraction(0, 0, 0.0625));
    try std.testing.expectEqual(@as(f64, 0.0625), try maintenanceWaterFraction(3, 2, 0.0625));
    try std.testing.expectEqual(@as(f64, 0.5), try maintenanceWaterFraction(1, 0, 0.0625));
    try std.testing.expectEqual(@as(f64, 0.5), try maintenanceWaterFraction(2, 3, 0.0625));
}

test "GROSUB shoot maintenance water rejects invalid runtime state" {
    try std.testing.expectError(error.InvalidShootMaintenanceWaterInput, maintenanceWaterFraction(4, 0, 0.5));
    try std.testing.expectError(error.InvalidShootMaintenanceWaterInput, maintenanceWaterFraction(0, 4, 0.5));
    try std.testing.expectError(error.InvalidShootMaintenanceWaterInput, maintenanceWaterFraction(0, 0, 1.01));
    try std.testing.expectError(error.InvalidShootMaintenanceWaterInput, maintenanceWaterFraction(0, 0, std.math.nan(f64)));
}

fn testPreEmergenceInputs() PreEmergenceInputs {
    return .{
        .mobile_carbon_g_c = 10,
        .mobile_nitrogen_g_n = 1,
        .mobile_phosphorus_g_p = 0.1,
        .mobile_carbon_concentration_g_c_per_g_c = 0.2,
        .mobile_nitrogen_concentration_g_n_per_g_c = 0.09,
        .mobile_phosphorus_concentration_g_p_per_g_c = 0.02,
        .structural_nitrogen_g_n = 0.5,
        .growth_temperature_fraction = 0.8,
        .maintenance_temperature_fraction = 0.7,
        .growth_water_fraction = 0.9,
        .maintenance_water_fraction = 0.6,
        .termination_fraction = 0.75,
        .nutrient_growth_fraction = 0.5,
        .oxygen_limitation_fraction = 0.4,
        .timestep_h = 1,
    };
}

test "GROSUB pre-emergence metabolism preserves dual oxygen paths" {
    const parameters = compatibilityParameters();
    const growth = try coefficients(.{ 0.5, 0.2, 0.1, 0.1, 0.05, 0.05, 0 }, .{0.8} ** partition_module.organ_count, .{0.04} ** partition_module.organ_count, .{0.004} ** partition_module.organ_count, parameters.minimum_leaf_nutrient_fraction);
    const inputs = testPreEmergenceInputs();
    const result = try calculatePreEmergence(parameters, growth, inputs);
    try std.testing.expectApproxEqAbs(result.substrate_respiration_oxygen_unlimited_g_c * inputs.oxygen_limitation_fraction, result.substrate_respiration_actual_g_c, 1.0e-15);
    try std.testing.expect(result.growth_respiration_actual_g_c <= result.growth_respiration_oxygen_unlimited_g_c);
    try std.testing.expectApproxEqAbs(result.growth_respiration_actual_g_c / growth.respiration_fraction_g_c_per_g_c, result.growth_carbon_consumption_actual_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(parameters.nitrogen_assimilation_respiration_g_c_per_g_n * result.assimilated_nitrogen_actual_g_n, result.nitrogen_assimilation_respiration_actual_g_c, 1.0e-15);
}

test "GROSUB pre-emergence zero oxygen retains source maintenance deficit order" {
    const parameters = compatibilityParameters();
    const growth = try coefficients(.{ 0.5, 0.2, 0.1, 0.1, 0.05, 0.05, 0 }, .{0.8} ** partition_module.organ_count, .{0.04} ** partition_module.organ_count, .{0.004} ** partition_module.organ_count, parameters.minimum_leaf_nutrient_fraction);
    var inputs = testPreEmergenceInputs();
    inputs.oxygen_limitation_fraction = 0;
    const result = try calculatePreEmergence(parameters, growth, inputs);
    const maintenance = parameters.maintenance_respiration_g_c_per_g_n_h * inputs.maintenance_temperature_fraction * inputs.structural_nitrogen_g_n * inputs.timestep_h * inputs.maintenance_water_fraction;
    try std.testing.expectEqual(@as(f64, 0), result.substrate_respiration_actual_g_c);
    try std.testing.expectEqual(@as(f64, 0), result.growth_respiration_actual_g_c);
    try std.testing.expectApproxEqAbs(maintenance, result.excess_maintenance_actual_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(2 * maintenance, result.total_respiration_actual_g_c, 1.0e-15);
}

test "GROSUB pre-emergence metabolism rejects invalid state" {
    const parameters = compatibilityParameters();
    const growth = try coefficients(.{ 0.5, 0.2, 0.1, 0.1, 0.05, 0.05, 0 }, .{0.8} ** partition_module.organ_count, .{0.04} ** partition_module.organ_count, .{0.004} ** partition_module.organ_count, parameters.minimum_leaf_nutrient_fraction);
    var inputs = testPreEmergenceInputs();
    inputs.oxygen_limitation_fraction = 1.1;
    try std.testing.expectError(error.InvalidPreEmergenceMetabolismInput, calculatePreEmergence(parameters, growth, inputs));
    inputs = testPreEmergenceInputs();
    inputs.mobile_carbon_g_c = std.math.nan(f64);
    try std.testing.expectError(error.InvalidPreEmergenceMetabolismInput, calculatePreEmergence(parameters, growth, inputs));
}

test "GROSUB growth nutrient ratios copy reserve ratios only to grain" {
    const nitrogen = [_]f64{ 0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.99 };
    const phosphorus = [_]f64{ 0.001, 0.002, 0.003, 0.004, 0.005, 0.006, 0.099 };
    const result = try growthNutrientRatios(nitrogen, phosphorus);
    try std.testing.expectEqual([_]f64{ 0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.04 }, result.nitrogen_to_carbon_g_n_per_g_c);
    try std.testing.expectEqual([_]f64{ 0.001, 0.002, 0.003, 0.004, 0.005, 0.006, 0.004 }, result.phosphorus_to_carbon_g_p_per_g_c);
}

test "GROSUB growth nutrient ratios reject invalid organ values" {
    var nitrogen = [_]f64{0.01} ** partition_module.organ_count;
    const phosphorus = [_]f64{0.001} ** partition_module.organ_count;
    nitrogen[5] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidShootGrowthNutrientRatio, growthNutrientRatios(nitrogen, phosphorus));
    nitrogen[5] = -0.01;
    try std.testing.expectError(error.InvalidShootGrowthNutrientRatio, growthNutrientRatios(nitrogen, phosphorus));
}

test "GROSUB stem diameter refresh requires every source gate" {
    const selected: StemDiameterRefreshInputs = .{
        .day_of_year = 60,
        .hour_of_day = 12,
        .integer_solar_noon_hour = 12,
        .biological_iteration = 1,
        .branch_index = 2,
        .main_branch_index = 2,
        .biomass_turnover_type = 3,
        .root_profile_type = 2,
    };
    try std.testing.expect(try shouldRefreshStemDiameter(selected));
    inline for (.{ "day", "hour", "iteration", "branch", "turnover", "root" }) |gate| {
        var rejected = selected;
        if (std.mem.eql(u8, gate, "day")) rejected.day_of_year = 61;
        if (std.mem.eql(u8, gate, "hour")) rejected.hour_of_day = 11;
        if (std.mem.eql(u8, gate, "iteration")) rejected.biological_iteration = 2;
        if (std.mem.eql(u8, gate, "branch")) rejected.branch_index = 1;
        if (std.mem.eql(u8, gate, "turnover")) rejected.biomass_turnover_type = 0;
        if (std.mem.eql(u8, gate, "root")) rejected.root_profile_type = 0;
        try std.testing.expect(!try shouldRefreshStemDiameter(rejected));
    }
}

test "GROSUB stem diameter refresh rejects invalid selector codes" {
    var inputs: StemDiameterRefreshInputs = .{ .day_of_year = 60, .hour_of_day = 12, .integer_solar_noon_hour = 12, .biological_iteration = 1, .branch_index = 0, .main_branch_index = 0, .biomass_turnover_type = 1, .root_profile_type = 1 };
    inputs.day_of_year = 0;
    try std.testing.expectError(error.InvalidStemDiameterRefreshInput, shouldRefreshStemDiameter(inputs));
    inputs.day_of_year = 60;
    inputs.hour_of_day = 24;
    try std.testing.expectError(error.InvalidStemDiameterRefreshInput, shouldRefreshStemDiameter(inputs));
    inputs.hour_of_day = 12;
    inputs.biological_iteration = 0;
    try std.testing.expectError(error.InvalidStemDiameterRefreshInput, shouldRefreshStemDiameter(inputs));
}

test "GROSUB branch reserve equilibration requires sapwood above cell threshold" {
    try std.testing.expect(!try shouldEquilibrateLateralBranchReserves(0.01, 0.01));
    try std.testing.expect(try shouldEquilibrateLateralBranchReserves(0.0100001, 0.01));
    try std.testing.expect(!try shouldEquilibrateLateralBranchReserves(0, 0));
}

test "GROSUB branch reserve equilibration rejects invalid threshold state" {
    try std.testing.expectError(
        error.InvalidBranchReserveEquilibrationInput,
        shouldEquilibrateLateralBranchReserves(-0.01, 0),
    );
    try std.testing.expectError(
        error.InvalidBranchReserveEquilibrationInput,
        shouldEquilibrateLateralBranchReserves(0.01, std.math.nan(f64)),
    );
}

test "GROSUB branch nutrient equilibration uses pre-exchange carbon threshold" {
    try std.testing.expect(!try shouldEquilibrateBranchReserveNutrients(0.02, 0.02));
    try std.testing.expect(try shouldEquilibrateBranchReserveNutrients(0.020001, 0.02));
    try std.testing.expectError(
        error.InvalidBranchReserveEquilibrationInput,
        shouldEquilibrateBranchReserveNutrients(-0.01, 0),
    );
}

test "GROSUB ZEROP adapter scales runtime threshold by current population" {
    try std.testing.expectApproxEqAbs(
        @as(f64, 3.0e-13),
        try plantScaledPresenceThresholdG(1.0e-15, 300),
        1.0e-28,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        try plantScaledPresenceThresholdG(1.0e-15, 0),
    );
}

test "GROSUB ZEROP adapter rejects invalid runtime inputs" {
    try std.testing.expectError(
        error.InvalidPlantPresenceThresholdInput,
        plantScaledPresenceThresholdG(-1.0e-15, 1),
    );
    try std.testing.expectError(
        error.InvalidPlantPresenceThresholdInput,
        plantScaledPresenceThresholdG(1.0e-15, std.math.inf(f64)),
    );
}
