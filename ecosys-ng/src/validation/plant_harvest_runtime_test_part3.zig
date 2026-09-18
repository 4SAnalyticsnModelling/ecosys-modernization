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
test "source-order dead branch litterfall conserves runtime branch components" {
    const kinetics: litter_partition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const composition: plant_harvest_runtime.TillageElementComposition = .{
        .carbon = .{ 0.25, 0.75 },
        .nitrogen = .{ 0.25, 0.75 },
        .phosphorus = .{ 0.25, 0.75 },
    };
    const common: plant_harvest_runtime.SourceOrderDeadBranchLitterInput = .{
        .annual_growth_habit = false,
        .deciduous_phenology = false,
        .pools = .{
            .bacterial_nonstructural = .{ .carbon_g = 1, .nitrogen_g = 1, .phosphorus_g = 1 },
            .bacterial_structural = .{ .carbon_g = 2, .nitrogen_g = 2, .phosphorus_g = 2 },
            .leaf = .{ .carbon_g = 4, .nitrogen_g = 4, .phosphorus_g = 4 },
            .sheath = .{ .carbon_g = 8, .nitrogen_g = 8, .phosphorus_g = 8 },
            .husk = .{ .carbon_g = 16, .nitrogen_g = 16, .phosphorus_g = 16 },
            .ear = .{ .carbon_g = 32, .nitrogen_g = 32, .phosphorus_g = 32 },
            .grain = .{ .carbon_g = 64, .nitrogen_g = 64, .phosphorus_g = 64 },
            .stalk = .{ .carbon_g = 128, .nitrogen_g = 128, .phosphorus_g = 128 },
        },
        .leaf_woody_fraction = composition,
        .sheath_woody_fraction = composition,
        .nonstructural_kinetics = kinetics,
        .foliar_kinetics = kinetics,
        .nonfoliar_kinetics = kinetics,
        .stalk_kinetics = kinetics,
        .coarse_wood_kinetics = kinetics,
    };
    const ordinary = try plant_harvest_runtime.sourceOrderDeadBranchLitterfall(common);
    try std.testing.expectEqual(@as(f64, 124), ordinary.nonwoody_litter[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 3), ordinary.woody_litter[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 128), ordinary.standing_dead_stalk[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 0), ordinary.seasonal_storage_addition.carbon_g);

    var winter_input = common;
    winter_input.annual_growth_habit = true;
    winter_input.deciduous_phenology = true;
    const winter = try plant_harvest_runtime.sourceOrderDeadBranchLitterfall(winter_input);
    try std.testing.expectEqual(@as(f64, 60), winter.nonwoody_litter[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 64), winter.seasonal_storage_addition.carbon_g);
    try std.testing.expectEqual(@as(f64, 255), winter.nonwoody_litter[0].carbon_g +
        winter.woody_litter[0].carbon_g +
        winter.standing_dead_stalk[0].carbon_g +
        winter.seasonal_storage_addition.carbon_g);
}

test "source-order dead branch storage recovery preserves six assignments" {
    const result = try plant_harvest_runtime.sourceOrderDeadBranchStorageRecovery(.{
        .current_seasonal_storage = .{
            .carbon_g = 100,
            .nitrogen_g = 20,
            .phosphorus_g = 5,
        },
        .branch_mobile = .{
            .carbon_g = 7,
            .nitrogen_g = 3,
            .phosphorus_g = 0.4,
        },
        .c4_intermediate_carbon_g_c = 11,
        .stalk_reserve = .{
            .carbon_g = 13,
            .nitrogen_g = 2,
            .phosphorus_g = 0.6,
        },
    });
    try std.testing.expectEqual(@as(f64, 131), result.seasonal_storage.carbon_g);
    try std.testing.expectEqual(@as(f64, 25), result.seasonal_storage.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 6), result.seasonal_storage.phosphorus_g);
    try std.testing.expectEqual(@as(f64, 31), result.recovered.carbon_g);
    try std.testing.expectEqual(@as(f64, 5), result.recovered.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 1), result.recovered.phosphorus_g);

    try std.testing.expectError(
        error.InvalidDeadBranchStorageRecoveryInput,
        plant_harvest_runtime.sourceOrderDeadBranchStorageRecovery(.{
            .current_seasonal_storage = .{},
            .branch_mobile = .{},
            .c4_intermediate_carbon_g_c = -1,
            .stalk_reserve = .{},
        }),
    );
}

test "source-order dead branch canopy reset preserves node zero exceptions" {
    var scalar: plant_harvest_runtime.SourceOrderDeadBranchScalarResetState = undefined;
    inline for (@typeInfo(plant_harvest_runtime.SourceOrderDeadBranchScalarResetState).@"struct".fields) |field| {
        if (field.type == f64) {
            @field(scalar, field.name) = 1;
        } else {
            @field(scalar, field.name) = .{
                .carbon_g = 1,
                .nitrogen_g = 1,
                .phosphorus_g = 1,
            };
        }
    }
    const node: plant_harvest_runtime.SourceOrderDeadBranchNodeResetState = .{
        .bundle_sheath_mobile_carbon_g_c = 1,
        .mesophyll_mobile_carbon_g_c = 1,
        .bundle_sheath_co2_carbon_g_c = 1,
        .bundle_sheath_bicarbonate_carbon_g_c = 1,
        .leaf_area_m2 = 1,
        .node_height_m = 1,
        .node_height_previous_m = 1,
        .sheath_height_m = 1,
        .leaf = .{ .carbon_g = 1, .nitrogen_g = 1, .phosphorus_g = 1 },
        .leaf_protein_g = 1,
        .sheath = .{ .carbon_g = 1, .nitrogen_g = 1, .phosphorus_g = 1 },
        .sheath_protein_g = 1,
        .stalk = .{ .carbon_g = 1, .nitrogen_g = 1, .phosphorus_g = 1 },
    };
    var nodes = [_]plant_harvest_runtime.SourceOrderDeadBranchNodeResetState{ node, node };
    var node_layers = [_]plant_harvest_runtime.SourceOrderDeadBranchLayerResetState{
        .{
            .leaf_area_m2 = 2,
            .leaf = .{ .carbon_g = 3, .nitrogen_g = 0.3, .phosphorus_g = 0.03 },
            .projected_leaf_surface_m2 = @splat(4),
        },
        .{
            .leaf_area_m2 = 5,
            .leaf = .{ .carbon_g = 7, .nitrogen_g = 0.7, .phosphorus_g = 0.07 },
            .projected_leaf_surface_m2 = @splat(8),
        },
    };
    var canopy_area = [_]f64{10};
    var canopy_carbon = [_]f64{20};
    var stalk_area = [_]f64{6};
    var stalk_surface = [_][4]f64{@splat(9)};
    try plant_harvest_runtime.sourceOrderResetDeadBranchCanopy(.{
        .scalar = &scalar,
        .nodes = &nodes,
        .node_layers = &node_layers,
        .canopy_leaf_area_m2_by_layer = &canopy_area,
        .canopy_leaf_carbon_g_c_by_layer = &canopy_carbon,
        .branch_stalk_area_m2_by_layer = &stalk_area,
        .branch_projected_stalk_surface_m2 = &stalk_surface,
    });
    try std.testing.expectEqual(@as(f64, 3), canopy_area[0]);
    try std.testing.expectEqual(@as(f64, 10), canopy_carbon[0]);
    try std.testing.expectEqual(@as(f64, 0), scalar.host_mobile.carbon_g);
    try std.testing.expectEqual(@as(f64, 1), nodes[0].bundle_sheath_mobile_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), nodes[1].bundle_sheath_mobile_carbon_g_c);
    try std.testing.expectEqual([_]f64{4} ** 4, node_layers[0].projected_leaf_surface_m2);
    try std.testing.expectEqual([_]f64{0} ** 4, node_layers[1].projected_leaf_surface_m2);
    try std.testing.expectEqual(@as(f64, 0), stalk_area[0]);
    try std.testing.expectEqual([_]f64{0} ** 4, stalk_surface[0]);
}

test "source-order whole plant termination preserves winter annual reseed branch" {
    const current: plant_harvest_runtime.SourceOrderWholePlantTerminationState = .{
        .shoot_alive = true,
        .root_alive = true,
        .total_node_count = 12,
        .hours_below_leaf_turgor_threshold_h = 8,
        .main_stalk_diameter_m = 0.03,
        .branch_count = 3,
        .living_population_per_m2 = 20,
        .living_population_count = 200,
        .hypocotyl_height_m = 0.1,
    };
    const partial = try plant_harvest_runtime.sourceOrderWholePlantTermination(&.{ true, false, true }, false, current);
    try std.testing.expect(!partial.all_branches_dead);
    try std.testing.expectEqual(@as(usize, 2), partial.dead_branch_count);
    try std.testing.expectEqualDeep(current, partial.state);

    const winter = try plant_harvest_runtime.sourceOrderWholePlantTermination(&.{ true, true, true }, true, current);
    try std.testing.expect(winter.all_branches_dead);
    try std.testing.expectEqual(@as(usize, 1), winter.state.branch_count);
    try std.testing.expectEqual(@as(f64, 20), winter.state.living_population_per_m2);
    try std.testing.expectEqual(@as(f64, 200), winter.state.living_population_count);
    try std.testing.expect(!winter.state.shoot_alive);
    try std.testing.expect(!winter.state.root_alive);
    try std.testing.expectEqual(@as(f64, 0), winter.state.hypocotyl_height_m);

    const ordinary = try plant_harvest_runtime.sourceOrderWholePlantTermination(&.{ true, true, true }, false, current);
    try std.testing.expectEqual(@as(usize, 0), ordinary.state.branch_count);
    try std.testing.expectEqual(@as(f64, 0), ordinary.state.living_population_per_m2);
    try std.testing.expectEqual(@as(f64, 0), ordinary.state.living_population_count);
}

test "source-order dead root litterfall conserves runtime domains and axes" {
    const kinetics: litter_partition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const mobile = [_]canopy.ElementalMass{
        .{ .carbon_g = 1, .nitrogen_g = 1, .phosphorus_g = 1 },
        .{ .carbon_g = 2, .nitrogen_g = 2, .phosphorus_g = 2 },
    };
    const axis: plant_harvest_runtime.SourceOrderDeadRootAxisPools = .{
        .primary = .{ .carbon_g = 1, .nitrogen_g = 1, .phosphorus_g = 1 },
        .secondary = .{ .carbon_g = 2, .nitrogen_g = 2, .phosphorus_g = 2 },
    };
    const structural = [_]plant_harvest_runtime.SourceOrderDeadRootAxisPools{ axis, axis, axis, axis };
    const base: plant_harvest_runtime.SourceOrderDeadRootLitterInput = .{
        .roots_dead = true,
        .root_domain_count = 2,
        .soil_layer_count = 1,
        .root_axis_count = 2,
        .mobile_by_domain_layer = &mobile,
        .structural_by_domain_layer_axis = &structural,
        .root_woody_fraction = .{
            .carbon = .{ 0.25, 0.75 },
            .nitrogen = .{ 0.25, 0.75 },
            .phosphorus = .{ 0.25, 0.75 },
        },
        .mobile_kinetics = kinetics,
        .fine_root_kinetics = kinetics,
        .coarse_root_kinetics = kinetics,
    };
    const dead = try plant_harvest_runtime.sourceOrderDeadRootLitterfall(std.testing.allocator, base);
    defer std.testing.allocator.free(dead);
    try std.testing.expectEqual(@as(f64, 3), dead[0].woody[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 12), dead[0].nonwoody[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 15), dead[0].woody[0].nitrogen_g +
        dead[0].nonwoody[0].nitrogen_g);

    var live_input = base;
    live_input.roots_dead = false;
    const live = try plant_harvest_runtime.sourceOrderDeadRootLitterfall(std.testing.allocator, live_input);
    defer std.testing.allocator.free(live);
    try std.testing.expectEqual(@as(f64, 0), live[0].woody[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 0), live[0].nonwoody[0].carbon_g);
}

test "source-order dead root gas release clears both phases conservatively" {
    const gaseous: plant_harvest_runtime.SourceOrderRootGasInventory = .{
        .carbon_dioxide_carbon_g_c = 1,
        .oxygen_g_o = 2,
        .methane_carbon_g_c = 3,
        .nitrous_oxide_nitrogen_g_n = 4,
        .ammonia_nitrogen_g_n = 5,
        .hydrogen_g_h = 6,
    };
    const aqueous: plant_harvest_runtime.SourceOrderRootGasInventory = .{
        .carbon_dioxide_carbon_g_c = 10,
        .oxygen_g_o = 20,
        .methane_carbon_g_c = 30,
        .nitrous_oxide_nitrogen_g_n = 40,
        .ammonia_nitrogen_g_n = 50,
        .hydrogen_g_h = 60,
    };
    var phases = [_]plant_harvest_runtime.SourceOrderRootGasPhases{
        .{ .gaseous = gaseous, .aqueous = aqueous },
        .{ .gaseous = gaseous, .aqueous = aqueous },
    };
    const loss = try plant_harvest_runtime.sourceOrderReleaseDeadRootGases(
        true,
        &phases,
        std.mem.zeroes(plant_harvest_runtime.SourceOrderRootGasInventory),
    );
    try std.testing.expectEqual(@as(f64, -22), loss.carbon_dioxide_carbon_g_c);
    try std.testing.expectEqual(@as(f64, -44), loss.oxygen_g_o);
    try std.testing.expectEqual(@as(f64, -132), loss.hydrogen_g_h);
    try std.testing.expectEqualDeep(
        std.mem.zeroes(plant_harvest_runtime.SourceOrderRootGasPhases),
        phases[0],
    );
    try std.testing.expectEqualDeep(
        std.mem.zeroes(plant_harvest_runtime.SourceOrderRootGasPhases),
        phases[1],
    );

    var living = [_]plant_harvest_runtime.SourceOrderRootGasPhases{.{ .gaseous = gaseous, .aqueous = aqueous }};
    const unchanged_loss = try plant_harvest_runtime.sourceOrderReleaseDeadRootGases(
        false,
        &living,
        gaseous,
    );
    try std.testing.expectEqualDeep(gaseous, unchanged_loss);
    try std.testing.expectEqualDeep(gaseous, living[0].gaseous);
    try std.testing.expectEqualDeep(aqueous, living[0].aqueous);
}

test "source-order dead root reset preserves runtime extents and radius defaults" {
    const mass: canopy.ElementalMass = .{
        .carbon_g = 1,
        .nitrogen_g = 1,
        .phosphorus_g = 1,
    };
    const axis_layer_value: plant_harvest_runtime.SourceOrderDeadRootAxisLayerState = .{
        .primary = mass,
        .secondary = mass,
        .primary_length_m = 1,
        .secondary_length_m = 1,
        .secondary_axis_count = 1,
    };
    var axis_layers = [_]plant_harvest_runtime.SourceOrderDeadRootAxisLayerState{
        axis_layer_value,
        axis_layer_value,
        axis_layer_value,
        axis_layer_value,
    };
    var domain_axes = [_]plant_harvest_runtime.SourceOrderDeadRootDomainAxisState{
        .{ .primary_total = mass },
        .{ .primary_total = mass },
    };
    const layer_value: plant_harvest_runtime.SourceOrderDeadRootDomainLayerState = .{
        .mobile = mass,
        .active_root_carbon_g_c = 1,
        .actual_root_carbon_g_c = 1,
        .root_protein_g = 1,
        .primary_axis_count = 1,
        .total_axis_count = 1,
        .root_length_per_plant_m = 1,
        .root_length_density_m_m3 = 1,
        .gaseous_volume_m3 = 1,
        .aqueous_volume_m3 = 1,
        .root_surface_area_per_plant_m2 = 1,
        .primary_radius_m = 1,
        .secondary_radius_m = 1,
        .average_secondary_root_length_m = 1,
    };
    var domain_layers = [_]plant_harvest_runtime.SourceOrderDeadRootDomainLayerState{
        layer_value,
        layer_value,
    };
    try plant_harvest_runtime.sourceOrderResetDeadRootState(true, .{
        .root_domain_count = 1,
        .soil_layer_count = 2,
        .root_axis_count = 2,
        .axis_layer = &axis_layers,
        .domain_axis = &domain_axes,
        .domain_layer = &domain_layers,
        .initial_primary_radius_m_by_domain = &.{0.01},
        .initial_secondary_radius_m_by_domain = &.{0.002},
        .initial_average_secondary_root_length_m = 0.1,
    });
    for (axis_layers) |axis| {
        try std.testing.expectEqual(@as(f64, 0), axis.primary.carbon_g);
        try std.testing.expectEqual(@as(f64, 0), axis.secondary_length_m);
        try std.testing.expectEqual(@as(f64, 0), axis.secondary_axis_count);
    }
    for (domain_axes) |axis|
        try std.testing.expectEqual(@as(f64, 0), axis.primary_total.carbon_g);
    for (domain_layers) |layer| {
        try std.testing.expectEqual(@as(f64, 0), layer.mobile.carbon_g);
        try std.testing.expectEqual(@as(f64, 0.01), layer.primary_radius_m);
        try std.testing.expectEqual(@as(f64, 0.002), layer.secondary_radius_m);
        try std.testing.expectEqual(@as(f64, 0.1), layer.average_secondary_root_length_m);
        try std.testing.expectEqual(@as(f64, 0), layer.root_surface_area_per_plant_m2);
    }
}

test "source-order dead nodule litterfall uses only first root domain" {
    const kinetics: litter_partition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const pools: plant_harvest_runtime.SourceOrderDeadNoduleLayerPools = .{
        .structural = .{ .carbon_g = 10, .nitrogen_g = 5, .phosphorus_g = 1 },
        .mobile = .{ .carbon_g = 2, .nitrogen_g = 1, .phosphorus_g = 0.2 },
    };
    var layers = [_]plant_harvest_runtime.SourceOrderDeadNoduleLayerPools{ pools, pools };
    const litter = try plant_harvest_runtime.sourceOrderDeadNoduleLitterfall(std.testing.allocator, .{
        .roots_dead = true,
        .nitrogen_fixation_enabled = true,
        .root_domain_count = 3,
        .layer_pools = &layers,
        .structural_kinetics = kinetics,
        .mobile_kinetics = kinetics,
    });
    defer std.testing.allocator.free(litter);
    try std.testing.expectEqual(@as(f64, 12), litter[0][0].carbon_g);
    try std.testing.expectEqual(@as(f64, 6), litter[1][0].nitrogen_g);
    try std.testing.expectEqual(@as(f64, 0), layers[0].structural.carbon_g);
    try std.testing.expectEqual(@as(f64, 0), layers[1].mobile.carbon_g);

    var nonfixing = [_]plant_harvest_runtime.SourceOrderDeadNoduleLayerPools{pools};
    const empty = try plant_harvest_runtime.sourceOrderDeadNoduleLitterfall(std.testing.allocator, .{
        .roots_dead = true,
        .nitrogen_fixation_enabled = false,
        .root_domain_count = 2,
        .layer_pools = &nonfixing,
        .structural_kinetics = kinetics,
        .mobile_kinetics = kinetics,
    });
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(f64, 0), empty[0][0].carbon_g);
    try std.testing.expectEqualDeep(pools, nonfixing[0]);
}

test "source-order dead root depth reset preserves axis-major domain order" {
    var deepest_by_axis = [_]usize{ 8, 9 };
    var depths = [_]f64{ 1, 2, 3, 4, 5, 6 };
    const mass: canopy.ElementalMass = .{
        .carbon_g = 1,
        .nitrogen_g = 0.1,
        .phosphorus_g = 0.01,
    };
    var totals = [_]canopy.ElementalMass{mass} ** 6;
    var deepest_active: usize = 9;
    var active_axes: usize = 2;
    try plant_harvest_runtime.sourceOrderResetDeadRootDepth(true, 3, 0.04, .{
        .root_domain_count = 3,
        .root_axis_count = 2,
        .deepest_layer_by_axis = &deepest_by_axis,
        .primary_depth_from_surface_m_by_axis_domain = &depths,
        .primary_total_by_axis_domain = &totals,
        .deepest_active_root_layer = &deepest_active,
        .active_root_axis_count = &active_axes,
    });
    try std.testing.expectEqual([_]usize{ 3, 3 }, deepest_by_axis);
    try std.testing.expectEqual([_]f64{0.04} ** 6, depths);
    for (totals) |total|
        try std.testing.expectEqual(@as(f64, 0), total.carbon_g);
    try std.testing.expectEqual(@as(usize, 3), deepest_active);
    try std.testing.expectEqual(@as(usize, 0), active_axes);
}

test "source-order complete death shoot litterfall conserves storage and branches" {
    const kinetics: litter_partition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const composition: plant_harvest_runtime.TillageElementComposition = .{
        .carbon = .{ 0.25, 0.75 },
        .nitrogen = .{ 0.25, 0.75 },
        .phosphorus = .{ 0.25, 0.75 },
    };
    const carbon = struct {
        fn mass(value: f64) canopy.ElementalMass {
            return .{ .carbon_g = value, .nitrogen_g = 0, .phosphorus_g = 0 };
        }
    }.mass;
    const branch: plant_harvest_runtime.SourceOrderCompleteDeathBranchPools = .{
        .host_mobile = carbon(1),
        .symbiont_mobile = carbon(2),
        .c4_intermediate_carbon_g_c = 3,
        .leaf = carbon(4),
        .symbiont_structural = carbon(5),
        .sheath = carbon(6),
        .husk = carbon(7),
        .ear = carbon(8),
        .grain = carbon(9),
        .stalk = carbon(10),
        .stalk_reserve = carbon(11),
    };
    const base: plant_harvest_runtime.SourceOrderCompleteDeathShootInput = .{
        .shoot_dead = true,
        .roots_dead = true,
        .perennial_growth_habit = true,
        .deciduous_phenology = true,
        .seasonal_storage = carbon(8),
        .branches = &.{branch},
        .root_woody_fraction = composition,
        .leaf_woody_fraction = composition,
        .sheath_woody_fraction = composition,
        .nonstructural_kinetics = kinetics,
        .foliar_kinetics = kinetics,
        .nonfoliar_kinetics = kinetics,
        .stalk_kinetics = kinetics,
        .coarse_wood_kinetics = kinetics,
    };
    const perennial = try plant_harvest_runtime.sourceOrderCompleteDeathShootLitterfall(base);
    try std.testing.expect(perennial.plant_death_initialized);
    try std.testing.expectEqual(@as(f64, 2), perennial.planting_layer_woody_litter[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 6), perennial.planting_layer_nonwoody_litter[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 42.5), perennial.surface_nonwoody_litter[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 2.5), perennial.surface_woody_litter[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 21), perennial.standing_dead_stalk[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 0), perennial.seasonal_storage.carbon_g);

    var winter_input = base;
    winter_input.perennial_growth_habit = false;
    const winter = try plant_harvest_runtime.sourceOrderCompleteDeathShootLitterfall(winter_input);
    try std.testing.expect(!winter.plant_death_initialized);
    try std.testing.expectEqual(@as(f64, 33.5), winter.surface_nonwoody_litter[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 17), winter.seasonal_storage.carbon_g);
    try std.testing.expectEqual(@as(f64, 74), winter.surface_nonwoody_litter[0].carbon_g +
        winter.surface_woody_litter[0].carbon_g +
        winter.standing_dead_stalk[0].carbon_g +
        winter.seasonal_storage.carbon_g);
}

test "source-order complete death root litterfall conserves domains axes and layers" {
    const kinetics: litter_partition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const mobile = [_]canopy.ElementalMass{
        .{ .carbon_g = 1, .nitrogen_g = 2, .phosphorus_g = 3 },
        .{ .carbon_g = 10, .nitrogen_g = 20, .phosphorus_g = 30 },
        .{ .carbon_g = 4, .nitrogen_g = 5, .phosphorus_g = 6 },
        .{ .carbon_g = 40, .nitrogen_g = 50, .phosphorus_g = 60 },
    };
    const axis: plant_harvest_runtime.SourceOrderDeadRootAxisPools = .{
        .primary = .{ .carbon_g = 2, .nitrogen_g = 2, .phosphorus_g = 2 },
        .secondary = .{ .carbon_g = 2, .nitrogen_g = 2, .phosphorus_g = 2 },
    };
    const structural = [_]plant_harvest_runtime.SourceOrderDeadRootAxisPools{
        axis, axis, axis, axis, axis, axis, axis, axis,
    };
    const base: plant_harvest_runtime.SourceOrderCompleteDeathRootInput = .{
        .shoot_dead = true,
        .roots_dead = true,
        .root_domain_count = 2,
        .soil_layer_count = 2,
        .root_axis_count = 2,
        .mobile_by_domain_layer = &mobile,
        .structural_by_domain_layer_axis = &structural,
        .root_woody_fraction = .{
            .carbon = .{ 0.25, 0.75 },
            .nitrogen = .{ 0.25, 0.75 },
            .phosphorus = .{ 0.25, 0.75 },
        },
        .nonstructural_kinetics = kinetics,
        .fine_root_kinetics = kinetics,
        .coarse_root_kinetics = kinetics,
    };
    const dead = try plant_harvest_runtime.sourceOrderCompleteDeathRootLitterfall(
        std.testing.allocator,
        base,
    );
    defer std.testing.allocator.free(dead);
    try std.testing.expectEqual(@as(f64, 4), dead[0].woody[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 17), dead[0].nonwoody[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 62), dead[1].nonwoody[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 21), dead[0].woody[0].carbon_g +
        dead[0].nonwoody[0].carbon_g);

    var partial_death = base;
    partial_death.shoot_dead = false;
    const live = try plant_harvest_runtime.sourceOrderCompleteDeathRootLitterfall(
        std.testing.allocator,
        partial_death,
    );
    defer std.testing.allocator.free(live);
    try std.testing.expectEqual(@as(f64, 0), live[0].nonwoody[0].carbon_g);
}

test "source-order complete death branch reset clears every runtime branch field" {
    const mass: canopy.ElementalMass = .{
        .carbon_g = 1,
        .nitrogen_g = 2,
        .phosphorus_g = 3,
    };
    const populated: plant_harvest_runtime.SourceOrderCompleteDeathBranchState = .{
        .host_mobile = mass,
        .c4_intermediate_carbon_g_c = 4,
        .symbiont_mobile = mass,
        .shoot = mass,
        .leaf = mass,
        .nodule = mass,
        .sheath = mass,
        .stalk = mass,
        .stalk_volume_m3 = 5,
        .reserve = mass,
        .husk = mass,
        .ear = mass,
        .grain = mass,
        .leaf_starch_carbon_g_c = 6,
        .stalk_extra = mass,
    };
    var partial = [_]plant_harvest_runtime.SourceOrderCompleteDeathBranchState{populated};
    try plant_harvest_runtime.sourceOrderResetCompleteDeathBranches(true, false, &partial);
    try std.testing.expectEqual(@as(f64, 1), partial[0].grain.carbon_g);

    var dead = [_]plant_harvest_runtime.SourceOrderCompleteDeathBranchState{ populated, populated };
    try plant_harvest_runtime.sourceOrderResetCompleteDeathBranches(true, true, &dead);
    for (dead) |branch| {
        inline for (@typeInfo(plant_harvest_runtime.SourceOrderCompleteDeathBranchState).@"struct".fields) |field| {
            const value = @field(branch, field.name);
            if (field.type == f64) {
                try std.testing.expectEqual(@as(f64, 0), value);
            } else inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element|
                try std.testing.expectEqual(@as(f64, 0), @field(value, element.name));
        }
    }
}

test "source-order complete death root reset preserves layer domain axis extents" {
    const mass: canopy.ElementalMass = .{
        .carbon_g = 1,
        .nitrogen_g = 2,
        .phosphorus_g = 3,
    };
    const axis: plant_harvest_runtime.SourceOrderDeadRootAxisLayerState = .{
        .primary = mass,
        .secondary = mass,
        .primary_length_m = 4,
        .secondary_length_m = 5,
        .secondary_axis_count = 6,
    };
    var mobile = [_]canopy.ElementalMass{ mass, mass, mass, mass };
    var structural = [_]plant_harvest_runtime.SourceOrderDeadRootAxisLayerState{
        axis, axis, axis, axis, axis, axis, axis, axis,
    };
    var totals = [_]plant_harvest_runtime.SourceOrderDeadRootDomainAxisState{
        .{ .primary_total = mass },
        .{ .primary_total = mass },
        .{ .primary_total = mass },
        .{ .primary_total = mass },
    };
    const state: plant_harvest_runtime.SourceOrderCompleteDeathRootResetState = .{
        .root_domain_count = 2,
        .soil_layer_count = 2,
        .root_axis_count = 2,
        .mobile_by_domain_layer = &mobile,
        .structural_by_domain_layer_axis = &structural,
        .primary_total_by_domain_axis = &totals,
    };
    try plant_harvest_runtime.sourceOrderResetCompleteDeathRoots(true, false, state);
    try std.testing.expectEqual(@as(f64, 1), mobile[0].carbon_g);

    try plant_harvest_runtime.sourceOrderResetCompleteDeathRoots(true, true, state);
    for (mobile) |value|
        try std.testing.expectEqual(@as(f64, 0), value.carbon_g);
    for (structural) |value| {
        try std.testing.expectEqual(@as(f64, 0), value.primary.carbon_g);
        try std.testing.expectEqual(@as(f64, 0), value.secondary.nitrogen_g);
        try std.testing.expectEqual(@as(f64, 0), value.primary_length_m);
        try std.testing.expectEqual(@as(f64, 0), value.secondary_length_m);
        try std.testing.expectEqual(@as(f64, 0), value.secondary_axis_count);
    }
    for (totals) |value|
        try std.testing.expectEqual(@as(f64, 0), value.primary_total.phosphorus_g);
}

test "source-order dead perennial reseed preserves next-day year rollover and gates" {
    const same_year = try plant_harvest_runtime.sourceOrderScheduleDeadPerennialReseed(
        true,
        false,
        200,
        365,
        2001,
    );
    try std.testing.expect(same_year.plant_death_flag);
    try std.testing.expectEqual(@as(u16, 201), same_year.reseed_date.?.day_of_year);
    try std.testing.expectEqual(@as(u32, 2001), same_year.reseed_date.?.year);

    const rollover = try plant_harvest_runtime.sourceOrderScheduleDeadPerennialReseed(
        true,
        false,
        366,
        366,
        2004,
    );
    try std.testing.expectEqual(@as(u16, 1), rollover.reseed_date.?.day_of_year);
    try std.testing.expectEqual(@as(u32, 2005), rollover.reseed_date.?.year);

    const annual = try plant_harvest_runtime.sourceOrderScheduleDeadPerennialReseed(
        false,
        false,
        100,
        365,
        2001,
    );
    try std.testing.expect(annual.reseed_date == null);
    try std.testing.expect(!annual.plant_death_flag);
    const terminated = try plant_harvest_runtime.sourceOrderScheduleDeadPerennialReseed(
        true,
        true,
        100,
        365,
        2001,
    );
    try std.testing.expect(terminated.reseed_date == null);
}

test "source-order soil plant exchange separates uptake fixation and NPP ledgers" {
    const result = try plant_harvest_runtime.sourceOrderAccumulateSoilPlantExchange(.{
        .organic_carbon_exchange_g_c_step = 1,
        .organic_nitrogen_exchange_g_n_step = 2,
        .ammonium_uptake_g_n_step = 3,
        .nitrate_uptake_g_n_step = 4,
        .root_fixation_g_n_step = 5,
        .canopy_fixation_g_n_step = 6,
        .organic_phosphorus_exchange_g_p_step = 7,
        .dihydrogen_phosphate_uptake_g_p_step = 8,
        .hydrogen_phosphate_uptake_g_p_step = 9,
        .cumulative_soil_exchange = .{
            .carbon_g = 10,
            .nitrogen_g = 20,
            .phosphorus_g = 30,
        },
        .cumulative_fixation_g_n = 40,
        .cumulative_plant_carbon_g_c = 50,
        .cumulative_respired_carbon_g_c = -12,
    });
    try std.testing.expectEqual(@as(f64, 1), result.hourly_net_exchange.carbon_g);
    try std.testing.expectEqual(@as(f64, 14), result.hourly_net_exchange.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 24), result.hourly_net_exchange.phosphorus_g);
    try std.testing.expectEqual(@as(f64, 11), result.cumulative_soil_exchange.carbon_g);
    try std.testing.expectEqual(@as(f64, 29), result.cumulative_soil_exchange.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 54), result.cumulative_soil_exchange.phosphorus_g);
    try std.testing.expectEqual(@as(f64, 51), result.cumulative_fixation_g_n);
    try std.testing.expectEqual(
        @as(f64, 38),
        result.cumulative_net_primary_productivity_g_c,
    );
    try std.testing.expectEqual(
        @as(f64, 5),
        result.hourly_net_exchange.nitrogen_g -
            (result.cumulative_soil_exchange.nitrogen_g - 20),
    );
}

test "source-order standing dead geometry aggregates runtime components and layers" {
    const components = [_]canopy.ElementalMass{
        .{ .carbon_g = 1.1416, .nitrogen_g = 2, .phosphorus_g = 3 },
        .{ .carbon_g = 2, .nitrogen_g = 4, .phosphorus_g = 5 },
    };
    const edges = [_]f64{ 0, 0.5, 1 };
    const result = try plant_harvest_runtime.sourceOrderStandingDeadGeometry(std.testing.allocator, .{
        .components = &components,
        .negligible_mass_g_c = 1.0e-12,
        .standing_dead_population_count = 1,
        .previous_height_m = 0.75,
        .canopy_height_m = 1,
        .stalk_volume_per_carbon_m3_g_c = 1,
        .canopy_layer_edges_m = &edges,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 3.1416), result.total_mass.carbon_g, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 6), result.total_mass.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 8), result.total_mass.phosphorus_g);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.height_m, 1.0e-12);
    try std.testing.expectApproxEqAbs(
        @as(f64, 6.2832),
        result.total_surface_area_m2,
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 3.1416),
        result.layer_surface_area_m2[0],
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.7854),
        result.projected_surface_area_m2[1],
        1.0e-12,
    );

    const empty = try plant_harvest_runtime.sourceOrderStandingDeadGeometry(std.testing.allocator, .{
        .components = &.{.{}},
        .negligible_mass_g_c = 1.0e-12,
        .standing_dead_population_count = 1,
        .previous_height_m = 1,
        .canopy_height_m = 1,
        .stalk_volume_per_carbon_m3_g_c = 1,
        .canopy_layer_edges_m = &edges,
    });
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 0), empty.height_m);
    try std.testing.expectEqual(@as(f64, 0), empty.layer_surface_area_m2[1]);
}
