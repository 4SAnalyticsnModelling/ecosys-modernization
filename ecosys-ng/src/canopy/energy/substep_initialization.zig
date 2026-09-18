// **A8a DISPOSITION: BOUND; CANOPY-TKC-001 closed for this component.**
// `stages/hourly_snow_energy.zig` calls this UPTAKE.F 849--858 setup before
// the coupled solve. The runtime's hard canopy iteration ceiling replaces the
// legacy `MXN=200`; `compatibilityIterationPolicy` remains a reference helper.
// Delayed combustion heat stays with the separately bound canopy-air solve, so
// the production call passes zero here and avoids booking the same heat twice.
const std = @import("std");

pub const IterationPolicy = struct {
    maximum_iterations: usize,
};

/// Runtime compatibility policy transcribed from UPTAKE `MXN=200`.
pub fn compatibilityIterationPolicy() IterationPolicy {
    return .{ .maximum_iterations = 200 };
}

pub const Inputs = struct {
    canopy_air_temperature_k: f64,
    canopy_air_heat_capacity_megajoules_per_k: f64,
    negligible_canopy_air_heat_capacity_megajoules_per_k: f64,
    canopy_radiation_share: f64,
    negligible_canopy_radiation_share: f64,
    previous_combustion_heat_megajoules_per_step: f64,
    legacy_substep_multiplier: f64,
    canopy_surface_water_m3: f64,
    retained_foliar_water_m3_per_step: f64,
    canopy_surface_temperature_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
};

pub const Result = struct {
    convergence_check: usize,
    temperature_direction: f64,
    canopy_air_temperature_k: f64,
    canopy_surface_water_m3: f64,
    retained_foliar_water_heat_megajoules_per_step: f64,
};

/// UPTAKE.F 849--858. Initializes one local canopy energy/root-water
/// subproblem before the legacy 200-cycle convergence loop.
pub fn calculate(inputs: Inputs) !Result {
    try validate(inputs);
    var canopy_air_temperature_k = inputs.canopy_air_temperature_k;
    if (inputs.canopy_air_heat_capacity_megajoules_per_k >
        inputs.negligible_canopy_air_heat_capacity_megajoules_per_k and
        inputs.canopy_radiation_share >
            inputs.negligible_canopy_radiation_share)
    {
        canopy_air_temperature_k =
            canopy_air_temperature_k +
            inputs.previous_combustion_heat_megajoules_per_step /
                (inputs.canopy_air_heat_capacity_megajoules_per_k *
                    inputs.canopy_radiation_share) *
                inputs.legacy_substep_multiplier;
    }
    const canopy_surface_water_m3 =
        inputs.canopy_surface_water_m3 +
        inputs.retained_foliar_water_m3_per_step;
    const retained_heat =
        inputs.retained_foliar_water_m3_per_step *
        inputs.liquid_water_heat_capacity_megajoules_per_m3_k *
        inputs.canopy_surface_temperature_k;
    const result = Result{
        .convergence_check = 0,
        .temperature_direction = 1,
        .canopy_air_temperature_k = canopy_air_temperature_k,
        .canopy_surface_water_m3 = canopy_surface_water_m3,
        .retained_foliar_water_heat_megajoules_per_step = retained_heat,
    };
    inline for (@typeInfo(Result).@"struct".fields) |field|
        if (field.type == f64 and !std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteCanopyEnergySubstepInitialization;
    return result;
}

fn validate(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.InvalidCanopyEnergySubstepInput;
    if (inputs.canopy_air_temperature_k <= 0 or
        inputs.canopy_air_heat_capacity_megajoules_per_k < 0 or
        inputs.negligible_canopy_air_heat_capacity_megajoules_per_k < 0 or
        inputs.canopy_radiation_share < 0 or
        inputs.negligible_canopy_radiation_share < 0 or
        inputs.legacy_substep_multiplier < 0 or
        inputs.canopy_surface_water_m3 < 0 or
        inputs.retained_foliar_water_m3_per_step < 0 or
        inputs.canopy_surface_temperature_k <= 0 or
        inputs.liquid_water_heat_capacity_megajoules_per_m3_k < 0)
        return error.InvalidCanopyEnergySubstepInput;
}

test "UPTAKE substep initializes combustion precipitation and retained heat" {
    const result = try calculate(.{
        .canopy_air_temperature_k = 290,
        .canopy_air_heat_capacity_megajoules_per_k = 2,
        .negligible_canopy_air_heat_capacity_megajoules_per_k = 1e-12,
        .canopy_radiation_share = 0.5,
        .negligible_canopy_radiation_share = 1e-12,
        .previous_combustion_heat_megajoules_per_step = 4,
        .legacy_substep_multiplier = 0.25,
        .canopy_surface_water_m3 = 0.1,
        .retained_foliar_water_m3_per_step = 0.02,
        .canopy_surface_temperature_k = 300,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    });
    try std.testing.expectEqual(@as(usize, 0), result.convergence_check);
    try std.testing.expectEqual(@as(f64, 1), result.temperature_direction);
    try std.testing.expectEqual(@as(f64, 291), result.canopy_air_temperature_k);
    try std.testing.expectApproxEqAbs(@as(f64, 0.12), result.canopy_surface_water_m3, 1e-15);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.02 * 4.19 * 300),
        result.retained_foliar_water_heat_megajoules_per_step,
        1e-14,
    );
}

test "strict heat and radiation gates skip combustion adjustment" {
    const result = try calculate(.{
        .canopy_air_temperature_k = 290,
        .canopy_air_heat_capacity_megajoules_per_k = 1,
        .negligible_canopy_air_heat_capacity_megajoules_per_k = 1,
        .canopy_radiation_share = 0.5,
        .negligible_canopy_radiation_share = 0.5,
        .previous_combustion_heat_megajoules_per_step = 100,
        .legacy_substep_multiplier = 1,
        .canopy_surface_water_m3 = 0,
        .retained_foliar_water_m3_per_step = 0,
        .canopy_surface_temperature_k = 300,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    });
    try std.testing.expectEqual(@as(f64, 290), result.canopy_air_temperature_k);
}

test "canopy energy legacy inner ceiling is 200 iterations" {
    try std.testing.expectEqual(
        @as(usize, 200),
        compatibilityIterationPolicy().maximum_iterations,
    );
}
