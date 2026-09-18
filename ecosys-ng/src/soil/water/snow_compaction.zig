const std = @import("std");
const snow = @import("../solute/snow_solute_transport.zig");

pub const Parameters = struct {
    maximum_temperature_metamorphism_density_megagrams_per_m3: f64,
    temperature_metamorphism_rate_per_h: f64,
    temperature_metamorphism_exponent_per_c: f64,
    viscosity_scale_megagrams_h_per_m3: f64,
    viscosity_temperature_exponent_per_c: f64,
    viscosity_density_exponent_m3_per_megagram: f64,
    minimum_snowfall_temperature_c: f64,
    maximum_snowfall_temperature_c: f64,
    snowfall_density_temperature_coefficient_megagrams_per_m3_c_pow_1_5: f64,
};

pub const Inputs = struct {
    snowfall_water_equivalent_m3: []const f64,
    atmospheric_temperature_k: []const f64,
    timestep_h: f64,
    initial_snow_density_megagrams_per_m3: f64,
    ice_density_megagrams_per_m3: f64,
};

/// REDIST snow metamorphism and overburden compaction. Density candidates are
/// validated for every runtime layer before any state is state_updateted.
pub fn apply(allocator: std.mem.Allocator, state: *snow.State, inputs: Inputs, parameters: Parameters) !void {
    if (inputs.snowfall_water_equivalent_m3.len != state.cell_count or inputs.atmospheric_temperature_k.len != state.cell_count) return error.SnowCompactionDimensionMismatch;
    inline for (.{ inputs.timestep_h, inputs.initial_snow_density_megagrams_per_m3, inputs.ice_density_megagrams_per_m3, parameters.maximum_temperature_metamorphism_density_megagrams_per_m3, parameters.temperature_metamorphism_rate_per_h, parameters.temperature_metamorphism_exponent_per_c, parameters.viscosity_scale_megagrams_h_per_m3, parameters.viscosity_temperature_exponent_per_c, parameters.viscosity_density_exponent_m3_per_megagram, parameters.minimum_snowfall_temperature_c, parameters.maximum_snowfall_temperature_c, parameters.snowfall_density_temperature_coefficient_megagrams_per_m3_c_pow_1_5 }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSnowCompactionParameter;
    if (inputs.timestep_h <= 0 or inputs.initial_snow_density_megagrams_per_m3 <= 0 or inputs.ice_density_megagrams_per_m3 <= 0 or parameters.maximum_temperature_metamorphism_density_megagrams_per_m3 <= 0 or parameters.temperature_metamorphism_rate_per_h < 0 or parameters.viscosity_scale_megagrams_h_per_m3 <= 0 or parameters.maximum_snowfall_temperature_c < parameters.minimum_snowfall_temperature_c or parameters.snowfall_density_temperature_coefficient_megagrams_per_m3_c_pow_1_5 < 0) return error.InvalidSnowCompactionParameter;

    const density = try allocator.dupe(f64, state.snow_density_megagrams_per_m3);
    defer allocator.free(density);
    for (0..state.cell_count) |cell| {
        const snowfall = inputs.snowfall_water_equivalent_m3[cell];
        const atmospheric_temperature_k = inputs.atmospheric_temperature_k[cell];
        if (!std.math.isFinite(snowfall) or snowfall < 0 or !std.math.isFinite(atmospheric_temperature_k) or atmospheric_temperature_k <= 0) return error.InvalidSnowCompactionInput;
        const area_m2 = state.horizontal_area_m2[cell * state.layer_capacity];
        if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidSnowCompactionArea;
        var overburden_water_equivalent_m3: f64 = 0;
        for (0..state.layer_capacity) |layer| {
            const index = cell * state.layer_capacity + layer;
            inline for (.{ state.solid_snow_water_equivalent_m3[index], state.liquid_water_volume_m3[index], state.ice_volume_m3[index], state.temperature_k[index], density[index] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSnowCompactionState;
            if (state.solid_snow_water_equivalent_m3[index] < 0 or state.liquid_water_volume_m3[index] < 0 or state.ice_volume_m3[index] < 0 or state.temperature_k[index] <= 0 or density[index] <= 0) return error.InvalidSnowCompactionState;

            const layer_water_equivalent_m3 = state.solid_snow_water_equivalent_m3[index] + state.liquid_water_volume_m3[index] + state.ice_volume_m3[index] * inputs.ice_density_megagrams_per_m3;
            overburden_water_equivalent_m3 += 0.5 * layer_water_equivalent_m3;
            // REDIST enters the metamorphism/overburden math only for an
            // extant snow layer, but its ELSE arm (redist.f:4116-4132) still
            // resets DENSS every hour for an empty layer: to DENS0 for L=1,
            // or cascaded from DENSS(L-1) otherwise. Reproduce that reset so a
            // layer that later gets repopulated by snow_relayering.zig (which
            // moves mass without touching density) picks up a physically
            // current density instead of an arbitrary historical one.
            if (!state.active[index] or state.solid_snow_water_equivalent_m3[index] <= 0) {
                overburden_water_equivalent_m3 += 0.5 * layer_water_equivalent_m3;
                density[index] = if (layer == 0) inputs.initial_snow_density_megagrams_per_m3 else density[index - 1];
                continue;
            }
            if (layer == 0 and snowfall > 0 and state.solid_snow_water_equivalent_m3[index] > 0) {
                const snowfall_temperature_c = std.math.clamp(atmospheric_temperature_k - 273.15, parameters.minimum_snowfall_temperature_c, parameters.maximum_snowfall_temperature_c);
                const snowfall_density_megagrams_per_m3 = inputs.initial_snow_density_megagrams_per_m3 + parameters.snowfall_density_temperature_coefficient_megagrams_per_m3_c_pow_1_5 * std.math.pow(f64, snowfall_temperature_c - parameters.minimum_snowfall_temperature_c, 1.5);
                // REDIST 4008--4010 deliberately uses the gross solid-snow
                // transfer after the same-hour vapor and phase updates have
                // changed VOLSSL.  Consequently VOLSSL-XFLWS may be negative
                // during partial melt of fresh snow; clamping or rejecting
                // that term changes the translated density physics.
                const mixed_solid_volume_m3 = snowfall / snowfall_density_megagrams_per_m3 +
                    (state.solid_snow_water_equivalent_m3[index] - snowfall) / density[index];
                if (!std.math.isFinite(mixed_solid_volume_m3) or mixed_solid_volume_m3 <= 0)
                    return error.InvalidSnowfallDensityMixture;
                density[index] = state.solid_snow_water_equivalent_m3[index] / mixed_solid_volume_m3;
                if (!std.math.isFinite(density[index]) or density[index] <= 0)
                    return error.InvalidSnowfallDensityMixture;
            }

            const temperature_c = state.temperature_k[index] - 273.15;
            const temperature_rate = if (density[index] < parameters.maximum_temperature_metamorphism_density_megagrams_per_m3)
                density[index] * parameters.temperature_metamorphism_rate_per_h * std.math.exp(parameters.temperature_metamorphism_exponent_per_c * temperature_c)
            else
                0;
            const viscosity_megagrams_h_per_m3 = parameters.viscosity_scale_megagrams_h_per_m3 * std.math.exp(parameters.viscosity_temperature_exponent_per_c * temperature_c + parameters.viscosity_density_exponent_m3_per_megagram * density[index]);
            const overburden_rate = density[index] * overburden_water_equivalent_m3 / (area_m2 * viscosity_megagrams_h_per_m3);
            const next_density = density[index] + (temperature_rate + overburden_rate) * inputs.timestep_h;
            if (!std.math.isFinite(next_density) or next_density <= 0) return error.InvalidSnowCompactionResult;
            density[index] = next_density;
            overburden_water_equivalent_m3 += 0.5 * layer_water_equivalent_m3;
        }
    }
    @memcpy(state.snow_density_megagrams_per_m3, density);
    state.refreshAllGeometry();
}

test "REDIST compaction increases density and conserves every inventory" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{2}, &.{268}, &.{ 0.05, 0.15 }, 0.05, snow.test_thermodynamics);
    state.liquid_water_volume_m3[0] = 0.001;
    state.amount_g[0] = 7;
    const solid_before = state.solid_snow_water_equivalent_m3[0] + state.solid_snow_water_equivalent_m3[1];
    try apply(std.testing.allocator, &state, .{ .snowfall_water_equivalent_m3 = &.{0}, .atmospheric_temperature_k = &.{268}, .timestep_h = 1, .initial_snow_density_megagrams_per_m3 = 0.05, .ice_density_megagrams_per_m3 = 0.92 }, .{ .maximum_temperature_metamorphism_density_megagrams_per_m3 = 0.25, .temperature_metamorphism_rate_per_h = 1e-5, .temperature_metamorphism_exponent_per_c = 0.04, .viscosity_scale_megagrams_h_per_m3 = 0.25, .viscosity_temperature_exponent_per_c = -0.08, .viscosity_density_exponent_m3_per_megagram = 23, .minimum_snowfall_temperature_c = -15, .maximum_snowfall_temperature_c = 2, .snowfall_density_temperature_coefficient_megagrams_per_m3_c_pow_1_5 = 1.7e-3 });
    try std.testing.expect(state.snow_density_megagrams_per_m3[0] > 0.05);
    try std.testing.expect(state.snow_density_megagrams_per_m3[1] > 0.05);
    try std.testing.expectApproxEqAbs(solid_before, state.solid_snow_water_equivalent_m3[0] + state.solid_snow_water_equivalent_m3[1], 1e-15);
    try std.testing.expectEqual(@as(f64, 7), state.amount_g[0]);
}

test "empty capacity layers cascade DENSS from the layer above instead of holding stale density" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.02}, &.{1}, &.{268}, &.{ 0.05, 0.10 }, 0.05, snow.test_thermodynamics);
    // Give the empty layer a stale density that must not survive the reset.
    state.snow_density_megagrams_per_m3[1] = 0.4;
    try apply(std.testing.allocator, &state, .{ .snowfall_water_equivalent_m3 = &.{0}, .atmospheric_temperature_k = &.{268}, .timestep_h = 1, .initial_snow_density_megagrams_per_m3 = 0.05, .ice_density_megagrams_per_m3 = 0.92 }, .{ .maximum_temperature_metamorphism_density_megagrams_per_m3 = 0.25, .temperature_metamorphism_rate_per_h = 1e-5, .temperature_metamorphism_exponent_per_c = 0.04, .viscosity_scale_megagrams_h_per_m3 = 0.25, .viscosity_temperature_exponent_per_c = -0.08, .viscosity_density_exponent_m3_per_megagram = 23, .minimum_snowfall_temperature_c = -15, .maximum_snowfall_temperature_c = 2, .snowfall_density_temperature_coefficient_megagrams_per_m3_c_pow_1_5 = 1.7e-3 });
    // Layer 1 (index 1) is empty and follows an active layer 0 (index 0), so
    // REDIST's ELSE arm (redist.f:4130) cascades DENSS(L)=DENSS(L-1): the
    // empty layer must pick up layer 0's freshly-updated density, not its own
    // stale prior value.
    try std.testing.expectEqual(state.snow_density_megagrams_per_m3[0], state.snow_density_megagrams_per_m3[1]);
}

test "snow compaction preserves REDIST gross-snowfall mixing after partial melt" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.01}, &.{1}, &.{268}, &.{0.10}, 0.05, snow.test_thermodynamics);
    // Model the post-phase, pre-compaction state directly: 0.02 m3 gross
    // snowfall entered an older 0.10 Mg/m3 layer, and 0.01 m3 remains solid.
    state.solid_snow_water_equivalent_m3[0] = 0.01;
    state.snow_density_megagrams_per_m3[0] = 0.10;
    try apply(std.testing.allocator, &state, .{
        .snowfall_water_equivalent_m3 = &.{0.02},
        .atmospheric_temperature_k = &.{268},
        .timestep_h = 1,
        .initial_snow_density_megagrams_per_m3 = 0.05,
        .ice_density_megagrams_per_m3 = 0.92,
    }, .{
        .maximum_temperature_metamorphism_density_megagrams_per_m3 = 0.25,
        .temperature_metamorphism_rate_per_h = 1e-5,
        .temperature_metamorphism_exponent_per_c = 0.04,
        .viscosity_scale_megagrams_h_per_m3 = 0.25,
        .viscosity_temperature_exponent_per_c = -0.08,
        .viscosity_density_exponent_m3_per_megagram = 23,
        .minimum_snowfall_temperature_c = -15,
        .maximum_snowfall_temperature_c = 2,
        .snowfall_density_temperature_coefficient_megagrams_per_m3_c_pow_1_5 = 1.7e-3,
    });
    // The exact REDIST mixture has a negative prior-solid term here because
    // half the gross snowfall has melted before compaction.  It remains a
    // finite positive volume and therefore must not be clipped or rejected.
    const snowfall_density = 0.05 + 1.7e-3 * std.math.pow(f64, -5.15 - -15.0, 1.5);
    const mixed_volume = 0.02 / snowfall_density + (0.01 - 0.02) / 0.10;
    const mixed_density = 0.01 / mixed_volume;
    const temperature_rate = mixed_density * 1e-5 * std.math.exp(0.04 * -5.15);
    const viscosity = 0.25 * std.math.exp(-0.08 * -5.15 + 23 * mixed_density);
    const overburden_rate = mixed_density * 0.5 * 0.01 / viscosity;
    try std.testing.expectApproxEqRel(mixed_density + temperature_rate + overburden_rate, state.snow_density_megagrams_per_m3[0], 1e-13);
}

test "an empty top layer resets density to the initial snow density" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0}, &.{1}, &.{268}, &.{0.10}, 0.05, snow.test_thermodynamics);
    state.snow_density_megagrams_per_m3[0] = 0.4;
    try apply(std.testing.allocator, &state, .{ .snowfall_water_equivalent_m3 = &.{0}, .atmospheric_temperature_k = &.{268}, .timestep_h = 1, .initial_snow_density_megagrams_per_m3 = 0.05, .ice_density_megagrams_per_m3 = 0.92 }, .{ .maximum_temperature_metamorphism_density_megagrams_per_m3 = 0.25, .temperature_metamorphism_rate_per_h = 1e-5, .temperature_metamorphism_exponent_per_c = 0.04, .viscosity_scale_megagrams_h_per_m3 = 0.25, .viscosity_temperature_exponent_per_c = -0.08, .viscosity_density_exponent_m3_per_megagram = 23, .minimum_snowfall_temperature_c = -15, .maximum_snowfall_temperature_c = 2, .snowfall_density_temperature_coefficient_megagrams_per_m3_c_pow_1_5 = 1.7e-3 });
    try std.testing.expectEqual(@as(f64, 0.05), state.snow_density_megagrams_per_m3[0]);
}
