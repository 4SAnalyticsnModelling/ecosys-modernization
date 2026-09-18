//! Tests for `plant_harvest_runtime.zig`.
//!
//! Extracted verbatim so the module beside it contains only the model
//! code. Tests that use private declarations of that module stay there,
//! since a sibling file can only reach `pub` declarations.

const builtin = @import("builtin");
const canopy = @import("../canopy/photosynthesis/photosynthesis.zig");
const canopy_biochemistry = @import("../canopy/photosynthesis/biochemistry.zig");
const canopy_layers = @import("../canopy/radiation/layer_distribution.zig");
const canopy_structure = @import("../canopy/morphology/structure.zig");
const carbon_exchange = @import("../canopy/photosynthesis/carbon_exchange.zig");
const dormancy = @import("../plant/lifecycle/dormancy.zig");
const grazing_manure = @import("../management/grazing_manure.zig");
const grid_module = @import("../state/grid.zig");
const growth_stages = @import("../plant/lifecycle/growth_stages.zig");
const litter_partition = @import("../plant/partition/litter.zig");
const management = @import("../management/plant_management.zig");
const phenology = @import("../plant/lifecycle/phenology.zig");
const root_disturbance = @import("../plant/root/plant_root_disturbance.zig");
const root_litter_ledger = @import("../plant/root/plant_root_litter_budget.zig");
const root_litterfall = @import("../plant/root/plant_root_litterfall.zig");
const root_system = @import("../plant/root/plant_root_system.zig");
const shoot_litter_bridge = @import("../plant/growth/shoot_litter_bridge.zig");
const soil_organic = @import("../soil/organic/initialization.zig");
const spring_reproductive_litterfall = @import("../plant/growth/spring_reproductive_litterfall.zig");
const std = @import("std");
const surface_nutrients = @import("../soil/biogeochemistry/organic_matter_fire_exchange.zig");
const symbiotic_fixation = @import("../canopy/symbiosis/plant_symbiotic_fixation.zig");
const plant_harvest_runtime = @import("../management/plant_harvest_runtime.zig");
test "GROSUB forest self thinning retains exact density law and runtime units" {
    try std.testing.expectEqual(@as(f64, 0), try plant_harvest_runtime.forestSelfThinningFraction(0, 10));
    try std.testing.expectEqual(@as(f64, 0), try plant_harvest_runtime.forestSelfThinningFraction(0.25, 0.05));
    // At 0.25 m PPQ is exactly 0.1 plants m-2.
    try std.testing.expectApproxEqAbs(@as(f64, 0.09), try plant_harvest_runtime.forestSelfThinningFraction(0.25, 1), 1.0e-15);
    try std.testing.expectError(error.InvalidForestSelfThinningInput, plant_harvest_runtime.forestSelfThinningFraction(-0.1, 1));
}

test "GROSUB first substep resets only hourly disturbance products" {
    const current: plant_harvest_runtime.HourlyDisturbanceReset = .{
        .previous_cumulative_harvest_carbon_g_c = 3,
        .manure_organic_carbon_g_c = .{ 1, 2, 3, 4 },
        .manure_organic_nitrogen_g_n = .{ 5, 6, 7, 8 },
        .manure_organic_phosphorus_g_p = .{ 9, 10, 11, 12 },
        .manure_inorganic_nitrogen_g_n = 13,
        .manure_inorganic_phosphorus_g_p = 14,
    };
    const unchanged = try plant_harvest_runtime.sourceOrderHourlyDisturbanceReset(false, 20, current);
    try std.testing.expectEqualDeep(current, unchanged);
    const reset = try plant_harvest_runtime.sourceOrderHourlyDisturbanceReset(true, 20, current);
    try std.testing.expectEqual(@as(f64, 20), reset.previous_cumulative_harvest_carbon_g_c);
    try std.testing.expectEqual([4]f64{ 0, 0, 0, 0 }, reset.manure_organic_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), reset.manure_inorganic_nitrogen_g_n);
}

test "GROSUB forest self thinning selector preserves monthly noon and event gates" {
    try std.testing.expect(try plant_harvest_runtime.sourceOrderForestSelfThinningIsEnabled(30, 12, 12.75, 1, 2, -1));
    try std.testing.expect(try plant_harvest_runtime.sourceOrderForestSelfThinningIsEnabled(360, 12, 12.75, 1, 2, 4));
    try std.testing.expect(try plant_harvest_runtime.sourceOrderForestSelfThinningIsEnabled(30, 12, 12.75, 1, 2, 6));
    try std.testing.expect(!try plant_harvest_runtime.sourceOrderForestSelfThinningIsEnabled(30, 12, 12.75, 1, 2, 0));
    try std.testing.expect(!try plant_harvest_runtime.sourceOrderForestSelfThinningIsEnabled(29, 12, 12.75, 1, 2, -1));
    try std.testing.expect(!try plant_harvest_runtime.sourceOrderForestSelfThinningIsEnabled(30, 13, 12.75, 1, 2, -1));
    try std.testing.expect(!try plant_harvest_runtime.sourceOrderForestSelfThinningIsEnabled(30, 12, 12.75, 0, 2, -1));
    try std.testing.expect(!try plant_harvest_runtime.sourceOrderForestSelfThinningIsEnabled(30, 12, 12.75, 1, 1, -1));
}

test "GROSUB pruning multiplies the persistent canopy clumping factor" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.48), try plant_harvest_runtime.prunedClumpingFactor(0.8, 0.6), 1.0e-15);
    try std.testing.expectError(error.InvalidPruningClumpingFraction, plant_harvest_runtime.prunedClumpingFactor(0.8, -0.1));
}

test "GROSUB negative HVST interpolates combined canopy leaf area across runtime layers" {
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.5),
        try plant_harvest_runtime.cuttingHeightFromLeafAreaRemoval(0.5, &.{ 0, 1, 3 }, &.{ 2, 4 }, 1.0e-12),
        1.0e-15,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        try plant_harvest_runtime.cuttingHeightFromLeafAreaRemoval(1, &.{ 0, 1, 3 }, &.{ 2, 4 }, 1.0e-12),
    );
    try std.testing.expectError(
        error.InvalidLeafAreaHarvestGeometry,
        plant_harvest_runtime.cuttingHeightFromLeafAreaRemoval(1.1, &.{ 0, 1 }, &.{1}, 1.0e-12),
    );
}

test "GROSUB cutting height uses authoritative combined canopy leaf area" {
    const exact = try plant_harvest_runtime.sourceOrderCuttingHeightFromLeafAreaRemoval(
        0.5,
        8,
        &.{ 0, 1, 3 },
        &.{ 2, 4 },
        1.0e-12,
    );
    try std.testing.expectEqual(@as(f64, 2), exact);
    const recomputed = try plant_harvest_runtime.cuttingHeightFromLeafAreaRemoval(0.5, &.{ 0, 1, 3 }, &.{ 2, 4 }, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 1.5), recomputed);
}

test "GROSUB aboveground disturbance dispatch and population update are exact" {
    try std.testing.expect(try plant_harvest_runtime.sourceOrderAbovegroundDisturbanceIsEnabled(4, 3, 12.5));
    try std.testing.expect(try plant_harvest_runtime.sourceOrderAbovegroundDisturbanceIsEnabled(6, 3, 12.5));
    try std.testing.expect(try plant_harvest_runtime.sourceOrderAbovegroundDisturbanceIsEnabled(2, 12, 12.5));
    try std.testing.expect(!try plant_harvest_runtime.sourceOrderAbovegroundDisturbanceIsEnabled(2, 11, 12.5));
    try std.testing.expect(!try plant_harvest_runtime.sourceOrderAbovegroundDisturbanceIsEnabled(-1, 12, 12.5));

    const current: plant_harvest_runtime.PopulationAfterDisturbance = .{
        .living_population_per_m2 = 4,
        .living_population_count = 40,
        .standing_dead_population_count = 10,
    };
    const thinned = try plant_harvest_runtime.sourceOrderPopulationAfterDisturbance(false, 0.25, current, 7, 10);
    try std.testing.expectEqual(@as(f64, 3), thinned.living_population_per_m2);
    try std.testing.expectEqual(@as(f64, 30), thinned.living_population_count);
    try std.testing.expectEqual(@as(f64, 7.5), thinned.standing_dead_population_count);
    const reseeded = try plant_harvest_runtime.sourceOrderPopulationAfterDisturbance(true, 0.25, current, 7, 10);
    try std.testing.expectEqual(@as(f64, 7), reseeded.living_population_per_m2);
    try std.testing.expectEqual(@as(f64, 70), reseeded.living_population_count);
    try std.testing.expectEqual(@as(f64, 70), reseeded.standing_dead_population_count);
}

test "GROSUB harvest litter uses organ-specific runtime kinetics conservatively" {
    const foliar: litter_partition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 0, 1, 0, 0 },
        .phosphorus = .{ 0, 0, 1, 0 },
    };
    const nonfoliar: litter_partition.ElementFractions = .{
        .carbon = .{ 0, 1, 0, 0 },
        .nitrogen = .{ 0, 0, 1, 0 },
        .phosphorus = .{ 0, 0, 0, 1 },
    };
    const woody: litter_partition.ElementFractions = .{
        .carbon = .{ 0, 0, 1, 0 },
        .nitrogen = .{ 0, 0, 0, 1 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const products: plant_harvest_runtime.ProductLedger = .{
        .foliar = .{ .litter = .{ .carbon_g = 2, .nitrogen_g = 0.2, .phosphorus_g = 0.02 } },
        .nonfoliar = .{ .litter = .{ .carbon_g = 3, .nitrogen_g = 0.3, .phosphorus_g = 0.03 } },
        .woody = .{ .litter = .{ .carbon_g = 5, .nitrogen_g = 0.5, .phosphorus_g = 0.05 } },
    };
    const result = try plant_harvest_runtime.harvestLitterToKinetics(products, foliar, foliar, nonfoliar, woody);
    try std.testing.expectEqual([4]f64{ 2, 3, 0, 0 }, result.nonwoody_carbon_g);
    try std.testing.expectEqual([4]f64{ 0, 0, 5, 0 }, result.woody_carbon_g);
    var carbon_g_c: f64 = 0;
    var nitrogen_g_n: f64 = 0;
    var phosphorus_g_p: f64 = 0;
    for (0..4) |kinetic| {
        carbon_g_c += result.nonwoody_carbon_g[kinetic] + result.woody_carbon_g[kinetic];
        nitrogen_g_n += result.nonwoody_nitrogen_g[kinetic] + result.woody_nitrogen_g[kinetic];
        phosphorus_g_p += result.nonwoody_phosphorus_g[kinetic] + result.woody_phosphorus_g[kinetic];
    }
    try std.testing.expectApproxEqAbs(@as(f64, 10), carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), nitrogen_g_n, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), phosphorus_g_p, 1.0e-15);
}

test "GROSUB automatic deciduous annual harvest fires once at reproductive turnover" {
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer state.deinit();
    var layers = try canopy_layers.State.init(std.testing.allocator, 1, 1, 1, 1, 1, &state);
    defer layers.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var plant_state = try phenology.State.init(std.testing.allocator, 1, 1);
    defer plant_state.deinit();
    plant_state.active[0] = true;
    plant_state.lifecycle_initialized[0] = true;
    var growth = try growth_stages.State.init(std.testing.allocator, &.{1});
    defer growth.deinit();
    state.branch_grain_carbon_g[0] = 5;
    state.branch_grain_nitrogen_g[0] = 0.5;
    state.branch_grain_phosphorus_g[0] = 0.05;
    state.plant_population_per_m2[0] = 2;
    const science = [_]plant_harvest_runtime.ScienceParameters{.{ .carbon_woody_fraction = .{ 0, 1 }, .leaf_nitrogen_woody_fraction = .{ 0, 1 }, .sheath_nitrogen_woody_fraction = .{ 0, 1 }, .leaf_phosphorus_woody_fraction = .{ 0, 1 }, .sheath_phosphorus_woody_fraction = .{ 0, 1 } }};
    var ledgers = [_]plant_harvest_runtime.ProductLedger{.{}};
    const population = [_]f64{4};
    const area = [_]f64{2};
    const root_woody = [_]f64{0};
    var automatic_dates = [_]management.PackedDate{.{ .day = 1, .month = 1, .year = 0 }};
    var context: plant_harvest_runtime.Context = .{
        .canopy_state = &state,
        .canopy_layer_state = &layers,
        .branch_development = &development,
        .science_by_plant = &science,
        .products_by_plant = &ledgers,
        .leaf_area_presence_tolerance_m2 = 1e-12,
        .plant_phenology = &plant_state,
        .growth_stages = &growth,
        .reseed_population_per_m2_by_plant = &population,
        .cell_area_m2_by_cell = &area,
        .root_woody_fraction_by_plant = &root_woody,
        .automatic_harvest_date_by_plant = &automatic_dates,
    };
    const current_date: management.PackedDate = .{ .day = 17, .month = 9, .year = 2004 };
    try std.testing.expectEqual(@as(usize, 1), try plant_harvest_runtime.applyAutomaticSelfSeedingHarvests(&context, &.{true}, &.{0}, &.{1}, current_date));
    try std.testing.expectApproxEqAbs(@as(f64, 5), state.plant_seed_storage_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4), state.plant_population_per_m2[0], 1e-12);
    try std.testing.expect(plant_state.reseed_pending[0]);
    try std.testing.expectEqual(current_date, automatic_dates[0]);
    try std.testing.expectEqual(@as(usize, 0), try plant_harvest_runtime.applyAutomaticSelfSeedingHarvests(&context, &.{true}, &.{0}, &.{1}, current_date));
}

test "GROSUB perennial start-of-season residue is conserved before reconstruction" {
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer state.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var partitions = try litter_partition.State.init(std.testing.allocator, 1);
    defer partitions.deinit();
    @memset(partitions.by_plant_and_organ, .{ .carbon = .{ 0.1, 0.2, 0.3, 0.4 }, .nitrogen = .{ 0.1, 0.2, 0.3, 0.4 }, .phosphorus = .{ 0.1, 0.2, 0.3, 0.4 } });
    state.sample_leaf_area_m2[0] = 1;
    state.sample_leaf_carbon_g[0] = 2;
    state.sample_leaf_nitrogen_g[0] = 0.2;
    state.sample_leaf_phosphorus_g[0] = 0.02;
    state.node_leaf_area_m2[0] = 1;
    state.node_leaf_carbon_g[0] = 2;
    state.node_leaf_nitrogen_g[0] = 0.2;
    state.node_leaf_phosphorus_g[0] = 0.02;
    state.branch_leaf_area_m2[0] = 1;
    state.branch_leaf_carbon_g[0] = 2;
    state.branch_leaf_nitrogen_g[0] = 0.2;
    state.branch_leaf_phosphorus_g[0] = 0.02;
    state.node_sheath_carbon_g[0] = 1;
    state.node_sheath_nitrogen_g[0] = 0.1;
    state.node_sheath_phosphorus_g[0] = 0.01;
    state.branch_sheath_carbon_g[0] = 1;
    state.branch_sheath_nitrogen_g[0] = 0.1;
    state.branch_sheath_phosphorus_g[0] = 0.01;
    state.branch_husk_carbon_g[0] = 1;
    state.branch_ear_carbon_g[0] = 1;
    state.branch_grain_carbon_g[0] = 1;
    state.branch_stalk_carbon_g[0] = 4;
    state.branch_stalk_nitrogen_g[0] = 0.4;
    state.branch_stalk_phosphorus_g[0] = 0.04;
    state.branch_reserve_carbon_g[0] = 2;
    state.branch_reserve_nitrogen_g[0] = 0.2;
    state.branch_reserve_phosphorus_g[0] = 0.02;
    const science = [_]plant_harvest_runtime.ScienceParameters{.{ .carbon_woody_fraction = .{ 0.25, 0.75 }, .leaf_nitrogen_woody_fraction = .{ 0.25, 0.75 }, .sheath_nitrogen_woody_fraction = .{ 0.25, 0.75 }, .leaf_phosphorus_woody_fraction = .{ 0.25, 0.75 }, .sheath_phosphorus_woody_fraction = .{ 0.25, 0.75 } }};
    var ledgers = [_]plant_harvest_runtime.ProductLedger{.{}};
    var context: plant_harvest_runtime.Context = .{ .canopy_state = &state, .branch_development = &development, .science_by_plant = &science, .products_by_plant = &ledgers, .leaf_area_presence_tolerance_m2 = 1e-12, .root_litter_partition = &partitions };
    var before_failure = try state.clone();
    defer before_failure.deinit();
    const products_before_failure = ledgers;
    partitions.by_plant_and_organ[@intFromEnum(litter_partition.Organ.stalk)].carbon[3] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidPlantLitterFraction, plant_harvest_runtime.applyStartOfSeasonResidue(&context, 0, 0, 1));
    inline for (@typeInfo(canopy.State).@"struct".fields) |field| if (field.type == []f64)
        try std.testing.expectEqualSlices(f64, @field(before_failure, field.name), @field(state, field.name));
    try std.testing.expectEqualDeep(products_before_failure, ledgers);
    partitions.by_plant_and_organ[@intFromEnum(litter_partition.Organ.stalk)].carbon = .{ 0.1, 0.2, 0.3, 0.4 };
    try plant_harvest_runtime.applyStartOfSeasonResidue(&context, 0, 0, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 4), state.plant_standing_dead_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.plant_seed_storage_carbon_g[0], 1e-12);
    var direct_litter_carbon_g_c: f64 = 0;
    for (ledgers[0].direct_litter.nonwoody_carbon_g) |value| direct_litter_carbon_g_c += value;
    const litter_carbon_g_c = ledgers[0].foliar.litter.carbon_g + ledgers[0].nonfoliar.litter.carbon_g + ledgers[0].woody.litter.carbon_g + direct_litter_carbon_g_c;
    try std.testing.expectApproxEqAbs(@as(f64, 6), litter_carbon_g_c, 1e-12);
    var standing_kinetic_carbon_g_c: f64 = 0;
    for (state.plant_standing_dead_carbon_by_kinetic_g[0..4]) |value| standing_kinetic_carbon_g_c += value;
    try std.testing.expectApproxEqAbs(@as(f64, 4), standing_kinetic_carbon_g_c, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), state.branch_stalk_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.branch_reserve_carbon_g[0]);
}

test "GROSUB whole-plant death conserves shoot storage symbiont and standing dead carbon" {
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer state.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var partitions = try litter_partition.State.init(std.testing.allocator, 1);
    defer partitions.deinit();
    @memset(partitions.by_plant_and_organ, .{
        .carbon = .{ 0.1, 0.2, 0.3, 0.4 },
        .nitrogen = .{ 0.1, 0.2, 0.3, 0.4 },
        .phosphorus = .{ 0.1, 0.2, 0.3, 0.4 },
    });
    state.plant_seed_storage_carbon_g[0] = 4;
    state.branch_stalk_carbon_g[0] = 3;
    state.branch_reserve_carbon_g[0] = 2;
    state.branch_mobile_carbon_g[0] = 1;
    state.node_c4_mesophyll_nonstructural_carbon_g[0] = 1;
    state.branch_symbiont_mobile_carbon_g[0] = 0.5;
    state.branch_symbiont_structural_carbon_g[0] = 0.5;
    state.branch_husk_carbon_g[0] = 1;
    const science = [_]plant_harvest_runtime.ScienceParameters{.{ .carbon_woody_fraction = .{ 0.25, 0.75 }, .leaf_nitrogen_woody_fraction = .{ 0.25, 0.75 }, .sheath_nitrogen_woody_fraction = .{ 0.25, 0.75 }, .leaf_phosphorus_woody_fraction = .{ 0.25, 0.75 }, .sheath_phosphorus_woody_fraction = .{ 0.25, 0.75 } }};
    var ledgers = [_]plant_harvest_runtime.ProductLedger{.{}};
    var context: plant_harvest_runtime.Context = .{
        .canopy_state = &state,
        .branch_development = &development,
        .science_by_plant = &science,
        .products_by_plant = &ledgers,
        .leaf_area_presence_tolerance_m2 = 1e-12,
        .root_litter_partition = &partitions,
    };

    try plant_harvest_runtime.applyWholePlantMortalityResidue(&context, 0);
    var direct_litter_carbon_g_c: f64 = 0;
    var direct_woody_carbon_g_c: f64 = 0;
    var direct_nonwoody_carbon_g_c: f64 = 0;
    for (ledgers[0].direct_litter.woody_carbon_g, ledgers[0].direct_litter.nonwoody_carbon_g) |woody, nonwoody| {
        direct_woody_carbon_g_c += woody;
        direct_nonwoody_carbon_g_c += nonwoody;
        direct_litter_carbon_g_c += woody + nonwoody;
    }
    const litter_carbon_g_c = direct_litter_carbon_g_c + ledgers[0].nonstructural.litter.carbon_g +
        ledgers[0].foliar.litter.carbon_g +
        ledgers[0].nonfoliar.litter.carbon_g +
        ledgers[0].woody.litter.carbon_g;
    try std.testing.expectApproxEqAbs(@as(f64, 5), state.plant_standing_dead_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 8), litter_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 13), state.plant_standing_dead_carbon_g[0] + litter_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), direct_woody_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), direct_nonwoody_carbon_g_c, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), state.plant_seed_storage_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.branch_stalk_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.branch_reserve_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.branch_mobile_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.node_c4_mesophyll_nonstructural_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.branch_symbiont_mobile_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.branch_symbiont_structural_carbon_g[0]);
}

test "GROSUB natural winter-annual branch death recovers mobile reserve and grain" {
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{0});
    defer state.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var partitions = try litter_partition.State.init(std.testing.allocator, 1);
    defer partitions.deinit();
    @memset(partitions.by_plant_and_organ, .{
        .carbon = .{ 0.1, 0.2, 0.3, 0.4 },
        .nitrogen = .{ 0.1, 0.2, 0.3, 0.4 },
        .phosphorus = .{ 0.1, 0.2, 0.3, 0.4 },
    });
    state.branch_mobile_carbon_g[0] = 2;
    state.node_c4_mesophyll_nonstructural_carbon_g[0] = 1;
    state.branch_reserve_carbon_g[0] = 3;
    state.branch_grain_carbon_g[0] = 4;
    state.branch_stalk_carbon_g[0] = 5;
    state.branch_symbiont_structural_carbon_g[0] = 1;
    const science = [_]plant_harvest_runtime.ScienceParameters{.{ .carbon_woody_fraction = .{ 0.25, 0.75 }, .leaf_nitrogen_woody_fraction = .{ 0.25, 0.75 }, .sheath_nitrogen_woody_fraction = .{ 0.25, 0.75 }, .leaf_phosphorus_woody_fraction = .{ 0.25, 0.75 }, .sheath_phosphorus_woody_fraction = .{ 0.25, 0.75 } }};
    var ledgers = [_]plant_harvest_runtime.ProductLedger{.{}};
    var context: plant_harvest_runtime.Context = .{ .canopy_state = &state, .branch_development = &development, .science_by_plant = &science, .products_by_plant = &ledgers, .leaf_area_presence_tolerance_m2 = 1e-12, .root_litter_partition = &partitions };

    try plant_harvest_runtime.applyNaturalDeadBranchResidue(&context, 0, 0, true);
    try std.testing.expectApproxEqAbs(@as(f64, 10), state.plant_seed_storage_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5), state.plant_standing_dead_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), ledgers[0].foliar.litter.carbon_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 16), state.plant_seed_storage_carbon_g[0] + state.plant_standing_dead_carbon_g[0] + ledgers[0].foliar.litter.carbon_g, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), state.branch_mobile_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.node_c4_mesophyll_nonstructural_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.branch_grain_carbon_g[0]);
}

test "non-grazing runtime callback conserves branch carbon through cutting" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{1};
    var canopy_state = try canopy.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer canopy_state.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    canopy_state.sample_leaf_area_m2[0] = 2;
    canopy_state.sample_layer_lower_height_m[0] = 0;
    canopy_state.sample_layer_upper_height_m[0] = 2;
    canopy_state.sample_leaf_carbon_g[0] = 4;
    canopy_state.sample_leaf_nitrogen_g[0] = 0.4;
    canopy_state.sample_leaf_phosphorus_g[0] = 0.04;
    canopy_state.node_leaf_area_m2[0] = 2;
    canopy_state.node_leaf_carbon_g[0] = 4;
    canopy_state.node_leaf_nitrogen_g[0] = 0.4;
    canopy_state.node_leaf_phosphorus_g[0] = 0.04;
    canopy_state.branch_leaf_area_m2[0] = 2;
    canopy_state.branch_leaf_carbon_g[0] = 4;
    canopy_state.branch_leaf_nitrogen_g[0] = 0.4;
    canopy_state.branch_leaf_phosphorus_g[0] = 0.04;
    canopy_state.node_height_m[0] = 2;
    canopy_state.node_sheath_height_m[0] = 1;
    canopy_state.node_sheath_carbon_g[0] = 2;
    canopy_state.node_sheath_nitrogen_g[0] = 0.2;
    canopy_state.node_sheath_phosphorus_g[0] = 0.02;
    canopy_state.branch_sheath_carbon_g[0] = 2;
    canopy_state.branch_sheath_nitrogen_g[0] = 0.2;
    canopy_state.branch_sheath_phosphorus_g[0] = 0.02;
    canopy_state.node_internode_length_m[0] = 2;
    canopy_state.node_internode_carbon_g[0] = 4;
    canopy_state.node_internode_nitrogen_g[0] = 0.4;
    canopy_state.node_internode_phosphorus_g[0] = 0.04;
    canopy_state.branch_stalk_carbon_g[0] = 4;
    canopy_state.branch_stalk_nitrogen_g[0] = 0.4;
    canopy_state.branch_stalk_phosphorus_g[0] = 0.04;
    canopy_state.branch_reserve_carbon_g[0] = 1;
    canopy_state.branch_reserve_nitrogen_g[0] = 0.1;
    canopy_state.branch_reserve_phosphorus_g[0] = 0.01;
    canopy_state.branch_mobile_carbon_g[0] = 2;
    canopy_state.branch_mobile_nitrogen_g[0] = 0.2;
    canopy_state.branch_mobile_phosphorus_g[0] = 0.02;
    const science = [_]plant_harvest_runtime.ScienceParameters{.{ .carbon_woody_fraction = .{ 0.25, 0.75 }, .leaf_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .sheath_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .leaf_phosphorus_woody_fraction = .{ 0.1, 0.9 }, .sheath_phosphorus_woody_fraction = .{ 0.1, 0.9 } }};
    var ledgers = [_]plant_harvest_runtime.ProductLedger{.{}};
    var context: plant_harvest_runtime.Context = .{ .canopy_state = &canopy_state, .branch_development = &development, .science_by_plant = &science, .products_by_plant = &ledgers, .leaf_area_presence_tolerance_m2 = 1.0e-12 };
    const event: management.HarvestEvent = .{ .date = .{ .day = 1, .month = 1, .year = 9999 }, .kind = .above_ground, .termination = .retain, .cutting_height_m_or_lai_fraction = 1, .thinning_fraction_or_consumption_rate = 0, .harvested_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 0 }, .ecosystem_export_fraction = .{ .leaf = 0.8, .nonfoliar = 0.8, .woody = 0.8, .standing_dead = 0 } };
    try plant_harvest_runtime.applyEvent(&context, 0, event);
    const remaining_c = canopy_state.branch_leaf_carbon_g[0] + canopy_state.branch_sheath_carbon_g[0] + canopy_state.branch_stalk_carbon_g[0] + canopy_state.branch_reserve_carbon_g[0] + canopy_state.branch_mobile_carbon_g[0];
    const products_c = ledgers[0].nonstructural.ecosystem_export.carbon_g + ledgers[0].nonstructural.litter.carbon_g + ledgers[0].foliar.ecosystem_export.carbon_g + ledgers[0].foliar.litter.carbon_g + ledgers[0].nonfoliar.ecosystem_export.carbon_g + ledgers[0].nonfoliar.litter.carbon_g + ledgers[0].woody.ecosystem_export.carbon_g + ledgers[0].woody.litter.carbon_g;
    try std.testing.expectApproxEqAbs(13.0, remaining_c + products_c, 1e-12);
    try std.testing.expectApproxEqAbs(2.0, canopy_state.branch_leaf_carbon_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(1.0, canopy_state.branch_sheath_carbon_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(2.0, canopy_state.branch_stalk_carbon_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(1.0, canopy_state.branch_mobile_carbon_g[0], 1e-15);

    canopy_state.branch_grain_carbon_g[0] = 3;
    canopy_state.branch_grain_nitrogen_g[0] = 0.3;
    canopy_state.branch_grain_phosphorus_g[0] = 0.03;
    var high_cut = event;
    high_cut.cutting_height_m_or_lai_fraction = 3;
    try plant_harvest_runtime.applyEvent(&context, 0, high_cut);
    try std.testing.expectApproxEqAbs(
        3,
        canopy_state.branch_grain_carbon_g[0],
        1e-15,
    );
}

test "runtime callback rejects grazing approximation" {
    const event: management.HarvestEvent = .{ .date = .{ .day = 1, .month = 1, .year = 9999 }, .kind = .animal_grazing, .termination = .retain, .cutting_height_m_or_lai_fraction = 0, .thinning_fraction_or_consumption_rate = 0, .harvested_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0 }, .ecosystem_export_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0 } };
    var context: plant_harvest_runtime.Context = undefined;
    try std.testing.expectError(error.GrazingRequiresDemandDrivenKernel, plant_harvest_runtime.applyEvent(&context, 0, event));
}

test "GROSUB grazing distributes host and symbiont pools by branch leaf sheath mass" {
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{2}, &.{ 1, 1 }, &.{ 1, 1 });
    defer state.deinit();
    var layers = try canopy_layers.State.init(std.testing.allocator, 1, 1, 1, 1, 1, &state);
    defer layers.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 2);
    defer development.deinit();
    for (0..2) |branch| {
        const leaf_g_c: f64 = if (branch == 0) 3 else 1;
        state.sample_leaf_area_m2[branch] = leaf_g_c;
        state.sample_exposed_leaf_area_m2[branch] = leaf_g_c;
        state.sample_leaf_carbon_g[branch] = leaf_g_c;
        state.node_leaf_area_m2[branch] = leaf_g_c;
        state.node_leaf_carbon_g[branch] = leaf_g_c;
        state.branch_leaf_area_m2[branch] = leaf_g_c;
        state.branch_leaf_carbon_g[branch] = leaf_g_c;
        layers.node_leaf_area_m2[branch] = leaf_g_c;
        layers.node_leaf_carbon_g[branch] = leaf_g_c;
        state.branch_mobile_carbon_g[branch] = if (branch == 0) 1 else 3;
        state.branch_symbiont_mobile_carbon_g[branch] = 1;
        state.branch_symbiont_structural_carbon_g[branch] = 2;
    }
    state.plant_total_shoot_carbon_g[0] = 14;
    state.plant_uptake_growth_temperature_response[0] = 1;
    state.plant_mobile_carbon_concentration_g_per_g[0] = 1;
    state.plant_symbiont_mobile_carbon_concentration_g_per_g[0] = 1;
    const science = [_]plant_harvest_runtime.ScienceParameters{.{ .carbon_woody_fraction = .{ 0.25, 0.75 }, .leaf_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .sheath_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .leaf_phosphorus_woody_fraction = .{ 0.1, 0.9 }, .sheath_phosphorus_woody_fraction = .{ 0.1, 0.9 } }};
    var ledgers = [_]plant_harvest_runtime.ProductLedger{.{}};
    var context: plant_harvest_runtime.Context = .{ .canopy_state = &state, .canopy_layer_state = &layers, .branch_development = &development, .science_by_plant = &science, .products_by_plant = &ledgers, .leaf_area_presence_tolerance_m2 = 1e-12 };
    const removed_g_c = try plant_harvest_runtime.applyGrazingEvent(&context, 0, .{
        .date = .{ .day = 1, .month = 1, .year = 9999 },
        .kind = .animal_grazing,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 96,
        .thinning_fraction_or_consumption_rate = 1,
        .harvested_fraction = .{ .leaf = 1, .nonfoliar = 0, .woody = 0, .standing_dead = 0 },
        .ecosystem_export_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 0 },
    }, 14, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), state.branch_mobile_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.75), state.branch_mobile_carbon_g[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), state.branch_symbiont_mobile_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), state.branch_symbiont_mobile_carbon_g[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.branch_symbiont_structural_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), state.branch_symbiont_structural_carbon_g[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5), removed_g_c, 1e-12);
}

test "grazing state_update state_updates manure mineral nutrients and export without examples" {
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer state.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var partitions = try litter_partition.State.init(std.testing.allocator, 1);
    defer partitions.deinit();
    const uniform: litter_partition.ElementFractions = .{
        .carbon = .{ 0.25, 0.25, 0.25, 0.25 },
        .nitrogen = .{ 0.25, 0.25, 0.25, 0.25 },
        .phosphorus = .{ 0.25, 0.25, 0.25, 0.25 },
    };
    @memset(partitions.by_plant_and_organ, uniform);
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 10 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var surface = try soil_organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var nutrients = try surface_nutrients.State.init(std.testing.allocator, 1, soil_organic.substrate_count);
    defer nutrients.deinit();
    var daily_manure_c = [_]f64{0};
    var daily_manure_n = [_]f64{0};
    var daily_manure_p = [_]f64{0};
    var shoot_litter_carbon_g_c = [_]f64{0};
    var shoot_litter_nitrogen_g_n = [_]f64{0};
    var shoot_litter_phosphorus_g_p = [_]f64{0};
    var hourly_manure_products = [_]grazing_manure.Products{.{}};
    const science = [_]plant_harvest_runtime.ScienceParameters{.{ .carbon_woody_fraction = .{ 0, 1 }, .leaf_nitrogen_woody_fraction = .{ 0, 1 }, .sheath_nitrogen_woody_fraction = .{ 0, 1 }, .leaf_phosphorus_woody_fraction = .{ 0, 1 }, .sheath_phosphorus_woody_fraction = .{ 0, 1 } }};
    var ledgers = [_]plant_harvest_runtime.ProductLedger{.{}};
    ledgers[0].direct_litter.nonwoody_carbon_g[0] = 2;
    ledgers[0].direct_litter.nonwoody_nitrogen_g[0] = 0.2;
    ledgers[0].direct_litter.nonwoody_phosphorus_g[0] = 0.02;
    ledgers[0].manure = try grazing_manure.partition(.animal_grazing, .{ .carbon_g = 10, .nitrogen_g = 1, .phosphorus_g = 0.2 });
    const expected_hourly_manure = ledgers[0].manure;
    ledgers[0].standing_dead_export = .{ .carbon_g = 1, .nitrogen_g = 0.1, .phosphorus_g = 0.01 };
    var context: plant_harvest_runtime.Context = .{
        .canopy_state = &state,
        .branch_development = &development,
        .science_by_plant = &science,
        .products_by_plant = &ledgers,
        .root_litter_partition = &partitions,
        .surface_organic_state = &surface,
        .surface_nutrient_state = &nutrients,
        .daily_manure_carbon_input_g_c = &daily_manure_c,
        .daily_manure_nitrogen_input_g_n = &daily_manure_n,
        .daily_manure_phosphorus_input_g_p = &daily_manure_p,
        .hourly_manure_products_by_plant = &hourly_manure_products,
        .shoot_litter_carbon_g_c_by_plant = &shoot_litter_carbon_g_c,
        .shoot_litter_nitrogen_g_n_by_plant = &shoot_litter_nitrogen_g_n,
        .shoot_litter_phosphorus_g_p_by_plant = &shoot_litter_phosphorus_g_p,
        .grid = &grid,
        .leaf_area_presence_tolerance_m2 = 1e-12,
    };
    const exported = try plant_harvest_runtime.publishPlantProducts(&context, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 1), exported.carbon_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), shoot_litter_carbon_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), shoot_litter_nitrogen_g_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), shoot_litter_phosphorus_g_p[0], 1e-12);
    var manure: canopy.ElementalMass = .{};
    for (0..4) |fraction| {
        const index = (2 * soil_organic.structural_fraction_count) + fraction;
        manure.carbon_g += surface.structural[index].carbon_g_c;
        manure.nitrogen_g += surface.structural[index].nitrogen_g_n;
        manure.phosphorus_g += surface.structural[index].phosphorus_g_p;
    }
    try std.testing.expectApproxEqAbs(@as(f64, 10), manure.carbon_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), manure.nitrogen_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), manure.phosphorus_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5 / 14.0), nutrients.pending_surface_ammonium_mol_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1 / 31.0), nutrients.pending_surface_phosphate_mol_p[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10), daily_manure_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), daily_manure_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), daily_manure_p[0], 1e-12);
    try std.testing.expectEqual(
        expected_hourly_manure,
        hourly_manure_products[0],
    );
    try std.testing.expectEqual(plant_harvest_runtime.ProductLedger{}, ledgers[0]);

    const surface_before = try std.testing.allocator.dupe(soil_organic.ElementPool, surface.structural);
    defer std.testing.allocator.free(surface_before);
    shoot_litter_phosphorus_g_p[0] = std.math.floatMax(f64);
    ledgers[0].direct_litter.nonwoody_phosphorus_g[0] = std.math.floatMax(f64);
    try std.testing.expectError(
        error.InvalidPlantHarvestProduct,
        plant_harvest_runtime.publishPlantProducts(&context, 0),
    );
    try std.testing.expectEqualSlices(soil_organic.ElementPool, surface_before, surface.structural);
    try std.testing.expectEqual(
        std.math.floatMax(f64),
        ledgers[0].direct_litter.nonwoody_phosphorus_g[0],
    );
}
