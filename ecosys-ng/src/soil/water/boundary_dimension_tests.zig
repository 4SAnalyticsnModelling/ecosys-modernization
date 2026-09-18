//! `GRID-INV-R3`: dimensional closure of the lateral water boundary.
//!
//! `docs/traceability/grid_dimension_invariance_improvements.md` section 6.
//! Unit-level, no model run. Hold the physical driving potential fixed and
//! scale every *geometric* length in a boundary face by a factor `c`. A
//! gradient-driven flux through an area is
//!
//!     Q = K * (dPsi / L) * A
//!
//! so with `A ~ c^2` and `L ~ c` it must scale by exactly `c`. A kernel that
//! multiplies by area and never divides by a length yields `c^2`, and one that
//! also carries a width-proportional slope potential yields `c^3`. Both wrong
//! powers are measured here directly.
//!
//! The scaling fixtures set `slope_sine = 0` deliberately. The gravity term is
//! a topographic gradient that is already dimensionless and therefore does not
//! respond to the separation distance at all, so a face carrying both terms has
//! no single scale exponent even when the kernel is correct: it interpolates
//! between the two. Leaving slope on here would have measured that mixture,
//! about 1.6, and reported a correct kernel as a failure. The head-driven term
//! is isolated here and the slope term is pinned separately by `GRID-INV-R3c`,
//! which is the property the mixed measurement would otherwise have obscured.
//!
//! Legacy `watsub.f` carries the same defect and absorbed it into site
//! calibration of `recharge_frequency_divisor`, so legacy agreement is
//! inadmissible evidence (`docs/agent_workflow.md:623-624`). These are
//! new-behaviour tests.
//!
//! Mass conservation cannot substitute for any of this: the boundary flux is a
//! single scalar booked equal-and-opposite against the external reservoir, so
//! the daily audit reads identically whether the face area is right or wrong.

const std = @import("std");
const water_boundary = @import("boundary.zig");

/// The scale exponent of `flux` under geometric scaling, `log(Q(c)/Q(1))/log(c)`.
fn observedExponent(flux_at_one: f64, flux_at_c: f64, c: f64) f64 {
    return @log(@abs(flux_at_c) / @abs(flux_at_one)) / @log(c);
}

fn matrixDischargeAtScale(c: f64) !f64 {
    // Lengths that describe the *grid* scale with `c`. Depths and potentials
    // describe the *physics* and are held fixed, which is what makes the
    // expected exponent 1 rather than 2.
    const flux = try water_boundary.matrixDischarge(.{
        .direction_sign = 1,
        .slope_sine = 0.0,
        .directional_layer_width_m = 1.0 * c,
        .water_table_slope = 0.0,
        .matric_potential_megapascal = -0.002,
        .saturation_water_potential_megapascal = -0.0005,
        .layer_midpoint_depth_m = 0.5,
        .external_water_table_depth_m = 2.0,
        .internal_water_table_depth_m = 3.0,
        .hydraulic_conductivity_m2_per_h_megapascal = 0.5,
        // A vertical cross-section, thickness x width, so it carries c^2 only
        // if both in-plane lengths scale. Thickness is a grid length too.
        .face_area_m2 = 0.1 * c * 1.0 * c,
        .external_separation_distance_m = 10.0 * c,
        .fraction_face_below_water_table = 0.0,
        .recharge_frequency_divisor = 0.0,
        .recharge_time_multiplier = 1.0,
        .time_fraction = 1.0,
        .source_temperature_k = 285.0,
    }, false);
    return flux.matrix_water_m3;
}

fn rechargeAtScale(c: f64) !f64 {
    const flux = try water_boundary.recharge(.{
        .direction_sign = 1,
        .slope_sine = 0.0,
        .directional_layer_width_m = 1.0 * c,
        .water_table_slope = 0.0,
        .matric_potential_megapascal = -0.002,
        .layer_or_macropore_water_depth_m = 3.0,
        .external_water_table_depth_m = 2.0,
        .hydraulic_conductivity_m2_per_h_megapascal = 0.5,
        .face_area_m2 = 0.1 * c * 1.0 * c,
        .external_separation_distance_m = 10.0 * c,
        .fraction_face_below_water_table = 1.0,
        .recharge_frequency_divisor = 1.0,
        .recharge_time_multiplier = 1.0,
        .time_fraction = 1.0,
        // Large enough that the donor bound never binds and we measure the
        // kernel rather than the clamp.
        .available_air_volume_m3 = 1.0e9,
        .source_temperature_k = 285.0,
    }, false);
    return flux.matrix_water_m3;
}

fn macroporeDischargeAtScale(c: f64) !f64 {
    const flux = try water_boundary.macroporeDischarge(.{
        .direction_sign = 1,
        .slope_sine = 0.0,
        .directional_layer_width_m = 1.0 * c,
        .water_table_slope = 0.0,
        .macropore_water_depth_m = 0.5,
        .external_water_table_depth_m = 2.0,
        .internal_water_table_depth_m = 3.0,
        .hydraulic_conductivity_m2_per_h_megapascal = 0.5,
        .face_area_m2 = 0.1 * c * 1.0 * c,
        .external_separation_distance_m = 10.0 * c,
        .fraction_face_below_water_table = 0.0,
        .recharge_frequency_divisor = 1.0,
        .recharge_time_multiplier = 1.0,
        .time_fraction = 1.0,
        .available_macropore_water_m3 = 1.0e9,
        .incoming_vertical_macropore_water_m3 = 0,
        .outgoing_vertical_macropore_water_m3 = 0,
        .source_temperature_k = 285.0,
    });
    return flux.macropore_water_m3;
}

test "GRID-INV-R3 lateral boundary discharge scales as the first power of cell size" {
    const c = 100.0;
    inline for (.{
        .{ "matrix", matrixDischargeAtScale },
        .{ "recharge", rechargeAtScale },
        .{ "macropore", macroporeDischargeAtScale },
    }) |entry| {
        const at_one = try entry[1](1.0);
        const at_c = try entry[1](c);
        try std.testing.expect(@abs(at_one) > 0);
        const exponent = observedExponent(at_one, at_c, c);
        // Exactly 1. Before `PR-GRID-INV-001` the head-driven part measured 2
        // and the slope-driven part 3, so this bound of 1e-9 is far tighter
        // than any plausible near-miss and cannot be satisfied by accident.
        std.testing.expectApproxEqAbs(@as(f64, 1.0), exponent, 1.0e-9) catch |err| {
            std.debug.print(
                "GRID-INV-R3 {s}: observed exponent {d} (want 1)\n",
                .{ entry[0], exponent },
            );
            return err;
        };
    }
}

test "GRID-INV-R3b halving the separation distance doubles the boundary flux" {
    // The direct statement that the kernel now computes a gradient: the flux
    // is inversely proportional to the distance to the external water table.
    // Under the defect this factor was absent entirely, so the flux did not
    // respond to the separation distance at all.
    const near = try water_boundary.matrixDischarge(.{
        .direction_sign = 1,
        .slope_sine = 0.0,
        .directional_layer_width_m = 1.0,
        .water_table_slope = 0.0,
        .matric_potential_megapascal = -0.002,
        .saturation_water_potential_megapascal = -0.0005,
        .layer_midpoint_depth_m = 0.5,
        .external_water_table_depth_m = 2.0,
        .internal_water_table_depth_m = 3.0,
        .hydraulic_conductivity_m2_per_h_megapascal = 0.5,
        .face_area_m2 = 0.1,
        .external_separation_distance_m = 5.0,
        .fraction_face_below_water_table = 0.0,
        .recharge_frequency_divisor = 0.0,
        .recharge_time_multiplier = 1.0,
        .time_fraction = 1.0,
        .source_temperature_k = 285.0,
    }, false);
    var far_inputs = water_boundary.WaterTableDischargeInputs{
        .direction_sign = 1,
        .slope_sine = 0.0,
        .directional_layer_width_m = 1.0,
        .water_table_slope = 0.0,
        .matric_potential_megapascal = -0.002,
        .saturation_water_potential_megapascal = -0.0005,
        .layer_midpoint_depth_m = 0.5,
        .external_water_table_depth_m = 2.0,
        .internal_water_table_depth_m = 3.0,
        .hydraulic_conductivity_m2_per_h_megapascal = 0.5,
        .face_area_m2 = 0.1,
        .external_separation_distance_m = 10.0,
        .fraction_face_below_water_table = 0.0,
        .recharge_frequency_divisor = 0.0,
        .recharge_time_multiplier = 1.0,
        .time_fraction = 1.0,
        .source_temperature_k = 285.0,
    };
    const far = try water_boundary.matrixDischarge(far_inputs, false);
    try std.testing.expectApproxEqRel(
        2.0,
        near.matrix_water_m3 / far.matrix_water_m3,
        1.0e-12,
    );

    // And a face with no stated separation is not a physical face: there is no
    // gradient to compute, so the kernel must refuse rather than silently
    // fall back to a bare potential difference.
    far_inputs.external_separation_distance_m = 0;
    try std.testing.expectError(
        error.InvalidSoilWaterBoundaryInput,
        water_boundary.matrixDischarge(far_inputs, false),
    );
}

test "GRID-INV-R3c the slope term is a pure gradient, independent of cell width" {
    // GRID-INV-002. The slope contribution used to be multiplied by
    // `directional_layer_width_m`, so one expression carried two different
    // powers of cell width and no single rescaling could make it invariant.
    // `slope_sine` is dimensionless and now contributes as a gradient.
    var inputs = water_boundary.WaterTableDischargeInputs{
        .direction_sign = 1,
        .slope_sine = 0.05,
        .directional_layer_width_m = 1.0,
        .water_table_slope = 0.0,
        .matric_potential_megapascal = -0.002,
        .saturation_water_potential_megapascal = -0.0005,
        .layer_midpoint_depth_m = 0.5,
        .external_water_table_depth_m = 2.0,
        .internal_water_table_depth_m = 3.0,
        .hydraulic_conductivity_m2_per_h_megapascal = 0.5,
        .face_area_m2 = 0.1,
        .external_separation_distance_m = 10.0,
        .fraction_face_below_water_table = 0.0,
        .recharge_frequency_divisor = 0.0,
        .recharge_time_multiplier = 1.0,
        .time_fraction = 1.0,
        .source_temperature_k = 285.0,
    };
    const narrow = try water_boundary.matrixDischarge(inputs, false);
    inputs.directional_layer_width_m = 250.0;
    const wide = try water_boundary.matrixDischarge(inputs, false);
    try std.testing.expectEqual(narrow.matrix_water_m3, wide.matrix_water_m3);

    // Still present and still signed: a downhill slope drives more discharge.
    inputs.directional_layer_width_m = 1.0;
    inputs.slope_sine = 0.0;
    const level = try water_boundary.matrixDischarge(inputs, false);
    try std.testing.expect(@abs(narrow.matrix_water_m3) > @abs(level.matrix_water_m3));
}
