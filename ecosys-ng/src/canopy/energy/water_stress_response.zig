const std = @import("std");

pub const RootProfile = enum {
    shallow,
    non_shallow,
};

pub const Inputs = struct {
    root_profile: RootProfile,
    canopy_turgor_potential_megapascal: f64,
    minimum_canopy_turgor_potential_megapascal: f64,
    canopy_water_potential_megapascal: f64,
    stomatal_turgor_shape_per_megapascal: f64,
};

pub const Response = struct {
    turgor_expansion_factor: f64,
    stomatal_resistance_factor: f64,
    growth_factor: f64,
    water_potential_expansion_factor: f64,
};

/// Exact grosub.f lines 535--544 canopy-water stress response.
///
/// `shallow` represents source IGTYP=0; every other runtime root-profile
/// value follows the `non_shallow` equations. Water and turgor potentials are MPa,
/// and the stomatal shape parameter is MPa^-1.
pub fn calculate(inputs: Inputs) !Response {
    inline for (.{
        inputs.canopy_turgor_potential_megapascal,
        inputs.minimum_canopy_turgor_potential_megapascal,
        inputs.canopy_water_potential_megapascal,
        inputs.stomatal_turgor_shape_per_megapascal,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopyWaterStressInput;

    const turgor_expansion_factor = @min(
        1.0,
        @max(
            0.0,
            inputs.canopy_turgor_potential_megapascal -
                inputs.minimum_canopy_turgor_potential_megapascal,
        ),
    );
    const stomatal_resistance_factor = switch (inputs.root_profile) {
        .shallow => 1.0,
        .non_shallow => std.math.exp(
            inputs.stomatal_turgor_shape_per_megapascal *
                inputs.canopy_turgor_potential_megapascal,
        ),
    };
    const growth_exponent: f64 = switch (inputs.root_profile) {
        .shallow => 0.05,
        .non_shallow => 0.10,
    };
    const growth_factor = std.math.exp(
        growth_exponent * inputs.canopy_water_potential_megapascal,
    );
    const water_potential_expansion_factor = std.math.pow(
        f64,
        growth_factor,
        0.25,
    );
    inline for (.{ stomatal_resistance_factor, growth_factor, water_potential_expansion_factor }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteCanopyWaterStressResponse;

    return .{
        .turgor_expansion_factor = turgor_expansion_factor,
        .stomatal_resistance_factor = stomatal_resistance_factor,
        .growth_factor = growth_factor,
        .water_potential_expansion_factor = water_potential_expansion_factor,
    };
}

test "GROSUB shallow-root response preserves source equations" {
    const response = try calculate(.{
        .root_profile = .shallow,
        .canopy_turgor_potential_megapascal = -0.4,
        .minimum_canopy_turgor_potential_megapascal = -0.9,
        .canopy_water_potential_megapascal = -2.0,
        .stomatal_turgor_shape_per_megapascal = 12.0,
    });
    try std.testing.expectEqual(@as(f64, 0.5), response.turgor_expansion_factor);
    try std.testing.expectEqual(@as(f64, 1.0), response.stomatal_resistance_factor);
    try std.testing.expectApproxEqAbs(std.math.exp(-0.1), response.growth_factor, 1.0e-15);
    try std.testing.expectApproxEqAbs(
        std.math.pow(f64, std.math.exp(-0.1), 0.25),
        response.water_potential_expansion_factor,
        1.0e-15,
    );
}

test "GROSUB deeper-root response and turgor bounds preserve source equations" {
    const response = try calculate(.{
        .root_profile = .non_shallow,
        .canopy_turgor_potential_megapascal = -0.25,
        .minimum_canopy_turgor_potential_megapascal = -2.0,
        .canopy_water_potential_megapascal = -3.0,
        .stomatal_turgor_shape_per_megapascal = 2.0,
    });
    try std.testing.expectEqual(@as(f64, 1.0), response.turgor_expansion_factor);
    try std.testing.expectApproxEqAbs(std.math.exp(-0.5), response.stomatal_resistance_factor, 1.0e-15);
    try std.testing.expectApproxEqAbs(std.math.exp(-0.3), response.growth_factor, 1.0e-15);

    const below_minimum = try calculate(.{
        .root_profile = .non_shallow,
        .canopy_turgor_potential_megapascal = -2.1,
        .minimum_canopy_turgor_potential_megapascal = -2.0,
        .canopy_water_potential_megapascal = 0.0,
        .stomatal_turgor_shape_per_megapascal = 0.0,
    });
    try std.testing.expectEqual(@as(f64, 0.0), below_minimum.turgor_expansion_factor);
}

test "GROSUB retains finite exponential responses above one" {
    const response = try calculate(.{
        .root_profile = .non_shallow,
        .canopy_turgor_potential_megapascal = 0.5,
        .minimum_canopy_turgor_potential_megapascal = -1.0,
        .canopy_water_potential_megapascal = 2.0,
        .stomatal_turgor_shape_per_megapascal = 2.0,
    });
    try std.testing.expectApproxEqAbs(std.math.exp(1.0), response.stomatal_resistance_factor, 1.0e-15);
    try std.testing.expectApproxEqAbs(std.math.exp(0.2), response.growth_factor, 1.0e-15);
    try std.testing.expect(response.stomatal_resistance_factor > 1);
    try std.testing.expect(response.growth_factor > 1);
    try std.testing.expect(response.water_potential_expansion_factor > 1);
}

test "non-finite canopy-water inputs and responses fail explicitly" {
    try std.testing.expectError(error.NonFiniteCanopyWaterStressInput, calculate(.{
        .root_profile = .shallow,
        .canopy_turgor_potential_megapascal = std.math.nan(f64),
        .minimum_canopy_turgor_potential_megapascal = 0.0,
        .canopy_water_potential_megapascal = 0.0,
        .stomatal_turgor_shape_per_megapascal = 0.0,
    }));
    try std.testing.expectError(error.NonFiniteCanopyWaterStressResponse, calculate(.{
        .root_profile = .non_shallow,
        .canopy_turgor_potential_megapascal = 1000.0,
        .minimum_canopy_turgor_potential_megapascal = 0.0,
        .canopy_water_potential_megapascal = 0.0,
        .stomatal_turgor_shape_per_megapascal = 1.0,
    }));
}
