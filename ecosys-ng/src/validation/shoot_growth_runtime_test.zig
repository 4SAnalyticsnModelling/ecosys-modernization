//! Tests for `shoot_growth_runtime.zig`.
//!
//! Extracted verbatim so the module beside it contains only the model
//! code. Tests that use private declarations of that module stay there,
//! since a sibling file can only reach `pub` declarations.

const CarbonExchange = @import("../canopy/photosynthesis/carbon_exchange.zig").State;
const CellRange = @import("../core/compute.zig").CellRange;
const branch_reserve_equilibration = @import("../plant/growth/branch_reserve_equilibration.zig");
const canopy_module = @import("../canopy/photosynthesis/photosynthesis.zig");
const development_module = @import("../plant/lifecycle/phenology.zig");
const dormancy_module = @import("../plant/lifecycle/dormancy.zig");
const end_of_season_reproductive_turnover = @import("../plant/growth/end_of_season_reproductive_turnover.zig");
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");
const growth_temperature_module = @import("../plant/response/growth_temperature.zig");
const leaf_structural_nutrient_recycling = @import("../canopy/leaf/structural_nutrient_recycling.zig");
const litter_partition_module = @import("../plant/partition/litter.zig");
const main_stalk_death_propagation = @import("../plant/growth/main_stalk_death_propagation.zig");
const metabolism_module = @import("../plant/growth/shoot_growth_metabolism.zig");
const partition_module = @import("../plant/partition/organ.zig");
const root_system_module = @import("../plant/root/plant_root_system.zig");
const root_uptake_module = @import("../plant/root/plant_root_nutrient_uptake.zig");
const seasonal_growth_flag_reset = @import("../plant/growth/seasonal_growth_flag_reset.zig");
const seasonal_stalk_standing_dead_turnover = @import("../plant/growth/seasonal_stalk_standing_dead_turnover.zig");
const soil_exchange_module = @import("../plant/exchange/soil.zig");
const stages_module = @import("../plant/lifecycle/growth_stages.zig");
const stalk_growing_node_window = @import("../plant/growth/stalk_growing_node_window.zig");
const std = @import("std");
const storage_carbon_branch_survival = @import("../plant/growth/storage_carbon_branch_survival.zig");
const symbiosis_module = @import("../canopy/symbiosis/plant_symbiotic_fixation.zig");
const traits_module = @import("../state/plant_traits.zig");
const shoot_growth_runtime = @import("../plant/growth/shoot_growth_runtime.zig");
test "GROSUB self-seeding reproductive turnover retains grain and litters husk and ear" {
    var canopy = try canopy_module.State.init(std.testing.allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer canopy.deinit();
    canopy.branch_husk_carbon_g[0] = 2;
    canopy.branch_husk_nitrogen_g[0] = 0.2;
    canopy.branch_husk_phosphorus_g[0] = 0.02;
    canopy.branch_ear_carbon_g[0] = 4;
    canopy.branch_ear_nitrogen_g[0] = 0.4;
    canopy.branch_ear_phosphorus_g[0] = 0.04;
    canopy.branch_grain_carbon_g[0] = 8;
    canopy.branch_grain_nitrogen_g[0] = 0.8;
    canopy.branch_grain_phosphorus_g[0] = 0.08;
    canopy.branch_potential_seed_site_count[0] = 100;
    canopy.branch_seed_count[0] = 80;
    canopy.branch_individual_seed_carbon_g[0] = 0.1;
    var products: canopy_module.SenescenceProducts = .{};
    try shoot_growth_runtime.state_updateEndOfSeasonReproductiveTurnover(&canopy, 0, 0, 0.25, true, .{
        .carbon = .{ 0.1, 0.2, 0.3, 0.4 },
        .nitrogen = .{ 0.1, 0.2, 0.3, 0.4 },
        .phosphorus = .{ 0.1, 0.2, 0.3, 0.4 },
    }, &products);
    try std.testing.expectApproxEqAbs(@as(f64, 2), canopy.plant_seed_storage_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), products.nonwoody_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6), canopy.branch_grain_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 60), canopy.branch_seed_count[0], 1e-12);
    const remaining_and_transferred_carbon_g_c =
        canopy.branch_husk_carbon_g[0] + canopy.branch_ear_carbon_g[0] +
        canopy.branch_grain_carbon_g[0] + canopy.plant_seed_storage_carbon_g[0] +
        products.nonwoody_carbon_g[0] + products.nonwoody_carbon_g[1] +
        products.nonwoody_carbon_g[2] + products.nonwoody_carbon_g[3];
    try std.testing.expectApproxEqAbs(@as(f64, 14), remaining_and_transferred_carbon_g_c, 1e-12);
}

test "GROSUB DEATHC storage backstop kills perennial but defers deciduous annual" {
    var canopy = try canopy_module.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{0});
    defer canopy.deinit();
    var growth = try stages_module.State.init(std.testing.allocator, &.{1});
    defer growth.deinit();
    var development = try development_module.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var dormant = try dormancy_module.RuntimeState.init(std.testing.allocator, 1);
    defer dormant.deinit();
    canopy.branch_stalk_carbon_g[0] = 3;
    canopy.plant_seed_storage_carbon_g[0] = 2;

    try std.testing.expect(!try shoot_growth_runtime.state_updateSenescenceStorageBackstop(&canopy, &growth, &development, &dormant, 0, 0, 1, true, false, 20, 1e-12));
    try std.testing.expectApproxEqAbs(@as(f64, 1), canopy.plant_seed_storage_carbon_g[0], 1e-12);
    try std.testing.expect(!growth.branches[0].dead);

    try std.testing.expect(try shoot_growth_runtime.state_updateSenescenceStorageBackstop(&canopy, &growth, &development, &dormant, 0, 0, 2, true, false, 20, 1e-12));
    try std.testing.expectEqual(@as(f64, 0), canopy.plant_seed_storage_carbon_g[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 2), canopy.branch_stalk_carbon_g[0], 1e-12);
    try std.testing.expect(growth.branches[0].dead);
    try std.testing.expect(development.dead[0]);

    growth.branches[0].dead = false;
    development.dead[0] = false;
    canopy.branch_stalk_carbon_g[0] = 3;
    canopy.plant_seed_storage_carbon_g[0] = 0;
    try std.testing.expect(!try shoot_growth_runtime.state_updateSenescenceStorageBackstop(&canopy, &growth, &development, &dormant, 0, 0, 1, false, false, 20, 1e-12));
    try std.testing.expectApproxEqAbs(@as(f64, 20.5), dormant.branches[0].accumulated_leafoff_h, 1e-12);
    try std.testing.expect(!growth.branches[0].dead);

    canopy.branch_stalk_carbon_g[0] = 0.25;
    canopy.plant_seed_storage_carbon_g[0] = 0.5;
    const leafoff_before = dormant.branches[0].accumulated_leafoff_h;
    try std.testing.expectError(error.StorageCarbonSurvivalStalkOverdraw, shoot_growth_runtime.state_updateSenescenceStorageBackstop(&canopy, &growth, &development, &dormant, 0, 0, 1, false, false, 20, 1e-12));
    try std.testing.expectEqual(@as(f64, 0.5), canopy.plant_seed_storage_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0.25), canopy.branch_stalk_carbon_g[0]);
    try std.testing.expectEqual(leafoff_before, dormant.branches[0].accumulated_leafoff_h);
}

test "GROSUB natural dead branch reset clears transient stages and preserves runtime controls" {
    var growth = try stages_module.State.init(std.testing.allocator, &.{1});
    defer growth.deinit();
    var development = try development_module.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var dormant = try dormancy_module.RuntimeState.init(std.testing.allocator, 1);
    defer dormant.deinit();
    growth.branches[0] = .{ .dead = true, .branch_order = 3, .emergence_day = 120, .anthesis_day = 180, .appeared_leaf_count = 9, .accumulated_reproductive_stage = 2 };
    development.maturity_group[0] = 8;
    development.initial_reproductive_stage[0] = 1.5;
    development.perennial_node_scaling[0] = 200;
    development.maximum_concurrently_growing_nodes[0] = 24;
    development.stage_day[4] = 180;
    development.remobilization_progress_h[0] = 30;
    development.dead[0] = true;
    dormant.branches[0].accumulated_leafout_h = 10;
    dormant.branches[0].accumulated_leafoff_h = 20;
    dormant.branches[0].phenological_remobilization_enabled = true;

    try shoot_growth_runtime.resetNaturalDeadBranch(&growth, &development, &dormant, 0);
    try std.testing.expect(growth.branches[0].dead);
    try std.testing.expectEqual(@as(usize, 3), growth.branches[0].branch_order);
    try std.testing.expectEqual(@as(f64, 1.5), growth.branches[0].initiated_node_count);
    try std.testing.expectEqual(@as(u16, 0), growth.branches[0].anthesis_day);
    try std.testing.expectEqual(@as(f64, 8), development.maturity_group[0]);
    try std.testing.expectEqual(@as(usize, 24), development.maximum_concurrently_growing_nodes[0]);
    try std.testing.expectEqual(@as(u32, 0), development.stage_day[4]);
    try std.testing.expect(development.dead[0]);
    try std.testing.expectEqual(@as(f64, 0), dormant.branches[0].accumulated_leafoff_h);
    try std.testing.expect(dormant.branches[0].leafout_disabled);
}

test "GROSUB seasonal stalk turnover conserves kinetic standing dead mass" {
    var canopy = try canopy_module.State.init(std.testing.allocator, 1, 1, &.{1}, &.{2}, &.{ 0, 0 });
    defer canopy.deinit();
    canopy.branch_stalk_carbon_g[0] = 10;
    canopy.branch_stalk_nitrogen_g[0] = 1;
    canopy.branch_stalk_phosphorus_g[0] = 0.1;
    canopy.branch_senescing_stalk_carbon_g[0] = 8;
    canopy.branch_senescing_stalk_nitrogen_g[0] = 0.8;
    canopy.branch_senescing_stalk_phosphorus_g[0] = 0.08;
    canopy.node_internode_carbon_g[0] = 3;
    canopy.node_internode_carbon_g[1] = 5;
    canopy.node_internode_nitrogen_g[0] = 0.3;
    canopy.node_internode_nitrogen_g[1] = 0.5;
    canopy.node_internode_phosphorus_g[0] = 0.03;
    canopy.node_internode_phosphorus_g[1] = 0.05;
    canopy.node_internode_length_m[0] = 1;
    canopy.node_internode_length_m[1] = 2;
    const kinetics: litter_partition_module.ElementFractions = .{
        .carbon = .{ 0.1, 0.2, 0.3, 0.4 },
        .nitrogen = .{ 0.1, 0.2, 0.3, 0.4 },
        .phosphorus = .{ 0.1, 0.2, 0.3, 0.4 },
    };
    try shoot_growth_runtime.state_updateSeasonalStalkToStandingDead(&canopy, 0, 0, 0.25, kinetics);
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), canopy.branch_stalk_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6), canopy.branch_senescing_stalk_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), canopy.plant_standing_dead_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), canopy.plant_standing_dead_carbon_by_kinetic_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.25), canopy.node_internode_length_m[0] + canopy.node_internode_length_m[1], 1e-12);
    var kinetic_carbon_g_c: f64 = 0;
    for (canopy.plant_standing_dead_carbon_by_kinetic_g[0..4]) |value| kinetic_carbon_g_c += value;
    try std.testing.expectApproxEqAbs(@as(f64, 10), canopy.branch_stalk_carbon_g[0] + kinetic_carbon_g_c, 1e-12);
}

test "GROSUB interbranch mobile exchange uses eligible branch snapshots and conserves C N P" {
    var canopy = try canopy_module.State.init(std.testing.allocator, 1, 1, &.{3}, &.{ 1, 1, 1 }, &.{ 0, 0, 0 });
    defer canopy.deinit();
    var growth = try stages_module.State.init(std.testing.allocator, &.{3});
    defer growth.deinit();
    var development = try development_module.BranchDevelopmentState.init(std.testing.allocator, 3);
    defer development.deinit();
    @memset(development.remobilization_progress_h, 200);
    growth.branches[2].dead = true;
    canopy.branch_leaf_carbon_g[0] = 1;
    canopy.branch_leaf_carbon_g[1] = 3;
    canopy.branch_leaf_carbon_g[2] = 2;
    canopy.branch_mobile_carbon_g[0] = 10;
    canopy.branch_mobile_carbon_g[1] = 2;
    canopy.branch_mobile_carbon_g[2] = 5;
    canopy.branch_mobile_nitrogen_g[0] = 0.5;
    canopy.branch_mobile_nitrogen_g[1] = 1;
    canopy.branch_mobile_nitrogen_g[2] = 2;
    canopy.branch_mobile_phosphorus_g[0] = 0.05;
    canopy.branch_mobile_phosphorus_g[1] = 0.2;
    canopy.branch_mobile_phosphorus_g[2] = 0.4;
    const before_c = canopy.branch_mobile_carbon_g[0] + canopy.branch_mobile_carbon_g[1];
    const before_n = canopy.branch_mobile_nitrogen_g[0] + canopy.branch_mobile_nitrogen_g[1];
    const before_p = canopy.branch_mobile_phosphorus_g[0] + canopy.branch_mobile_phosphorus_g[1];

    try shoot_growth_runtime.equilibratePlantBranchMobilePools(&canopy, &growth, &development, try canopy.branchRange(0), 138.4, shoot_growth_runtime.sourceBranchMobileExchangeParameters(), 1, 1.0e-12);

    try std.testing.expectApproxEqAbs(before_c, canopy.branch_mobile_carbon_g[0] + canopy.branch_mobile_carbon_g[1], 1.0e-15);
    try std.testing.expectApproxEqAbs(before_n, canopy.branch_mobile_nitrogen_g[0] + canopy.branch_mobile_nitrogen_g[1], 1.0e-15);
    try std.testing.expectApproxEqAbs(before_p, canopy.branch_mobile_phosphorus_g[0] + canopy.branch_mobile_phosphorus_g[1], 1.0e-15);
    try std.testing.expect(canopy.branch_mobile_carbon_g[1] > 2);
    try std.testing.expectEqual(@as(f64, 5), canopy.branch_mobile_carbon_g[2]);
    try std.testing.expectEqual(@as(f64, 2), canopy.branch_mobile_nitrogen_g[2]);
}

test "interbranch mobile exchange late overdraw leaves every branch unchanged" {
    var canopy = try canopy_module.State.init(std.testing.allocator, 1, 1, &.{2}, &.{ 1, 1 }, &.{ 0, 0 });
    defer canopy.deinit();
    var growth = try stages_module.State.init(std.testing.allocator, &.{2});
    defer growth.deinit();
    var development = try development_module.BranchDevelopmentState.init(std.testing.allocator, 2);
    defer development.deinit();
    @memset(development.remobilization_progress_h, 200);
    canopy.branch_leaf_carbon_g[0] = 3;
    canopy.branch_leaf_carbon_g[1] = 1;
    canopy.branch_mobile_carbon_g[0] = 2;
    canopy.branch_mobile_carbon_g[1] = 10;
    const before = [_]f64{ canopy.branch_mobile_carbon_g[0], canopy.branch_mobile_carbon_g[1] };

    try std.testing.expectError(
        error.BranchMobileExchangeExhaustedPool,
        shoot_growth_runtime.equilibratePlantBranchMobilePools(
            &canopy,
            &growth,
            &development,
            try canopy.branchRange(0),
            100,
            .{ .carbon_exchange_fraction_per_h = 1, .nutrient_exchange_fraction_per_h = 1, .remobilization_redistribution_fraction_per_h = 0 },
            2,
            0,
        ),
    );
    try std.testing.expectEqualSlices(f64, &before, canopy.branch_mobile_carbon_g);
}

test "GROSUB interbranch mobile exchange uses strict ATRP and ZEROP gates" {
    var canopy = try canopy_module.State.init(std.testing.allocator, 1, 1, &.{2}, &.{ 1, 1 }, &.{ 0, 0 });
    defer canopy.deinit();
    var growth = try stages_module.State.init(std.testing.allocator, &.{2});
    defer growth.deinit();
    var development = try development_module.BranchDevelopmentState.init(std.testing.allocator, 2);
    defer development.deinit();
    @memset(development.remobilization_progress_h, 10);
    canopy.branch_leaf_carbon_g[0] = 1;
    canopy.branch_leaf_carbon_g[1] = 3;
    canopy.branch_mobile_carbon_g[0] = 10;
    canopy.branch_mobile_carbon_g[1] = 2;

    try shoot_growth_runtime.equilibratePlantBranchMobilePools(
        &canopy,
        &growth,
        &development,
        try canopy.branchRange(0),
        10,
        shoot_growth_runtime.sourceBranchMobileExchangeParameters(),
        1,
        0,
    );
    try std.testing.expectEqual(@as(f64, 10), canopy.branch_mobile_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 2), canopy.branch_mobile_carbon_g[1]);

    @memset(development.remobilization_progress_h, 11);
    try shoot_growth_runtime.equilibratePlantBranchMobilePools(
        &canopy,
        &growth,
        &development,
        try canopy.branchRange(0),
        10,
        shoot_growth_runtime.sourceBranchMobileExchangeParameters(),
        1,
        12,
    );
    try std.testing.expectEqual(@as(f64, 10), canopy.branch_mobile_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 2), canopy.branch_mobile_carbon_g[1]);
}

test "GROSUB remobilization redistributes mobile pools only from main to lateral branch" {
    var canopy = try canopy_module.State.init(std.testing.allocator, 1, 1, &.{2}, &.{ 1, 1 }, &.{ 0, 0 });
    defer canopy.deinit();
    canopy.branch_mobile_carbon_g[0] = 10;
    canopy.branch_mobile_carbon_g[1] = 2;
    canopy.branch_mobile_nitrogen_g[0] = 0.2;
    canopy.branch_mobile_nitrogen_g[1] = 0.6;
    canopy.branch_mobile_phosphorus_g[0] = 0.1;
    canopy.branch_mobile_phosphorus_g[1] = 0;

    try shoot_growth_runtime.redistributeMainBranchMobileDuringRemobilization(&canopy, 0, 1, 1, shoot_growth_runtime.sourceBranchMobileExchangeParameters(), 1);

    try std.testing.expectApproxEqAbs(@as(f64, 12), canopy.branch_mobile_carbon_g[0] + canopy.branch_mobile_carbon_g[1], 1.0e-15);
    try std.testing.expect(canopy.branch_mobile_carbon_g[1] > 2);
    try std.testing.expectEqual(@as(f64, 0.2), canopy.branch_mobile_nitrogen_g[0]);
    try std.testing.expectEqual(@as(f64, 0.6), canopy.branch_mobile_nitrogen_g[1]);
    try std.testing.expect(canopy.branch_mobile_phosphorus_g[1] > 0);
}
