// **A8a DISPOSITION: RECONCILED; RETAINED ORACLE, PRODUCTION SUPERSEDED.**
// This transcribes UPTAKE.F 1305--1316's historical M-substep accumulator for
// source-equation tests. It deliberately has no production caller. MIGRATION.md
// defines NPH as a nonlinear hard ceiling in ecosys-ng, not a time-splitting
// count: `canopy_coupled_convergence.solveOuterCoupled` solves the one-hour
// extensive TKCY/root-water residual and `stages/hourly_snow_energy.zig`
// publishes its accepted flux tuple exactly once with
// `heat_flux_timestep_h = 1`. Trial Newton/Anderson evaluations are pure and
// therefore must never be accumulated as if they were elapsed time.
//
// The whole-hour water identity is the signed source equation at
// uptake.f:1190--1192, expressed in Zig signs:
//   delta_storage = root_uptake - net_canopy_boundary_outflow.
// The heat identity is uptake.f:1026:
//   storage_heat = net_radiation + latent + sensible + vapor_sensible
//                  + retained_water_heat.
// Focused tests in `coupled_convergence.zig` independently reconstruct both
// identities from the accepted result and prove that enlarging max_iterations
// does not multiply flux or change a converged answer. This module remains only
// to guard the reference ordering; binding it would double-count the hour.
const std = @import("std");

pub const Aggregates = struct {
    net_radiation_flux_megajoules_per_step: f64,
    latent_heat_flux_megajoules_per_step: f64,
    sensible_heat_flux_megajoules_per_step: f64,
    storage_heat_flux_megajoules_per_step: f64,
    convective_water_heat_flux_megajoules_per_step: f64,
    longwave_emission_megajoules_per_step: f64,
    intercepted_evaporation_m3_per_step: f64,
    transpiration_m3_per_step: f64,
    ground_vapor_flux_m3_per_step: f64,
    ground_sensible_heat_flux_megajoules_per_step: f64,
};

pub const Inputs = struct {
    aggregates: Aggregates,
    substep_net_radiation_flux_megajoules_per_step: f64,
    substep_latent_heat_flux_megajoules_per_step: f64,
    substep_sensible_heat_flux_megajoules_per_step: f64,
    substep_storage_heat_flux_megajoules_per_step: f64,
    substep_convective_water_heat_flux_megajoules_per_step: f64,
    substep_longwave_emission_megajoules_per_step: f64,
    substep_intercepted_evaporation_m3_per_step: f64,
    substep_transpiration_m3_per_step: f64,
    substep_ground_vapor_flux_m3_per_step: f64,
    substep_ground_sensible_heat_flux_megajoules_per_step: f64,
    dry_canopy_heat_capacity_megajoules_per_k: f64,
    intercepted_water_volume_m3: f64,
    canopy_water_volume_m3: f64,
};

pub const Result = struct {
    aggregates: Aggregates,
    wet_canopy_heat_capacity_megajoules_per_k: f64,
};

/// UPTAKE.F 1305--1316. Adds one M-substep to canopy energy/water totals in
/// exact source order, then refreshes wet heat capacity from current stores.
pub fn calculate(inputs: Inputs) !Result {
    try validate(inputs);
    var aggregates = inputs.aggregates;
    aggregates.net_radiation_flux_megajoules_per_step +=
        inputs.substep_net_radiation_flux_megajoules_per_step;
    aggregates.latent_heat_flux_megajoules_per_step +=
        inputs.substep_latent_heat_flux_megajoules_per_step;
    aggregates.sensible_heat_flux_megajoules_per_step +=
        inputs.substep_sensible_heat_flux_megajoules_per_step;
    aggregates.storage_heat_flux_megajoules_per_step +=
        inputs.substep_storage_heat_flux_megajoules_per_step;
    aggregates.convective_water_heat_flux_megajoules_per_step +=
        inputs.substep_convective_water_heat_flux_megajoules_per_step;
    aggregates.longwave_emission_megajoules_per_step +=
        inputs.substep_longwave_emission_megajoules_per_step;
    aggregates.intercepted_evaporation_m3_per_step +=
        inputs.substep_intercepted_evaporation_m3_per_step;
    aggregates.transpiration_m3_per_step +=
        inputs.substep_transpiration_m3_per_step;
    aggregates.ground_vapor_flux_m3_per_step +=
        inputs.substep_ground_vapor_flux_m3_per_step;
    aggregates.ground_sensible_heat_flux_megajoules_per_step +=
        inputs.substep_ground_sensible_heat_flux_megajoules_per_step;
    const wet_heat_capacity =
        inputs.dry_canopy_heat_capacity_megajoules_per_k +
        4.19 * (@max(0, inputs.intercepted_water_volume_m3) +
            @max(0, inputs.canopy_water_volume_m3));
    const result = Result{
        .aggregates = aggregates,
        .wet_canopy_heat_capacity_megajoules_per_k = wet_heat_capacity,
    };
    inline for (@typeInfo(Aggregates).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result.aggregates, field.name)))
            return error.NonFiniteCanopyEnergyWaterAggregationResult;
    if (!std.math.isFinite(result.wet_canopy_heat_capacity_megajoules_per_k))
        return error.NonFiniteCanopyEnergyWaterAggregationResult;
    return result;
}

fn validate(inputs: Inputs) !void {
    inline for (@typeInfo(Aggregates).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs.aggregates, field.name)))
            return error.InvalidCanopyEnergyWaterAggregationInput;
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (field.type == Aggregates) continue;
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.InvalidCanopyEnergyWaterAggregationInput;
    }
    if (inputs.dry_canopy_heat_capacity_megajoules_per_k < 0)
        return error.InvalidCanopyEnergyWaterAggregationInput;
}

fn sourceInputs() Inputs {
    return .{
        .aggregates = .{
            .net_radiation_flux_megajoules_per_step = 1,
            .latent_heat_flux_megajoules_per_step = 2,
            .sensible_heat_flux_megajoules_per_step = 3,
            .storage_heat_flux_megajoules_per_step = 4,
            .convective_water_heat_flux_megajoules_per_step = 5,
            .longwave_emission_megajoules_per_step = 6,
            .intercepted_evaporation_m3_per_step = 7,
            .transpiration_m3_per_step = 8,
            .ground_vapor_flux_m3_per_step = 9,
            .ground_sensible_heat_flux_megajoules_per_step = 10,
        },
        .substep_net_radiation_flux_megajoules_per_step = -0.1,
        .substep_latent_heat_flux_megajoules_per_step = -0.2,
        .substep_sensible_heat_flux_megajoules_per_step = -0.3,
        .substep_storage_heat_flux_megajoules_per_step = -0.4,
        .substep_convective_water_heat_flux_megajoules_per_step = -0.5,
        .substep_longwave_emission_megajoules_per_step = 0.6,
        .substep_intercepted_evaporation_m3_per_step = -0.7,
        .substep_transpiration_m3_per_step = -0.8,
        .substep_ground_vapor_flux_m3_per_step = 0.9,
        .substep_ground_sensible_heat_flux_megajoules_per_step = 1,
        .dry_canopy_heat_capacity_megajoules_per_k = 2,
        .intercepted_water_volume_m3 = 0.1,
        .canopy_water_volume_m3 = 0.2,
    };
}

test "UPTAKE canopy aggregation preserves signed source additions" {
    const result = try calculate(sourceInputs());
    try std.testing.expectEqual(@as(f64, 0.9), result.aggregates.net_radiation_flux_megajoules_per_step);
    try std.testing.expectEqual(@as(f64, 1.8), result.aggregates.latent_heat_flux_megajoules_per_step);
    try std.testing.expectEqual(@as(f64, 2.7), result.aggregates.sensible_heat_flux_megajoules_per_step);
    try std.testing.expectEqual(@as(f64, 3.6), result.aggregates.storage_heat_flux_megajoules_per_step);
    try std.testing.expectEqual(@as(f64, 4.5), result.aggregates.convective_water_heat_flux_megajoules_per_step);
    try std.testing.expectEqual(@as(f64, 6.6), result.aggregates.longwave_emission_megajoules_per_step);
    try std.testing.expectEqual(@as(f64, 6.3), result.aggregates.intercepted_evaporation_m3_per_step);
    try std.testing.expectEqual(@as(f64, 7.2), result.aggregates.transpiration_m3_per_step);
    try std.testing.expectEqual(@as(f64, 9.9), result.aggregates.ground_vapor_flux_m3_per_step);
    try std.testing.expectEqual(@as(f64, 11), result.aggregates.ground_sensible_heat_flux_megajoules_per_step);
}

test "wet heat capacity excludes negative water stores" {
    var inputs = sourceInputs();
    inputs.intercepted_water_volume_m3 = -0.1;
    inputs.canopy_water_volume_m3 = 0.2;
    const result = try calculate(inputs);
    try std.testing.expectApproxEqAbs(
        2.0 + 4.19 * 0.2,
        result.wet_canopy_heat_capacity_megajoules_per_k,
        1e-15,
    );
}

test "non-finite substep fails explicitly" {
    var inputs = sourceInputs();
    inputs.substep_storage_heat_flux_megajoules_per_step = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidCanopyEnergyWaterAggregationInput,
        calculate(inputs),
    );
}
