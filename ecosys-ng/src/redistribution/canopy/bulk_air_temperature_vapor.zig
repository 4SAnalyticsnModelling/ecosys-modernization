// **A8a DISPOSITION: BOUND; ATMOS-TKQ-001 is closed for TKQ/VPQ blending.**
//
// Accurate translation of `redist.f:4373--4377`, `TKQ = TKQGX*FRADG +
// TKQT*(1-FRADG)` with `TCQ = TKQ-273.15` and the matching vapor blend, verified
// against the source. `atmosphere/canopy_gas_state.zig` calls `blend` for every
// cell during accepted-hour closeout. Its FRADG is the live
// `canopy_exposure.State.ground_exposure_fraction`; live and standing-dead
// TKQC/VPQC are radiation-weighted before this final ground/canopy blend. The
// resulting TKQ/VPQ are staged atomically, checkpointed, and used for the next
// hour's gas mass concentrations and downstream atmospheric boundary science.

const std = @import("std");

pub const Inputs = struct {
    /// TKQGX. Ground surface air temperature (K).
    ground_temperature_k: f64,
    /// TKQT. Bulk canopy air temperature (K).
    canopy_temperature_k: f64,
    /// VPQGX. Ground surface vapor concentration (m3 m-3).
    ground_vapor_m3_per_m3: f64,
    /// VPQT. Bulk canopy vapor concentration (m3 m-3).
    canopy_vapor_m3_per_m3: f64,
    /// FRADG. Fraction of radiation received at ground surface (dimensionless,
    /// [0, 1]).
    ground_radiation_fraction: f64,
};

pub const Result = struct {
    /// TKQ. Bulk canopy-and-ground air temperature (K).
    bulk_temperature_k: f64,
    /// TCQ. Bulk temperature (°C).
    bulk_temperature_c: f64,
    /// VPQ. Bulk canopy-and-ground vapor concentration (m3 m-3).
    bulk_vapor_m3_per_m3: f64,
};

/// Direct translation of redist.f lines 4373--4377.
///
/// Blends ground surface and canopy bulk temperatures and vapor
/// concentrations weighted by the ground radiation fraction FRADG:
///   TKQ = TKQGX*FRADG + TKQT*(1-FRADG)
///   TCQ = TKQ - 273.15
///   VPQ = VPQGX*FRADG + VPQT*(1-FRADG)
pub fn blend(inputs: Inputs) !Result {
    const f = inputs.ground_radiation_fraction;
    if (!std.math.isFinite(f) or f < 0.0 or f > 1.0)
        return error.InvalidGroundRadiationFraction;
    if (!std.math.isFinite(inputs.ground_temperature_k) or inputs.ground_temperature_k <= 0 or
        !std.math.isFinite(inputs.canopy_temperature_k) or inputs.canopy_temperature_k <= 0 or
        !std.math.isFinite(inputs.ground_vapor_m3_per_m3) or inputs.ground_vapor_m3_per_m3 < 0 or
        !std.math.isFinite(inputs.canopy_vapor_m3_per_m3) or inputs.canopy_vapor_m3_per_m3 < 0)
        return error.InvalidBulkAirInput;

    const bulk_temperature_k = inputs.ground_temperature_k * f +
        inputs.canopy_temperature_k * (1.0 - f);
    const result = Result{
        .bulk_temperature_k = bulk_temperature_k,
        .bulk_temperature_c = bulk_temperature_k - 273.15,
        .bulk_vapor_m3_per_m3 = inputs.ground_vapor_m3_per_m3 * f +
            inputs.canopy_vapor_m3_per_m3 * (1.0 - f),
    };
    inline for (@typeInfo(Result).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteBulkAirResult;
    return result;
}

test "REDIST bulk air blend uses pure ground when FRADG=1" {
    const result = try blend(.{
        .ground_temperature_k = 280.0,
        .canopy_temperature_k = 290.0,
        .ground_vapor_m3_per_m3 = 0.01,
        .canopy_vapor_m3_per_m3 = 0.02,
        .ground_radiation_fraction = 1.0,
    });
    try std.testing.expectEqual(@as(f64, 280.0), result.bulk_temperature_k);
    try std.testing.expectApproxEqRel(
        result.bulk_temperature_k - 273.15,
        result.bulk_temperature_c,
        1.0e-15,
    );
    try std.testing.expectEqual(@as(f64, 0.01), result.bulk_vapor_m3_per_m3);
}

test "REDIST bulk air blend uses pure canopy when FRADG=0" {
    const result = try blend(.{
        .ground_temperature_k = 280.0,
        .canopy_temperature_k = 290.0,
        .ground_vapor_m3_per_m3 = 0.01,
        .canopy_vapor_m3_per_m3 = 0.02,
        .ground_radiation_fraction = 0.0,
    });
    try std.testing.expectEqual(@as(f64, 290.0), result.bulk_temperature_k);
    try std.testing.expectEqual(@as(f64, 0.02), result.bulk_vapor_m3_per_m3);
}

test "REDIST bulk air blend linearly interpolates at 50/50" {
    const result = try blend(.{
        .ground_temperature_k = 280.0,
        .canopy_temperature_k = 300.0,
        .ground_vapor_m3_per_m3 = 0.01,
        .canopy_vapor_m3_per_m3 = 0.03,
        .ground_radiation_fraction = 0.5,
    });
    try std.testing.expectEqual(@as(f64, 290.0), result.bulk_temperature_k);
    try std.testing.expectEqual(@as(f64, 0.02), result.bulk_vapor_m3_per_m3);
}

test "REDIST bulk air blend rejects invalid ground radiation fraction" {
    try std.testing.expectError(
        error.InvalidGroundRadiationFraction,
        blend(.{
            .ground_temperature_k = 280.0,
            .canopy_temperature_k = 290.0,
            .ground_vapor_m3_per_m3 = 0.01,
            .canopy_vapor_m3_per_m3 = 0.02,
            .ground_radiation_fraction = 1.5,
        }),
    );
    try std.testing.expectError(
        error.InvalidGroundRadiationFraction,
        blend(.{
            .ground_temperature_k = 280.0,
            .canopy_temperature_k = 290.0,
            .ground_vapor_m3_per_m3 = 0.01,
            .canopy_vapor_m3_per_m3 = 0.02,
            .ground_radiation_fraction = std.math.nan(f64),
        }),
    );
}
