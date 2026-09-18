// **A8a DISPOSITION: BOUND; CANOPY-TKC-001 closed for this component.**
// `canopy_coupled_convergence` calls this UPTAKE.F 880--885 evaluation on every
// TKCY residual. Its accepted emitted, canopy-ground, and net longwave values
// are published by `stages/hourly_snow_energy.zig`; the former independent
// living-canopy `canopy/energy/energy.zig` writer is no longer dispatched.
const std = @import("std");

pub const IterationPolicy = struct {
    maximum_iterations: usize,
};

pub fn compatibilityIterationPolicy() IterationPolicy {
    return .{ .maximum_iterations = 200 };
}

pub const Inputs = struct {
    canopy_water_capacity_m3: f64,
    current_canopy_water_m3: f64,
    legacy_substep_multiplier: f64,
    emitted_longwave_coefficient_megajoules_per_step_k4: f64,
    canopy_surface_temperature_k: f64,
    ground_surface_temperature_k: f64,
    absorbed_radiation_fraction: f64,
    absorbed_sky_longwave_megajoules_per_step: f64,
    absorbed_lateral_longwave_megajoules_per_step: f64,
    absorbed_shortwave_radiation_megajoules_per_step: f64,
};

pub const Result = struct {
    canopy_water_capacity_difference_change_m3_per_step: f64,
    emitted_canopy_longwave_megajoules_per_step: f64,
    canopy_to_ground_longwave_megajoules_per_step: f64,
    net_canopy_longwave_megajoules_per_step: f64,
    net_canopy_radiation_megajoules_per_step: f64,
};

/// UPTAKE.F 880--885. One evaluation of the water-capacity and radiation
/// component inside the runtime-bounded canopy Newton/Picard residual.
pub fn calculate(inputs: Inputs) !Result {
    try validate(inputs);
    const water_capacity_change =
        (inputs.canopy_water_capacity_m3 -
            inputs.current_canopy_water_m3) *
        inputs.legacy_substep_multiplier;
    const canopy_temperature_fourth =
        std.math.pow(f64, inputs.canopy_surface_temperature_k, 4);
    const emitted_longwave =
        inputs.emitted_longwave_coefficient_megajoules_per_step_k4 *
        canopy_temperature_fourth;
    const canopy_to_ground =
        inputs.emitted_longwave_coefficient_megajoules_per_step_k4 *
        (canopy_temperature_fourth -
            std.math.pow(f64, inputs.ground_surface_temperature_k, 4)) *
        inputs.absorbed_radiation_fraction;
    const net_longwave =
        inputs.absorbed_sky_longwave_megajoules_per_step +
        inputs.absorbed_lateral_longwave_megajoules_per_step -
        emitted_longwave -
        canopy_to_ground;
    const net_radiation =
        inputs.absorbed_shortwave_radiation_megajoules_per_step +
        net_longwave;
    const result = Result{
        .canopy_water_capacity_difference_change_m3_per_step = water_capacity_change,
        .emitted_canopy_longwave_megajoules_per_step = emitted_longwave,
        .canopy_to_ground_longwave_megajoules_per_step = canopy_to_ground,
        .net_canopy_longwave_megajoules_per_step = net_longwave,
        .net_canopy_radiation_megajoules_per_step = net_radiation,
    };
    inline for (@typeInfo(Result).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteCanopyEnergyRadiationIteration;
    return result;
}

fn validate(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.InvalidCanopyEnergyRadiationIterationInput;
    if (inputs.legacy_substep_multiplier < 0 or
        inputs.emitted_longwave_coefficient_megajoules_per_step_k4 < 0 or
        inputs.canopy_surface_temperature_k <= 0 or
        inputs.ground_surface_temperature_k <= 0 or
        inputs.absorbed_radiation_fraction < 0)
        return error.InvalidCanopyEnergyRadiationIterationInput;
}

test "UPTAKE iterative radiation component preserves source operation order" {
    const inputs = Inputs{
        .canopy_water_capacity_m3 = 0.4,
        .current_canopy_water_m3 = 0.1,
        .legacy_substep_multiplier = 0.25,
        .emitted_longwave_coefficient_megajoules_per_step_k4 = 1e-10,
        .canopy_surface_temperature_k = 300,
        .ground_surface_temperature_k = 290,
        .absorbed_radiation_fraction = 0.4,
        .absorbed_sky_longwave_megajoules_per_step = 1.2,
        .absorbed_lateral_longwave_megajoules_per_step = -0.1,
        .absorbed_shortwave_radiation_megajoules_per_step = 2,
    };
    const result = try calculate(inputs);
    const canopy_fourth = std.math.pow(f64, 300, 4);
    const ground_fourth = std.math.pow(f64, 290, 4);
    const emitted = 1e-10 * canopy_fourth;
    const to_ground = 1e-10 * (canopy_fourth - ground_fourth) * 0.4;
    try std.testing.expectApproxEqAbs(@as(f64, 0.075), result.canopy_water_capacity_difference_change_m3_per_step, 1e-15);
    try std.testing.expectEqual(emitted, result.emitted_canopy_longwave_megajoules_per_step);
    try std.testing.expectEqual(to_ground, result.canopy_to_ground_longwave_megajoules_per_step);
    try std.testing.expectApproxEqAbs(
        1.2 - 0.1 - emitted - to_ground,
        result.net_canopy_longwave_megajoules_per_step,
        5e-16,
    );
    try std.testing.expectEqual(2 + result.net_canopy_longwave_megajoules_per_step, result.net_canopy_radiation_megajoules_per_step);
}

test "canopy-to-ground term retains source second radiation fraction" {
    var inputs = Inputs{
        .canopy_water_capacity_m3 = 0,
        .current_canopy_water_m3 = 0,
        .legacy_substep_multiplier = 1,
        .emitted_longwave_coefficient_megajoules_per_step_k4 = 2e-10,
        .canopy_surface_temperature_k = 300,
        .ground_surface_temperature_k = 280,
        .absorbed_radiation_fraction = 0.25,
        .absorbed_sky_longwave_megajoules_per_step = 0,
        .absorbed_lateral_longwave_megajoules_per_step = 0,
        .absorbed_shortwave_radiation_megajoules_per_step = 0,
    };
    const quarter = (try calculate(inputs)).canopy_to_ground_longwave_megajoules_per_step;
    inputs.absorbed_radiation_fraction = 0.5;
    const half = (try calculate(inputs)).canopy_to_ground_longwave_megajoules_per_step;
    try std.testing.expectEqual(2 * quarter, half);
}

test "iterative radiation compatibility ceiling is runtime 200" {
    try std.testing.expectEqual(
        @as(usize, 200),
        compatibilityIterationPolicy().maximum_iterations,
    );
}
