const std = @import("std");

pub const Inputs = struct {
    growth_respiration_unlimited_g_c: f64,
    mobile_nitrogen_g_n: f64,
    mobile_phosphorus_g_p: f64,
    respiration_fraction_g_c_per_g_c_consumed: f64,
    other_shoot_nitrogen_g_n_per_g_c_consumed: f64,
    minimum_leaf_nitrogen_g_n_per_g_c_consumed: f64,
    variable_leaf_nitrogen_g_n_per_g_c_consumed: f64,
    other_shoot_phosphorus_g_p_per_g_c_consumed: f64,
    minimum_leaf_phosphorus_g_p_per_g_c_consumed: f64,
    variable_leaf_phosphorus_g_p_per_g_c_consumed: f64,
    nutrient_growth_fraction: f64,
};

/// Exact grosub.f lines 1787--1794 N/P limitation of shoot growth
/// respiration. Masses are g C, g N, and g P per branch and coefficient
/// units are element mass per g nonstructural C consumed.
///
/// The source admission gate deliberately tests only CNSHX or CNLFX; a
/// phosphorus-only demand therefore does not admit growth.
pub fn limit(inputs: Inputs) !f64 {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value))
            return error.InvalidShootGrowthNutrientLimitationInput;
    }
    inline for (.{
        inputs.growth_respiration_unlimited_g_c,
        inputs.respiration_fraction_g_c_per_g_c_consumed,
        inputs.other_shoot_nitrogen_g_n_per_g_c_consumed,
        inputs.minimum_leaf_nitrogen_g_n_per_g_c_consumed,
        inputs.variable_leaf_nitrogen_g_n_per_g_c_consumed,
        inputs.other_shoot_phosphorus_g_p_per_g_c_consumed,
        inputs.minimum_leaf_phosphorus_g_p_per_g_c_consumed,
        inputs.variable_leaf_phosphorus_g_p_per_g_c_consumed,
        inputs.nutrient_growth_fraction,
    }) |value| if (value < 0)
        return error.InvalidShootGrowthNutrientLimitationInput;
    if (inputs.respiration_fraction_g_c_per_g_c_consumed <= 0 or
        inputs.nutrient_growth_fraction > 1)
        return error.InvalidShootGrowthNutrientLimitationInput;
    if (inputs.growth_respiration_unlimited_g_c <= 0 or
        (inputs.other_shoot_nitrogen_g_n_per_g_c_consumed <= 0 and
            inputs.variable_leaf_nitrogen_g_n_per_g_c_consumed <= 0))
        return 0;

    const nitrogen_demand =
        inputs.other_shoot_nitrogen_g_n_per_g_c_consumed +
        inputs.minimum_leaf_nitrogen_g_n_per_g_c_consumed +
        inputs.variable_leaf_nitrogen_g_n_per_g_c_consumed *
            inputs.nutrient_growth_fraction;
    const phosphorus_demand =
        inputs.other_shoot_phosphorus_g_p_per_g_c_consumed +
        inputs.minimum_leaf_phosphorus_g_p_per_g_c_consumed +
        inputs.variable_leaf_phosphorus_g_p_per_g_c_consumed *
            inputs.nutrient_growth_fraction;
    if (nitrogen_demand <= 0 or phosphorus_demand <= 0)
        return error.InvalidShootGrowthNutrientDemand;
    const nitrogen_limited_respiration_g_c =
        @max(0, inputs.mobile_nitrogen_g_n) *
        inputs.respiration_fraction_g_c_per_g_c_consumed / nitrogen_demand;
    const phosphorus_limited_respiration_g_c =
        @max(0, inputs.mobile_phosphorus_g_p) *
        inputs.respiration_fraction_g_c_per_g_c_consumed / phosphorus_demand;
    const result = @min(
        inputs.growth_respiration_unlimited_g_c,
        nitrogen_limited_respiration_g_c,
        phosphorus_limited_respiration_g_c,
    );
    if (!std.math.isFinite(result))
        return error.NonFiniteShootGrowthNutrientLimitation;
    return result;
}

fn sampleInputs() Inputs {
    return .{
        .growth_respiration_unlimited_g_c = 5,
        .mobile_nitrogen_g_n = 0.4,
        .mobile_phosphorus_g_p = 0.03,
        .respiration_fraction_g_c_per_g_c_consumed = 0.2,
        .other_shoot_nitrogen_g_n_per_g_c_consumed = 0.01,
        .minimum_leaf_nitrogen_g_n_per_g_c_consumed = 0.005,
        .variable_leaf_nitrogen_g_n_per_g_c_consumed = 0.02,
        .other_shoot_phosphorus_g_p_per_g_c_consumed = 0.002,
        .minimum_leaf_phosphorus_g_p_per_g_c_consumed = 0.001,
        .variable_leaf_phosphorus_g_p_per_g_c_consumed = 0.004,
        .nutrient_growth_fraction = 0.5,
    };
}

test "GROSUB limits growth by source-ordered N and P capacities" {
    const inputs = sampleInputs();
    const nitrogen_demand = 0.01 + 0.005 + 0.02 * 0.5;
    const phosphorus_demand = 0.002 + 0.001 + 0.004 * 0.5;
    const expected = @min(
        5.0,
        0.4 * 0.2 / nitrogen_demand,
        0.03 * 0.2 / phosphorus_demand,
    );
    try std.testing.expectEqual(expected, try limit(inputs));
}

test "GROSUB N-only admission gate rejects phosphorus-only demand" {
    var inputs = sampleInputs();
    inputs.other_shoot_nitrogen_g_n_per_g_c_consumed = 0;
    inputs.minimum_leaf_nitrogen_g_n_per_g_c_consumed = 0;
    inputs.variable_leaf_nitrogen_g_n_per_g_c_consumed = 0;
    try std.testing.expectEqual(@as(f64, 0), try limit(inputs));
}

test "zero growth follows source else branch before nutrient division" {
    var inputs = sampleInputs();
    inputs.growth_respiration_unlimited_g_c = 0;
    inputs.other_shoot_phosphorus_g_p_per_g_c_consumed = 0;
    inputs.minimum_leaf_phosphorus_g_p_per_g_c_consumed = 0;
    inputs.variable_leaf_phosphorus_g_p_per_g_c_consumed = 0;
    try std.testing.expectEqual(@as(f64, 0), try limit(inputs));
}

test "admitted zero nutrient denominator fails instead of propagating NaN" {
    var inputs = sampleInputs();
    inputs.other_shoot_phosphorus_g_p_per_g_c_consumed = 0;
    inputs.minimum_leaf_phosphorus_g_p_per_g_c_consumed = 0;
    inputs.variable_leaf_phosphorus_g_p_per_g_c_consumed = 0;
    try std.testing.expectError(
        error.InvalidShootGrowthNutrientDemand,
        limit(inputs),
    );
}
