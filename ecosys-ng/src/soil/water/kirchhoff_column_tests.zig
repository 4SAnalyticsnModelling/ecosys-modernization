//! `KIRCH-F5`: a dry layer must be able to rewet.
//!
//! `PR-KIRCHHOFF-DESIGN` section 6. This is the falsifier that states the
//! requirement a user actually cares about, and it is deliberately a *column*
//! test rather than a single-face test: the collapse of section 2 turns a dry
//! layer into an absorbing state, and an absorbing state is only visible when
//! you try to drive water through it.
//!
//! Both schemes are integrated here on the same column with the same forcing,
//! so the test reports a comparison rather than an assertion about one kernel
//! in isolation. Legacy `watsub.f` carried the harmonic mean, so legacy
//! agreement is inadmissible as evidence (`docs/agent_workflow.md:618-632`);
//! this is a new-behaviour test.

const std = @import("std");
const retention = @import("retention.zig");
const kirchhoff = @import("kirchhoff.zig");
const water_flux = @import("flux.zig");

const layer_count = 6;
const layer_thickness_m = 0.10;
const face_area_m2 = 1.0;
const time_fraction = 1.0;

fn columnParameters() retention.MualemVanGenuchtenParameters {
    return .{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.45,
        .alpha_per_m = 3.6,
        .n = 1.56,
        .saturated_hydraulic_conductivity_m_per_h = 0.02,
        .pore_connectivity = 0.5,
    };
}

const Scheme = enum { harmonic, kirchhoff };

/// One hour of vertical Darcy redistribution on a column whose layers hold
/// `water_m3` each, with a fixed infiltration supply into the top layer.
fn stepColumn(
    scheme: Scheme,
    parameters: retention.MualemVanGenuchtenParameters,
    water_m3: *[layer_count]f64,
    infiltration_m3: f64,
) !void {
    const bulk_volume_m3 = layer_thickness_m * face_area_m2;
    const pore_capacity_m3 =
        parameters.saturated_water_content_m3_per_m3 * bulk_volume_m3;
    const gravitational_mpa_per_m = 0.00980665;

    // Supply at the surface, capped by the top layer's air volume.
    water_m3[0] = @min(pore_capacity_m3, water_m3[0] + infiltration_m3);

    var head_m: [layer_count]f64 = undefined;
    var conductivity: [layer_count]f64 = undefined;
    for (0..layer_count) |layer| {
        const fraction = std.math.clamp(
            water_m3[layer] / bulk_volume_m3,
            parameters.residual_water_content_m3_per_m3,
            parameters.saturated_water_content_m3_per_m3,
        );
        head_m[layer] = try parameters.pressureHeadAtWaterContent(fraction);
        conductivity[layer] =
            try parameters.hydraulicConductivityMPerH(head_m[layer]) /
            gravitational_mpa_per_m;
    }

    var delta = [_]f64{0} ** layer_count;
    for (0..layer_count - 1) |upper| {
        const lower = upper + 1;
        const source_conductivity = switch (scheme) {
            .harmonic => conductivity[upper],
            .kirchhoff => try kirchhoff.intervalAveragedConductivityMPerH(
                parameters,
                head_m[upper],
                head_m[lower],
            ) / gravitational_mpa_per_m,
        };
        const destination_conductivity = switch (scheme) {
            .harmonic => conductivity[lower],
            .kirchhoff => try kirchhoff.intervalAveragedConductivityMPerH(
                parameters,
                head_m[lower],
                head_m[upper],
            ) / gravitational_mpa_per_m,
        };
        // Depth increases downward, so the upper cell sits higher and carries
        // the larger gravitational potential.
        const upper_elevation_m =
            -@as(f64, @floatFromInt(upper)) * layer_thickness_m;
        const lower_elevation_m =
            -@as(f64, @floatFromInt(lower)) * layer_thickness_m;
        const flux = try water_flux.calculateMatrixFaceFlux(.{
            .direction = .vertical,
            .source_water_m3 = water_m3[upper],
            .destination_water_m3 = water_m3[lower],
            .source_air_m3 = @max(0.0, pore_capacity_m3 - water_m3[upper]),
            .destination_air_m3 = @max(0.0, pore_capacity_m3 - water_m3[lower]),
            .source_micropore_volume_m3 = bulk_volume_m3,
            .destination_micropore_volume_m3 = bulk_volume_m3,
            .source_water_fraction = water_m3[upper] / bulk_volume_m3,
            .destination_water_fraction = water_m3[lower] / bulk_volume_m3,
            .source_total_water_potential_megapascal = head_m[upper] * gravitational_mpa_per_m +
                upper_elevation_m * gravitational_mpa_per_m,
            .destination_total_water_potential_megapascal = head_m[lower] * gravitational_mpa_per_m +
                lower_elevation_m * gravitational_mpa_per_m,
            .source_hydraulic_conductivity_m2_per_h_megapascal = source_conductivity,
            .destination_hydraulic_conductivity_m2_per_h_megapascal = destination_conductivity,
            .source_path_length_m = layer_thickness_m,
            .destination_path_length_m = layer_thickness_m,
            .face_area_m2 = face_area_m2,
            .time_fraction = time_fraction,
        });
        delta[upper] -= flux.limited_water_m3;
        delta[lower] += flux.limited_water_m3;
    }
    for (0..layer_count) |layer| {
        water_m3[layer] = std.math.clamp(
            water_m3[layer] + delta[layer],
            parameters.residual_water_content_m3_per_m3 * bulk_volume_m3,
            pore_capacity_m3,
        );
    }
}

fn runColumn(scheme: Scheme, hours: usize) ![layer_count]f64 {
    const parameters = columnParameters();
    const bulk_volume_m3 = layer_thickness_m * face_area_m2;
    // Start bone dry everywhere: effective saturation 0.02.
    const initial_fraction = parameters.residual_water_content_m3_per_m3 +
        0.02 * (parameters.saturated_water_content_m3_per_m3 -
            parameters.residual_water_content_m3_per_m3);
    var water_m3 = [_]f64{initial_fraction * bulk_volume_m3} ** layer_count;
    const infiltration_m3 = 0.002 * face_area_m2;
    for (0..hours) |_| {
        try stepColumn(scheme, parameters, &water_m3, infiltration_m3);
    }
    return water_m3;
}

fn effectiveSaturations(water_m3: [layer_count]f64) [layer_count]f64 {
    const parameters = columnParameters();
    const bulk_volume_m3 = layer_thickness_m * face_area_m2;
    var result: [layer_count]f64 = undefined;
    for (0..layer_count) |layer| {
        const fraction = water_m3[layer] / bulk_volume_m3;
        result[layer] = (fraction - parameters.residual_water_content_m3_per_m3) /
            (parameters.saturated_water_content_m3_per_m3 -
                parameters.residual_water_content_m3_per_m3);
    }
    return result;
}

test "KIRCH-F5 a dry column rewets under steady infiltration, and did not before" {
    const hours = 240;
    const harmonic = effectiveSaturations(try runColumn(.harmonic, hours));
    const integrated = effectiveSaturations(try runColumn(.kirchhoff, hours));

    // The falsifier of the old scheme. The bottom of the column is an
    // absorbing dry state under the harmonic mean: ten days of steady
    // infiltration leave it essentially where it started.
    try std.testing.expect(harmonic[layer_count - 1] < 0.05);

    // The requirement. Every layer, including the deepest, has taken up water.
    for (integrated) |saturation| {
        try std.testing.expect(saturation > 0.05);
    }
    try std.testing.expect(
        integrated[layer_count - 1] > harmonic[layer_count - 1] * 2.0,
    );

    // The wetting front is monotone: no layer is wetter than the one above it,
    // which is what a physically advancing front looks like.
    for (1..layer_count) |layer| {
        try std.testing.expect(integrated[layer] <= integrated[layer - 1] + 1.0e-9);
    }
}

test "KIRCH-F6 conservation is unchanged, and is not evidence of the fix" {
    // Stated plainly in the design note: this passes under the defect too. It
    // is a necessary check and a worthless one for discriminating the schemes,
    // recorded here so nobody mistakes a green balance for a validated fix.
    const parameters = columnParameters();
    const bulk_volume_m3 = layer_thickness_m * face_area_m2;
    inline for (.{ Scheme.harmonic, Scheme.kirchhoff }) |scheme| {
        const initial_fraction = parameters.residual_water_content_m3_per_m3 +
            0.30 * (parameters.saturated_water_content_m3_per_m3 -
                parameters.residual_water_content_m3_per_m3);
        var water_m3 = [_]f64{initial_fraction * bulk_volume_m3} ** layer_count;
        var total_before: f64 = 0;
        for (water_m3) |value| total_before += value;
        // No infiltration, so redistribution alone must conserve exactly.
        for (0..24) |_| try stepColumn(scheme, parameters, &water_m3, 0);
        var total_after: f64 = 0;
        for (water_m3) |value| total_after += value;
        try std.testing.expectApproxEqAbs(total_before, total_after, 1.0e-12);
    }
}
