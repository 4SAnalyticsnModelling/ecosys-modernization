const std = @import("std");
const retention = @import("retention.zig");

pub const VaporEquilibriumParameters = struct {
    vapor_density_temperature_coefficient: f64,
    molecular_weight_ratio: f64,
    clausius_clapeyron_coefficient_k: f64,
    reference_inverse_temperature_per_k: f64,
    water_molar_mass_g_per_mol: f64,
    gas_constant_j_per_mol_k: f64,
    latent_heat_of_vaporization_megajoules_per_m3: f64,
};

pub const VaporEquilibrium = struct {
    saturated_vapor_fraction: f64,
    water_condensation_m3: f64,
    vapor_change_m3: f64,
    latent_heat_megajoules: f64,
};

/// Positive water_condensation_m3 converts vapor to liquid; negative values
/// evaporate liquid. This is WATSUB's below-surface VOLV/VOLW equilibrium.
pub fn vaporLiquidEquilibrium(temperature_k: f64, matric_plus_osmotic_potential_megapascal: f64, vapor_volume_m3: f64, air_volume_m3: f64, liquid_water_m3: f64, time_fraction: f64, parameters: VaporEquilibriumParameters) !VaporEquilibrium {
    inline for (.{ temperature_k, matric_plus_osmotic_potential_megapascal, vapor_volume_m3, air_volume_m3, liquid_water_m3, time_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilPhaseInput;
    inline for (@typeInfo(VaporEquilibriumParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteSoilPhaseInput;
    if (temperature_k <= 0 or vapor_volume_m3 < 0 or air_volume_m3 < 0 or liquid_water_m3 < 0 or time_fraction <= 0 or time_fraction > 1 or parameters.vapor_density_temperature_coefficient <= 0 or parameters.molecular_weight_ratio <= 0 or parameters.clausius_clapeyron_coefficient_k <= 0 or parameters.reference_inverse_temperature_per_k <= 0 or parameters.water_molar_mass_g_per_mol <= 0 or parameters.gas_constant_j_per_mol_k <= 0 or parameters.latent_heat_of_vaporization_megajoules_per_m3 <= 0) return error.InvalidSoilPhaseInput;
    const saturation = parameters.vapor_density_temperature_coefficient / temperature_k * parameters.molecular_weight_ratio * @exp(parameters.clausius_clapeyron_coefficient_k * (parameters.reference_inverse_temperature_per_k - 1.0 / temperature_k)) * @exp(parameters.water_molar_mass_g_per_mol * matric_plus_osmotic_potential_megapascal / (parameters.gas_constant_j_per_mol_k * temperature_k));
    const unlimited = vapor_volume_m3 - saturation * air_volume_m3;
    const water_change = @max(unlimited, -liquid_water_m3 * time_fraction);
    const latent = parameters.latent_heat_of_vaporization_megajoules_per_m3 * water_change;
    if (!std.math.isFinite(saturation) or saturation < 0 or !std.math.isFinite(water_change) or !std.math.isFinite(latent)) return error.NonFiniteSoilPhaseFlux;
    return .{ .saturated_vapor_fraction = saturation, .water_condensation_m3 = water_change, .vapor_change_m3 = -water_change, .latent_heat_megajoules = latent };
}

pub const FreezeThawParameters = struct {
    freezing_potential_numerator_k_megapascal: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    ice_density_megagrams_per_m3: f64,
    heat_capacity_temperature_feedback_per_k: f64,
    pure_water_freezing_temperature_k: f64,
};

pub const FreezeThaw = struct {
    freezing_temperature_k: f64,
    liquid_water_change_m3: f64,
    ice_volume_change_m3: f64,
    latent_heat_megajoules: f64,
};

pub const DallAmicoEquilibriumInputs = struct {
    temperature_k: f64,
    total_water_equivalent_m3: f64,
    porous_medium_volume_m3: f64,
    unfrozen_pressure_head_m: f64,
    gravitational_water_potential_mpa_per_m: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    mualem_van_genuchten: retention.MualemVanGenuchtenParameters,
};

pub const DallAmicoEquilibrium = struct {
    depressed_melting_temperature_k: f64,
    liquid_pressure_head_m: f64,
    liquid_water_m3: f64,
    ice_water_equivalent_m3: f64,
};

/// Dall'Amico et al. (2011), Eqs. 11-12 and 20-24. We retain the exact
/// integrated Clapeyron logarithm from Eqs. 11-12 rather than the linearized
/// approximation in Eq. 13. The two are first-order equivalent around the
/// melting point, while the exact form remains positive for very dry soil.
/// Ice is returned as water-equivalent volume because the paper assumes a
/// rigid porous medium with equal water and ice densities. Mechanical
/// frost-heave volume is a separate geometry process and must not alter this
/// conservative closure.
pub fn dallAmicoEquilibrium(inputs: DallAmicoEquilibriumInputs) !DallAmicoEquilibrium {
    inline for (@typeInfo(DallAmicoEquilibriumInputs).@"struct".fields) |field| {
        if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteDallAmicoInput;
    }
    if (inputs.temperature_k <= 0 or
        inputs.total_water_equivalent_m3 < 0 or
        inputs.porous_medium_volume_m3 <= 0 or
        inputs.unfrozen_pressure_head_m > 0 or
        inputs.gravitational_water_potential_mpa_per_m <= 0 or
        inputs.latent_heat_of_fusion_megajoules_per_m3 <= 0 or
        inputs.pure_water_melting_temperature_k <= 0)
    {
        return error.InvalidDallAmicoInput;
    }
    try inputs.mualem_van_genuchten.validate();
    // `DALLAMICO-BELOW-RESIDUAL-WATER-HOUR-2726-001` and the zero-water case before
    // it. A below-residual total is not a defect and needs no special handling,
    // because **the computation below never uses the water content at all**:
    //
    //   * the retention inverse is called with a PRESSURE HEAD
    //     (`waterContentAtPressureHead(liquid_pressure_head_m)`), not a content;
    //   * `liquid_water_m3 = @min(total_water_equivalent_m3, retention_limited)`
    //     already caps the liquid at what the layer actually holds;
    //   * `ice_water_equivalent_m3 = total - liquid` is therefore already
    //     non-negative by construction.
    //
    // So for a very dry layer the normal path returns `liquid = total, ice = 0`
    // continuously, in both temperature and water content. The residual half of
    // this precondition was rejecting states the arithmetic handles correctly.
    //
    // It also contradicted this function's own contract: the input validation above
    // accepts `total_water_equivalent_m3 == 0` (it rejects only negatives), and the
    // doc records that the exact Clapeyron form was kept specifically because it
    // "remains positive for very dry soil".
    //
    // Two measured states, both a surface layer baked dry by evaporation far above
    // any melting point. The van Genuchten residual bounds what *capillary*
    // processes can remove; evaporation removes more, which is how the deck arrives
    // here:
    //
    //   hour 2,705  content 0                      residual 9.5e-2  at 312.12 K (39 C)
    //   hour 2,726  content 3.4687218985266395e-2  residual 9.5e-2  at 319.80 K (46.7 C)
    //
    // A previous attempt short-circuited this case with an unconditional
    // `ice = 0` return and produced `SoilHeatSolverStagnated` at the same hour: that
    // was a genuine discontinuity, since `ice = 0` is right at 46.7 C and wrong
    // below freezing, and the heat solver's Newton iteration explores temperature
    // space. Letting the normal path run instead introduces no such step.
    //
    // Above saturation still rejects: an over-filled medium is a real defect,
    // whereas a sun-dried one is a real state.
    const total_water_content =
        inputs.total_water_equivalent_m3 / inputs.porous_medium_volume_m3;
    const tolerance = 64.0 * std.math.floatEps(f64);
    if (total_water_content >
        inputs.mualem_van_genuchten.saturated_water_content_m3_per_m3 + tolerance)
    {
        // Frontier blocker after MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001 was
        // fixed: the deck reaches 2,704 h and stops here. Name which bound was
        // crossed and by how much, so the next step is decided by a measurement
        // rather than by guessing whether this is an over-fill or a domain that is
        // too tight.
        std.log.info(
            "total water outside retention domain: content={e} residual={e} saturated={e} below_by={e} above_by={e} total_water_m3={e} medium_volume_m3={e}",
            .{
                total_water_content,
                inputs.mualem_van_genuchten.residual_water_content_m3_per_m3,
                inputs.mualem_van_genuchten.saturated_water_content_m3_per_m3,
                inputs.mualem_van_genuchten.residual_water_content_m3_per_m3 - total_water_content,
                total_water_content - inputs.mualem_van_genuchten.saturated_water_content_m3_per_m3,
                inputs.total_water_equivalent_m3,
                inputs.porous_medium_volume_m3,
            },
        );
        return error.TotalWaterOutsideRetentionDomain;
    }
    const clapeyron_exponent =
        inputs.gravitational_water_potential_mpa_per_m *
        inputs.unfrozen_pressure_head_m /
        inputs.latent_heat_of_fusion_megajoules_per_m3;
    const minimum_exponent =
        @log(std.math.floatMin(f64)) -
        @log(inputs.pure_water_melting_temperature_k);
    const melting_temperature_k =
        inputs.pure_water_melting_temperature_k *
        @exp(@max(minimum_exponent, clapeyron_exponent));
    if (!std.math.isFinite(melting_temperature_k) or melting_temperature_k <= 0)
        return error.NonFiniteDallAmicoEquilibrium;
    const liquid_pressure_head_m = if (inputs.temperature_k < melting_temperature_k)
        inputs.unfrozen_pressure_head_m +
            inputs.latent_heat_of_fusion_megajoules_per_m3 /
                inputs.gravitational_water_potential_mpa_per_m *
                std.math.log1p(
                    (inputs.temperature_k - melting_temperature_k) /
                        melting_temperature_k,
                )
    else
        inputs.unfrozen_pressure_head_m;
    const retention_limited_liquid_m3 =
        try inputs.mualem_van_genuchten.waterContentAtPressureHead(
            liquid_pressure_head_m,
        ) * inputs.porous_medium_volume_m3;
    const liquid_water_m3 = @min(
        inputs.total_water_equivalent_m3,
        retention_limited_liquid_m3,
    );
    const ice_water_equivalent_m3 =
        inputs.total_water_equivalent_m3 - liquid_water_m3;
    if (!std.math.isFinite(liquid_pressure_head_m) or
        !std.math.isFinite(liquid_water_m3) or liquid_water_m3 < 0 or
        !std.math.isFinite(ice_water_equivalent_m3) or
        ice_water_equivalent_m3 < 0)
    {
        return error.NonFiniteDallAmicoEquilibrium;
    }
    return .{
        .depressed_melting_temperature_k = melting_temperature_k,
        .liquid_pressure_head_m = liquid_pressure_head_m,
        .liquid_water_m3 = liquid_water_m3,
        .ice_water_equivalent_m3 = ice_water_equivalent_m3,
    };
}

pub const PhaseEnthalpyState = struct {
    matrix_liquid_water_m3: f64,
    water_vapor_volume_m3: f64,
    matrix_ice_volume_m3: f64,
    macropore_liquid_water_m3: f64,
    macropore_ice_volume_m3: f64,
};

pub const PhaseEnthalpyParameters = struct {
    liquid_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    vaporization_latent_heat_megajoules_per_m3: f64,
    fusion_latent_heat_megajoules_per_m3: f64,
};

/// Exact endpoint form of WATSUB's ENGY1/VHCP1/TK1 update for phase changes.
/// Conductive, convective, combustion, and imposed heat are supplied separately
/// because they belong to the coupled spatial heat residual.
pub fn endpointTemperatureFromPhaseEnthalpy(
    initial_temperature_k: f64,
    initial_heat_capacity_megajoules_per_k: f64,
    initial: PhaseEnthalpyState,
    endpoint: PhaseEnthalpyState,
    non_phase_heat_megajoules: f64,
    parameters: PhaseEnthalpyParameters,
) !f64 {
    inline for (.{ initial_temperature_k, initial_heat_capacity_megajoules_per_k, non_phase_heat_megajoules, parameters.liquid_heat_capacity_megajoules_per_m3_k, parameters.ice_heat_capacity_megajoules_per_m3_k, parameters.vaporization_latent_heat_megajoules_per_m3, parameters.fusion_latent_heat_megajoules_per_m3 }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilPhaseInput;
    inline for (@typeInfo(PhaseEnthalpyState).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(initial, field.name)) or !std.math.isFinite(@field(endpoint, field.name)) or @field(initial, field.name) < 0 or @field(endpoint, field.name) < 0) return error.InvalidSoilPhaseInput;
    }
    if (initial_temperature_k <= 0 or initial_heat_capacity_megajoules_per_k <= 0 or parameters.liquid_heat_capacity_megajoules_per_m3_k <= 0 or parameters.ice_heat_capacity_megajoules_per_m3_k <= 0 or parameters.vaporization_latent_heat_megajoules_per_m3 <= 0 or parameters.fusion_latent_heat_megajoules_per_m3 <= 0) return error.InvalidSoilPhaseInput;
    const initial_liquid_and_vapor_m3 = initial.matrix_liquid_water_m3 + initial.water_vapor_volume_m3 + initial.macropore_liquid_water_m3;
    const initial_ice_m3 = initial.matrix_ice_volume_m3 + initial.macropore_ice_volume_m3;
    const solid_heat_capacity_megajoules_per_k = initial_heat_capacity_megajoules_per_k - parameters.liquid_heat_capacity_megajoules_per_m3_k * initial_liquid_and_vapor_m3 - parameters.ice_heat_capacity_megajoules_per_m3_k * initial_ice_m3;
    if (!std.math.isFinite(solid_heat_capacity_megajoules_per_k) or solid_heat_capacity_megajoules_per_k < 0) {
        std.log.err(
            "invalid soil phase solid heat capacity: initial_heat_capacity_megajoules_per_k={e} initial_matrix_liquid_water_m3={e} initial_water_vapor_volume_m3={e} initial_matrix_ice_water_equivalent_m3={e} initial_macropore_liquid_water_m3={e} initial_macropore_ice_water_equivalent_m3={e} liquid_heat_capacity_megajoules_per_m3_k={e} ice_heat_capacity_megajoules_per_m3_k={e} derived_solid_heat_capacity_megajoules_per_k={e}",
            .{
                initial_heat_capacity_megajoules_per_k,
                initial.matrix_liquid_water_m3,
                initial.water_vapor_volume_m3,
                initial.matrix_ice_volume_m3,
                initial.macropore_liquid_water_m3,
                initial.macropore_ice_volume_m3,
                parameters.liquid_heat_capacity_megajoules_per_m3_k,
                parameters.ice_heat_capacity_megajoules_per_m3_k,
                solid_heat_capacity_megajoules_per_k,
            },
        );
        return error.InvalidSoilPhaseHeatCapacity;
    }
    const endpoint_heat_capacity_megajoules_per_k = solid_heat_capacity_megajoules_per_k + parameters.liquid_heat_capacity_megajoules_per_m3_k * (endpoint.matrix_liquid_water_m3 + endpoint.water_vapor_volume_m3 + endpoint.macropore_liquid_water_m3) + parameters.ice_heat_capacity_megajoules_per_m3_k * (endpoint.matrix_ice_volume_m3 + endpoint.macropore_ice_volume_m3);
    if (!std.math.isFinite(endpoint_heat_capacity_megajoules_per_k) or endpoint_heat_capacity_megajoules_per_k <= 0) {
        std.log.err(
            "invalid soil phase endpoint heat capacity: solid_heat_capacity_megajoules_per_k={e} endpoint_matrix_liquid_water_m3={e} endpoint_water_vapor_volume_m3={e} endpoint_matrix_ice_water_equivalent_m3={e} endpoint_macropore_liquid_water_m3={e} endpoint_macropore_ice_water_equivalent_m3={e} endpoint_heat_capacity_megajoules_per_k={e}",
            .{
                solid_heat_capacity_megajoules_per_k,
                endpoint.matrix_liquid_water_m3,
                endpoint.water_vapor_volume_m3,
                endpoint.matrix_ice_volume_m3,
                endpoint.macropore_liquid_water_m3,
                endpoint.macropore_ice_volume_m3,
                endpoint_heat_capacity_megajoules_per_k,
            },
        );
        return error.InvalidSoilPhaseHeatCapacity;
    }
    const condensation_heat_megajoules = parameters.vaporization_latent_heat_megajoules_per_m3 * (initial.water_vapor_volume_m3 - endpoint.water_vapor_volume_m3);
    // Ice inventories are liquid-water-equivalent volumes. Fusion latent heat
    // is defined per m3 WE, so density must not appear here.
    const freezing_heat_megajoules = parameters.fusion_latent_heat_megajoules_per_m3 * ((endpoint.matrix_ice_volume_m3 + endpoint.macropore_ice_volume_m3) - initial_ice_m3);
    const endpoint_temperature_k = (initial_heat_capacity_megajoules_per_k * initial_temperature_k + non_phase_heat_megajoules + condensation_heat_megajoules + freezing_heat_megajoules) / endpoint_heat_capacity_megajoules_per_k;
    if (!std.math.isFinite(endpoint_temperature_k) or endpoint_temperature_k <= 0) return error.NonFiniteSoilPhaseFlux;
    return endpoint_temperature_k;
}

pub fn matrixFreezeThaw(temperature_k: f64, matric_plus_osmotic_potential_megapascal: f64, liquid_water_m3: f64, ice_volume_m3: f64, heat_capacity_megajoules_per_k: f64, time_fraction: f64, parameters: FreezeThawParameters) !FreezeThaw {
    return freezeThaw(temperature_k, matric_plus_osmotic_potential_megapascal, liquid_water_m3, ice_volume_m3, heat_capacity_megajoules_per_k, time_fraction, false, parameters);
}

pub fn macroporeFreezeThaw(temperature_k: f64, matric_plus_osmotic_potential_megapascal: f64, liquid_water_m3: f64, ice_volume_m3: f64, liquid_heat_capacity_megajoules_per_m3_k: f64, ice_heat_capacity_megajoules_per_m3_k: f64, time_fraction: f64, parameters: FreezeThawParameters) !FreezeThaw {
    if (!std.math.isFinite(liquid_heat_capacity_megajoules_per_m3_k) or liquid_heat_capacity_megajoules_per_m3_k <= 0 or !std.math.isFinite(ice_heat_capacity_megajoules_per_m3_k) or ice_heat_capacity_megajoules_per_m3_k <= 0) return error.InvalidSoilPhaseInput;
    const capacity = liquid_heat_capacity_megajoules_per_m3_k * liquid_water_m3 + ice_heat_capacity_megajoules_per_m3_k * ice_volume_m3;
    return freezeThaw(temperature_k, matric_plus_osmotic_potential_megapascal, liquid_water_m3, ice_volume_m3, capacity, time_fraction, true, parameters);
}

fn freezeThaw(temperature_k: f64, potential_megapascal: f64, liquid_m3: f64, ice_m3: f64, capacity_megajoules_per_k: f64, time_fraction: f64, macropore: bool, parameters: FreezeThawParameters) !FreezeThaw {
    inline for (.{ temperature_k, potential_megapascal, liquid_m3, ice_m3, capacity_megajoules_per_k, time_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilPhaseInput;
    inline for (@typeInfo(FreezeThawParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteSoilPhaseInput;
    if (temperature_k <= 0 or liquid_m3 < 0 or ice_m3 < 0 or capacity_megajoules_per_k < 0 or time_fraction <= 0 or time_fraction > 1 or parameters.freezing_potential_numerator_k_megapascal <= 0 or parameters.latent_heat_of_fusion_megajoules_per_m3 <= 0 or parameters.ice_density_megagrams_per_m3 <= 0 or parameters.heat_capacity_temperature_feedback_per_k < 0 or parameters.pure_water_freezing_temperature_k <= 0 or potential_megapascal == parameters.latent_heat_of_fusion_megajoules_per_m3) return error.InvalidSoilPhaseInput;
    const freezing_temperature = -parameters.freezing_potential_numerator_k_megapascal / (potential_megapascal - parameters.latent_heat_of_fusion_megajoules_per_m3);
    const threshold_temperature = if (macropore) parameters.pure_water_freezing_temperature_k else freezing_temperature;
    if (!((temperature_k < threshold_temperature and liquid_m3 > 0) or (temperature_k > threshold_temperature and ice_m3 > 0))) return .{ .freezing_temperature_k = freezing_temperature, .liquid_water_change_m3 = 0, .ice_volume_change_m3 = 0, .latent_heat_megajoules = 0 };
    const unlimited_heat = capacity_megajoules_per_k * (freezing_temperature - temperature_k) / (1.0 + parameters.heat_capacity_temperature_feedback_per_k * freezing_temperature);
    const heat = if (unlimited_heat < 0)
        @max(-parameters.latent_heat_of_fusion_megajoules_per_m3 * parameters.ice_density_megagrams_per_m3 * ice_m3 * time_fraction, unlimited_heat)
    else
        @min(parameters.latent_heat_of_fusion_megajoules_per_m3 * liquid_m3 * time_fraction, unlimited_heat);
    const liquid_change = -heat / parameters.latent_heat_of_fusion_megajoules_per_m3;
    const ice_change = -liquid_change / parameters.ice_density_megagrams_per_m3;
    if (!std.math.isFinite(freezing_temperature) or freezing_temperature <= 0 or !std.math.isFinite(heat)) return error.NonFiniteSoilPhaseFlux;
    return .{ .freezing_temperature_k = freezing_temperature, .liquid_water_change_m3 = liquid_change, .ice_volume_change_m3 = ice_change, .latent_heat_megajoules = heat };
}

pub const PoreExchangeInputs = struct {
    saturated_lateral_matrix_conductivity_m2_per_h_megapascal: f64,
    face_area_m2: f64,
    saturation_water_potential_megapascal: f64,
    current_matric_potential_megapascal: f64,
    macropore_spacing_m: f64,
    macropore_radius_m: f64,
    time_fraction: f64,
    matrix_water_m3: f64,
    matrix_air_m3: f64,
    macropore_water_m3: f64,
    macropore_air_m3: f64,
};

/// FINHL: positive transfers macropore water into matrix; negative reverses.
pub fn macroporeMatrixExchange(inputs: PoreExchangeInputs) !f64 {
    inline for (@typeInfo(PoreExchangeInputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteSoilPhaseInput;
    if (inputs.saturated_lateral_matrix_conductivity_m2_per_h_megapascal < 0 or inputs.face_area_m2 < 0 or inputs.macropore_spacing_m <= inputs.macropore_radius_m or inputs.macropore_radius_m <= 0 or inputs.time_fraction <= 0 or inputs.time_fraction > 1 or inputs.matrix_water_m3 < 0 or inputs.matrix_air_m3 < 0 or inputs.macropore_water_m3 < 0 or inputs.macropore_air_m3 < 0) return error.InvalidSoilPhaseInput;
    const unlimited = 6.283 * inputs.saturated_lateral_matrix_conductivity_m2_per_h_megapascal * inputs.face_area_m2 * (inputs.saturation_water_potential_megapascal - inputs.current_matric_potential_megapascal) / @log(inputs.macropore_spacing_m / inputs.macropore_radius_m) * inputs.time_fraction;
    const limited = if (unlimited > 0) @max(0.0, @min(unlimited, @min(inputs.macropore_water_m3, inputs.matrix_air_m3))) else @min(0.0, @max(unlimited, @max(-inputs.macropore_air_m3, -inputs.matrix_water_m3)));
    if (!std.math.isFinite(limited)) return error.NonFiniteSoilPhaseFlux;
    return limited;
}

fn freezeParameters() FreezeThawParameters {
    return .{ .freezing_potential_numerator_k_megapascal = 9.0959e4, .latent_heat_of_fusion_megajoules_per_m3 = 333, .ice_density_megagrams_per_m3 = 0.917, .heat_capacity_temperature_feedback_per_k = 6.2913e-3, .pure_water_freezing_temperature_k = 273.15 };
}

test "soil vapor equilibrium conserves liquid plus vapor volume" {
    const result = try vaporLiquidEquilibrium(280, -0.1, 0.01, 1, 0.5, 1, .{ .vapor_density_temperature_coefficient = 2.173e-3, .molecular_weight_ratio = 0.61, .clausius_clapeyron_coefficient_k = 5360, .reference_inverse_temperature_per_k = 3.661e-3, .water_molar_mass_g_per_mol = 18, .gas_constant_j_per_mol_k = 8.3143, .latent_heat_of_vaporization_megajoules_per_m3 = 2450 });
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.water_condensation_m3 + result.vapor_change_m3, 1e-15);
}

test "matrix freezing converts liquid to denser ice volume" {
    const result = try matrixFreezeThaw(260, -1, 1, 0, 4.19, 1, freezeParameters());
    try std.testing.expect(result.latent_heat_megajoules > 0);
    try std.testing.expect(result.liquid_water_change_m3 < 0);
    try std.testing.expect(result.ice_volume_change_m3 > 0);
}

test "Dall'Amico equilibrium conserves water and depresses unsaturated melting point" {
    const parameters: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.45,
        .alpha_per_m = 1.6,
        .n = 1.6,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    };
    const initial_pressure_head_m = -2.0;
    const total_water_m3 =
        try parameters.waterContentAtPressureHead(initial_pressure_head_m);
    const result = try dallAmicoEquilibrium(.{
        .temperature_k = 268,
        .total_water_equivalent_m3 = total_water_m3,
        .porous_medium_volume_m3 = 1,
        .unfrozen_pressure_head_m = initial_pressure_head_m,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.55,
        .pure_water_melting_temperature_k = 273.15,
        .mualem_van_genuchten = parameters,
    });
    try std.testing.expect(result.depressed_melting_temperature_k < 273.15);
    try std.testing.expect(result.liquid_pressure_head_m < initial_pressure_head_m);
    try std.testing.expect(result.ice_water_equivalent_m3 > 0);
    try std.testing.expectApproxEqAbs(
        total_water_m3,
        result.liquid_water_m3 + result.ice_water_equivalent_m3,
        1e-14,
    );
}

test "Dall'Amico equilibrium leaves warm unsaturated soil unfrozen" {
    const parameters: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.45,
        .alpha_per_m = 1.6,
        .n = 1.6,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    };
    const pressure_head_m = -2.0;
    const total_water_m3 =
        try parameters.waterContentAtPressureHead(pressure_head_m);
    const result = try dallAmicoEquilibrium(.{
        .temperature_k = 273.15,
        .total_water_equivalent_m3 = total_water_m3,
        .porous_medium_volume_m3 = 1,
        .unfrozen_pressure_head_m = pressure_head_m,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.55,
        .pure_water_melting_temperature_k = 273.15,
        .mualem_van_genuchten = parameters,
    });
    try std.testing.expectApproxEqAbs(total_water_m3, result.liquid_water_m3, 1e-14);
    try std.testing.expectEqual(@as(f64, 0), result.ice_water_equivalent_m3);
}

test "exact Clapeyron equilibrium remains finite for an extremely dry macropore" {
    const parameters: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 15,
        .n = 2.68,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    };
    const pressure_head_m = -1.0e12;
    const total_water_m3 =
        try parameters.waterContentAtPressureHead(pressure_head_m);
    const result = try dallAmicoEquilibrium(.{
        .temperature_k = 250,
        .total_water_equivalent_m3 = total_water_m3,
        .porous_medium_volume_m3 = 1,
        .unfrozen_pressure_head_m = pressure_head_m,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.55,
        .pure_water_melting_temperature_k = 273.15,
        .mualem_van_genuchten = parameters,
    });
    try std.testing.expect(std.math.isFinite(
        result.depressed_melting_temperature_k,
    ));
    try std.testing.expect(result.depressed_melting_temperature_k > 0);
    try std.testing.expect(std.math.isFinite(result.liquid_pressure_head_m));
    try std.testing.expectApproxEqAbs(
        total_water_m3,
        result.liquid_water_m3 + result.ice_water_equivalent_m3,
        1.0e-30,
    );
}

test "macropore matrix exchange is bounded by receiving air" {
    const result = try macroporeMatrixExchange(.{ .saturated_lateral_matrix_conductivity_m2_per_h_megapascal = 1, .face_area_m2 = 1, .saturation_water_potential_megapascal = -0.0005, .current_matric_potential_megapascal = -1, .macropore_spacing_m = 1, .macropore_radius_m = 0.01, .time_fraction = 1, .matrix_water_m3 = 1, .matrix_air_m3 = 0.02, .macropore_water_m3 = 1, .macropore_air_m3 = 0 });
    try std.testing.expectEqual(@as(f64, 0.02), result);
}

test "FINHL reverse branch is limited by matrix donor and macropore air" {
    const result = try macroporeMatrixExchange(.{
        .saturated_lateral_matrix_conductivity_m2_per_h_megapascal = 1,
        .face_area_m2 = 1,
        .saturation_water_potential_megapascal = -1,
        .current_matric_potential_megapascal = -0.0005,
        .macropore_spacing_m = 1,
        .macropore_radius_m = 0.01,
        .time_fraction = 1,
        .matrix_water_m3 = 0.03,
        .matrix_air_m3 = 1,
        .macropore_water_m3 = 0.1,
        .macropore_air_m3 = 0.02,
    });
    try std.testing.expectEqual(@as(f64, -0.02), result);
}

test "endpoint phase enthalpy reproduces WATSUB heat-capacity and latent-energy update" {
    const parameters: PhaseEnthalpyParameters = .{ .liquid_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274 / 0.917, .vaporization_latent_heat_megajoules_per_m3 = 2450.0, .fusion_latent_heat_megajoules_per_m3 = 333.0 };
    const initial: PhaseEnthalpyState = .{ .matrix_liquid_water_m3 = 0.5, .water_vapor_volume_m3 = 0.01, .matrix_ice_volume_m3 = 0.1, .macropore_liquid_water_m3 = 0.05, .macropore_ice_volume_m3 = 0.01 };
    const solid_capacity = 2.0;
    const initial_capacity = solid_capacity + 4.19 * 0.56 + (1.9274 / 0.917) * 0.11;
    const endpoint: PhaseEnthalpyState = .{ .matrix_liquid_water_m3 = 0.488, .water_vapor_volume_m3 = 0.008, .matrix_ice_volume_m3 = 0.11, .macropore_liquid_water_m3 = 0.05, .macropore_ice_volume_m3 = 0.01 };
    const actual = try endpointTemperatureFromPhaseEnthalpy(270, initial_capacity, initial, endpoint, 0.25, parameters);
    const endpoint_capacity = solid_capacity + 4.19 * 0.546 + (1.9274 / 0.917) * 0.12;
    const expected = (initial_capacity * 270 + 0.25 + 2450 * 0.002 + 333 * 0.01) / endpoint_capacity;
    try std.testing.expectApproxEqAbs(expected, actual, 1e-12);
}
