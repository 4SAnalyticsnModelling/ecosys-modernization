// **A8a DISPOSITION: BOUND; CANOPY-TKC-001 closed for this component.**
// `stages/hourly_snow_energy.zig` calls this UPTAKE.F 572--615 tuple builder
// before the production `canopy_coupled_convergence.solveOuterCoupled` solve.
// The complete result stays local until the coupled canopy/root transaction
// validates, preserving the module's atomic initialization contract.
const std = @import("std");

pub const Inputs = struct {
    foliar_water_retention_m3_per_h: f64,
    water_flux_timestep_h: f64,
    current_canopy_water_m3: f64,
    previous_hydrologically_active_carbon_g_c: f64,
    leaf_and_petiole_carbon_g_c: f64,
    stalk_carbon_g_c: f64,
    sapwood_thickness_m: f64,
    stalk_surface_area_m2: f64,
    stalk_volume_per_carbon_m3_per_g_c: f64,
    canopy_total_water_potential_megapascal: f64,
    minimum_dry_matter_fraction: f64,
    canopy_surface_water_m3: f64,
    dry_carbon_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    high_heat_capacity_threshold_megajoules_per_m2_k: f64,
    low_heat_capacity_threshold_megajoules_per_m2_k: f64,
    cell_area_m2: f64,
    current_canopy_temperature_k: f64,
    high_capacity_temperature_step_k: f64,
    low_capacity_temperature_step_k: f64,
    water_volume_per_carbon_scale_m3_per_g_c: f64,
    dry_matter_potential_numerator: f64,
    dry_matter_potential_denominator_coefficient: f64,
    dry_matter_potential_denominator_intercept: f64,
};

pub const Result = struct {
    retained_foliar_water_m3_per_step: f64,
    previous_canopy_water_m3: f64,
    previous_hydrologically_active_carbon_g_c: f64,
    hydrologically_active_carbon_g_c: f64,
    absolute_canopy_water_potential_megapascal: f64,
    dry_matter_fraction: f64,
    canopy_water_capacity_m3: f64,
    trial_canopy_water_capacity_m3: f64,
    dry_canopy_heat_capacity_megajoules_per_k: f64,
    wet_canopy_heat_capacity_megajoules_per_k: f64,
    high_heat_capacity_threshold_megajoules_per_k: f64,
    low_heat_capacity_threshold_megajoules_per_k: f64,
    previous_canopy_temperature_k: f64,
    trial_canopy_temperature_k: f64,
    canopy_temperature_step_k: f64,
};

/// UPTAKE.F 572--615. Returns one complete per-species initialization tuple,
/// avoiding partial state state_update when a derived value is invalid.
pub fn calculate(inputs: Inputs) !Result {
    try validateInputs(inputs);
    const retained_foliar_water =
        inputs.foliar_water_retention_m3_per_h * inputs.water_flux_timestep_h;
    const previous_canopy_water = inputs.current_canopy_water_m3;
    const previous_active_carbon =
        inputs.previous_hydrologically_active_carbon_g_c;
    const active_carbon = @max(
        0,
        inputs.leaf_and_petiole_carbon_g_c +
            @min(
                inputs.stalk_carbon_g_c,
                inputs.sapwood_thickness_m *
                    inputs.stalk_surface_area_m2 /
                    inputs.stalk_volume_per_carbon_m3_per_g_c,
            ),
    );
    const absolute_potential = @abs(inputs.canopy_total_water_potential_megapascal);
    const dry_matter_fraction = inputs.minimum_dry_matter_fraction +
        inputs.dry_matter_potential_numerator * absolute_potential /
            (inputs.dry_matter_potential_denominator_coefficient *
                absolute_potential +
                inputs.dry_matter_potential_denominator_intercept);
    const water_capacity =
        inputs.water_volume_per_carbon_scale_m3_per_g_c *
        active_carbon /
        dry_matter_fraction;
    const trial_water_capacity = water_capacity;
    const dry_heat_capacity =
        inputs.dry_carbon_heat_capacity_megajoules_per_m3_k *
        active_carbon *
        inputs.stalk_volume_per_carbon_m3_per_g_c;
    const wet_heat_capacity = dry_heat_capacity +
        inputs.liquid_water_heat_capacity_megajoules_per_m3_k *
            (@max(0, inputs.canopy_surface_water_m3) +
                @max(0, inputs.current_canopy_water_m3));
    const high_threshold =
        inputs.high_heat_capacity_threshold_megajoules_per_m2_k * inputs.cell_area_m2;
    const low_threshold =
        inputs.low_heat_capacity_threshold_megajoules_per_m2_k * inputs.cell_area_m2;
    const previous_temperature = inputs.current_canopy_temperature_k;
    const trial_temperature = previous_temperature;
    const temperature_step = if (dry_heat_capacity > high_threshold)
        inputs.high_capacity_temperature_step_k
    else
        inputs.low_capacity_temperature_step_k;
    const result = Result{
        .retained_foliar_water_m3_per_step = retained_foliar_water,
        .previous_canopy_water_m3 = previous_canopy_water,
        .previous_hydrologically_active_carbon_g_c = previous_active_carbon,
        .hydrologically_active_carbon_g_c = active_carbon,
        .absolute_canopy_water_potential_megapascal = absolute_potential,
        .dry_matter_fraction = dry_matter_fraction,
        .canopy_water_capacity_m3 = water_capacity,
        .trial_canopy_water_capacity_m3 = trial_water_capacity,
        .dry_canopy_heat_capacity_megajoules_per_k = dry_heat_capacity,
        .wet_canopy_heat_capacity_megajoules_per_k = wet_heat_capacity,
        .high_heat_capacity_threshold_megajoules_per_k = high_threshold,
        .low_heat_capacity_threshold_megajoules_per_k = low_threshold,
        .previous_canopy_temperature_k = previous_temperature,
        .trial_canopy_temperature_k = trial_temperature,
        .canopy_temperature_step_k = temperature_step,
    };
    inline for (@typeInfo(Result).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteCanopyWaterHeatInitialization;
    if (result.dry_matter_fraction <= 0)
        return error.InvalidCanopyWaterHeatInitialization;
    return result;
}

fn validateInputs(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.InvalidCanopyWaterHeatInitializationInput;
    if (inputs.water_flux_timestep_h < 0 or
        inputs.stalk_volume_per_carbon_m3_per_g_c <= 0 or
        inputs.minimum_dry_matter_fraction <= 0 or
        inputs.dry_carbon_heat_capacity_megajoules_per_m3_k < 0 or
        inputs.liquid_water_heat_capacity_megajoules_per_m3_k < 0 or
        inputs.high_heat_capacity_threshold_megajoules_per_m2_k < 0 or
        inputs.low_heat_capacity_threshold_megajoules_per_m2_k < 0 or
        inputs.cell_area_m2 <= 0 or
        inputs.current_canopy_temperature_k <= 0 or
        inputs.high_capacity_temperature_step_k <= 0 or
        inputs.low_capacity_temperature_step_k <= 0 or
        inputs.water_volume_per_carbon_scale_m3_per_g_c <= 0 or
        inputs.dry_matter_potential_denominator_intercept <= 0)
        return error.InvalidCanopyWaterHeatInitializationInput;
}

fn sourceInputs() Inputs {
    return .{
        .foliar_water_retention_m3_per_h = 0.2,
        .water_flux_timestep_h = 0.5,
        .current_canopy_water_m3 = 0.3,
        .previous_hydrologically_active_carbon_g_c = 7,
        .leaf_and_petiole_carbon_g_c = 10,
        .stalk_carbon_g_c = 8,
        .sapwood_thickness_m = 0.02,
        .stalk_surface_area_m2 = 20,
        .stalk_volume_per_carbon_m3_per_g_c = 0.1,
        .canopy_total_water_potential_megapascal = -2,
        .minimum_dry_matter_fraction = 0.2,
        .canopy_surface_water_m3 = 0.1,
        .dry_carbon_heat_capacity_megajoules_per_m3_k = 2.496,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .high_heat_capacity_threshold_megajoules_per_m2_k = 0.838e-3,
        .low_heat_capacity_threshold_megajoules_per_m2_k = 0.838e-4,
        .cell_area_m2 = 100,
        .current_canopy_temperature_k = 295,
        .high_capacity_temperature_step_k = 0.125,
        .low_capacity_temperature_step_k = 0.025,
        .water_volume_per_carbon_scale_m3_per_g_c = 1e-6,
        .dry_matter_potential_numerator = 0.10,
        .dry_matter_potential_denominator_coefficient = 0.05,
        .dry_matter_potential_denominator_intercept = 2,
    };
}

test "UPTAKE canopy water and heat initialization preserves source equations" {
    const result = try calculate(sourceInputs());
    try std.testing.expectEqual(@as(f64, 0.1), result.retained_foliar_water_m3_per_step);
    try std.testing.expectEqual(@as(f64, 0.3), result.previous_canopy_water_m3);
    try std.testing.expectEqual(@as(f64, 7), result.previous_hydrologically_active_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 14), result.hydrologically_active_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 2), result.absolute_canopy_water_potential_megapascal);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2 + 0.2 / 2.1), result.dry_matter_fraction, 1e-15);
    try std.testing.expectEqual(result.canopy_water_capacity_m3, result.trial_canopy_water_capacity_m3);
    try std.testing.expectEqual(@as(f64, 295), result.previous_canopy_temperature_k);
    try std.testing.expectEqual(@as(f64, 295), result.trial_canopy_temperature_k);
    try std.testing.expectEqual(@as(f64, 0.125), result.canopy_temperature_step_k);
}

test "low dry heat capacity selects source low-capacity temperature step" {
    var inputs = sourceInputs();
    inputs.leaf_and_petiole_carbon_g_c = -20;
    inputs.stalk_carbon_g_c = 0;
    const result = try calculate(inputs);
    try std.testing.expectEqual(@as(f64, 0), result.hydrologically_active_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), result.dry_canopy_heat_capacity_megajoules_per_k);
    try std.testing.expectEqual(@as(f64, 0.025), result.canopy_temperature_step_k);
}

test "invalid stalk conversion fails before canopy initialization" {
    var inputs = sourceInputs();
    inputs.stalk_volume_per_carbon_m3_per_g_c = 0;
    try std.testing.expectError(
        error.InvalidCanopyWaterHeatInitializationInput,
        calculate(inputs),
    );
}
