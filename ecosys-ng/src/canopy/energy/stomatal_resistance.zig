const std = @import("std");
const aqueous_gas = @import("../gas/aqueous_environment.zig");

pub const GasEnvironment = struct {
    air_amount_mol_per_m3: f64,
    intercellular_co2_umol_per_mol: f64,
    co2_solubility_umol_per_l_per_umol_per_mol: f64,
    o2_solubility_umol_per_l_per_umol_per_mol: f64,
    dissolved_co2_umol_per_l: f64,
    dissolved_o2_umol_per_l: f64,
    atmospheric_to_intercellular_co2_umol_per_m3: f64,
    rubisco_carboxylation_temperature_factor: f64,
    rubisco_oxygenation_temperature_factor: f64,
    electron_transport_temperature_factor: f64,
    rubisco_co2_half_saturation_umol_per_l: f64,
    rubisco_co2_half_saturation_with_o2_umol_per_l: f64,
    /// Arrhenius-scaled O2 Michaelis constant (matches STOMATE's XKO2L,
    /// stomate.f:106), not the raw 25 C value. The CO2 compensation point
    /// (stomate.f:441-442/497-498) must use this scaled value, not the
    /// caller's 25 C PFT constant.
    rubisco_o2_half_saturation_umol_per_l: f64,
};

/// Temperature and gas terms at the opening of STOMATE. Concentrations retain
/// the model's micromolar convention while names make the unit boundary explicit.
pub fn gasEnvironment(
    canopy_temperature_k: f64,
    thermal_adaptation_offset_k: f64,
    atmospheric_co2_umol_per_mol: f64,
    intercellular_to_atmospheric_co2_ratio: f64,
    intercellular_o2_umol_per_mol: f64,
    rubisco_co2_half_saturation_25c_umol_per_l: f64,
    rubisco_o2_half_saturation_25c_umol_per_l: f64,
) !GasEnvironment {
    inline for (.{ canopy_temperature_k, thermal_adaptation_offset_k, atmospheric_co2_umol_per_mol, intercellular_to_atmospheric_co2_ratio, intercellular_o2_umol_per_mol, rubisco_co2_half_saturation_25c_umol_per_l, rubisco_o2_half_saturation_25c_umol_per_l }) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopyGasInput;
    if (canopy_temperature_k <= 0 or canopy_temperature_k + thermal_adaptation_offset_k <= 0 or atmospheric_co2_umol_per_mol < 0 or intercellular_to_atmospheric_co2_ratio < 0 or intercellular_o2_umol_per_mol < 0 or rubisco_co2_half_saturation_25c_umol_per_l <= 0 or rubisco_o2_half_saturation_25c_umol_per_l <= 0) return error.InvalidCanopyGasInput;

    const canopy_temperature_c = canopy_temperature_k - 273.15;
    const adapted_temperature_k = canopy_temperature_k + thermal_adaptation_offset_k;
    const gas_constant_temperature_j_per_mol = 8.3143 * adapted_temperature_k;
    const entropy_temperature_j_per_mol = 710.0 * adapted_temperature_k;
    const inactivation = 1.0 + @exp((197_500.0 - entropy_temperature_j_per_mol) / gas_constant_temperature_j_per_mol) + @exp((entropy_temperature_j_per_mol - 222_500.0) / gas_constant_temperature_j_per_mol);
    const intercellular_co2 = intercellular_to_atmospheric_co2_ratio * atmospheric_co2_umol_per_mol;
    const source_gases = try aqueous_gas.compute(.{
        .canopy_temperature_c = canopy_temperature_c,
        .air_amount_mol_per_m3 = 12_194.0 / canopy_temperature_k,
        .atmospheric_co2_umol_per_mol = atmospheric_co2_umol_per_mol,
        .intercellular_co2_umol_per_mol = intercellular_co2,
        .intercellular_o2_umol_per_mol = intercellular_o2_umol_per_mol,
    });
    const co2_half_saturation = rubisco_co2_half_saturation_25c_umol_per_l * @exp(16.136 - 40_000.0 / gas_constant_temperature_j_per_mol);
    const o2_half_saturation = rubisco_o2_half_saturation_25c_umol_per_l * @exp(8.067 - 20_000.0 / gas_constant_temperature_j_per_mol);
    const result: GasEnvironment = .{
        .air_amount_mol_per_m3 = 12_194.0 / canopy_temperature_k,
        .intercellular_co2_umol_per_mol = intercellular_co2,
        .co2_solubility_umol_per_l_per_umol_per_mol = source_gases.co2_solubility_umol_per_l_per_umol_per_mol,
        .o2_solubility_umol_per_l_per_umol_per_mol = source_gases.o2_solubility_umol_per_l_per_umol_per_mol,
        .dissolved_co2_umol_per_l = source_gases.dissolved_co2_umol_per_l,
        .dissolved_o2_umol_per_l = source_gases.dissolved_o2_umol_per_l,
        .atmospheric_to_intercellular_co2_umol_per_m3 = source_gases.atmospheric_to_intercellular_co2_umol_per_m3,
        .rubisco_carboxylation_temperature_factor = @exp(26.237 - 65_000.0 / gas_constant_temperature_j_per_mol) / inactivation,
        .rubisco_oxygenation_temperature_factor = @exp(24.220 - 60_000.0 / gas_constant_temperature_j_per_mol) / inactivation,
        .electron_transport_temperature_factor = @exp(17.362 - 43_000.0 / gas_constant_temperature_j_per_mol) / inactivation,
        .rubisco_co2_half_saturation_umol_per_l = co2_half_saturation,
        .rubisco_co2_half_saturation_with_o2_umol_per_l = co2_half_saturation * (1.0 + source_gases.dissolved_o2_umol_per_l / o2_half_saturation),
        .rubisco_o2_half_saturation_umol_per_l = o2_half_saturation,
    };
    inline for (@typeInfo(GasEnvironment).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteCanopyGasResult;
    return result;
}

/// Non-rectangular-hyperbola light limitation, evaluated in its algebraically
/// equivalent cancellation-resistant form.
pub fn lightLimitedElectronTransport(par_umol_per_m2_s: f64, light_saturated_transport_umol_per_m2_s: f64) !f64 {
    if (!std.math.isFinite(par_umol_per_m2_s) or !std.math.isFinite(light_saturated_transport_umol_per_m2_s) or par_umol_per_m2_s < 0 or light_saturated_transport_umol_per_m2_s < 0) return error.InvalidElectronTransportInput;
    const absorbed_electrons = 0.45 * par_umol_per_m2_s;
    const sum = absorbed_electrons + light_saturated_transport_umol_per_m2_s;
    const discriminant = @max(0.0, sum * sum - 4.0 * 0.70 * absorbed_electrons * light_saturated_transport_umol_per_m2_s);
    const denominator = sum + @sqrt(discriminant);
    return if (denominator > 0) 2.0 * absorbed_electrons * light_saturated_transport_umol_per_m2_s / denominator else 0;
}

pub fn minimumWaterVaporResistanceHPerM(
    canopy_co2_fixation_umol_per_s: f64,
    canopy_radiation_fraction: f64,
    co2_concentration_difference_umol_per_m3: f64,
    horizontal_cell_area_m2: f64,
    cuticular_water_vapor_resistance_h_per_m: f64,
    active_canopy: bool,
) !f64 {
    inline for (.{ canopy_co2_fixation_umol_per_s, canopy_radiation_fraction, co2_concentration_difference_umol_per_m3, horizontal_cell_area_m2, cuticular_water_vapor_resistance_h_per_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteStomatalResistanceInput;
    if (canopy_co2_fixation_umol_per_s < 0 or canopy_radiation_fraction < 0 or horizontal_cell_area_m2 <= 0 or cuticular_water_vapor_resistance_h_per_m < 0) return error.InvalidStomatalResistanceInput;
    if (!active_canopy) return cuticular_water_vapor_resistance_h_per_m;
    const co2_resistance_h_per_m = if (canopy_co2_fixation_umol_per_s > 0)
        canopy_radiation_fraction * co2_concentration_difference_umol_per_m3 * horizontal_cell_area_m2 / (canopy_co2_fixation_umol_per_s * 3600.0)
    else
        cuticular_water_vapor_resistance_h_per_m * 1.56;
    return @min(cuticular_water_vapor_resistance_h_per_m, @max(2.78e-3, co2_resistance_h_per_m * 0.641));
}

pub const BranchFeedback = struct {
    c3_fraction: f64,
    c4_fraction: f64,
    annual_termination_fraction: f64,
    photosynthetically_active: bool,
};

/// Branch-scale nutrient, heat, hardening, phenology, and annual-termination
/// feedback. The integer codes are parsed runtime PFT values, not dimensions.
pub fn branchFeedback(
    phenology_type: u8,
    growth_habit: u8,
    aboveground_turnover_type: u8,
    leafout_accumulated_h: f64,
    leafout_required_h: f64,
    leafoff_accumulated_h: f64,
    leafoff_required_h: f64,
    nonstructural_c_g: f64,
    nonstructural_n_g: f64,
    nonstructural_p_g: f64,
    heat_stress_h: f64,
    dehardening_h: f64,
    hours_without_grain_fill: f64,
    annual_termination_hours_without_grain_fill: f64,
) !BranchFeedback {
    inline for (.{ leafout_accumulated_h, leafout_required_h, leafoff_accumulated_h, leafoff_required_h, nonstructural_c_g, nonstructural_n_g, nonstructural_p_g, heat_stress_h, dehardening_h, hours_without_grain_fill, annual_termination_hours_without_grain_fill }) |value| if (!std.math.isFinite(value)) return error.NonFiniteBranchFeedbackInput;
    if (phenology_type > 5 or nonstructural_c_g < 0 or nonstructural_n_g < 0 or nonstructural_p_g < 0 or heat_stress_h < 0 or dehardening_h < 0 or hours_without_grain_fill < 0 or annual_termination_hours_without_grain_fill <= 0) return error.InvalidBranchFeedbackInput;
    const active = phenology_type == 0 or growth_habit == 0 or leafout_accumulated_h >= leafout_required_h or leafoff_accumulated_h < leafoff_required_h;
    if (!active) return .{ .c3_fraction = 0, .c4_fraction = 0, .annual_termination_fraction = 1, .photosynthetically_active = false };

    var c3_fraction: f64 = if (nonstructural_c_g > 0)
        @min(
            nonstructural_n_g / (nonstructural_n_g + nonstructural_c_g * 2.5e-2),
            nonstructural_p_g / (nonstructural_p_g + nonstructural_c_g * 2.5e-3),
        )
    else
        1.0;
    c3_fraction /= 1.0 + heat_stress_h;
    if (phenology_type != 0 and aboveground_turnover_type == 2) c3_fraction *= std.math.clamp(dehardening_h / 250.0, 0.0, 1.0);
    const termination = if (growth_habit == 0 and hours_without_grain_fill > 0) @max(0.0, 1.0 - hours_without_grain_fill / annual_termination_hours_without_grain_fill) else 1.0;
    c3_fraction *= termination;
    return .{ .c3_fraction = c3_fraction, .c4_fraction = termination, .annual_termination_fraction = termination, .photosynthetically_active = true };
}

pub const C3Capacity = struct {
    co2_unlimited_carboxylation_umol_per_m2_s: f64,
    oxygenation_umol_per_m2_s: f64,
    co2_compensation_umol_per_l: f64,
    co2_limited_carboxylation_umol_per_m2_s: f64,
    light_saturated_electron_transport_umol_per_m2_s: f64,
    carboxylation_umol_co2_per_umol_electron: f64,
};

pub fn c3Capacity(
    leaf_protein_g_per_m2: f64,
    rubisco_protein_fraction: f64,
    chlorophyll_protein_fraction: f64,
    rubisco_carboxylation_umol_per_g_s_25c: f64,
    rubisco_oxygenation_umol_per_g_s_25c: f64,
    chlorophyll_electron_transport_umol_per_g_s_25c: f64,
    gas: GasEnvironment,
    co2_substrate_umol_per_l: f64,
) !C3Capacity {
    inline for (.{ leaf_protein_g_per_m2, rubisco_protein_fraction, chlorophyll_protein_fraction, rubisco_carboxylation_umol_per_g_s_25c, rubisco_oxygenation_umol_per_g_s_25c, chlorophyll_electron_transport_umol_per_g_s_25c, co2_substrate_umol_per_l }) |value| if (!std.math.isFinite(value)) return error.NonFiniteC3CapacityInput;
    if (leaf_protein_g_per_m2 <= 0 or rubisco_protein_fraction < 0 or chlorophyll_protein_fraction < 0 or rubisco_carboxylation_umol_per_g_s_25c <= 0 or rubisco_oxygenation_umol_per_g_s_25c < 0 or chlorophyll_electron_transport_umol_per_g_s_25c < 0 or co2_substrate_umol_per_l < 0) return error.InvalidC3CapacityInput;
    const rubisco_o2_half_saturation_umol_per_l = gas.rubisco_o2_half_saturation_umol_per_l;
    const rubisco_g_per_m2 = rubisco_protein_fraction * leaf_protein_g_per_m2;
    const chlorophyll_g_per_m2 = chlorophyll_protein_fraction * leaf_protein_g_per_m2;
    const unlimited = rubisco_carboxylation_umol_per_g_s_25c * gas.rubisco_carboxylation_temperature_factor * rubisco_g_per_m2;
    if (unlimited <= 0) return error.ZeroRubiscoCapacity;
    const oxygenation = rubisco_oxygenation_umol_per_g_s_25c * gas.rubisco_oxygenation_temperature_factor * rubisco_g_per_m2;
    const compensation = 0.5 * gas.dissolved_o2_umol_per_l * oxygenation * gas.rubisco_co2_half_saturation_umol_per_l / (unlimited * rubisco_o2_half_saturation_umol_per_l);
    const co2_limited = @max(0.0, unlimited * (co2_substrate_umol_per_l - compensation) / (co2_substrate_umol_per_l + gas.rubisco_co2_half_saturation_with_o2_umol_per_l));
    const denominator = 4.5 * co2_substrate_umol_per_l + 10.5 * compensation;
    return .{
        .co2_unlimited_carboxylation_umol_per_m2_s = unlimited,
        .oxygenation_umol_per_m2_s = oxygenation,
        .co2_compensation_umol_per_l = compensation,
        .co2_limited_carboxylation_umol_per_m2_s = co2_limited,
        .light_saturated_electron_transport_umol_per_m2_s = chlorophyll_electron_transport_umol_per_g_s_25c * gas.electron_transport_temperature_factor * chlorophyll_g_per_m2,
        .carboxylation_umol_co2_per_umol_electron = if (denominator > 0) @max(0.0, (co2_substrate_umol_per_l - compensation) / denominator) else 0,
    };
}

pub const C4Capacity = struct {
    mesophyll_nonstructural_c_umol_per_l: f64,
    bundle_sheath_nonstructural_c_umol_per_l: f64,
    feedback_fraction: f64,
    co2_unlimited_carboxylation_umol_per_m2_s: f64,
    co2_limited_carboxylation_umol_per_m2_s: f64,
    light_saturated_electron_transport_umol_per_m2_s: f64,
    carboxylation_umol_co2_per_umol_electron: f64,
};

pub fn c4Capacity(leaf_c_g: f64, leaf_protein_g_per_m2: f64, mesophyll_nonstructural_c_g: f64, bundle_sheath_nonstructural_c_g: f64, pep_carboxylase_protein_fraction: f64, mesophyll_chlorophyll_protein_fraction: f64, pep_carboxylation_umol_per_g_s_25c: f64, pep_co2_half_saturation_umol_per_l: f64, chlorophyll_electron_transport_umol_per_g_s_25c: f64, gas: GasEnvironment, annual_termination_fraction: f64) !C4Capacity {
    inline for (.{ leaf_c_g, leaf_protein_g_per_m2, mesophyll_nonstructural_c_g, bundle_sheath_nonstructural_c_g, pep_carboxylase_protein_fraction, mesophyll_chlorophyll_protein_fraction, pep_carboxylation_umol_per_g_s_25c, pep_co2_half_saturation_umol_per_l, chlorophyll_electron_transport_umol_per_g_s_25c, annual_termination_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteC4CapacityInput;
    if (leaf_c_g <= 0 or leaf_protein_g_per_m2 <= 0 or mesophyll_nonstructural_c_g < 0 or bundle_sheath_nonstructural_c_g < 0 or pep_carboxylase_protein_fraction < 0 or mesophyll_chlorophyll_protein_fraction < 0 or pep_carboxylation_umol_per_g_s_25c < 0 or pep_co2_half_saturation_umol_per_l <= 0 or chlorophyll_electron_transport_umol_per_g_s_25c < 0 or annual_termination_fraction < 0 or annual_termination_fraction > 1) return error.InvalidC4CapacityInput;
    const mesophyll_c = @max(0.0, 0.021e9 * mesophyll_nonstructural_c_g / (leaf_c_g * 4.8));
    const bundle_sheath_c = @max(0.0, 0.083e9 * bundle_sheath_nonstructural_c_g / (leaf_c_g * 1.2));
    const feedback = annual_termination_fraction / (1.0 + mesophyll_c / 5.0e6);
    const unlimited = pep_carboxylation_umol_per_g_s_25c * gas.rubisco_carboxylation_temperature_factor * pep_carboxylase_protein_fraction * leaf_protein_g_per_m2;
    const co2_limited = @max(0.0, unlimited * (gas.dissolved_co2_umol_per_l - 0.5) / (gas.dissolved_co2_umol_per_l + pep_co2_half_saturation_umol_per_l));
    const efficiency_denominator = 3.0 * gas.dissolved_co2_umol_per_l + 10.5 * 0.5;
    return .{
        .mesophyll_nonstructural_c_umol_per_l = mesophyll_c,
        .bundle_sheath_nonstructural_c_umol_per_l = bundle_sheath_c,
        .feedback_fraction = feedback,
        .co2_unlimited_carboxylation_umol_per_m2_s = unlimited,
        .co2_limited_carboxylation_umol_per_m2_s = co2_limited,
        .light_saturated_electron_transport_umol_per_m2_s = chlorophyll_electron_transport_umol_per_g_s_25c * gas.electron_transport_temperature_factor * mesophyll_chlorophyll_protein_fraction * leaf_protein_g_per_m2,
        .carboxylation_umol_co2_per_umol_electron = if (efficiency_denominator > 0) @max(0.0, (gas.dissolved_co2_umol_per_l - 0.5) / efficiency_denominator) else 0,
    };
}

/// Sums arbitrary runtime canopy samples (layers, inclinations, azimuths, and
/// nodes flattened by the caller), preserving the STOMATE direct+diffuse terms.
pub fn integrateCarboxylationUmolPerS(direct_par_umol_per_m2_s: []const f64, diffuse_par_umol_per_m2_s: []const f64, exposed_leaf_area_m2: []const f64, direct_transmission_fraction: []const f64, diffuse_transmission_fraction: []const f64, co2_limited_umol_per_m2_s: f64, light_saturated_electron_transport_umol_per_m2_s: f64, carboxylation_umol_co2_per_umol_electron: f64, feedback_fraction: f64) !f64 {
    const count = direct_par_umol_per_m2_s.len;
    if (diffuse_par_umol_per_m2_s.len != count or exposed_leaf_area_m2.len != count or direct_transmission_fraction.len != count or diffuse_transmission_fraction.len != count) return error.CanopySampleDimensionMismatch;
    inline for (.{ co2_limited_umol_per_m2_s, light_saturated_electron_transport_umol_per_m2_s, carboxylation_umol_co2_per_umol_electron, feedback_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteCarboxylationInput;
    if (co2_limited_umol_per_m2_s < 0 or light_saturated_electron_transport_umol_per_m2_s < 0 or carboxylation_umol_co2_per_umol_electron < 0 or feedback_fraction < 0) return error.InvalidCarboxylationInput;
    var total: f64 = 0;
    for (0..count) |sample| {
        inline for (.{ direct_par_umol_per_m2_s[sample], diffuse_par_umol_per_m2_s[sample], exposed_leaf_area_m2[sample], direct_transmission_fraction[sample], diffuse_transmission_fraction[sample] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopySample;
        if (direct_par_umol_per_m2_s[sample] < 0 or diffuse_par_umol_per_m2_s[sample] < 0 or exposed_leaf_area_m2[sample] < 0 or direct_transmission_fraction[sample] < 0 or diffuse_transmission_fraction[sample] < 0) return error.InvalidCanopySample;
        if (exposed_leaf_area_m2[sample] == 0) continue;
        if (direct_par_umol_per_m2_s[sample] > 0) {
            const light_limited = try lightLimitedElectronTransport(direct_par_umol_per_m2_s[sample], light_saturated_electron_transport_umol_per_m2_s) * carboxylation_umol_co2_per_umol_electron;
            total += @min(co2_limited_umol_per_m2_s, light_limited) * feedback_fraction * exposed_leaf_area_m2[sample] * direct_transmission_fraction[sample];
        }
        if (diffuse_par_umol_per_m2_s[sample] > 0) {
            const light_limited = try lightLimitedElectronTransport(diffuse_par_umol_per_m2_s[sample], light_saturated_electron_transport_umol_per_m2_s) * carboxylation_umol_co2_per_umol_electron;
            total += @min(co2_limited_umol_per_m2_s, light_limited) * feedback_fraction * exposed_leaf_area_m2[sample] * diffuse_transmission_fraction[sample];
        }
    }
    if (!std.math.isFinite(total)) return error.NonFiniteCarboxylationResult;
    return total;
}

test "gas environment reproduces STOMATE equations at 25 C" {
    const result = try gasEnvironment(298.15, 0, 400, 0.7, 210_000, 30, 300);
    try std.testing.expectApproxEqRel(280.0, result.intercellular_co2_umol_per_mol, 1e-14);
    try std.testing.expectApproxEqRel(@exp(-2.621 - 0.0317 * 25.0) * 280.0, result.dissolved_co2_umol_per_l, 1e-14);
    try std.testing.expect(result.rubisco_co2_half_saturation_with_o2_umol_per_l > result.rubisco_co2_half_saturation_umol_per_l);
    // At exactly 25 C the Arrhenius scaling exp(8.067 - 20000/(8.3143*298.15))
    // is not 1, so the exposed scaled O2 Km must still differ from the raw
    // 25 C input -- this is XKO2L (stomate.f:106), never the bare XKO2.
    try std.testing.expect(result.rubisco_o2_half_saturation_umol_per_l != 300.0);
}

test "rubisco_o2_half_saturation_umol_per_l is Arrhenius-scaled with temperature, matching STOMATE's XKO2L" {
    const at_25c = try gasEnvironment(298.15, 0, 400, 0.7, 210_000, 30, 300);
    const at_35c = try gasEnvironment(308.15, 0, 400, 0.7, 210_000, 30, 300);
    // XKO2L = XKO2 * exp(8.067 - 20000/RTK): strictly increasing in
    // temperature since the exponent's derivative w.r.t. T is positive.
    try std.testing.expect(at_35c.rubisco_o2_half_saturation_umol_per_l > at_25c.rubisco_o2_half_saturation_umol_per_l);
    const expected_25c = 300.0 * @exp(8.067 - 20_000.0 / (8.3143 * 298.15));
    const expected_35c = 300.0 * @exp(8.067 - 20_000.0 / (8.3143 * 308.15));
    try std.testing.expectApproxEqRel(expected_25c, at_25c.rubisco_o2_half_saturation_umol_per_l, 1e-12);
    try std.testing.expectApproxEqRel(expected_35c, at_35c.rubisco_o2_half_saturation_umol_per_l, 1e-12);
}

test "c3Capacity's CO2 compensation point uses the temperature-adjusted O2 Km, not the raw 25 C value" {
    const raw_o2_km: f64 = 300.0;
    const gas_25c = try gasEnvironment(298.15, 0, 400, 0.7, 210_000, 30, raw_o2_km);
    const gas_35c = try gasEnvironment(308.15, 0, 400, 0.7, 210_000, 30, raw_o2_km);
    const capacity_25c = try c3Capacity(3.0, 0.125, 0.0625, 60, 9.5, 300, gas_25c, gas_25c.dissolved_co2_umol_per_l);
    const capacity_35c = try c3Capacity(3.0, 0.125, 0.0625, 60, 9.5, 300, gas_35c, gas_35c.dissolved_co2_umol_per_l);
    // If the bug were still present, compensation would be computed with the
    // same raw_o2_km at both temperatures, scaled only by the (also
    // temperature-dependent) numerator terms; using the scaled O2 Km instead
    // means compensation must differ from what the raw-value formula would
    // give at 35 C.
    const wrong_compensation_35c = 0.5 * gas_35c.dissolved_o2_umol_per_l * capacity_35c.oxygenation_umol_per_m2_s *
        gas_35c.rubisco_co2_half_saturation_umol_per_l / (capacity_35c.co2_unlimited_carboxylation_umol_per_m2_s * raw_o2_km);
    try std.testing.expect(@abs(capacity_35c.co2_compensation_umol_per_l - wrong_compensation_35c) > 1e-9);
    try std.testing.expectApproxEqRel(
        0.5 * gas_35c.dissolved_o2_umol_per_l * capacity_35c.oxygenation_umol_per_m2_s * gas_35c.rubisco_co2_half_saturation_umol_per_l /
            (capacity_35c.co2_unlimited_carboxylation_umol_per_m2_s * gas_35c.rubisco_o2_half_saturation_umol_per_l),
        capacity_35c.co2_compensation_umol_per_l,
        1e-12,
    );
    _ = capacity_25c;
}

test "zero intercellular CO2 retains explicit finite solubility" {
    const result = try gasEnvironment(298.15, 0, 400, 0, 210_000, 30, 300);
    try std.testing.expectEqual(@as(f64, 0), result.dissolved_co2_umol_per_l);
    try std.testing.expectEqual(
        @exp(-2.621 - 0.0317 * 25.0),
        result.co2_solubility_umol_per_l_per_umol_per_mol,
    );
}

test "light response and resistance retain exact limiting behavior" {
    try std.testing.expectEqual(0.0, try lightLimitedElectronTransport(0, 100));
    const transport = try lightLimitedElectronTransport(1000, 150);
    try std.testing.expect(transport > 0 and transport < 150);
    try std.testing.expectApproxEqAbs(2.78e-3, try minimumWaterVaporResistanceHPerM(100, 1, 100, 1, 0.01, true), 1e-15);
    try std.testing.expectEqual(0.01, try minimumWaterVaporResistanceHPerM(100, 1, 100, 1, 0.01, false));
}

test "branch feedback reproduces nutrient heat hardening and annual termination" {
    const result = try branchFeedback(1, 0, 2, 300, 200, 0, 100, 10, 0.5, 0.05, 1, 125, 168, 336);
    try std.testing.expect(result.photosynthetically_active);
    try std.testing.expectApproxEqAbs(1.0 / 12.0, result.c3_fraction, 1e-15);
    try std.testing.expectApproxEqAbs(0.5, result.c4_fraction, 1e-15);
}

test "runtime canopy sample integration includes direct and diffuse fixation" {
    const direct = [_]f64{ 1000, 0 };
    const diffuse = [_]f64{ 100, 200 };
    const area = [_]f64{ 2, 1 };
    const direct_tau = [_]f64{ 0.8, 0.7 };
    const diffuse_tau = [_]f64{ 0.6, 0.5 };
    const total = try integrateCarboxylationUmolPerS(&direct, &diffuse, &area, &direct_tau, &diffuse_tau, 30, 150, 0.2, 0.5);
    const expected = @min(30.0, (try lightLimitedElectronTransport(1000, 150)) * 0.2) * 0.5 * 2 * 0.8 + @min(30.0, (try lightLimitedElectronTransport(100, 150)) * 0.2) * 0.5 * 2 * 0.6 + @min(30.0, (try lightLimitedElectronTransport(200, 150)) * 0.2) * 0.5 * 1 * 0.5;
    try std.testing.expectApproxEqAbs(expected, total, 1e-14);
}
