//! `plant_harvest_runtime` declarations: tests.
//!
//! Split out of `plant_harvest_runtime.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const management = @import("plant_management.zig");
const canopy = @import("../canopy/photosynthesis/photosynthesis.zig");
const phenology = @import("../plant/lifecycle/phenology.zig");
const growth_stages = @import("../plant/lifecycle/growth_stages.zig");
const root_system = @import("../plant/root/plant_root_system.zig");
const root_disturbance = @import("../plant/root/plant_root_disturbance.zig");
const symbiotic_fixation = @import("../canopy/symbiosis/plant_symbiotic_fixation.zig");
const root_litterfall = @import("../plant/root/plant_root_litterfall.zig");
const root_litter_ledger = @import("../plant/root/plant_root_litter_budget.zig");
const litter_partition = @import("../plant/partition/litter.zig");
const soil_organic = @import("../soil/organic/initialization.zig");
const grid_module = @import("../state/grid.zig");
const carbon_exchange = @import("../canopy/photosynthesis/carbon_exchange.zig");
const shoot_litter_bridge = @import("../plant/growth/shoot_litter_bridge.zig");
const canopy_structure = @import("../canopy/morphology/structure.zig");
const canopy_layers = @import("../canopy/radiation/layer_distribution.zig");
const canopy_biochemistry = @import("../canopy/photosynthesis/biochemistry.zig");
const dormancy = @import("../plant/lifecycle/dormancy.zig");
const grazing_manure = @import("grazing_manure.zig");
const surface_nutrients = @import("../soil/biogeochemistry/organic_matter_fire_exchange.zig");
const spring_reproductive_litterfall = @import("../plant/growth/spring_reproductive_litterfall.zig");
const group_apply = @import("plant_harvest_runtime_apply.zig");
const group_harvest = @import("plant_harvest_runtime_harvest.zig");
const group_misc = @import("plant_harvest_runtime_misc.zig");
const group_mortality = @import("plant_harvest_runtime_mortality.zig");
const group_types = @import("plant_harvest_runtime_types.zig");

test "harvest product subtraction rejects sub-legacy-tolerance overdraw atomically" {
    var target: canopy.ElementalMass = .{ .carbon_g = 1, .nitrogen_g = 2, .phosphorus_g = 3 };
    const before = target;
    try std.testing.expectError(error.HarvestProductSubtractionWouldOverdraw, group_misc.subtractMass(
        &target,
        .{ .carbon_g = 1 + 5e-13, .nitrogen_g = 1, .phosphorus_g = 1 },
    ));
    try std.testing.expectEqualDeep(before, target);
}

test "GROSUB JHVST two resets population and retains exports for reseeding" {
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{0});
    defer state.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    state.plant_population_per_m2[0] = 3;
    state.plant_population_count[0] = 6;
    state.plant_population_change_count[0] = 6;
    state.plant_standing_dead_population_count[0] = 2;
    state.plant_seed_storage_carbon_g[0] = 1;
    state.plant_seed_storage_nitrogen_g[0] = 0.1;
    state.plant_seed_storage_phosphorus_g[0] = 0.01;
    const science = [_]group_types.ScienceParameters{.{ .carbon_woody_fraction = .{ 0, 1 }, .leaf_nitrogen_woody_fraction = .{ 0, 1 }, .sheath_nitrogen_woody_fraction = .{ 0, 1 }, .leaf_phosphorus_woody_fraction = .{ 0, 1 }, .sheath_phosphorus_woody_fraction = .{ 0, 1 } }};
    var ledgers = [_]group_types.ProductLedger{.{}};
    ledgers[0].foliar.ecosystem_export = .{ .carbon_g = 4, .nitrogen_g = 0.4, .phosphorus_g = 0.04 };
    ledgers[0].standing_dead_export = .{ .carbon_g = 2, .nitrogen_g = 0.2, .phosphorus_g = 0.02 };
    const target_population_per_m2 = [_]f64{7};
    const cell_area_m2 = [_]f64{2};
    var plant_state = try phenology.State.init(std.testing.allocator, 1, 1);
    defer plant_state.deinit();
    plant_state.active[0] = true;
    plant_state.lifecycle_initialized[0] = true;
    var context: group_misc.Context = .{
        .canopy_state = &state,
        .branch_development = &development,
        .science_by_plant = &science,
        .products_by_plant = &ledgers,
        .leaf_area_presence_tolerance_m2 = 1e-12,
        .reseed_population_per_m2_by_plant = &target_population_per_m2,
        .cell_area_m2_by_cell = &cell_area_m2,
        .plant_phenology = &plant_state,
    };
    try group_apply.applyEventInternal(&context, 0, .{
        .date = .{ .day = 1, .month = 1, .year = 9999 },
        .kind = .grain,
        .termination = .terminate_and_reseed,
        .cutting_height_m_or_lai_fraction = 0,
        .thinning_fraction_or_consumption_rate = 1,
        .harvested_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 1 },
        .ecosystem_export_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 1 },
    }, false, false);
    try std.testing.expectApproxEqAbs(@as(f64, 7), state.plant_population_per_m2[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 14), state.plant_population_count[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 14), state.plant_population_change_count[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 14), state.plant_standing_dead_population_count[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7), state.plant_seed_storage_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), state.plant_seed_storage_nitrogen_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.07), state.plant_seed_storage_phosphorus_g[0], 1e-12);
    try std.testing.expectEqual(canopy.ElementalMass{}, ledgers[0].foliar.ecosystem_export);
    try std.testing.expectEqual(canopy.ElementalMass{}, ledgers[0].standing_dead_export);
    try std.testing.expect(plant_state.reseed_pending[0]);
    try std.testing.expect(plant_state.active[0]);
    try std.testing.expect(plant_state.lifecycle_initialized[0]);
}

test "GROSUB grain harvest cuts vegetative leaf/sheath/stalk/reserve carbon, not just reproductive organs" {
    // Regression test for the fix to the defect where applyEventInternal
    // unconditionally skipped harvestVegetativeBranch whenever
    // event.kind == .grain, leaving 100% of leaf/sheath/stalk/reserve
    // carbon on the plant after a grain harvest -- grosub.f runs the
    // identical cutting-height transaction for IHVST=1 (grain) as for any
    // other non-grazing harvest code (grosub.f:8566-8568, :8872-8873,
    // :10604-10619).
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{0});
    defer state.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    state.plant_population_per_m2[0] = 1;
    state.plant_population_count[0] = 1;
    state.node_height_m[0] = 2;
    state.node_internode_length_m[0] = 2;
    state.branch_stalk_carbon_g[0] = 4;
    state.branch_reserve_carbon_g[0] = 1;
    state.branch_mobile_carbon_g[0] = 2;
    state.branch_husk_carbon_g[0] = 1;
    state.branch_ear_carbon_g[0] = 1;
    state.branch_grain_carbon_g[0] = 6;
    const science = [_]group_types.ScienceParameters{.{ .carbon_woody_fraction = .{ 0, 1 }, .leaf_nitrogen_woody_fraction = .{ 0, 1 }, .sheath_nitrogen_woody_fraction = .{ 0, 1 }, .leaf_phosphorus_woody_fraction = .{ 0, 1 }, .sheath_phosphorus_woody_fraction = .{ 0, 1 } }};
    var ledgers = [_]group_types.ProductLedger{.{}};
    var context: group_misc.Context = .{
        .canopy_state = &state,
        .branch_development = &development,
        .science_by_plant = &science,
        .products_by_plant = &ledgers,
        .leaf_area_presence_tolerance_m2 = 1e-12,
    };
    try group_apply.applyEventInternal(&context, 0, .{
        .date = .{ .day = 1, .month = 9, .year = 9999 },
        .kind = .grain,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 0,
        .thinning_fraction_or_consumption_rate = 0,
        .harvested_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 1 },
        .ecosystem_export_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 1 },
    }, false, false);
    // Vegetative stalk/reserve/mobile pools must be cut down, not left
    // untouched -- these are branch-level operations in harvestVegetativeBranch
    // that do not require any leaf-layer samples to exercise.
    try std.testing.expect(state.branch_stalk_carbon_g[0] < 4);
    try std.testing.expect(state.branch_reserve_carbon_g[0] < 1);
    try std.testing.expect(state.branch_mobile_carbon_g[0] < 2);
    // Reproductive organs still export via harvestReproductiveOrgans, unaffected by this fix.
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.branch_husk_carbon_g[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.branch_ear_carbon_g[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.branch_grain_carbon_g[0], 1e-9);
    try std.testing.expect(ledgers[0].harvested_grain.carbon_g > 0);
    // Cut vegetative (woody/stalk) carbon must be routed into products, not vanish.
    try std.testing.expect(ledgers[0].woody.litter.carbon_g + ledgers[0].woody.ecosystem_export.carbon_g > 0);
}

test "GROSUB scheduled above-ground harvest respects the deck's woody ecosystem-export fraction for stalk, not forced 100% export" {
    // Regression test for the fix to the defect where the deterministic
    // (non-grazing) stalk/reserve harvest path ignored
    // event.ecosystem_export_fraction.woody entirely, forcing 100%
    // ecosystem export / 0% litter of every removed stalk gram regardless
    // of the deck's configured export fraction. grosub.f applies
    // WTHTR3 = WTHTH3*(1.0-EHVST(2,3)) to the removed stalk mass
    // independently of and after the cutting-height/thinning removal
    // computed at grosub.f:9339-9382 (grosub.f:10633-10635 for IHVST=2,
    // above-ground).
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{0});
    defer state.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    state.plant_population_per_m2[0] = 1;
    state.plant_population_count[0] = 1;
    state.node_height_m[0] = 2;
    state.node_internode_length_m[0] = 2;
    state.branch_stalk_carbon_g[0] = 4;
    state.branch_stalk_nitrogen_g[0] = 0.4;
    state.branch_stalk_phosphorus_g[0] = 0.04;
    const science = [_]group_types.ScienceParameters{.{ .carbon_woody_fraction = .{ 0, 1 }, .leaf_nitrogen_woody_fraction = .{ 0, 1 }, .sheath_nitrogen_woody_fraction = .{ 0, 1 }, .leaf_phosphorus_woody_fraction = .{ 0, 1 }, .sheath_phosphorus_woody_fraction = .{ 0, 1 } }};
    var ledgers = [_]group_types.ProductLedger{.{}};
    var context: group_misc.Context = .{
        .canopy_state = &state,
        .branch_development = &development,
        .science_by_plant = &science,
        .products_by_plant = &ledgers,
        .leaf_area_presence_tolerance_m2 = 1e-12,
    };
    try group_apply.applyEventInternal(&context, 0, .{
        .date = .{ .day = 1, .month = 9, .year = 9999 },
        .kind = .above_ground,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 0,
        .thinning_fraction_or_consumption_rate = 0,
        .harvested_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 1 },
        .ecosystem_export_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 0.2, .standing_dead = 1 },
    }, false, false);
    // Cutting height 0 with harvested_fraction.woody=1 removes the entire
    // stalk, but only 20% of the removed mass should leave the ecosystem --
    // the remaining 80% must return to litter, not vanish into export.
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.branch_stalk_carbon_g[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8) * 4, ledgers[0].woody.litter.carbon_g, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2) * 4, ledgers[0].woody.ecosystem_export.carbon_g, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8) * 0.4, ledgers[0].woody.litter.nitrogen_g, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2) * 0.4, ledgers[0].woody.ecosystem_export.nitrogen_g, 1e-9);
}

test "GROSUB scheduled harvest routes the nonstructural mobile-carbon pool through the leaf export fraction, not nonfoliar" {
    // Regression test for GROSUB-HARVEST-NONSTRUCTURAL-EXPORT-001: the
    // deterministic (non-grazing) nonstructural/mobile-carbon harvest split
    // in harvestVegetativeBranch used event.ecosystem_export_fraction.nonfoliar
    // instead of .leaf, diverging from grosub.f:10586/:10589 (WTHTR0/WTHTR1
    // both apply EHVST(2,1), the leaf slot -- not EHVST(2,2), nonfoliar)
    // whenever the deck's leaf and nonfoliar export fractions differ. With
    // no leaf/sheath carbon on the branch, the mobile-carbon retention
    // ratio collapses to zero, so the entire pool is removed and its
    // litter/export split isolates exactly the fraction under test.
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{0});
    defer state.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    state.plant_population_per_m2[0] = 1;
    state.plant_population_count[0] = 1;
    state.node_height_m[0] = 2;
    state.node_internode_length_m[0] = 2;
    state.branch_mobile_carbon_g[0] = 2;
    state.branch_mobile_nitrogen_g[0] = 0.2;
    state.branch_mobile_phosphorus_g[0] = 0.02;
    const science = [_]group_types.ScienceParameters{.{ .carbon_woody_fraction = .{ 0, 1 }, .leaf_nitrogen_woody_fraction = .{ 0, 1 }, .sheath_nitrogen_woody_fraction = .{ 0, 1 }, .leaf_phosphorus_woody_fraction = .{ 0, 1 }, .sheath_phosphorus_woody_fraction = .{ 0, 1 } }};
    var ledgers = [_]group_types.ProductLedger{.{}};
    var context: group_misc.Context = .{
        .canopy_state = &state,
        .branch_development = &development,
        .science_by_plant = &science,
        .products_by_plant = &ledgers,
        .leaf_area_presence_tolerance_m2 = 1e-12,
    };
    try group_apply.applyEventInternal(&context, 0, .{
        .date = .{ .day = 1, .month = 9, .year = 9999 },
        .kind = .above_ground,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 0,
        .thinning_fraction_or_consumption_rate = 0,
        .harvested_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 1 },
        .ecosystem_export_fraction = .{ .leaf = 0.3, .nonfoliar = 0.7, .woody = 1, .standing_dead = 1 },
    }, false, false);
    // Must follow the 0.3 leaf fraction, not the 0.7 nonfoliar one -- a
    // leaf/nonfoliar mixup here would silently swap these two numbers with
    // nothing else in the suite distinguishing them.
    try std.testing.expectApproxEqAbs(@as(f64, 0.3) * 2, ledgers[0].nonstructural.ecosystem_export.carbon_g, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7) * 2, ledgers[0].nonstructural.litter.carbon_g, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3) * 0.2, ledgers[0].nonstructural.ecosystem_export.nitrogen_g, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7) * 0.2, ledgers[0].nonstructural.litter.nitrogen_g, 1e-9);
}

test "GROSUB grazing removes top layers and newest nodes first and conserves C N P" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{2};
    const sample_counts = [_]usize{ 2, 2 };
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    var layers = try canopy_layers.State.init(std.testing.allocator, 1, 1, 2, 1, 1, &state);
    defer layers.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();

    // Old node: bottom=2, top=1. New node: bottom=1, top=2 g C.
    const carbon = [_]f64{ 2, 1, 1, 2 };
    for (0..2) |node| {
        var node_carbon_g_c: f64 = 0;
        for (0..2) |layer| {
            const node_layer = node * 2 + layer;
            const sample = node_layer;
            const carbon_g_c = carbon[node_layer];
            layers.node_leaf_area_m2[node_layer] = carbon_g_c;
            layers.node_leaf_carbon_g[node_layer] = carbon_g_c;
            layers.node_leaf_nitrogen_g[node_layer] = 0.1 * carbon_g_c;
            layers.node_leaf_phosphorus_g[node_layer] = 0.01 * carbon_g_c;
            state.sample_leaf_area_m2[sample] = carbon_g_c;
            state.sample_exposed_leaf_area_m2[sample] = carbon_g_c;
            state.sample_leaf_carbon_g[sample] = carbon_g_c;
            state.sample_leaf_nitrogen_g[sample] = 0.1 * carbon_g_c;
            state.sample_leaf_phosphorus_g[sample] = 0.01 * carbon_g_c;
            node_carbon_g_c += carbon_g_c;
        }
        state.node_leaf_area_m2[node] = node_carbon_g_c;
        state.node_leaf_carbon_g[node] = node_carbon_g_c;
        state.node_leaf_nitrogen_g[node] = 0.1 * node_carbon_g_c;
        state.node_leaf_phosphorus_g[node] = 0.01 * node_carbon_g_c;
    }
    state.node_sheath_carbon_g[0] = 3;
    state.node_sheath_nitrogen_g[0] = 0.3;
    state.node_sheath_phosphorus_g[0] = 0.03;
    state.node_sheath_carbon_g[1] = 1;
    state.node_sheath_nitrogen_g[1] = 0.1;
    state.node_sheath_phosphorus_g[1] = 0.01;
    state.branch_leaf_area_m2[0] = 6;
    state.branch_leaf_carbon_g[0] = 6;
    state.branch_leaf_nitrogen_g[0] = 0.6;
    state.branch_leaf_phosphorus_g[0] = 0.06;
    state.branch_sheath_carbon_g[0] = 4;
    state.branch_sheath_nitrogen_g[0] = 0.4;
    state.branch_sheath_phosphorus_g[0] = 0.04;
    state.plant_total_shoot_carbon_g[0] = 10;
    state.plant_uptake_growth_temperature_response[0] = 1;
    state.plant_mobile_carbon_concentration_g_per_g[0] = 0;
    state.plant_symbiont_mobile_carbon_concentration_g_per_g[0] = 0;

    const science = [_]group_types.ScienceParameters{.{ .carbon_woody_fraction = .{ 0.25, 0.75 }, .leaf_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .sheath_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .leaf_phosphorus_woody_fraction = .{ 0.1, 0.9 }, .sheath_phosphorus_woody_fraction = .{ 0.1, 0.9 } }};
    var ledgers = [_]group_types.ProductLedger{.{}};
    var context: group_misc.Context = .{ .canopy_state = &state, .canopy_layer_state = &layers, .branch_development = &development, .science_by_plant = &science, .products_by_plant = &ledgers, .leaf_area_presence_tolerance_m2 = 1.0e-12 };
    const consumed_g_c = try group_apply.applyGrazingEvent(&context, 0, .{
        .date = .{ .day = 1, .month = 1, .year = 9999 },
        .kind = .animal_grazing,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 192,
        .thinning_fraction_or_consumption_rate = 1,
        .harvested_fraction = .{ .leaf = 0.5, .nonfoliar = 0.5, .woody = 0, .standing_dead = 0 },
        .ecosystem_export_fraction = .{ .leaf = 0.25, .nonfoliar = 0.25, .woody = 0, .standing_dead = 0 },
    }, 10, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 4), consumed_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), state.node_leaf_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.node_leaf_carbon_g[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.node_sheath_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.node_sheath_carbon_g[1], 1e-12);
    var products: canopy.ElementalMass = .{};
    inline for (.{ "foliar", "woody", "nonfoliar" }) |field_name| {
        group_misc.addMass(&products, @field(ledgers[0], field_name).ecosystem_export);
        group_misc.addMass(&products, @field(ledgers[0], field_name).litter);
    }
    group_misc.addMass(&products, ledgers[0].standing_dead_export);
    for (ledgers[0].manure.organic_by_biochemical_fraction) |mass| group_misc.addMass(&products, mass);
    products.nitrogen_g += ledgers[0].manure.inorganic_nitrogen_g_n;
    products.phosphorus_g += ledgers[0].manure.inorganic_phosphorus_g_p;
    try std.testing.expectApproxEqAbs(@as(f64, 10), state.branch_leaf_carbon_g[0] + state.branch_sheath_carbon_g[0] + products.carbon_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.branch_leaf_nitrogen_g[0] + state.branch_sheath_nitrogen_g[0] + products.nitrogen_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.branch_leaf_phosphorus_g[0] + state.branch_sheath_phosphorus_g[0] + products.phosphorus_g, 1e-12);
}

test "GROSUB grazing applies reserve demand independently to every runtime branch" {
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{2}, &.{ 1, 1 }, &.{ 1, 1 });
    defer state.deinit();
    var layers = try canopy_layers.State.init(std.testing.allocator, 1, 1, 1, 1, 1, &state);
    defer layers.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 2);
    defer development.deinit();
    for (0..2) |branch| {
        state.branch_stalk_carbon_g[branch] = 5;
        state.branch_stalk_nitrogen_g[branch] = 0.5;
        state.branch_stalk_phosphorus_g[branch] = 0.05;
        state.node_internode_carbon_g[branch] = 5;
        state.node_internode_nitrogen_g[branch] = 0.5;
        state.node_internode_phosphorus_g[branch] = 0.05;
    }
    state.branch_reserve_carbon_g[0] = 1;
    state.branch_reserve_nitrogen_g[0] = 0.1;
    state.branch_reserve_phosphorus_g[0] = 0.01;
    state.branch_reserve_carbon_g[1] = 3;
    state.branch_reserve_nitrogen_g[1] = 0.3;
    state.branch_reserve_phosphorus_g[1] = 0.03;
    state.plant_total_shoot_carbon_g[0] = 14;
    state.plant_uptake_growth_temperature_response[0] = 1;
    const science = [_]group_types.ScienceParameters{.{ .carbon_woody_fraction = .{ 0.25, 0.75 }, .leaf_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .sheath_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .leaf_phosphorus_woody_fraction = .{ 0.1, 0.9 }, .sheath_phosphorus_woody_fraction = .{ 0.1, 0.9 } }};
    var ledgers = [_]group_types.ProductLedger{.{}};
    var context: group_misc.Context = .{ .canopy_state = &state, .canopy_layer_state = &layers, .branch_development = &development, .science_by_plant = &science, .products_by_plant = &ledgers, .leaf_area_presence_tolerance_m2 = 1e-12 };
    const event: management.HarvestEvent = .{
        .date = .{ .day = 1, .month = 1, .year = 9999 },
        .kind = .animal_grazing,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 192,
        .thinning_fraction_or_consumption_rate = 1,
        .harvested_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 1, .standing_dead = 0 },
        .ecosystem_export_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 1, .standing_dead = 0 },
    };
    const removed_g_c = try group_apply.applyGrazingEvent(&context, 0, event, 14, 1);
    const reserve_target_g_c = 4.0 * 4.0 / 14.0;
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.branch_reserve_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(3.0 - reserve_target_g_c, state.branch_reserve_carbon_g[1], 1e-12);
    try std.testing.expectApproxEqAbs(4.0 * 10.0 / 14.0 + 1.0 + reserve_target_g_c, removed_g_c, 1e-12);
    const remaining_g_c = state.branch_stalk_carbon_g[0] + state.branch_stalk_carbon_g[1] +
        state.branch_reserve_carbon_g[0] + state.branch_reserve_carbon_g[1];
    try std.testing.expectApproxEqAbs(@as(f64, 14), remaining_g_c + ledgers[0].woody.ecosystem_export.carbon_g, 1e-12);

    // A late-organ invalid pool is rejected by preflight before any earlier
    // organ or product ledger can be changed.
    state.branch_reserve_carbon_g[0] = -1;
    const stalk_before = state.branch_stalk_carbon_g[0];
    const products_before = group_misc.productLedgerCarbonG(ledgers[0]);
    try std.testing.expectError(error.InvalidGrazingState, group_apply.applyGrazingEvent(&context, 0, event, 14, 1));
    try std.testing.expectEqual(stalk_before, state.branch_stalk_carbon_g[0]);
    try std.testing.expectEqual(products_before, group_misc.productLedgerCarbonG(ledgers[0]));
}

test "GROSUB grazing counts reproductive grain removal exactly once" {
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer state.deinit();
    var layers = try canopy_layers.State.init(std.testing.allocator, 1, 1, 1, 1, 1, &state);
    defer layers.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    state.branch_husk_carbon_g[0] = 2;
    state.branch_husk_nitrogen_g[0] = 0.2;
    state.branch_husk_phosphorus_g[0] = 0.02;
    state.branch_ear_carbon_g[0] = 2;
    state.branch_ear_nitrogen_g[0] = 0.2;
    state.branch_ear_phosphorus_g[0] = 0.02;
    state.branch_grain_carbon_g[0] = 2;
    state.branch_grain_nitrogen_g[0] = 0.2;
    state.branch_grain_phosphorus_g[0] = 0.02;
    state.plant_total_shoot_carbon_g[0] = 6;
    state.plant_uptake_growth_temperature_response[0] = 1;
    const science = [_]group_types.ScienceParameters{.{ .carbon_woody_fraction = .{ 0.25, 0.75 }, .leaf_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .sheath_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .leaf_phosphorus_woody_fraction = .{ 0.1, 0.9 }, .sheath_phosphorus_woody_fraction = .{ 0.1, 0.9 } }};
    var ledgers = [_]group_types.ProductLedger{.{}};
    var context: group_misc.Context = .{ .canopy_state = &state, .canopy_layer_state = &layers, .branch_development = &development, .science_by_plant = &science, .products_by_plant = &ledgers, .leaf_area_presence_tolerance_m2 = 1e-12 };
    const event: management.HarvestEvent = .{
        .date = .{ .day = 1, .month = 1, .year = 9999 },
        .kind = .animal_grazing,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 144,
        .thinning_fraction_or_consumption_rate = 1,
        .harvested_fraction = .{ .leaf = 0, .nonfoliar = 1, .woody = 0, .standing_dead = 0 },
        .ecosystem_export_fraction = .{ .leaf = 0, .nonfoliar = 0.5, .woody = 0, .standing_dead = 0 },
    };
    const removed_g_c = try group_apply.applyGrazingEvent(&context, 0, event, 6, 1);
    const remaining_g_c = state.branch_husk_carbon_g[0] + state.branch_ear_carbon_g[0] + state.branch_grain_carbon_g[0];
    try std.testing.expectApproxEqAbs(@as(f64, 3), removed_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), remaining_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), ledgers[0].nonfoliar.ecosystem_export.carbon_g, 1e-12);
    var manure_carbon_g_c: f64 = 0;
    for (ledgers[0].manure.organic_by_biochemical_fraction) |mass| manure_carbon_g_c += mass.carbon_g;
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), manure_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6), remaining_g_c + group_misc.productLedgerCarbonG(ledgers[0]), 1e-12);

    state.branch_husk_carbon_g[0] = 2;
    state.branch_ear_carbon_g[0] = 2;
    state.branch_grain_carbon_g[0] = 2;
    state.plant_population_count[0] = 1;
    ledgers[0] = .{};
    context.plant_structural_presence_threshold_g_per_plant = 2;
    _ = try group_apply.applyGrazingEvent(&context, 0, event, 6, 1);
    try std.testing.expectApproxEqAbs(
        6,
        state.branch_husk_carbon_g[0] +
            state.branch_ear_carbon_g[0] +
            state.branch_grain_carbon_g[0],
        1e-12,
    );
    try std.testing.expectApproxEqAbs(0, group_misc.productLedgerCarbonG(ledgers[0]), 1e-12);
}

test "production post-cut binding resets live development and publishes coherent downstream totals" {
    const branch_counts = [_]usize{2};
    const node_counts = [_]usize{ 2, 2 };
    const sample_counts = [_]usize{ 2, 2, 2, 2 };
    var state = try canopy.State.init(
        std.testing.allocator,
        1,
        1,
        &branch_counts,
        &node_counts,
        &sample_counts,
    );
    defer state.deinit();
    var layers = try canopy_layers.State.init(std.testing.allocator, 1, 1, 2, 1, 1, &state);
    defer layers.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 2);
    defer development.deinit();
    var growth = try growth_stages.State.init(std.testing.allocator, &branch_counts);
    defer growth.deinit();
    var dormancy_state = try dormancy.RuntimeState.init(std.testing.allocator, 2);
    defer dormancy_state.deinit();

    state.plant_population_per_m2[0] = 1;
    state.plant_population_count[0] = 1;
    state.plant_uptake_growth_temperature_response[0] = 1;
    for (0..2) |branch| {
        state.branch_stalk_carbon_g[branch] = @as(f64, @floatFromInt(4 + branch * 2));
        state.branch_stalk_nitrogen_g[branch] = 0.1 * state.branch_stalk_carbon_g[branch];
        state.branch_stalk_phosphorus_g[branch] = 0.01 * state.branch_stalk_carbon_g[branch];
        state.branch_sapwood_carbon_g[branch] = @as(f64, @floatFromInt(branch + 1));
        state.branch_reserve_carbon_g[branch] = 1;
        state.branch_mobile_carbon_g[branch] = 0.5;
        const nodes = try state.nodeRange(branch);
        state.node_height_m[nodes.first] = 0.5;
        state.node_height_m[nodes.first + 1] = 2;
        state.node_internode_length_m[nodes.first] = 0.5;
        state.node_internode_length_m[nodes.first + 1] = 1.5;
        for (nodes.first..nodes.end) |node| {
            const samples = try state.sampleRange(node);
            state.sample_layer_lower_height_m[samples.first] = 0;
            state.sample_layer_upper_height_m[samples.first] = 1;
            state.sample_layer_lower_height_m[samples.first + 1] = 1;
            state.sample_layer_upper_height_m[samples.first + 1] = 2;
        }
        development.maturity_group[branch] = 9;
        development.final_reproductive_stage[branch] = 4;
        development.hours_without_grain_fill[branch] = 24;
        development.stage_day[branch * 10] = 20;
        growth.branches[branch] = .{
            .branch_order = branch,
            .emergence_day = 20,
            .floral_initiation_day = 40,
            .anthesis_day = 60,
            .initiated_node_count = if (branch == 0) 8 else 11,
            .nodes_at_floral_initiation = 5,
            .nodes_at_anthesis = 7,
            .maximum_active_leaf_node = 9,
            .vegetative_stage_normalized = 2,
            .reproductive_stage_normalized = 3,
            .accumulated_vegetative_stage = 4,
            .accumulated_reproductive_stage = 5,
        };
        dormancy_state.branches[branch].accumulated_leafoff_h = 0;
        layers.branch_stalk_area_m2[branch * 2] = @as(f64, @floatFromInt(branch + 1));
        layers.branch_stalk_area_m2[branch * 2 + 1] = @as(f64, @floatFromInt(branch + 2));
    }
    layers.canopy_height_m_by_plant[0] = 2;
    layers.cell_stalk_area_m2[0] = 3;
    layers.cell_stalk_area_m2[1] = 5;
    const science = [_]group_types.ScienceParameters{.{
        .carbon_woody_fraction = .{ 0, 1 },
        .leaf_nitrogen_woody_fraction = .{ 0, 1 },
        .sheath_nitrogen_woody_fraction = .{ 0, 1 },
        .leaf_phosphorus_woody_fraction = .{ 0, 1 },
        .sheath_phosphorus_woody_fraction = .{ 0, 1 },
    }};
    var ledgers = [_]group_types.ProductLedger{.{}};
    const dormancy_parameters = [_]dormancy.Parameters{.{
        .required_leafout_h = 100,
        .required_leafoff_h = 100,
        .leafout_temperature_threshold_c = 5,
        .leafoff_temperature_threshold_c = 0,
        .chilling_temperature_c = 0,
        .drought_leafout_total_water_potential_megapascal = -0.1,
        .combined_leafout_turgor_potential_megapascal = 0.1,
        .leafoff_total_water_potential_megapascal = -1.5,
        .drought_leafoff_total_water_potential_megapascal = -2,
        .maximum_photoperiod_counter_h = 3600,
        .evergreen_leafoff_remobilization_start_fraction = 0.75,
        .deciduous_leafoff_remobilization_start_fraction = 0.5,
        .full_senescence_duration_h = 720,
    }};
    const turnover = [_]u8{0};
    const root_profile = [_]u8{1};
    const phenology_type = [_]u8{0};
    var initial_maturity = [_]f64{3};
    var context: group_misc.Context = .{
        .canopy_state = &state,
        .canopy_layer_state = &layers,
        .branch_development = &development,
        .science_by_plant = &science,
        .products_by_plant = &ledgers,
        .leaf_area_presence_tolerance_m2 = 1.0e-12,
        .growth_stages = &growth,
        .current_day_of_year = 120,
        .post_harvest = .{
            .dormancy_state = &dormancy_state,
            .dormancy_parameters_by_plant = &dormancy_parameters,
            .biomass_turnover_type_by_plant = &turnover,
            .root_profile_type_by_plant = &root_profile,
            .winter_phenology_type_by_plant = &phenology_type,
            .initial_maturity_group_by_plant = &initial_maturity,
        },
    };
    const cut: management.HarvestEvent = .{
        .date = .{ .day = 1, .month = 5, .year = 9999 },
        .kind = .above_ground,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 0.5,
        .thinning_fraction_or_consumption_rate = 0,
        .harvested_fraction = .{ .leaf = 0.5, .nonfoliar = 0, .woody = 0.5, .standing_dead = 0 },
        .ecosystem_export_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 1 },
    };
    try group_apply.applyEventInternal(&context, 0, cut, false, false);
    for (growth.branches, 0..) |branch, index| {
        try std.testing.expectEqual(if (index == 0) @as(f64, 8) else 11, development.initial_reproductive_stage[index]);
        try std.testing.expectEqual(@as(f64, 3), development.maturity_group[index]);
        try std.testing.expectEqual(@as(f64, 0), development.hours_without_grain_fill[index]);
        try std.testing.expectEqual(@as(u32, 120), development.stage_day[index * 10]);
        try std.testing.expectEqual(branch.initiated_node_count, branch.nodes_at_floral_initiation);
        try std.testing.expectEqual(@as(f64, 0), branch.nodes_at_anthesis);
        try std.testing.expectEqual(@as(f64, 0), branch.accumulated_vegetative_stage);
        try std.testing.expectEqual(@as(f64, 0), branch.accumulated_reproductive_stage);
        try std.testing.expectEqual(@as(u16, 120), branch.emergence_day);
        try std.testing.expectEqual(@as(u16, 0), branch.floral_initiation_day);
    }
    var expected_leaf_sheath: f64 = 0;
    var expected_stalk: f64 = 0;
    var expected_sapwood: f64 = 0;
    var expected_shoot: f64 = 0;
    for (0..2) |branch| {
        expected_leaf_sheath += state.branch_leaf_carbon_g[branch] + state.branch_sheath_carbon_g[branch];
        expected_stalk += state.branch_stalk_carbon_g[branch];
        expected_sapwood += state.branch_sapwood_carbon_g[branch];
        expected_shoot += state.branch_leaf_carbon_g[branch] + state.branch_sheath_carbon_g[branch] +
            state.branch_stalk_carbon_g[branch] + state.branch_reserve_carbon_g[branch] +
            state.branch_husk_carbon_g[branch] + state.branch_ear_carbon_g[branch] +
            state.branch_grain_carbon_g[branch] + state.branch_mobile_carbon_g[branch];
    }
    var expected_stalk_area: f64 = 0;
    for (layers.branch_stalk_area_m2) |area| expected_stalk_area += area;
    try std.testing.expectEqual(expected_leaf_sheath, state.plant_leaf_sheath_carbon_g[0]);
    try std.testing.expectEqual(expected_stalk, state.plant_stalk_carbon_g[0]);
    try std.testing.expectEqual(expected_sapwood, state.plant_sapwood_carbon_g[0]);
    try std.testing.expectEqual(expected_stalk_area, state.plant_stalk_surface_area_m2[0]);
    try std.testing.expectEqual(expected_shoot, state.plant_total_shoot_carbon_g[0]);
    try std.testing.expectEqual(expected_shoot, state.plant_previous_total_shoot_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.plant_shoot_growth_g_c_per_step[0]);

    // A cut plane at or above the canopy is a strict no-reset case.
    development.maturity_group[0] = 9;
    development.hours_without_grain_fill[0] = 13;
    growth.branches[0].accumulated_reproductive_stage = 6;
    var high_cut = cut;
    high_cut.cutting_height_m_or_lai_fraction = 2;
    high_cut.harvested_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0 };
    try group_apply.applyEventInternal(&context, 0, high_cut, false, false);
    try std.testing.expectEqual(@as(f64, 9), development.maturity_group[0]);
    try std.testing.expectEqual(@as(f64, 13), development.hours_without_grain_fill[0]);
    try std.testing.expectEqual(@as(f64, 6), growth.branches[0].accumulated_reproductive_stage);

    // Grazing remains on its demand-driven path and never enters the post-cut
    // reset even with a low nominal height/demand value.
    const grazed = try group_apply.applyGrazingEvent(&context, 0, .{
        .date = .{ .day = 1, .month = 5, .year = 9999 },
        .kind = .animal_grazing,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 0,
        .thinning_fraction_or_consumption_rate = 0,
        .harvested_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 0 },
        .ecosystem_export_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 0 },
    }, state.plant_total_shoot_carbon_g[0], 1);
    try std.testing.expectEqual(@as(f64, 0), grazed);
    try std.testing.expectEqual(@as(f64, 9), development.maturity_group[0]);
    try std.testing.expectEqual(@as(f64, 13), development.hours_without_grain_fill[0]);

    // Invalid late binding input is rejected during preflight, before any
    // organ, development, or product owner changes.
    initial_maturity[0] = std.math.nan(f64);
    const stalk_before = state.branch_stalk_carbon_g[0];
    const maturity_before = development.maturity_group[0];
    const products_before = group_misc.productLedgerCarbonG(ledgers[0]);
    try std.testing.expectError(
        error.InvalidPostHarvestBinding,
        group_apply.applyEventInternal(&context, 0, cut, false, false),
    );
    try std.testing.expectEqual(stalk_before, state.branch_stalk_carbon_g[0]);
    try std.testing.expectEqual(maturity_before, development.maturity_group[0]);
    try std.testing.expectEqual(products_before, group_misc.productLedgerCarbonG(ledgers[0]));
}

test "GROSUB standing dead grazing updates mass area export and manure" {
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer state.deinit();
    var layers = try canopy_layers.State.init(std.testing.allocator, 1, 1, 1, 1, 1, &state);
    defer layers.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    state.plant_standing_dead_carbon_g[0] = 8;
    state.plant_standing_dead_nitrogen_g[0] = 0.8;
    state.plant_standing_dead_phosphorus_g[0] = 0.08;
    state.plant_charcoal_carbon_g[0] = 4;
    state.plant_charcoal_nitrogen_g[0] = 0.4;
    state.plant_charcoal_phosphorus_g[0] = 0.04;
    for (0..4) |fraction| {
        state.plant_standing_dead_carbon_by_kinetic_g[fraction] = 2;
        state.plant_standing_dead_nitrogen_by_kinetic_g[fraction] = 0.2;
        state.plant_standing_dead_phosphorus_by_kinetic_g[fraction] = 0.02;
    }
    layers.plant_standing_dead_area_m2[0] = 5;
    layers.plant_standing_dead_projected_surface_m2[0] = 5;
    layers.cell_standing_dead_area_m2[0] = 5;
    state.plant_uptake_growth_temperature_response[0] = 1;
    const science = [_]group_types.ScienceParameters{.{ .carbon_woody_fraction = .{ 0.25, 0.75 }, .leaf_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .sheath_nitrogen_woody_fraction = .{ 0.2, 0.8 }, .leaf_phosphorus_woody_fraction = .{ 0.1, 0.9 }, .sheath_phosphorus_woody_fraction = .{ 0.1, 0.9 } }};
    var ledgers = [_]group_types.ProductLedger{.{}};
    var context: group_misc.Context = .{ .canopy_state = &state, .canopy_layer_state = &layers, .branch_development = &development, .science_by_plant = &science, .products_by_plant = &ledgers, .leaf_area_presence_tolerance_m2 = 1e-12 };
    const removed_g_c = try group_apply.applyGrazingEvent(&context, 0, .{
        .date = .{ .day = 1, .month = 1, .year = 9999 },
        .kind = .animal_grazing,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 96,
        .thinning_fraction_or_consumption_rate = 1,
        .harvested_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0.5 },
        .ecosystem_export_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0.25 },
    }, 0, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 2), removed_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0 / 3.0), state.plant_standing_dead_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), state.plant_charcoal_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0 / 6.0), layers.plant_standing_dead_area_m2[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), ledgers[0].standing_dead_export.carbon_g, 1e-12);
    var manure_carbon_g_c: f64 = 0;
    for (ledgers[0].manure.organic_by_biochemical_fraction) |mass| manure_carbon_g_c += mass.carbon_g;
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), manure_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 12), state.plant_standing_dead_carbon_g[0] +
        state.plant_charcoal_carbon_g[0] + group_misc.productLedgerCarbonG(ledgers[0]), 1e-12);
}

test "post-harvest topology guard still rejects direct tillage of an unassigned slot" {
    // Reproduces the actual Ottawa day-106 diagnostic. Dispatch must exclude
    // unassigned slots using the input assignment, not weaken this invariant.
    const branch_counts = [_]usize{ 1, 0, 0, 0, 0 };
    var state = try canopy.State.init(std.testing.allocator, 1, 5, &branch_counts, &.{1}, &.{1});
    defer state.deinit();
    var layers = try canopy_layers.State.init(std.testing.allocator, 1, 5, 1, 1, 1, &state);
    defer layers.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var growth = try growth_stages.State.init(std.testing.allocator, &branch_counts);
    defer growth.deinit();
    var dormancy_state = try dormancy.RuntimeState.init(std.testing.allocator, 1);
    defer dormancy_state.deinit();
    const science = [_]group_types.ScienceParameters{.{
        .carbon_woody_fraction = .{ 1, 0 },
        .leaf_nitrogen_woody_fraction = .{ 1, 0 },
        .sheath_nitrogen_woody_fraction = .{ 1, 0 },
        .leaf_phosphorus_woody_fraction = .{ 1, 0 },
        .sheath_phosphorus_woody_fraction = .{ 1, 0 },
    }} ** 5;
    var products = [_]group_types.ProductLedger{.{}} ** 5;
    var parameters = [_]dormancy.Parameters{std.mem.zeroes(dormancy.Parameters)} ** 5;
    for (&parameters) |*parameter| parameter.full_senescence_duration_h = 720;
    var context: group_misc.Context = .{
        .canopy_state = &state,
        .canopy_layer_state = &layers,
        .branch_development = &development,
        .growth_stages = &growth,
        .science_by_plant = &science,
        .products_by_plant = &products,
        .leaf_area_presence_tolerance_m2 = 1e-12,
        .root_woody_fraction_by_plant = &.{ 1, 1, 1, 1, 1 },
        .current_day_of_year = 106,
        .post_harvest = .{
            .dormancy_state = &dormancy_state,
            .dormancy_parameters_by_plant = &parameters,
            .biomass_turnover_type_by_plant = &.{ 0, 0, 0, 0, 0 },
            .root_profile_type_by_plant = &.{ 0, 0, 0, 0, 0 },
            .winter_phenology_type_by_plant = &.{ 0, 0, 0, 0, 0 },
            .initial_maturity_group_by_plant = &.{ 0, 0, 0, 0, 0 },
        },
    };
    const products_before = products;
    try std.testing.expectError(error.PostHarvestDimensionMismatch, group_apply.applyAbovegroundTillage(&context, 1, 0.5, false));
    try std.testing.expectEqualDeep(products_before, products);
    try std.testing.expectEqual(@as(f64, 0), state.plant_population_count[1]);
}

test "GROSUB tillage removes shoot and standing dead but leaves root state_update separate" {
    // One canopy layer × one inclination × one azimuth requires one sample
    // for every live node, even when this tillage fixture has no leaf mass.
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer state.deinit();
    var layers = try canopy_layers.State.init(std.testing.allocator, 1, 1, 1, 1, 1, &state);
    defer layers.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var roots = try root_system.State.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    const root = try roots.layerIndex(0, 0, 0);
    roots.mobile_carbon_g[root] = 7;
    state.branch_stalk_carbon_g[0] = 10;
    state.branch_stalk_nitrogen_g[0] = 1;
    state.branch_stalk_phosphorus_g[0] = 0.1;
    state.node_height_m[0] = 1;
    state.node_internode_length_m[0] = 1;
    state.branch_symbiont_mobile_carbon_g[0] = 2;
    state.branch_symbiont_structural_carbon_g[0] = 3;
    state.branch_grain_carbon_g[0] = 4;
    state.plant_seed_storage_carbon_g[0] = 2;
    state.plant_population_per_m2[0] = 20;
    state.plant_population_count[0] = 20;
    state.plant_standing_dead_population_count[0] = 4;
    state.plant_standing_dead_carbon_g[0] = 8;
    state.plant_standing_dead_nitrogen_g[0] = 0.8;
    state.plant_standing_dead_phosphorus_g[0] = 0.08;
    for (0..4) |kinetic| {
        state.plant_standing_dead_carbon_by_kinetic_g[kinetic] = 2;
        state.plant_standing_dead_nitrogen_by_kinetic_g[kinetic] = 0.2;
        state.plant_standing_dead_phosphorus_by_kinetic_g[kinetic] = 0.02;
    }
    layers.plant_standing_dead_area_m2[0] = 5;
    layers.cell_standing_dead_area_m2[0] = 5;
    layers.plant_standing_dead_projected_surface_m2[0] = 5;
    const science = [_]group_types.ScienceParameters{.{
        .carbon_woody_fraction = .{ 0.25, 0.75 },
        .leaf_nitrogen_woody_fraction = .{ 0.25, 0.75 },
        .sheath_nitrogen_woody_fraction = .{ 0.25, 0.75 },
        .leaf_phosphorus_woody_fraction = .{ 0.25, 0.75 },
        .sheath_phosphorus_woody_fraction = .{ 0.25, 0.75 },
    }};
    const root_nonwoody = [_]f64{0.4};
    var ledgers = [_]group_types.ProductLedger{.{}};
    var context: group_misc.Context = .{
        .canopy_state = &state,
        .canopy_layer_state = &layers,
        .branch_development = &development,
        .science_by_plant = &science,
        .products_by_plant = &ledgers,
        .leaf_area_presence_tolerance_m2 = 1e-12,
        .root_state = &roots,
        .root_woody_fraction_by_plant = &root_nonwoody,
    };
    try group_apply.applyAbovegroundTillage(&context, 0, 0.5, true);
    try std.testing.expectApproxEqAbs(@as(f64, 5), state.branch_stalk_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.branch_symbiont_mobile_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), state.branch_symbiont_structural_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.branch_grain_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.plant_seed_storage_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4), state.plant_standing_dead_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), layers.plant_standing_dead_area_m2[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10), state.plant_population_count[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7), roots.mobile_carbon_g[root], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 13.5), group_misc.productLedgerCarbonG(ledgers[0]), 1e-12);
}

test "GROSUB kind zero standing dead thinning separates retained litter and export" {
    var state = try canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer state.deinit();
    var layers = try canopy_layers.State.init(std.testing.allocator, 1, 1, 1, 1, 1, &state);
    defer layers.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    state.plant_standing_dead_carbon_g[0] = 10;
    state.plant_standing_dead_nitrogen_g[0] = 1;
    state.plant_standing_dead_phosphorus_g[0] = 0.1;
    state.plant_charcoal_carbon_g[0] = 5;
    state.plant_charcoal_nitrogen_g[0] = 0.5;
    state.plant_charcoal_phosphorus_g[0] = 0.05;
    for (0..4) |kinetic| state.plant_standing_dead_carbon_by_kinetic_g[kinetic] = 2.5;
    layers.plant_standing_dead_area_m2[0] = 5;
    layers.cell_standing_dead_area_m2[0] = 5;
    layers.plant_standing_dead_projected_surface_m2[0] = 5;
    const root_nonwoody = [_]f64{0.25};
    var ledgers = [_]group_types.ProductLedger{.{}};
    var context: group_misc.Context = .{
        .canopy_state = &state,
        .canopy_layer_state = &layers,
        .branch_development = &development,
        .science_by_plant = &.{},
        .products_by_plant = &ledgers,
        .leaf_area_presence_tolerance_m2 = 1e-12,
        .root_woody_fraction_by_plant = &root_nonwoody,
    };
    try group_apply.applyScheduledStandingDeadHarvest(&context, 0, .{
        .date = .{ .day = 1, .month = 1, .year = 9999 },
        .kind = .none,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 0,
        .thinning_fraction_or_consumption_rate = 0.4,
        .harvested_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0.5 },
        .ecosystem_export_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0.5 },
    });
    try std.testing.expectApproxEqAbs(@as(f64, 6), state.plant_standing_dead_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), state.plant_charcoal_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), ledgers[0].standing_dead_export.carbon_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), ledgers[0].woody.litter.carbon_g + ledgers[0].nonfoliar.litter.carbon_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), ledgers[0].standing_dead_charcoal_litter.carbon_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 15), state.plant_standing_dead_carbon_g[0] +
        state.plant_charcoal_carbon_g[0] + group_misc.productLedgerCarbonG(ledgers[0]), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), layers.plant_standing_dead_area_m2[0], 1e-12);
}

test "thinning then complete mortality conserves host and nodule roots and publishes HCNET disturbance" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{1};
    var canopy_state = try canopy.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer canopy_state.deinit();
    var development = try phenology.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var roots = try root_system.State.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    var partitions = try litter_partition.State.init(std.testing.allocator, 1);
    defer partitions.deinit();
    const uniform: litter_partition.ElementFractions = .{
        .carbon = .{ 0.25, 0.25, 0.25, 0.25 },
        .nitrogen = .{ 0.25, 0.25, 0.25, 0.25 },
        .phosphorus = .{ 0.25, 0.25, 0.25, 0.25 },
    };
    partitions.by_plant_and_organ[@intFromEnum(litter_partition.Organ.fine_root)] = uniform;
    partitions.by_plant_and_organ[@intFromEnum(litter_partition.Organ.nonstructural)] = uniform;
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 10 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var organic = try soil_organic.State.init(std.testing.allocator, 2);
    defer organic.deinit();
    for (0..2) |layer| {
        const root = try roots.layerIndex(0, 0, layer);
        roots.symbiont_structural_carbon_g_c[root] = 2;
        roots.symbiont_structural_nitrogen_g_n[root] = 0.2;
        roots.symbiont_structural_phosphorus_g_p[root] = 0.02;
        roots.symbiont_mobile_carbon_g_c[root] = 1;
        roots.symbiont_mobile_nitrogen_g_n[root] = 0.1;
        roots.symbiont_mobile_phosphorus_g_p[root] = 0.01;
        roots.mobile_carbon_g[root] = 1;
        roots.mobile_nitrogen_g[root] = 0.1;
        roots.mobile_phosphorus_g[root] = 0.01;
        const axis_layer = try roots.layerAxisIndex(0, 0, layer, 0);
        roots.axis_primary_carbon_g[axis_layer] = 2;
        roots.axis_primary_nitrogen_g[axis_layer] = 0.2;
        roots.axis_primary_phosphorus_g[axis_layer] = 0.02;
        roots.axis_secondary_carbon_g[axis_layer] = 1;
        roots.axis_secondary_nitrogen_g[axis_layer] = 0.1;
        roots.axis_secondary_phosphorus_g[axis_layer] = 0.01;
        for (0..root_system.biological_domain_count) |domain| {
            const gas_root = try roots.layerIndex(0, domain, layer);
            roots.gaseous_carbon_dioxide_g_c[gas_root] = 1;
            roots.aqueous_carbon_dioxide_g_c[gas_root] = 3;
        }
    }
    roots.active_root_axis_count[0] = 1;
    var exchange = try carbon_exchange.State.init(std.testing.allocator, 1);
    defer exchange.deinit();
    var root_litter_carbon = try root_litter_ledger.State.init(
        std.testing.allocator,
        1,
        root_system.biological_domain_count,
        2,
    );
    defer root_litter_carbon.deinit();
    const woody_fraction = [_]f64{0};
    const belowground_composition = [_]group_types.BelowgroundHarvestComposition{.{
        .root_woody_nonwoody = .{ .carbon = .{ 0, 1 }, .nitrogen = .{ 0, 1 }, .phosphorus = .{ 0, 1 } },
        .storage_woody_nonwoody = .{ .carbon = .{ 0, 1 }, .nitrogen = .{ 0, 1 }, .phosphorus = .{ 0, 1 } },
        .perennial = false,
    }};
    const science = [_]group_types.ScienceParameters{.{ .nitrogen_fixation_type = 1, .carbon_woody_fraction = .{ 0, 1 }, .leaf_nitrogen_woody_fraction = .{ 0, 1 }, .sheath_nitrogen_woody_fraction = .{ 0, 1 }, .leaf_phosphorus_woody_fraction = .{ 0, 1 }, .sheath_phosphorus_woody_fraction = .{ 0, 1 } }};
    var products = [_]group_types.ProductLedger{.{}};
    var context: group_misc.Context = .{
        .canopy_state = &canopy_state,
        .branch_development = &development,
        .science_by_plant = &science,
        .products_by_plant = &products,
        .leaf_area_presence_tolerance_m2 = 1.0e-12,
        .root_state = &roots,
        .root_litter_partition = &partitions,
        .soil_organic_state = &organic,
        .grid = &grid,
        .belowground_harvest_composition_by_plant = &belowground_composition,
        .root_woody_fraction_by_plant = &woody_fraction,
        .carbon_exchange_state = &exchange,
        .root_litter_carbon_ledger = &root_litter_carbon,
    };
    try group_apply.applyRootSymbiontHarvest(&context, 0, 0.5);
    for (0..2) |layer| {
        try std.testing.expectApproxEqAbs(
            3.5,
            root_litter_carbon.carbon_g_c[try root_litter_carbon.index(0, 0, layer)],
            1e-14,
        );
        try std.testing.expectApproxEqAbs(
            0,
            root_litter_carbon.carbon_g_c[try root_litter_carbon.index(0, 1, layer)],
            1e-14,
        );
    }
    var remaining_carbon_g_c: f64 = 0;
    var litter_carbon_g_c: f64 = 0;
    for (0..2) |layer| {
        const root = try roots.layerIndex(0, 0, layer);
        const axis_layer = try roots.layerAxisIndex(0, 0, layer, 0);
        remaining_carbon_g_c += roots.symbiont_structural_carbon_g_c[root] + roots.symbiont_mobile_carbon_g_c[root] +
            roots.mobile_carbon_g[root] + roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer];
        for (0..root_litterfall.kinetic_component_count) |component|
            litter_carbon_g_c += organic.structural[(layer * soil_organic.substrate_count + 1) * soil_organic.structural_fraction_count + component].carbon_g_c;
    }
    try std.testing.expectApproxEqAbs(14, remaining_carbon_g_c + litter_carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(7, remaining_carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(4, exchange.disturbance_carbon_g_c_per_h[0], 1e-14);
    try std.testing.expectApproxEqAbs(-8, roots.withdrawal_carbon_dioxide_loss_g_c_per_h[0], 1e-14);
    var remaining_root_carbon_dioxide_g_c: f64 = 0;
    for (roots.gaseous_carbon_dioxide_g_c, roots.aqueous_carbon_dioxide_g_c) |gaseous, aqueous|
        remaining_root_carbon_dioxide_g_c += gaseous + aqueous;
    try std.testing.expectApproxEqAbs(8, remaining_root_carbon_dioxide_g_c, 1e-14);

    try group_mortality.releaseDeadRootsToLitter(&context, 0);
    remaining_carbon_g_c = 0;
    litter_carbon_g_c = 0;
    for (0..2) |layer| {
        const root = try roots.layerIndex(0, 0, layer);
        const axis_layer = try roots.layerAxisIndex(0, 0, layer, 0);
        remaining_carbon_g_c += roots.symbiont_structural_carbon_g_c[root] + roots.symbiont_mobile_carbon_g_c[root] +
            roots.mobile_carbon_g[root] + roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer];
        for (0..root_litterfall.kinetic_component_count) |component|
            litter_carbon_g_c += organic.structural[(layer * soil_organic.substrate_count + 1) * soil_organic.structural_fraction_count + component].carbon_g_c;
    }
    try std.testing.expectApproxEqAbs(0, remaining_carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(14, litter_carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(8, exchange.disturbance_carbon_g_c_per_h[0], 1e-14);
    try std.testing.expectApproxEqAbs(-16, roots.withdrawal_carbon_dioxide_loss_g_c_per_h[0], 1e-14);
    remaining_root_carbon_dioxide_g_c = 0;
    for (roots.gaseous_carbon_dioxide_g_c, roots.aqueous_carbon_dioxide_g_c) |gaseous, aqueous|
        remaining_root_carbon_dioxide_g_c += gaseous + aqueous;
    try std.testing.expectApproxEqAbs(0, remaining_root_carbon_dioxide_g_c, 1e-14);
}

test "GROSUB harvest leaves nodule pools intact for non-fixing plants" {
    const pool: symbiotic_fixation.Pool = .{
        .carbon_g_c = 2,
        .nitrogen_g_n = 0.2,
        .phosphorus_g_p = 0.02,
    };
    const partition: litter_partition.ElementFractions = .{
        .carbon = .{ 0.25, 0.25, 0.25, 0.25 },
        .nitrogen = .{ 0.25, 0.25, 0.25, 0.25 },
        .phosphorus = .{ 0.25, 0.25, 0.25, 0.25 },
    };
    const result = try group_harvest.noduleHarvestResult(0, pool, pool, 0.5, partition, partition);
    try std.testing.expectEqual(pool, result.structural);
    try std.testing.expectEqual(pool, result.mobile);
    try std.testing.expectEqual(
        @as(f64, 0),
        try root_litter_ledger.totalCarbon(result.litterfall),
    );
}
