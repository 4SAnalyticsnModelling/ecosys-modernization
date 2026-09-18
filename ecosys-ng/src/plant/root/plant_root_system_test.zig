//! Tests for `plant_root_system.zig`.
//!
//! Extracted so the module beside it carries only model code. Tests
//! that reach a private declaration of that module stay there, since a
//! sibling file can only see `pub` declarations.

const std = @import("std");
const root_system = @import("plant_root_system.zig");

test "STARTQ root and mycorrhizal state has runtime axes and source initial values" {
    const traits = try @import("../../state/plant_traits.zig").parse(@import("../../core/test_fixtures.zig").plant_traits_source);
    var state = try root_system.State.init(std.testing.allocator, 2, 3, 17);
    defer state.deinit();
    try state.initializePlant(1, traits, 2, 0.08, root_system.compatibilityInitializationParameters());
    try std.testing.expectEqual(@as(usize, 17), state.root_axis_count);
    try std.testing.expectEqual(@as(usize, 2), state.planting_layer_by_plant[1]);
    const root_layer = try state.layerIndex(1, 0, 2);
    const mycorrhizal_layer = try state.layerIndex(1, 1, 2);
    try std.testing.expectEqual(@as(f64, -0.01), state.total_water_potential_megapascal[root_layer]);
    try std.testing.expectEqual(@as(f64, 1.0e-3), state.active_length_m[root_layer]);
    try std.testing.expectEqual(traits.roots.primary_root_radius_m, state.primary_radius_m[root_layer]);
    try std.testing.expectEqual(@as(f64, 2.5e-6), state.primary_radius_m[mycorrhizal_layer]);
    try std.testing.expectEqual(@as(f64, 0.08), state.axis_depth_m[try state.axisIndex(1, 1, 16)]);
    try std.testing.expectEqual(
        @as(usize, 2),
        state.deepest_rooted_layer_by_axis[try state.rootAxisIndex(1, 16)],
    );
    try std.testing.expectEqual(traits.roots.root_porosity_fraction, state.current_porosity_fraction_by_domain[try state.domainIndex(1, 0)]);
    try std.testing.expectEqual(traits.roots.root_porosity_fraction, state.current_porosity_fraction_by_domain[try state.domainIndex(1, 1)]);
    try std.testing.expectEqual(traits.roots.root_porosity_fraction, state.initial_porosity_fraction_by_domain[try state.domainIndex(1, 1)]);
    try state.validateFinite();
}

test "STARTQ runtime root initialization controls all domain seed values" {
    const traits = try @import("../../state/plant_traits.zig").parse(@import("../../core/test_fixtures.zig").plant_traits_source);
    var parameters = root_system.compatibilityInitializationParameters();
    parameters.mycorrhizal_radius_m = 4e-6;
    parameters.initial_total_water_potential_megapascal = -0.02;
    parameters.osmotic_water_potential_decrement_megapascal = -0.03;
    parameters.initial_active_length_m = 0.002;
    parameters.initial_water_fraction = 0.9;
    var state = try root_system.State.init(std.testing.allocator, 1, 2, 3);
    defer state.deinit();
    try state.initializePlant(0, traits, 1, 0.05, parameters);
    const root = try state.layerIndex(0, 0, 1);
    const mycorrhiza = try state.layerIndex(0, 1, 1);
    try std.testing.expectEqual(@as(f64, -0.02), state.total_water_potential_megapascal[root]);
    try std.testing.expectEqual(@as(f64, 0.002), state.active_length_m[root]);
    try std.testing.expectEqual(@as(f64, 0.9), state.water_fraction[mycorrhiza]);
    try std.testing.expectEqual(@as(f64, 4e-6), state.primary_radius_m[mycorrhiza]);
    try std.testing.expectApproxEqAbs(traits.water_relations.osmotic_potential_megapascal - 0.03, state.osmotic_water_potential_megapascal[root], 1e-15);
}

test "GROSUB NI and NIX remain plant-wide across biological domains" {
    const traits = try @import("../../state/plant_traits.zig").parse(@import("../../core/test_fixtures.zig").plant_traits_source);
    var state = try root_system.State.init(std.testing.allocator, 2, 6, 3);
    defer state.deinit();
    try state.initializePlant(0, traits, 1, 0.05, root_system.compatibilityInitializationParameters());
    try state.initializePlant(1, traits, 2, 0.10, root_system.compatibilityInitializationParameters());
    try state.includeNextDeepestRootedLayer(0, 4);
    try state.includeNextDeepestRootedLayer(1, 3);

    try state.advanceRootedLayerBoundary(0, 2);
    try std.testing.expectEqualSlices(usize, &.{ 4, 3 }, state.current_deepest_rooted_layer_by_plant);
    // Source `NIX=MAX(NIX,NINR)` (grosub.f:7332) never regresses below an
    // already-reached depth on a non-crossing hour, so the accumulator for
    // the next hour is seeded from the depth just published rather than
    // reset down to the planting layer.
    try std.testing.expectEqualSlices(usize, &.{ 4, 3 }, state.next_deepest_rooted_layer_by_plant);
    for (0..root_system.biological_domain_count) |domain| {
        _ = try state.layerIndex(0, domain, state.current_deepest_rooted_layer_by_plant[0]);
        _ = try state.layerIndex(1, domain, state.current_deepest_rooted_layer_by_plant[1]);
    }
}

test "rooted-layer boundary does not collapse to the planting layer on a non-crossing hour" {
    // Regression test for the audit finding: `advanceRootedLayerBoundary`
    // used to reset `next_deepest_rooted_layer_by_plant` down to
    // `planting_layer_by_plant` every hour, so a plant that reached a
    // deeper layer on one hour's crossing would snap back to its planting
    // layer at the very next hour boundary that had no fresh crossing,
    // silently abandoning the deeper layers for nutrient/O2 competition
    // even though the axis's root carbon was still fully present there.
    const traits = try @import("../../state/plant_traits.zig").parse(@import("../../core/test_fixtures.zig").plant_traits_source);
    var state = try root_system.State.init(std.testing.allocator, 1, 6, 3);
    defer state.deinit();
    try state.initializePlant(0, traits, 1, 0.05, root_system.compatibilityInitializationParameters());

    // Hour 1: axis crosses into layer 4.
    try state.includeNextDeepestRootedLayer(0, 4);
    try state.advanceRootedLayerBoundary(0, 1);
    try std.testing.expectEqual(@as(usize, 4), state.current_deepest_rooted_layer_by_plant[0]);

    // Hour 2: no crossing occurs (the ordinary case once a tip is
    // mid-layer). The published boundary must stay at the previously
    // reached depth, not collapse to the planting layer.
    try state.advanceRootedLayerBoundary(0, 1);
    try std.testing.expectEqual(@as(usize, 4), state.current_deepest_rooted_layer_by_plant[0]);

    // Hour 3, still no crossing: still must not collapse.
    try state.advanceRootedLayerBoundary(0, 1);
    try std.testing.expectEqual(@as(usize, 4), state.current_deepest_rooted_layer_by_plant[0]);
}

test "GROSUB NIX rebuild follows the deepest surviving axis after withdrawal" {
    const traits = try @import("../../state/plant_traits.zig").parse(@import("../../core/test_fixtures.zig").plant_traits_source);
    var state = try root_system.State.init(std.testing.allocator, 1, 6, 3);
    defer state.deinit();
    try state.initializePlant(0, traits, 1, 0.05, root_system.compatibilityInitializationParameters());
    state.active_root_axis_count[0] = 3;
    state.deepest_rooted_layer_by_axis[try state.rootAxisIndex(0, 0)] = 2;
    state.deepest_rooted_layer_by_axis[try state.rootAxisIndex(0, 1)] = 4;
    state.deepest_rooted_layer_by_axis[try state.rootAxisIndex(0, 2)] = 3;
    try state.rebuildNextDeepestRootedLayerFromAxes(0);
    try std.testing.expectEqual(@as(usize, 4), state.next_deepest_rooted_layer_by_plant[0]);
    state.deepest_rooted_layer_by_axis[try state.rootAxisIndex(0, 1)] = 2;
    try state.rebuildNextDeepestRootedLayerFromAxes(0);
    try std.testing.expectEqual(@as(usize, 3), state.next_deepest_rooted_layer_by_plant[0]);
}

test "rooted-layer boundary is invariant to plant decomposition" {
    const traits = try @import("../../state/plant_traits.zig").parse(@import("../../core/test_fixtures.zig").plant_traits_source);
    var whole = try root_system.State.init(std.testing.allocator, 4, 7, 2);
    defer whole.deinit();
    var split = try root_system.State.init(std.testing.allocator, 4, 7, 2);
    defer split.deinit();
    for (0..4) |plant| {
        try whole.initializePlant(plant, traits, plant % 2, 0.05, root_system.compatibilityInitializationParameters());
        try split.initializePlant(plant, traits, plant % 2, 0.05, root_system.compatibilityInitializationParameters());
        try whole.includeNextDeepestRootedLayer(plant, plant + 2);
        try split.includeNextDeepestRootedLayer(plant, plant + 2);
    }
    try whole.advanceRootedLayerBoundary(0, 4);
    try split.advanceRootedLayerBoundary(0, 2);
    try split.advanceRootedLayerBoundary(2, 4);
    try std.testing.expectEqualSlices(usize, whole.current_deepest_rooted_layer_by_plant, split.current_deepest_rooted_layer_by_plant);
    try std.testing.expectEqualSlices(usize, whole.next_deepest_rooted_layer_by_plant, split.next_deepest_rooted_layer_by_plant);
}

test "rooted-layer boundary rejects an invalid late plant atomically" {
    var state = try root_system.State.init(std.testing.allocator, 2, 3, 1);
    defer state.deinit();
    state.planting_layer_by_plant[0] = 0;
    state.planting_layer_by_plant[1] = 1;
    state.current_deepest_rooted_layer_by_plant[0] = 0;
    state.current_deepest_rooted_layer_by_plant[1] = 1;
    state.next_deepest_rooted_layer_by_plant[0] = 2;
    state.next_deepest_rooted_layer_by_plant[1] = 0;
    try std.testing.expectError(error.InvalidRootedLayerBounds, state.advanceRootedLayerBoundary(0, 2));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, state.current_deepest_rooted_layer_by_plant);
    try std.testing.expectEqualSlices(usize, &.{ 2, 0 }, state.next_deepest_rooted_layer_by_plant);
}

test "replant reconstruction clears every root history without changing neighboring plants" {
    const traits = try @import("../../state/plant_traits.zig").parse(@import("../../core/test_fixtures.zig").plant_traits_source);
    var state = try root_system.State.init(std.testing.allocator, 2, 3, 4);
    defer state.deinit();
    @memset(state.mobile_carbon_g, 11);
    @memset(state.gaseous_oxygen_g_o, 12);
    @memset(state.salt_content_mol, 13);
    @memset(state.exudate_carbon_exchange_g_c_per_h, 14);
    @memset(state.axis_primary_carbon_g, 15);
    state.active_root_axis_count[0] = 3;
    state.roots_dead[0] = false;

    try state.reconstructPlant(0, traits, 2, 0.08, root_system.compatibilityInitializationParameters());

    const layer_extent = root_system.biological_domain_count * state.soil_layer_count;
    const salt_extent = layer_extent * root_system.salt_species_count;
    const substrate_extent = layer_extent * root_system.organic_substrate_count;
    const axis_extent = root_system.biological_domain_count * state.root_axis_count;
    for (state.mobile_carbon_g[0..layer_extent]) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (state.gaseous_oxygen_g_o[0..layer_extent]) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (state.salt_content_mol[0..salt_extent]) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (state.exudate_carbon_exchange_g_c_per_h[0..substrate_extent]) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (state.axis_primary_carbon_g[0..axis_extent]) |value| try std.testing.expectEqual(@as(f64, 0), value);
    try std.testing.expectEqual(@as(f64, 11), state.mobile_carbon_g[layer_extent]);
    try std.testing.expectEqual(@as(f64, 13), state.salt_content_mol[salt_extent]);
    try std.testing.expectEqual(@as(usize, 0), state.active_root_axis_count[0]);
    try std.testing.expect(state.roots_dead[0]);
    try std.testing.expectEqual(@as(usize, 2), state.planting_layer_by_plant[0]);
}

test "UPTAKE competition uses demand shares, source minima, and biome fallback" {
    const population = root_system.UptakeCompetition{
        .oxygen = 2,
        .ammonium_nonband = 0.01,
        .ammonium_band = 3,
        .nitrate_nonband = 4,
        .nitrate_band = 5,
        .phosphate_h2_nonband = 6,
        .phosphate_h2_band = 7,
        .phosphate_h_nonband = 8,
        .phosphate_h_band = 9,
    };
    const combined = root_system.UptakeCompetition{
        .oxygen = 10,
        .ammonium_nonband = 10,
        .ammonium_band = 0,
        .nitrate_nonband = 20,
        .nitrate_band = 20,
        .phosphate_h2_nonband = 20,
        .phosphate_h2_band = 20,
        .phosphate_h_nonband = 20,
        .phosphate_h_band = 20,
    };
    const fractions = try root_system.uptakeCompetition(0.05, 0.125, 1.0e-12, population, combined);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), fractions.oxygen, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), fractions.ammonium_nonband, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.125), fractions.ammonium_band, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.45), fractions.phosphate_h_band, 1.0e-12);
}

test "root salt state uses runtime plant domain layer and typed species extents" {
    var state = try root_system.State.init(std.testing.allocator, 7, 3, 2);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 7 * root_system.biological_domain_count * 3 * root_system.salt_species_count), state.salt_content_mol.len);
    const chloride = try state.saltIndex(6, 1, 2, .chloride);
    state.salt_content_mol[chloride] = 0.25;
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), state.salt_content_mol[state.salt_content_mol.len - 1], 1.0e-12);
}

test "UPTAKE hourly reset preserves prior WSRTL and GROSUB reset clears it without changing authoritative pools" {
    var state = try root_system.State.init(std.testing.allocator, 1, 1, 1);
    defer state.deinit();
    state.mobile_carbon_g[0] = 3;
    state.protein_carbon_g[0] = 5;
    state.root_length_m_per_plant[0] = 2;
    state.water_uptake_m3_per_h[0] = -0.1;
    state.ammonium_uptake_nonband_g_n_per_h[0] = 0.03;
    state.ammonium_demand_nonband_g_n_per_h[0] = 0.05;
    state.publishAcceptedNutrientDemandHistory();
    state.ammonium_demand_nonband_g_n_per_h[0] = 0.07;
    state.salt_uptake_mol_per_h[0] = 0.2;
    state.exudate_carbon_exchange_g_c_per_h[0] = -0.3;
    state.symbiont_structural_carbon_g_c[0] = 0.4;
    state.symbiont_mobile_nitrogen_g_n[0] = 0.02;
    state.symbiotic_respiration_actual_g_c_per_h[0] = 0.03;
    state.symbiotic_respiration_oxygen_unlimited_g_c_per_h[0] = 0.05;
    state.withdrawal_carbon_dioxide_loss_g_c_per_h[0] = -0.2;
    state.withdrawal_carbon_dioxide_loss_g_c_per_h_by_root[0] = -0.2;
    state.resetHourlyFluxes();
    try std.testing.expectEqual(@as(f64, 0), state.water_uptake_m3_per_h[0]);
    try std.testing.expectEqual(@as(f64, 0.03), state.previous_ammonium_uptake_nonband_g_n_per_h[0]);
    try std.testing.expectEqual(@as(f64, 0), state.ammonium_uptake_nonband_g_n_per_h[0]);
    // Resetting a failed/retried attempt cannot overwrite the last accepted
    // nutrient-demand snapshot.
    try std.testing.expectEqual(@as(f64, 0.05), state.previous_ammonium_demand_nonband_g_n_per_h[0]);
    try std.testing.expectEqual(@as(f64, 0), state.ammonium_demand_nonband_g_n_per_h[0]);
    try std.testing.expectEqual(@as(f64, 0), state.salt_uptake_mol_per_h[0]);
    try std.testing.expectEqual(@as(f64, 0), state.exudate_carbon_exchange_g_c_per_h[0]);
    try std.testing.expectEqual(@as(f64, 3), state.mobile_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 5), state.protein_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0.4), state.symbiont_structural_carbon_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0.02), state.symbiont_mobile_nitrogen_g_n[0]);
    try std.testing.expectEqual(@as(f64, 0), state.symbiotic_respiration_actual_g_c_per_h[0]);
    try std.testing.expectEqual(@as(f64, 0), state.symbiotic_respiration_oxygen_unlimited_g_c_per_h[0]);
    try std.testing.expectEqual(@as(f64, 0), state.withdrawal_carbon_dioxide_loss_g_c_per_h[0]);
    try std.testing.expectEqual(@as(f64, 0), state.withdrawal_carbon_dioxide_loss_g_c_per_h_by_root[0]);
    try std.testing.expectEqual(@as(f64, 2), state.root_length_m_per_plant[0]);
    state.resetGrosubProteinCarbon();
    try std.testing.expectEqual(@as(f64, 0), state.protein_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 3), state.mobile_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 2), state.root_length_m_per_plant[0]);
}

test "GROSUB root topology aggregation has no axis ceiling" {
    var state = try root_system.State.init(std.testing.allocator, 1, 2, 12);
    defer state.deinit();
    for (0..12) |axis| {
        const index = try state.layerAxisIndex(0, 0, 1, axis);
        state.axis_primary_count[index] = 1;
        state.axis_secondary_count[index] = 2;
        state.axis_primary_length_m[index] = 0.1;
        state.axis_secondary_length_m[index] = 0.2;
    }
    state.secondary_axis_count_total[try state.layerIndex(0, 0, 1)] = 24;
    const topology = try state.layerTopology(0, 0, 1, 6, 0.5, 0.75, 0.01);
    try std.testing.expectApproxEqAbs(12, topology.primary_axis_count, 1e-14);
    try std.testing.expectApproxEqAbs(24, topology.secondary_axis_count, 1e-14);
    try std.testing.expectApproxEqAbs(9.6, topology.total_root_length_m, 1e-14);
    try std.testing.expectApproxEqAbs(1.2, topology.root_length_m_per_plant, 1e-14);
    try std.testing.expectApproxEqAbs(2.4, topology.root_length_density_m_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(0.1, topology.average_secondary_length_m, 1e-14);
    const layer = try state.layerIndex(0, 0, 1);
    state.total_carbon_g[layer] = 2;
    state.turgor_water_potential_megapascal[layer] = 1;
    state.total_water_potential_megapascal[layer] = -1;
    state.reference_primary_radius_m[layer] = 4e-4;
    state.reference_secondary_radius_m[layer] = 2e-4;
    const parameters = root_system.compatibilityMorphologyParameters();
    const refreshed = try state.refreshLayerMorphology(0, 0, 1, 6, 0.5, 0.75, 0.2, 2e-5, 3.1416, true, parameters);
    try std.testing.expectEqual(topology.total_root_length_m, refreshed.total_root_length_m);
    // GROSUB/grosub.f:7440-7443 drives RRAD1/RRAD2 elastic growth from PSIRT
    // (total root water potential), which is always <=0 in the oracle
    // (startq.f:750 PSIRT=-0.01), so the AMAX1 floor branch (the reference
    // radius) is always selected; radius stays pinned at the reference value.
    try std.testing.expectApproxEqAbs(@as(f64, 4e-4), state.primary_radius_m[layer], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2e-4), state.secondary_radius_m[layer], 1e-14);
    try std.testing.expectApproxEqAbs(0.8 * @max(3.1416 * 2e-4 * 2e-4 * 2.4, 4e-5), state.aqueous_volume_m3[layer], 1e-14);
    try std.testing.expect(state.root_surface_area_m2_per_plant[layer] > 0);
    const thin = try state.refreshLayerMorphologySourceOrder(
        0,
        0,
        1,
        6,
        0.5,
        0.5,
        0.75,
        0.2,
        2e-5,
        3.1416,
        true,
        parameters,
    );
    try std.testing.expectEqual(@as(f64, 0), thin.root_length_density_m_per_m3);
    try std.testing.expectEqual(
        @as(f64, 0),
        state.root_length_density_m_per_m3[layer],
    );
}

test "GROSUB layer topology consumes authoritative RTNL rather than summing RTN2" {
    var state = try root_system.State.init(std.testing.allocator, 1, 1, 2);
    defer state.deinit();
    state.axis_secondary_count[try state.layerAxisIndex(0, 0, 0, 0)] = 2;
    state.axis_secondary_count[try state.layerAxisIndex(0, 0, 0, 1)] = 3;
    state.axis_secondary_length_m[try state.layerAxisIndex(0, 0, 0, 0)] = 7;
    state.secondary_axis_count_total[try state.layerIndex(0, 0, 0)] = 7;
    const topology = try state.layerTopology(0, 0, 0, 1, 1, 1, 0.01);
    try std.testing.expectEqual(@as(f64, 7), topology.secondary_axis_count);
    try std.testing.expectEqual(@as(f64, 1), topology.average_secondary_length_m);
}

test "STARTQ seed geometry augments only the root planting layer" {
    var state = try root_system.State.init(std.testing.allocator, 1, 2, 1);
    defer state.deinit();
    state.planting_layer_by_plant[0] = 1;
    try state.setSeedGeometry(0, 1.0e-6, 0.02, 0.003);

    const root_layer = try state.layerIndex(0, 0, 1);
    state.reference_primary_radius_m[root_layer] = 4.0e-4;
    state.reference_secondary_radius_m[root_layer] = 2.0e-4;
    state.turgor_water_potential_megapascal[root_layer] = 1;
    const topology = try state.refreshLayerMorphology(0, 0, 1, 6, 0.5, 0.75, 0.2, 2.0e-5, 3.1416, true, root_system.compatibilityMorphologyParameters());
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), topology.root_length_m_per_plant, 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.04), topology.root_length_density_m_per_m3, 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0e-6), state.aqueous_volume_m3[root_layer] + state.gaseous_volume_m3[root_layer], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), state.root_surface_area_m2_per_plant[root_layer], 1.0e-14);

    const symbiont = try state.layerTopology(0, 1, 1, 6, 0.5, 0.75, 0.01);
    const other_layer = try state.layerTopology(0, 0, 0, 6, 0.5, 0.75, 0.01);
    try std.testing.expectEqual(@as(f64, 0), symbiont.root_length_m_per_plant);
    try std.testing.expectEqual(@as(f64, 0), other_layer.root_length_m_per_plant);
}

test "GROSUB empty root layer releases both gas phases and restores reference radii" {
    var state = try root_system.State.init(std.testing.allocator, 1, 1, 1);
    defer state.deinit();
    const root = try state.layerIndex(0, 0, 0);
    state.reference_primary_radius_m[root] = 4.0e-4;
    state.reference_secondary_radius_m[root] = 2.0e-4;
    state.primary_radius_m[root] = 8.0e-4;
    state.secondary_radius_m[root] = 6.0e-4;
    state.gaseous_carbon_dioxide_g_c[root] = 2;
    state.aqueous_carbon_dioxide_g_c[root] = 3;
    state.gaseous_oxygen_g_o[root] = 5;
    state.aqueous_oxygen_g_o[root] = 7;

    _ = try state.refreshLayerMorphology(0, 0, 0, 4, 0.25, 1, 0.2, 2.0e-5, 3.142, false, root_system.compatibilityMorphologyParameters());

    try std.testing.expectEqual(@as(f64, 4.0e-4), state.primary_radius_m[root]);
    try std.testing.expectEqual(@as(f64, 2.0e-4), state.secondary_radius_m[root]);
    try std.testing.expectEqual(@as(f64, -5), state.withdrawal_carbon_dioxide_loss_g_c_per_h[0]);
    try std.testing.expectEqual(@as(f64, -12), state.withdrawal_oxygen_loss_g_o_per_h[0]);
    try std.testing.expectEqual(@as(f64, -5), state.withdrawal_carbon_dioxide_loss_g_c_per_h_by_root[root]);
    try std.testing.expectEqual(@as(f64, -12), state.withdrawal_oxygen_loss_g_o_per_h_by_root[root]);
    try std.testing.expectEqual(@as(f64, 0), state.gaseous_carbon_dioxide_g_c[root]);
    try std.testing.expectEqual(@as(f64, 0), state.aqueous_oxygen_g_o[root]);
}

// STARTQ-ROOTGAS-001. `startq.f:793--794` and `:801--802` seed the symbiont
// gas pools as CCO2A*RTVLP, CCO2P*RTVLW, COXYA*RTVLP and COXYP*RTVLW, but
// `:768--769` set RTVLP=RTVLW=0.0 twenty-four lines earlier in the same loop
// body, so every one of those products is identically zero at initialization.
// The solubility expressions 0.030*EXP(-2.621-0.0317*ATCA)*CO2EI and
// 0.032*EXP(-6.175-0.0211*ATCA)*OXYE are evaluated and discarded. Production
// therefore correctly leaves the pools at their allocation zero and grows the
// volumes only once `refreshLayerMorphology` runs. WFR=1.0 at `startq.f:811`
// is the one non-zero value in the block, so pin it alongside.
// See `docs/traceability/symbiont_gas_initialization_multiplies_by_zero.md`.
test "startq.f:768 zeroes root volumes before :793 scales the gas pools by them" {
    const traits = try @import("../../state/plant_traits.zig").parse(@import("../../core/test_fixtures.zig").plant_traits_source);
    var state = try root_system.State.init(std.testing.allocator, 1, 2, 3);
    defer state.deinit();
    try state.initializePlant(0, traits, 1, 0.05, root_system.compatibilityInitializationParameters());
    for (0..2) |domain| {
        for (0..2) |layer| {
            const index = try state.layerIndex(0, domain, layer);
            try std.testing.expectEqual(@as(f64, 0), state.gaseous_volume_m3[index]);
            try std.testing.expectEqual(@as(f64, 0), state.aqueous_volume_m3[index]);
            try std.testing.expectEqual(@as(f64, 0), state.gaseous_carbon_dioxide_g_c[index]);
            try std.testing.expectEqual(@as(f64, 0), state.aqueous_carbon_dioxide_g_c[index]);
            try std.testing.expectEqual(@as(f64, 0), state.gaseous_oxygen_g_o[index]);
            try std.testing.expectEqual(@as(f64, 0), state.aqueous_oxygen_g_o[index]);
            try std.testing.expectEqual(@as(f64, 1.0), state.water_fraction[index]);
        }
    }
    // The zeros above are a statement about STARTQ ordering, not a blanket
    // clear: give the planting layer a seed volume and the phase volumes
    // become positive, so the assertions are falsifiable rather than vacuous.
    try state.setSeedGeometry(0, 1.0e-6, 1.0e-3, 1.0e-4);
    _ = try state.refreshLayerMorphology(0, 0, 1, 4, 0.25, 1, 0.2, 2.0e-5, 3.142, false, root_system.compatibilityMorphologyParameters());
    const planted = try state.layerIndex(0, 0, 1);
    try std.testing.expect(state.gaseous_volume_m3[planted] > 0);
    try std.testing.expect(state.aqueous_volume_m3[planted] > 0);
}

test "GROSUB active carbon assigns whole primary axis to its runtime tip layer" {
    var state = try root_system.State.init(std.testing.allocator, 1, 3, 2);
    defer state.deinit();
    state.active_root_axis_count[0] = 2;
    state.planting_layer_by_plant[0] = 0;
    const axis_0_layer_0 = try state.layerAxisIndex(0, 0, 0, 0);
    const axis_0_layer_1 = try state.layerAxisIndex(0, 0, 1, 0);
    const axis_1_layer_0 = try state.layerAxisIndex(0, 0, 0, 1);
    const axis_1_layer_2 = try state.layerAxisIndex(0, 0, 2, 1);
    state.axis_primary_carbon_g[axis_0_layer_0] = 1;
    state.axis_primary_carbon_g[axis_0_layer_1] = 2;
    state.axis_primary_length_m[axis_0_layer_1] = 0.1;
    state.axis_primary_carbon_g[axis_1_layer_0] = 4;
    state.axis_primary_carbon_g[axis_1_layer_2] = 5;
    state.axis_primary_length_m[axis_1_layer_2] = 0.1;
    state.axis_secondary_carbon_g[axis_0_layer_0] = 0.5;
    state.axis_secondary_carbon_g[axis_1_layer_2] = 0.25;
    try state.refreshActiveCarbonByLayer(0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.total_carbon_g[try state.layerIndex(0, 0, 0)], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), state.total_carbon_g[try state.layerIndex(0, 0, 1)], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 9.25), state.total_carbon_g[try state.layerIndex(0, 0, 2)], 1.0e-15);
}

test "GROSUB root totals distinguish active and actual layer carbon" {
    const totals = try root_system.State.sourceOrderLayerCarbonTotals(
        &.{ 1.0, 3.0, 5.0 },
        &.{ 0.5, 0.25, 0.125 },
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.875), totals.active_secondary_carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 9.875), totals.actual_primary_and_secondary_carbon_g_c, 1.0e-15);
    try std.testing.expectError(error.RootCarbonTotalDimensionMismatch, root_system.State.sourceOrderLayerCarbonTotals(&.{1}, &.{ 1, 2 }));
}

test "GROSUB negative structural carbon cleanup charges the mobile pool" {
    const primary = try root_system.sourceOrderNegativeStructuralCarbonCleanup(-0.25, 2);
    try std.testing.expectEqual(@as(f64, 0), primary.structural_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 1.75), primary.mobile_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0.25), primary.removed_deficit_g_c);

    const secondary = try root_system.sourceOrderNegativeStructuralCarbonCleanup(0.5, 2);
    try std.testing.expectEqual(@as(f64, 0.5), secondary.structural_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 2), secondary.mobile_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), secondary.removed_deficit_g_c);
}

test "GROSUB negative cleanup exposes rather than hides a mobile overdraw" {
    const result = try root_system.sourceOrderNegativeStructuralCarbonCleanup(-2, 0.5);
    try std.testing.expectEqual(@as(f64, -1.5), result.mobile_carbon_g_c);
    try std.testing.expectError(
        error.NonFiniteNegativeStructuralCarbonCleanup,
        root_system.sourceOrderNegativeStructuralCarbonCleanup(std.math.nan(f64), 1),
    );
}

test "GROSUB morphology requires length carbon and population above ZEROP" {
    try std.testing.expect(try root_system.sourceOrderRootMorphologyIsActive(1, 2, 3, 1.0e-6));
    try std.testing.expect(!try root_system.sourceOrderRootMorphologyIsActive(1.0e-6, 2, 3, 1.0e-6));
    try std.testing.expect(!try root_system.sourceOrderRootMorphologyIsActive(1, 2, 0, 1.0e-6));
}

test "GROSUB thin layer publishes zero root length density" {
    try std.testing.expectEqual(@as(f64, 4), try root_system.sourceOrderRootLengthDensity(1, 0.25, 0.01));
    try std.testing.expectEqual(@as(f64, 0), try root_system.sourceOrderRootLengthDensity(1, 0.01, 0.01));
    try std.testing.expectEqual(@as(f64, 0), try root_system.sourceOrderRootLengthDensity(1, 0, 0.01));
}
