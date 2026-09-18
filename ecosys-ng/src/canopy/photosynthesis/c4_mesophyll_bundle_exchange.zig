const std = @import("std");

pub const Inputs = struct {
    bundle_sheath_nonstructural_carbon_g_c: f64,
    mesophyll_nonstructural_carbon_g_c: f64,
    bundle_sheath_fixation_g_c_per_timestep: f64,
    mesophyll_fixation_g_c_per_timestep: f64,
    leaf_carbon_g_c: f64,
    bundle_sheath_water_g_h2o_per_g_c: f64,
    mesophyll_water_g_h2o_per_g_c: f64,
    timestep_h: f64,
};

pub const Result = struct {
    bundle_sheath_nonstructural_carbon_g_c: f64,
    mesophyll_nonstructural_carbon_g_c: f64,
    mesophyll_to_bundle_sheath_carbon_g_c: f64,
};

/// Exact grosub.f lines 2112--2118 C4 mesophyll-to-bundle-sheath exchange for
/// one runtime node. The apparently cancellable leaf-carbon factors remain in
/// source order to preserve initial translation rounding and traceability.
pub fn exchange(inputs: Inputs) !Result {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteCanopyC4ExchangeInput;
    }
    if (inputs.bundle_sheath_nonstructural_carbon_g_c < 0 or
        inputs.mesophyll_nonstructural_carbon_g_c < 0 or
        inputs.bundle_sheath_fixation_g_c_per_timestep < 0 or
        inputs.mesophyll_fixation_g_c_per_timestep < 0 or
        inputs.leaf_carbon_g_c <= 0 or
        inputs.bundle_sheath_water_g_h2o_per_g_c <= 0 or
        inputs.mesophyll_water_g_h2o_per_g_c <= 0 or
        inputs.timestep_h <= 0)
        return error.InvalidCanopyC4ExchangeInput;

    var bundle_sheath_carbon_g_c =
        inputs.bundle_sheath_nonstructural_carbon_g_c -
        inputs.bundle_sheath_fixation_g_c_per_timestep;
    var mesophyll_carbon_g_c =
        inputs.mesophyll_nonstructural_carbon_g_c +
        inputs.mesophyll_fixation_g_c_per_timestep;
    const transfer_g_c = 1.0 *
        (mesophyll_carbon_g_c * inputs.leaf_carbon_g_c *
            inputs.bundle_sheath_water_g_h2o_per_g_c -
            bundle_sheath_carbon_g_c * inputs.leaf_carbon_g_c *
                inputs.mesophyll_water_g_h2o_per_g_c) /
        (inputs.leaf_carbon_g_c *
            (inputs.bundle_sheath_water_g_h2o_per_g_c +
                inputs.mesophyll_water_g_h2o_per_g_c)) *
        inputs.timestep_h;
    mesophyll_carbon_g_c = mesophyll_carbon_g_c - transfer_g_c;
    bundle_sheath_carbon_g_c = bundle_sheath_carbon_g_c + transfer_g_c;
    inline for (.{ bundle_sheath_carbon_g_c, mesophyll_carbon_g_c, transfer_g_c }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteCanopyC4ExchangeResult;
    if (bundle_sheath_carbon_g_c < 0 or mesophyll_carbon_g_c < 0)
        return error.CanopyC4ExchangePoolExhausted;
    return .{
        .bundle_sheath_nonstructural_carbon_g_c = bundle_sheath_carbon_g_c,
        .mesophyll_nonstructural_carbon_g_c = mesophyll_carbon_g_c,
        .mesophyll_to_bundle_sheath_carbon_g_c = transfer_g_c,
    };
}

fn sampleInputs() Inputs {
    return .{
        .bundle_sheath_nonstructural_carbon_g_c = 2,
        .mesophyll_nonstructural_carbon_g_c = 5,
        .bundle_sheath_fixation_g_c_per_timestep = 0.2,
        .mesophyll_fixation_g_c_per_timestep = 0.6,
        .leaf_carbon_g_c = 3,
        .bundle_sheath_water_g_h2o_per_g_c = 1.2,
        .mesophyll_water_g_h2o_per_g_c = 4.8,
        .timestep_h = 0.25,
    };
}

test "GROSUB C4 exchange preserves exact source operation order" {
    const inputs = sampleInputs();
    const bundle_after_fixation = 2.0 - 0.2;
    const mesophyll_after_fixation = 5.0 + 0.6;
    const transfer = 1.0 *
        (mesophyll_after_fixation * 3.0 * 1.2 -
            bundle_after_fixation * 3.0 * 4.8) /
        (3.0 * (1.2 + 4.8)) * 0.25;
    const result = try exchange(inputs);
    try std.testing.expectApproxEqAbs(transfer, result.mesophyll_to_bundle_sheath_carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(mesophyll_after_fixation - transfer, result.mesophyll_nonstructural_carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(bundle_after_fixation + transfer, result.bundle_sheath_nonstructural_carbon_g_c, 1.0e-15);
}

test "C4 exchange conserves the source-adjusted two-pool total" {
    const inputs = sampleInputs();
    const result = try exchange(inputs);
    const expected = inputs.bundle_sheath_nonstructural_carbon_g_c -
        inputs.bundle_sheath_fixation_g_c_per_timestep +
        inputs.mesophyll_nonstructural_carbon_g_c +
        inputs.mesophyll_fixation_g_c_per_timestep;
    try std.testing.expectApproxEqAbs(
        expected,
        result.bundle_sheath_nonstructural_carbon_g_c +
            result.mesophyll_nonstructural_carbon_g_c,
        1.0e-15,
    );
}

test "invalid exchange domain and exhausted result fail explicitly" {
    var inputs = sampleInputs();
    inputs.leaf_carbon_g_c = 0;
    try std.testing.expectError(error.InvalidCanopyC4ExchangeInput, exchange(inputs));
    inputs = sampleInputs();
    inputs.bundle_sheath_fixation_g_c_per_timestep = 100;
    try std.testing.expectError(error.CanopyC4ExchangePoolExhausted, exchange(inputs));
}
