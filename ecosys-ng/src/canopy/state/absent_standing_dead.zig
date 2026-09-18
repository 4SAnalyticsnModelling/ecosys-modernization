const std = @import("std");
const canopy_default = @import("absent_species.zig");

pub const FallbackInputs = canopy_default.Inputs;
pub const State = canopy_default.State;

/// UPTAKE.F 4297--4316. A present standing-dead canopy preserves its supplied
/// state. An absent canopy uses the shared source-equivalent canopy defaults.
pub fn apply(
    standing_dead_present: bool,
    before: State,
    fallback_inputs: FallbackInputs,
) !State {
    if (standing_dead_present) {
        try validateState(before);
        return before;
    }
    return canopy_default.compute(fallback_inputs);
}

pub fn applyRuntimeSpecies(
    standing_dead_present: []const bool,
    initial: []const State,
    fallback_inputs: []const FallbackInputs,
    scratch: []State,
    destination: []State,
) !void {
    if (standing_dead_present.len != initial.len or
        initial.len != fallback_inputs.len or initial.len != scratch.len or
        initial.len != destination.len)
        return error.AbsentStandingDeadCanopyDimensionMismatch;
    for (
        standing_dead_present,
        initial,
        fallback_inputs,
        scratch,
    ) |present, before, inputs, *candidate| {
        candidate.* = try apply(present, before, inputs);
    }
    @memcpy(destination, scratch);
}

fn validateState(state: State) !void {
    if (!std.math.isFinite(state.intercepted_water_m3) or
        state.intercepted_water_m3 < 0 or
        !std.math.isFinite(state.canopy_air_temperature_k) or
        state.canopy_air_temperature_k <= 0 or
        !std.math.isFinite(state.canopy_air_vapor_volume_fraction) or
        state.canopy_air_vapor_volume_fraction < 0 or
        !std.math.isFinite(state.canopy_surface_temperature_k) or
        state.canopy_surface_temperature_k <= 0 or
        !std.math.isFinite(state.canopy_surface_temperature_c))
        return error.InvalidStandingDeadCanopyState;
    inline for (@typeInfo(canopy_default.EnergyFluxDiagnostics).@"struct".fields) |field|
        if (!std.math.isFinite(@field(state.energy_flux, field.name)))
            return error.InvalidStandingDeadCanopyState;
}

fn testInputs() FallbackInputs {
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

test "absent standing dead reuses exact source canopy defaults" {
    const result = try apply(false, std.mem.zeroes(State), testInputs());
    try std.testing.expectEqual(@as(f64, 2.125), result.intercepted_water_m3);
    try std.testing.expectEqualDeep(
        std.mem.zeroes(canopy_default.EnergyFluxDiagnostics),
        result.energy_flux,
    );
    try std.testing.expectEqual(@as(f64, 280), result.canopy_air_temperature_k);
    try std.testing.expectEqual(@as(f64, 280), result.canopy_surface_temperature_k);
    try std.testing.expectApproxEqAbs(@as(f64, 6.85), result.canopy_surface_temperature_c, 1e-12);
}

test "standing dead below snow surface selects topsoil temperature" {
    var inputs = testInputs();
    inputs.canopy_height_m = 0;
    const result = try apply(false, std.mem.zeroes(State), inputs);
    try std.testing.expectEqual(@as(f64, 275), result.canopy_surface_temperature_k);
}

test "present standing dead does not evaluate fallback-only inputs" {
    const before = try canopy_default.compute(testInputs());
    var unused = testInputs();
    unused.ambient_air_temperature_k = std.math.nan(f64);
    try std.testing.expectEqualDeep(before, try apply(true, before, unused));
}

test "later invalid absent species leaves destination unchanged" {
    const before = try canopy_default.compute(testInputs());
    const present = [_]bool{ false, false };
    var invalid = testInputs();
    invalid.topsoil_temperature_k = 0;
    invalid.canopy_height_m = 0;
    const inputs = [_]FallbackInputs{ testInputs(), invalid };
    const initial = [_]State{ before, before };
    var scratch: [2]State = undefined;
    var destination = [_]State{ before, before };
    destination[0].intercepted_water_m3 = 41;
    destination[1].intercepted_water_m3 = 42;
    try std.testing.expectError(
        error.InvalidAbsentSpeciesCanopyInput,
        applyRuntimeSpecies(&present, &initial, &inputs, &scratch, &destination),
    );
    try std.testing.expectEqual(@as(f64, 41), destination[0].intercepted_water_m3);
    try std.testing.expectEqual(@as(f64, 42), destination[1].intercepted_water_m3);
}
