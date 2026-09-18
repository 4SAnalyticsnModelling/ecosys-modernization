const std = @import("std");

pub const Inputs = struct {
    calculation_floor: f64,
    geometry_floor_m: f64,
    initial_water_content_m3_per_m3: f64,
    initial_ice_porosity_m3_per_m3: f64,
    pure_ice_density_megagrams_per_m3: f64,
};

pub const State = struct {
    calculation_floor: f64,
    geometry_floor_m: f64,
    accumulated_area_m2: f64,
    initial_water_content_m3_per_m3: f64,
    initial_ice_porosity_m3_per_m3: f64,
    effective_ice_density_megagrams_per_m3: f64,
    ice_specific_volume_difference_m3_per_m3: f64,
};

/// Exact source-order translation of legacy `STARTS` lines 93--100.
///
/// Unlike the fixed `DATA` values in the source, every independent quantity
/// enters through runtime configuration. `DENSI` and `DENSJ` retain the source
/// equations, generalized to the configured pure-ice density.
pub fn initialize(inputs: Inputs) !State {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteSoilInitializationScale;
    }
    if (inputs.calculation_floor <= 0 or
        inputs.geometry_floor_m <= 0 or
        inputs.initial_water_content_m3_per_m3 < 0 or
        inputs.initial_water_content_m3_per_m3 > 1 or
        inputs.initial_ice_porosity_m3_per_m3 < 0 or
        inputs.initial_ice_porosity_m3_per_m3 > 1 or
        inputs.pure_ice_density_megagrams_per_m3 <= 0 or
        inputs.pure_ice_density_megagrams_per_m3 > 1 or
        inputs.initial_ice_porosity_m3_per_m3 >
            inputs.pure_ice_density_megagrams_per_m3)
    {
        return error.InvalidSoilInitializationScale;
    }

    const effective_ice_density_megagrams_per_m3 =
        inputs.pure_ice_density_megagrams_per_m3 -
        inputs.initial_ice_porosity_m3_per_m3;
    const ice_specific_volume_difference_m3_per_m3 =
        1.0 - effective_ice_density_megagrams_per_m3;

    return .{
        .calculation_floor = inputs.calculation_floor,
        .geometry_floor_m = inputs.geometry_floor_m,
        .accumulated_area_m2 = 0.0,
        .initial_water_content_m3_per_m3 = inputs.initial_water_content_m3_per_m3,
        .initial_ice_porosity_m3_per_m3 = inputs.initial_ice_porosity_m3_per_m3,
        .effective_ice_density_megagrams_per_m3 = effective_ice_density_megagrams_per_m3,
        .ice_specific_volume_difference_m3_per_m3 = ice_specific_volume_difference_m3_per_m3,
    };
}

test "STARTS source runtime values reproduce lines 93 through 100" {
    const state = try initialize(.{
        .calculation_floor = 1.0e-15,
        .geometry_floor_m = 1.0e-6,
        .initial_water_content_m3_per_m3 = 1.0e-3,
        .initial_ice_porosity_m3_per_m3 = 0.0,
        .pure_ice_density_megagrams_per_m3 = 0.92,
    });

    try std.testing.expectEqual(@as(f64, 1.0e-15), state.calculation_floor);
    try std.testing.expectEqual(@as(f64, 1.0e-6), state.geometry_floor_m);
    try std.testing.expectEqual(@as(f64, 0.0), state.accumulated_area_m2);
    try std.testing.expectEqual(
        @as(f64, 1.0e-3),
        state.initial_water_content_m3_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 0.92),
        state.effective_ice_density_megagrams_per_m3,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.08),
        state.ice_specific_volume_difference_m3_per_m3,
        1.0e-15,
    );
}

test "configured initial ice porosity preserves source density equations" {
    const state = try initialize(.{
        .calculation_floor = 1.0e-12,
        .geometry_floor_m = 2.0e-6,
        .initial_water_content_m3_per_m3 = 0.2,
        .initial_ice_porosity_m3_per_m3 = 0.02,
        .pure_ice_density_megagrams_per_m3 = 0.917,
    });

    try std.testing.expectApproxEqAbs(
        @as(f64, 0.897),
        state.effective_ice_density_megagrams_per_m3,
        1.0e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.103),
        state.ice_specific_volume_difference_m3_per_m3,
        1.0e-15,
    );
}

test "invalid runtime scales fail before producing state" {
    try std.testing.expectError(
        error.InvalidSoilInitializationScale,
        initialize(.{
            .calculation_floor = 0.0,
            .geometry_floor_m = 1.0e-6,
            .initial_water_content_m3_per_m3 = 0.1,
            .initial_ice_porosity_m3_per_m3 = 0.0,
            .pure_ice_density_megagrams_per_m3 = 0.92,
        }),
    );
    try std.testing.expectError(
        error.NonFiniteSoilInitializationScale,
        initialize(.{
            .calculation_floor = 1.0e-15,
            .geometry_floor_m = std.math.nan(f64),
            .initial_water_content_m3_per_m3 = 0.1,
            .initial_ice_porosity_m3_per_m3 = 0.0,
            .pure_ice_density_megagrams_per_m3 = 0.92,
        }),
    );
}
