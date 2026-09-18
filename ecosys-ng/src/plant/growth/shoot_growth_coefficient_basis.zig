const std = @import("std");

pub const EmergenceState = enum {
    pre_emergence,
    emerged,
};

pub const Inputs = struct {
    emergence: EmergenceState,
    leaf_growth_yield_g_c_per_g_c: f64,
    petiole_growth_yield_g_c_per_g_c: f64,
    leaf_nitrogen_to_carbon_g_n_per_g_c: f64,
    petiole_nitrogen_to_carbon_g_n_per_g_c: f64,
    leaf_phosphorus_to_carbon_g_p_per_g_c: f64,
    petiole_phosphorus_to_carbon_g_p_per_g_c: f64,
    root_growth_yield_g_c_per_g_c: f64,
    root_nitrogen_to_carbon_g_n_per_g_c: f64,
    root_phosphorus_to_carbon_g_p_per_g_c: f64,
};

pub const Coefficients = struct {
    leaf_growth_yield_g_c_per_g_c: f64,
    petiole_growth_yield_g_c_per_g_c: f64,
    leaf_nitrogen_to_carbon_g_n_per_g_c: f64,
    petiole_nitrogen_to_carbon_g_n_per_g_c: f64,
    leaf_phosphorus_to_carbon_g_p_per_g_c: f64,
    petiole_phosphorus_to_carbon_g_p_per_g_c: f64,
};

/// Exact grosub.f lines 868--882 selection of the leaf and petiole coefficient
/// basis. Ratios are g N or g P per g C; growth yields are g C produced per
/// g nonstructural C consumed.
///
/// Before emergence, both prospective shoot organs use root coefficients.
/// After emergence, each uses its shoot-organ coefficient. This selection
/// precedes the seven-organ weighted coefficients at source line 883.
pub fn select(inputs: Inputs) !Coefficients {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (field.type == f64) {
            const value = @field(inputs, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidShootGrowthCoefficientBasis;
        }
    }
    return switch (inputs.emergence) {
        .emerged => .{
            .leaf_growth_yield_g_c_per_g_c = inputs.leaf_growth_yield_g_c_per_g_c,
            .petiole_growth_yield_g_c_per_g_c = inputs.petiole_growth_yield_g_c_per_g_c,
            .leaf_nitrogen_to_carbon_g_n_per_g_c = inputs.leaf_nitrogen_to_carbon_g_n_per_g_c,
            .petiole_nitrogen_to_carbon_g_n_per_g_c = inputs.petiole_nitrogen_to_carbon_g_n_per_g_c,
            .leaf_phosphorus_to_carbon_g_p_per_g_c = inputs.leaf_phosphorus_to_carbon_g_p_per_g_c,
            .petiole_phosphorus_to_carbon_g_p_per_g_c = inputs.petiole_phosphorus_to_carbon_g_p_per_g_c,
        },
        .pre_emergence => .{
            .leaf_growth_yield_g_c_per_g_c = inputs.root_growth_yield_g_c_per_g_c,
            .petiole_growth_yield_g_c_per_g_c = inputs.root_growth_yield_g_c_per_g_c,
            .leaf_nitrogen_to_carbon_g_n_per_g_c = inputs.root_nitrogen_to_carbon_g_n_per_g_c,
            .petiole_nitrogen_to_carbon_g_n_per_g_c = inputs.root_nitrogen_to_carbon_g_n_per_g_c,
            .leaf_phosphorus_to_carbon_g_p_per_g_c = inputs.root_phosphorus_to_carbon_g_p_per_g_c,
            .petiole_phosphorus_to_carbon_g_p_per_g_c = inputs.root_phosphorus_to_carbon_g_p_per_g_c,
        },
    };
}

fn sampleInputs(emergence: EmergenceState) Inputs {
    return .{
        .emergence = emergence,
        .leaf_growth_yield_g_c_per_g_c = 0.81,
        .petiole_growth_yield_g_c_per_g_c = 0.72,
        .leaf_nitrogen_to_carbon_g_n_per_g_c = 0.041,
        .petiole_nitrogen_to_carbon_g_n_per_g_c = 0.022,
        .leaf_phosphorus_to_carbon_g_p_per_g_c = 0.0041,
        .petiole_phosphorus_to_carbon_g_p_per_g_c = 0.0022,
        .root_growth_yield_g_c_per_g_c = 0.63,
        .root_nitrogen_to_carbon_g_n_per_g_c = 0.031,
        .root_phosphorus_to_carbon_g_p_per_g_c = 0.0031,
    };
}

test "GROSUB emerged branch selects distinct leaf and petiole coefficients" {
    const result = try select(sampleInputs(.emerged));
    try std.testing.expectEqual(@as(f64, 0.81), result.leaf_growth_yield_g_c_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.72), result.petiole_growth_yield_g_c_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.041), result.leaf_nitrogen_to_carbon_g_n_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.022), result.petiole_nitrogen_to_carbon_g_n_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.0041), result.leaf_phosphorus_to_carbon_g_p_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.0022), result.petiole_phosphorus_to_carbon_g_p_per_g_c);
}

test "GROSUB pre-emergence branch uses root basis for both shoot organs" {
    const result = try select(sampleInputs(.pre_emergence));
    try std.testing.expectEqual(@as(f64, 0.63), result.leaf_growth_yield_g_c_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.63), result.petiole_growth_yield_g_c_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.031), result.leaf_nitrogen_to_carbon_g_n_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.031), result.petiole_nitrogen_to_carbon_g_n_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.0031), result.leaf_phosphorus_to_carbon_g_p_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.0031), result.petiole_phosphorus_to_carbon_g_p_per_g_c);
}

test "non-finite late coefficient basis fails explicitly" {
    var inputs = sampleInputs(.emerged);
    inputs.root_phosphorus_to_carbon_g_p_per_g_c = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidShootGrowthCoefficientBasis,
        select(inputs),
    );
}
