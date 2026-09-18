// **A8a DISPOSITION: NOT A BINDING CANDIDATE. This file is a test sidecar.**
//
// Unbound by construction and correctly so. It is reached by the standard Zig
// refer-block idiom at `soil_water_retention_validation.zig:873`, which is the
// only mechanism that pulls tests into analysis; a plain `@import` would not.
// Do not delete it and do not remove that refer line: dropping a `_ =` line
// silently removes tests with no signal from the test count.
//
// It exists separately so the module beside it carries only model code. Tests
// that reach a private declaration of that module must stay in that file, since
// a sibling can only see `pub` declarations.
//
// VALIDATION-EVIDENCE group of docs/traceability/a8a_validation_dispositions.md
//! Tests for `soil_water_retention_validation.zig`.
//!
//! Extracted so the module beside it carries only model code. Tests
//! that reach a private declaration of that module stay there, since a
//! sibling file can only see `pub` declarations.

const std = @import("std");
const retention = @import("../soil/water/retention.zig");
const retention_validation = @import("soil_water_retention_validation.zig");

test "tier 1: nonphysical retention parameters and inputs are rejected, not clamped" {
    var parameters = try retention.carselParrishDefault(.loam, null);
    try std.testing.expectError(
        error.NonFinitePressureHead,
        parameters.waterCapacityPerM(std.math.nan(f64)),
    );
    try std.testing.expectError(
        error.WaterContentOutsideRetentionDomain,
        parameters.pressureHeadAtWaterContent(
            parameters.saturated_water_content_m3_per_m3 + 1.0e-6,
        ),
    );
    parameters.n = 1.0;
    try std.testing.expectError(
        error.InvalidMualemVanGenuchtenParameter,
        parameters.effectiveSaturationAtPressureHead(-1.0),
    );
}

test "tier 3: n = 2 closed-form retention and Mualem conductivity are reproduced" {
    // For n = 2, m = 1/2, the van Genuchten retention and the Mualem integral
    // both collapse to elementary algebraic expressions.
    const parameters: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.45,
        .alpha_per_m = 2.0,
        .n = 2.0,
        .saturated_hydraulic_conductivity_m_per_h = 0.02,
    };
    try std.testing.expectApproxEqRel(@as(f64, 0.5), parameters.m(), 1.0e-15);
    const heads_m = [_]f64{ -0.05, -0.25, -1.0, -3.0, -20.0 };
    for (heads_m) |head_m| {
        const scaled = parameters.alpha_per_m * -head_m;
        const analytic_saturation = 1.0 / @sqrt(1.0 + scaled * scaled);
        const saturation =
            try parameters.effectiveSaturationAtPressureHead(head_m);
        try std.testing.expectApproxEqRel(analytic_saturation, saturation, 1.0e-13);

        // Mualem with m = 1/2:
        //   Kr = Se^(1/2) * (1 - (1 - Se^2)^(1/2))^2
        const analytic_relative_conductivity = @sqrt(analytic_saturation) *
            std.math.pow(
                f64,
                1.0 - @sqrt(1.0 - analytic_saturation * analytic_saturation),
                2.0,
            );
        const relative_conductivity =
            try parameters.relativeHydraulicConductivityAtEffectiveSaturation(saturation);
        try std.testing.expectApproxEqRel(
            analytic_relative_conductivity,
            relative_conductivity,
            1.0e-12,
        );

        // dtheta/dh in closed form for n = 2:
        //   C = (theta_s - theta_r) * alpha^2 * |h| * (1 + (alpha h)^2)^(-3/2)
        const analytic_capacity =
            (parameters.saturated_water_content_m3_per_m3 -
                parameters.residual_water_content_m3_per_m3) *
            parameters.alpha_per_m * parameters.alpha_per_m * -head_m *
            std.math.pow(f64, 1.0 + scaled * scaled, -1.5);
        try std.testing.expectApproxEqRel(
            analytic_capacity,
            try parameters.waterCapacityPerM(head_m),
            1.0e-12,
        );
    }
}

test "legacy log-log retention has a discontinuous water capacity at both joints" {
    const parameters = retention.compatibilityParameters();
    const resolved = try retention.resolve(parameters, .{
        .porosity_fraction = 0.5,
        .macropore_fraction = 0,
        .sand_fraction = 0.4,
        .clay_fraction = 0.2,
        .organic_carbon_g_per_megagram = 10_000,
        .bulk_density_megagrams_per_m3 = 1.3,
        .supplied_field_capacity_fraction = null,
        .supplied_wilting_point_fraction = null,
    }, -0.033, -1.5);

    // Sanity: the analytic derivative agrees with a central difference taken
    // strictly inside one branch, so the jumps measured below are properties of
    // the formulation and not of this derivative.
    const interior = 0.5 * (resolved.curve.wilting_point_fraction +
        resolved.curve.field_capacity_fraction);
    const step = 1.0e-7;
    const difference =
        (try resolved.waterPotentialMpa(interior + step) -
            try resolved.waterPotentialMpa(interior - step)) / (2 * step);
    const analytic = try retention_validation.legacyPotentialDerivativeMpaPerVolumeFraction(
        resolved,
        interior,
        .wetter,
    );
    try std.testing.expectApproxEqRel(difference, analytic, 1.0e-5);

    // At the wilting point the only difference between the two branches is the
    // HCN shape factor `below_wilting_shape`, which multiplies the log-log
    // slope on the drier side only. The drier slope is therefore exactly
    // `below_wilting_shape` times the wetter slope, so the reported relative
    // discontinuity is `1 - below_wilting_shape`.
    const wilting_jump = try retention_validation.legacyJointSlopeDiscontinuity(
        resolved,
        resolved.curve.wilting_point_fraction,
    );
    try std.testing.expectApproxEqRel(
        1.0 - parameters.below_wilting_shape,
        wilting_jump,
        1.0e-12,
    );
    // Half the capacity is lost across a single point of the state space.
    try std.testing.expect(wilting_jump > 0.4);

    // At field capacity the saturation-to-field branch meets the field-to-
    // wilting branch with an entirely unrelated slope.
    const field_jump = try retention_validation.legacyJointSlopeDiscontinuity(
        resolved,
        resolved.curve.field_capacity_fraction,
    );
    // Smaller than the wilting-point jump for this texture (7.5% versus 50%)
    // but still a genuine discontinuity, and it sits at field capacity, which
    // is the water content a drained profile spends most of its time near.
    try std.testing.expect(field_jump > 0.05);
}
