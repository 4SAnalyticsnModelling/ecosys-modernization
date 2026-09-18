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

test "production harvest composition contract preserves current FWOOD FWODR provenance" {
    const composition = try plant_harvest_runtime.sourceOrderBelowgroundHarvestComposition(
        true,
        true,
        1,
        100,
        25,
        0.01,
        0.03,
        0.001,
        0.003,
        1e-12,
        0.5,
    );
    try std.testing.expectEqual([2]f64{ 0.5, 0.5 }, composition.root_woody_nonwoody.carbon);
    try std.testing.expectEqual(composition.root_woody_nonwoody.carbon, composition.root_woody_nonwoody.nitrogen);
    try std.testing.expectEqual(composition.root_woody_nonwoody.carbon, composition.root_woody_nonwoody.phosphorus);
    try std.testing.expectEqual([2]f64{ 0.75, 0.25 }, composition.storage_woody_nonwoody.carbon);
    try std.testing.expectEqual(composition.storage_woody_nonwoody.carbon, composition.storage_woody_nonwoody.nitrogen);
    try std.testing.expectEqual(composition.storage_woody_nonwoody.carbon, composition.storage_woody_nonwoody.phosphorus);
    try std.testing.expect(composition.perennial);
}

test "GROSUB belowground harvest scales every root field and conserves element-specific root and perennial storage litter" {
    var canopy_state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer canopy_state.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var roots = try root_system.State.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    roots.active_root_axis_count[0] = 1;
    roots.planting_layer_by_plant[0] = 0;

    for (0..root_system.biological_domain_count) |domain| {
        const root = try roots.layerIndex(0, domain, 0);
        roots.mobile_carbon_g[root] = 2;
        roots.mobile_nitrogen_g[root] = 1;
        roots.mobile_phosphorus_g[root] = 0.5;
        roots.total_carbon_g[root] = 20;
        roots.primary_root_carbon_g[root] = 10;
        roots.protein_carbon_g[root] = 4;
        roots.root_length_m_per_plant[root] = 8;
        roots.root_length_density_m_per_m3[root] = 6;
        roots.gaseous_volume_m3[root] = 2;
        roots.aqueous_volume_m3[root] = 4;
        roots.root_surface_area_m2_per_plant[root] = 10;
        roots.secondary_axis_count_total[root] = 26;
        roots.respiration_unlimited_by_oxygen_g_c_per_h[root] = 12;
        roots.respiration_unlimited_by_carbon_g_c_per_h[root] = 14;
        roots.actual_respiration_g_c_per_h[root] = 16;
        const axis = try roots.layerAxisIndex(0, domain, 0, 0);
        roots.axis_primary_carbon_g[axis] = 4;
        roots.axis_primary_nitrogen_g[axis] = 2;
        roots.axis_primary_phosphorus_g[axis] = 1;
        roots.axis_secondary_carbon_g[axis] = 2;
        roots.axis_secondary_nitrogen_g[axis] = 1;
        roots.axis_secondary_phosphorus_g[axis] = 0.5;
        roots.axis_primary_length_m[axis] = 18;
        roots.axis_secondary_length_m[axis] = 20;
        roots.axis_primary_count[axis] = 22;
        roots.axis_secondary_count[axis] = 24;
    }

    canopy_state.plant_seed_storage_carbon_g[0] = 10;
    canopy_state.plant_seed_storage_nitrogen_g[0] = 2;
    canopy_state.plant_seed_storage_phosphorus_g[0] = 1;
    var partitions = try litter_partition.State.init(std.testing.allocator, 1);
    defer partitions.deinit();
    const single_component: litter_partition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    partitions.by_plant_and_organ[@intFromEnum(litter_partition.Organ.fine_root)] = single_component;
    partitions.by_plant_and_organ[@intFromEnum(litter_partition.Organ.coarse_wood)] = single_component;
    partitions.by_plant_and_organ[@intFromEnum(litter_partition.Organ.nonstructural)] = single_component;
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 10 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var organic = try soil_organic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    const science = [_]plant_harvest_runtime.ScienceParameters{.{
        .carbon_woody_fraction = .{ 0, 1 },
        .leaf_nitrogen_woody_fraction = .{ 0, 1 },
        .sheath_nitrogen_woody_fraction = .{ 0, 1 },
        .leaf_phosphorus_woody_fraction = .{ 0, 1 },
        .sheath_phosphorus_woody_fraction = .{ 0, 1 },
    }};
    var products = [_]plant_harvest_runtime.ProductLedger{.{}};
    var composition = [_]plant_harvest_runtime.BelowgroundHarvestComposition{.{
        .root_woody_nonwoody = .{ .carbon = .{ 0.2, 0.7 }, .nitrogen = .{ 0.6, 0.4 }, .phosphorus = .{ 0.8, 0.2 } },
        .storage_woody_nonwoody = .{ .carbon = .{ 0.3, 0.7 }, .nitrogen = .{ 0.4, 0.6 }, .phosphorus = .{ 0.7, 0.3 } },
        .perennial = true,
    }};
    var context: plant_harvest_runtime.Context = .{
        .canopy_state = &canopy_state,
        .branch_development = &development,
        .science_by_plant = &science,
        .products_by_plant = &products,
        .leaf_area_presence_tolerance_m2 = 1e-12,
        .root_state = &roots,
        .root_litter_partition = &partitions,
        .soil_organic_state = &organic,
        .grid = &grid,
        .belowground_harvest_composition_by_plant = &composition,
    };

    // Invalid composition is rejected before any donor or recipient changes.
    try std.testing.expectError(error.NonConservativeBelowgroundHarvestComposition, plant_harvest_runtime.applyRootSymbiontHarvest(&context, 0, 0.5));
    try std.testing.expectEqual(@as(f64, 10), canopy_state.plant_seed_storage_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 4), roots.axis_primary_carbon_g[try roots.layerAxisIndex(0, 0, 0, 0)]);
    try std.testing.expectEqual(@as(f64, 0), organic.structural[0].carbon_g_c);
    composition[0].root_woody_nonwoody.carbon[1] = 0.8;

    try plant_harvest_runtime.applyRootSymbiontHarvest(&context, 0, 0.5);
    for (0..root_system.biological_domain_count) |domain| {
        const root = try roots.layerIndex(0, domain, 0);
        inline for (.{
            .{ roots.mobile_carbon_g[root], 1.0 },
            .{ roots.mobile_nitrogen_g[root], 0.5 },
            .{ roots.mobile_phosphorus_g[root], 0.25 },
            .{ roots.total_carbon_g[root], 10.0 },
            .{ roots.primary_root_carbon_g[root], 5.0 },
            .{ roots.protein_carbon_g[root], 2.0 },
            .{ roots.root_length_m_per_plant[root], 4.0 },
            .{ roots.root_length_density_m_per_m3[root], 3.0 },
            .{ roots.gaseous_volume_m3[root], 1.0 },
            .{ roots.aqueous_volume_m3[root], 2.0 },
            .{ roots.root_surface_area_m2_per_plant[root], 5.0 },
            .{ roots.respiration_unlimited_by_oxygen_g_c_per_h[root], 6.0 },
            .{ roots.respiration_unlimited_by_carbon_g_c_per_h[root], 7.0 },
            .{ roots.actual_respiration_g_c_per_h[root], 8.0 },
            .{ roots.secondary_axis_count_total[root], 13.0 },
        }) |pair| try std.testing.expectApproxEqAbs(pair[1], pair[0], 1e-14);
        const axis = try roots.layerAxisIndex(0, domain, 0, 0);
        inline for (.{
            .{ roots.axis_primary_carbon_g[axis], 2.0 },   .{ roots.axis_primary_nitrogen_g[axis], 1.0 },   .{ roots.axis_primary_phosphorus_g[axis], 0.5 },
            .{ roots.axis_secondary_carbon_g[axis], 1.0 }, .{ roots.axis_secondary_nitrogen_g[axis], 0.5 }, .{ roots.axis_secondary_phosphorus_g[axis], 0.25 },
            .{ roots.axis_primary_length_m[axis], 9.0 },   .{ roots.axis_secondary_length_m[axis], 10.0 },  .{ roots.axis_primary_count[axis], 11.0 },
            .{ roots.axis_secondary_count[axis], 12.0 },
        }) |pair| try std.testing.expectApproxEqAbs(pair[1], pair[0], 1e-14);
    }
    try std.testing.expectEqual(@as(f64, 5), canopy_state.plant_seed_storage_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 1), canopy_state.plant_seed_storage_nitrogen_g[0]);
    try std.testing.expectEqual(@as(f64, 0.5), canopy_state.plant_seed_storage_phosphorus_g[0]);

    const woody = organic.structural[0];
    const nonwoody = organic.structural[soil_organic.structural_fraction_count];
    try std.testing.expectApproxEqAbs(@as(f64, 2.7), woody.carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.2), woody.nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.55), woody.phosphorus_g_p, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 10.3), nonwoody.carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.8), nonwoody.nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), nonwoody.phosphorus_g_p, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 26), 8 + canopy_state.plant_seed_storage_carbon_g[0] + woody.carbon_g_c + nonwoody.carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 10), 4 + canopy_state.plant_seed_storage_nitrogen_g[0] + woody.nitrogen_g_n + nonwoody.nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 5), 2 + canopy_state.plant_seed_storage_phosphorus_g[0] + woody.phosphorus_g_p + nonwoody.phosphorus_g_p, 1e-14);
}

test "source-order fire inventory preserves plant layer domain and axis sums" {
    const carbon = struct {
        fn pools(value: f64) plant_harvest_runtime.SourceOrderDeadRootAxisPools {
            return .{
                .primary = .{ .carbon_g = value },
                .secondary = .{ .carbon_g = value },
            };
        }
    }.pools;
    const structural_a = [_]plant_harvest_runtime.SourceOrderDeadRootAxisPools{
        carbon(1), carbon(1), carbon(1), carbon(1),
        carbon(1), carbon(1), carbon(1), carbon(1),
    };
    const structural_b = [_]plant_harvest_runtime.SourceOrderDeadRootAxisPools{ carbon(2), carbon(3) };
    const shoot_a: plant_harvest_runtime.SourceOrderFireShootCarbon = .{
        .canopy_nonstructural_g_c = 1,
        .leaf_g_c = 2,
        .sheath_g_c = 3,
        .stalk_g_c = 4,
        .reserve_g_c = 5,
        .husk_g_c = 6,
        .ear_g_c = 7,
        .grain_g_c = 8,
        .symbiont_nonstructural_g_c = 9,
        .symbiont_biomass_g_c = 10,
        .seasonal_storage_g_c = 11,
        .standing_dead_g_c = 12,
    };
    var shoot_b = shoot_a;
    shoot_b.symbiont_nonstructural_g_c = 90;
    shoot_b.symbiont_biomass_g_c = 100;
    const plants = [_]plant_harvest_runtime.SourceOrderFirePlantInventory{
        .{
            .shoot = shoot_a,
            .canopy_symbiont_included = true,
            .root_domain_count = 2,
            .root_axis_count = 2,
            .nodule_nonstructural_by_layer_g_c = &.{ 1, 2 },
            .nodule_biomass_by_layer_g_c = &.{ 3, 4 },
            .root_nonstructural_by_layer_domain_g_c = &.{ 1, 2, 3, 4 },
            .root_structural_by_layer_domain_axis = &structural_a,
        },
        .{
            .shoot = shoot_b,
            .canopy_symbiont_included = false,
            .root_domain_count = 1,
            .root_axis_count = 1,
            .nodule_nonstructural_by_layer_g_c = &.{ 10, 20 },
            .nodule_biomass_by_layer_g_c = &.{ 30, 40 },
            .root_nonstructural_by_layer_domain_g_c = &.{ 10, 20 },
            .root_structural_by_layer_domain_axis = &structural_b,
        },
    };
    const optional = try plant_harvest_runtime.sourceOrderAggregateFireCarbonInventory(
        std.testing.allocator,
        true,
        2,
        &plants,
    );
    const result = optional.?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 2), result.shoot.canopy_nonstructural_g_c);
    try std.testing.expectEqual(@as(f64, 9), result.shoot.symbiont_nonstructural_g_c);
    try std.testing.expectEqual(@as(f64, 22), result.shoot.seasonal_storage_g_c);
    try std.testing.expectEqual(@as(f64, 13), result.layers[0].root_nonstructural_g_c);
    try std.testing.expectEqual(@as(f64, 12), result.layers[0].root_structural_g_c);
    try std.testing.expectEqual(@as(f64, 11), result.layers[0].nodule_nonstructural_g_c);
    try std.testing.expectEqual(@as(f64, 44), result.layers[1].nodule_biomass_g_c);
    try std.testing.expect((try plant_harvest_runtime.sourceOrderAggregateFireCarbonInventory(
        std.testing.allocator,
        false,
        0,
        &.{},
    )) == null);
}

test "source-order combustion rates preserve independent temperature gates" {
    const specific: plant_harvest_runtime.SourceOrderCombustionSpecificRates = .{
        .living_nonstructural_and_leaf_g_c_m2_h = 1,
        .living_sheath_g_c_m2_h = 2,
        .living_stalk_g_c_m2_h = 3,
        .living_reproductive_g_c_m2_h = 4,
        .standing_dead_g_c_m2_h = 5,
    };
    const living = try plant_harvest_runtime.sourceOrderCombustionRates(
        600,
        500,
        550,
        0.5,
        2,
        3,
        specific,
    );
    try std.testing.expectEqual(@as(f64, 0.5), living.living_temperature_fraction);
    try std.testing.expectEqual(@as(f64, 3), living.living_nonstructural_and_leaf_g_c_step);
    try std.testing.expectEqual(@as(f64, 6), living.living_sheath_g_c_step);
    try std.testing.expectEqual(@as(f64, 9), living.living_stalk_g_c_step);
    try std.testing.expectEqual(@as(f64, 12), living.living_reproductive_g_c_step);
    try std.testing.expectEqual(@as(f64, 0), living.standing_dead_g_c_step);

    const dead = try plant_harvest_runtime.sourceOrderCombustionRates(
        500,
        600,
        550,
        0.5,
        2,
        3,
        specific,
    );
    try std.testing.expectEqual(@as(f64, 0), dead.living_temperature_fraction);
    try std.testing.expectEqual(@as(f64, 0.5), dead.standing_dead_temperature_fraction);
    try std.testing.expectEqual(@as(f64, 15), dead.standing_dead_g_c_step);

    const cold = try plant_harvest_runtime.sourceOrderCombustionRates(
        550,
        550,
        550,
        0.5,
        2,
        3,
        specific,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        cold.living_nonstructural_and_leaf_g_c_step,
    );
    try std.testing.expectEqual(@as(f64, 0), cold.standing_dead_g_c_step);
}

test "source-order shoot combustion fractions preserve pool gates and routing" {
    const totals: plant_harvest_runtime.SourceOrderShootCombustionTotals = .{
        .canopy_nonstructural_g_c = 10,
        .leaf_g_c = 10,
        .sheath_g_c = 10,
        .stalk_g_c = 10,
        .husk_g_c = 10,
        .ear_g_c = 10,
        .grain_g_c = 10,
        .symbiont_nonstructural_g_c = 10,
        .symbiont_biomass_g_c = 10,
        .standing_dead_g_c = 10,
    };
    const rates: plant_harvest_runtime.SourceOrderCombustionRates = .{
        .living_temperature_fraction = 1,
        .standing_dead_temperature_fraction = 1,
        .living_nonstructural_and_leaf_g_c_step = 1,
        .living_sheath_g_c_step = 2,
        .living_stalk_g_c_step = 3,
        .living_reproductive_g_c_step = 4,
        .standing_dead_g_c_step = 5,
    };
    const woody = try plant_harvest_runtime.sourceOrderShootCombustionFractions(
        totals,
        rates,
        0,
        1,
        2,
    );
    try std.testing.expectEqual(@as(f64, 0.1), woody.canopy_nonstructural);
    try std.testing.expectEqual(@as(f64, 0.3), woody.sheath);
    try std.testing.expectEqual(@as(f64, 0.4), woody.stalk);
    try std.testing.expectEqual(woody.stalk, woody.reserve);
    try std.testing.expectEqual(@as(f64, 0.2), woody.ear);
    try std.testing.expectEqual(@as(f64, 0.5), woody.standing_dead);

    const herbaceous = try plant_harvest_runtime.sourceOrderShootCombustionFractions(
        totals,
        rates,
        0,
        0,
        2,
    );
    try std.testing.expectEqual(@as(f64, 0.2), herbaceous.sheath);
    try std.testing.expectEqual(@as(f64, 0.2), herbaceous.stalk);
    var sparse = totals;
    sparse.leaf_g_c = 1.0e-12;
    const gated = try plant_harvest_runtime.sourceOrderShootCombustionFractions(
        sparse,
        rates,
        1.0e-12,
        0,
        2,
    );
    try std.testing.expectEqual(@as(f64, 0), gated.leaf);
    inline for (@typeInfo(plant_harvest_runtime.SourceOrderShootCombustionFractions).@"struct".fields) |field| {
        const value = @field(woody, field.name);
        try std.testing.expect(value >= 0 and value <= 1);
    }
}

test "source-order branch combustion conserves C N P and signed ledgers" {
    const mass: canopy.ElementalMass = .{
        .carbon_g = 1,
        .nitrogen_g = 2,
        .phosphorus_g = 3,
    };
    const branch: plant_harvest_runtime.SourceOrderShootCombustionBranchPools = .{
        .canopy_nonstructural = mass,
        .leaf = mass,
        .sheath = mass,
        .stalk = mass,
        .reserve = mass,
        .husk = mass,
        .ear = mass,
        .grain = mass,
        .symbiont_nonstructural = mass,
        .symbiont_biomass = mass,
    };
    const fractions: plant_harvest_runtime.SourceOrderShootCombustionFractions = .{
        .canopy_nonstructural = 0.5,
        .leaf = 0.5,
        .sheath = 0.5,
        .stalk = 0.5,
        .reserve = 0.5,
        .husk = 0.5,
        .ear = 0.5,
        .grain = 0.5,
        .symbiont_nonstructural = 0.5,
        .symbiont_biomass = 0.5,
        .standing_dead = 0.5,
    };
    const result = try plant_harvest_runtime.sourceOrderShootCombustionLosses(
        std.testing.allocator,
        &.{ branch, branch },
        fractions,
        1,
        .{ .carbon_g = 100, .nitrogen_g = 200, .phosphorus_g = 300 },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.branches.len);
    try std.testing.expectEqual(@as(f64, 5), result.branches[0].total_combusted.carbon_g);
    try std.testing.expectEqual(@as(f64, 10), result.branches[0].total_combusted.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 15), result.branches[0].total_combusted.phosphorus_g);
    try std.testing.expectEqual(@as(f64, 11), result.cumulative_canopy_combustion_g_c);
    try std.testing.expectEqual(@as(f64, 90), result.disturbance_emission_ledger.carbon_g);
    try std.testing.expectEqual(@as(f64, 180), result.disturbance_emission_ledger.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 270), result.disturbance_emission_ledger.phosphorus_g);
    try std.testing.expectEqual(
        @as(f64, 10),
        100 - result.disturbance_emission_ledger.carbon_g,
    );
}

test "source-order shoot salt combustion conserves all eight species" {
    const branch: plant_harvest_runtime.SourceOrderShootSaltInventory = .{
        .aluminum_mol = 1,
        .iron_mol = 2,
        .calcium_mol = 3,
        .magnesium_mol = 4,
        .sodium_mol = 5,
        .potassium_mol = 6,
        .sulfate_mol = 7,
        .chloride_mol = 8,
    };
    const optional = try plant_harvest_runtime.sourceOrderShootSaltCombustion(
        std.testing.allocator,
        true,
        0.25,
        &.{ branch, branch },
    );
    const result = optional.?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(f64, 0.25), result[0].combusted.aluminum_mol);
    try std.testing.expectEqual(@as(f64, 2), result[0].combusted.chloride_mol);
    try std.testing.expectEqual(@as(f64, 6), result[0].remaining.chloride_mol);
    inline for (@typeInfo(plant_harvest_runtime.SourceOrderShootSaltInventory).@"struct".fields) |field| {
        try std.testing.expectEqual(
            @field(branch, field.name),
            @field(result[0].combusted, field.name) +
                @field(result[0].remaining, field.name),
        );
    }
    try std.testing.expect((try plant_harvest_runtime.sourceOrderShootSaltCombustion(
        std.testing.allocator,
        false,
        2,
        &.{},
    )) == null);
}

test "source-order uncombusted shoot state conserves pools and runtime topology" {
    const pool: canopy.ElementalMass = .{
        .carbon_g = 10,
        .nitrogen_g = 20,
        .phosphorus_g = 30,
    };
    const burned_mass: canopy.ElementalMass = .{
        .carbon_g = 2,
        .nitrogen_g = 4,
        .phosphorus_g = 6,
    };
    const pools: plant_harvest_runtime.SourceOrderShootCombustionBranchPools = .{
        .canopy_nonstructural = pool,
        .leaf = pool,
        .sheath = pool,
        .stalk = pool,
        .reserve = pool,
        .husk = pool,
        .ear = pool,
        .grain = pool,
        .symbiont_nonstructural = pool,
        .symbiont_biomass = pool,
    };
    const burned: plant_harvest_runtime.SourceOrderShootCombustionBranchPools = .{
        .canopy_nonstructural = burned_mass,
        .leaf = burned_mass,
        .sheath = burned_mass,
        .stalk = burned_mass,
        .reserve = burned_mass,
        .husk = burned_mass,
        .ear = burned_mass,
        .grain = burned_mass,
        .symbiont_nonstructural = burned_mass,
        .symbiont_biomass = burned_mass,
    };
    var nodes = [_]plant_harvest_runtime.SourceOrderShootCombustionNodeState{.{
        .leaf_area_m2 = 4,
        .sheath_height_m = 6,
        .green_leaf = pool,
        .senescent_leaf_carbon_g_c = 8,
        .green_sheath = pool,
        .senescent_sheath_carbon_g_c = 10,
        .node = pool,
    }};
    var layers = [_]plant_harvest_runtime.SourceOrderShootCombustionNodeLayerState{
        .{ .leaf_area_m2 = 2, .green_leaf = pool },
        .{ .leaf_area_m2 = 4, .green_leaf = pool },
    };
    var branches = [_]plant_harvest_runtime.SourceOrderUncombustedBranchState{.{
        .pools = pools,
        .c4_intermediate_carbon_g_c = 1,
        .total_shoot = .{},
        .leaf_area_m2 = 12,
        .nodes = &nodes,
        .node_layers = &layers,
        .canopy_layer_count = 2,
    }};
    var fractions = std.mem.zeroes(plant_harvest_runtime.SourceOrderShootCombustionFractions);
    fractions.leaf = 0.25;
    fractions.sheath = 0.5;
    fractions.stalk = 0.75;
    try plant_harvest_runtime.sourceOrderApplyUncombustedShootState(&branches, &.{burned}, fractions);
    try std.testing.expectEqual(@as(f64, 8), branches[0].pools.leaf.carbon_g);
    try std.testing.expectEqual(@as(f64, 65), branches[0].total_shoot.carbon_g);
    try std.testing.expectEqual(@as(f64, 128), branches[0].total_shoot.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 9), branches[0].leaf_area_m2);
    try std.testing.expectEqual(@as(f64, 3), nodes[0].leaf_area_m2);
    try std.testing.expectEqual(@as(f64, 3), nodes[0].sheath_height_m);
    try std.testing.expectEqual(@as(f64, 2.5), nodes[0].node.carbon_g);
    try std.testing.expectEqual(@as(f64, 1.5), layers[0].leaf_area_m2);
    try std.testing.expectEqual(@as(f64, 7.5), layers[1].green_leaf.carbon_g);
}

test "source-order standing dead combustion conserves components and ledgers" {
    const components = [_]canopy.ElementalMass{
        .{ .carbon_g = 1, .nitrogen_g = 2, .phosphorus_g = 3 },
        .{ .carbon_g = 2, .nitrogen_g = 4, .phosphorus_g = 6 },
        .{ .carbon_g = 3, .nitrogen_g = 6, .phosphorus_g = 9 },
        .{ .carbon_g = 4, .nitrogen_g = 8, .phosphorus_g = 12 },
    };
    const result = try plant_harvest_runtime.sourceOrderStandingDeadCombustion(
        std.testing.allocator,
        &components,
        0.25,
        10,
        .{ .carbon_g = 100, .nitrogen_g = 200, .phosphorus_g = 300 },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), result.components.len);
    try std.testing.expectEqual(@as(f64, 0.25), result.components[0].combusted.carbon_g);
    try std.testing.expectEqual(@as(f64, 3), result.components[3].remaining.carbon_g);
    try std.testing.expectEqual(
        @as(f64, 12.5),
        result.cumulative_standing_dead_combustion_g_c,
    );
    try std.testing.expectEqual(@as(f64, 97.5), result.disturbance_emission_ledger.carbon_g);
    try std.testing.expectEqual(@as(f64, 195), result.disturbance_emission_ledger.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 292.5), result.disturbance_emission_ledger.phosphorus_g);
    for (components, result.components) |before, after| {
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
            try std.testing.expectEqual(
                @field(before, field.name),
                @field(after.combusted, field.name) +
                    @field(after.remaining, field.name),
            );
    }
}

test "source-order charcoal combustion preserves response fraction and ledgers" {
    const result = try plant_harvest_runtime.sourceOrderCharcoalCombustion(
        700,
        0.5,
        2,
        3,
        4,
        24,
        1.0e-12,
        .{ .carbon_g = 10, .nitrogen_g = 2, .phosphorus_g = 1 },
        7,
        .{ .carbon_g = 100, .nitrogen_g = 20, .phosphorus_g = 10 },
        100,
        3,
    );
    try std.testing.expectEqual(@as(f64, 0.5), result.temperature_response);
    try std.testing.expectEqual(@as(f64, 12), result.potential_combustion_g_c_step);
    try std.testing.expectEqual(@as(f64, 0.5), result.combustion_fraction);
    try std.testing.expectEqual(@as(f64, 5), result.combusted.carbon_g);
    try std.testing.expectEqual(@as(f64, 5), result.remaining.carbon_g);
    try std.testing.expectEqual(@as(f64, 12), result.cumulative_standing_dead_combustion_g_c);
    try std.testing.expectEqual(@as(f64, 95), result.disturbance_emission_ledger.carbon_g);
    try std.testing.expectEqual(@as(f64, 19), result.disturbance_emission_ledger.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 9.5), result.disturbance_emission_ledger.phosphorus_g);
    try std.testing.expectEqual(@as(f64, 115), result.grid_total_combustion_g_c);
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        try std.testing.expectEqual(
            @field(result.combusted, field.name) +
                @field(result.remaining, field.name),
            @field(canopy.ElementalMass{
                .carbon_g = 10,
                .nitrogen_g = 2,
                .phosphorus_g = 1,
            }, field.name),
        );
}

test "source-order no-combustion branch resets every combustion rate" {
    const result = try plant_harvest_runtime.sourceOrderResetNoCombustion(std.testing.allocator, 3, true);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 0), result.canopy_combustion_g_c_step);
    try std.testing.expectEqual(@as(f64, 0), result.standing_dead_combustion_g_c_step);
    try std.testing.expectEqual(@as(f64, 0), result.canopy_temperature_response);
    try std.testing.expectEqual(@as(f64, 0), result.standing_dead_temperature_response);
    try std.testing.expectEqual(@as(usize, 3), result.branch_combustion.len);
    try std.testing.expectEqual(@as(usize, 5), result.standing_dead_combustion.len);
    for (result.branch_combustion) |branch|
        inline for (@typeInfo(plant_harvest_runtime.SourceOrderShootCombustionBranchPools).@"struct".fields) |field|
            try std.testing.expectEqual(
                std.mem.zeroes(canopy.ElementalMass),
                @field(branch, field.name),
            );
    const salts = result.branch_salt_combustion.?;
    try std.testing.expectEqual(@as(usize, 3), salts.len);
    for (salts) |salt|
        inline for (@typeInfo(plant_harvest_runtime.SourceOrderShootSaltInventory).@"struct".fields) |field|
            try std.testing.expectEqual(@as(f64, 0), @field(salt, field.name));
    for (result.standing_dead_combustion) |component|
        try std.testing.expectEqual(std.mem.zeroes(canopy.ElementalMass), component);

    const without_salt = try plant_harvest_runtime.sourceOrderResetNoCombustion(
        std.testing.allocator,
        0,
        false,
    );
    defer without_salt.deinit(std.testing.allocator);
    try std.testing.expect(without_salt.branch_salt_combustion == null);
}

test "source-order root and surface storage combustion preserves source fractions" {
    const specific: plant_harvest_runtime.SourceOrderCombustionSpecificRates = .{
        .living_nonstructural_and_leaf_g_c_m2_h = 1,
        .living_sheath_g_c_m2_h = 2,
        .living_stalk_g_c_m2_h = 3,
        .living_reproductive_g_c_m2_h = 4,
        .standing_dead_g_c_m2_h = 5,
    };
    const result = try plant_harvest_runtime.sourceOrderRootStorageCombustion(.{
        .soil_temperature_k = 600,
        .minimum_combustion_temperature_k = 500,
        .maximum_temperature_response = 0.5,
        .surface_area_m2 = 2,
        .biological_timestep_h = 1,
        .specific_rates = specific,
        .totals = .{
            .root_nonstructural_g_c = 4,
            .active_root_g_c = 12,
            .nodule_nonstructural_g_c = 8,
            .nodule_biomass_g_c = 16,
        },
        .negligible_carbon_g_c = 1.0e-12,
        .is_surface_layer = true,
        .storage = .{ .carbon_g = 6, .nitrogen_g = 3, .phosphorus_g = 1.5 },
        .preceding_layer_combustion_g_c = 10,
        .preceding_disturbance_emission_ledger = .{ .carbon_g = 100, .nitrogen_g = 50, .phosphorus_g = 25 },
    });
    try std.testing.expectEqual(@as(f64, 0.5), result.temperature_response);
    try std.testing.expectEqual(@as(f64, 1), result.potential_rates.root_nonstructural_g_c_step);
    try std.testing.expectEqual(@as(f64, 2), result.potential_rates.nodule_biomass_g_c_step);
    try std.testing.expectEqual(@as(f64, 3), result.potential_rates.active_root_g_c_step);
    try std.testing.expectEqual(@as(f64, 0.25), result.fractions.root_nonstructural);
    try std.testing.expectEqual(@as(f64, 0.25), result.fractions.active_root);
    try std.testing.expectEqual(@as(f64, 0.125), result.fractions.nodule_nonstructural);
    try std.testing.expectEqual(@as(f64, 0.125), result.fractions.nodule_biomass);
    try std.testing.expectEqual(result.fractions.active_root, result.fractions.storage);
    try std.testing.expectEqual(@as(f64, 1.5), result.storage_combusted.carbon_g);
    try std.testing.expectEqual(@as(f64, 4.5), result.storage_remaining.carbon_g);
    try std.testing.expectEqual(@as(f64, 11.5), result.layer_combustion_g_c);
    try std.testing.expectEqual(@as(f64, 98.5), result.disturbance_emission_ledger.carbon_g);
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        try std.testing.expectEqual(
            @field(result.storage_combusted, field.name) +
                @field(result.storage_remaining, field.name),
            @field(canopy.ElementalMass{
                .carbon_g = 6,
                .nitrogen_g = 3,
                .phosphorus_g = 1.5,
            }, field.name),
        );

    const subsurface = try plant_harvest_runtime.sourceOrderRootStorageCombustion(.{
        .soil_temperature_k = 600,
        .minimum_combustion_temperature_k = 500,
        .maximum_temperature_response = 0.5,
        .surface_area_m2 = 2,
        .biological_timestep_h = 1,
        .specific_rates = specific,
        .totals = .{
            .root_nonstructural_g_c = 4,
            .active_root_g_c = 12,
            .nodule_nonstructural_g_c = 8,
            .nodule_biomass_g_c = 16,
        },
        .negligible_carbon_g_c = 1.0e-12,
        .is_surface_layer = false,
        .storage = .{ .carbon_g = 6, .nitrogen_g = 3, .phosphorus_g = 1.5 },
        .preceding_layer_combustion_g_c = 10,
        .preceding_disturbance_emission_ledger = .{ .carbon_g = 100, .nitrogen_g = 50, .phosphorus_g = 25 },
    });
    try std.testing.expectEqual(@as(f64, 0), subsurface.fractions.storage);
    try std.testing.expectEqual(@as(f64, 6), subsurface.storage_remaining.carbon_g);
    try std.testing.expectEqual(@as(f64, 10), subsurface.layer_combustion_g_c);
}

test "source-order root-domain combustion conserves runtime domains and axes" {
    var axes = [_]plant_harvest_runtime.SourceOrderRootCombustionAxisState{
        .{
            .primary = .{ .carbon_g = 8, .nitrogen_g = 4, .phosphorus_g = 2 },
            .secondary = .{ .carbon_g = 4, .nitrogen_g = 2, .phosphorus_g = 1 },
            .whole_primary = .{ .carbon_g = 16, .nitrogen_g = 8, .phosphorus_g = 4 },
            .primary_length_m = 10,
            .secondary_length_m = 6,
            .secondary_root_number = 2,
        },
        .{
            .primary = .{ .carbon_g = 12, .nitrogen_g = 6, .phosphorus_g = 3 },
            .secondary = .{ .carbon_g = 8, .nitrogen_g = 4, .phosphorus_g = 2 },
            .whole_primary = .{ .carbon_g = 20, .nitrogen_g = 10, .phosphorus_g = 5 },
            .primary_length_m = 14,
            .secondary_length_m = 8,
            .secondary_root_number = 4,
        },
    };
    var domains = [_]plant_harvest_runtime.SourceOrderRootCombustionDomainState{.{
        .nonstructural = .{ .carbon_g = 10, .nitrogen_g = 5, .phosphorus_g = 2 },
        .salts = .{
            .aluminum_mol = 1,
            .iron_mol = 2,
            .calcium_mol = 3,
            .magnesium_mol = 4,
            .sodium_mol = 5,
            .potassium_mol = 6,
            .sulfate_mol = 7,
            .chloride_mol = 8,
        },
        .active_root_carbon_g_c = 100,
        .root_density_g_c_m3 = 20,
        .root_surface_area_m2 = 30,
        .primary_root_number = 4,
        .root_length_m = 5,
        .root_length_growth_m_step = 6,
        .root_depth_growth_m_step = 7,
        .root_volume_growth_m3_step = 8,
        .root_volume_m3 = 9,
        .root_area_m2 = 10,
        .axes = &axes,
    }};
    const result = try plant_harvest_runtime.sourceOrderApplyRootDomainCombustion(
        std.testing.allocator,
        &domains,
        0.2,
        0.25,
        true,
        5,
        .{ .carbon_g = 100, .nitrogen_g = 50, .phosphorus_g = 25 },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.losses.len);
    try std.testing.expectEqual(@as(f64, 2), result.losses[0].nonstructural.carbon_g);
    try std.testing.expectEqual(@as(f64, 8), domains[0].nonstructural.carbon_g);
    try std.testing.expectEqual(@as(f64, 0.2), result.losses[0].salts.?.aluminum_mol);
    try std.testing.expectEqual(@as(f64, 0.8), domains[0].salts.aluminum_mol);
    try std.testing.expectEqual(@as(f64, 8), result.losses[0].structural.carbon_g);
    try std.testing.expectEqual(@as(f64, 6), axes[0].primary.carbon_g);
    try std.testing.expectEqual(@as(f64, 3), axes[0].secondary.carbon_g);
    try std.testing.expectEqual(@as(f64, 75), domains[0].active_root_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 7.5), axes[0].primary_length_m);
    try std.testing.expectEqual(@as(f64, 15), result.layer_combustion_g_c);
    try std.testing.expectEqual(@as(f64, 90), result.disturbance_emission_ledger.carbon_g);
    try std.testing.expectEqual(@as(f64, 45), result.disturbance_emission_ledger.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 22.6), result.disturbance_emission_ledger.phosphorus_g);
}

test "source-order root-nodule combustion conserves pools and source ledgers" {
    const result = try plant_harvest_runtime.sourceOrderRootNoduleCombustion(
        .{ .carbon_g = 8, .nitrogen_g = 4, .phosphorus_g = 2 },
        .{ .carbon_g = 12, .nitrogen_g = 6, .phosphorus_g = 3 },
        0.25,
        0.5,
        10,
        100,
        .{ .carbon_g = 50, .nitrogen_g = 25, .phosphorus_g = 12 },
    );
    try std.testing.expectEqual(@as(f64, 2), result.nonstructural_combusted.carbon_g);
    try std.testing.expectEqual(@as(f64, 6), result.nonstructural_remaining.carbon_g);
    try std.testing.expectEqual(@as(f64, 6), result.biomass_combusted.carbon_g);
    try std.testing.expectEqual(@as(f64, 6), result.biomass_remaining.carbon_g);
    try std.testing.expectEqual(@as(f64, 18), result.layer_plant_combustion_g_c);
    try std.testing.expectEqual(@as(f64, 118), result.grid_layer_combustion_g_c);
    try std.testing.expectEqual(@as(f64, 42), result.disturbance_emission_ledger.carbon_g);
    try std.testing.expectEqual(@as(f64, 21), result.disturbance_emission_ledger.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 10), result.disturbance_emission_ledger.phosphorus_g);
    inline for (.{ .{
        result.nonstructural_combusted,
        result.nonstructural_remaining,
        canopy.ElementalMass{ .carbon_g = 8, .nitrogen_g = 4, .phosphorus_g = 2 },
    }, .{
        result.biomass_combusted,
        result.biomass_remaining,
        canopy.ElementalMass{ .carbon_g = 12, .nitrogen_g = 6, .phosphorus_g = 3 },
    } }) |pools|
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
            try std.testing.expectEqual(
                @field(pools[2], field.name),
                @field(pools[0], field.name) + @field(pools[1], field.name),
            );
}

test "source-order cold-soil reset preserves heterogeneous runtime topology" {
    const axis_counts = [_]usize{ 2, 0, 1 };
    const result = try plant_harvest_runtime.sourceOrderResetColdSoilCombustion(
        std.testing.allocator,
        &axis_counts,
        true,
        true,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 0), result.layer_plant_combustion_g_c);
    try std.testing.expectEqual(std.mem.zeroes(canopy.ElementalMass), result.storage_combustion.?);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 2, 3 }, result.axis_offsets);
    try std.testing.expectEqual(@as(usize, 3), result.domains.len);
    try std.testing.expectEqual(@as(usize, 3), result.axes.len);
    for (result.domains) |domain| {
        try std.testing.expectEqual(std.mem.zeroes(canopy.ElementalMass), domain.nonstructural);
        try std.testing.expectEqual(std.mem.zeroes(canopy.ElementalMass), domain.structural);
        const salts = domain.salts.?;
        inline for (@typeInfo(plant_harvest_runtime.SourceOrderShootSaltInventory).@"struct".fields) |field|
            try std.testing.expectEqual(@as(f64, 0), @field(salts, field.name));
    }
    for (result.axes) |axis| {
        try std.testing.expectEqual(std.mem.zeroes(canopy.ElementalMass), axis.primary);
        try std.testing.expectEqual(std.mem.zeroes(canopy.ElementalMass), axis.secondary);
    }
    try std.testing.expectEqual(
        std.mem.zeroes(canopy.ElementalMass),
        result.nodule_nonstructural_combustion,
    );
    try std.testing.expectEqual(
        std.mem.zeroes(canopy.ElementalMass),
        result.nodule_biomass_combustion,
    );

    const subsurface = try plant_harvest_runtime.sourceOrderResetColdSoilCombustion(
        std.testing.allocator,
        &.{},
        false,
        false,
    );
    defer subsurface.deinit(std.testing.allocator);
    try std.testing.expect(subsurface.storage_combustion == null);
    try std.testing.expectEqualSlices(usize, &.{0}, subsurface.axis_offsets);
}

test "source-order dormant-seed activation uses first qualifying branch" {
    const activation = (try plant_harvest_runtime.sourceOrderDormantSeedActivation(
        true,
        true,
        &.{
            .{
                .leafout_disabled = true,
                .accumulated_leafout_h = 100,
                .required_leafout_h = 10,
            },
            .{
                .leafout_disabled = false,
                .accumulated_leafout_h = 9,
                .required_leafout_h = 10,
            },
            .{
                .leafout_disabled = false,
                .accumulated_leafout_h = 10,
                .required_leafout_h = 10,
            },
            .{
                .leafout_disabled = false,
                .accumulated_leafout_h = 20,
                .required_leafout_h = 10,
            },
        },
        150,
        2025,
        0.02,
    )).?;
    try std.testing.expectEqual(@as(usize, 2), activation.qualifying_branch_index);
    try std.testing.expectEqual(@as(u16, 150), activation.planting_day_of_year);
    try std.testing.expectEqual(@as(i32, 2025), activation.planting_year);
    try std.testing.expectEqual(@as(f64, 0.025), activation.seeding_depth_m);
    try std.testing.expect(!activation.initialization_pending);
}

test "source-order dormant-seed activation preserves iteration and pending gates" {
    const ready = [_]plant_harvest_runtime.SourceOrderDormantSeedBranch{.{
        .leafout_disabled = false,
        .accumulated_leafout_h = 1,
        .required_leafout_h = 1,
    }};
    try std.testing.expect((try plant_harvest_runtime.sourceOrderDormantSeedActivation(
        false,
        true,
        &ready,
        1,
        2025,
        0,
    )) == null);
    try std.testing.expect((try plant_harvest_runtime.sourceOrderDormantSeedActivation(
        true,
        false,
        &ready,
        1,
        2025,
        0,
    )) == null);
    try std.testing.expectError(
        error.InvalidDormantSeedLeafoutHours,
        plant_harvest_runtime.sourceOrderDormantSeedActivation(
            true,
            true,
            &.{.{
                .leafout_disabled = false,
                .accumulated_leafout_h = std.math.nan(f64),
                .required_leafout_h = 1,
            }},
            1,
            2025,
            0,
        ),
    );
}

test "source-order litterfall accumulation preserves position fraction layer order" {
    var carbon: [20]f64 = undefined;
    var nitrogen: [20]f64 = undefined;
    var phosphorus: [20]f64 = undefined;
    for (0..20) |index| {
        carbon[index] = @floatFromInt(index + 1);
        nitrogen[index] = carbon[index] * 0.1;
        phosphorus[index] = carbon[index] * 0.01;
    }
    const result = try plant_harvest_runtime.sourceOrderAccumulateLitterfall(std.testing.allocator, .{
        .carbon_g_c_by_position_fraction_layer = &carbon,
        .nitrogen_g_n_by_position_fraction_layer = &nitrogen,
        .phosphorus_g_p_by_position_fraction_layer = &phosphorus,
        .layer_count_including_surface = 2,
        .preceding_cumulative_surface_litter = .{ .carbon_g = 5, .nitrogen_g = 0.5, .phosphorus_g = 0.05 },
        .preceding_hourly_litter = .{ .carbon_g = 7, .nitrogen_g = 0.7, .phosphorus_g = 0.07 },
        .preceding_cumulative_litter = .{ .carbon_g = 11, .nitrogen_g = 1.1, .phosphorus_g = 0.11 },
        .preceding_layer_carbon_g_c = &.{ 13, 17 },
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 105), result.cumulative_surface_litter.carbon_g);
    try std.testing.expectApproxEqAbs(
        @as(f64, 10.5),
        result.cumulative_surface_litter.nitrogen_g,
        1.0e-14,
    );
    try std.testing.expectEqual(@as(f64, 217), result.hourly_litter.carbon_g);
    try std.testing.expectEqual(@as(f64, 221), result.cumulative_litter.carbon_g);
    try std.testing.expectEqualSlices(f64, &.{ 113, 127 }, result.layer_carbon_g_c);
}

test "source-order litterfall accumulation rejects a late invalid value atomically" {
    var values = [_]f64{0} ** 10;
    values[9] = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidLitterfallAccumulationInput,
        plant_harvest_runtime.sourceOrderAccumulateLitterfall(std.testing.allocator, .{
            .carbon_g_c_by_position_fraction_layer = &values,
            .nitrogen_g_n_by_position_fraction_layer = &([_]f64{0} ** 10),
            .phosphorus_g_p_by_position_fraction_layer = &([_]f64{0} ** 10),
            .layer_count_including_surface = 1,
            .preceding_cumulative_surface_litter = .{},
            .preceding_hourly_litter = .{},
            .preceding_cumulative_litter = .{},
            .preceding_layer_carbon_g_c = &.{0},
        }),
    );
}
