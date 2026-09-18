const std = @import("std");
const delimited_input = @import("../io/input/delimited_input.zig");
const fertilizer_schedule = @import("fertilizer_schedule.zig");
const land_management = @import("land_management.zig");
const Date = @import("../core/options.zig").Date;
const nitrogen_inventory = @import("fertilizer_nitrogen_inventory.zig");
const reactive_nitrogen_state = @import("../soil/nutrients/reactive_nitrogen_state.zig");
const surface_fertilizer = @import("../surface/litter_fertilizer.zig");
const organic = @import("../soil/organic/initialization.zig");
const organic_parameters = @import("../soil/organic/parameters.zig");
const organic_application = @import("organic_fertilizer_application.zig");
const soil_solver_properties = @import("../soil/water/solver_properties.zig");
const mineral_fertilizer = @import("mineral_fertilizer_inventory.zig");
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");

/// Dense runtime lookup built once when a scene is activated. `null` denotes
/// an explicit case-insensitive NO schedule, never a missing file lookup.
pub const ScheduleMap = struct {
    allocator: std.mem.Allocator,
    catalog_index_by_cell: []?usize,

    pub fn init(allocator: std.mem.Allocator, assignments: land_management.Assignments, unit_by_cell: []const usize, catalog: fertilizer_schedule.Catalog) !ScheduleMap {
        const map = try allocator.alloc(?usize, unit_by_cell.len);
        errdefer allocator.free(map);
        for (unit_by_cell, 0..) |unit_index, cell| {
            if (unit_index >= assignments.units.len) return error.LandManagementUnitIndexOutOfBounds;
            const name = assignments.units[unit_index].fertilizer_file;
            map[cell] = if (delimited_input.isNo(name)) null else catalog.find(name) orelse return error.FertilizerScheduleMissingFromCatalog;
        }
        return .{ .allocator = allocator, .catalog_index_by_cell = map };
    }

    pub fn deinit(self: *ScheduleMap) void {
        self.allocator.free(self.catalog_index_by_cell);
        self.* = undefined;
    }
};

/// Exact extensive material introduced by accepted fertilizer events for one
/// cell/hour. These are producer quantities, not differences of cumulative
/// diagnostics. Element fields use the same formula-mole conventions as
/// `mineral_fertilizer_inventory.applyEvent`.
pub const FertilizerActivity = struct {
    carbon_g_c: f64 = 0,
    /// Subset of carbon_g_c supplied by CaCO3, not organic fertilizer.
    /// The local ledger consumes total C; the landscape daily organic-input
    /// owner cannot account for this separate mineral boundary.
    mineral_carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
    aluminum_mol: f64 = 0,
    iron_mol: f64 = 0,
    calcium_mol: f64 = 0,
    magnesium_mol: f64 = 0,
    sodium_mol: f64 = 0,
    potassium_mol: f64 = 0,
    sulfur_mol: f64 = 0,
    silicon_mol: f64 = 0,

    pub fn hasMaterialInput(self: FertilizerActivity) bool {
        inline for (std.meta.fields(FertilizerActivity)) |field|
            if (@field(self, field.name) > 0) return true;
        return false;
    }

    fn add(self: *FertilizerActivity, addition: FertilizerActivity) !void {
        inline for (std.meta.fields(FertilizerActivity)) |field| {
            const next = @field(self, field.name) + @field(addition, field.name);
            if (!std.math.isFinite(next) or next < 0) return error.FertilizerActivityOverflow;
            @field(self, field.name) = next;
        }
    }
};

/// Accepted fertilizer input resolved to the two owners that may receive one
/// HOUR1 event. `soil_layer` is local to the event's cell. The surface and
/// soil fragments deliberately remain extensive and direction-free here;
/// the conservation adapter is the sole owner of ledger direction fields.
pub const RoutedEventActivity = struct {
    surface: FertilizerActivity = .{},
    soil: FertilizerActivity = .{},
    soil_layer: usize,
};

/// Hour-scoped producer sidecar. It is reconstructed before any fertilizer
/// owner mutates, then published only after nitrogen, mineral and organic
/// application all accept. Thus a failed outer-hour attempt cannot leave a
/// one-sided accounting write, while successful applications retain their
/// exact litter-versus-soil-layer provenance.
pub const LocalActivityState = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    soil_layer_capacity: usize,
    surface_by_cell: []FertilizerActivity,
    soil_by_layer: []FertilizerActivity,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        soil_layer_capacity: usize,
    ) !LocalActivityState {
        if (cell_count == 0 or soil_layer_capacity == 0)
            return error.ZeroFertilizerActivityExtent;
        const layer_count = try std.math.mul(usize, cell_count, soil_layer_capacity);
        const surface = try allocator.alloc(FertilizerActivity, cell_count);
        errdefer allocator.free(surface);
        const soil = try allocator.alloc(FertilizerActivity, layer_count);
        @memset(surface, .{});
        @memset(soil, .{});
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .soil_layer_capacity = soil_layer_capacity,
            .surface_by_cell = surface,
            .soil_by_layer = soil,
        };
    }

    pub fn deinit(self: *LocalActivityState) void {
        self.allocator.free(self.surface_by_cell);
        self.allocator.free(self.soil_by_layer);
        self.* = undefined;
    }

    pub fn reset(self: *LocalActivityState) void {
        @memset(self.surface_by_cell, .{});
        @memset(self.soil_by_layer, .{});
    }

    /// Reconstructs the same accepted events and litter-cover split consumed
    /// by all three live application owners. HOUR1 routes every non-surface
    /// fragment to the single depth-selected soil layer for that event.
    pub fn reconstructAcceptedHour(
        self: *LocalActivityState,
        map: ScheduleMap,
        catalog: fertilizer_schedule.Catalog,
        date: Date,
        source_hour_one_through_twenty_four: u8,
        solar_noon_hour_by_cell: []const u8,
        cell_area_m2: []const f64,
        carbon_g_per_mol: f64,
        active_soil_layer_count: []const usize,
        soil_layer_thickness_m: []const f64,
        surface_organic: *const organic.State,
    ) !void {
        try validateDispatchDate(date);
        if (map.catalog_index_by_cell.len != self.cell_count or
            solar_noon_hour_by_cell.len != self.cell_count or
            cell_area_m2.len != self.cell_count or
            active_soil_layer_count.len != self.cell_count or
            surface_organic.layer_count != self.cell_count or
            soil_layer_thickness_m.len != self.soil_by_layer.len)
            return error.FertilizerActivityDimensionMismatch;
        if (!std.math.isFinite(carbon_g_per_mol) or carbon_g_per_mol <= 0)
            return error.InvalidFertilizerCellArea;

        self.reset();
        for (0..self.cell_count) |cell| {
            if (!try isApplicationHour(
                source_hour_one_through_twenty_four,
                solar_noon_hour_by_cell,
                cell,
            )) continue;
            const area_m2 = cell_area_m2[cell];
            if (!std.math.isFinite(area_m2) or area_m2 <= 0)
                return error.InvalidFertilizerCellArea;
            const active_layers = active_soil_layer_count[cell];
            if (active_layers == 0 or active_layers > self.soil_layer_capacity)
                return error.InvalidActiveSoilLayerCount;
            const first = try std.math.mul(usize, cell, self.soil_layer_capacity);
            const thickness = soil_layer_thickness_m[first .. first + active_layers];
            for (thickness) |value|
                if (!std.math.isFinite(value) or value <= 0)
                    return error.InvalidSoilLayerThickness;
            const surface_carbon_g_c = try surface_organic.totalCarbon_g_c(cell);
            const cover_fraction = 1.0 - @exp(-0.008 * surface_carbon_g_c / area_m2);
            const schedule_index = map.catalog_index_by_cell[cell] orelse continue;
            if (schedule_index >= catalog.entries.items.len)
                return error.FertilizerScheduleIndexOutOfBounds;
            for (catalog.entries.items[schedule_index].events) |event| {
                if (event.date.day != date.day or event.date.month != date.month or
                    (!event.date.isRecurring() and event.date.year != date.year)) continue;
                const routed = try eventRoutedActivity(
                    event,
                    area_m2,
                    carbon_g_per_mol,
                    cover_fraction,
                    thickness,
                );
                try self.surface_by_cell[cell].add(routed.surface);
                try self.soil_by_layer[first + routed.soil_layer].add(routed.soil);
            }
        }
    }
};

/// Exact destination split shared by the local-conservation sidecar. The
/// predicates and conversions mirror `fertilizer_nitrogen_inventory`,
/// `mineral_fertilizer_inventory`, and `applyOrganic` respectively.
pub fn eventRoutedActivity(
    event: fertilizer_schedule.Event,
    area_m2: f64,
    carbon_g_per_mol: f64,
    surface_litter_cover_fraction: f64,
    active_layer_thickness_m: []const f64,
) !RoutedEventActivity {
    _ = try eventActivity(event, area_m2, carbon_g_per_mol);
    if (!std.math.isFinite(surface_litter_cover_fraction) or
        surface_litter_cover_fraction < 0 or surface_litter_cover_fraction > 1 or
        active_layer_thickness_m.len == 0)
        return error.InvalidFertilizerApplication;
    for (active_layer_thickness_m) |thickness|
        if (!std.math.isFinite(thickness) or thickness <= 0)
            return error.InvalidSoilLayerThickness;
    const soil_layer = try organicLayerAtDepth(
        active_layer_thickness_m,
        event.application_depth_m,
    );
    var result: RoutedEventActivity = .{ .soil_layer = soil_layer };

    const n = event.nitrogen_g_per_m2;
    const p = event.phosphorus_g_per_m2;
    const banded_nitrogen = n.banded_ammonium + n.banded_ammonia +
        n.banded_urea + n.banded_nitrate;
    const surface_target = event.application_depth_m == 0 and
        banded_nitrogen == 0 and p.banded_monocalcium_phosphate == 0 and
        event.calcium_carbonate_g_ca_per_m2 == 0 and
        event.calcium_sulfate_g_ca_per_m2 == 0;
    if (surface_target) {
        result.surface.nitrogen_g_n += (n.broadcast_ammonium +
            n.broadcast_urea + n.broadcast_nitrate) * area_m2 *
            surface_litter_cover_fraction;
        result.soil.nitrogen_g_n += n.broadcast_ammonia * area_m2 +
            (n.broadcast_ammonium + n.broadcast_urea + n.broadcast_nitrate) *
                area_m2 * (1.0 - surface_litter_cover_fraction);
    } else {
        result.soil.nitrogen_g_n += (n.broadcast_ammonium +
            n.broadcast_ammonia + n.broadcast_urea + n.broadcast_nitrate) * area_m2;
    }
    result.soil.nitrogen_g_n += banded_nitrogen * area_m2;

    const broadcast_monocalcium_mol =
        p.broadcast_monocalcium_phosphate * area_m2 / 62.0;
    const banded_monocalcium_mol =
        p.banded_monocalcium_phosphate * area_m2 / 62.0;
    const hydroxyapatite_mol =
        p.broadcast_hydroxyapatite * area_m2 / 93.0;
    const broadcast_phosphorus_g = (p.broadcast_monocalcium_phosphate +
        p.broadcast_hydroxyapatite) * area_m2;
    if (surface_target) {
        result.surface.phosphorus_g_p += broadcast_phosphorus_g *
            surface_litter_cover_fraction;
        result.soil.phosphorus_g_p += broadcast_phosphorus_g *
            (1.0 - surface_litter_cover_fraction);
        result.surface.calcium_mol += (broadcast_monocalcium_mol +
            5.0 * hydroxyapatite_mol) * surface_litter_cover_fraction;
        result.soil.calcium_mol += (broadcast_monocalcium_mol +
            5.0 * hydroxyapatite_mol) * (1.0 - surface_litter_cover_fraction);
    } else {
        result.soil.phosphorus_g_p += broadcast_phosphorus_g;
        result.soil.calcium_mol += broadcast_monocalcium_mol +
            5.0 * hydroxyapatite_mol;
    }
    result.soil.phosphorus_g_p += p.banded_monocalcium_phosphate * area_m2;
    result.soil.calcium_mol += banded_monocalcium_mol;

    const calcite_mol = event.calcium_carbonate_g_ca_per_m2 * area_m2 / 40.0;
    result.soil.carbon_g_c += calcite_mol * carbon_g_per_mol;
    result.soil.mineral_carbon_g_c += calcite_mol * carbon_g_per_mol;
    result.soil.calcium_mol += calcite_mol;
    if (event.fertilizer_formulation < 10) {
        const gypsum_mol = event.calcium_sulfate_g_ca_per_m2 * area_m2 / 40.0;
        result.soil.calcium_mol += gypsum_mol;
        result.soil.sulfur_mol += gypsum_mol;
    } else {
        const each_ground_silicate_mol =
            event.calcium_sulfate_g_ca_per_m2 * area_m2 / (92.0 * 6.0);
        result.soil.aluminum_mol += each_ground_silicate_mol;
        result.soil.iron_mol += each_ground_silicate_mol;
        result.soil.calcium_mol += each_ground_silicate_mol;
        result.soil.magnesium_mol += each_ground_silicate_mol;
        result.soil.sodium_mol += each_ground_silicate_mol;
        result.soil.potassium_mol += each_ground_silicate_mol;
        result.soil.silicon_mol += 3.0 * each_ground_silicate_mol;
    }

    inline for (.{ event.plant_residue_g_per_m2, event.manure_g_per_m2 }) |input| {
        const destination = if (event.application_depth_m == 0)
            &result.surface
        else
            &result.soil;
        destination.carbon_g_c += input.carbon * area_m2;
        destination.nitrogen_g_n += input.nitrogen * area_m2;
        destination.phosphorus_g_p += input.phosphorus * area_m2;
    }
    inline for (std.meta.fields(FertilizerActivity)) |field| {
        const surface_value = @field(result.surface, field.name);
        const soil_value = @field(result.soil, field.name);
        if (!std.math.isFinite(surface_value) or surface_value < 0 or
            !std.math.isFinite(soil_value) or soil_value < 0)
            return error.InvalidFertilizerApplication;
    }
    return result;
}

/// Reconstructs the exact input accepted by all three fertilizer application
/// owners for a single cell. The hour/date gates are shared with dispatch;
/// callers can therefore preflight conservation before any owner mutation and
/// publish the same result after all three applications succeed.
pub fn applicationActivityForCell(
    map: ScheduleMap,
    catalog: fertilizer_schedule.Catalog,
    date: Date,
    source_hour_one_through_twenty_four: u8,
    solar_noon_hour_by_cell: []const u8,
    cell_area_m2: []const f64,
    carbon_g_per_mol: f64,
    cell: usize,
) !FertilizerActivity {
    try validateDispatchDate(date);
    if (cell >= map.catalog_index_by_cell.len or cell >= cell_area_m2.len)
        return error.FertilizerDispatchCellOutOfBounds;
    if (!try isApplicationHour(source_hour_one_through_twenty_four, solar_noon_hour_by_cell, cell))
        return .{};
    const area_m2 = cell_area_m2[cell];
    if (!std.math.isFinite(area_m2) or area_m2 <= 0 or
        !std.math.isFinite(carbon_g_per_mol) or carbon_g_per_mol <= 0)
        return error.InvalidFertilizerCellArea;
    const schedule_index = map.catalog_index_by_cell[cell] orelse return .{};
    if (schedule_index >= catalog.entries.items.len)
        return error.FertilizerScheduleIndexOutOfBounds;
    var result: FertilizerActivity = .{};
    for (catalog.entries.items[schedule_index].events) |event| {
        if (event.date.day != date.day or event.date.month != date.month or
            (!event.date.isRecurring() and event.date.year != date.year)) continue;
        try result.add(try eventActivity(event, area_m2, carbon_g_per_mol));
    }
    return result;
}

fn eventActivity(
    event: fertilizer_schedule.Event,
    area_m2: f64,
    carbon_g_per_mol: f64,
) !FertilizerActivity {
    var result: FertilizerActivity = .{};
    const n = event.nitrogen_g_per_m2;
    inline for (@typeInfo(fertilizer_schedule.Nitrogen_g_per_m2).@"struct".fields) |field| {
        const value = @field(n, field.name) * area_m2;
        if (!std.math.isFinite(value) or value < 0) return error.InvalidFertilizerApplication;
        result.nitrogen_g_n += value;
    }
    const p = event.phosphorus_g_per_m2;
    const broadcast_monocalcium_mol = p.broadcast_monocalcium_phosphate * area_m2 / 62.0;
    const banded_monocalcium_mol = p.banded_monocalcium_phosphate * area_m2 / 62.0;
    const hydroxyapatite_mol = p.broadcast_hydroxyapatite * area_m2 / 93.0;
    result.phosphorus_g_p = (p.broadcast_monocalcium_phosphate +
        p.banded_monocalcium_phosphate + p.broadcast_hydroxyapatite) * area_m2;
    result.calcium_mol = broadcast_monocalcium_mol + banded_monocalcium_mol +
        5.0 * hydroxyapatite_mol;

    const calcite_mol = event.calcium_carbonate_g_ca_per_m2 * area_m2 / 40.0;
    result.carbon_g_c = calcite_mol * carbon_g_per_mol;
    result.mineral_carbon_g_c = calcite_mol * carbon_g_per_mol;
    result.calcium_mol += calcite_mol;
    if (event.fertilizer_formulation < 10) {
        const gypsum_mol = event.calcium_sulfate_g_ca_per_m2 * area_m2 / 40.0;
        result.calcium_mol += gypsum_mol;
        result.sulfur_mol = gypsum_mol;
    } else {
        const each_ground_silicate_mol = event.calcium_sulfate_g_ca_per_m2 * area_m2 / (92.0 * 6.0);
        result.aluminum_mol = each_ground_silicate_mol;
        result.iron_mol = each_ground_silicate_mol;
        result.calcium_mol += each_ground_silicate_mol;
        result.magnesium_mol = each_ground_silicate_mol;
        result.sodium_mol = each_ground_silicate_mol;
        result.potassium_mol = each_ground_silicate_mol;
        result.silicon_mol = 3.0 * each_ground_silicate_mol;
    }
    inline for (.{ event.plant_residue_g_per_m2, event.manure_g_per_m2 }) |organic_input| {
        result.carbon_g_c += organic_input.carbon * area_m2;
        result.nitrogen_g_n += organic_input.nitrogen * area_m2;
        result.phosphorus_g_p += organic_input.phosphorus * area_m2;
    }
    inline for (std.meta.fields(FertilizerActivity)) |field|
        if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0)
            return error.InvalidFertilizerApplication;
    return result;
}

pub fn dispatchDate(map: ScheduleMap, catalog: fertilizer_schedule.Catalog, date: Date, context: anytype, comptime apply: fn (@TypeOf(context), usize, *const fertilizer_schedule.Event) anyerror!void) !usize {
    try validateDispatchDate(date);
    var applied: usize = 0;
    for (map.catalog_index_by_cell, 0..) |maybe_schedule, cell| {
        const schedule_index = maybe_schedule orelse continue;
        if (schedule_index >= catalog.entries.items.len) return error.FertilizerScheduleIndexOutOfBounds;
        for (catalog.entries.items[schedule_index].events) |*event| {
            if (event.date.day != date.day or event.date.month != date.month or (!event.date.isRecurring() and event.date.year != date.year)) continue;
            try apply(context, cell, event);
            applied = try std.math.add(usize, applied, 1);
        }
    }
    return applied;
}

fn validateDispatchDate(date: Date) !void {
    if (date.year == 0) return error.InvalidFertilizerDispatchDate;
    _ = execution_calendar_date.dayOfYear(.{ .day = date.day, .month = date.month, .year = date.year }) catch return error.InvalidFertilizerDispatchDate;
}

pub const NitrogenApplyContext = struct {
    soil: *nitrogen_inventory.State,
    surface: *surface_fertilizer.State,
    /// Sole owner of the runtime nitrification-inhibition activity arrays
    /// (`FERT-002`); must share `soil`'s `cell * layer_capacity + layer`
    /// indexing.
    reactive_nitrogen: *reactive_nitrogen_state.State,
    cell_area_m2: []const f64,
    active_soil_layer_count: []const usize,
    soil_layer_thickness_m: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
    surface_organic: *const organic.State,
    source_hour_one_through_twenty_four: u8,
    solar_noon_hour_by_cell: []const u8,
};

pub fn applyNitrogen(context: *NitrogenApplyContext, cell: usize, event: *const fertilizer_schedule.Event) !void {
    if (!try isApplicationHour(context.source_hour_one_through_twenty_four, context.solar_noon_hour_by_cell, cell)) return;
    if (cell >= context.soil.cell_count or cell >= context.cell_area_m2.len or cell >= context.active_soil_layer_count.len) return error.FertilizerDispatchCellOutOfBounds;
    const layer_count = context.active_soil_layer_count[cell];
    if (layer_count == 0 or layer_count > context.soil.layer_capacity) return error.InvalidActiveSoilLayerCount;
    const first = try std.math.mul(usize, cell, context.soil.layer_capacity);
    if (first + layer_count > context.soil_layer_thickness_m.len) return error.FertilizerDispatchLayerExtentMismatch;
    const area_m2 = context.cell_area_m2[cell];
    if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidFertilizerCellArea;
    const surface_carbon_g_c = try context.surface_organic.totalCarbon_g_c(cell);
    const cover_fraction = 1.0 - @exp(-0.008 * surface_carbon_g_c / area_m2);
    try nitrogen_inventory.applyEventNitrogen(context.soil, context.surface, context.reactive_nitrogen, cell, area_m2, context.nitrogen_molar_mass_g_per_mol, cover_fraction, context.soil_layer_thickness_m[first .. first + layer_count], event.*);
}

pub const MineralApplyContext = struct {
    inventory: *mineral_fertilizer.State,
    surface_organic: *const organic.State,
    cell_area_m2: []const f64,
    active_soil_layer_count: []const usize,
    soil_layer_thickness_m: []const f64,
    source_hour_one_through_twenty_four: u8,
    solar_noon_hour_by_cell: []const u8,
};

pub fn applyMinerals(context: *MineralApplyContext, cell: usize, event: *const fertilizer_schedule.Event) !void {
    if (!try isApplicationHour(context.source_hour_one_through_twenty_four, context.solar_noon_hour_by_cell, cell)) return;
    if (cell >= context.inventory.cell_count or cell >= context.surface_organic.layer_count or cell >= context.cell_area_m2.len or cell >= context.active_soil_layer_count.len) return error.FertilizerDispatchCellOutOfBounds;
    const active_layers = context.active_soil_layer_count[cell];
    const first = try std.math.mul(usize, cell, context.inventory.layer_capacity);
    if (active_layers == 0 or active_layers > context.inventory.layer_capacity or first + active_layers > context.soil_layer_thickness_m.len) return error.FertilizerDispatchLayerExtentMismatch;
    const area_m2 = context.cell_area_m2[cell];
    if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidFertilizerCellArea;
    const surface_carbon_g_c = try context.surface_organic.totalCarbon_g_c(cell);
    const cover_fraction = 1.0 - @exp(-0.008 * surface_carbon_g_c / area_m2);
    try mineral_fertilizer.applyEvent(context.inventory, cell, area_m2, cover_fraction, context.soil_layer_thickness_m[first .. first + active_layers], event.*);
}

pub const OrganicApplyContext = struct {
    soil: *organic.State,
    surface: *organic.State,
    parameters: *const organic_parameters.OwnedParameters,
    cell_area_m2: []const f64,
    active_soil_layer_count: []const usize,
    soil_layer_capacity: usize,
    soil_layer_thickness_m: []const f64,
    daily_organic_carbon_input_g_c: []f64,
    daily_biome_carbon_input_g_c: []f64,
    daily_organic_phosphorus_input_g_p: []f64,
    daily_organic_nitrogen_input_g_n: []f64,
    source_hour_one_through_twenty_four: u8,
    solar_noon_hour_by_cell: []const u8,
};

pub fn applyOrganic(context: *OrganicApplyContext, cell: usize, event: *const fertilizer_schedule.Event) !void {
    if (!try isApplicationHour(context.source_hour_one_through_twenty_four, context.solar_noon_hour_by_cell, cell)) return;
    if (cell >= context.cell_area_m2.len or cell >= context.active_soil_layer_count.len or cell >= context.daily_organic_carbon_input_g_c.len or cell >= context.daily_biome_carbon_input_g_c.len or cell >= context.daily_organic_phosphorus_input_g_p.len or cell >= context.daily_organic_nitrogen_input_g_n.len or cell >= context.surface.layer_count) return error.FertilizerDispatchCellOutOfBounds;
    const active_layers = context.active_soil_layer_count[cell];
    const first = try std.math.mul(usize, cell, context.soil_layer_capacity);
    if (active_layers == 0 or active_layers > context.soil_layer_capacity or first + active_layers > context.soil_layer_thickness_m.len or first + active_layers > context.soil.layer_count) return error.FertilizerDispatchLayerExtentMismatch;
    const area_m2 = context.cell_area_m2[cell];
    if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidFertilizerCellArea;
    const local_layer = try organicLayerAtDepth(context.soil_layer_thickness_m[first .. first + active_layers], event.application_depth_m);
    const destination = if (event.application_depth_m == 0) context.surface else context.soil;
    const destination_layer = if (event.application_depth_m == 0) cell else first + local_layer;
    const plant: organic.ElementPool = .{
        .carbon_g_c = event.plant_residue_g_per_m2.carbon * area_m2,
        .nitrogen_g_n = event.plant_residue_g_per_m2.nitrogen * area_m2,
        .phosphorus_g_p = event.plant_residue_g_per_m2.phosphorus * area_m2,
    };
    const manure: organic.ElementPool = .{
        .carbon_g_c = event.manure_g_per_m2.carbon * area_m2,
        .nitrogen_g_n = event.manure_g_per_m2.nitrogen * area_m2,
        .phosphorus_g_p = event.manure_g_per_m2.phosphorus * area_m2,
    };
    // Preflight every late ledger write before mutating the organic owner.
    const daily_organic_next = context.daily_organic_carbon_input_g_c[cell] + plant.carbon_g_c + manure.carbon_g_c;
    const daily_phosphorus_next = context.daily_organic_phosphorus_input_g_p[cell] + plant.phosphorus_g_p + manure.phosphorus_g_p;
    const daily_nitrogen_next = context.daily_organic_nitrogen_input_g_n[cell] + plant.nitrogen_g_n + manure.nitrogen_g_n;
    const daily_biome_next = context.daily_biome_carbon_input_g_c[cell] + plant.carbon_g_c + manure.carbon_g_c;
    inline for (.{ daily_organic_next, daily_phosphorus_next, daily_nitrogen_next, daily_biome_next }) |value|
        if (!std.math.isFinite(value)) return error.OrganicFertilizerApplicationOverflow;

    const owner_microbial_stride: usize = organic.microbial_substrate_count *
        organic.microbial_population_count *
        organic.kinetic_fraction_count;
    const owner_dissolved_stride: usize = organic.substrate_count;
    const owner_structural_stride: usize = organic.substrate_count * organic.structural_fraction_count;

    const owner_microbial_start = destination_layer * owner_microbial_stride;
    const owner_dissolved_start = destination_layer * owner_dissolved_stride;
    const owner_structural_start = destination_layer * owner_structural_stride;

    var owner_microbial_before: [organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count]organic.ElementPool = undefined;
    var owner_dissolved_before: [organic.substrate_count]organic.ElementPool = undefined;
    var owner_structural_before: [organic.substrate_count * organic.structural_fraction_count]organic.ElementPool = undefined;
    var owner_colonized_before: [organic.substrate_count * organic.structural_fraction_count]f64 = undefined;

    @memcpy(&owner_microbial_before, destination.microbial[owner_microbial_start .. owner_microbial_start + owner_microbial_stride]);
    @memcpy(&owner_dissolved_before, destination.dissolved[owner_dissolved_start .. owner_dissolved_start + owner_dissolved_stride]);
    @memcpy(&owner_structural_before, destination.structural[owner_structural_start .. owner_structural_start + owner_structural_stride]);
    @memcpy(&owner_colonized_before, destination.colonized_structural_carbon_g_c[owner_structural_start .. owner_structural_start + owner_structural_stride]);

    const rollback = struct {
        fn restore(
            target: *organic.State,
            microbial_start_from: usize,
            dissolved_start_from: usize,
            structural_start_from: usize,
            microbial_stride_from: usize,
            dissolved_stride_from: usize,
            structural_stride_from: usize,
            microbial_before: [*]const organic.ElementPool,
            dissolved_before: [*]const organic.ElementPool,
            structural_before: [*]const organic.ElementPool,
            colonized_before: []const f64,
        ) void {
            @memcpy(target.microbial[microbial_start_from .. microbial_start_from + microbial_stride_from], microbial_before[0..microbial_stride_from]);
            @memcpy(target.dissolved[dissolved_start_from .. dissolved_start_from + dissolved_stride_from], dissolved_before[0..dissolved_stride_from]);
            @memcpy(target.structural[structural_start_from .. structural_start_from + structural_stride_from], structural_before[0..structural_stride_from]);
            @memcpy(target.colonized_structural_carbon_g_c[structural_start_from .. structural_start_from + structural_stride_from], colonized_before);
        }
    };

    if (organic_application.apply(destination, destination_layer, .plant_residue, event.plant_residue_type, plant, context.parameters)) |_| {
        // Continue.
    } else |err| {
        rollback.restore(destination, owner_microbial_start, owner_dissolved_start, owner_structural_start, owner_microbial_stride, owner_dissolved_stride, owner_structural_stride, &owner_microbial_before, &owner_dissolved_before, &owner_structural_before, &owner_colonized_before);
        return err;
    }
    if (organic_application.apply(destination, destination_layer, .manure, event.manure_type, manure, context.parameters)) |_| {
        // Continue.
    } else |err| {
        rollback.restore(destination, owner_microbial_start, owner_dissolved_start, owner_structural_start, owner_microbial_stride, owner_dissolved_stride, owner_structural_stride, &owner_microbial_before, &owner_dissolved_before, &owner_structural_before, &owner_colonized_before);
        return err;
    }
    context.daily_organic_carbon_input_g_c[cell] = daily_organic_next;
    context.daily_organic_phosphorus_input_g_p[cell] = daily_phosphorus_next;
    context.daily_organic_nitrogen_input_g_n[cell] = daily_nitrogen_next;
    if (event.manure_type < 3)
        context.daily_biome_carbon_input_g_c[cell] = daily_biome_next;
}

fn isApplicationHour(source_hour: u8, solar_noon_by_cell: []const u8, cell: usize) !bool {
    if (source_hour == 0 or source_hour > 24) return error.InvalidHourlyFertilizerSchedule;
    if (cell >= solar_noon_by_cell.len) return error.FertilizerDispatchCellOutOfBounds;
    const solar_noon = solar_noon_by_cell[cell];
    if (solar_noon > 24) return error.InvalidHourlyFertilizerSchedule;
    return source_hour == solar_noon;
}

/// Weather observations use a 0--23 wall clock, while the legacy HOUR1
/// management gate numbers the same hours 1--24 with midnight represented by
/// 24. Keep this conversion at the driver boundary so all fertilizer owners
/// continue to share one unambiguous schedule domain.
pub fn sourceHourOneThroughTwentyFour(wall_clock_hour_zero_through_twenty_three: u8) !u8 {
    if (wall_clock_hour_zero_through_twenty_three > 23)
        return error.InvalidHourlyFertilizerSchedule;
    return if (wall_clock_hour_zero_through_twenty_three == 0)
        24
    else
        wall_clock_hour_zero_through_twenty_three;
}

fn organicLayerAtDepth(thickness_m: []const f64, depth_m: f64) !usize {
    var lower_boundary_m: f64 = 0;
    for (thickness_m, 0..) |thickness, layer| {
        lower_boundary_m += thickness;
        if (depth_m <= lower_boundary_m) return layer;
    }
    return error.FertilizerApplicationBelowSoilProfile;
}

test "fertilizer dispatch handles recurring dates and case-insensitive NO" {
    const allocator = std.testing.allocator;
    var assignments = try land_management.fromUnits(allocator, &.{ .{ .fertilizer_file = "annual", .irrigation_file = "NO", .tillage_file = "tillage" }, .{ .fertilizer_file = "no", .irrigation_file = "irrigation", .tillage_file = "tillage" } });
    defer assignments.deinit();
    const units = try assignments.buildCellUnitMap(allocator);
    defer allocator.free(units);
    var catalog = fertilizer_schedule.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("annual", "01050000 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n");
    var map = try ScheduleMap.init(allocator, assignments, units, catalog);
    defer map.deinit();
    var count: usize = 0;
    const Callback = struct {
        fn apply(output: *usize, cell: usize, event: *const fertilizer_schedule.Event) !void {
            try std.testing.expectEqual(@as(usize, 0), cell);
            try std.testing.expectEqual(@as(f64, 1), event.nitrogen_g_per_m2.broadcast_ammonium);
            output.* += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 1), try dispatchDate(map, catalog, .{ .day = 1, .month = 5, .year = 2026 }, &count, Callback.apply));
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "fertilizer dispatch date preserves DAY modulo-four chronology" {
    try validateDispatchDate(.{ .day = 29, .month = 2, .year = 1900 });
    try validateDispatchDate(.{ .day = 30, .month = 4, .year = 1901 });
    try std.testing.expectError(error.InvalidFertilizerDispatchDate, validateDispatchDate(.{ .day = 0, .month = 2, .year = 1901 }));
    try std.testing.expectError(
        error.InvalidFertilizerDispatchDate,
        validateDispatchDate(.{ .day = 1, .month = 1, .year = 0 }),
    );
}

test "HOUR1 fertilizer admission uses each grid cell solar noon" {
    const solar_noon = [_]u8{ 11, 13 };
    try std.testing.expect(try isApplicationHour(11, &solar_noon, 0));
    try std.testing.expect(!try isApplicationHour(11, &solar_noon, 1));
    try std.testing.expect(!try isApplicationHour(12, &solar_noon, 0));
    try std.testing.expect(try isApplicationHour(13, &solar_noon, 1));
    try std.testing.expectError(
        error.InvalidHourlyFertilizerSchedule,
        isApplicationHour(0, &solar_noon, 0),
    );
    try std.testing.expectError(
        error.FertilizerDispatchCellOutOfBounds,
        isApplicationHour(11, &solar_noon, 2),
    );
}

test "fertilizer source clock maps weather midnight to legacy hour twenty four" {
    try std.testing.expectEqual(
        @as(u8, 24),
        try sourceHourOneThroughTwentyFour(0),
    );
    try std.testing.expectEqual(
        @as(u8, 12),
        try sourceHourOneThroughTwentyFour(12),
    );
    try std.testing.expectError(
        error.InvalidHourlyFertilizerSchedule,
        sourceHourOneThroughTwentyFour(24),
    );
}

test "organic dispatch resolves runtime depth and publishes UORGF and eligible TNBP input" {
    const allocator = std.testing.allocator;
    var soil = try organic.State.init(allocator, 2);
    defer soil.deinit();
    var surface = try organic.State.init(allocator, 1);
    defer surface.deinit();
    var parameters = try organic_parameters.sourceParameters(allocator);
    defer parameters.deinit();
    var daily_organic = [_]f64{0};
    var daily_biome = [_]f64{0};
    var daily_phosphorus = [_]f64{0};
    var daily_nitrogen = [_]f64{0};
    var context: OrganicApplyContext = .{
        .soil = &soil,
        .surface = &surface,
        .parameters = &parameters,
        .cell_area_m2 = &.{10},
        .active_soil_layer_count = &.{2},
        .soil_layer_capacity = 2,
        .soil_layer_thickness_m = &.{ 0.1, 0.2 },
        .daily_organic_carbon_input_g_c = &daily_organic,
        .daily_biome_carbon_input_g_c = &daily_biome,
        .daily_organic_phosphorus_input_g_p = &daily_phosphorus,
        .daily_organic_nitrogen_input_g_n = &daily_nitrogen,
        .source_hour_one_through_twenty_four = 12,
        .solar_noon_hour_by_cell = &.{12},
    };
    const event: fertilizer_schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 0 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 0, .broadcast_ammonia = 0, .broadcast_urea = 0, .broadcast_nitrate = 0, .banded_ammonium = 0, .banded_ammonia = 0, .banded_urea = 0, .banded_nitrate = 0 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 0, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 0 },
        .calcium_carbonate_g_ca_per_m2 = 0,
        .calcium_sulfate_g_ca_per_m2 = 0,
        .plant_residue_g_per_m2 = .{ .carbon = 2, .nitrogen = 0.2, .phosphorus = 0.02 },
        .manure_g_per_m2 = .{ .carbon = 3, .nitrogen = 0.3, .phosphorus = 0.03 },
        .application_depth_m = 0.15,
        .band_row_width_m = 0,
        .fertilizer_formulation = 0,
        .plant_residue_type = 2,
        .manure_type = 2,
    };
    try applyOrganic(&context, 0, &event);
    try std.testing.expectEqual(@as(f64, 50), daily_organic[0]);
    try std.testing.expectEqual(@as(f64, 50), daily_biome[0]);
    try std.testing.expectEqual(@as(f64, 0.5), daily_phosphorus[0]);
    try std.testing.expectEqual(@as(f64, 5), daily_nitrogen[0]);
    var upper_dissolved_carbon_g_c: f64 = 0;
    var lower_dissolved_carbon_g_c: f64 = 0;
    for (soil.dissolved[0..organic.substrate_count]) |pool| upper_dissolved_carbon_g_c += pool.carbon_g_c;
    for (soil.dissolved[organic.substrate_count .. 2 * organic.substrate_count]) |pool| lower_dissolved_carbon_g_c += pool.carbon_g_c;
    try std.testing.expectEqual(@as(f64, 0), upper_dissolved_carbon_g_c);
    try std.testing.expect(lower_dissolved_carbon_g_c > 0);
}

test "organic dispatch rolls back full state change when manure application fails" {
    const allocator = std.testing.allocator;
    var soil = try organic.State.init(allocator, 2);
    defer soil.deinit();
    var surface = try organic.State.init(allocator, 1);
    defer surface.deinit();
    var parameters = try organic_parameters.sourceParameters(allocator);
    defer parameters.deinit();

    var daily_organic = [_]f64{0};
    var daily_biome = [_]f64{0};
    var daily_phosphorus = [_]f64{0};
    var daily_nitrogen = [_]f64{0};
    var context: OrganicApplyContext = .{
        .soil = &soil,
        .surface = &surface,
        .parameters = &parameters,
        .cell_area_m2 = &.{10},
        .active_soil_layer_count = &.{2},
        .soil_layer_capacity = 2,
        .soil_layer_thickness_m = &.{ 0.1, 0.2 },
        .daily_organic_carbon_input_g_c = &daily_organic,
        .daily_biome_carbon_input_g_c = &daily_biome,
        .daily_organic_phosphorus_input_g_p = &daily_phosphorus,
        .daily_organic_nitrogen_input_g_n = &daily_nitrogen,
        .source_hour_one_through_twenty_four = 12,
        .solar_noon_hour_by_cell = &.{12},
    };
    const event: fertilizer_schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 0 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 0, .broadcast_ammonia = 0, .broadcast_urea = 0, .broadcast_nitrate = 0, .banded_ammonium = 0, .banded_ammonia = 0, .banded_urea = 0, .banded_nitrate = 0 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 0, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 0 },
        .calcium_carbonate_g_ca_per_m2 = 0,
        .calcium_sulfate_g_ca_per_m2 = 0,
        .plant_residue_g_per_m2 = .{ .carbon = 2, .nitrogen = 0.2, .phosphorus = 0.02 },
        .manure_g_per_m2 = .{ .carbon = -1, .nitrogen = -0.1, .phosphorus = -0.01 },
        .application_depth_m = 0.15,
        .band_row_width_m = 0,
        .fertilizer_formulation = 0,
        .plant_residue_type = 2,
        .manure_type = 2,
    };

    const before_microbial = try allocator.dupe(organic.ElementPool, soil.microbial);
    defer allocator.free(before_microbial);
    const before_dissolved = try allocator.dupe(organic.ElementPool, soil.dissolved);
    defer allocator.free(before_dissolved);
    const before_structural = try allocator.dupe(organic.ElementPool, soil.structural);
    defer allocator.free(before_structural);
    const before_colonized = try allocator.dupe(f64, soil.colonized_structural_carbon_g_c);
    defer allocator.free(before_colonized);

    try std.testing.expectError(error.InvalidOrganicFertilizerInput, applyOrganic(&context, 0, &event));
    try std.testing.expectEqualSlices(organic.ElementPool, before_microbial, soil.microbial);
    try std.testing.expectEqualSlices(organic.ElementPool, before_dissolved, soil.dissolved);
    try std.testing.expectEqualSlices(organic.ElementPool, before_structural, soil.structural);
    try std.testing.expectEqualSlices(f64, before_colonized, soil.colonized_structural_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), daily_organic[0]);
    try std.testing.expectEqual(@as(f64, 0), daily_biome[0]);
    try std.testing.expectEqual(@as(f64, 0), daily_phosphorus[0]);
    try std.testing.expectEqual(@as(f64, 0), daily_nitrogen[0]);
}

fn organicApplyContextForCharcoalTest(
    soil: *organic.State,
    surface: *organic.State,
    parameters: *const organic_parameters.OwnedParameters,
    daily_organic: []f64,
    daily_biome: []f64,
    daily_phosphorus: []f64,
    daily_nitrogen: []f64,
    cec: []f64,
    aec: []f64,
    cec_mol: []f64,
    aec_mol: []f64,
    bulk_density_megagrams_per_m3: []const f64,
    layer_volume_m3: []const f64,
) OrganicApplyContext {
    _ = .{ cec, aec, cec_mol, aec_mol, bulk_density_megagrams_per_m3, layer_volume_m3 };
    return .{
        .soil = soil,
        .surface = surface,
        .parameters = parameters,
        .cell_area_m2 = &.{10},
        .active_soil_layer_count = &.{2},
        .soil_layer_capacity = 2,
        .soil_layer_thickness_m = &.{ 0.1, 0.2 },
        .daily_organic_carbon_input_g_c = daily_organic,
        .daily_biome_carbon_input_g_c = daily_biome,
        .daily_organic_phosphorus_input_g_p = daily_phosphorus,
        .daily_organic_nitrogen_input_g_n = daily_nitrogen,
        .source_hour_one_through_twenty_four = 12,
        .solar_noon_hour_by_cell = &.{12},
    };
}

const TestSoilProperties = struct {
    state: soil_solver_properties.State,

    fn init(allocator: std.mem.Allocator, layer_count: usize) !TestSoilProperties {
        @setEvalBranchQuota(10_000);
        const retention = @import("../soil/water/retention.zig");
        var state: soil_solver_properties.State = undefined;
        state.allocator = allocator;
        state.layer_count = layer_count;
        var allocated: usize = 0;
        errdefer {
            var visited: usize = 0;
            inline for (@typeInfo(soil_solver_properties.State).@"struct".fields) |field| {
                if (field.type == []f64 or field.type == []retention.ResolvedCurve or field.type == []retention.MualemVanGenuchtenParameters) {
                    if (visited < allocated) allocator.free(@field(state, field.name));
                    visited += 1;
                }
            }
        }
        inline for (@typeInfo(soil_solver_properties.State).@"struct".fields) |field| {
            if (field.type == []f64) {
                @field(state, field.name) = try allocator.alloc(f64, layer_count);
                @memset(@field(state, field.name), 0);
                allocated += 1;
            } else if (field.type == []retention.ResolvedCurve) {
                @field(state, field.name) = try allocator.alloc(retention.ResolvedCurve, layer_count);
                allocated += 1;
            } else if (field.type == []retention.MualemVanGenuchtenParameters) {
                @field(state, field.name) = try allocator.alloc(retention.MualemVanGenuchtenParameters, layer_count);
                allocated += 1;
            }
        }
        @memset(state.matrix_bulk_volume_m3, 1);
        @memset(state.layer_volume_m3, 2);
        @memset(state.layer_thickness_m, 0.1);
        @memset(state.bulk_density_megagrams_per_m3, 1);
        @memset(state.sand_mass_fraction, 0.5);
        @memset(state.silt_mass_fraction, 0.3);
        @memset(state.clay_mass_fraction, 0.2);
        @memset(state.total_organic_carbon_g_per_megagram, 10_000);
        @memset(state.porosity_fraction, 0.5);
        @memset(state.micropore_fraction, 0.8);
        @memset(state.macropore_fraction, 0.1);
        @memset(state.rock_fraction, 0.1);
        @memset(state.supplied_field_capacity_fraction, 0.3);
        @memset(state.supplied_wilting_point_fraction, 0.1);
        @memset(state.field_capacity_water_potential_megapascal, -0.033);
        @memset(state.wilting_point_water_potential_megapascal, -1.5);
        @memset(state.supplied_vertical_saturated_hydraulic_conductivity_m_per_h, -1);
        @memset(state.supplied_lateral_saturated_hydraulic_conductivity_m_per_h, -1);
        @memset(state.supplied_lateral_conductivity_m2_per_h_megapascal, -1);
        @memset(state.van_genuchten_inflection_pressure_head_m, 0);
        @memset(state.field_capacity_fraction, 0.3);
        @memset(state.wilting_point_fraction, 0.1);
        @memset(state.saturation_water_potential_megapascal, -0.001);
        @memset(state.cation_exchange_capacity_mol_per_megagram, 20);
        @memset(state.anion_exchange_capacity_mol_per_megagram, 2);
        @memset(state.cation_exchange_capacity_mol, 20);
        @memset(state.anion_exchange_capacity_mol, 2);
        @memset(state.rainfall_conductivity_multiplier, 1);
        const curve = try retention.resolve(soil_solver_properties.compatibilityParameters().retention, .{
            .porosity_fraction = 0.5,
            .macropore_fraction = 0.1,
            .sand_fraction = 0.5,
            .clay_fraction = 0.2,
            .organic_carbon_g_per_megagram = 10_000,
            .bulk_density_megagrams_per_m3 = 1,
            .supplied_field_capacity_fraction = 0.3,
            .supplied_wilting_point_fraction = 0.1,
        }, -0.033, -1.5);
        @memset(state.retention_curve, curve);
        const mualem = try retention.carselParrishDefault(.loam, 0.5);
        @memset(state.mualem_van_genuchten_parameters, mualem);
        @memset(state.lateral_saturated_hydraulic_conductivity_m_per_h, mualem.saturated_hydraulic_conductivity_m_per_h);
        return .{ .state = state };
    }

    fn deinit(self: *TestSoilProperties) void {
        self.state.deinit();
    }
};

test "subsurface charcoal property effects are deferred to accepted-hour material refresh" {
    const allocator = std.testing.allocator;
    var soil = try organic.State.init(allocator, 2);
    defer soil.deinit();
    var surface = try organic.State.init(allocator, 1);
    defer surface.deinit();
    var parameters = try organic_parameters.sourceParameters(allocator);
    defer parameters.deinit();
    var daily_organic = [_]f64{0};
    var daily_biome = [_]f64{0};
    var daily_phosphorus = [_]f64{0};
    var daily_nitrogen = [_]f64{0};
    var cec = [_]f64{ 20.0, 20.0 };
    var aec = [_]f64{ 2.0, 2.0 };
    var cec_mol = [_]f64{ 200.0, 400.0 };
    var aec_mol = [_]f64{ 20.0, 40.0 };
    const bulk_density_megagrams_per_m3 = [_]f64{ 1.0, 2.0 };
    const layer_volume_m3 = [_]f64{ 1.0, 10.0 };
    var context = organicApplyContextForCharcoalTest(&soil, &surface, &parameters, &daily_organic, &daily_biome, &daily_phosphorus, &daily_nitrogen, &cec, &aec, &cec_mol, &aec_mol, &bulk_density_megagrams_per_m3, &layer_volume_m3);
    var properties = try TestSoilProperties.init(allocator, 2);
    defer properties.deinit();
    // Source VOLY excludes rock/macropores: matrix=10 m3, total=20 m3.
    properties.state.matrix_bulk_volume_m3[1] = 10;
    properties.state.layer_volume_m3[1] = 20;
    properties.state.bulk_density_megagrams_per_m3[1] = 2;
    properties.state.cation_exchange_capacity_mol[1] = 400;
    properties.state.anion_exchange_capacity_mol[1] = 40;
    const event: fertilizer_schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 0 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 0, .broadcast_ammonia = 0, .broadcast_urea = 0, .broadcast_nitrate = 0, .banded_ammonium = 0, .banded_ammonia = 0, .banded_urea = 0, .banded_nitrate = 0 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 0, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 0 },
        .calcium_carbonate_g_ca_per_m2 = 0,
        .calcium_sulfate_g_ca_per_m2 = 0,
        .plant_residue_g_per_m2 = .{ .carbon = 10_000.0, .nitrogen = 0, .phosphorus = 0 },
        .manure_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .application_depth_m = 0.15,
        .band_row_width_m = 0,
        .fertilizer_formulation = 0,
        .plant_residue_type = 10,
        .manure_type = 2,
    };
    try applyOrganic(&context, 0, &event);
    // GROSUB mutates only the authoritative organic pool. HOUR1 derives the
    // signed DORGCC property change at the next fixed-hour boundary, so the
    // event cannot be double-applied here and again by material refresh.
    try std.testing.expect((try soil.charcoalCarbon_g_c(1)) > 0);
    try std.testing.expectEqual(@as(f64, 100_000), daily_organic[0]);
    try std.testing.expectEqual(@as(f64, 20.0), properties.state.cation_exchange_capacity_mol_per_megagram[1]);
    try std.testing.expectEqual(@as(f64, 2.0), properties.state.anion_exchange_capacity_mol_per_megagram[1]);
    try std.testing.expectEqual(@as(f64, 400.0), properties.state.cation_exchange_capacity_mol[1]);
    try std.testing.expectEqual(@as(f64, 40.0), properties.state.anion_exchange_capacity_mol[1]);
    try std.testing.expectEqual(@as(f64, 0.3), properties.state.field_capacity_fraction[1]);
    try std.testing.expectEqual(@as(f64, 0.1), properties.state.wilting_point_fraction[1]);
    try std.testing.expectEqual(@as(f64, 0), properties.state.charcoal_retention_increment_fraction[1]);
    try std.testing.expectEqual(@as(f64, 20.0), properties.state.cation_exchange_capacity_mol_per_megagram[0]);
    try std.testing.expectEqual(@as(f64, 2.0), properties.state.anion_exchange_capacity_mol_per_megagram[0]);
}

test "charcoal late manure failure rolls back CNP and leaves every property owner unchanged" {
    const allocator = std.testing.allocator;
    var soil = try organic.State.init(allocator, 2);
    defer soil.deinit();
    var surface = try organic.State.init(allocator, 1);
    defer surface.deinit();
    var parameters = try organic_parameters.sourceParameters(allocator);
    defer parameters.deinit();
    var properties = try TestSoilProperties.init(allocator, 2);
    defer properties.deinit();
    properties.state.matrix_bulk_volume_m3[1] = 10;
    properties.state.bulk_density_megagrams_per_m3[1] = 2;
    var daily_organic = [_]f64{0};
    var daily_biome = [_]f64{0};
    var daily_phosphorus = [_]f64{0};
    var daily_nitrogen = [_]f64{0};
    var scratch = [_]f64{ 0, 0 };
    var context = organicApplyContextForCharcoalTest(&soil, &surface, &parameters, &daily_organic, &daily_biome, &daily_phosphorus, &daily_nitrogen, &scratch, &scratch, &scratch, &scratch, &scratch, &scratch);
    var event: fertilizer_schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 0 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 0, .broadcast_ammonia = 0, .broadcast_urea = 0, .broadcast_nitrate = 0, .banded_ammonium = 0, .banded_ammonia = 0, .banded_urea = 0, .banded_nitrate = 0 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 0, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 0 },
        .calcium_carbonate_g_ca_per_m2 = 0,
        .calcium_sulfate_g_ca_per_m2 = 0,
        .plant_residue_g_per_m2 = .{ .carbon = 100, .nitrogen = 10, .phosphorus = 1 },
        .manure_g_per_m2 = .{ .carbon = -1, .nitrogen = -0.1, .phosphorus = -0.01 },
        .application_depth_m = 0.15,
        .band_row_width_m = 0,
        .fertilizer_formulation = 0,
        .plant_residue_type = 10,
        .manure_type = 2,
    };
    const microbial_before = try allocator.dupe(organic.ElementPool, soil.microbial);
    defer allocator.free(microbial_before);
    const dissolved_before = try allocator.dupe(organic.ElementPool, soil.dissolved);
    defer allocator.free(dissolved_before);
    const structural_before = try allocator.dupe(organic.ElementPool, soil.structural);
    defer allocator.free(structural_before);
    const properties_before = .{
        properties.state.field_capacity_fraction[1],
        properties.state.wilting_point_fraction[1],
        properties.state.cation_exchange_capacity_mol_per_megagram[1],
        properties.state.anion_exchange_capacity_mol_per_megagram[1],
        properties.state.cation_exchange_capacity_mol[1],
        properties.state.anion_exchange_capacity_mol[1],
        properties.state.charcoal_retention_increment_fraction[1],
        properties.state.retention_curve[1],
        properties.state.mualem_van_genuchten_parameters[1],
    };
    try std.testing.expectError(error.InvalidOrganicFertilizerInput, applyOrganic(&context, 0, &event));
    try std.testing.expectEqualSlices(organic.ElementPool, microbial_before, soil.microbial);
    try std.testing.expectEqualSlices(organic.ElementPool, dissolved_before, soil.dissolved);
    try std.testing.expectEqualSlices(organic.ElementPool, structural_before, soil.structural);
    try std.testing.expectEqual(properties_before[0], properties.state.field_capacity_fraction[1]);
    try std.testing.expectEqual(properties_before[1], properties.state.wilting_point_fraction[1]);
    try std.testing.expectEqual(properties_before[2], properties.state.cation_exchange_capacity_mol_per_megagram[1]);
    try std.testing.expectEqual(properties_before[3], properties.state.anion_exchange_capacity_mol_per_megagram[1]);
    try std.testing.expectEqual(properties_before[4], properties.state.cation_exchange_capacity_mol[1]);
    try std.testing.expectEqual(properties_before[5], properties.state.anion_exchange_capacity_mol[1]);
    try std.testing.expectEqual(properties_before[6], properties.state.charcoal_retention_increment_fraction[1]);
    try std.testing.expectEqual(properties_before[7], properties.state.retention_curve[1]);
    try std.testing.expectEqual(properties_before[8], properties.state.mualem_van_genuchten_parameters[1]);
    try std.testing.expectEqual(@as(f64, 0), daily_organic[0]);
    try std.testing.expectEqual(@as(f64, 0), daily_phosphorus[0]);
    try std.testing.expectEqual(@as(f64, 0), daily_nitrogen[0]);
}

test "DIST-022: surface-applied charcoal leaves CEC/AEC untouched" {
    const allocator = std.testing.allocator;
    var soil = try organic.State.init(allocator, 2);
    defer soil.deinit();
    var surface = try organic.State.init(allocator, 1);
    defer surface.deinit();
    var parameters = try organic_parameters.sourceParameters(allocator);
    defer parameters.deinit();
    var daily_organic = [_]f64{0};
    var daily_biome = [_]f64{0};
    var daily_phosphorus = [_]f64{0};
    var daily_nitrogen = [_]f64{0};
    var cec = [_]f64{ 20.0, 20.0 };
    var aec = [_]f64{ 2.0, 2.0 };
    var cec_mol = [_]f64{ 200.0, 400.0 };
    var aec_mol = [_]f64{ 20.0, 40.0 };
    const bulk_density_megagrams_per_m3 = [_]f64{ 1.0, 2.0 };
    const layer_volume_m3 = [_]f64{ 1.0, 10.0 };
    var context = organicApplyContextForCharcoalTest(&soil, &surface, &parameters, &daily_organic, &daily_biome, &daily_phosphorus, &daily_nitrogen, &cec, &aec, &cec_mol, &aec_mol, &bulk_density_megagrams_per_m3, &layer_volume_m3);
    const event: fertilizer_schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 0 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 0, .broadcast_ammonia = 0, .broadcast_urea = 0, .broadcast_nitrate = 0, .banded_ammonium = 0, .banded_ammonia = 0, .banded_urea = 0, .banded_nitrate = 0 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 0, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 0 },
        .calcium_carbonate_g_ca_per_m2 = 0,
        .calcium_sulfate_g_ca_per_m2 = 0,
        .plant_residue_g_per_m2 = .{ .carbon = 10_000.0, .nitrogen = 0, .phosphorus = 0 },
        .manure_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .application_depth_m = 0,
        .band_row_width_m = 0,
        .fertilizer_formulation = 0,
        .plant_residue_type = 10,
        .manure_type = 2,
    };
    try applyOrganic(&context, 0, &event);
    try std.testing.expectEqual(@as(f64, 20.0), cec[0]);
    try std.testing.expectEqual(@as(f64, 2.0), aec[0]);
    try std.testing.expectEqual(@as(f64, 20.0), cec[1]);
    try std.testing.expectEqual(@as(f64, 2.0), aec[1]);
    try std.testing.expectEqual(@as(f64, 200.0), cec_mol[0]);
    try std.testing.expectEqual(@as(f64, 20.0), aec_mol[0]);
    try std.testing.expectEqual(@as(f64, 400.0), cec_mol[1]);
    try std.testing.expectEqual(@as(f64, 40.0), aec_mol[1]);
}

test "fertilizer activity preserves exact C N P and mineral formula inputs" {
    const event: fertilizer_schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 2001 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 1, .broadcast_ammonia = 2, .broadcast_urea = 3, .broadcast_nitrate = 4, .banded_ammonium = 5, .banded_ammonia = 6, .banded_urea = 7, .banded_nitrate = 8 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 62, .banded_monocalcium_phosphate = 62, .broadcast_hydroxyapatite = 93 },
        .calcium_carbonate_g_ca_per_m2 = 80,
        .calcium_sulfate_g_ca_per_m2 = 40,
        .plant_residue_g_per_m2 = .{ .carbon = 1, .nitrogen = 2, .phosphorus = 3 },
        .manure_g_per_m2 = .{ .carbon = 4, .nitrogen = 5, .phosphorus = 6 },
        .application_depth_m = 0,
        .band_row_width_m = 0,
        .fertilizer_formulation = 0,
        .plant_residue_type = 0,
        .manure_type = 0,
    };
    const activity = try eventActivity(event, 2, 12);
    try std.testing.expectEqual(@as(f64, 58), activity.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 48), activity.mineral_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 86), activity.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 452), activity.phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 20), activity.calcium_mol);
    try std.testing.expectEqual(@as(f64, 2), activity.sulfur_mol);
    try std.testing.expectEqual(@as(f64, 0), activity.silicon_mol);

    var rock = event;
    rock.phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 0, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 0 };
    rock.calcium_carbonate_g_ca_per_m2 = 0;
    rock.calcium_sulfate_g_ca_per_m2 = 276;
    rock.plant_residue_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 };
    rock.manure_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 };
    rock.nitrogen_g_per_m2 = .{ .broadcast_ammonium = 0, .broadcast_ammonia = 0, .broadcast_urea = 0, .broadcast_nitrate = 0, .banded_ammonium = 0, .banded_ammonia = 0, .banded_urea = 0, .banded_nitrate = 0 };
    rock.fertilizer_formulation = 10;
    const rock_activity = try eventActivity(rock, 2, 12);
    try std.testing.expectEqual(@as(f64, 1), rock_activity.aluminum_mol);
    try std.testing.expectEqual(@as(f64, 1), rock_activity.iron_mol);
    try std.testing.expectEqual(@as(f64, 1), rock_activity.calcium_mol);
    try std.testing.expectEqual(@as(f64, 1), rock_activity.magnesium_mol);
    try std.testing.expectEqual(@as(f64, 1), rock_activity.sodium_mol);
    try std.testing.expectEqual(@as(f64, 1), rock_activity.potassium_mol);
    try std.testing.expectEqual(@as(f64, 3), rock_activity.silicon_mol);
}

test "fertilizer local activity mirrors independent litter and soil owner routing" {
    var event: fertilizer_schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 2001 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 1, .broadcast_ammonia = 2, .broadcast_urea = 3, .broadcast_nitrate = 4, .banded_ammonium = 0, .banded_ammonia = 0, .banded_urea = 0, .banded_nitrate = 0 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 62, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 93 },
        .calcium_carbonate_g_ca_per_m2 = 0,
        .calcium_sulfate_g_ca_per_m2 = 0,
        .plant_residue_g_per_m2 = .{ .carbon = 5, .nitrogen = 6, .phosphorus = 7 },
        .manure_g_per_m2 = .{ .carbon = 8, .nitrogen = 9, .phosphorus = 10 },
        .application_depth_m = 0,
        .band_row_width_m = 0,
        .fertilizer_formulation = 1,
        .plant_residue_type = 0,
        .manure_type = 0,
    };
    const routed = try eventRoutedActivity(event, 2, 12, 0.25, &.{ 0.1, 0.2 });
    try std.testing.expectEqual(@as(usize, 0), routed.soil_layer);
    // NH3 bypasses litter; the other broadcast N species follow litter cover.
    try std.testing.expectEqual(@as(f64, 16), routed.soil.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 4), routed.surface.nitrogen_g_n - 6 * 2 - 9 * 2);
    // Organic material independently follows the zero-depth surface rule.
    try std.testing.expectEqual(@as(f64, 26), routed.surface.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), routed.soil.carbon_g_c);
    const total = try eventActivity(event, 2, 12);
    inline for (std.meta.fields(FertilizerActivity)) |field| {
        try std.testing.expectApproxEqAbs(
            @field(total, field.name),
            @field(routed.surface, field.name) + @field(routed.soil, field.name),
            32 * std.math.floatEps(f64) * @max(@field(total, field.name), 1),
        );
    }

    // A carbonate co-application forces all mineral fertilizer into soil,
    // while zero-depth residue/manure remain in the surface organic owner.
    event.calcium_carbonate_g_ca_per_m2 = 40;
    const forced_soil = try eventRoutedActivity(event, 2, 12, 0.25, &.{ 0.1, 0.2 });
    try std.testing.expectEqual(@as(f64, 0), forced_soil.surface.calcium_mol);
    try std.testing.expectEqual(@as(f64, 26), forced_soil.surface.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 24), forced_soil.soil.carbon_g_c);

    // At depth all three owners resolve to the same local soil layer.
    event.application_depth_m = 0.15;
    const deep = try eventRoutedActivity(event, 2, 12, 0.25, &.{ 0.1, 0.2 });
    try std.testing.expectEqual(@as(usize, 1), deep.soil_layer);
    try std.testing.expectEqualDeep(FertilizerActivity{}, deep.surface);
}

test "fertilizer local sidecar reconstructs only the accepted cell hour and resets" {
    const allocator = std.testing.allocator;
    var assignments = try land_management.fromUnits(allocator, &.{.{
        .fertilizer_file = "annual",
        .irrigation_file = "NO",
        .tillage_file = "NO",
    }});
    defer assignments.deinit();
    const unit_by_cell = try assignments.buildCellUnitMap(allocator);
    defer allocator.free(unit_by_cell);
    var catalog = fertilizer_schedule.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource(
        "annual",
        "01050000 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n",
    );
    var map = try ScheduleMap.init(allocator, assignments, unit_by_cell, catalog);
    defer map.deinit();
    var surface_organic = try organic.State.init(allocator, 1);
    defer surface_organic.deinit();
    var activity = try LocalActivityState.init(allocator, 1, 2);
    defer activity.deinit();

    try activity.reconstructAcceptedHour(
        map,
        catalog,
        .{ .day = 1, .month = 5, .year = 2026 },
        12,
        &.{12},
        &.{2},
        12,
        &.{2},
        &.{ 0.1, 0.2 },
        &surface_organic,
    );
    try std.testing.expectEqual(@as(f64, 0), activity.surface_by_cell[0].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 2), activity.soil_by_layer[0].nitrogen_g_n);
    try std.testing.expectEqualDeep(FertilizerActivity{}, activity.soil_by_layer[1]);

    try activity.reconstructAcceptedHour(
        map,
        catalog,
        .{ .day = 1, .month = 5, .year = 2026 },
        11,
        &.{12},
        &.{2},
        12,
        &.{2},
        &.{ 0.1, 0.2 },
        &surface_organic,
    );
    try std.testing.expectEqualDeep(FertilizerActivity{}, activity.surface_by_cell[0]);
    try std.testing.expectEqualDeep(FertilizerActivity{}, activity.soil_by_layer[0]);
}

test "late fertilizer dispatch failure leaves preflighted hourly cell ledger empty" {
    const hourly = @import("../validation/hourly_cell_conservation.zig");
    var ledger = try hourly.BoundaryLedger.init(std.testing.allocator, 1);
    defer ledger.deinit();
    var event: fertilizer_schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 2001 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 0, .broadcast_ammonia = 0, .broadcast_urea = 0, .broadcast_nitrate = 0, .banded_ammonium = 0, .banded_ammonia = 0, .banded_urea = 0, .banded_nitrate = 0 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 0, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 0 },
        .calcium_carbonate_g_ca_per_m2 = 0,
        .calcium_sulfate_g_ca_per_m2 = 0,
        .plant_residue_g_per_m2 = .{ .carbon = 10, .nitrogen = 1, .phosphorus = 0.1 },
        .manure_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .application_depth_m = 0.15,
        .band_row_width_m = 0,
        .fertilizer_formulation = 0,
        .plant_residue_type = 10,
        .manure_type = 0,
    };
    const activity = try eventActivity(event, 1, 12);
    try ledger.preflight(0, .{
        .carbon_input_g = activity.carbon_g_c,
        .nitrogen_input_g = activity.nitrogen_g_n,
        .phosphorus_input_g = activity.phosphorus_g_p,
    });
    event.manure_g_per_m2.carbon = -1;

    var soil = try organic.State.init(std.testing.allocator, 2);
    defer soil.deinit();
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var parameters = try organic_parameters.sourceParameters(std.testing.allocator);
    defer parameters.deinit();
    var daily_organic = [_]f64{0};
    var daily_biome = [_]f64{0};
    var daily_phosphorus = [_]f64{0};
    var daily_nitrogen = [_]f64{0};
    var scratch = [_]f64{ 0, 0 };
    var context = organicApplyContextForCharcoalTest(
        &soil,
        &surface,
        &parameters,
        &daily_organic,
        &daily_biome,
        &daily_phosphorus,
        &daily_nitrogen,
        &scratch,
        &scratch,
        &scratch,
        &scratch,
        &scratch,
        &scratch,
    );
    try std.testing.expectError(error.InvalidOrganicFertilizerInput, applyOrganic(&context, 0, &event));
    try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, ledger.cells[0]);
}
