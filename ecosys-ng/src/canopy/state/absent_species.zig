const std = @import("std");

pub const EnergyFluxDiagnostics = struct {
    net_radiation_megajoules_per_step: f64,
    latent_heat_megajoules_per_step: f64,
    sensible_heat_megajoules_per_step: f64,
    heat_storage_megajoules_per_step: f64,
    vapor_convective_heat_megajoules_per_step: f64,
    emitted_thermal_radiation_megajoules_per_step: f64,
    evaporation_m3_per_step: f64,
    transpiration_m3_per_step: f64,
    ground_canopy_vapor_flux_m3_per_step: f64,
    ground_canopy_sensible_heat_megajoules_per_step: f64,
};

pub const Inputs = struct {
    intercepted_water_m3: f64,
    intercepted_water_rate_m3_per_h: f64,
    timestep_h: f64,
    ambient_air_temperature_k: f64,
    ambient_vapor_volume_fraction: f64,
    canopy_height_m: f64,
    snow_surface_depth_m: f64,
    depth_tolerance_m: f64,
    topsoil_temperature_k: f64,
};

pub const State = struct {
    intercepted_water_m3: f64,
    energy_flux: EnergyFluxDiagnostics,
    canopy_air_temperature_k: f64,
    canopy_air_vapor_volume_fraction: f64,
    canopy_surface_temperature_k: f64,
    canopy_surface_temperature_c: f64,
};

/// UPTAKE.F 3867--3886 absent-species live-canopy defaults.
pub fn compute(inputs: Inputs) !State {
    try validate(inputs);
    var result: State = undefined;
    result.intercepted_water_m3 =
        inputs.intercepted_water_m3 +
        inputs.intercepted_water_rate_m3_per_h * inputs.timestep_h;
    result.energy_flux.net_radiation_megajoules_per_step = 0;
    result.energy_flux.latent_heat_megajoules_per_step = 0;
    result.energy_flux.sensible_heat_megajoules_per_step = 0;
    result.energy_flux.heat_storage_megajoules_per_step = 0;
    result.energy_flux.vapor_convective_heat_megajoules_per_step = 0;
    result.energy_flux.emitted_thermal_radiation_megajoules_per_step = 0;
    result.energy_flux.evaporation_m3_per_step = 0;
    result.energy_flux.transpiration_m3_per_step = 0;
    result.energy_flux.ground_canopy_vapor_flux_m3_per_step = 0;
    result.energy_flux.ground_canopy_sensible_heat_megajoules_per_step = 0;
    result.canopy_air_temperature_k = inputs.ambient_air_temperature_k;
    result.canopy_air_vapor_volume_fraction = inputs.ambient_vapor_volume_fraction;
    result.canopy_surface_temperature_k =
        if (inputs.canopy_height_m >= inputs.snow_surface_depth_m - inputs.depth_tolerance_m)
            inputs.ambient_air_temperature_k
        else
            inputs.topsoil_temperature_k;
    result.canopy_surface_temperature_c =
        result.canopy_surface_temperature_k - 273.15;
    try validateState(result);
    return result;
}

pub fn computeRuntimeSpecies(
    inputs: []const Inputs,
    scratch: []State,
    destination: []State,
) !void {
    if (inputs.len != scratch.len or inputs.len != destination.len)
        return error.AbsentSpeciesCanopyDimensionMismatch;
    for (inputs, scratch) |species_inputs, *candidate|
        candidate.* = try compute(species_inputs);
    @memcpy(destination, scratch);
}

fn validate(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteAbsentSpeciesCanopyInput;
    if (inputs.intercepted_water_m3 < 0 or
        inputs.intercepted_water_rate_m3_per_h < 0 or
        inputs.timestep_h < 0 or
        inputs.ambient_air_temperature_k <= 0 or
        inputs.ambient_vapor_volume_fraction < 0 or
        inputs.canopy_height_m < 0 or
        inputs.snow_surface_depth_m < 0 or
        inputs.depth_tolerance_m < 0 or
        inputs.topsoil_temperature_k <= 0)
        return error.InvalidAbsentSpeciesCanopyInput;
}

fn validateState(state: State) !void {
    if (!std.math.isFinite(state.intercepted_water_m3) or
        state.intercepted_water_m3 < 0 or
        !std.math.isFinite(state.canopy_surface_temperature_c))
        return error.InvalidAbsentSpeciesCanopyResult;
}

fn testInputs() Inputs {
    return .{
        .intercepted_water_m3 = 2,
        .intercepted_water_rate_m3_per_h = 0.5,
        .timestep_h = 0.25,
        .ambient_air_temperature_k = 280,
        .ambient_vapor_volume_fraction = 0.01,
        .canopy_height_m = 0.2,
        .snow_surface_depth_m = 0.1,
        .depth_tolerance_m = 1e-12,
        .topsoil_temperature_k = 275,
    };
}

test "absent species preserves source water update and zero diagnostics" {
    const result = try compute(testInputs());
    try std.testing.expectEqual(@as(f64, 2.125), result.intercepted_water_m3);
    try std.testing.expectEqualDeep(std.mem.zeroes(EnergyFluxDiagnostics), result.energy_flux);
    try std.testing.expectEqual(@as(f64, 280), result.canopy_air_temperature_k);
    try std.testing.expectEqual(@as(f64, 0.01), result.canopy_air_vapor_volume_fraction);
}

test "canopy at snow threshold uses ambient temperature" {
    var inputs = testInputs();
    inputs.canopy_height_m = inputs.snow_surface_depth_m - inputs.depth_tolerance_m;
    const result = try compute(inputs);
    try std.testing.expectEqual(inputs.ambient_air_temperature_k, result.canopy_surface_temperature_k);
    try std.testing.expectApproxEqAbs(@as(f64, 6.85), result.canopy_surface_temperature_c, 1e-12);
}

test "canopy below snow threshold uses topsoil temperature" {
    var inputs = testInputs();
    inputs.canopy_height_m = 0.05;
    const result = try compute(inputs);
    try std.testing.expectEqual(inputs.topsoil_temperature_k, result.canopy_surface_temperature_k);
    try std.testing.expectApproxEqAbs(@as(f64, 1.85), result.canopy_surface_temperature_c, 1e-12);
}

test "runtime species dimensions are unrestricted and independent" {
    var second = testInputs();
    second.canopy_height_m = 0;
    const inputs = [_]Inputs{ testInputs(), second };
    var scratch: [2]State = undefined;
    var destination: [2]State = undefined;
    try computeRuntimeSpecies(&inputs, &scratch, &destination);
    try std.testing.expectEqual(@as(f64, 280), destination[0].canopy_surface_temperature_k);
    try std.testing.expectEqual(@as(f64, 275), destination[1].canopy_surface_temperature_k);
}

test "later nonfinite species input leaves destination unchanged" {
    var second = testInputs();
    second.ambient_air_temperature_k = std.math.nan(f64);
    const inputs = [_]Inputs{ testInputs(), second };
    var scratch: [2]State = undefined;
    var destination: [2]State = undefined;
    destination[0] = try compute(testInputs());
    destination[1] = destination[0];
    destination[0].intercepted_water_m3 = 41;
    destination[1].intercepted_water_m3 = 42;
    try std.testing.expectError(
        error.NonFiniteAbsentSpeciesCanopyInput,
        computeRuntimeSpecies(&inputs, &scratch, &destination),
    );
    try std.testing.expectEqual(@as(f64, 41), destination[0].intercepted_water_m3);
    try std.testing.expectEqual(@as(f64, 42), destination[1].intercepted_water_m3);
}
