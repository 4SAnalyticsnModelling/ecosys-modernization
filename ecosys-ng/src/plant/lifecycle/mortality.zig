const std = @import("std");
const CanopyState = @import("../../canopy/photosynthesis/photosynthesis.zig").State;
const GrowthState = @import("growth_stages.zig").State;
const PlantPhenologyState = @import("phenology.zig").State;
const BranchDevelopmentState = @import("phenology.zig").BranchDevelopmentState;
const RootState = @import("../root/plant_root_system.zig").State;
const RetentionState = @import("../../canopy/energy/precipitation_retention.zig").State;
const PlantState = @import("../../state/grid.zig").PlantState;
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");

/// grosub.f lines 7535--7538 DEATHR predicate with the runtime per-plant
/// replacement for source `ZERO` scaled to the current population (`ZEROP`).
pub fn sourceOrderStorageExhausted(
    storage_carbon_g_c: f64,
    storage_nitrogen_g_n: f64,
    storage_phosphorus_g_p: f64,
    perennial: bool,
    presence_threshold_g_per_plant: f64,
    plant_population_count: f64,
) !bool {
    inline for (.{
        storage_carbon_g_c,
        storage_nitrogen_g_n,
        storage_phosphorus_g_p,
        presence_threshold_g_per_plant,
        plant_population_count,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidStorageExhaustionInput;
    if (!perennial) return false;
    const threshold_g = presence_threshold_g_per_plant * plant_population_count;
    if (!std.math.isFinite(threshold_g)) return error.InvalidStorageExhaustionInput;
    return storage_carbon_g_c <= threshold_g or
        storage_nitrogen_g_n <= threshold_g or
        storage_phosphorus_g_p <= threshold_g;
}

/// GROSUB IDAY0/IYR0: dead perennials without a terminating harvest are
/// eligible for reconstruction on the following calendar day.
pub fn scheduleNextDayReplant(
    phenology: *PlantPhenologyState,
    plant: usize,
    current_day_of_year: u16,
    current_year: u16,
    days_in_current_year: u16,
) !void {
    if (plant >= phenology.active.len) return error.PlantMortalityIndexOutOfBounds;
    const expected_days: u16 =
        if (execution_calendar_date.isLeapYear(current_year)) 366 else 365;
    if (current_year == 0 or days_in_current_year != expected_days or
        current_day_of_year == 0 or current_day_of_year > expected_days)
        return error.InvalidPerennialReplantDate;
    if (current_day_of_year < days_in_current_year) {
        phenology.replant_day_of_year[plant] = current_day_of_year + 1;
        phenology.replant_year[plant] = current_year;
    } else {
        if (current_year == std.math.maxInt(u16)) return error.PerennialReplantYearOverflow;
        phenology.replant_day_of_year[plant] = 1;
        phenology.replant_year[plant] = current_year + 1;
    }
    phenology.lifecycle_initialized[plant] = false;
    phenology.death_replant_pending[plant] = true;
}

/// GROSUB DEATHR: a perennial dies when any seasonal storage element is
/// exhausted. The transition is validated completely before any state changes.
pub fn applyStorageExhaustion(
    canopy: *CanopyState,
    growth: *GrowthState,
    development: *BranchDevelopmentState,
    phenology: *PlantPhenologyState,
    roots: *RootState,
    retention: *RetentionState,
    plants: *PlantState,
    plant: usize,
    perennial: bool,
    cell_area_m2: f64,
    presence_threshold_g_per_plant: f64,
) !bool {
    if (plant >= canopy.plant_seed_storage_carbon_g.len or
        plant >= growth.plant_count or
        plant >= phenology.active.len or
        plant >= roots.plant_count or
        plant >= retention.living_surface_water_m3.len or
        plant >= plants.canopy_water_storage_m_per_m2.len)
        return error.PlantMortalityIndexOutOfBounds;
    inline for (.{
        cell_area_m2,
        presence_threshold_g_per_plant,
        canopy.plant_seed_storage_carbon_g[plant],
        canopy.plant_seed_storage_nitrogen_g[plant],
        canopy.plant_seed_storage_phosphorus_g[plant],
        canopy.plant_population_per_m2[plant],
        canopy.plant_population_count[plant],
        plants.canopy_water_storage_m_per_m2[plant],
        retention.living_surface_water_m3[plant],
        retention.standing_dead_surface_water_m3[plant],
    }) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantMortalityState;
    if (cell_area_m2 <= 0 or presence_threshold_g_per_plant < 0 or
        canopy.plant_population_per_m2[plant] < 0 or canopy.plant_population_count[plant] < 0 or
        plants.canopy_water_storage_m_per_m2[plant] < 0 or retention.living_surface_water_m3[plant] < 0 or retention.standing_dead_surface_water_m3[plant] < 0)
        return error.InvalidPlantMortalityState;
    if (!try sourceOrderStorageExhausted(
        canopy.plant_seed_storage_carbon_g[plant],
        canopy.plant_seed_storage_nitrogen_g[plant],
        canopy.plant_seed_storage_phosphorus_g[plant],
        perennial,
        presence_threshold_g_per_plant,
        canopy.plant_population_count[plant],
    ))
        return false;

    const branches = try growth.branchRange(plant);
    if (branches.end > development.branch_count) return error.PlantMortalityBranchDimensionMismatch;
    const internal_canopy_water_m3 = plants.canopy_water_storage_m_per_m2[plant] * cell_area_m2;
    const next_standing_dead_water_m3 = retention.standing_dead_surface_water_m3[plant] +
        retention.living_surface_water_m3[plant] +
        internal_canopy_water_m3;
    if (!std.math.isFinite(next_standing_dead_water_m3)) return error.NonFinitePlantMortalityState;

    for (growth.branches[branches.first..branches.end]) |*branch| branch.dead = true;
    @memset(development.dead[branches.first..branches.end], true);
    phenology.active[plant] = false;
    roots.roots_dead[plant] = true;
    canopy.plant_population_per_m2[plant] = 0;
    canopy.plant_population_count[plant] = 0;
    retention.standing_dead_surface_water_m3[plant] = next_standing_dead_water_m3;
    retention.living_surface_water_m3[plant] = 0;
    plants.canopy_water_storage_m_per_m2[plant] = 0;
    return true;
}

/// GROSUB transition after every runtime branch has completed natural death.
/// Winter annuals retain population for their source self-seeding lifecycle;
/// all other plants clear living population immediately.
pub fn applyAllBranchesDead(
    canopy: *CanopyState,
    phenology: *PlantPhenologyState,
    roots: *RootState,
    retention: *RetentionState,
    plants: *PlantState,
    plant: usize,
    preserve_population: bool,
    cell_area_m2: f64,
) !void {
    if (plant >= canopy.plant_population_per_m2.len or plant >= phenology.active.len or
        plant >= roots.roots_dead.len or plant >= retention.living_surface_water_m3.len or
        plant >= plants.canopy_water_storage_m_per_m2.len)
        return error.PlantMortalityIndexOutOfBounds;
    inline for (.{
        cell_area_m2,
        canopy.plant_population_per_m2[plant],
        canopy.plant_population_count[plant],
        plants.canopy_water_storage_m_per_m2[plant],
        retention.living_surface_water_m3[plant],
        retention.standing_dead_surface_water_m3[plant],
    }) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantMortalityState;
    if (cell_area_m2 <= 0) return error.InvalidPlantMortalityState;
    const transferred_water_m3 = plants.canopy_water_storage_m_per_m2[plant] * cell_area_m2 +
        retention.living_surface_water_m3[plant];
    const next_standing_dead_water_m3 = retention.standing_dead_surface_water_m3[plant] + transferred_water_m3;
    if (!std.math.isFinite(next_standing_dead_water_m3)) return error.NonFinitePlantMortalityState;

    phenology.active[plant] = false;
    roots.roots_dead[plant] = true;
    if (!preserve_population) {
        canopy.plant_population_per_m2[plant] = 0;
        canopy.plant_population_count[plant] = 0;
    }
    retention.standing_dead_surface_water_m3[plant] = next_standing_dead_water_m3;
    retention.living_surface_water_m3[plant] = 0;
    plants.canopy_water_storage_m_per_m2[plant] = 0;
}

test "GROSUB perennial storage exhaustion kills all runtime branches and transfers water" {
    const allocator = std.testing.allocator;
    var canopy = try CanopyState.init(allocator, 1, 1, &.{2}, &.{ 0, 0 }, &.{});
    defer canopy.deinit();
    var growth = try GrowthState.init(allocator, &.{2});
    defer growth.deinit();
    var development = try BranchDevelopmentState.init(allocator, 2);
    defer development.deinit();
    var phenology = try PlantPhenologyState.init(allocator, 1, 1);
    defer phenology.deinit();
    var roots = try RootState.init(allocator, 1, 1, 1);
    defer roots.deinit();
    var retention = try RetentionState.init(allocator, 1, 1);
    defer retention.deinit();
    var plants = try PlantState.init(allocator, try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 }));
    defer plants.deinit();

    canopy.plant_seed_storage_carbon_g[0] = 1;
    canopy.plant_seed_storage_nitrogen_g[0] = 0;
    canopy.plant_seed_storage_phosphorus_g[0] = 0.1;
    canopy.plant_population_per_m2[0] = 3;
    canopy.plant_population_count[0] = 6;
    phenology.active[0] = true;
    roots.roots_dead[0] = false;
    plants.canopy_water_storage_m_per_m2[0] = 0.25;
    retention.living_surface_water_m3[0] = 2;
    retention.standing_dead_surface_water_m3[0] = 5;

    try std.testing.expect(try applyStorageExhaustion(&canopy, &growth, &development, &phenology, &roots, &retention, &plants, 0, true, 2, 1.0e-12));
    for (growth.branches) |branch| try std.testing.expect(branch.dead);
    for (development.dead) |dead| try std.testing.expect(dead);
    try std.testing.expect(!phenology.active[0]);
    try std.testing.expect(roots.roots_dead[0]);
    try std.testing.expectEqual(@as(f64, 0), canopy.plant_population_count[0]);
    try std.testing.expectEqual(@as(f64, 0), retention.living_surface_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 7.5), retention.standing_dead_surface_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0), plants.canopy_water_storage_m_per_m2[0]);
}

test "GROSUB DEATHR scales ZEROP by current population and uses any element" {
    try std.testing.expect(try sourceOrderStorageExhausted(2, 1, 2, true, 0.5, 2));
    try std.testing.expect(!try sourceOrderStorageExhausted(2, 1.00001, 2, true, 0.5, 2));
    try std.testing.expect(!try sourceOrderStorageExhausted(0, 0, 0, false, 0.5, 2));
    try std.testing.expectError(
        error.InvalidStorageExhaustionInput,
        sourceOrderStorageExhausted(1, 1, 1, true, 1.0e-6, std.math.inf(f64)),
    );
}

test "GROSUB dead perennial replant scheduling advances normally and across year end" {
    var phenology = try PlantPhenologyState.init(std.testing.allocator, 1, 1);
    defer phenology.deinit();
    phenology.lifecycle_initialized[0] = true;

    try scheduleNextDayReplant(&phenology, 0, 120, 2024, 366);
    try std.testing.expectEqual(@as(u16, 121), phenology.replant_day_of_year[0]);
    try std.testing.expectEqual(@as(u16, 2024), phenology.replant_year[0]);
    try std.testing.expect(!phenology.lifecycle_initialized[0]);

    phenology.lifecycle_initialized[0] = true;
    try scheduleNextDayReplant(&phenology, 0, 366, 2024, 366);
    try std.testing.expectEqual(@as(u16, 1), phenology.replant_day_of_year[0]);
    try std.testing.expectEqual(@as(u16, 2025), phenology.replant_year[0]);
    try std.testing.expect(!phenology.lifecycle_initialized[0]);
}

test "perennial replant scheduling preserves DAY modulo-four chronology" {
    var phenology = try PlantPhenologyState.init(std.testing.allocator, 1, 1);
    defer phenology.deinit();
    try scheduleNextDayReplant(&phenology, 0, 366, 1900, 366);
    try std.testing.expectEqual(@as(u16, 1), phenology.replant_day_of_year[0]);
    try std.testing.expectEqual(@as(u16, 1901), phenology.replant_year[0]);

    const before_day = phenology.replant_day_of_year[0];
    const before_year = phenology.replant_year[0];
    try std.testing.expectError(
        error.InvalidPerennialReplantDate,
        scheduleNextDayReplant(&phenology, 0, 366, 1901, 366),
    );
    try std.testing.expectEqual(before_day, phenology.replant_day_of_year[0]);
    try std.testing.expectEqual(before_year, phenology.replant_year[0]);
    try std.testing.expectError(
        error.InvalidPerennialReplantDate,
        scheduleNextDayReplant(&phenology, 0, 365, 1900, 365),
    );
}

test "GROSUB all-branch death preserves winter-annual population and transfers canopy water" {
    const allocator = std.testing.allocator;
    var canopy = try CanopyState.init(allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer canopy.deinit();
    var phenology = try PlantPhenologyState.init(allocator, 1, 1);
    defer phenology.deinit();
    var roots = try RootState.init(allocator, 1, 1, 1);
    defer roots.deinit();
    var retention = try RetentionState.init(allocator, 1, 1);
    defer retention.deinit();
    var plants = try PlantState.init(allocator, try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 }));
    defer plants.deinit();
    phenology.active[0] = true;
    roots.roots_dead[0] = false;
    canopy.plant_population_per_m2[0] = 3;
    canopy.plant_population_count[0] = 6;
    retention.living_surface_water_m3[0] = 2;
    retention.standing_dead_surface_water_m3[0] = 1;
    plants.canopy_water_storage_m_per_m2[0] = 0.5;

    try applyAllBranchesDead(&canopy, &phenology, &roots, &retention, &plants, 0, true, 2);
    try std.testing.expect(!phenology.active[0]);
    try std.testing.expect(roots.roots_dead[0]);
    try std.testing.expectEqual(@as(f64, 3), canopy.plant_population_per_m2[0]);
    try std.testing.expectEqual(@as(f64, 6), canopy.plant_population_count[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 4), retention.standing_dead_surface_water_m3[0], 1e-12);
    try std.testing.expectEqual(@as(f64, 0), retention.living_surface_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0), plants.canopy_water_storage_m_per_m2[0]);
}

test "GROSUB storage exhaustion does not kill annuals" {
    const allocator = std.testing.allocator;
    var canopy = try CanopyState.init(allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer canopy.deinit();
    var growth = try GrowthState.init(allocator, &.{1});
    defer growth.deinit();
    var development = try BranchDevelopmentState.init(allocator, 1);
    defer development.deinit();
    var phenology = try PlantPhenologyState.init(allocator, 1, 1);
    defer phenology.deinit();
    var roots = try RootState.init(allocator, 1, 1, 1);
    defer roots.deinit();
    var retention = try RetentionState.init(allocator, 1, 1);
    defer retention.deinit();
    var plants = try PlantState.init(allocator, try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 }));
    defer plants.deinit();
    canopy.plant_seed_storage_carbon_g[0] = 0;
    try std.testing.expect(!try applyStorageExhaustion(&canopy, &growth, &development, &phenology, &roots, &retention, &plants, 0, false, 1, 1.0e-12));
    try std.testing.expect(!growth.branches[0].dead);
}
