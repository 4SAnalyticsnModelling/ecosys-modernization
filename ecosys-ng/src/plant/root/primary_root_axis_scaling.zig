const std = @import("std");

pub const State = struct {
    retained_root_carbon_g_c_per_plant: f64,
};

pub const Inputs = struct {
    total_root_carbon_g_c: f64,
    plant_population: f64,
    biological_timestep_h: f64,
    hourly_retention_fraction: f64,
    axis_scaling_exponent: f64,
};

pub const Result = struct {
    primary_root_axis_count_multiplier: f64,
};

/// Exact GROSUB lines 506--512 WTRTA/XRTN1 recurrence.
///
/// WTRTA is retained root carbon per plant (g C plant-1). The source directly
/// multiplies its hourly retention fraction by XNFH; it does not exponentiate
/// the retention fraction by the timestep.
pub fn advance(state: *State, inputs: Inputs) !Result {
    inline for (.{
        state.retained_root_carbon_g_c_per_plant,
        inputs.total_root_carbon_g_c,
        inputs.plant_population,
        inputs.biological_timestep_h,
        inputs.hourly_retention_fraction,
        inputs.axis_scaling_exponent,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidPrimaryRootAxisScalingInput;
    if (inputs.biological_timestep_h == 0 or
        inputs.hourly_retention_fraction > 1 or
        inputs.axis_scaling_exponent == 0)
        return error.InvalidPrimaryRootAxisScalingInput;

    const retained = if (inputs.plant_population > 0)
        @max(
            inputs.hourly_retention_fraction *
                state.retained_root_carbon_g_c_per_plant *
                inputs.biological_timestep_h,
            inputs.total_root_carbon_g_c / inputs.plant_population,
        )
    else
        0;
    const multiplier = @max(
        @as(f64, 1),
        std.math.pow(f64, retained, inputs.axis_scaling_exponent),
    ) * inputs.plant_population;
    if (!std.math.isFinite(retained) or !std.math.isFinite(multiplier))
        return error.PrimaryRootAxisScalingOverflow;

    state.retained_root_carbon_g_c_per_plant = retained;
    return .{ .primary_root_axis_count_multiplier = multiplier };
}

test "GROSUB retained root carbon uses exact recurrence ordering" {
    var state: State = .{ .retained_root_carbon_g_c_per_plant = 8 };
    const result = try advance(&state, .{
        .total_root_carbon_g_c = 6,
        .plant_population = 2,
        .biological_timestep_h = 0.5,
        .hourly_retention_fraction = 0.999992087,
        .axis_scaling_exponent = 0.667,
    });
    const expected_retained = 0.999992087 * 8 * 0.5;
    try std.testing.expectEqual(expected_retained, state.retained_root_carbon_g_c_per_plant);
    try std.testing.expectApproxEqAbs(
        std.math.pow(f64, expected_retained, 0.667) * 2,
        result.primary_root_axis_count_multiplier,
        1.0e-12,
    );
}

test "current root carbon per plant supplies the larger source branch" {
    var state: State = .{ .retained_root_carbon_g_c_per_plant = 1 };
    const result = try advance(&state, .{
        .total_root_carbon_g_c = 20,
        .plant_population = 4,
        .biological_timestep_h = 1,
        .hourly_retention_fraction = 0.999992087,
        .axis_scaling_exponent = 0.667,
    });
    try std.testing.expectEqual(@as(f64, 5), state.retained_root_carbon_g_c_per_plant);
    try std.testing.expectApproxEqAbs(
        std.math.pow(f64, @as(f64, 5), 0.667) * 4,
        result.primary_root_axis_count_multiplier,
        1.0e-12,
    );
}

test "zero population clears retained mass and publishes zero axes" {
    var state: State = .{ .retained_root_carbon_g_c_per_plant = 7 };
    const result = try advance(&state, .{
        .total_root_carbon_g_c = 9,
        .plant_population = 0,
        .biological_timestep_h = 1,
        .hourly_retention_fraction = 0.999992087,
        .axis_scaling_exponent = 0.667,
    });
    try std.testing.expectEqual(@as(f64, 0), state.retained_root_carbon_g_c_per_plant);
    try std.testing.expectEqual(@as(f64, 0), result.primary_root_axis_count_multiplier);
}

test "invalid input leaves retained root state unchanged" {
    var state: State = .{ .retained_root_carbon_g_c_per_plant = 7 };
    try std.testing.expectError(
        error.InvalidPrimaryRootAxisScalingInput,
        advance(&state, .{
            .total_root_carbon_g_c = std.math.nan(f64),
            .plant_population = 2,
            .biological_timestep_h = 1,
            .hourly_retention_fraction = 0.999992087,
            .axis_scaling_exponent = 0.667,
        }),
    );
    try std.testing.expectEqual(@as(f64, 7), state.retained_root_carbon_g_c_per_plant);
}

test "zero timestep and scaling exponent fail before mutation" {
    inline for (.{
        Inputs{ .total_root_carbon_g_c = 1, .plant_population = 1, .biological_timestep_h = 0, .hourly_retention_fraction = 0.999992087, .axis_scaling_exponent = 0.667 },
        Inputs{ .total_root_carbon_g_c = 1, .plant_population = 1, .biological_timestep_h = 1, .hourly_retention_fraction = 0.999992087, .axis_scaling_exponent = 0 },
    }) |inputs| {
        var state: State = .{ .retained_root_carbon_g_c_per_plant = 7 };
        try std.testing.expectError(error.InvalidPrimaryRootAxisScalingInput, advance(&state, inputs));
        try std.testing.expectEqual(@as(f64, 7), state.retained_root_carbon_g_c_per_plant);
    }
}

test "BIND-GROSUB-506 XRTN1 departs from the constant 1 production substituted for it" {
    // Discriminating test for the defect this kernel's binding corrects.
    // `ecosys_ng.zig` read `@max(1, roots.axis_primary_count[axis_layer])`,
    // which is the source's per-layer `RTN1` and has no production writer, so
    // the multiplier was identically `1`. This pins how far the source's own
    // `XRTN1` is from that constant for a stand that is merely ordinary, not
    // extreme, so the defect cannot be dismissed as a rounding term.
    var state: State = .{ .retained_root_carbon_g_c_per_plant = 0 };
    const result = try advance(&state, .{
        // 10 plants holding 1 g C of root carbon each.
        .total_root_carbon_g_c = 10,
        .plant_population = 10,
        .biological_timestep_h = 1,
        .hourly_retention_fraction = 0.999992087,
        .axis_scaling_exponent = 0.667,
    });
    // `WTRT/PP = 1`, so `AMAX1(1, 1**0.667) * 10 == 10`.
    try std.testing.expectEqual(@as(f64, 1), state.retained_root_carbon_g_c_per_plant);
    try std.testing.expectApproxEqAbs(@as(f64, 10), result.primary_root_axis_count_multiplier, 1.0e-12);
    // An order of magnitude above the constant production used, and the gap
    // widens with population and with root mass, so it grows through a season
    // rather than averaging out.
    try std.testing.expect(result.primary_root_axis_count_multiplier >= 10 * 1.0);

    // Same population, ten times the root mass: the multiplier scales as
    // `WTRTA**0.667`, which the constant `1` cannot represent at all.
    var heavier: State = .{ .retained_root_carbon_g_c_per_plant = 0 };
    const heavy = try advance(&heavier, .{
        .total_root_carbon_g_c = 100,
        .plant_population = 10,
        .biological_timestep_h = 1,
        .hourly_retention_fraction = 0.999992087,
        .axis_scaling_exponent = 0.667,
    });
    try std.testing.expectApproxEqAbs(
        std.math.pow(f64, @as(f64, 10), 0.667) * 10,
        heavy.primary_root_axis_count_multiplier,
        1.0e-12,
    );
    try std.testing.expect(heavy.primary_root_axis_count_multiplier >
        result.primary_root_axis_count_multiplier);
}

test "BIND-GROSUB-506 the multiplier renormalizes rather than creating root sink" {
    // Tier-2 conservation evidence A2's request asks for, stated as the
    // invariant rather than as a legacy comparison (production's prior
    // behaviour is wrong, so agreeing with it would prove only that the bug was
    // reproduced). `normalizeRootAxisSinkFractions` divides every axis strength
    // by their sum, so scaling `XRTN1` REDISTRIBUTES the carbon draw across
    // axes and cannot manufacture or destroy any: the fractions still sum to
    // one. This test proves that property holds across a multiplier change of
    // an order of magnitude, which is the size of the correction.
    const metabolism = @import("plant_root_metabolism.zig");
    const parameters = metabolism.compatibilitySecondaryRootParameters();
    inline for (.{ @as(f64, 1), @as(f64, 10), @as(f64, 46.7) }) |multiplier| {
        var strengths: [3]metabolism.RootAxisSinkStrength = undefined;
        for (&strengths, 0..) |*strength, axis| {
            strength.* = try metabolism.sourceOrderRootAxisSinkStrength(parameters, .{
                .root_profile_type = 2,
                .primary_axis_count_multiplier = multiplier,
                .primary_root_radius_m = 1.0e-3,
                .primary_root_depth_from_surface_m = 0.15 + 0.01 * @as(f64, @floatFromInt(axis)),
                .layer_top_depth_m = 0.1,
                .layer_thickness_m = 0.1,
                .secondary_root_origin_offset_m = 0,
                .seeding_depth_m = 0.05,
                .hypocotyledon_height_m = 0.02,
                .canopy_height_m = 0.3,
                .secondary_axis_count = 4,
                .secondary_root_radius_m = 5.0e-4,
                .average_secondary_root_length_m = 0.05,
                .negligible_sink_m = 1.0e-15,
                .primary_biological_domain = true,
            });
        }
        var primary_fractions: [3]f64 = undefined;
        var secondary_fractions: [3]f64 = undefined;
        const total = try metabolism.normalizeRootAxisSinkFractions(
            &strengths,
            &primary_fractions,
            &secondary_fractions,
            1.0e-15,
        );
        try std.testing.expect(total > 0);
        var sum: f64 = 0;
        for (primary_fractions, secondary_fractions) |primary, secondary| {
            try std.testing.expect(primary >= 0 and secondary >= 0);
            sum += primary + secondary;
        }
        // Closes to one at every multiplier, which is the conservation claim.
        try std.testing.expectApproxEqAbs(@as(f64, 1), sum, 1.0e-12);
    }
}
