//! Tests for `plant_root_disturbance.zig`.
//!
//! Extracted so the module beside it carries only model code. Tests
//! that reach a private declaration of that module stay there, since a
//! sibling file can only see `pub` declarations.

const std = @import("std");
const Symbiosis = @import("../../canopy/symbiosis/plant_symbiotic_fixation.zig");
const LitterPartition = @import("../partition/litter.zig");
const RootMetabolism = @import("plant_root_metabolism.zig");
const RootSystem = @import("plant_root_system.zig");
const disturbance = @import("plant_root_disturbance.zig");

test "GROSUB nodule harvest requires fixation and first biological domain" {
    try std.testing.expect(try disturbance.sourceOrderNoduleHarvestIsEnabled(1, 0, 2));
    try std.testing.expect(!(try disturbance.sourceOrderNoduleHarvestIsEnabled(0, 0, 2)));
    try std.testing.expect(!(try disturbance.sourceOrderNoduleHarvestIsEnabled(1, 1, 2)));
    try std.testing.expectError(
        error.InvalidNoduleHarvestDomain,
        disturbance.sourceOrderNoduleHarvestIsEnabled(1, 2, 2),
    );
}

test "GROSUB root harvest scales complete axis and layer state" {
    const axis = disturbance.HostAxisHarvestState{
        .primary = .{ .carbon_g_c = 8, .nitrogen_g_n = 4, .phosphorus_g_p = 2 },
        .secondary = .{ .carbon_g_c = 6, .nitrogen_g_n = 3, .phosphorus_g_p = 1 },
        .total_primary = .{ .carbon_g_c = 10, .nitrogen_g_n = 5, .phosphorus_g_p = 2.5 },
        .primary_length_m = 12,
        .secondary_length_m = 20,
        .secondary_axis_count = 4,
    };
    const layer = disturbance.HostLayerHarvestState{
        .mobile = .{ .carbon_g_c = 4, .nitrogen_g_n = 2, .phosphorus_g_p = 1 },
        .active_root_carbon_g_c = 14,
        .actual_root_carbon_g_c = 18,
        .protein_mass_g = 3,
        .primary_axis_count = 2,
        .total_root_axis_count = 6,
        .root_length_m_per_plant = 16,
        .root_length_density_m_per_m3 = 32,
        .gaseous_volume_m3 = 0.4,
        .aqueous_volume_m3 = 0.6,
        .root_surface_area_m2_per_plant = 5,
        .respiration_unlimited_by_oxygen_g_c_per_h = 0.8,
        .respiration_unlimited_by_carbon_g_c_per_h = 0.6,
        .actual_respiration_g_c_per_h = 0.4,
    };
    const scaled = try disturbance.sourceOrderScaleHostHarvestState(axis, layer, .{
        .carbon = 0.5,
        .nitrogen = 0.25,
        .phosphorus = 0.8,
    });
    try std.testing.expectEqual(@as(f64, 4), scaled.axis.primary.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 1), scaled.axis.primary.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 1.6), scaled.axis.primary.phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 2.5), scaled.axis.total_primary.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 6), scaled.axis.primary_length_m);
    try std.testing.expectEqual(@as(f64, 0.3), scaled.layer.aqueous_volume_m3);
    try std.testing.expectEqual(@as(f64, 0.2), scaled.layer.actual_respiration_g_c_per_h);
    try std.testing.expectEqual(@as(f64, 0.8), scaled.layer.mobile.phosphorus_g_p);
}

test "GROSUB tillage scales complete root mass geometry and respiration state" {
    const axis: disturbance.HostAxisHarvestState = .{
        .primary = .{ .carbon_g_c = 8, .nitrogen_g_n = 4, .phosphorus_g_p = 2 },
        .secondary = .{ .carbon_g_c = 12, .nitrogen_g_n = 6, .phosphorus_g_p = 3 },
        .total_primary = .{ .carbon_g_c = 16, .nitrogen_g_n = 8, .phosphorus_g_p = 4 },
        .primary_length_m = 20,
        .secondary_length_m = 24,
        .secondary_axis_count = 4,
    };
    const layer: disturbance.HostLayerHarvestState = .{
        .mobile = .{ .carbon_g_c = 8, .nitrogen_g_n = 4, .phosphorus_g_p = 2 },
        .active_root_carbon_g_c = 12,
        .actual_root_carbon_g_c = 16,
        .protein_mass_g = 20,
        .primary_axis_count = 4,
        .total_root_axis_count = 8,
        .root_length_m_per_plant = 24,
        .root_length_density_m_per_m3 = 28,
        .gaseous_volume_m3 = 0.8,
        .aqueous_volume_m3 = 1.2,
        .root_surface_area_m2_per_plant = 16,
        .respiration_unlimited_by_oxygen_g_c_per_h = 2,
        .respiration_unlimited_by_carbon_g_c_per_h = 1.6,
        .actual_respiration_g_c_per_h = 1.2,
    };
    const scaled = try disturbance.sourceOrderScaleHostTillageState(axis, layer, 0.25);
    try std.testing.expectEqual(@as(f64, 2), scaled.axis.primary.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 1), scaled.axis.primary.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 1), scaled.axis.secondary_axis_count);
    try std.testing.expectEqual(@as(f64, 2), scaled.layer.mobile.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 7), scaled.layer.root_length_density_m_per_m3);
    try std.testing.expectEqual(@as(f64, 0.2), scaled.layer.gaseous_volume_m3);
    try std.testing.expectEqual(@as(f64, 4), scaled.layer.root_surface_area_m2_per_plant);
    try std.testing.expectEqual(@as(f64, 0.3), scaled.layer.actual_respiration_g_c_per_h);
}

test "root nodule combustion preserves separate mobile and structural fractions" {
    const result = try disturbance.combustSymbiont(
        .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 },
        .{ .carbon_g_c = 4, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.08 },
        0.25,
        0.5,
    );
    try std.testing.expectApproxEqAbs(7.5, result.structural.carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(2, result.mobile.carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(4.5, result.emitted.carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(14, result.structural.carbon_g_c + result.mobile.carbon_g_c + result.emitted.carbon_g_c, 1e-14);
}

test "root nodule combustion fraction preserves TCMBX and source Arrhenius equation" {
    const parameters = disturbance.sourceCombustionParameters();
    try std.testing.expectEqual(@as(f64, 0), try disturbance.combustionFraction(10, 473.15, 1, 1, 1_000, parameters));
    const fraction = try disturbance.combustionFraction(10_000, 600, 1, 1, 1_000, parameters);
    const expected = @min(1, 1_000.0 * @min(2, @exp(12.028 - 60_000.0 / (8.3143 * 600.0))) / 10_000.0);
    try std.testing.expectApproxEqAbs(expected, fraction, 1e-15);
}

test "withdrawing root layer conservatively transfers all rhizobial pools" {
    var roots = try RootSystem.State.init(std.testing.allocator, 1, 3, 1);
    defer roots.deinit();
    const source = try roots.layerIndex(0, 0, 2);
    const destination = try roots.layerIndex(0, 0, 1);
    roots.symbiont_structural_carbon_g_c[source] = 8;
    roots.symbiont_structural_nitrogen_g_n[source] = 0.8;
    roots.symbiont_structural_phosphorus_g_p[source] = 0.08;
    roots.symbiont_mobile_carbon_g_c[source] = 4;
    roots.symbiont_mobile_nitrogen_g_n[source] = 0.4;
    roots.symbiont_mobile_phosphorus_g_p[source] = 0.04;
    roots.symbiont_structural_carbon_g_c[destination] = 2;
    try disturbance.transferSymbiontLayerFraction(&roots, 0, 2, 1, 0.25);
    try std.testing.expectApproxEqAbs(6, roots.symbiont_structural_carbon_g_c[source], 1e-14);
    try std.testing.expectApproxEqAbs(4, roots.symbiont_structural_carbon_g_c[destination], 1e-14);
    try std.testing.expectApproxEqAbs(0.3, roots.symbiont_mobile_nitrogen_g_n[source], 1e-14);
    try std.testing.expectApproxEqAbs(0.1, roots.symbiont_mobile_nitrogen_g_n[destination], 1e-14);
}

test "GROSUB root withdrawal preserves RTLG2 and moves RTNL independently from RTN2" {
    var roots = try RootSystem.State.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    const source_axis = try roots.layerAxisIndex(0, 0, 1, 0);
    const destination_axis = try roots.layerAxisIndex(0, 0, 0, 0);
    const source_root = try roots.layerIndex(0, 0, 1);
    const destination_root = try roots.layerIndex(0, 0, 0);
    roots.axis_primary_carbon_g[source_axis] = 3;
    roots.axis_secondary_carbon_g[source_axis] = 2;
    roots.axis_primary_length_m[source_axis] = 0.4;
    roots.axis_secondary_length_m[source_axis] = 0.8;
    roots.axis_secondary_length_m[destination_axis] = 0.2;
    roots.axis_primary_carbon_g[destination_axis] = 1;
    roots.axis_primary_count[source_axis] = 1;
    roots.axis_secondary_count[source_axis] = 4;
    roots.secondary_axis_count_total[source_root] = 4;
    roots.axis_depth_m[try roots.axisIndex(0, 0, 0)] = 0.3;
    roots.mobile_carbon_g[source_root] = 8;
    roots.mobile_carbon_g[destination_root] = 2;
    roots.symbiont_mobile_carbon_g_c[source_root] = 4;
    roots.gaseous_carbon_dioxide_g_c[source_root] = 3;
    roots.aqueous_carbon_dioxide_g_c[source_root] = 1;
    try disturbance.withdrawRootAxisLayer(&roots, 0, 0, 1, 1, 0, 0.25, 0.1, &.{ 0.5, 0.5 }, &.{ 0.5, 1.0 });
    try std.testing.expectEqual(@as(f64, 0), roots.axis_primary_carbon_g[source_axis]);
    try std.testing.expectEqual(@as(f64, 4), roots.axis_primary_carbon_g[destination_axis]);
    try std.testing.expectEqual(@as(f64, 2), roots.axis_secondary_carbon_g[destination_axis]);
    try std.testing.expectEqual(@as(f64, 0), roots.axis_primary_count[source_axis]);
    try std.testing.expectEqual(@as(f64, 0), roots.axis_primary_count[destination_axis]);
    try std.testing.expectEqual(@as(f64, 0), roots.axis_secondary_count[source_axis]);
    try std.testing.expectEqual(@as(f64, 0), roots.axis_secondary_count[destination_axis]);
    try std.testing.expectEqual(@as(f64, 0), roots.secondary_axis_count_total[source_root]);
    try std.testing.expectEqual(@as(f64, 4), roots.secondary_axis_count_total[destination_root]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), roots.axis_primary_length_m[destination_axis], 1e-14);
    try std.testing.expectEqual(@as(f64, 0.8), roots.axis_secondary_length_m[source_axis]);
    try std.testing.expectEqual(@as(f64, 0.2), roots.axis_secondary_length_m[destination_axis]);
    try std.testing.expectEqual(@as(f64, 6), roots.mobile_carbon_g[source_root]);
    try std.testing.expectEqual(@as(f64, 4), roots.mobile_carbon_g[destination_root]);
    try std.testing.expectEqual(@as(f64, 1), roots.symbiont_mobile_carbon_g_c[destination_root]);
    try std.testing.expectEqual(@as(f64, 2.25), roots.gaseous_carbon_dioxide_g_c[source_root]);
    try std.testing.expectEqual(@as(f64, 0.75), roots.aqueous_carbon_dioxide_g_c[source_root]);
    try std.testing.expectEqual(@as(f64, -1), roots.withdrawal_carbon_dioxide_loss_g_c_per_h[0]);
}

test "GROSUB ordered withdrawal moves one axis through every root domain" {
    var roots = try RootSystem.State.init(std.testing.allocator, 1, 3, 1);
    defer roots.deinit();
    roots.active_root_axis_count[0] = 1;
    roots.deepest_rooted_layer_by_axis[try roots.rootAxisIndex(0, 0)] = 2;
    roots.axis_depth_m[try roots.axisIndex(0, 0, 0)] = 0.5;
    for (0..RootSystem.biological_domain_count) |domain| {
        const deepest_axis = try roots.layerAxisIndex(0, domain, 2, 0);
        const middle_axis = try roots.layerAxisIndex(0, domain, 1, 0);
        const shallow_axis = try roots.layerAxisIndex(0, domain, 0, 0);
        roots.axis_primary_carbon_g[deepest_axis] = 2;
        roots.axis_primary_carbon_g[middle_axis] = 3;
        roots.axis_primary_carbon_g[shallow_axis] = 5;
        roots.axis_primary_length_m[deepest_axis] = 2;
        roots.axis_primary_length_m[middle_axis] = 3;
        roots.axis_primary_length_m[shallow_axis] = 5;
        roots.axis_secondary_length_m[deepest_axis] = 7;
        roots.axis_secondary_length_m[middle_axis] = 11;
        roots.axis_secondary_length_m[shallow_axis] = 13;
        roots.mobile_carbon_g[try roots.layerIndex(0, domain, 2)] = 4;
        roots.mobile_carbon_g[try roots.layerIndex(0, domain, 1)] = 6;
        roots.axis_primary_count[deepest_axis] = 17 + @as(f64, @floatFromInt(domain));
        roots.axis_primary_count[middle_axis] = 19 + @as(f64, @floatFromInt(domain));
        roots.axis_primary_count[shallow_axis] = 23 + @as(f64, @floatFromInt(domain));
        roots.axis_secondary_count[deepest_axis] = 29 + @as(f64, @floatFromInt(domain));
        roots.axis_secondary_count[middle_axis] = 31 + @as(f64, @floatFromInt(domain));
        roots.axis_secondary_count[shallow_axis] = 37 + @as(f64, @floatFromInt(domain));
    }
    roots.secondary_axis_count_total[try roots.layerIndex(0, 0, 2)] = 29;
    roots.secondary_axis_count_total[try roots.layerIndex(0, 0, 1)] = 31;
    roots.secondary_axis_count_total[try roots.layerIndex(0, 0, 0)] = 37;
    try disturbance.withdrawRootAxisLayersSourceOrder(
        &roots,
        0,
        0,
        RootSystem.biological_domain_count,
        &.{ 2, 1 },
        &.{ 0.5, 1 },
        0,
        &.{ 0.5, 0.5, 0.5 },
        &.{ 0.5, 1.0, 1.5 },
    );
    for (0..RootSystem.biological_domain_count) |domain| {
        try std.testing.expectEqual(
            @as(f64, 10),
            roots.axis_primary_carbon_g[try roots.layerAxisIndex(0, domain, 0, 0)],
        );
        try std.testing.expectEqual(
            @as(f64, 0),
            roots.axis_primary_carbon_g[try roots.layerAxisIndex(0, domain, 1, 0)],
        );
        try std.testing.expectEqual(
            @as(f64, 0),
            roots.axis_primary_carbon_g[try roots.layerAxisIndex(0, domain, 2, 0)],
        );
        try std.testing.expectEqual(
            @as(f64, 8),
            roots.mobile_carbon_g[try roots.layerIndex(0, domain, 0)],
        );
        try std.testing.expectEqual(
            @as(f64, 2),
            roots.mobile_carbon_g[try roots.layerIndex(0, domain, 2)],
        );
        const shallow_axis = try roots.layerAxisIndex(0, domain, 0, 0);
        const middle_axis = try roots.layerAxisIndex(0, domain, 1, 0);
        const deepest_axis = try roots.layerAxisIndex(0, domain, 2, 0);
        try std.testing.expectEqual(
            if (domain == 0) @as(f64, 0.5) else @as(f64, 10),
            roots.axis_primary_length_m[shallow_axis],
        );
        try std.testing.expectEqual(@as(f64, 0), roots.axis_primary_length_m[middle_axis]);
        try std.testing.expectEqual(@as(f64, 0), roots.axis_primary_length_m[deepest_axis]);
        try std.testing.expectEqual(@as(f64, 13), roots.axis_secondary_length_m[shallow_axis]);
        try std.testing.expectEqual(@as(f64, 11), roots.axis_secondary_length_m[middle_axis]);
        try std.testing.expectEqual(@as(f64, 7), roots.axis_secondary_length_m[deepest_axis]);
        if (domain == 0) {
            try std.testing.expectEqual(@as(f64, 23), roots.axis_primary_count[shallow_axis]);
            try std.testing.expectEqual(@as(f64, 0), roots.axis_primary_count[middle_axis]);
            try std.testing.expectEqual(@as(f64, 0), roots.axis_primary_count[deepest_axis]);
            try std.testing.expectEqual(@as(f64, 37), roots.axis_secondary_count[shallow_axis]);
            try std.testing.expectEqual(@as(f64, 0), roots.axis_secondary_count[middle_axis]);
            try std.testing.expectEqual(@as(f64, 0), roots.axis_secondary_count[deepest_axis]);
        } else {
            try std.testing.expectEqual(@as(f64, 24), roots.axis_primary_count[shallow_axis]);
            try std.testing.expectEqual(@as(f64, 20), roots.axis_primary_count[middle_axis]);
            try std.testing.expectEqual(@as(f64, 18), roots.axis_primary_count[deepest_axis]);
            try std.testing.expectEqual(@as(f64, 38), roots.axis_secondary_count[shallow_axis]);
            try std.testing.expectEqual(@as(f64, 32), roots.axis_secondary_count[middle_axis]);
            try std.testing.expectEqual(@as(f64, 30), roots.axis_secondary_count[deepest_axis]);
        }
    }
    // The deep RTN2 contributes to RTNL in the middle layer, but RTN2 itself
    // is not added there. The next withdrawal therefore moves only the
    // middle layer's own RTN2, leaving the deep RTNL contribution behind.
    try std.testing.expectEqual(@as(f64, 68), roots.secondary_axis_count_total[try roots.layerIndex(0, 0, 0)]);
    try std.testing.expectEqual(@as(f64, 29), roots.secondary_axis_count_total[try roots.layerIndex(0, 0, 1)]);
    try std.testing.expectEqual(@as(f64, 0), roots.secondary_axis_count_total[try roots.layerIndex(0, 0, 2)]);
    try std.testing.expectEqual(
        @as(usize, 0),
        roots.deepest_rooted_layer_by_axis[try roots.rootAxisIndex(0, 0)],
    );
}

test "GROSUB withdrawal scans every geometrically eligible layer" {
    const thickness = [_]f64{ 0.1, 0.2, 0.2, 0.2, 0.2 };
    const bottoms = [_]f64{ 0.1, 0.3, 0.5, 0.7, 0.9 };
    var withdrawn: [4]usize = undefined;
    const count = try disturbance.selectSourceOrderWithdrawnLayers(
        4,
        4,
        0,
        0.25,
        0.05,
        0.01,
        &thickness,
        &bottoms,
        &withdrawn,
    );
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualSlices(usize, &.{ 4, 3, 2 }, withdrawn[0..count]);
}

test "GROSUB withdrawal stops at first failed destination geometry gate" {
    const thickness = [_]f64{ 0.1, 0.2, 0.001, 0.2, 0.2 };
    const bottoms = [_]f64{ 0.1, 0.3, 0.5, 0.7, 0.9 };
    var withdrawn: [4]usize = undefined;
    const count = try disturbance.selectSourceOrderWithdrawnLayers(
        4,
        4,
        0,
        0.25,
        0.05,
        0.01,
        &thickness,
        &bottoms,
        &withdrawn,
    );
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 4), withdrawn[0]);
    try std.testing.expectEqual(@as(usize, 0), try disturbance.selectSourceOrderWithdrawnLayers(
        3,
        4,
        0,
        0.25,
        0.05,
        0.01,
        &thickness,
        &bottoms,
        &withdrawn,
    ));
}

test "EXTRACT root gas aggregation has runtime species extent and source signs" {
    var roots = try RootSystem.State.init(std.testing.allocator, 7, 1, 1);
    defer roots.deinit();
    for (0..7) |plant| {
        roots.withdrawal_carbon_dioxide_loss_g_c_per_h[plant] = -@as(f64, @floatFromInt(plant + 1));
        roots.withdrawal_nitrous_oxide_loss_g_n_per_h[plant] = -0.5;
    }
    const first = try disturbance.rootGasWithdrawalForCell(&roots, 0, 7);
    try std.testing.expectEqual(@as(f64, -28), first.carbon_dioxide_g_c_per_h);
    try std.testing.expectEqual(@as(f64, -3.5), first.nitrous_oxide_g_n_per_h);
}
