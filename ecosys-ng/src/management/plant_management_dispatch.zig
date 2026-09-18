const std = @import("std");
const management = @import("plant_management.zig");
const plant_assignment = @import("../state/plant_assignment.zig");
const Date = @import("../core/options.zig").Date;
const Timestamp = @import("../io/input/weather.zig").Timestamp;
const phenology = @import("../plant/lifecycle/phenology.zig");
const growth_stages = @import("../plant/lifecycle/growth_stages.zig");
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");

pub const no_schedule = std.math.maxInt(usize);

/// Dense cell x species lookup constructed once from runtime assignments.
/// Hourly dispatch performs no allocation or filename lookup.
pub const ScheduleMap = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    catalog_index_by_plant: []usize,

    pub fn initMapped(allocator: std.mem.Allocator, cell_count: usize, species_count: usize, assignments: plant_assignment.Assignments, unit_by_cell: []const usize, catalog: management.Catalog) !ScheduleMap {
        if (cell_count == 0 or species_count == 0 or unit_by_cell.len != cell_count) return error.InvalidPlantManagementMapDimensions;
        const indices = try allocator.alloc(usize, try std.math.mul(usize, cell_count, species_count));
        errdefer allocator.free(indices);
        @memset(indices, no_schedule);
        for (unit_by_cell, 0..) |unit_index, cell| {
            if (unit_index >= assignments.units.len) return error.PlantAssignmentUnitOutOfBounds;
            const species_assignments = assignments.units[unit_index].species;
            if (species_assignments.len > species_count) return error.PlantSpeciesCapacityExceeded;
            for (species_assignments, 0..) |assignment, species| {
                if (@import("../io/input/delimited_input.zig").isNo(assignment.management_file)) continue;
                indices[cell * species_count + species] = catalog.find(assignment.management_file) orelse return error.MissingPlantManagementSchedule;
            }
        }
        return .{ .allocator = allocator, .cell_count = cell_count, .species_count = species_count, .catalog_index_by_plant = indices };
    }

    pub fn deinit(self: *ScheduleMap) void {
        self.allocator.free(self.catalog_index_by_plant);
        self.* = undefined;
    }
};

pub fn dateFromTimestamp(timestamp: Timestamp) !Date {
    const year = timestamp.year orelse return error.ManagementTimestampMissingYear;
    if (timestamp.month) |month| {
        const day = timestamp.day_of_month orelse return error.ManagementTimestampMissingDay;
        const result: Date = .{ .day = day, .month = month, .year = year };
        _ = calendarDayOfYear(result) catch return error.InvalidManagementTimestamp;
        return result;
    }
    const resolved = execution_calendar_date.fromDayOfYear(
        timestamp.day_of_year orelse return error.ManagementTimestampMissingDay,
        year,
    ) catch return error.InvalidManagementTimestamp;
    return .{ .day = resolved.day, .month = resolved.month, .year = resolved.year };
}

pub const DispatchCounts = struct { plants_with_schedules: usize = 0, events_applied: usize = 0 };

/// HFUNC IFLGC planting gate. A terminated plant remains inactive until an
/// exact subsequent planting date; a simulation beginning after its planting
/// date activates it on the first evaluated day.
pub fn refreshPlantActivity(map: ScheduleMap, catalog: management.Catalog, date: Date, plant_phenology: *phenology.State, stages: *growth_stages.State, emerged: []bool, lifecycle_initialized: []bool, newly_activated: []bool) !usize {
    const plant_count = try std.math.mul(usize, map.cell_count, map.species_count);
    if (plant_phenology.active.len != plant_count or stages.plant_count != plant_count or emerged.len != plant_count or lifecycle_initialized.len != plant_count or newly_activated.len != plant_count) return error.PlantLifecycleDimensionMismatch;
    @memset(newly_activated, false);
    const current_day_of_year = try calendarDayOfYear(date);
    var activation_count: usize = 0;
    for (map.catalog_index_by_plant, 0..) |catalog_index, plant| {
        if (catalog_index == no_schedule) continue;
        if (catalog_index >= catalog.entries.items.len) return error.PlantManagementCatalogIndexOutOfBounds;
        const planting = catalog.entries.items[catalog_index].schedule.planting.date;
        const resolved = try planting.resolve(date.year);
        const planting_key = resolved.orderKey();
        const current_key = date.orderKey();
        const exact_planting_day = planting_key == current_key;
        // IFLGC is the source inactive-plant gate. A recurring planting date
        // must not force an already living perennial back to pre-emergence.
        const has_replant_date = plant_phenology.replant_year[plant] != 0 or plant_phenology.replant_day_of_year[plant] != 0;
        if ((plant_phenology.replant_year[plant] == 0) != (plant_phenology.replant_day_of_year[plant] == 0))
            return error.InvalidPerennialReplantDate;
        const scheduled_replant_due = has_replant_date and
            (date.year > plant_phenology.replant_year[plant] or
                (date.year == plant_phenology.replant_year[plant] and current_day_of_year >= plant_phenology.replant_day_of_year[plant]));
        const activation_due = if (has_replant_date)
            scheduled_replant_due
        else
            exact_planting_day or (!lifecycle_initialized[plant] and current_key >= planting_key);
        if (!plant_phenology.active[plant] and activation_due) {
            plant_phenology.active[plant] = true;
            emerged[plant] = false;
            lifecycle_initialized[plant] = true;
            newly_activated[plant] = true;
            plant_phenology.replant_day_of_year[plant] = 0;
            plant_phenology.replant_year[plant] = 0;
            activation_count += 1;
            const branch_range = try stages.branchRange(plant);
            for (stages.branches[branch_range.first..branch_range.end]) |*branch| branch.dead = false;
        }
    }
    return activation_count;
}

pub fn calendarDayOfYear(date: Date) !u16 {
    return execution_calendar_date.dayOfYear(.{
        .day = date.day,
        .month = date.month,
        .year = date.year,
    }) catch return error.InvalidManagementDate;
}

/// Calls `apply(context, plant_index, event)` for every due event. Call only on
/// the first model hour of a calendar day, matching the daily management gate.
pub fn dispatchDate(map: ScheduleMap, catalog: management.Catalog, date: Date, context: anytype, comptime apply: anytype) !DispatchCounts {
    if (map.catalog_index_by_plant.len != try std.math.mul(usize, map.cell_count, map.species_count)) return error.PlantManagementMapDimensionMismatch;
    var counts: DispatchCounts = .{};
    for (map.catalog_index_by_plant, 0..) |catalog_index, plant| {
        if (catalog_index == no_schedule) continue;
        if (catalog_index >= catalog.entries.items.len) return error.PlantManagementCatalogIndexOutOfBounds;
        counts.plants_with_schedules += 1;
        var iterator = catalog.entries.items[catalog_index].schedule.eventsOnDate(date);
        while (iterator.next()) |event| {
            try apply(context, plant, event.*);
            counts.events_applied += 1;
        }
    }
    return counts;
}

/// Solar-noon deterministic harvest dispatch. Demand-driven grazing events
/// remain active in their separate hourly kernel.
pub fn dispatchDateNonGrazing(map: ScheduleMap, catalog: management.Catalog, date: Date, context: anytype, comptime apply: anytype) !DispatchCounts {
    if (map.catalog_index_by_plant.len != try std.math.mul(usize, map.cell_count, map.species_count)) return error.PlantManagementMapDimensionMismatch;
    var counts: DispatchCounts = .{};
    for (map.catalog_index_by_plant, 0..) |catalog_index, plant| {
        if (catalog_index == no_schedule) continue;
        if (catalog_index >= catalog.entries.items.len) return error.PlantManagementCatalogIndexOutOfBounds;
        counts.plants_with_schedules += 1;
        var iterator = catalog.entries.items[catalog_index].schedule.eventsOnDate(date);
        while (iterator.next()) |event| {
            if (event.kind == .animal_grazing or event.kind == .insect_grazing) continue;
            try apply(context, plant, event.*);
            counts.events_applied += 1;
        }
    }
    return counts;
}

pub fn dispatchDateGrazing(map: ScheduleMap, catalog: management.Catalog, date: Date, context: anytype, comptime apply: anytype) !DispatchCounts {
    if (map.catalog_index_by_plant.len != try std.math.mul(usize, map.cell_count, map.species_count)) return error.PlantManagementMapDimensionMismatch;
    var counts: DispatchCounts = .{};
    for (map.catalog_index_by_plant, 0..) |catalog_index, plant| {
        if (catalog_index == no_schedule) continue;
        if (catalog_index >= catalog.entries.items.len) return error.PlantManagementCatalogIndexOutOfBounds;
        counts.plants_with_schedules += 1;
        var iterator = catalog.entries.items[catalog_index].schedule.eventsOnDate(date);
        while (iterator.next()) |event| {
            if (event.kind != .animal_grazing and event.kind != .insect_grazing) continue;
            try apply(context, plant, event.*);
            counts.events_applied += 1;
        }
    }
    return counts;
}

/// GROSUB THVST/TWTSHT pre-pass. Both animal and insect grazing records
/// contribute to the cell totals; the caller applies the redistribution only
/// to animal grazing.
pub fn accumulateGrazingRebalanceTotals(
    map: ScheduleMap,
    catalog: management.Catalog,
    date: Date,
    shoot_carbon_g_c: []const f64,
    active: []const bool,
    total_shoot_carbon_g_c_by_cell: []f64,
    total_grazer_biomass_by_cell: []f64,
) !void {
    const plant_count = try std.math.mul(usize, map.cell_count, map.species_count);
    if (map.catalog_index_by_plant.len != plant_count or shoot_carbon_g_c.len != plant_count or
        active.len != plant_count or total_shoot_carbon_g_c_by_cell.len != map.cell_count or
        total_grazer_biomass_by_cell.len != map.cell_count) return error.GrazingRebalanceDimensionMismatch;
    @memset(total_shoot_carbon_g_c_by_cell, 0);
    @memset(total_grazer_biomass_by_cell, 0);
    for (map.catalog_index_by_plant, 0..) |catalog_index, plant| {
        if (!active[plant] or catalog_index == no_schedule) continue;
        if (catalog_index >= catalog.entries.items.len) return error.PlantManagementCatalogIndexOutOfBounds;
        var iterator = catalog.entries.items[catalog_index].schedule.eventsOnDate(date);
        while (iterator.next()) |event| {
            if (event.kind != .animal_grazing and event.kind != .insect_grazing) continue;
            if (!std.math.isFinite(event.cutting_height_m_or_lai_fraction) or event.cutting_height_m_or_lai_fraction < 0)
                return error.InvalidGrazerBiomass;
            const cell = plant / map.species_count;
            total_shoot_carbon_g_c_by_cell[cell] += shoot_carbon_g_c[plant];
            total_grazer_biomass_by_cell[cell] += event.cutting_height_m_or_lai_fraction;
        }
    }
}

/// GROSUB permits monthly forest self-thinning only when the day's IHVST is
/// absent/negative or is demand-driven animal/insect grazing.
pub fn allowsForestSelfThinning(map: ScheduleMap, catalog: management.Catalog, date: Date, plant: usize) !bool {
    if (plant >= map.catalog_index_by_plant.len) return error.PlantManagementMapIndexOutOfBounds;
    const catalog_index = map.catalog_index_by_plant[plant];
    if (catalog_index == no_schedule) return true;
    if (catalog_index >= catalog.entries.items.len) return error.PlantManagementCatalogIndexOutOfBounds;
    var iterator = catalog.entries.items[catalog_index].schedule.eventsOnDate(date);
    while (iterator.next()) |event| {
        if (event.kind != .animal_grazing and event.kind != .insect_grazing) return false;
    }
    return true;
}

test "runtime management map dispatches recurring events without example dependencies" {
    const allocator = std.testing.allocator;
    var assignments = try plant_assignment.fromUnits(allocator, &.{&.{ .{ .species_file = "maiz", .management_file = "maize_management" }, .{ .species_file = "wheat", .management_file = "NO" } }});
    defer assignments.deinit();
    const unit_by_cell = [_]usize{0};
    var catalog = management.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("maize_management", "01059999,10,0.02\n15069999,2,0,0.2,0,1,1,1,1,0.8,0.8,0.8,0.8\n");
    var map = try ScheduleMap.initMapped(allocator, 1, 2, assignments, &unit_by_cell, catalog);
    defer map.deinit();
    const Counter = struct {
        count: usize = 0,
        plant: usize = no_schedule,
        fn apply(self: *@This(), plant: usize, event: management.HarvestEvent) !void {
            self.count += 1;
            self.plant = plant;
            try std.testing.expectEqual(management.HarvestKind.above_ground, event.kind);
        }
    };
    var counter: Counter = .{};
    const counts = try dispatchDate(map, catalog, .{ .day = 15, .month = 6, .year = 2024 }, &counter, Counter.apply);
    try std.testing.expectEqual(@as(usize, 1), counts.plants_with_schedules);
    try std.testing.expectEqual(@as(usize, 1), counts.events_applied);
    try std.testing.expectEqual(@as(usize, 0), counter.plant);
}

test "HFUNC plant lifecycle activates on recurring planting day" {
    const allocator = std.testing.allocator;
    var assignments = try plant_assignment.fromUnits(allocator, &.{&.{.{ .species_file = "maiz", .management_file = "maize_management" }}});
    defer assignments.deinit();
    var catalog = management.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("maize_management", "01059999,10,0.02\n");
    var map = try ScheduleMap.initMapped(allocator, 1, 1, assignments, &.{0}, catalog);
    defer map.deinit();
    var plant_state = try phenology.State.init(allocator, 1, 1);
    defer plant_state.deinit();
    var stages = try growth_stages.State.init(allocator, &.{1});
    defer stages.deinit();
    var emerged = [_]bool{true};
    var initialized = [_]bool{false};
    var activated = [_]bool{false};
    _ = try refreshPlantActivity(map, catalog, .{ .day = 30, .month = 4, .year = 2024 }, &plant_state, &stages, &emerged, &initialized, &activated);
    try std.testing.expect(!plant_state.active[0]);
    try std.testing.expectEqual(@as(usize, 1), try refreshPlantActivity(map, catalog, .{ .day = 1, .month = 5, .year = 2024 }, &plant_state, &stages, &emerged, &initialized, &activated));
    try std.testing.expect(plant_state.active[0]);
    try std.testing.expect(!emerged[0]);
    try std.testing.expect(activated[0]);
}

test "recurring planting date does not reset an active perennial" {
    const allocator = std.testing.allocator;
    var assignments = try plant_assignment.fromUnits(allocator, &.{&.{.{ .species_file = "aspen", .management_file = "aspen_management" }}});
    defer assignments.deinit();
    var catalog = management.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("aspen_management", "01059999,10,0.02\n");
    var map = try ScheduleMap.initMapped(allocator, 1, 1, assignments, &.{0}, catalog);
    defer map.deinit();
    var plant_state = try phenology.State.init(allocator, 1, 1);
    defer plant_state.deinit();
    var stages = try growth_stages.State.init(allocator, &.{1});
    defer stages.deinit();
    plant_state.active[0] = true;
    stages.branches[0].dead = false;
    var emerged = [_]bool{true};
    var initialized = [_]bool{true};

    var activated = [_]bool{false};
    try std.testing.expectEqual(@as(usize, 0), try refreshPlantActivity(map, catalog, .{ .day = 1, .month = 5, .year = 2025 }, &plant_state, &stages, &emerged, &initialized, &activated));

    try std.testing.expect(plant_state.active[0]);
    try std.testing.expect(emerged[0]);
    try std.testing.expect(!activated[0]);
    try std.testing.expect(!stages.branches[0].dead);
}

test "dead perennial waits for its runtime next-day replant date" {
    const allocator = std.testing.allocator;
    var assignments = try plant_assignment.fromUnits(allocator, &.{&.{.{ .species_file = "aspen", .management_file = "aspen_management" }}});
    defer assignments.deinit();
    var catalog = management.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("aspen_management", "01059999,10,0.02\n");
    var map = try ScheduleMap.initMapped(allocator, 1, 1, assignments, &.{0}, catalog);
    defer map.deinit();
    var plant_state = try phenology.State.init(allocator, 1, 1);
    defer plant_state.deinit();
    var stages = try growth_stages.State.init(allocator, &.{1});
    defer stages.deinit();
    plant_state.replant_day_of_year[0] = 1;
    plant_state.replant_year[0] = 2025;
    var emerged = [_]bool{true};
    var initialized = [_]bool{false};
    var activated = [_]bool{false};

    try std.testing.expectEqual(@as(usize, 0), try refreshPlantActivity(map, catalog, .{ .day = 31, .month = 12, .year = 2024 }, &plant_state, &stages, &emerged, &initialized, &activated));
    try std.testing.expect(!plant_state.active[0]);
    try std.testing.expectEqual(@as(usize, 1), try refreshPlantActivity(map, catalog, .{ .day = 1, .month = 1, .year = 2025 }, &plant_state, &stages, &emerged, &initialized, &activated));
    try std.testing.expect(plant_state.active[0]);
    try std.testing.expectEqual(@as(u16, 0), plant_state.replant_day_of_year[0]);
    try std.testing.expectEqual(@as(u16, 0), plant_state.replant_year[0]);
}

test "day-of-year management timestamp converts leap day exactly" {
    const date = try dateFromTimestamp(.{ .year = 2024, .day_of_year = 60, .month = null, .day_of_month = null, .hour = 0, .minute = 0 });
    try std.testing.expectEqual(@as(u8, 29), date.day);
    try std.testing.expectEqual(@as(u8, 2), date.month);
    const century = try dateFromTimestamp(.{ .year = 1900, .day_of_year = 60, .month = null, .day_of_month = null, .hour = 0, .minute = 0 });
    try std.testing.expectEqual(@as(u8, 29), century.day);
    try std.testing.expectEqual(@as(u8, 2), century.month);
    try std.testing.expectEqual(
        @as(u16, 60),
        try calendarDayOfYear(.{ .day = 29, .month = 2, .year = 1900 }),
    );
    try std.testing.expectError(
        error.InvalidManagementTimestamp,
        dateFromTimestamp(.{ .year = 1901, .day_of_year = 366, .month = null, .day_of_month = null, .hour = 0, .minute = 0 }),
    );
}

test "GROSUB forest self thinning gate excludes scheduled cutting but permits grazing" {
    const allocator = std.testing.allocator;
    var assignments = try plant_assignment.fromUnits(allocator, &.{&.{.{ .species_file = "aspen", .management_file = "aspen_management" }}});
    defer assignments.deinit();
    var catalog = management.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("aspen_management", "01059999,10,0.02\n" ++
        "30059999,2,0,0.2,0,1,1,1,1,0,0,0,0\n" ++
        "29069999,4,0,0,0.1,1,1,1,1,0,0,0,0\n");
    var map = try ScheduleMap.initMapped(allocator, 1, 1, assignments, &.{0}, catalog);
    defer map.deinit();
    try std.testing.expect(!try allowsForestSelfThinning(map, catalog, .{ .day = 30, .month = 5, .year = 2024 }, 0));
    try std.testing.expect(try allowsForestSelfThinning(map, catalog, .{ .day = 29, .month = 6, .year = 2024 }, 0));
    try std.testing.expect(try allowsForestSelfThinning(map, catalog, .{ .day = 30, .month = 6, .year = 2024 }, 0));
}

test "solar-noon dispatcher excludes demand-driven grazing events" {
    const allocator = std.testing.allocator;
    var assignments = try plant_assignment.fromUnits(allocator, &.{&.{.{ .species_file = "maiz", .management_file = "maize_management" }}});
    defer assignments.deinit();
    var catalog = management.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("maize_management", "01059999,10,0.02\n" ++
        "15069999,2,0,0.2,0,1,1,1,1,0.8,0.8,0.8,0.8\n" ++
        "15069999,4,0,0,0.1,1,1,1,1,0,0,0,0\n");
    var map = try ScheduleMap.initMapped(allocator, 1, 1, assignments, &.{0}, catalog);
    defer map.deinit();
    const Counter = struct {
        count: usize = 0,
        fn apply(self: *@This(), _: usize, event: management.HarvestEvent) !void {
            try std.testing.expectEqual(management.HarvestKind.above_ground, event.kind);
            self.count += 1;
        }
    };
    var counter: Counter = .{};
    const counts = try dispatchDateNonGrazing(map, catalog, .{ .day = 15, .month = 6, .year = 2024 }, &counter, Counter.apply);
    try std.testing.expectEqual(@as(usize, 1), counts.events_applied);
    try std.testing.expectEqual(@as(usize, 1), counter.count);
}

test "hourly grazing dispatcher and GROSUB cell rebalance are self contained" {
    const allocator = std.testing.allocator;
    var assignments = try plant_assignment.fromUnits(allocator, &.{&.{ .{ .species_file = "crop_a", .management_file = "grazing_a" }, .{ .species_file = "crop_b", .management_file = "grazing_b" } }});
    defer assignments.deinit();
    var catalog = management.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("grazing_a", "01059999,10,0.02\n15069999,4,0,2,0.1,1,1,1,1,0,0,0,0\n");
    _ = try catalog.appendFromSource("grazing_b", "01059999,10,0.02\n15069999,6,0,3,0.1,1,1,1,1,0,0,0,0\n");
    var map = try ScheduleMap.initMapped(allocator, 1, 2, assignments, &.{0}, catalog);
    defer map.deinit();
    const date: Date = .{ .day = 15, .month = 6, .year = 2024 };
    var total_shoot = [_]f64{0};
    var total_grazers = [_]f64{0};
    try accumulateGrazingRebalanceTotals(map, catalog, date, &.{ 4, 6 }, &.{ true, true }, &total_shoot, &total_grazers);
    try std.testing.expectApproxEqAbs(@as(f64, 10), total_shoot[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5), total_grazers[0], 1e-12);
    const Counter = struct {
        count: usize = 0,
        fn apply(self: *@This(), _: usize, event: management.HarvestEvent) !void {
            try std.testing.expect(event.kind == .animal_grazing or event.kind == .insect_grazing);
            self.count += 1;
        }
    };
    var counter: Counter = .{};
    const counts = try dispatchDateGrazing(map, catalog, date, &counter, Counter.apply);
    try std.testing.expectEqual(@as(usize, 2), counts.events_applied);
    try std.testing.expectEqual(@as(usize, 2), counter.count);
}
