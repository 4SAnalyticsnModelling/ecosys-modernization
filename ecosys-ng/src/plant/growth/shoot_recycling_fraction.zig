const std = @import("std");

pub const Concentrations = struct {
    mobile_carbon_g_c_per_g_c: f64,
    mobile_nitrogen_g_n_per_g_c: f64,
    mobile_phosphorus_g_p_per_g_c: f64,
};

pub const Inhibition = struct {
    nitrogen_g_n_per_g_c: f64,
    phosphorus_g_p_per_g_c: f64,
};

pub const ProfileCoefficients = struct {
    minimum_carbon_fraction: []const f64,
    responsive_carbon_fraction: []const f64,
    maximum_nitrogen_fraction: []const f64,
    maximum_phosphorus_fraction: []const f64,
};

pub const Fractions = struct {
    carbon: f64,
    nitrogen: f64,
    phosphorus: f64,
};

/// grosub.f lines 2509--2529. Shoot recycling coefficients remain indexed by
/// runtime root-profile type (`IGTYP`) instead of being collapsed to one scalar
/// set. Concentrations are branch mobile mass per branch structural C mass.
pub fn calculate(
    emergence_date_is_set: bool,
    root_profile_index: usize,
    concentrations: Concentrations,
    inhibition: Inhibition,
    coefficients: ProfileCoefficients,
) !Fractions {
    const profile_count = coefficients.minimum_carbon_fraction.len;
    inline for (.{
        coefficients.responsive_carbon_fraction,
        coefficients.maximum_nitrogen_fraction,
        coefficients.maximum_phosphorus_fraction,
    }) |values| if (values.len != profile_count)
        return error.ShootRecyclingProfileDimensionMismatch;
    if (profile_count == 0 or root_profile_index >= profile_count)
        return error.ShootRecyclingProfileIndexOutOfBounds;

    inline for (@typeInfo(Concentrations).@"struct".fields) |field| {
        const value = @field(concentrations, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidShootRecyclingConcentration;
    }
    inline for (@typeInfo(Inhibition).@"struct".fields) |field| {
        const value = @field(inhibition, field.name);
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidShootRecyclingInhibition;
    }
    for (0..profile_count) |profile| {
        const minimum_carbon = coefficients.minimum_carbon_fraction[profile];
        const responsive_carbon = coefficients.responsive_carbon_fraction[profile];
        const maximum_nitrogen = coefficients.maximum_nitrogen_fraction[profile];
        const maximum_phosphorus = coefficients.maximum_phosphorus_fraction[profile];
        inline for (.{ minimum_carbon, responsive_carbon, maximum_nitrogen, maximum_phosphorus }) |value|
            if (!std.math.isFinite(value) or value < 0 or value > 1)
                return error.InvalidShootRecyclingCoefficient;
        if (minimum_carbon + responsive_carbon > 1)
            return error.InvalidShootRecyclingCoefficient;
    }

    var carbon_constraint: f64 = 1.0;
    var nitrogen_constraint: f64 = 0.0;
    var phosphorus_constraint: f64 = 0.0;
    if (emergence_date_is_set and concentrations.mobile_carbon_g_c_per_g_c > 0) {
        carbon_constraint = @max(0.0, @min(1.0, @min(
            concentrations.mobile_nitrogen_g_n_per_g_c /
                (concentrations.mobile_nitrogen_g_n_per_g_c +
                    concentrations.mobile_carbon_g_c_per_g_c * inhibition.nitrogen_g_n_per_g_c),
            concentrations.mobile_phosphorus_g_p_per_g_c /
                (concentrations.mobile_phosphorus_g_p_per_g_c +
                    concentrations.mobile_carbon_g_c_per_g_c * inhibition.phosphorus_g_p_per_g_c),
        )));
        nitrogen_constraint = @max(0.0, @min(
            1.0,
            concentrations.mobile_carbon_g_c_per_g_c /
                (concentrations.mobile_carbon_g_c_per_g_c +
                    concentrations.mobile_nitrogen_g_n_per_g_c / inhibition.nitrogen_g_n_per_g_c),
        ));
        phosphorus_constraint = @max(0.0, @min(
            1.0,
            concentrations.mobile_carbon_g_c_per_g_c /
                (concentrations.mobile_carbon_g_c_per_g_c +
                    concentrations.mobile_phosphorus_g_p_per_g_c / inhibition.phosphorus_g_p_per_g_c),
        ));
    }

    const result: Fractions = .{
        .carbon = coefficients.minimum_carbon_fraction[root_profile_index] +
            carbon_constraint * coefficients.responsive_carbon_fraction[root_profile_index],
        .nitrogen = nitrogen_constraint * coefficients.maximum_nitrogen_fraction[root_profile_index],
        .phosphorus = phosphorus_constraint * coefficients.maximum_phosphorus_fraction[root_profile_index],
    };
    inline for (@typeInfo(Fractions).@"struct".fields) |field| {
        const value = @field(result, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidShootRecyclingResult;
    }
    return result;
}

fn sampleCoefficients() ProfileCoefficients {
    return .{
        .minimum_carbon_fraction = &.{ 0.1, 0.2, 0.3, 0.4 },
        .responsive_carbon_fraction = &.{ 0.2, 0.3, 0.4, 0.5 },
        .maximum_nitrogen_fraction = &.{ 0.5, 0.6, 0.7, 0.8 },
        .maximum_phosphorus_fraction = &.{ 0.4, 0.5, 0.6, 0.7 },
    };
}

test "GROSUB recycling uses selected runtime root profile" {
    const concentrations: Concentrations = .{
        .mobile_carbon_g_c_per_g_c = 0.2,
        .mobile_nitrogen_g_n_per_g_c = 0.02,
        .mobile_phosphorus_g_p_per_g_c = 0.002,
    };
    const inhibition: Inhibition = .{
        .nitrogen_g_n_per_g_c = 0.025,
        .phosphorus_g_p_per_g_c = 0.0025,
    };
    const carbon_constraint = @min(
        0.02 / (0.02 + 0.2 * 0.025),
        0.002 / (0.002 + 0.2 * 0.0025),
    );
    const nitrogen_constraint = 0.2 / (0.2 + 0.02 / 0.025);
    const phosphorus_constraint = 0.2 / (0.2 + 0.002 / 0.0025);
    const result = try calculate(true, 2, concentrations, inhibition, sampleCoefficients());
    try std.testing.expectApproxEqAbs(0.3 + carbon_constraint * 0.4, result.carbon, 1.0e-15);
    try std.testing.expectApproxEqAbs(nitrogen_constraint * 0.7, result.nitrogen, 1.0e-15);
    try std.testing.expectApproxEqAbs(phosphorus_constraint * 0.6, result.phosphorus, 1.0e-15);
}

test "pre-emergence and zero mobile carbon preserve source defaults" {
    const inhibition: Inhibition = .{
        .nitrogen_g_n_per_g_c = 0.025,
        .phosphorus_g_p_per_g_c = 0.0025,
    };
    const concentrations: Concentrations = .{
        .mobile_carbon_g_c_per_g_c = 0.2,
        .mobile_nitrogen_g_n_per_g_c = 0.02,
        .mobile_phosphorus_g_p_per_g_c = 0.002,
    };
    const pre_emergence = try calculate(false, 1, concentrations, inhibition, sampleCoefficients());
    try std.testing.expectEqual(@as(f64, 0.5), pre_emergence.carbon);
    try std.testing.expectEqual(@as(f64, 0), pre_emergence.nitrogen);
    try std.testing.expectEqual(@as(f64, 0), pre_emergence.phosphorus);

    var zero_carbon = concentrations;
    zero_carbon.mobile_carbon_g_c_per_g_c = 0;
    const zero = try calculate(true, 0, zero_carbon, inhibition, sampleCoefficients());
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), zero.carbon, 1.0e-15);
    try std.testing.expectEqual(@as(f64, 0), zero.nitrogen);
    try std.testing.expectEqual(@as(f64, 0), zero.phosphorus);
}

test "profile topology and coefficient errors fail explicitly" {
    const concentrations: Concentrations = .{
        .mobile_carbon_g_c_per_g_c = 0.2,
        .mobile_nitrogen_g_n_per_g_c = 0.02,
        .mobile_phosphorus_g_p_per_g_c = 0.002,
    };
    const inhibition: Inhibition = .{
        .nitrogen_g_n_per_g_c = 0.025,
        .phosphorus_g_p_per_g_c = 0.0025,
    };
    var malformed = sampleCoefficients();
    malformed.maximum_phosphorus_fraction = malformed.maximum_phosphorus_fraction[0..3];
    try std.testing.expectError(error.ShootRecyclingProfileDimensionMismatch, calculate(true, 0, concentrations, inhibition, malformed));
    try std.testing.expectError(error.ShootRecyclingProfileIndexOutOfBounds, calculate(true, 4, concentrations, inhibition, sampleCoefficients()));
    var invalid = sampleCoefficients();
    invalid.minimum_carbon_fraction = &.{ 0.9, 0.2, 0.3, 0.4 };
    try std.testing.expectError(error.InvalidShootRecyclingCoefficient, calculate(true, 0, concentrations, inhibition, invalid));
}
