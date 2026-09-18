const std = @import("std");
const irrigation = @import("irrigation_schedule.zig");
const layer_routing = @import("irrigation_layer_routing.zig");
const land_management = @import("land_management.zig");
const PackedDate = @import("plant_management.zig").PackedDate;
const Date = @import("../core/options.zig").Date;
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");

pub const dissolved_species_count = 11;

pub const ScheduleMap = struct {
    allocator: std.mem.Allocator,
    schedule_by_cell: []?usize,

    pub fn init(allocator: std.mem.Allocator, assignments: land_management.Assignments, unit_by_cell: []const usize, catalog: irrigation.Catalog) !ScheduleMap {
        const map = try allocator.alloc(?usize, unit_by_cell.len);
        errdefer allocator.free(map);
        for (unit_by_cell, map) |unit_index, *entry| {
            if (unit_index >= assignments.units.len) return error.LandManagementUnitIndexOutOfBounds;
            const filename = assignments.units[unit_index].irrigation_file;
            entry.* = if (@import("../io/input/delimited_input.zig").isNo(filename)) null else catalog.find(filename) orelse return error.MissingIrrigationSchedule;
        }
        return .{ .allocator = allocator, .schedule_by_cell = map };
    }

    pub fn deinit(self: *ScheduleMap) void {
        self.allocator.free(self.schedule_by_cell);
        self.* = undefined;
    }
};

pub const HourlyInputs = struct {
    water_depth_m: []f64,
    dissolved_mass_g_per_m2: []f64,
    hydrogen_mol_per_m2: []f64,
};

pub const RuntimeRoutingContext = struct {
    cell_area_m2: []const f64,
    active_layer_count: []const usize,
    layer_thickness_m: []const f64,
    loads: *layer_routing.Loads,
};

pub const AutomatedPlanningInputs = struct {
    date: Date,
    cell_area_m2: []const f64,
    active_layer_count: []const usize,
    soil_layer_capacity: usize,
    layer_thickness_m: []const f64,
    porosity_fraction: []const f64,
    field_capacity_fraction: []const f64,
    wilting_point_fraction: []const f64,
    liquid_water_m3: []const f64,
    ice_water_m3: []const f64,
    minimum_canopy_water_potential_megapascal: []const f64,
};

/// Reproduces DAY.F's once-daily automatic-irrigation decision and writes the
/// following 24 source-hour depths. Storage is runtime sized as cell x 24.
pub fn planAutomatedDay(map: ScheduleMap, catalog: irrigation.Catalog, inputs: AutomatedPlanningInputs, depth_m_by_cell_hour: []f64) !usize {
    const cells = map.schedule_by_cell.len;
    if (inputs.cell_area_m2.len != cells or inputs.active_layer_count.len != cells or inputs.minimum_canopy_water_potential_megapascal.len != cells or inputs.soil_layer_capacity == 0 or depth_m_by_cell_hour.len != cells * 24) return error.IrrigationDispatchDimensionMismatch;
    const layers = try std.math.mul(usize, cells, inputs.soil_layer_capacity);
    inline for (.{ inputs.layer_thickness_m, inputs.porosity_fraction, inputs.field_capacity_fraction, inputs.wilting_point_fraction, inputs.liquid_water_m3, inputs.ice_water_m3 }) |values| if (values.len != layers) return error.IrrigationDispatchDimensionMismatch;
    @memset(depth_m_by_cell_hour, 0);
    var planned: usize = 0;
    const current_day = try dayOfYear(inputs.date);
    for (map.schedule_by_cell, 0..) |maybe_schedule, cell| {
        const schedule_index = maybe_schedule orelse continue;
        if (schedule_index >= catalog.entries.items.len) return error.IrrigationScheduleIndexOutOfBounds;
        const automatic = switch (catalog.entries.items[schedule_index].schedule) {
            .scheduled => continue,
            .automated => |value| value,
        };
        const start_day = dayOfYear(.{
            .day = automatic.start.day,
            .month = automatic.start.month,
            .year = inputs.date.year,
        }) catch |err| {
            // A recurring 29-Feb schedule has no occurrence in a source
            // non-leap year; every other invalid date is a malformed active
            // schedule and must not disappear silently.
            if (automatic.start.day == 29 and automatic.start.month == 2) continue;
            return err;
        };
        const end_day = dayOfYear(.{
            .day = automatic.end.day,
            .month = automatic.end.month,
            .year = inputs.date.year,
        }) catch |err| {
            if (automatic.end.day == 29 and automatic.end.month == 2) continue;
            return err;
        };
        if (current_day < start_day or current_day > end_day) continue;
        const area_m2 = inputs.cell_area_m2[cell];
        const active = inputs.active_layer_count[cell];
        if (!std.math.isFinite(area_m2) or area_m2 <= 0 or active > inputs.soil_layer_capacity) return error.InvalidAutomatedIrrigationState;
        var target_water_m3: f64 = 0;
        var wilting_water_m3: f64 = 0;
        var current_water_m3: f64 = 0;
        var remaining_depth_m = automatic.evaluated_soil_depth_m;
        for (0..active) |local_layer| {
            if (remaining_depth_m <= 0) break;
            const layer = cell * inputs.soil_layer_capacity + local_layer;
            const thickness_m = inputs.layer_thickness_m[layer];
            const included_thickness_m = @min(remaining_depth_m, thickness_m);
            if (!std.math.isFinite(thickness_m) or thickness_m <= 0 or included_thickness_m < 0) return error.InvalidAutomatedIrrigationState;
            const fraction = included_thickness_m / thickness_m;
            const volume_m3 = area_m2 * thickness_m;
            const porosity = inputs.porosity_fraction[layer];
            const field_capacity = inputs.field_capacity_fraction[layer];
            const wilting = inputs.wilting_point_fraction[layer];
            const target_fraction = @min(porosity, wilting + automatic.refill_fraction_of_field_capacity * (field_capacity - wilting));
            inline for (.{ porosity, field_capacity, wilting, target_fraction, inputs.liquid_water_m3[layer], inputs.ice_water_m3[layer] }) |value| if (!std.math.isFinite(value)) return error.InvalidAutomatedIrrigationState;
            if (porosity < 0 or field_capacity < wilting or wilting < 0 or target_fraction < 0 or inputs.liquid_water_m3[layer] < 0 or inputs.ice_water_m3[layer] < 0) return error.InvalidAutomatedIrrigationState;
            target_water_m3 += fraction * target_fraction * volume_m3;
            wilting_water_m3 += fraction * wilting * volume_m3;
            current_water_m3 += fraction * (inputs.liquid_water_m3[layer] + inputs.ice_water_m3[layer]);
            remaining_depth_m -= included_thickness_m;
        }
        const triggered = switch (automatic.trigger) {
            .soil_water_content => |remaining_fraction| current_water_m3 < wilting_water_m3 + remaining_fraction * (target_water_m3 - wilting_water_m3),
            .canopy_water_potential_megapascal => |threshold_megapascal| inputs.minimum_canopy_water_potential_megapascal[cell] < threshold_megapascal,
        };
        if (!triggered) continue;
        const required_depth_m = @max(0, target_water_m3 - current_water_m3) / area_m2;
        if (required_depth_m == 0) continue;
        const hours: usize = automatic.end.hour - automatic.start.hour + 1;
        const hourly_depth_m = required_depth_m / @as(f64, @floatFromInt(hours));
        for (automatic.start.hour..automatic.end.hour + 1) |zero_based_hour| depth_m_by_cell_hour[cell * 24 + zero_based_hour] = hourly_depth_m;
        planned += 1;
    }
    return planned;
}

pub fn accumulatePlannedAutomatedHour(map: ScheduleMap, catalog: irrigation.Catalog, source_hour: u8, depth_m_by_cell_hour: []const f64, outputs: HourlyInputs) !usize {
    const cells = map.schedule_by_cell.len;
    if (source_hour < 1 or source_hour > 24 or depth_m_by_cell_hour.len != cells * 24 or outputs.water_depth_m.len != cells or outputs.hydrogen_mol_per_m2.len != cells or outputs.dissolved_mass_g_per_m2.len != cells * dissolved_species_count) return error.IrrigationDispatchDimensionMismatch;
    var count: usize = 0;
    for (map.schedule_by_cell, 0..) |maybe_schedule, cell| {
        const schedule_index = maybe_schedule orelse continue;
        if (schedule_index >= catalog.entries.items.len) return error.IrrigationScheduleIndexOutOfBounds;
        const automatic = switch (catalog.entries.items[schedule_index].schedule) {
            .scheduled => continue,
            .automated => |value| value,
        };
        const depth_m = depth_m_by_cell_hour[cell * 24 + source_hour - 1];
        if (!std.math.isFinite(depth_m) or depth_m < 0) return error.InvalidScheduledIrrigationLoad;
        if (depth_m == 0) continue;
        outputs.water_depth_m[cell] += depth_m;
        outputs.hydrogen_mol_per_m2[cell] += depth_m * 1000.0 * std.math.pow(f64, 10.0, -automatic.water.ph);
        inline for (chemistryValues(automatic.water), 0..) |concentration_g_per_m3, species| {
            outputs.dissolved_mass_g_per_m2[cell * dissolved_species_count + species] += depth_m * concentration_g_per_m3;
        }
        count += 1;
    }
    return count;
}

pub fn accumulatePlannedAutomatedHourRouted(
    map: ScheduleMap,
    catalog: irrigation.Catalog,
    source_hour: u8,
    depth_m_by_cell_hour: []const f64,
    context: RuntimeRoutingContext,
) !usize {
    try validateRoutingContext(map, context);
    const cells = map.schedule_by_cell.len;
    if (source_hour < 1 or source_hour > 24 or
        depth_m_by_cell_hour.len != cells * 24)
        return error.IrrigationDispatchDimensionMismatch;
    var count: usize = 0;
    for (map.schedule_by_cell, 0..) |maybe_schedule, cell| {
        const schedule_index = maybe_schedule orelse continue;
        if (schedule_index >= catalog.entries.items.len)
            return error.IrrigationScheduleIndexOutOfBounds;
        const automatic = switch (catalog.entries.items[schedule_index].schedule) {
            .scheduled => continue,
            .automated => |value| value,
        };
        const depth_m =
            depth_m_by_cell_hour[cell * 24 + source_hour - 1];
        if (!std.math.isFinite(depth_m) or depth_m < 0)
            return error.InvalidScheduledIrrigationLoad;
        if (depth_m == 0) continue;
        try accumulateRoutedEvent(
            context,
            cell,
            depth_m,
            automatic.application_depth_m,
            automatic.water,
        );
        count += 1;
    }
    return count;
}

/// Adds scheduled irrigation for one model hour. The caller owns and clears
/// the output ledgers; this routine allocates nothing and validates the entire
/// map before publishing any load.
pub fn accumulateScheduledHour(map: ScheduleMap, catalog: irrigation.Catalog, date: Date, source_hour: u8, outputs: HourlyInputs) !usize {
    if (source_hour < 1 or source_hour > 24 or outputs.water_depth_m.len != map.schedule_by_cell.len or outputs.hydrogen_mol_per_m2.len != map.schedule_by_cell.len or outputs.dissolved_mass_g_per_m2.len != map.schedule_by_cell.len * dissolved_species_count) return error.IrrigationDispatchDimensionMismatch;
    var matches: usize = 0;
    for (map.schedule_by_cell) |maybe_schedule| if (maybe_schedule) |schedule_index| {
        if (schedule_index >= catalog.entries.items.len) return error.IrrigationScheduleIndexOutOfBounds;
        switch (catalog.entries.items[schedule_index].schedule) {
            .automated => {},
            .scheduled => |events| for (events) |event| {
                if (dateMatches(event.date, date) and source_hour >= event.first_hour and source_hour <= event.last_hour) {
                    const depth_m = event.hourlyAmountM();
                    if (!std.math.isFinite(depth_m) or depth_m < 0) return error.InvalidScheduledIrrigationLoad;
                    inline for (chemistryValues(event.water)) |concentration| if (!std.math.isFinite(concentration) or concentration < 0) return error.InvalidScheduledIrrigationLoad;
                    matches += 1;
                }
            },
        }
    };
    for (map.schedule_by_cell, 0..) |maybe_schedule, cell| if (maybe_schedule) |schedule_index| switch (catalog.entries.items[schedule_index].schedule) {
        .automated => {},
        .scheduled => |events| for (events) |event| {
            if (!dateMatches(event.date, date) or source_hour < event.first_hour or source_hour > event.last_hour) continue;
            const depth_m = event.hourlyAmountM();
            outputs.water_depth_m[cell] += depth_m;
            outputs.hydrogen_mol_per_m2[cell] += depth_m * 1000.0 * std.math.pow(f64, 10.0, -event.water.ph);
            inline for (chemistryValues(event.water), 0..) |concentration_g_per_m3, species| {
                outputs.dissolved_mass_g_per_m2[cell * dissolved_species_count + species] += depth_m * concentration_g_per_m3;
            }
        },
    };
    return matches;
}

pub fn accumulateScheduledHourRouted(
    map: ScheduleMap,
    catalog: irrigation.Catalog,
    date: Date,
    source_hour: u8,
    context: RuntimeRoutingContext,
) !usize {
    try validateRoutingContext(map, context);
    if (source_hour < 1 or source_hour > 24)
        return error.IrrigationDispatchDimensionMismatch;
    // Validate the complete hour before publishing any event.
    var matches: usize = 0;
    for (map.schedule_by_cell) |maybe_schedule| if (maybe_schedule) |schedule_index| {
        if (schedule_index >= catalog.entries.items.len)
            return error.IrrigationScheduleIndexOutOfBounds;
        switch (catalog.entries.items[schedule_index].schedule) {
            .automated => {},
            .scheduled => |events| for (events) |event| {
                if (!dateMatches(event.date, date) or
                    source_hour < event.first_hour or
                    source_hour > event.last_hour)
                    continue;
                const depth_m = event.hourlyAmountM();
                if (!std.math.isFinite(depth_m) or depth_m < 0)
                    return error.InvalidScheduledIrrigationLoad;
                inline for (chemistryValues(event.water)) |concentration|
                    if (!std.math.isFinite(concentration) or concentration < 0)
                        return error.InvalidScheduledIrrigationLoad;
                matches += 1;
            },
        }
    };
    for (map.schedule_by_cell, 0..) |maybe_schedule, cell| {
        const schedule_index = maybe_schedule orelse continue;
        switch (catalog.entries.items[schedule_index].schedule) {
            .automated => {},
            .scheduled => |events| for (events) |event| {
                if (!dateMatches(event.date, date) or
                    source_hour < event.first_hour or
                    source_hour > event.last_hour)
                    continue;
                try accumulateRoutedEvent(
                    context,
                    cell,
                    event.hourlyAmountM(),
                    event.application_depth_m,
                    event.water,
                );
            },
        }
    }
    return matches;
}

fn validateRoutingContext(
    map: ScheduleMap,
    context: RuntimeRoutingContext,
) !void {
    const cells = map.schedule_by_cell.len;
    if (context.loads.cell_count != cells or
        context.cell_area_m2.len != cells or
        context.active_layer_count.len != cells or
        context.layer_thickness_m.len !=
            cells * context.loads.soil_layer_capacity)
        return error.IrrigationDispatchDimensionMismatch;
}

fn accumulateRoutedEvent(
    context: RuntimeRoutingContext,
    cell: usize,
    water_depth_m: f64,
    application_depth_m: f64,
    water: irrigation.WaterChemistry_g_per_m3,
) !void {
    const first = cell * context.loads.soil_layer_capacity;
    try context.loads.accumulate(
        cell,
        context.active_layer_count[cell],
        context.layer_thickness_m[first .. first + context.loads.soil_layer_capacity],
        context.cell_area_m2[cell],
        water_depth_m,
        application_depth_m,
        water,
    );
}

fn chemistryValues(water: irrigation.WaterChemistry_g_per_m3) [dissolved_species_count]f64 {
    return .{ water.ammonium_nitrogen, water.nitrate_nitrogen, water.phosphate_phosphorus, water.aluminum, water.iron, water.calcium, water.magnesium, water.sodium, water.potassium, water.sulfate_sulfur, water.chloride };
}

fn dateMatches(event: PackedDate, date: Date) bool {
    return event.day == date.day and event.month == date.month and (event.isRecurring() or event.year == date.year);
}

fn dayOfYear(date: Date) !u16 {
    if (date.year == 0) return error.InvalidIrrigationDate;
    return execution_calendar_date.dayOfYear(.{
        .day = date.day,
        .month = date.month,
        .year = date.year,
    }) catch return error.InvalidIrrigationDate;
}

test "scheduled irrigation dispatch is runtime sized and date-hour selective" {
    const allocator = std.testing.allocator;
    var catalog = irrigation.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("water.txt", "01062024,24,7,12,0,7,1,2,3,4,5,6,7,8,9,10,11\n");
    var assignments = try land_management.fromUnits(allocator, &.{.{ .fertilizer_file = "no", .irrigation_file = "water.txt", .tillage_file = "till" }});
    defer assignments.deinit();
    const units = [_]usize{ 0, 0, 0 };
    var map = try ScheduleMap.init(allocator, assignments, &units, catalog);
    defer map.deinit();
    var depth = [_]f64{0} ** 3;
    var mass = [_]f64{0} ** (3 * dissolved_species_count);
    var hydrogen = [_]f64{0} ** 3;
    const count = try accumulateScheduledHour(map, catalog, .{ .day = 1, .month = 6, .year = 2024 }, 7, .{ .water_depth_m = &depth, .dissolved_mass_g_per_m2 = &mass, .hydrogen_mol_per_m2 = &hydrogen });
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.004), depth[2], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.004), mass[2 * dissolved_species_count], 1.0e-12);
}

test "automatic irrigation is planned once across its source-hour window" {
    const allocator = std.testing.allocator;
    var catalog = irrigation.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("AUTO-water", "01060000 30061800 0 .5 1 .3 0 7 0 0 0 0 0 0 0 0 0 0 0");
    var assignments = try land_management.fromUnits(allocator, &.{.{ .fertilizer_file = "no", .irrigation_file = "AUTO-water", .tillage_file = "no" }});
    defer assignments.deinit();
    const units = [_]usize{0};
    var map = try ScheduleMap.init(allocator, assignments, &units, catalog);
    defer map.deinit();
    var planned = [_]f64{0} ** 24;
    const count = try planAutomatedDay(map, catalog, .{
        .date = .{ .day = 15, .month = 6, .year = 2024 },
        .cell_area_m2 = &.{10},
        .active_layer_count = &.{1},
        .soil_layer_capacity = 1,
        .layer_thickness_m = &.{0.5},
        .porosity_fraction = &.{0.5},
        .field_capacity_fraction = &.{0.4},
        .wilting_point_fraction = &.{0.1},
        .liquid_water_m3 = &.{0.5},
        .ice_water_m3 = &.{0},
        .minimum_canopy_water_potential_megapascal = &.{-0.1},
    }, &planned);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.09 / 19.0), planned[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(planned[0], planned[18], 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0), planned[19]);
}

test "scheduled routing sends both surface- and depth-targeted events to the surface carriers (IRRIGATION-SUBSURFACE-DEAD-CODE-001)" {
    const allocator = std.testing.allocator;
    var catalog = irrigation.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource(
        "water-depths",
        "01062024 10 7 7 0.0 7 1 0 0 0 0 0 0 0 0 0 0\n" ++
            "01062024 20 7 7 0.25 7 0 2 0 0 0 0 0 0 0 0 0\n",
    );
    var assignments = try land_management.fromUnits(allocator, &.{.{
        .fertilizer_file = "no",
        .irrigation_file = "water-depths",
        .tillage_file = "no",
    }});
    defer assignments.deinit();
    var map = try ScheduleMap.init(allocator, assignments, &.{0}, catalog);
    defer map.deinit();
    var loads = try layer_routing.Loads.init(allocator, 1, 4);
    defer loads.deinit();
    const count = try accumulateScheduledHourRouted(
        map,
        catalog,
        .{ .day = 1, .month = 6, .year = 2024 },
        7,
        .{
            .cell_area_m2 = &.{10},
            .active_layer_count = &.{4},
            .layer_thickness_m = &.{ 0.1, 0.1, 0.1, 0.1 },
            .loads = &loads,
        },
    );
    try std.testing.expectEqual(@as(usize, 2), count);
    // Both events -- one with application_depth_m == 0, one with a nonzero
    // depth -- land on the surface carrier: the Fortran oracle's
    // depth-based split is permanently dead code (wthr.f:308-315), so
    // production must match it rather than actually deliver water below
    // the surface.
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.1 + 0.2),
        loads.surface_water_m3[0],
        1.0e-14,
    );
    for (loads.subsurface_water_m3) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
    // Event 1 (application_depth_m == 0) carries ammonium (species 0);
    // event 2 (application_depth_m == 0.25) carries nitrate (species 1).
    // Both land on the surface carrier for cell 0.
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.1),
        loads.surface_dissolved_mass_g[0],
        1.0e-14,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.4),
        loads.surface_dissolved_mass_g[1],
        1.0e-14,
    );
    for (loads.subsurface_dissolved_mass_g) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
}

test "irrigation dispatch preserves DAY modulo-four chronology" {
    try std.testing.expectEqual(
        @as(u16, 60),
        try dayOfYear(.{ .day = 29, .month = 2, .year = 1900 }),
    );
    try std.testing.expectEqual(
        @as(u16, 61),
        try dayOfYear(.{ .day = 1, .month = 3, .year = 1900 }),
    );
    try std.testing.expectError(
        error.InvalidIrrigationDate,
        dayOfYear(.{ .day = 0, .month = 2, .year = 1901 }),
    );
}

test "automatic irrigation leap-day windows are skipped in non-leap years" {
    const allocator = std.testing.allocator;
    var catalog = irrigation.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource(
        "AUTO-water",
        "29020000 29020000 0 .5 1 .3 0 7 0 0 0 0 0 0 0 0 0 0 0",
    );
    var assignments = try land_management.fromUnits(allocator, &.{.{ .fertilizer_file = "no", .irrigation_file = "AUTO-water", .tillage_file = "no" }});
    defer assignments.deinit();
    const units = [_]usize{0};
    var map = try ScheduleMap.init(allocator, assignments, &units, catalog);
    defer map.deinit();
    var planned = [_]f64{0} ** 24;
    const count = try planAutomatedDay(map, catalog, .{
        .date = .{ .day = 1, .month = 3, .year = 1901 },
        .cell_area_m2 = &.{10},
        .active_layer_count = &.{1},
        .soil_layer_capacity = 1,
        .layer_thickness_m = &.{0.5},
        .porosity_fraction = &.{0.5},
        .field_capacity_fraction = &.{0.4},
        .wilting_point_fraction = &.{0.1},
        .liquid_water_m3 = &.{0.5},
        .ice_water_m3 = &.{0},
        .minimum_canopy_water_potential_megapascal = &.{-0.1},
    }, &planned);
    try std.testing.expectEqual(@as(usize, 0), count);
    for (planned) |depth| {
        try std.testing.expectEqual(@as(f64, 0), depth);
    }
}
