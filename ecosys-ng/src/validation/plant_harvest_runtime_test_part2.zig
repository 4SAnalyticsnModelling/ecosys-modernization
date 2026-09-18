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
test "source-order tillage population reduction scales all population fields" {
    const result = try plant_harvest_runtime.sourceOrderTillagePopulationReduction(.{
        .hour_of_day = 12,
        .local_solar_noon_h = 12.75,
        .biomass_turnover_type = 0,
        .root_profile_type = 2,
        .current_day_of_year = 151,
        .current_year = 2001,
        .planting_day_of_year = 100,
        .planting_year = 2001,
        .tillage_code = 8,
        .is_first_plant_population = true,
        .remaining_fraction = 0.25,
        .zero_population_threshold = 1.0e-12,
        .state = .{
            .living_population_per_m2 = 8,
            .living_population_count = 40,
            .standing_dead_population_count = 12,
            .canopy_radiation_fraction = 0.8,
        },
    });
    try std.testing.expect(result.applied);
    try std.testing.expect(result.clear_leaf_sheath_and_sapwood_totals);
    try std.testing.expect(!result.terminate_living_branches);
    try std.testing.expectEqual(@as(f64, 2), result.state.living_population_per_m2);
    try std.testing.expectEqual(@as(f64, 10), result.state.living_population_count);
    try std.testing.expectEqual(@as(f64, 3), result.state.standing_dead_population_count);
    try std.testing.expectEqual(@as(f64, 0.2), result.state.canopy_radiation_fraction);
}

test "source-order tillage population selector preserves crop and date gates" {
    const base: plant_harvest_runtime.SourceOrderTillagePopulationInput = .{
        .hour_of_day = 11,
        .local_solar_noon_h = 11.4,
        .biomass_turnover_type = 1,
        .root_profile_type = 1,
        .current_day_of_year = 200,
        .current_year = 2000,
        .planting_day_of_year = 100,
        .planting_year = 2001,
        .tillage_code = 15,
        .is_first_plant_population = true,
        .remaining_fraction = 0,
        .zero_population_threshold = 1.0e-9,
        .state = .{
            .living_population_per_m2 = 1,
            .living_population_count = 1,
            .standing_dead_population_count = 1,
            .canopy_radiation_fraction = 1,
        },
    };
    try std.testing.expect(!(try plant_harvest_runtime.sourceOrderTillagePopulationReduction(base)).applied);

    var second_population = base;
    second_population.is_first_plant_population = false;
    const source_date_result = try plant_harvest_runtime.sourceOrderTillagePopulationReduction(second_population);
    try std.testing.expect(source_date_result.applied);
    try std.testing.expect(source_date_result.terminate_living_branches);

    var planting_date = second_population;
    planting_date.current_day_of_year = planting_date.planting_day_of_year;
    planting_date.current_year = planting_date.planting_year;
    try std.testing.expect(!(try plant_harvest_runtime.sourceOrderTillagePopulationReduction(planting_date)).applied);
}

test "source-order tillage branch litter conserves every element" {
    const kinetics: litter_partition.ElementFractions = .{
        .carbon = .{ 0.1, 0.2, 0.3, 0.4 },
        .nitrogen = .{ 0.4, 0.3, 0.2, 0.1 },
        .phosphorus = .{ 0.25, 0.25, 0.25, 0.25 },
    };
    const composition: plant_harvest_runtime.TillageElementComposition = .{
        .carbon = .{ 0.25, 0.75 },
        .nitrogen = .{ 0.4, 0.6 },
        .phosphorus = .{ 0.5, 0.5 },
    };
    const pools: plant_harvest_runtime.SourceOrderTillageBranchPools = .{
        .host_mobile = .{ .carbon_g = 1, .nitrogen_g = 0.1, .phosphorus_g = 0.01 },
        .symbiont_mobile = .{ .carbon_g = 2, .nitrogen_g = 0.2, .phosphorus_g = 0.02 },
        .c4_mobile_carbon_g_c = 0.5,
        .stalk_reserve = .{ .carbon_g = 3, .nitrogen_g = 0.3, .phosphorus_g = 0.03 },
        .leaf = .{ .carbon_g = 4, .nitrogen_g = 0.4, .phosphorus_g = 0.04 },
        .symbiont_structural = .{ .carbon_g = 5, .nitrogen_g = 0.5, .phosphorus_g = 0.05 },
        .sheath = .{ .carbon_g = 6, .nitrogen_g = 0.6, .phosphorus_g = 0.06 },
        .husk = .{ .carbon_g = 7, .nitrogen_g = 0.7, .phosphorus_g = 0.07 },
        .ear = .{ .carbon_g = 8, .nitrogen_g = 0.8, .phosphorus_g = 0.08 },
        .grain = .{ .carbon_g = 9, .nitrogen_g = 0.9, .phosphorus_g = 0.09 },
        .stalk = .{ .carbon_g = 10, .nitrogen_g = 1, .phosphorus_g = 0.1 },
    };
    const result = try plant_harvest_runtime.sourceOrderTillageBranchLitter(.{
        .remaining_fraction = 0.4,
        .winter_annual = true,
        .pools = pools,
        .leaf_composition = composition,
        .sheath_composition = composition,
        .stalk_composition = composition,
        .nonstructural_kinetics = kinetics,
        .foliar_kinetics = kinetics,
        .nonfoliar_kinetics = kinetics,
        .stalk_kinetics = kinetics,
        .coarse_wood_kinetics = kinetics,
    });
    var litter_carbon_g_c: f64 = 0;
    var litter_nitrogen_g_n: f64 = 0;
    var litter_phosphorus_g_p: f64 = 0;
    for (0..litter_partition.kinetic_component_count) |kinetic| {
        litter_carbon_g_c += result.litter.woody_carbon_g[kinetic] + result.litter.nonwoody_carbon_g[kinetic];
        litter_nitrogen_g_n += result.litter.woody_nitrogen_g[kinetic] + result.litter.nonwoody_nitrogen_g[kinetic];
        litter_phosphorus_g_p += result.litter.woody_phosphorus_g[kinetic] + result.litter.nonwoody_phosphorus_g[kinetic];
    }
    try std.testing.expectApproxEqAbs(0.6 * 55.5, litter_carbon_g_c + result.seasonal_storage.carbon_g, 1.0e-12);
    try std.testing.expectApproxEqAbs(0.6 * 5.5, litter_nitrogen_g_n + result.seasonal_storage.nitrogen_g, 1.0e-12);
    try std.testing.expectApproxEqAbs(0.6 * 0.55, litter_phosphorus_g_p + result.seasonal_storage.phosphorus_g, 1.0e-12);
    try std.testing.expectApproxEqAbs(0.6 * pools.grain.carbon_g, result.seasonal_storage.carbon_g, 1.0e-12);
}

test "source-order tillage routes non-winter grain to nonwoody litter" {
    const one_hot: litter_partition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const zero_mass: canopy.ElementalMass = .{};
    const result = try plant_harvest_runtime.sourceOrderTillageBranchLitter(.{
        .remaining_fraction = 0.25,
        .winter_annual = false,
        .pools = .{
            .host_mobile = zero_mass,
            .symbiont_mobile = zero_mass,
            .c4_mobile_carbon_g_c = 0,
            .stalk_reserve = zero_mass,
            .leaf = zero_mass,
            .symbiont_structural = zero_mass,
            .sheath = zero_mass,
            .husk = zero_mass,
            .ear = zero_mass,
            .grain = .{ .carbon_g = 4, .nitrogen_g = 0.4, .phosphorus_g = 0.04 },
            .stalk = zero_mass,
        },
        .leaf_composition = .{ .carbon = .{ 0, 1 }, .nitrogen = .{ 0, 1 }, .phosphorus = .{ 0, 1 } },
        .sheath_composition = .{ .carbon = .{ 0, 1 }, .nitrogen = .{ 0, 1 }, .phosphorus = .{ 0, 1 } },
        .stalk_composition = .{ .carbon = .{ 0, 1 }, .nitrogen = .{ 0, 1 }, .phosphorus = .{ 0, 1 } },
        .nonstructural_kinetics = one_hot,
        .foliar_kinetics = one_hot,
        .nonfoliar_kinetics = one_hot,
        .stalk_kinetics = one_hot,
        .coarse_wood_kinetics = one_hot,
    });
    try std.testing.expectEqual(@as(f64, 3), result.litter.nonwoody_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), result.seasonal_storage.carbon_g);
}

test "source-order tillage retains complete branch state over runtime extents" {
    const mass: canopy.ElementalMass = .{ .carbon_g = 8, .nitrogen_g = 4, .phosphorus_g = 2 };
    var scalar: plant_harvest_runtime.SourceOrderTillageBranchScalarState = .{
        .host_mobile = mass,
        .c4_mobile_carbon_g_c = 8,
        .symbiont_mobile = mass,
        .total_shoot = mass,
        .leaf = mass,
        .symbiont_structural = mass,
        .sheath = mass,
        .stalk = mass,
        .sapwood_carbon_g_c = 8,
        .stalk_reserve = mass,
        .husk = mass,
        .ear = mass,
        .grain = mass,
        .potential_seed_site_count = 8,
        .seed_count = 8,
        .individual_seed_carbon_g_c = 3,
        .leaf_area_m2 = 8,
        .stalk_total = mass,
    };
    var node_values: [16][3]f64 = @splat(.{ 2, 4, 6 });
    var sample_values: [4][2]f64 = @splat(.{ 10, 12 });
    const result = try plant_harvest_runtime.sourceOrderRetainTillageBranchState(&scalar, .{
        .c3_mobile_carbon_g_c = &node_values[0],
        .c4_mobile_carbon_g_c = &node_values[1],
        .carbon_dioxide_g_c = &node_values[2],
        .bicarbonate_g_c = &node_values[3],
        .leaf_area_m2 = &node_values[4],
        .growing_leaf_carbon_g_c = &node_values[5],
        .senescing_leaf_carbon_g_c = &node_values[6],
        .growing_sheath_carbon_g_c = &node_values[7],
        .senescing_sheath_carbon_g_c = &node_values[8],
        .growing_node_carbon_g_c = &node_values[9],
        .growing_leaf_nitrogen_g_n = &node_values[10],
        .growing_sheath_nitrogen_g_n = &node_values[11],
        .growing_node_nitrogen_g_n = &node_values[12],
        .growing_leaf_phosphorus_g_p = &node_values[13],
        .growing_sheath_phosphorus_g_p = &node_values[14],
        .growing_node_phosphorus_g_p = &node_values[15],
    }, .{
        .leaf_area_m2 = &sample_values[0],
        .growing_leaf_carbon_g_c = &sample_values[1],
        .growing_leaf_nitrogen_g_n = &sample_values[2],
        .growing_leaf_phosphorus_g_p = &sample_values[3],
    }, 0.25);

    try std.testing.expectEqual(@as(f64, 2), scalar.host_mobile.carbon_g);
    try std.testing.expectEqual(@as(f64, 3), scalar.individual_seed_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 4), result.leaf_sheath_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 2), result.sapwood_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 2), node_values[0][0]);
    try std.testing.expectEqual(@as(f64, 1), node_values[0][1]);
    try std.testing.expectEqual(@as(f64, 0.5), node_values[4][0]);
    try std.testing.expectEqual(@as(f64, 2.5), sample_values[0][0]);
}

test "source-order tillage standing dead repartitions and conserves C N P" {
    const stalk_kinetics: litter_partition.ElementFractions = .{
        .carbon = .{ 0.1, 0.2, 0.3, 0.4 },
        .nitrogen = .{ 0.4, 0.3, 0.2, 0.1 },
        .phosphorus = .{ 0.25, 0.25, 0.25, 0.25 },
    };
    const coarse_kinetics: litter_partition.ElementFractions = .{
        .carbon = .{ 0.4, 0.3, 0.2, 0.1 },
        .nitrogen = .{ 0.1, 0.2, 0.3, 0.4 },
        .phosphorus = .{ 0.25, 0.25, 0.25, 0.25 },
    };
    const result = try plant_harvest_runtime.sourceOrderTillageStandingDead(.{
        .remaining_fraction = 0.25,
        .standing_dead_by_source_component = .{
            .{ .carbon_g = 1, .nitrogen_g = 0.1, .phosphorus_g = 0.01 },
            .{ .carbon_g = 2, .nitrogen_g = 0.2, .phosphorus_g = 0.02 },
            .{ .carbon_g = 3, .nitrogen_g = 0.3, .phosphorus_g = 0.03 },
            .{ .carbon_g = 4, .nitrogen_g = 0.4, .phosphorus_g = 0.04 },
        },
        .composition = .{
            .carbon = .{ 0.6, 0.4 },
            .nitrogen = .{ 0.7, 0.3 },
            .phosphorus = .{ 0.8, 0.2 },
        },
        .stalk_kinetics = stalk_kinetics,
        .coarse_wood_kinetics = coarse_kinetics,
    });
    var litter_carbon_g_c: f64 = 0;
    var litter_nitrogen_g_n: f64 = 0;
    var litter_phosphorus_g_p: f64 = 0;
    for (0..litter_partition.kinetic_component_count) |kinetic| {
        litter_carbon_g_c += result.litter.woody_carbon_g[kinetic] + result.litter.nonwoody_carbon_g[kinetic];
        litter_nitrogen_g_n += result.litter.woody_nitrogen_g[kinetic] + result.litter.nonwoody_nitrogen_g[kinetic];
        litter_phosphorus_g_p += result.litter.woody_phosphorus_g[kinetic] + result.litter.nonwoody_phosphorus_g[kinetic];
    }
    try std.testing.expectApproxEqAbs(7.5, litter_carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(0.75, litter_nitrogen_g_n, 1.0e-12);
    try std.testing.expectApproxEqAbs(0.075, litter_phosphorus_g_p, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 1), result.remaining_by_source_component[3].carbon_g);
    try std.testing.expectApproxEqAbs(
        0.75 * 0.4 * 10 * 0.6,
        result.litter.woody_carbon_g[0],
        1.0e-12,
    );
}

test "source-order tillage termination sets all death flags and harvest date" {
    const prior: plant_harvest_runtime.SourceOrderTillageTerminationState = .{
        .roots_dead = false,
        .shoots_dead = false,
        .plant_dead = false,
        .harvest_termination_code = 0,
        .harvest_day_of_year = 0,
        .harvest_year = 0,
    };
    const alive = try plant_harvest_runtime.sourceOrderTillageTermination(.{
        .living_population_count = 1.1e-6,
        .zero_population_threshold = 1.0e-6,
        .current_day_of_year = 240,
        .current_year = 2004,
        .state = prior,
    });
    try std.testing.expect(!alive.terminated);
    try std.testing.expectEqualDeep(prior, alive.state);

    const terminated = try plant_harvest_runtime.sourceOrderTillageTermination(.{
        .living_population_count = 1.0e-6,
        .zero_population_threshold = 1.0e-6,
        .current_day_of_year = 240,
        .current_year = 2004,
        .state = prior,
    });
    try std.testing.expect(terminated.terminated);
    try std.testing.expect(terminated.state.roots_dead);
    try std.testing.expect(terminated.state.shoots_dead);
    try std.testing.expect(terminated.state.plant_dead);
    try std.testing.expectEqual(@as(u8, 1), terminated.state.harvest_termination_code);
    try std.testing.expectEqual(@as(u16, 240), terminated.state.harvest_day_of_year);
    try std.testing.expectEqual(@as(u32, 2004), terminated.state.harvest_year);
}

test "source-order standing dead harvest separates harvest litter and retention" {
    const result = try plant_harvest_runtime.sourceOrderStandingDeadHarvest(.{
        .harvest_code = 0,
        .hour_of_day = 12,
        .local_solar_noon_h = 12.8,
        .thinning_fraction_or_specific_consumption_rate = 0.5,
        .standing_dead_removal_fraction = 0.4,
        .grazer_live_mass_g_per_m2 = 0,
        .animal_accessible_area_m2 = 0,
        .insect_accessible_area_m2 = 0,
        .standing_dead_presence_threshold_g_c = 1.0e-12,
        .standing_dead_by_component = .{
            .{ .carbon_g = 1, .nitrogen_g = 0.1, .phosphorus_g = 0.01 },
            .{ .carbon_g = 2, .nitrogen_g = 0.2, .phosphorus_g = 0.02 },
            .{ .carbon_g = 3, .nitrogen_g = 0.3, .phosphorus_g = 0.03 },
            .{ .carbon_g = 4, .nitrogen_g = 0.4, .phosphorus_g = 0.04 },
            .{ .carbon_g = 5, .nitrogen_g = 0.5, .phosphorus_g = 0.05 },
        },
    });
    try std.testing.expectEqual(@as(f64, 0.5), result.retained_fraction);
    try std.testing.expectEqual(@as(f64, 0.8), result.harvested_fraction);
    try std.testing.expectApproxEqAbs(3, result.harvested.carbon_g, 1.0e-14);
    try std.testing.expectApproxEqAbs(4.5, result.returned_to_litter.carbon_g, 1.0e-14);
    try std.testing.expectEqual(@as(f64, 2.5), result.remaining_by_component[4].carbon_g);
    try std.testing.expectApproxEqAbs(
        15,
        result.harvested.carbon_g + result.returned_to_litter.carbon_g +
            result.remaining_by_component[0].carbon_g + result.remaining_by_component[1].carbon_g +
            result.remaining_by_component[2].carbon_g + result.remaining_by_component[3].carbon_g +
            result.remaining_by_component[4].carbon_g,
        1.0e-14,
    );
}

test "source-order standing dead grazing selects animal and insect areas" {
    const base: plant_harvest_runtime.SourceOrderStandingDeadHarvestInput = .{
        .harvest_code = 4,
        .hour_of_day = 3,
        .local_solar_noon_h = 12,
        .thinning_fraction_or_specific_consumption_rate = 1,
        .standing_dead_removal_fraction = 0.5,
        .grazer_live_mass_g_per_m2 = 96,
        .animal_accessible_area_m2 = 2,
        .insect_accessible_area_m2 = 5,
        .standing_dead_presence_threshold_g_c = 1,
        .standing_dead_by_component = .{
            .{ .carbon_g = 2 },
            .{ .carbon_g = 2 },
            .{ .carbon_g = 2 },
            .{ .carbon_g = 2 },
            .{ .carbon_g = 2 },
        },
    };
    const animal = try plant_harvest_runtime.sourceOrderStandingDeadHarvest(base);
    try std.testing.expectEqual(@as(f64, 0.8), animal.retained_fraction);
    var insect_input = base;
    insect_input.harvest_code = 6;
    const insect = try plant_harvest_runtime.sourceOrderStandingDeadHarvest(insect_input);
    try std.testing.expectEqual(@as(f64, 0.5), insect.retained_fraction);
    var absent = base;
    absent.standing_dead_presence_threshold_g_c = 10;
    try std.testing.expectEqual(
        @as(f64, 1),
        (try plant_harvest_runtime.sourceOrderStandingDeadHarvest(absent)).retained_fraction,
    );
}

test "source-order harvest residue routes all five components" {
    const harvested = [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass{
        .{ .carbon_g = 10, .nitrogen_g = 1, .phosphorus_g = 0.1 },
        .{ .carbon_g = 20, .nitrogen_g = 2, .phosphorus_g = 0.2 },
        .{ .carbon_g = 30, .nitrogen_g = 3, .phosphorus_g = 0.3 },
        .{ .carbon_g = 40, .nitrogen_g = 4, .phosphorus_g = 0.4 },
        .{ .carbon_g = 50, .nitrogen_g = 5, .phosphorus_g = 0.5 },
    };
    const residue = try plant_harvest_runtime.sourceOrderHarvestResidueRouting(.{
        .harvest_code = 0,
        .harvested_by_component = harvested,
        .harvested_grain = .{},
        .ecosystem_export_fraction = .{ 0.1, 0.2, 0.3, 0.4 },
    });
    try std.testing.expectEqual(@as(f64, 9), residue[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 18), residue[1].carbon_g);
    try std.testing.expectEqual(@as(f64, 24), residue[2].carbon_g);
    try std.testing.expectEqual(@as(f64, 28), residue[3].carbon_g);
    try std.testing.expectEqual(@as(f64, 30), residue[4].carbon_g);

    const grazing = try plant_harvest_runtime.sourceOrderHarvestResidueRouting(.{
        .harvest_code = 6,
        .harvested_by_component = harvested,
        .harvested_grain = .{},
        .ecosystem_export_fraction = .{ 0.1, 0.2, 0.3, 0.4 },
    });
    try std.testing.expectEqualDeep(residue, grazing);
}

test "source-order grain harvest subtracts only exported grain from component two" {
    const harvested = [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass{
        .{ .carbon_g = 10, .nitrogen_g = 1, .phosphorus_g = 0.1 },
        .{ .carbon_g = 20, .nitrogen_g = 2, .phosphorus_g = 0.2 },
        .{ .carbon_g = 30, .nitrogen_g = 3, .phosphorus_g = 0.3 },
        .{ .carbon_g = 40, .nitrogen_g = 4, .phosphorus_g = 0.4 },
        .{ .carbon_g = 50, .nitrogen_g = 5, .phosphorus_g = 0.5 },
    };
    const residue = try plant_harvest_runtime.sourceOrderHarvestResidueRouting(.{
        .harvest_code = 1,
        .harvested_by_component = harvested,
        .harvested_grain = .{ .carbon_g = 10, .nitrogen_g = 1, .phosphorus_g = 0.1 },
        .ecosystem_export_fraction = .{ 0.9, 0.5, 0.8, 0.7 },
    });
    try std.testing.expectEqualDeep(harvested[0], residue[0]);
    try std.testing.expectEqualDeep(harvested[1], residue[1]);
    try std.testing.expectEqual(@as(f64, 25), residue[2].carbon_g);
    try std.testing.expectEqualDeep(harvested[3], residue[3]);
    try std.testing.expectEqualDeep(harvested[4], residue[4]);
}

test "harvest source-order rejects sub-legacy-tolerance residue overdraw" {
    var harvested: [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass = @splat(.{});
    harvested[2].carbon_g = 1;
    try std.testing.expectError(error.HarvestResidueOverdraw, plant_harvest_runtime.sourceOrderHarvestResidueRouting(.{
        .harvest_code = 1,
        .harvested_by_component = harvested,
        .harvested_grain = .{ .carbon_g = 1 + 5e-13 },
        .ecosystem_export_fraction = .{ 0, 1, 0, 0 },
    }));

    var residue: [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass = @splat(.{});
    residue[0].carbon_g = 1 + 5e-13;
    try std.testing.expectError(error.DisturbanceRemovalResidueOverdraw, plant_harvest_runtime.sourceOrderTotalDisturbanceRemoval(.{
        .harvest_code = 2,
        .terminate_and_reseed = false,
        .grazer_growth_yield = 0,
        .grazer_respiration_fraction = 0,
        .harvested_by_component = @splat(.{ .carbon_g = 0.2 }),
        .residue_by_component = residue,
        .direct_litter_by_component = @splat(.{}),
    }));
}

test "source-order disturbance totals route ordinary export and reseed storage" {
    const harvested: [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass =
        @splat(.{ .carbon_g = 2, .nitrogen_g = 1, .phosphorus_g = 0.5 });
    const residue: [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass =
        @splat(.{ .carbon_g = 1, .nitrogen_g = 0.5, .phosphorus_g = 0.25 });
    const direct_litter: [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass =
        @splat(.{ .carbon_g = 0.2, .nitrogen_g = 0.1, .phosphorus_g = 0.05 });
    const ordinary = try plant_harvest_runtime.sourceOrderTotalDisturbanceRemoval(.{
        .harvest_code = 2,
        .terminate_and_reseed = false,
        .grazer_growth_yield = 0,
        .grazer_respiration_fraction = 0,
        .harvested_by_component = harvested,
        .residue_by_component = residue,
        .direct_litter_by_component = direct_litter,
    });
    try std.testing.expectEqual(@as(f64, 10), ordinary.harvested_total.carbon_g);
    try std.testing.expectEqual(@as(f64, 5), ordinary.residue_total.carbon_g);
    try std.testing.expectEqual(@as(f64, 1), ordinary.direct_litter_total.carbon_g);
    try std.testing.expectEqual(@as(f64, 5), ordinary.plant_ecosystem_removal.carbon_g);
    try std.testing.expectEqual(@as(f64, -5), ordinary.net_biome_production_carbon_change_g_c_per_h);

    const reseed = try plant_harvest_runtime.sourceOrderTotalDisturbanceRemoval(.{
        .harvest_code = 2,
        .terminate_and_reseed = true,
        .grazer_growth_yield = 0,
        .grazer_respiration_fraction = 0,
        .harvested_by_component = harvested,
        .residue_by_component = residue,
        .direct_litter_by_component = direct_litter,
    });
    try std.testing.expectEqual(@as(f64, 5), reseed.reseed_storage_addition.carbon_g);
    try std.testing.expectEqual(@as(f64, 0), reseed.plant_ecosystem_removal.carbon_g);
    try std.testing.expectEqual(@as(f64, 0), reseed.grid_ecosystem_removal.carbon_g);
}

test "source-order grazing totals split growth and respiration carbon" {
    const harvested: [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass =
        @splat(.{ .carbon_g = 2, .nitrogen_g = 1, .phosphorus_g = 0.5 });
    const residue: [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass =
        @splat(.{ .carbon_g = 1, .nitrogen_g = 0.5, .phosphorus_g = 0.25 });
    const result = try plant_harvest_runtime.sourceOrderTotalDisturbanceRemoval(.{
        .harvest_code = 4,
        .terminate_and_reseed = false,
        .grazer_growth_yield = 0.4,
        .grazer_respiration_fraction = 0.6,
        .harvested_by_component = harvested,
        .residue_by_component = residue,
        .direct_litter_by_component = @splat(.{}),
    });
    try std.testing.expectEqual(@as(f64, 2), result.plant_ecosystem_removal.carbon_g);
    try std.testing.expectEqual(@as(f64, 2.5), result.plant_ecosystem_removal.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 1.25), result.plant_ecosystem_removal.phosphorus_g);
    try std.testing.expectEqual(@as(f64, -3), result.plant_total_respiration_change_g_c_per_h);
    try std.testing.expectEqual(@as(f64, -3), result.plant_actual_respiration_change_g_c_per_h);
    try std.testing.expectEqual(@as(f64, -3), result.ecosystem_respiration_change_g_c_per_h);
    try std.testing.expectEqual(@as(f64, -3), result.autotrophic_respiration_change_g_c_per_h);
}

test "source-order aboveground harvest litter preserves herbaceous and woody routing" {
    const residue = [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass{
        .{ .carbon_g = 1, .nitrogen_g = 0.1, .phosphorus_g = 0.01 },
        .{ .carbon_g = 2, .nitrogen_g = 0.2, .phosphorus_g = 0.02 },
        .{ .carbon_g = 3, .nitrogen_g = 0.3, .phosphorus_g = 0.03 },
        .{ .carbon_g = 4, .nitrogen_g = 0.4, .phosphorus_g = 0.04 },
        .{ .carbon_g = 5, .nitrogen_g = 0.5, .phosphorus_g = 0.05 },
    };
    const direct: [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass =
        @splat(.{ .carbon_g = 1, .nitrogen_g = 0.1, .phosphorus_g = 0.01 });
    const one_hot: litter_partition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const common: plant_harvest_runtime.SourceOrderAbovegroundHarvestLitterInput = .{
        .harvest_code = 2,
        .biomass_turnover_type = 0,
        .root_profile_type = 2,
        .residue_by_component = residue,
        .direct_litter_by_component = direct,
        .woody_composition = .{
            .carbon = .{ 0.25, 0.75 },
            .nitrogen = .{ 0.25, 0.75 },
            .phosphorus = .{ 0.25, 0.75 },
        },
        .nonstructural_kinetics = one_hot,
        .foliar_kinetics = one_hot,
        .nonfoliar_kinetics = one_hot,
        .stalk_kinetics = one_hot,
        .coarse_wood_kinetics = one_hot,
    };
    const herbaceous = try plant_harvest_runtime.sourceOrderAbovegroundHarvestLitter(common);
    try std.testing.expectEqual(@as(f64, 20), herbaceous.litter.nonwoody_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), herbaceous.litter.woody_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), herbaceous.standing_dead_addition.woody_carbon_g[0]);

    var woody_input = common;
    woody_input.biomass_turnover_type = 2;
    const woody = try plant_harvest_runtime.sourceOrderAbovegroundHarvestLitter(woody_input);
    try std.testing.expectEqual(@as(f64, 15.75), woody.litter.nonwoody_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 2.25), woody.litter.woody_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 2), woody.standing_dead_addition.woody_carbon_g[0]);
}

test "source-order grazing ledgers preserve five components and manure partition" {
    const residue: [plant_harvest_runtime.harvest_product_component_count]canopy.ElementalMass =
        @splat(.{ .carbon_g = 1, .nitrogen_g = 0.2, .phosphorus_g = 0.04 });
    const direct = residue;
    const current: plant_harvest_runtime.SourceOrderGrazingLitterLedgerState = .{
        .hourly_litter = .{},
        .cumulative_litter = .{ .carbon_g = 20, .nitrogen_g = 10, .phosphorus_g = 1 },
        .cumulative_aboveground_litter = .{ .carbon_g = 4, .nitrogen_g = 3, .phosphorus_g = 0.3 },
        .surface_litter_carbon_g_c = 7,
        .accumulated_application = .{},
    };
    const animal = try plant_harvest_runtime.sourceOrderGrazingLitterLedgers(4, residue, direct, current);
    try std.testing.expectEqual(@as(f64, 10), animal.returned_mass.carbon_g);
    try std.testing.expectEqual(@as(f64, 2), animal.returned_mass.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 14), animal.state.cumulative_aboveground_litter.carbon_g);
    try std.testing.expectEqual(@as(f64, 14), animal.state.cumulative_aboveground_litter.nitrogen_g);
    try std.testing.expectApproxEqAbs(1.8, animal.state.cumulative_aboveground_litter.phosphorus_g, 1.0e-14);
    try std.testing.expectEqual(@as(f64, 17), animal.state.surface_litter_carbon_g_c);
    try std.testing.expectApproxEqAbs(0.36, animal.manure.organic_by_biochemical_fraction[0].carbon_g, 1.0e-14);
    try std.testing.expectEqual(@as(f64, 1), animal.manure.inorganic_nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 0.2), animal.manure.inorganic_phosphorus_g_p);

    const insect = try plant_harvest_runtime.sourceOrderGrazingLitterLedgers(6, residue, direct, current);
    try std.testing.expectApproxEqAbs(1.38, insect.manure.organic_by_biochemical_fraction[0].carbon_g, 1.0e-14);
}

test "source-order population thresholds preserve runtime scaling and evaluation order" {
    const result = try plant_harvest_runtime.sourceOrderPopulationScaledNumericalThresholds(
        250,
        50,
        1.0e-15,
        1.0e-6,
    );
    try std.testing.expectEqual(@as(f64, 2.5e-13), result.plant_mass_presence_g);
    try std.testing.expectEqual(@as(f64, 5.0e-15), result.plant_mass_density_g_m2);
    try std.testing.expectEqual(@as(f64, 2.5e-4), result.plant_flux_presence_g_per_step);

    const extinct = try plant_harvest_runtime.sourceOrderPopulationScaledNumericalThresholds(0, 50, 1.0e-15, 1.0e-6);
    try std.testing.expectEqual(@as(f64, 0), extinct.plant_mass_presence_g);
    try std.testing.expectEqual(@as(f64, 0), extinct.plant_mass_density_g_m2);
    try std.testing.expectEqual(@as(f64, 0), extinct.plant_flux_presence_g_per_step);

    try std.testing.expectError(
        error.InvalidPopulationScaledNumericalThresholdInput,
        plant_harvest_runtime.sourceOrderPopulationScaledNumericalThresholds(1, 0, 1.0e-15, 1.0e-6),
    );
    try std.testing.expectError(
        error.InvalidPopulationScaledNumericalThresholdInput,
        plant_harvest_runtime.sourceOrderPopulationScaledNumericalThresholds(1, 1, -1, 1.0e-6),
    );
}

test "source-order dead branch reset preserves selector and runtime branch loop" {
    const stale: plant_harvest_runtime.SourceOrderDeadBranchPhenologyState = .{
        .dead = true,
        .maturity_group_node_count = 9,
        .initiated_node_count = 8,
        .nodes_at_floral_initiation = 7,
        .nodes_at_anthesis = 6,
        .appeared_leaf_count = 5,
        .leaves_at_floral_initiation = 4,
        .current_leaf_ordinal = 3,
        .current_growing_leaf_ordinal = 2,
        .normalized_vegetative_node_change = 1,
        .normalized_reproductive_node_change = 1,
        .accumulated_leafout_h = 1,
        .accumulated_leafoff_h = 1,
        .lengthening_photoperiod_h = 1,
        .shortening_photoperiod_h = 1,
        .time_since_germination_h = 1,
        .hours_without_grain_fill = 1,
        .carbon_fixation_feedback = 0.5,
        .carbon_fixation_feedback_previous = 0.5,
        .leafout_initialization_enabled = false,
        .emergence_initialization_disabled = false,
        .leafoff_enabled = false,
        .remobilization_enabled = false,
        .hours_after_maturity_h = 1,
        .new_branch_count = 3,
        .stage_day_of_year = @splat(100),
    };
    var branches = [_]plant_harvest_runtime.SourceOrderDeadBranchPhenologyState{ stale, stale };
    branches[1].dead = false;
    const live_before = branches[1];
    const applied = try plant_harvest_runtime.sourceOrderResetDeadBranchPhenology(&branches, .{
        .first_living_branch_emergence_day_of_year = 20,
        .perennial_growth_habit = false,
        .current_day_of_year = 200,
        .current_year = 2025,
        .harvest_day_of_year = 200,
        .harvest_year = 2025,
        .hour_of_day = 12,
        .local_solar_noon_h = 12.8,
        .initial_maturity_group_node_count = 4,
        .initial_node_count = 0.25,
    });
    try std.testing.expect(applied);
    try std.testing.expectEqual(@as(f64, 4), branches[0].maturity_group_node_count);
    try std.testing.expectEqual(@as(f64, 0.25), branches[0].initiated_node_count);
    try std.testing.expectEqual(@as(f64, 0.25), branches[0].nodes_at_floral_initiation);
    try std.testing.expectEqual(@as(usize, 1), branches[0].current_leaf_ordinal);
    try std.testing.expectEqual(@as(f64, 1), branches[0].carbon_fixation_feedback);
    try std.testing.expect(branches[0].leafout_initialization_enabled);
    try std.testing.expect(branches[0].emergence_initialization_disabled);
    try std.testing.expectEqual([_]u16{0} ** 10, branches[0].stage_day_of_year);
    try std.testing.expectEqualDeep(live_before, branches[1]);

    var unselected = [_]plant_harvest_runtime.SourceOrderDeadBranchPhenologyState{stale};
    const skipped = try plant_harvest_runtime.sourceOrderResetDeadBranchPhenology(&unselected, .{
        .first_living_branch_emergence_day_of_year = 20,
        .perennial_growth_habit = false,
        .current_day_of_year = 199,
        .current_year = 2025,
        .harvest_day_of_year = 200,
        .harvest_year = 2025,
        .hour_of_day = 12,
        .local_solar_noon_h = 12,
        .initial_maturity_group_node_count = 4,
        .initial_node_count = 0.25,
    });
    try std.testing.expect(!skipped);
    try std.testing.expectEqualDeep(stale, unselected[0]);
}
