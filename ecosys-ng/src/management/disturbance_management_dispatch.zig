const std = @import("std");
const delimited_input = @import("../io/input/delimited_input.zig");
const disturbance = @import("disturbance_schedule.zig");
const land_management = @import("land_management.zig");
const Date = @import("../core/options.zig").Date;
const RootSystem = @import("../plant/root/plant_root_system.zig");
const RootDisturbance = @import("../plant/root/plant_root_disturbance.zig");
const RootLitterfall = @import("../plant/root/plant_root_litterfall.zig");
const RootLitterLedger = @import("../plant/root/plant_root_litter_budget.zig");
const RootMetabolism = @import("../plant/root/plant_root_metabolism.zig");
const LitterPartition = @import("../plant/partition/litter.zig");
const SoilOrganic = @import("../soil/organic/initialization.zig");
const Grid = @import("../state/grid.zig").GridState;
const SurfaceEnergy = @import("../surface/energy.zig").State;
const Canopy = @import("../canopy/photosynthesis/photosynthesis.zig");
const OrganicMatterFireExchange = @import("../soil/biogeochemistry/organic_matter_fire_exchange.zig");
const PlantHarvest = @import("plant_harvest_runtime.zig");
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");
const BoundaryTopology = @import("../soil/profile/boundary_topology.zig");
const TerrainHydrology = @import("../state/terrain_hydrology.zig");
const SoilGeometry = @import("../soil/profile/layer_geometry.zig");
const PlantAssignment = @import("../state/plant_assignment.zig");
const TillageRuntime = @import("../redistribution/tillage/runtime_adapter.zig");
const SurfaceLitterRemoval = @import("../surface/litter_removal.zig");
const SurfaceLitterGeometry = @import("../surface/litter_geometry_step.zig");

/// WTHR 50, 548--561 temperature thresholds for ICHKF. The source uses the
/// warmer threshold for TKS(0..NU) and TKQ, and the lower threshold for soil
/// layers strictly below NU.
pub const wthr_surface_fire_temperature_k: f64 = 373.15;
pub const wthr_subsurface_fire_temperature_k: f64 = 348.15;

pub const WthrFireTemperatureState = struct {
    surface_temperature_k: []const f64,
    soil_temperature_k: []const f64,
    canopy_bulk_air_temperature_k: []const f64,
    first_active_soil_layer_by_cell: []const usize,
    active_soil_layer_count_by_cell: []const usize,
    soil_layer_capacity: usize,
};

/// Reconstructs WTHR's temperature half of ICHKF from the accepted start-hour
/// TKS/TKQ owners. Existing true flags are retained so the scheduled ITILL=22
/// fire transaction and temperature detection form the source `OR`, regardless
/// of which producer ran first.
pub fn mergeWthrTemperatureFireFlags(
    fire_active_this_hour: []bool,
    temperatures: WthrFireTemperatureState,
) !void {
    const cell_count = fire_active_this_hour.len;
    const expected_layer_count = std.math.mul(
        usize,
        cell_count,
        temperatures.soil_layer_capacity,
    ) catch return error.WthrFireTemperatureDimensionMismatch;
    if (cell_count == 0 or temperatures.soil_layer_capacity == 0 or
        temperatures.surface_temperature_k.len != cell_count or
        temperatures.canopy_bulk_air_temperature_k.len != cell_count or
        temperatures.first_active_soil_layer_by_cell.len != cell_count or
        temperatures.active_soil_layer_count_by_cell.len != cell_count or
        temperatures.soil_temperature_k.len != expected_layer_count)
        return error.WthrFireTemperatureDimensionMismatch;

    // Complete validation before publication so a malformed topology or
    // temperature cannot leave a partially updated flag array.
    for (0..cell_count) |cell| {
        const first = temperatures.first_active_soil_layer_by_cell[cell];
        const active = temperatures.active_soil_layer_count_by_cell[cell];
        if (active == 0 or first >= temperatures.soil_layer_capacity or
            active > temperatures.soil_layer_capacity - first)
            return error.InvalidWthrFireLayerTopology;
        inline for (.{
            temperatures.surface_temperature_k[cell],
            temperatures.canopy_bulk_air_temperature_k[cell],
        }) |temperature_k| if (!std.math.isFinite(temperature_k) or temperature_k <= 0)
            return error.InvalidWthrFireTemperature;
        const layer_base = cell * temperatures.soil_layer_capacity;
        for (0..first + active) |layer| {
            const temperature_k = temperatures.soil_temperature_k[layer_base + layer];
            if (!std.math.isFinite(temperature_k) or temperature_k <= 0)
                return error.InvalidWthrFireTemperature;
        }
    }

    for (0..cell_count) |cell| {
        const first = temperatures.first_active_soil_layer_by_cell[cell];
        const active = temperatures.active_soil_layer_count_by_cell[cell];
        var temperature_fire =
            temperatures.surface_temperature_k[cell] > wthr_surface_fire_temperature_k or
            temperatures.canopy_bulk_air_temperature_k[cell] > wthr_surface_fire_temperature_k;
        const layer_base = cell * temperatures.soil_layer_capacity;
        for (0..first + active) |layer| {
            const threshold_k = if (layer <= first)
                wthr_surface_fire_temperature_k
            else
                wthr_subsurface_fire_temperature_k;
            temperature_fire = temperature_fire or
                temperatures.soil_temperature_k[layer_base + layer] > threshold_k;
        }
        fire_active_this_hour[cell] = fire_active_this_hour[cell] or temperature_fire;
    }
}

test "WTHR cold state stays inactive and scheduled fire remains active" {
    var flags = [_]bool{ false, true };
    try mergeWthrTemperatureFireFlags(&flags, .{
        .surface_temperature_k = &.{ 300, 300 },
        .soil_temperature_k = &.{ 300, 300, 300, 300 },
        .canopy_bulk_air_temperature_k = &.{ 300, 300 },
        .first_active_soil_layer_by_cell = &.{ 0, 0 },
        .active_soil_layer_count_by_cell = &.{ 2, 2 },
        .soil_layer_capacity = 2,
    });
    try std.testing.expectEqualSlices(bool, &.{ false, true }, &flags);
}

test "WTHR hot topsoil and deeper soil use their distinct strict thresholds" {
    var flags = [_]bool{ false, false };
    try mergeWthrTemperatureFireFlags(&flags, .{
        .surface_temperature_k = &.{ 300, 300 },
        .soil_temperature_k = &.{ 373.1501, 300, 373.15, 348.1501 },
        .canopy_bulk_air_temperature_k = &.{ 300, 300 },
        .first_active_soil_layer_by_cell = &.{ 0, 0 },
        .active_soil_layer_count_by_cell = &.{ 2, 2 },
        .soil_layer_capacity = 2,
    });
    try std.testing.expectEqualSlices(bool, &.{ true, true }, &flags);

    flags = .{ false, false };
    try mergeWthrTemperatureFireFlags(&flags, .{
        .surface_temperature_k = &.{ 300, 300 },
        .soil_temperature_k = &.{ 373.15, 348.15, 373.15, 348.15 },
        .canopy_bulk_air_temperature_k = &.{ 300, 300 },
        .first_active_soil_layer_by_cell = &.{ 0, 0 },
        .active_soil_layer_count_by_cell = &.{ 2, 2 },
        .soil_layer_capacity = 2,
    });
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &flags);
}

test "WTHR hot surface or prior accepted TKQ activates fire" {
    var flags = [_]bool{ false, false };
    try mergeWthrTemperatureFireFlags(&flags, .{
        .surface_temperature_k = &.{ 373.1501, 300 },
        .soil_temperature_k = &.{ 300, 300 },
        .canopy_bulk_air_temperature_k = &.{ 300, 373.1501 },
        .first_active_soil_layer_by_cell = &.{ 0, 0 },
        .active_soil_layer_count_by_cell = &.{ 1, 1 },
        .soil_layer_capacity = 1,
    });
    try std.testing.expectEqualSlices(bool, &.{ true, true }, &flags);
}

test "WTHR NU and NL topology applies upper threshold through NU and ignores below NL" {
    var flags = [_]bool{false};
    var soil = [_]f64{ 360, 360, 373.15, 348.1501, 900 };
    try mergeWthrTemperatureFireFlags(&flags, .{
        .surface_temperature_k = &.{300},
        .soil_temperature_k = &soil,
        .canopy_bulk_air_temperature_k = &.{300},
        .first_active_soil_layer_by_cell = &.{2},
        .active_soil_layer_count_by_cell = &.{2},
        .soil_layer_capacity = soil.len,
    });
    try std.testing.expect(flags[0]);

    flags[0] = false;
    soil[3] = 348.15;
    try mergeWthrTemperatureFireFlags(&flags, .{
        .surface_temperature_k = &.{300},
        .soil_temperature_k = &soil,
        .canopy_bulk_air_temperature_k = &.{300},
        .first_active_soil_layer_by_cell = &.{2},
        .active_soil_layer_count_by_cell = &.{2},
        .soil_layer_capacity = soil.len,
    });
    try std.testing.expect(!flags[0]);
}

test "production derives WTHR fire before scheduled OR and hourly science" {
    const source = @embedFile("../ecosys_ng.zig");
    const temperature_flag = std.mem.indexOf(
        u8,
        source,
        "mergeWthrTemperatureFireFlags(",
    ) orelse return error.MissingWthrTemperatureFireBinding;
    const scheduled_fire = std.mem.indexOfPos(
        u8,
        source,
        temperature_flag,
        "dispatchDatePhase(",
    ) orelse return error.MissingPreScienceFireDispatch;
    const hourly_science = std.mem.indexOfPos(
        u8,
        source,
        scheduled_fire,
        "executeHourlyScience(",
    ) orelse return error.MissingHourlyScienceCall;
    try std.testing.expect(temperature_flag < scheduled_fire);
    try std.testing.expect(scheduled_fire < hourly_science);
}

/// Production owners needed by REDIST operation 21.  The science transaction
/// remains in `surface/litter_removal.zig`; this wrapper selects the event cell
/// and binds it to the normal hourly export and cumulative heat ledgers.
pub const SurfaceLitterRemovalContext = struct {
    runtime: SurfaceLitterRemoval.RuntimeContext,
    carbon_export_g_c_per_h_by_cell: []f64,
    nitrogen_export_g_n_per_h_by_cell: []f64,
    phosphorus_export_g_p_per_h_by_cell: []f64,
    cumulative_heat_output_megajoules: *f64,
};

pub const ScheduleMap = struct {
    allocator: std.mem.Allocator,
    catalog_index_by_cell: []?usize,

    pub fn init(allocator: std.mem.Allocator, assignments: land_management.Assignments, unit_by_cell: []const usize, catalog: disturbance.Catalog) !ScheduleMap {
        const map = try allocator.alloc(?usize, unit_by_cell.len);
        errdefer allocator.free(map);
        for (unit_by_cell, 0..) |unit_index, cell| {
            if (unit_index >= assignments.units.len) return error.LandManagementUnitIndexOutOfBounds;
            const name = assignments.units[unit_index].tillage_file;
            map[cell] = if (delimited_input.isNo(name)) null else catalog.find(name) orelse return error.DisturbanceScheduleMissingFromCatalog;
        }
        return .{ .allocator = allocator, .catalog_index_by_cell = map };
    }

    pub fn deinit(self: *ScheduleMap) void {
        self.allocator.free(self.catalog_index_by_cell);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    roots: *RootSystem.State,
    litter_partition: *const LitterPartition.State,
    soil_organic: *SoilOrganic.State,
    grid: *const Grid,
    species_count: usize,
    /// Capacity is the array stride, not the number of assigned PFTs (GROSUB
    /// NP). Dormant/dead assigned plants still own tillage-relevant material.
    plant_assignments: *const PlantAssignment.Assignments,
    plant_unit_by_cell: []const usize,
    biological_domain_count_by_plant: []const u8,
    root_nonwoody_fraction_by_plant: []const f64,
    biomass_turnover_type_by_plant: []const u8,
    root_profile_type_by_plant: []const u8,
    growth_habit_by_plant: []const u8,
    leaf_phenology_type_by_plant: []const u8,
    planting_day_of_year_by_plant: []const u16,
    planting_year_by_plant: []const i32,
    current_day_of_year: u16,
    current_year: i32,
    /// Source HOUR1/GROSUB management clock. Disturbance events execute at
    /// each cell's assigned weather-grid solar noon, not stream zero's noon.
    source_hour_one_through_twenty_four: u8,
    solar_noon_hour_by_cell: []const u8,
    soil_boundary_topology: *BoundaryTopology.State,
    terrain_hydrology: *const TerrainHydrology.State,
    soil_geometry: *const SoilGeometry.State,
    plant_harvest: ?*PlantHarvest.Context,
    /// Required because late dynamic-salt transfer consumes the tillage-killed
    /// root carbon published here; a nullable ledger silently loses that path.
    root_litter_carbon_ledger: *RootLitterLedger.State,
    surface_energy: *SurfaceEnergy,
    fire_active_this_hour: []bool,
    /// Complete REDIST tillage owner map. Kept in the disturbance context so
    /// the per-cell, solar-noon event gate owns the entire transaction.
    tillage_runtime: TillageRuntime.Context,
    /// Production defers only the destructive soil REDIST half until the
    /// late GROSUB plant-salt return has reached chemistry and transport.
    /// The enclosing fixed-hour transaction owns rollback across the gap.
    deferred_tillage_soil_by_cell: ?[]DeferredTillage = null,
    /// Operation 21 is post-science. A missing binding is an explicit error,
    /// never a silently counted no-op.
    surface_litter_removal: ?*SurfaceLitterRemovalContext = null,
    /// Count of plants whose ABOVEGROUND tillage branch actually executed,
    /// accumulated by `applyEvent` and read by the serial caller.
    ///
    /// `dispatchDatePhase` already returns an applied-event count, but that
    /// counts every operation kind -- fire, surface-litter removal, tillage --
    /// so it cannot answer "did aboveground tillage run". `applyEvent` returns
    /// `!void`, so the alternative was a signature change through the dispatch
    /// chain; a producer-owned counter here is additive and needs no caller to
    /// change shape. Never reset by this module: the owner resets it, exactly
    /// as `fire_active_this_hour` is owned and reset by the caller.
    aboveground_tillage_plant_count: usize = 0,
};

pub const DeferredTillage = struct {
    pending: bool = false,
    depth_m: f64 = 0,
    mixing_fraction: f64 = 0,
};

fn stageDeferredTillage(pending: []DeferredTillage, cell: usize, depth_m: f64, mixing_fraction: f64) !void {
    if (cell >= pending.len) return error.DeferredTillageDimensionMismatch;
    if (pending[cell].pending) return error.MultipleTillageEventsPerCellDay;
    pending[cell] = .{ .pending = true, .depth_m = depth_m, .mixing_fraction = mixing_fraction };
}

/// Completes the soil half after late plant-litter salt ingress. Each cell
/// adapter remains attempt-atomic; production wraps the cross-cell sequence
/// in the fixed external-hour transaction.
pub fn applyDeferredTillageSoil(runtime: *TillageRuntime.Context, pending: []DeferredTillage) !usize {
    if (pending.len != runtime.grid.cell_count) return error.DeferredTillageDimensionMismatch;
    try runtime.local_activity.beginAttempt();
    errdefer runtime.local_activity.abortAttempt();
    var applied: usize = 0;
    for (pending, 0..) |request, cell| {
        if (!request.pending) continue;
        try TillageRuntime.apply(runtime, cell, request.depth_m, request.mixing_fraction);
        applied += 1;
    }
    try runtime.local_activity.commitAttempt();
    for (pending) |*request| request.* = .{};
    return applied;
}

test "deferred tillage rejects ambiguous duplicate cell events" {
    var pending = [_]DeferredTillage{.{}};
    try stageDeferredTillage(&pending, 0, 0.2, 0.5);
    try std.testing.expectError(error.MultipleTillageEventsPerCellDay, stageDeferredTillage(&pending, 0, 0.1, 0.25));
    try std.testing.expect(pending[0].pending);
    try std.testing.expectEqual(@as(f64, 0.2), pending[0].depth_m);
    try std.testing.expectEqual(@as(f64, 0.5), pending[0].mixing_fraction);
}

const RollbackEntry = struct {
    destination: []u8,
    before: []u8,
};

const ScaledRollbackField = struct {
    bytes: []u8,
    element_count: usize,
};

fn mutableSliceFieldCount(comptime State: type) usize {
    var result: usize = 0;
    for (@typeInfo(State).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .pointer => |pointer| if (pointer.size == .slice and !pointer.is_const) {
            result += 1;
        },
        else => {},
    };
    return result;
}

/// Reflection is restricted to loading slice descriptors in declaration order.
/// Range validation, allocation, and error propagation are emitted once in
/// `captureScaledFieldTable`, rather than once for every field of every owner.
noinline fn scaledRollbackFields(state: anytype) [mutableSliceFieldCount(@TypeOf(state.*))]ScaledRollbackField {
    var result: [mutableSliceFieldCount(@TypeOf(state.*))]ScaledRollbackField = undefined;
    comptime var index: usize = 0;
    inline for (@typeInfo(@TypeOf(state.*)).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .pointer => |pointer| if (pointer.size == .slice and !pointer.is_const) {
            const values = @field(state.*, field.name);
            result[index] = .{
                .bytes = std.mem.sliceAsBytes(values),
                .element_count = values.len,
            };
            index += 1;
        },
        else => {},
    };
    return result;
}

/// Cell-local undo log for the plant/litter half of a tillage event. Immediate
/// callers run the atomic soil adapter last. Production stages the soil half
/// for late GROSUB and relies on its enclosing fixed-hour transaction across
/// that deliberate source-order gap.
const EventRollback = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(RollbackEntry) = .empty,

    fn init(allocator: std.mem.Allocator) EventRollback {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *EventRollback) void {
        for (self.entries.items) |entry| self.allocator.free(entry.before);
        self.entries.deinit(self.allocator);
    }

    fn restore(self: EventRollback) void {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.entries.items[index];
            @memcpy(entry.destination, entry.before);
        }
    }

    fn capture(self: *EventRollback, values: anytype, first: usize, end: usize) !void {
        const info = @typeInfo(@TypeOf(values)).pointer;
        comptime std.debug.assert(info.size == .slice and !info.is_const);
        if (first > end or end > values.len) return error.TillageRollbackRangeOutOfBounds;
        const destination = std.mem.sliceAsBytes(values[first..end]);
        const before = try self.allocator.dupe(u8, destination);
        errdefer self.allocator.free(before);
        try self.entries.append(self.allocator, .{ .destination = destination, .before = before });
    }

    noinline fn captureScaledFieldTable(self: *EventRollback, fields: []const ScaledRollbackField, total: usize, first: usize, end: usize) !void {
        if (total == 0 or first > end or end > total) return error.TillageRollbackRangeOutOfBounds;
        for (fields) |field| {
            if (field.element_count == 0) continue;
            if (field.element_count % total != 0) return error.TillageRollbackOwnerDimensionMismatch;
            const byte_stride = field.bytes.len / total;
            try self.capture(field.bytes, first * byte_stride, end * byte_stride);
        }
    }

    noinline fn captureScaledFields(self: *EventRollback, state: anytype, total: usize, first: usize, end: usize) !void {
        const fields = scaledRollbackFields(state);
        try self.captureScaledFieldTable(&fields, total, first, end);
    }
};

test "tillage event undo log restores late-failure writes exactly" {
    var values = [_]u32{ 1, 2, 3, 4 };
    const value_slice: []u32 = &values;
    var rollback = EventRollback.init(std.testing.allocator);
    defer rollback.deinit();
    try rollback.capture(value_slice, 1, 3);
    values[1] = 20;
    values[2] = 30;
    rollback.restore();
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, &values);
}

const ScaledRollbackTestState = struct {
    ignored_scalar: usize,
    first: []u16,
    empty: []f64,
    ignored_const: []const u8,
    second: []bool,
    third: []u32,
};

fn testScaledRollbackAllocationFailure(allocator: std.mem.Allocator) !void {
    var first = [_]u16{ 1, 2, 3, 4, 5, 6 };
    var second = [_]bool{ false, true, false };
    var third = [_]u32{ 10, 20, 30, 40, 50, 60, 70, 80, 90 };
    var state: ScaledRollbackTestState = .{
        .ignored_scalar = 3,
        .first = &first,
        .empty = &.{},
        .ignored_const = "not owned",
        .second = &second,
        .third = &third,
    };
    var rollback = EventRollback.init(allocator);
    defer rollback.deinit();
    try rollback.captureScaledFields(&state, 3, 1, 2);
}

test "scaled rollback releases every partially captured field on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testScaledRollbackAllocationFailure,
        .{},
    );
}

test "scaled rollback preserves field order byte width and neighboring domains" {
    var first = [_]u16{ 1, 2, 3, 4, 5, 6 };
    var second = [_]bool{ false, true, false };
    var third = [_]u32{ 10, 20, 30, 40, 50, 60, 70, 80, 90 };
    var state: ScaledRollbackTestState = .{
        .ignored_scalar = 3,
        .first = &first,
        .empty = &.{},
        .ignored_const = "not owned",
        .second = &second,
        .third = &third,
    };
    var rollback = EventRollback.init(std.testing.allocator);
    defer rollback.deinit();
    try rollback.captureScaledFields(&state, 3, 1, 2);

    try std.testing.expectEqual(@as(usize, 3), rollback.entries.items.len);
    try std.testing.expect(rollback.entries.items[0].destination.ptr == std.mem.sliceAsBytes(first[2..4]).ptr);
    try std.testing.expectEqual(std.mem.sliceAsBytes(first[2..4]).len, rollback.entries.items[0].destination.len);
    try std.testing.expect(rollback.entries.items[1].destination.ptr == std.mem.sliceAsBytes(second[1..2]).ptr);
    try std.testing.expectEqual(std.mem.sliceAsBytes(second[1..2]).len, rollback.entries.items[1].destination.len);
    try std.testing.expect(rollback.entries.items[2].destination.ptr == std.mem.sliceAsBytes(third[3..6]).ptr);
    try std.testing.expectEqual(std.mem.sliceAsBytes(third[3..6]).len, rollback.entries.items[2].destination.len);

    @memset(&first, 100);
    @memset(&second, false);
    @memset(&third, 1000);
    rollback.restore();
    try std.testing.expectEqualSlices(u16, &.{ 100, 100, 3, 4, 100, 100 }, &first);
    try std.testing.expectEqualSlices(bool, &.{ false, true, false }, &second);
    try std.testing.expectEqualSlices(u32, &.{ 1000, 1000, 1000, 40, 50, 60, 1000, 1000, 1000 }, &third);
}

test "scaled rollback retains earlier captures when a later owner is malformed" {
    const MalformedState = struct {
        valid: []u16,
        invalid: []u32,
    };
    var valid = [_]u16{ 1, 2, 3 };
    var invalid = [_]u32{ 4, 5 };
    var state: MalformedState = .{ .valid = &valid, .invalid = &invalid };
    var rollback = EventRollback.init(std.testing.allocator);
    defer rollback.deinit();
    try std.testing.expectError(
        error.TillageRollbackOwnerDimensionMismatch,
        rollback.captureScaledFields(&state, 3, 1, 2),
    );
    try std.testing.expectEqual(@as(usize, 1), rollback.entries.items.len);
    valid[1] = 20;
    rollback.restore();
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, &valid);
}

test "post-science tillage requires the dynamic-salt root litter ledger" {
    try std.testing.expect(@FieldType(ApplyContext, "root_litter_carbon_ledger") == *RootLitterLedger.State);
}

const DomainRange = struct { total: usize, first: usize, end: usize };

const CanopyRollbackDomain = enum { plant, branch, node, sample };

const canopy_rollback_float_field_count = count: {
    var result: usize = 0;
    for (@typeInfo(Canopy.State).@"struct".fields) |field| if (field.type == []f64) {
        result += 1;
    };
    break :count result;
};

const CanopyRollbackFloatFieldPointers = [canopy_rollback_float_field_count]*[]f64;

const canopy_rollback_domains: [canopy_rollback_float_field_count]CanopyRollbackDomain = domains: {
    @setEvalBranchQuota(10_000);
    var result: [canopy_rollback_float_field_count]CanopyRollbackDomain = undefined;
    var index: usize = 0;
    for (@typeInfo(Canopy.State).@"struct".fields) |field| if (field.type == []f64) {
        result[index] = canopyRollbackDomain(field.name);
        index += 1;
    };
    break :domains result;
};

fn canopyRollbackDomain(comptime field_name: []const u8) CanopyRollbackDomain {
    if (std.mem.startsWith(u8, field_name, "plant_")) return .plant;
    if (std.mem.startsWith(u8, field_name, "branch_")) return .branch;
    if (std.mem.startsWith(u8, field_name, "node_")) return .node;
    if (std.mem.startsWith(u8, field_name, "sample_")) return .sample;
    @compileError("unmapped canopy tillage rollback owner: " ++ field_name);
}

/// Reflection is limited to loading field addresses. The allocation/error path
/// below is emitted once and runs over this table in declaration order instead
/// of being cloned into machine code for every canopy field.
noinline fn canopyRollbackFloatFieldPointers(state: *Canopy.State) CanopyRollbackFloatFieldPointers {
    var result: CanopyRollbackFloatFieldPointers = undefined;
    comptime var index: usize = 0;
    inline for (@typeInfo(Canopy.State).@"struct".fields) |field| if (field.type == []f64) {
        result[index] = &@field(state, field.name);
        index += 1;
    };
    return result;
}

noinline fn captureCanopyState(rollback: *EventRollback, state: *Canopy.State, plant: DomainRange, branch: DomainRange, node: DomainRange, sample: DomainRange) !void {
    var fields = canopyRollbackFloatFieldPointers(state);
    for (&fields, canopy_rollback_domains) |field, domain| {
        const range = switch (domain) {
            .plant => plant,
            .branch => branch,
            .node => node,
            .sample => sample,
        };
        const values = field.*;
        if (values.len % range.total != 0) return error.TillageRollbackOwnerDimensionMismatch;
        const stride = values.len / range.total;
        try rollback.capture(values, range.first * stride, range.end * stride);
    }
}

const canopy_rollback_test_branch_counts = [_]usize{ 2, 1, 1, 1 };
const canopy_rollback_test_node_counts = [_]usize{ 2, 1, 1, 1, 1 };
const canopy_rollback_test_sample_counts = [_]usize{ 1, 2, 1, 3, 2, 1 };
const canopy_rollback_test_ranges = struct {
    const plant: DomainRange = .{ .total = 4, .first = 1, .end = 3 };
    const branch: DomainRange = .{ .total = 5, .first = 1, .end = 4 };
    const node: DomainRange = .{ .total = 6, .first = 1, .end = 5 };
    const sample: DomainRange = .{ .total = 10, .first = 2, .end = 7 };
};

fn testCanopyRollbackAllocationFailure(allocator: std.mem.Allocator) !void {
    var state = try Canopy.State.init(
        std.testing.allocator,
        2,
        2,
        &canopy_rollback_test_branch_counts,
        &canopy_rollback_test_node_counts,
        &canopy_rollback_test_sample_counts,
    );
    defer state.deinit();
    var rollback = EventRollback.init(allocator);
    defer rollback.deinit();
    try captureCanopyState(
        &rollback,
        &state,
        canopy_rollback_test_ranges.plant,
        canopy_rollback_test_ranges.branch,
        canopy_rollback_test_ranges.node,
        canopy_rollback_test_ranges.sample,
    );
}

test "canopy rollback releases every partially captured field on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testCanopyRollbackAllocationFailure,
        .{},
    );
}

test "canopy rollback captures every field in declaration order and preserves neighbors" {
    var state = try Canopy.State.init(
        std.testing.allocator,
        2,
        2,
        &canopy_rollback_test_branch_counts,
        &canopy_rollback_test_node_counts,
        &canopy_rollback_test_sample_counts,
    );
    defer state.deinit();
    var fields = canopyRollbackFloatFieldPointers(&state);
    for (&fields, 0..) |field, field_index| {
        for (field.*, 0..) |*value, value_index|
            value.* = @floatFromInt(field_index * 10_000 + value_index + 1);
    }

    var rollback = EventRollback.init(std.testing.allocator);
    defer rollback.deinit();
    try captureCanopyState(
        &rollback,
        &state,
        canopy_rollback_test_ranges.plant,
        canopy_rollback_test_ranges.branch,
        canopy_rollback_test_ranges.node,
        canopy_rollback_test_ranges.sample,
    );
    try std.testing.expectEqual(canopy_rollback_float_field_count, rollback.entries.items.len);

    for (&fields, canopy_rollback_domains, 0..) |field, domain, field_index| {
        const range = switch (domain) {
            .plant => canopy_rollback_test_ranges.plant,
            .branch => canopy_rollback_test_ranges.branch,
            .node => canopy_rollback_test_ranges.node,
            .sample => canopy_rollback_test_ranges.sample,
        };
        const stride = field.*.len / range.total;
        const first = range.first * stride;
        const end = range.end * stride;
        const captured_bytes = std.mem.sliceAsBytes(field.*[first..end]);
        try std.testing.expect(rollback.entries.items[field_index].destination.ptr == captured_bytes.ptr);
        try std.testing.expectEqual(captured_bytes.len, rollback.entries.items[field_index].destination.len);
        for (field.*, 0..) |*value, value_index|
            value.* = -@as(f64, @floatFromInt(field_index * 10_000 + value_index + 1));
    }

    rollback.restore();
    for (&fields, canopy_rollback_domains, 0..) |field, domain, field_index| {
        const range = switch (domain) {
            .plant => canopy_rollback_test_ranges.plant,
            .branch => canopy_rollback_test_ranges.branch,
            .node => canopy_rollback_test_ranges.node,
            .sample => canopy_rollback_test_ranges.sample,
        };
        const stride = field.*.len / range.total;
        const first = range.first * stride;
        const end = range.end * stride;
        for (field.*, 0..) |value, value_index| {
            const original: f64 = @floatFromInt(field_index * 10_000 + value_index + 1);
            try std.testing.expectEqual(if (value_index >= first and value_index < end) original else -original, value);
        }
    }
}

fn captureCanopyLayers(rollback: *EventRollback, state: anytype, cell: DomainRange, plant: DomainRange, branch: DomainRange, node: DomainRange) !void {
    @setEvalBranchQuota(10_000);
    inline for (@typeInfo(@TypeOf(state.*)).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .pointer => |pointer| if (pointer.size == .slice and !pointer.is_const and (pointer.child == f64 or pointer.child == ?usize)) {
            const maybe_range: ?DomainRange = if (comptime std.mem.startsWith(u8, field.name, "cell_"))
                cell
            else if (comptime std.mem.startsWith(u8, field.name, "plant_") or std.mem.endsWith(u8, field.name, "_by_plant"))
                plant
            else if (comptime std.mem.startsWith(u8, field.name, "branch_"))
                branch
            else if (comptime std.mem.startsWith(u8, field.name, "node_"))
                node
            else
                null;
            if (maybe_range) |range| {
                const values = @field(state.*, field.name);
                if (values.len % range.total != 0) return error.TillageRollbackOwnerDimensionMismatch;
                const stride = values.len / range.total;
                try rollback.capture(values, range.first * stride, range.end * stride);
            }
        },
        else => {},
    };
}

fn captureTillagePlantOwners(context: *ApplyContext, cell: usize, rollback: *EventRollback) !void {
    const plant_first = cell * context.species_count;
    const plant_end = plant_first + context.species_count;
    const plant_count = context.roots.plant_count;
    const canopy_state = if (context.plant_harvest) |harvest| harvest.canopy_state else null;

    try rollback.captureScaledFields(context.roots, plant_count, plant_first, plant_end);
    const layer_first = cell * context.grid.soil_layer_capacity;
    try rollback.captureScaledFields(context.soil_organic, context.soil_organic.layer_count, layer_first, layer_first + context.grid.soil_layer_capacity);
    try rollback.captureScaledFields(context.root_litter_carbon_ledger, context.root_litter_carbon_ledger.plant_count, plant_first, plant_end);

    const harvest = context.plant_harvest orelse return;
    try rollback.capture(harvest.products_by_plant, plant_first, plant_end);
    const branch_first = canopy_state.?.plant_branch_offsets[plant_first];
    const branch_end = canopy_state.?.plant_branch_offsets[plant_end];
    const branch_total = canopy_state.?.branch_node_offsets.len - 1;
    const node_first = canopy_state.?.branch_node_offsets[branch_first];
    const node_end = canopy_state.?.branch_node_offsets[branch_end];
    const node_total = canopy_state.?.node_sample_offsets.len - 1;
    const sample_first = canopy_state.?.node_sample_offsets[node_first];
    const sample_end = canopy_state.?.node_sample_offsets[node_end];
    const sample_total = canopy_state.?.node_sample_offsets[node_total];
    const plants: DomainRange = .{ .total = plant_count, .first = plant_first, .end = plant_end };
    const branches: DomainRange = .{ .total = branch_total, .first = branch_first, .end = branch_end };
    const nodes: DomainRange = .{ .total = node_total, .first = node_first, .end = node_end };
    const samples: DomainRange = .{ .total = sample_total, .first = sample_first, .end = sample_end };
    try captureCanopyState(rollback, canopy_state.?, plants, branches, nodes, samples);
    try rollback.captureScaledFields(harvest.branch_development, branch_total, branch_first, branch_end);
    if (harvest.canopy_layer_state) |layers|
        try captureCanopyLayers(rollback, layers, .{ .total = context.grid.cell_count, .first = cell, .end = cell + 1 }, plants, branches, nodes);
    if (harvest.plant_phenology) |phenology|
        try rollback.captureScaledFields(phenology, plant_count, plant_first, plant_end);
    if (harvest.growth_stages) |growth| {
        const first_growth = try growth.branchRange(plant_first);
        const last_growth = try growth.branchRange(plant_end - 1);
        try rollback.capture(growth.branches, first_growth.first, last_growth.end);
    }
    if (harvest.emerged_by_plant) |emerged| try rollback.capture(emerged, plant_first, plant_end);
    if (harvest.shoot_litter_carbon_g_c_by_plant) |values| try rollback.capture(values, plant_first, plant_end);
    if (harvest.shoot_litter_nitrogen_g_n_by_plant) |values| try rollback.capture(values, plant_first, plant_end);
    if (harvest.shoot_litter_phosphorus_g_p_by_plant) |values| try rollback.capture(values, plant_first, plant_end);
    if (harvest.root_litter_carbon_ledger) |ledger|
        try rollback.captureScaledFields(ledger, ledger.plant_count, plant_first, plant_end);
    if (harvest.surface_organic_state) |surface|
        try rollback.captureScaledFields(surface, surface.layer_count, cell, cell + 1);
}

pub fn dispatchDate(map: ScheduleMap, catalog: disturbance.Catalog, date: Date, context: *ApplyContext) !usize {
    const before = try dispatchDatePhase(map, catalog, date, context, .pre_science);
    return before + try dispatchDatePhase(map, catalog, date, context, .post_science);
}

pub const Phase = enum { pre_science, post_science };

fn lastEventForDate(events: []const disturbance.Event, date: Date) ?disturbance.Event {
    var selected: ?disturbance.Event = null;
    for (events) |event| {
        if (event.date.day != date.day or event.date.month != date.month or
            (!event.date.isRecurring() and event.date.year != date.year)) continue;
        selected = event;
    }
    return selected;
}

test "same-date disturbance uses the last READS record across phases" {
    const events = [_]disturbance.Event{
        .{ .date = .{ .day = 2, .month = 7, .year = 0 }, .operation = .{ .tillage = .{ .depth_m = 0.2, .mixing_fraction = 0.5, .includes_crop = true } } },
        .{ .date = .{ .day = 2, .month = 7, .year = 0 }, .operation = .{ .fire = .{ .energy_kw_per_m2 = 3 } } },
    };
    const selected = lastEventForDate(&events, .{ .day = 2, .month = 7, .year = 2024 }) orelse return error.TestExpectedEqual;
    switch (selected.operation) {
        .fire => |fire| try std.testing.expectEqual(@as(f64, 3), fire.energy_kw_per_m2),
        else => return error.TestExpectedEqual,
    }
}

// `dispatchDatePhase`'s no-op property for an hour with no scheduled event
// reduces to two already-independently-true facts: `lastEventForDate` returns
// null when nothing matches (proven here), and it is reached via
// `orelse continue` at :791 before any owner is touched, exactly mirroring
// how "runtime disturbance map resolves schedules and case-insensitive no"
// (above) proves `ScheduleMap.catalog_index_by_cell` stays null for an
// unassigned unit. A full `dispatchDatePhase` call would need a fully
// populated `ApplyContext` (~20 required owner pointers) whose fields this
// skip path never dereferences, so asserting the two preconditions directly
// is the narrower and equally conclusive proof of no-op-ness.
test "no matching event on a date leaves the dispatch skip path with nothing to select" {
    const events = [_]disturbance.Event{
        .{ .date = .{ .day = 2, .month = 7, .year = 2023 }, .operation = .{ .tillage = .{ .depth_m = 0.2, .mixing_fraction = 0.5, .includes_crop = true } } },
        .{ .date = .{ .day = 3, .month = 8, .year = 0 }, .operation = .{ .fire = .{ .energy_kw_per_m2 = 3 } } },
    };
    try std.testing.expectEqual(@as(?disturbance.Event, null), lastEventForDate(&events, .{ .day = 2, .month = 7, .year = 2024 }));
    try std.testing.expectEqual(@as(?disturbance.Event, null), lastEventForDate(&events, .{ .day = 3, .month = 9, .year = 0 }));
}

pub fn dispatchDatePhase(map: ScheduleMap, catalog: disturbance.Catalog, date: Date, context: *ApplyContext, phase: Phase) !usize {
    try validateDispatchDate(date);
    if (context.source_hour_one_through_twenty_four == 0 or context.source_hour_one_through_twenty_four > 24)
        return error.InvalidHourlyDisturbanceSchedule;
    if (context.solar_noon_hour_by_cell.len != map.catalog_index_by_cell.len)
        return error.DisturbanceSolarNoonDimensionMismatch;
    var applied: usize = 0;
    for (map.catalog_index_by_cell, 0..) |maybe_schedule, cell| {
        if (!try isApplicationHour(context.source_hour_one_through_twenty_four, context.solar_noon_hour_by_cell, cell)) continue;
        const schedule = maybe_schedule orelse continue;
        if (schedule >= catalog.entries.items.len) return error.DisturbanceScheduleIndexOutOfBounds;
        // READS owns one ITILL/DCORP slot per cell; later same-date records
        // overwrite earlier records before GROSUB/REDIST sees the operation.
        if (lastEventForDate(catalog.entries.items[schedule].events, date)) |event| {
            const event_phase: Phase = switch (event.operation) {
                .fire => .pre_science,
                else => .post_science,
            };
            if (event_phase != phase) continue;
            try applyEvent(context, cell, event);
            applied += 1;
        }
    }
    return applied;
}

/// Adapts the weather timestamp's conventional 0--23 wall clock to the
/// source GROSUB/READS HOUR1 domain. Midnight belongs to source hour 24;
/// all other wall-clock hour numbers retain their source value.
pub fn sourceHourOneThroughTwentyFour(
    wall_clock_hour_zero_through_twenty_three: u8,
) !u8 {
    if (wall_clock_hour_zero_through_twenty_three > 23)
        return error.InvalidHourlyDisturbanceSchedule;
    return if (wall_clock_hour_zero_through_twenty_three == 0)
        24
    else
        wall_clock_hour_zero_through_twenty_three;
}

fn validateDispatchDate(date: Date) !void {
    if (date.year == 0) return error.InvalidDisturbanceDispatchDate;
    _ = execution_calendar_date.dayOfYear(.{ .day = date.day, .month = date.month, .year = date.year }) catch return error.InvalidDisturbanceDispatchDate;
}

fn isApplicationHour(source_hour: u8, solar_noon_by_cell: []const u8, cell: usize) !bool {
    if (source_hour == 0 or source_hour > 24) return error.InvalidHourlyDisturbanceSchedule;
    if (cell >= solar_noon_by_cell.len) return error.DisturbanceSolarNoonDimensionMismatch;
    const solar_noon = solar_noon_by_cell[cell];
    if (solar_noon > 24) return error.InvalidHourlyDisturbanceSchedule;
    return source_hour == solar_noon;
}

fn assignedSpeciesCountForCell(
    assignments: *const PlantAssignment.Assignments,
    unit_by_cell: []const usize,
    cell_count: usize,
    species_capacity: usize,
    cell: usize,
) !usize {
    if (species_capacity == 0 or unit_by_cell.len != cell_count or cell >= cell_count)
        return error.DisturbancePlantAssignmentDimensionMismatch;
    const unit = unit_by_cell[cell];
    if (unit >= assignments.units.len) return error.DisturbancePlantAssignmentUnitOutOfBounds;
    const assigned = assignments.units[unit].species.len;
    if (assigned > species_capacity) return error.PlantSpeciesCapacityExceeded;
    return assigned;
}

test "tillage iterates assigned PFTs rather than runtime capacity" {
    var species = [_]PlantAssignment.SpeciesAssignment{
        .{ .species_file = "maize", .management_file = "crop" },
        .{ .species_file = "soybean", .management_file = "legume" },
        .{ .species_file = "grass", .management_file = "perennial" },
    };
    var units = [_]PlantAssignment.Unit{
        .{ .species = species[0..1] },
        .{ .species = species[0..3] },
        .{ .species = species[0..2] },
        .{ .species = species[0..0] },
    };
    const assignments: PlantAssignment.Assignments = .{ .allocator = std.testing.allocator, .units = &units };
    // Nonidentity geographic cell mapping, with capacity larger than every
    // assigned set. Eligibility must not depend on current biomass/activity.
    const map = [_]usize{ 2, 0, 1, 3 };
    for ([_]usize{ 2, 1, 3, 0 }, 0..) |expected, cell|
        try std.testing.expectEqual(expected, try assignedSpeciesCountForCell(&assignments, &map, 4, 7, cell));
    // Ottawa is one assigned PFT in five allocated slots. The four unused
    // slots have default planting dates but must never enter plant tillage.
    try std.testing.expectEqual(@as(usize, 1), try assignedSpeciesCountForCell(&assignments, &.{0}, 1, 5, 0));
    try std.testing.expectError(error.PlantSpeciesCapacityExceeded, assignedSpeciesCountForCell(&assignments, &map, 4, 2, 2));
    try std.testing.expectError(error.DisturbancePlantAssignmentDimensionMismatch, assignedSpeciesCountForCell(&assignments, &map, 3, 7, 0));
    try std.testing.expectError(error.DisturbancePlantAssignmentDimensionMismatch, assignedSpeciesCountForCell(&assignments, &map, 4, 7, 4));
    try std.testing.expectError(error.DisturbancePlantAssignmentDimensionMismatch, assignedSpeciesCountForCell(&assignments, &map, 4, 0, 0));
    try std.testing.expectError(error.DisturbancePlantAssignmentUnitOutOfBounds, assignedSpeciesCountForCell(&assignments, &.{4}, 1, 7, 0));
}

pub fn applyEvent(context: *ApplyContext, cell: usize, event: disturbance.Event) !void {
    const tillage = switch (event.operation) {
        .tillage => |value| value,
        .surface_litter_removal => |removal| {
            const binding = context.surface_litter_removal orelse
                return error.IncompleteSurfaceLitterRemovalContext;
            try applySurfaceLitterRemoval(binding, cell, removal.fraction);
            return;
        },
        .fire => |fire| {
            if (cell >= context.surface_energy.cell_count or cell >= context.fire_active_this_hour.len) return error.DisturbanceCellOutOfBounds;
            const energy_megajoules_per_m2 = 3.6 * fire.energy_kw_per_m2;
            const next = context.surface_energy.fire_ignition_megajoules_per_m2[cell] + energy_megajoules_per_m2;
            if (!std.math.isFinite(next)) return error.NonFiniteFireIgnitionEnergy;
            context.surface_energy.fire_ignition_megajoules_per_m2[cell] = next;
            context.fire_active_this_hour[cell] = true;
            return;
        },
        .natural_drainage => |drainage| {
            try context.soil_boundary_topology.applyNaturalDrainageReset(
                cell,
                drainage.depth_m,
                context.terrain_hydrology,
                context.soil_geometry,
            );
            try SurfaceLitterGeometry.markRetentionRefresh(context.tillage_runtime.surface_geometry, cell);
            return;
        },
        .artificial_drainage => |drainage| {
            try context.soil_boundary_topology.applyArtificialDrainageReset(
                cell,
                drainage.depth_m,
                drainage.boundaries,
                context.terrain_hydrology,
                context.soil_geometry,
            );
            return;
        },
    };
    if (context.species_count == 0 or context.roots.plant_count != context.grid.cell_count * context.species_count or context.litter_partition.plant_count != context.roots.plant_count or
        context.biological_domain_count_by_plant.len != context.roots.plant_count or context.root_nonwoody_fraction_by_plant.len != context.roots.plant_count or
        context.biomass_turnover_type_by_plant.len != context.roots.plant_count or context.root_profile_type_by_plant.len != context.roots.plant_count or
        context.growth_habit_by_plant.len != context.roots.plant_count or context.leaf_phenology_type_by_plant.len != context.roots.plant_count or
        context.planting_day_of_year_by_plant.len != context.roots.plant_count or context.planting_year_by_plant.len != context.roots.plant_count)
        return error.DisturbancePlantDimensionMismatch;
    if (cell >= context.grid.cell_count) return error.DisturbanceCellOutOfBounds;
    const assigned_species_count = try assignedSpeciesCountForCell(
        context.plant_assignments,
        context.plant_unit_by_cell,
        context.grid.cell_count,
        context.species_count,
        cell,
    );
    if (context.tillage_runtime.grid != context.grid or context.tillage_runtime.soil_organic != context.soil_organic)
        return error.TillageRuntimeOwnerMismatch;
    if (context.plant_harvest) |harvest| if (harvest.surface_organic_state) |surface|
        if (surface != context.tillage_runtime.surface_organic) return error.TillageRuntimeOwnerMismatch;

    var rollback = EventRollback.init(context.tillage_runtime.allocator);
    defer rollback.deinit();
    try captureTillagePlantOwners(context, cell, &rollback);
    errdefer rollback.restore();

    const retention = RootDisturbance.ElementRetention.uniform(1 - tillage.mixing_fraction);
    for (0..assigned_species_count) |species| {
        if (!tillage.includes_crop and species == 0) continue;
        const plant = cell * context.species_count + species;
        const after_planting = context.current_year > context.planting_year_by_plant[plant] or
            (context.current_year == context.planting_year_by_plant[plant] and
                context.current_day_of_year > context.planting_day_of_year_by_plant[plant]);
        const tillage_eligible = (context.biomass_turnover_type_by_plant[plant] == 0 or
            context.root_profile_type_by_plant[plant] <= 1) and after_planting;
        if (!tillage_eligible) continue;
        const fine = try context.litter_partition.get(plant, .fine_root);
        const coarse = try context.litter_partition.get(plant, .coarse_wood);
        const mobile = try context.litter_partition.get(plant, .nonstructural);
        const nonwoody_fraction = context.root_nonwoody_fraction_by_plant[plant];
        if (!std.math.isFinite(nonwoody_fraction) or nonwoody_fraction < 0 or nonwoody_fraction > 1) return error.InvalidRootTillageInput;
        // grosub.f:10305-10306 bounds this root/nodule tillage litterfall-and-
        // retention loop to `DO L=NU,NJ` (the rooting zone), never the full
        // soil column (`NL`); described/extrapolated layers below the
        // rooting zone are untouched by tillage in the oracle.
        for (0..context.grid.maximum_rooting_layer_count[cell]) |layer| {
            const root = try context.roots.layerIndex(plant, 0, layer);
            const result = try calculateLayer(context.roots, root, retention, fine, mobile);
            var state_update: RootLitterfall.LayerInput = .{};
            try state_update.add(result.litterfall);
            try state_update.add(try calculateHostRootTillage(
                context.roots,
                plant,
                layer,
                context.biological_domain_count_by_plant[plant],
                tillage.mixing_fraction,
                nonwoody_fraction,
                coarse,
                fine,
                mobile,
            ));
            const ledger = context.root_litter_carbon_ledger;
            const host_domain_zero = try calculateHostRootTillageDomain(context.roots, plant, 0, layer, tillage.mixing_fraction, nonwoody_fraction, coarse, fine, mobile);
            try ledger.validateAdd(plant, 0, layer, host_domain_zero);
            if (context.biological_domain_count_by_plant[plant] > 1) {
                const host_domain_one = try calculateHostRootTillageDomain(context.roots, plant, 1, layer, tillage.mixing_fraction, nonwoody_fraction, coarse, fine, mobile);
                try ledger.validateCarbonAdd(
                    plant,
                    1,
                    layer,
                    try RootLitterLedger.totalCarbon(host_domain_one) +
                        try RootLitterLedger.totalCarbon(result.litterfall),
                );
            } else {
                try ledger.validateAdd(plant, 1, layer, result.litterfall);
            }
            try RootDisturbance.validateRootGasRelease(context.roots, plant, layer, tillage.mixing_fraction);
            try RootLitterfall.validateStateUpdate(context.soil_organic, try context.grid.layerIndex(cell, layer), state_update);
        }
        const harvest = context.plant_harvest orelse return error.IncompleteAbovegroundTillageContext;
        try PlantHarvest.applyAbovegroundTillage(
            harvest,
            plant,
            1 - tillage.mixing_fraction,
            context.growth_habit_by_plant[plant] == 0 and context.leaf_phenology_type_by_plant[plant] != 0,
        );
        // Counted only after the call succeeds, so a rejected context cannot
        // report the branch as executed. Saturates rather than wrapping for the
        // same reason the census counter does.
        if (context.aboveground_tillage_plant_count != std.math.maxInt(usize))
            context.aboveground_tillage_plant_count += 1;
        // Same NJ (rooting-zone) bound as the loop above; see grosub.f:10305-10306.
        for (0..context.grid.maximum_rooting_layer_count[cell]) |layer| {
            const root = try context.roots.layerIndex(plant, 0, layer);
            const soil = try context.grid.layerIndex(cell, layer);
            const result = try calculateLayer(context.roots, root, retention, fine, mobile);
            var host_litter_by_domain = [_]RootMetabolism.RootLitter{
                std.mem.zeroes(RootMetabolism.RootLitter),
                std.mem.zeroes(RootMetabolism.RootLitter),
            };
            for (0..context.biological_domain_count_by_plant[plant]) |domain|
                host_litter_by_domain[domain] = calculateHostRootTillageDomain(
                    context.roots,
                    plant,
                    domain,
                    layer,
                    tillage.mixing_fraction,
                    nonwoody_fraction,
                    coarse,
                    fine,
                    mobile,
                ) catch unreachable;
            context.roots.symbiont_structural_carbon_g_c[root] = result.structural.carbon_g_c;
            context.roots.symbiont_structural_nitrogen_g_n[root] = result.structural.nitrogen_g_n;
            context.roots.symbiont_structural_phosphorus_g_p[root] = result.structural.phosphorus_g_p;
            context.roots.symbiont_mobile_carbon_g_c[root] = result.mobile.carbon_g_c;
            context.roots.symbiont_mobile_nitrogen_g_n[root] = result.mobile.nitrogen_g_n;
            context.roots.symbiont_mobile_phosphorus_g_p[root] = result.mobile.phosphorus_g_p;
            var state_update: RootLitterfall.LayerInput = .{};
            state_update.add(result.litterfall) catch unreachable;
            state_update.add(calculateHostRootTillage(
                context.roots,
                plant,
                layer,
                context.biological_domain_count_by_plant[plant],
                tillage.mixing_fraction,
                nonwoody_fraction,
                coarse,
                fine,
                mobile,
            ) catch unreachable) catch unreachable;
            state_updateHostRootTillage(
                context.roots,
                plant,
                layer,
                context.biological_domain_count_by_plant[plant],
                tillage.mixing_fraction,
            ) catch unreachable;
            RootDisturbance.releaseRootGasFraction(context.roots, plant, layer, tillage.mixing_fraction) catch unreachable;
            RootLitterfall.publishValidated(context.soil_organic, soil, state_update);
            const ledger = context.root_litter_carbon_ledger;
            ledger.addValidated(plant, 1, layer, result.litterfall);
            for (0..context.biological_domain_count_by_plant[plant]) |domain|
                ledger.addValidated(plant, domain, layer, host_litter_by_domain[domain]);
        }
    }

    // Above-ground tillage litter must enter the surface owner before REDIST
    // transfers that owner into the mixed soil column. The normal post-event
    // publisher then observes an empty ledger; tillage never exports biomass.
    if (context.plant_harvest) |harvest| for (0..assigned_species_count) |species| {
        if (!tillage.includes_crop and species == 0) continue;
        const plant = cell * context.species_count + species;
        const after_planting = context.current_year > context.planting_year_by_plant[plant] or
            (context.current_year == context.planting_year_by_plant[plant] and
                context.current_day_of_year > context.planting_day_of_year_by_plant[plant]);
        const tillage_eligible = (context.biomass_turnover_type_by_plant[plant] == 0 or
            context.root_profile_type_by_plant[plant] <= 1) and after_planting;
        if (!tillage_eligible) continue;
        const exported = try PlantHarvest.publishPlantProducts(harvest, plant);
        if (exported.carbon_g != 0 or exported.nitrogen_g != 0 or exported.phosphorus_g != 0)
            return error.TillageUnexpectedEcosystemExport;
    };

    if (context.deferred_tillage_soil_by_cell) |pending| {
        try stageDeferredTillage(pending, cell, tillage.depth_m, tillage.mixing_fraction);
        return;
    }

    // This is the final fallible operation. The adapter runs all 17 REDIST
    // kernels and every closure check on private storage, then commits without
    // failure; any error above or here restores every earlier plant/litter write.
    try context.tillage_runtime.local_activity.beginAttempt();
    errdefer context.tillage_runtime.local_activity.abortAttempt();
    try TillageRuntime.apply(&context.tillage_runtime, cell, tillage.depth_m, tillage.mixing_fraction);
    try context.tillage_runtime.local_activity.commitAttempt();
}

fn applySurfaceLitterRemoval(
    binding: *SurfaceLitterRemovalContext,
    cell: usize,
    removal_fraction: f64,
) !void {
    const cell_count = binding.runtime.surface_organic.layer_count;
    if (cell >= cell_count or
        binding.carbon_export_g_c_per_h_by_cell.len != cell_count or
        binding.nitrogen_export_g_n_per_h_by_cell.len != cell_count or
        binding.phosphorus_export_g_p_per_h_by_cell.len != cell_count)
        return error.SurfaceLitterRemovalDimensionMismatch;

    var carbon_targets = [_]*f64{&binding.carbon_export_g_c_per_h_by_cell[cell]};
    var nitrogen_targets = [_]*f64{&binding.nitrogen_export_g_n_per_h_by_cell[cell]};
    var phosphorus_targets = [_]*f64{&binding.phosphorus_export_g_p_per_h_by_cell[cell]};
    var heat_targets = [_]*f64{binding.cumulative_heat_output_megajoules};
    var runtime = binding.runtime;
    runtime.ledgers = .{
        // These hourly arrays are rolled into the daily landscape export
        // ledger at day close. Binding the cumulative C/N/P ledger here as
        // well would count the same external removal twice.
        .dissolved_carbon_output_g_c = &carbon_targets,
        .dissolved_nitrogen_output_g_n = &nitrogen_targets,
        .dissolved_phosphorus_output_g_p = &phosphorus_targets,
        // Heat has no equivalent daily export carrier and is booked once now.
        .heat_output_megajoules = &heat_targets,
    };
    _ = try SurfaceLitterRemoval.applyRuntimeCell(&runtime, cell, removal_fraction);
}

fn calculateHostRootTillage(
    roots: *const RootSystem.State,
    plant: usize,
    layer: usize,
    domain_count: usize,
    removed_fraction: f64,
    nonwoody_fraction: f64,
    coarse: LitterPartition.ElementFractions,
    fine: LitterPartition.ElementFractions,
    mobile: LitterPartition.ElementFractions,
) !RootMetabolism.RootLitter {
    return calculateHostRootTillageRange(
        roots,
        plant,
        0,
        domain_count,
        layer,
        removed_fraction,
        nonwoody_fraction,
        coarse,
        fine,
        mobile,
    );
}

fn calculateHostRootTillageRange(
    roots: *const RootSystem.State,
    plant: usize,
    first_domain: usize,
    end_domain: usize,
    layer: usize,
    removed_fraction: f64,
    nonwoody_fraction: f64,
    coarse: LitterPartition.ElementFractions,
    fine: LitterPartition.ElementFractions,
    mobile: LitterPartition.ElementFractions,
) !RootMetabolism.RootLitter {
    if (first_domain >= end_domain or end_domain > RootSystem.biological_domain_count or
        !std.math.isFinite(removed_fraction) or removed_fraction < 0 or removed_fraction > 1 or
        !std.math.isFinite(nonwoody_fraction) or nonwoody_fraction < 0 or nonwoody_fraction > 1)
        return error.InvalidRootTillageInput;
    try coarse.validate();
    try fine.validate();
    try mobile.validate();
    var structural = [3]f64{ 0, 0, 0 };
    var mobile_pool = [3]f64{ 0, 0, 0 };
    for (first_domain..end_domain) |domain| {
        const root = try roots.layerIndex(plant, domain, layer);
        inline for (.{
            .{ "mobile_carbon_g", 0 },
            .{ "mobile_nitrogen_g", 1 },
            .{ "mobile_phosphorus_g", 2 },
        }) |entry| {
            const value = @field(roots, entry[0])[root];
            if (!std.math.isFinite(value) or value < 0) return error.InvalidRootTillageInput;
            mobile_pool[entry[1]] += value;
        }
        for (0..roots.active_root_axis_count[plant]) |axis| {
            const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
            inline for (.{
                .{ "axis_primary_carbon_g", "axis_secondary_carbon_g", 0 },
                .{ "axis_primary_nitrogen_g", "axis_secondary_nitrogen_g", 1 },
                .{ "axis_primary_phosphorus_g", "axis_secondary_phosphorus_g", 2 },
            }) |entry| {
                const primary = @field(roots, entry[0])[axis_layer];
                const secondary = @field(roots, entry[1])[axis_layer];
                if (!std.math.isFinite(primary) or primary < 0 or !std.math.isFinite(secondary) or secondary < 0)
                    return error.InvalidRootTillageInput;
                structural[entry[2]] += primary + secondary;
            }
        }
    }
    var litter = std.mem.zeroes(RootMetabolism.RootLitter);
    const woody_fraction = 1 - nonwoody_fraction;
    for (0..LitterPartition.kinetic_component_count) |component| {
        litter.woody_carbon_g_c[component] = removed_fraction * structural[0] * woody_fraction * coarse.carbon[component];
        litter.woody_nitrogen_g_n[component] = removed_fraction * structural[1] * woody_fraction * coarse.nitrogen[component];
        litter.woody_phosphorus_g_p[component] = removed_fraction * structural[2] * woody_fraction * coarse.phosphorus[component];
        litter.nonwoody_carbon_g_c[component] = removed_fraction * (structural[0] * nonwoody_fraction * fine.carbon[component] + mobile_pool[0] * mobile.carbon[component]);
        litter.nonwoody_nitrogen_g_n[component] = removed_fraction * (structural[1] * nonwoody_fraction * fine.nitrogen[component] + mobile_pool[1] * mobile.nitrogen[component]);
        litter.nonwoody_phosphorus_g_p[component] = removed_fraction * (structural[2] * nonwoody_fraction * fine.phosphorus[component] + mobile_pool[2] * mobile.phosphorus[component]);
    }
    return litter;
}

fn calculateHostRootTillageDomain(
    roots: *const RootSystem.State,
    plant: usize,
    domain: usize,
    layer: usize,
    removed_fraction: f64,
    nonwoody_fraction: f64,
    coarse: LitterPartition.ElementFractions,
    fine: LitterPartition.ElementFractions,
    mobile: LitterPartition.ElementFractions,
) !RootMetabolism.RootLitter {
    if (domain >= RootSystem.biological_domain_count)
        return error.InvalidRootTillageInput;
    return calculateHostRootTillageRange(
        roots,
        plant,
        domain,
        domain + 1,
        layer,
        removed_fraction,
        nonwoody_fraction,
        coarse,
        fine,
        mobile,
    );
}

fn state_updateHostRootTillage(
    roots: *RootSystem.State,
    plant: usize,
    layer: usize,
    domain_count: usize,
    removed_fraction: f64,
) !void {
    const retained = 1 - removed_fraction;
    for (0..domain_count) |domain| {
        const root = try roots.layerIndex(plant, domain, layer);
        inline for (.{
            "mobile_carbon_g",
            "mobile_nitrogen_g",
            "mobile_phosphorus_g",
            "protein_carbon_g",
            "total_carbon_g",
            "primary_root_carbon_g",
            "projected_area_m2",
            "active_length_m",
            "aqueous_volume_m3",
            "gaseous_volume_m3",
            "root_length_m_per_plant",
            "root_length_density_m_per_m3",
            "root_surface_area_m2_per_plant",
            "average_secondary_length_m",
            "secondary_axis_count_total",
            "symbiotic_respiration_actual_g_c_per_h",
            "symbiotic_respiration_oxygen_unlimited_g_c_per_h",
        }) |field_name| @field(roots, field_name)[root] *= retained;
        for (0..roots.active_root_axis_count[plant]) |axis| {
            const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
            inline for (.{
                "axis_primary_carbon_g",
                "axis_primary_nitrogen_g",
                "axis_primary_phosphorus_g",
                "axis_secondary_carbon_g",
                "axis_secondary_nitrogen_g",
                "axis_secondary_phosphorus_g",
                "axis_primary_length_m",
                "axis_secondary_length_m",
                "axis_primary_count",
                "axis_secondary_count",
            }) |field_name| @field(roots, field_name)[axis_layer] *= retained;
        }
    }
}

/// GROSUB nodule-fire transaction. Source FWPODL/FWTNDL fractions are formed
/// from the total mobile/structural nodule carbon across every runtime species
/// in a cell and layer, then applied uniformly to each species' C/N/P pools.
pub fn applyRootFireCombustion(
    roots: *RootSystem.State,
    canopy: ?*Canopy.State,
    grid: *const Grid,
    species_count: usize,
    biological_domain_count_by_plant: []const u8,
    cell_area_m2: []const f64,
    fire_active_this_hour: []const bool,
    timestep_h: f64,
    salinity_enabled_by_cell: []const bool,
    parameters: RootDisturbance.CombustionParameters,
    fire_exchange: *OrganicMatterFireExchange.State,
) !void {
    try parameters.validate();
    if (species_count == 0 or roots.plant_count != grid.cell_count * species_count or biological_domain_count_by_plant.len != roots.plant_count) return error.DisturbancePlantDimensionMismatch;
    if (canopy) |state| if (state.cell_count != grid.cell_count or state.species_count != species_count) return error.DisturbancePlantDimensionMismatch;
    if (cell_area_m2.len != grid.cell_count or fire_active_this_hour.len != grid.cell_count or salinity_enabled_by_cell.len != grid.cell_count or fire_exchange.layer_count != grid.layer_count) return error.DisturbanceCellDimensionMismatch;
    if (!std.math.isFinite(timestep_h) or timestep_h <= 0) return error.InvalidRootNoduleCombustionInput;
    for (0..grid.cell_count) |cell| {
        if (!fire_active_this_hour[cell]) continue;
        const dynamic_salts = salinity_enabled_by_cell[cell];
        if (!std.math.isFinite(cell_area_m2[cell]) or cell_area_m2[cell] <= 0) return error.InvalidRootNoduleCombustionInput;
        for (0..grid.active_soil_layer_count[cell]) |layer| {
            const soil = try grid.layerIndex(cell, layer);
            var previous_carbon_loss_g_c: f64 = 0;
            var previous_nitrogen_loss_g_n: f64 = 0;
            var previous_phosphorus_loss_g_p: f64 = 0;
            var previous_salt_loss_mol: [OrganicMatterFireExchange.salt_species_count]f64 = @splat(0);
            for (0..species_count) |species| {
                const plant = cell * species_count + species;
                previous_carbon_loss_g_c += roots.combustion_carbon_loss_g_c_per_h[plant];
                previous_nitrogen_loss_g_n += roots.combustion_nitrogen_loss_g_n_per_h[plant];
                previous_phosphorus_loss_g_p += roots.combustion_phosphorus_loss_g_p_per_h[plant];
                const biological_domain_count = try domainCount(biological_domain_count_by_plant, plant);
                if (dynamic_salts) for (0..biological_domain_count) |domain| {
                    const root = try roots.layerIndex(plant, domain, layer);
                    for (0..OrganicMatterFireExchange.salt_species_count) |salt| previous_salt_loss_mol[salt] += roots.combustion_salt_loss_mol_per_h[root * OrganicMatterFireExchange.salt_species_count + salt];
                };
            }
            var total_symbiont_structural_carbon_g_c: f64 = 0;
            var total_symbiont_mobile_carbon_g_c: f64 = 0;
            var total_root_mobile_carbon_g_c: f64 = 0;
            var total_root_structural_carbon_g_c: f64 = 0;
            for (0..species_count) |species| {
                const plant = cell * species_count + species;
                const root = try roots.layerIndex(plant, 0, layer);
                const symbiont_structural = roots.symbiont_structural_carbon_g_c[root];
                const symbiont_mobile = roots.symbiont_mobile_carbon_g_c[root];
                if (!std.math.isFinite(symbiont_structural) or symbiont_structural < 0 or !std.math.isFinite(symbiont_mobile) or symbiont_mobile < 0) return error.InvalidRootSymbiontPool;
                total_symbiont_structural_carbon_g_c += symbiont_structural;
                total_symbiont_mobile_carbon_g_c += symbiont_mobile;
                const biological_domain_count = try domainCount(biological_domain_count_by_plant, plant);
                for (0..biological_domain_count) |domain| {
                    const domain_root = try roots.layerIndex(plant, domain, layer);
                    const mobile = roots.mobile_carbon_g[domain_root];
                    if (!std.math.isFinite(mobile) or mobile < 0) return error.InvalidRootCombustionPool;
                    total_root_mobile_carbon_g_c += mobile;
                    for (0..roots.root_axis_count) |axis| {
                        const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
                        const structural = roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer];
                        if (!std.math.isFinite(structural) or structural < 0) return error.InvalidRootCombustionPool;
                        total_root_structural_carbon_g_c += structural;
                    }
                }
            }
            const symbiont_structural_fraction = try RootDisturbance.combustionFraction(total_symbiont_structural_carbon_g_c, grid.soil_temperature_k[soil], cell_area_m2[cell], timestep_h, parameters.nonwoody_structural_specific_combustion_g_c_per_m2_h, parameters);
            const symbiont_mobile_fraction = try RootDisturbance.combustionFraction(total_symbiont_mobile_carbon_g_c, grid.soil_temperature_k[soil], cell_area_m2[cell], timestep_h, parameters.mobile_and_leaf_specific_combustion_g_c_per_m2_h, parameters);
            const root_mobile_fraction = try RootDisturbance.combustionFraction(total_root_mobile_carbon_g_c, grid.soil_temperature_k[soil], cell_area_m2[cell], timestep_h, parameters.mobile_and_leaf_specific_combustion_g_c_per_m2_h, parameters);
            const root_structural_fraction = try RootDisturbance.combustionFraction(total_root_structural_carbon_g_c, grid.soil_temperature_k[soil], cell_area_m2[cell], timestep_h, parameters.root_structural_specific_combustion_g_c_per_m2_h, parameters);

            // Validate the complete layer before publishing any mutation.
            for (0..species_count) |species| {
                const plant = cell * species_count + species;
                const root = try roots.layerIndex(plant, 0, layer);
                _ = try combustionResult(roots, root, symbiont_structural_fraction, symbiont_mobile_fraction);
                try validateRootCombustion(roots, plant, layer, try domainCount(biological_domain_count_by_plant, plant), root_mobile_fraction, root_structural_fraction, dynamic_salts);
                if (layer == 0) if (canopy) |state| try validateStorageCombustion(state, plant);
            }
            for (0..species_count) |species| {
                const plant = cell * species_count + species;
                const root = try roots.layerIndex(plant, 0, layer);
                const result = combustionResult(roots, root, symbiont_structural_fraction, symbiont_mobile_fraction) catch unreachable;
                roots.symbiont_structural_carbon_g_c[root] = result.structural.carbon_g_c;
                roots.symbiont_structural_nitrogen_g_n[root] = result.structural.nitrogen_g_n;
                roots.symbiont_structural_phosphorus_g_p[root] = result.structural.phosphorus_g_p;
                roots.symbiont_mobile_carbon_g_c[root] = result.mobile.carbon_g_c;
                roots.symbiont_mobile_nitrogen_g_n[root] = result.mobile.nitrogen_g_n;
                roots.symbiont_mobile_phosphorus_g_p[root] = result.mobile.phosphorus_g_p;
                roots.combustion_carbon_loss_g_c_per_h[plant] -= result.emitted.carbon_g_c;
                roots.combustion_nitrogen_loss_g_n_per_h[plant] -= result.emitted.nitrogen_g_n;
                roots.combustion_phosphorus_loss_g_p_per_h[plant] -= result.emitted.phosphorus_g_p;
                roots.symbiont_combustion_g_c_per_h[root] += result.emitted.carbon_g_c;
                state_updateRootCombustion(roots, plant, layer, biological_domain_count_by_plant[plant], root_mobile_fraction, root_structural_fraction, dynamic_salts);
                if (layer == 0) if (canopy) |state| state_updateStorageCombustion(state, roots, plant, root, root_structural_fraction);
            }
            var carbon_loss_g_c: f64 = 0;
            var nitrogen_loss_g_n: f64 = 0;
            var phosphorus_loss_g_p: f64 = 0;
            var salt_loss_mol: [OrganicMatterFireExchange.salt_species_count]f64 = @splat(0);
            for (0..species_count) |species| {
                const plant = cell * species_count + species;
                carbon_loss_g_c += roots.combustion_carbon_loss_g_c_per_h[plant];
                nitrogen_loss_g_n += roots.combustion_nitrogen_loss_g_n_per_h[plant];
                phosphorus_loss_g_p += roots.combustion_phosphorus_loss_g_p_per_h[plant];
                const biological_domain_count = try domainCount(biological_domain_count_by_plant, plant);
                if (dynamic_salts) for (0..biological_domain_count) |domain| {
                    const root = try roots.layerIndex(plant, domain, layer);
                    for (0..OrganicMatterFireExchange.salt_species_count) |salt| salt_loss_mol[salt] += roots.combustion_salt_loss_mol_per_h[root * OrganicMatterFireExchange.salt_species_count + salt];
                };
            }
            for (0..OrganicMatterFireExchange.salt_species_count) |salt| salt_loss_mol[salt] -= previous_salt_loss_mol[salt];
            try fire_exchange.addCombustedPoolsForSubstrate(
                soil,
                1,
                previous_carbon_loss_g_c - carbon_loss_g_c,
                previous_nitrogen_loss_g_n - nitrogen_loss_g_n,
                previous_phosphorus_loss_g_p - phosphorus_loss_g_p,
                &salt_loss_mol,
            );
        }
    }
}

fn validateStorageCombustion(canopy: *const Canopy.State, plant: usize) !void {
    inline for (.{
        canopy.plant_seed_storage_carbon_g[plant],
        canopy.plant_seed_storage_nitrogen_g[plant],
        canopy.plant_seed_storage_phosphorus_g[plant],
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootCombustionPool;
}

fn state_updateStorageCombustion(canopy: *Canopy.State, roots: *RootSystem.State, plant: usize, top_root: usize, fraction: f64) void {
    const carbon = canopy.plant_seed_storage_carbon_g[plant] * fraction;
    const nitrogen = canopy.plant_seed_storage_nitrogen_g[plant] * fraction;
    const phosphorus = canopy.plant_seed_storage_phosphorus_g[plant] * fraction;
    canopy.plant_seed_storage_carbon_g[plant] -= carbon;
    canopy.plant_seed_storage_nitrogen_g[plant] -= nitrogen;
    canopy.plant_seed_storage_phosphorus_g[plant] -= phosphorus;
    roots.combustion_carbon_loss_g_c_per_h[plant] -= carbon;
    roots.combustion_nitrogen_loss_g_n_per_h[plant] -= nitrogen;
    roots.combustion_phosphorus_loss_g_p_per_h[plant] -= phosphorus;
    roots.root_combustion_g_c_per_h[top_root] += carbon;
}

fn domainCount(counts: []const u8, plant: usize) !u8 {
    if (plant >= counts.len or counts[plant] < 1 or counts[plant] > RootSystem.biological_domain_count)
        return error.DisturbancePlantDimensionMismatch;
    return counts[plant];
}

fn validateRootCombustion(roots: *const RootSystem.State, plant: usize, layer: usize, biological_domain_count: u8, mobile_fraction: f64, structural_fraction: f64, dynamic_salts: bool) !void {
    for (0..biological_domain_count) |domain| {
        const root = try roots.layerIndex(plant, domain, layer);
        inline for (.{ roots.mobile_carbon_g[root], roots.mobile_nitrogen_g[root], roots.mobile_phosphorus_g[root], roots.secondary_axis_count_total[root] }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidRootCombustionPool;
        for (0..roots.root_axis_count) |axis| {
            const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
            inline for (.{
                roots.axis_primary_carbon_g[axis_layer],   roots.axis_primary_nitrogen_g[axis_layer],   roots.axis_primary_phosphorus_g[axis_layer],
                roots.axis_secondary_carbon_g[axis_layer], roots.axis_secondary_nitrogen_g[axis_layer], roots.axis_secondary_phosphorus_g[axis_layer],
                roots.axis_primary_length_m[axis_layer],   roots.axis_secondary_length_m[axis_layer],   roots.axis_primary_count[axis_layer],
                roots.axis_secondary_count[axis_layer],
            }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootCombustionPool;
        }
        if (dynamic_salts) for (0..RootSystem.salt_species_count) |salt| {
            const index = root * RootSystem.salt_species_count + salt;
            if (!std.math.isFinite(roots.salt_content_mol[index]) or roots.salt_content_mol[index] < 0) return error.InvalidRootCombustionPool;
        };
    }
    inline for (.{ mobile_fraction, structural_fraction }) |fraction|
        if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidRootSymbiontCombustionFraction;
}

fn state_updateRootCombustion(roots: *RootSystem.State, plant: usize, layer: usize, biological_domain_count: u8, mobile_fraction: f64, structural_fraction: f64, dynamic_salts: bool) void {
    var emitted_c: f64 = 0;
    var emitted_n: f64 = 0;
    var emitted_p: f64 = 0;
    for (0..biological_domain_count) |domain| {
        const root = roots.layerIndex(plant, domain, layer) catch unreachable;
        var domain_emitted_c: f64 = 0;
        inline for (.{ "carbon", "nitrogen", "phosphorus" }) |element| {
            const field_name = "mobile_" ++ element ++ "_g";
            const burned = @field(roots, field_name)[root] * mobile_fraction;
            @field(roots, field_name)[root] -= burned;
            if (comptime std.mem.eql(u8, element, "carbon")) {
                emitted_c += burned;
                domain_emitted_c += burned;
            } else if (comptime std.mem.eql(u8, element, "nitrogen")) emitted_n += burned else emitted_p += burned;
        }
        for (0..roots.root_axis_count) |axis| {
            const axis_layer = roots.layerAxisIndex(plant, domain, layer, axis) catch unreachable;
            inline for (.{ "primary", "secondary" }) |order| {
                inline for (.{ "carbon", "nitrogen", "phosphorus" }) |element| {
                    const field_name = "axis_" ++ order ++ "_" ++ element ++ "_g";
                    const burned = @field(roots, field_name)[axis_layer] * structural_fraction;
                    @field(roots, field_name)[axis_layer] -= burned;
                    if (comptime std.mem.eql(u8, element, "carbon")) {
                        emitted_c += burned;
                        domain_emitted_c += burned;
                    } else if (comptime std.mem.eql(u8, element, "nitrogen")) emitted_n += burned else emitted_p += burned;
                }
                @field(roots, "axis_" ++ order ++ "_length_m")[axis_layer] *= 1 - structural_fraction;
                @field(roots, "axis_" ++ order ++ "_count")[axis_layer] *= 1 - structural_fraction;
            }
        }
        roots.secondary_axis_count_total[root] *= 1 - structural_fraction;
        if (dynamic_salts) for (0..RootSystem.salt_species_count) |salt| {
            const index = root * RootSystem.salt_species_count + salt;
            const burned = roots.salt_content_mol[index] * mobile_fraction;
            roots.salt_content_mol[index] -= burned;
            roots.combustion_salt_loss_mol_per_h[index] += burned;
        };
        roots.root_combustion_g_c_per_h[root] += domain_emitted_c;
    }
    roots.combustion_carbon_loss_g_c_per_h[plant] -= emitted_c;
    roots.combustion_nitrogen_loss_g_n_per_h[plant] -= emitted_n;
    roots.combustion_phosphorus_loss_g_p_per_h[plant] -= emitted_p;
}

fn combustionResult(roots: *const RootSystem.State, root: usize, structural_fraction: f64, mobile_fraction: f64) !RootDisturbance.CombustionResult {
    return RootDisturbance.combustSymbiont(
        .{ .carbon_g_c = roots.symbiont_structural_carbon_g_c[root], .nitrogen_g_n = roots.symbiont_structural_nitrogen_g_n[root], .phosphorus_g_p = roots.symbiont_structural_phosphorus_g_p[root] },
        .{ .carbon_g_c = roots.symbiont_mobile_carbon_g_c[root], .nitrogen_g_n = roots.symbiont_mobile_nitrogen_g_n[root], .phosphorus_g_p = roots.symbiont_mobile_phosphorus_g_p[root] },
        structural_fraction,
        mobile_fraction,
    );
}

fn calculateLayer(roots: *const RootSystem.State, root: usize, retention: RootDisturbance.ElementRetention, fine: LitterPartition.ElementFractions, mobile: LitterPartition.ElementFractions) !RootDisturbance.Result {
    return RootDisturbance.retainAndRelease(
        .{ .carbon_g_c = roots.symbiont_structural_carbon_g_c[root], .nitrogen_g_n = roots.symbiont_structural_nitrogen_g_n[root], .phosphorus_g_p = roots.symbiont_structural_phosphorus_g_p[root] },
        .{ .carbon_g_c = roots.symbiont_mobile_carbon_g_c[root], .nitrogen_g_n = roots.symbiont_mobile_nitrogen_g_n[root], .phosphorus_g_p = roots.symbiont_mobile_phosphorus_g_p[root] },
        retention,
        fine,
        mobile,
    );
}

test "runtime disturbance map resolves schedules and case-insensitive no" {
    var assignments = try land_management.fromUnits(std.testing.allocator, &.{ .{ .fertilizer_file = "NO", .irrigation_file = "NO", .tillage_file = "annual" }, .{ .fertilizer_file = "NO", .irrigation_file = "NO", .tillage_file = "nO" } });
    defer assignments.deinit();
    const unit_map = try assignments.buildCellUnitMap(std.testing.allocator);
    defer std.testing.allocator.free(unit_map);
    var catalog = disturbance.Catalog.init(std.testing.allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("annual", "01010000,10,0.15\n");
    var map = try ScheduleMap.init(std.testing.allocator, assignments, unit_map, catalog);
    defer map.deinit();
    try std.testing.expectEqual(@as(?usize, 0), map.catalog_index_by_cell[0]);
    try std.testing.expectEqual(@as(?usize, null), map.catalog_index_by_cell[1]);
}

test "disturbance dispatch date preserves DAY modulo-four chronology" {
    try validateDispatchDate(.{ .day = 29, .month = 2, .year = 1900 });
    try validateDispatchDate(.{ .day = 1, .month = 3, .year = 1900 });
    try validateDispatchDate(.{ .day = 30, .month = 3, .year = 1900 });
    try std.testing.expectError(error.InvalidDisturbanceDispatchDate, validateDispatchDate(.{ .day = 0, .month = 1, .year = 1900 }));
    try std.testing.expectError(
        error.InvalidDisturbanceDispatchDate,
        validateDispatchDate(.{ .day = 1, .month = 1, .year = 0 }),
    );
}

test "GROSUB disturbance timing follows each cell weather-grid solar noon" {
    const solar_noon_by_cell = [_]u8{ 11, 14 };
    try std.testing.expect(try isApplicationHour(11, &solar_noon_by_cell, 0));
    try std.testing.expect(!(try isApplicationHour(11, &solar_noon_by_cell, 1)));
    try std.testing.expect(!(try isApplicationHour(14, &solar_noon_by_cell, 0)));
    try std.testing.expect(try isApplicationHour(14, &solar_noon_by_cell, 1));
    try std.testing.expectError(error.InvalidHourlyDisturbanceSchedule, isApplicationHour(0, &solar_noon_by_cell, 0));
    try std.testing.expectError(error.InvalidHourlyDisturbanceSchedule, isApplicationHour(25, &solar_noon_by_cell, 0));
    try std.testing.expectError(error.DisturbanceSolarNoonDimensionMismatch, isApplicationHour(11, &solar_noon_by_cell, 2));
    try std.testing.expectError(error.InvalidHourlyDisturbanceSchedule, isApplicationHour(11, &.{25}, 0));
}

test "disturbance source clock maps weather midnight to legacy hour twenty four" {
    try std.testing.expectEqual(
        @as(u8, 24),
        try sourceHourOneThroughTwentyFour(0),
    );
    try std.testing.expectEqual(
        @as(u8, 12),
        try sourceHourOneThroughTwentyFour(12),
    );
    try std.testing.expectError(
        error.InvalidHourlyDisturbanceSchedule,
        sourceHourOneThroughTwentyFour(24),
    );
}

test "GROSUB fire combustion conserves runtime species nodule C N P" {
    const SimulationConfig = @import("../core/config.zig").SimulationConfig;
    const cfg = try SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 7 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 10 },
    );
    var grid = try Grid.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 500;
    var roots = try RootSystem.State.init(std.testing.allocator, 7, 1, 1);
    defer roots.deinit();
    var canopy = try Canopy.State.init(std.testing.allocator, 1, 7, &([_]usize{1} ** 7), &([_]usize{1} ** 7), &([_]usize{1} ** 7));
    defer canopy.deinit();
    var initial_c: f64 = 0;
    var initial_n: f64 = 0;
    var initial_p: f64 = 0;
    var initial_salt_mol: f64 = 0;
    for (0..7) |plant| {
        const root = try roots.layerIndex(plant, 0, 0);
        const scale: f64 = @floatFromInt(plant + 1);
        roots.symbiont_structural_carbon_g_c[root] = 2 * scale;
        roots.symbiont_structural_nitrogen_g_n[root] = 0.2 * scale;
        roots.symbiont_structural_phosphorus_g_p[root] = 0.02 * scale;
        roots.symbiont_mobile_carbon_g_c[root] = scale;
        roots.symbiont_mobile_nitrogen_g_n[root] = 0.1 * scale;
        roots.symbiont_mobile_phosphorus_g_p[root] = 0.01 * scale;
        initial_c += 3 * scale;
        initial_n += 0.3 * scale;
        initial_p += 0.03 * scale;
        canopy.plant_seed_storage_carbon_g[plant] = 0.4 * scale;
        canopy.plant_seed_storage_nitrogen_g[plant] = 0.04 * scale;
        canopy.plant_seed_storage_phosphorus_g[plant] = 0.004 * scale;
        initial_c += 0.4 * scale;
        initial_n += 0.04 * scale;
        initial_p += 0.004 * scale;
        for (0..RootSystem.biological_domain_count) |domain| {
            const domain_root = try roots.layerIndex(plant, domain, 0);
            const axis_layer = try roots.layerAxisIndex(plant, domain, 0, 0);
            roots.mobile_carbon_g[domain_root] = 0.5 * scale;
            roots.mobile_nitrogen_g[domain_root] = 0.05 * scale;
            roots.mobile_phosphorus_g[domain_root] = 0.005 * scale;
            roots.axis_primary_carbon_g[axis_layer] = scale;
            roots.axis_primary_nitrogen_g[axis_layer] = 0.1 * scale;
            roots.axis_primary_phosphorus_g[axis_layer] = 0.01 * scale;
            roots.axis_secondary_carbon_g[axis_layer] = 0.25 * scale;
            roots.axis_secondary_nitrogen_g[axis_layer] = 0.025 * scale;
            roots.axis_secondary_phosphorus_g[axis_layer] = 0.0025 * scale;
            roots.axis_primary_length_m[axis_layer] = scale;
            roots.axis_secondary_length_m[axis_layer] = 2 * scale;
            roots.axis_primary_count[axis_layer] = scale;
            roots.axis_secondary_count[axis_layer] = 2 * scale;
            initial_c += 1.75 * scale;
            initial_n += 0.175 * scale;
            initial_p += 0.0175 * scale;
            for (0..RootSystem.salt_species_count) |salt| {
                const amount = 0.001 * scale * @as(f64, @floatFromInt(salt + 1));
                roots.salt_content_mol[domain_root * RootSystem.salt_species_count + salt] = amount;
                initial_salt_mol += amount;
            }
        }
    }
    var fire_exchange = try OrganicMatterFireExchange.State.init(std.testing.allocator, grid.layer_count, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    var biological_domain_counts = [_]u8{2} ** 7;
    biological_domain_counts[0] = 1;
    try applyRootFireCombustion(&roots, &canopy, &grid, 7, &biological_domain_counts, &.{0.01}, &.{true}, 1, &.{true}, RootDisturbance.sourceCombustionParameters(), &fire_exchange);
    var remaining_c: f64 = 0;
    var remaining_n: f64 = 0;
    var remaining_p: f64 = 0;
    var emitted_c: f64 = 0;
    var emitted_n: f64 = 0;
    var emitted_p: f64 = 0;
    var remaining_salt_mol: f64 = 0;
    var emitted_salt_mol: f64 = 0;
    for (0..7) |plant| {
        const root = try roots.layerIndex(plant, 0, 0);
        remaining_c += roots.symbiont_structural_carbon_g_c[root] + roots.symbiont_mobile_carbon_g_c[root];
        remaining_n += roots.symbiont_structural_nitrogen_g_n[root] + roots.symbiont_mobile_nitrogen_g_n[root];
        remaining_p += roots.symbiont_structural_phosphorus_g_p[root] + roots.symbiont_mobile_phosphorus_g_p[root];
        remaining_c += canopy.plant_seed_storage_carbon_g[plant];
        remaining_n += canopy.plant_seed_storage_nitrogen_g[plant];
        remaining_p += canopy.plant_seed_storage_phosphorus_g[plant];
        for (0..RootSystem.biological_domain_count) |domain| {
            const domain_root = try roots.layerIndex(plant, domain, 0);
            const axis_layer = try roots.layerAxisIndex(plant, domain, 0, 0);
            remaining_c += roots.mobile_carbon_g[domain_root] + roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer];
            remaining_n += roots.mobile_nitrogen_g[domain_root] + roots.axis_primary_nitrogen_g[axis_layer] + roots.axis_secondary_nitrogen_g[axis_layer];
            remaining_p += roots.mobile_phosphorus_g[domain_root] + roots.axis_primary_phosphorus_g[axis_layer] + roots.axis_secondary_phosphorus_g[axis_layer];
            if (plant == 0 and domain == 1)
                try std.testing.expectEqual(@as(f64, 1), roots.axis_primary_length_m[axis_layer])
            else
                try std.testing.expect(roots.axis_primary_length_m[axis_layer] < @as(f64, @floatFromInt(plant + 1)));
            for (0..RootSystem.salt_species_count) |salt| {
                const salt_index = domain_root * RootSystem.salt_species_count + salt;
                remaining_salt_mol += roots.salt_content_mol[salt_index];
                emitted_salt_mol += roots.combustion_salt_loss_mol_per_h[salt_index];
            }
        }
        emitted_c -= roots.combustion_carbon_loss_g_c_per_h[plant];
        emitted_n -= roots.combustion_nitrogen_loss_g_n_per_h[plant];
        emitted_p -= roots.combustion_phosphorus_loss_g_p_per_h[plant];
        var root_emitted_c: f64 = 0;
        for (0..RootSystem.biological_domain_count) |domain| root_emitted_c += roots.root_combustion_g_c_per_h[try roots.layerIndex(plant, domain, 0)];
        try std.testing.expectApproxEqAbs(-roots.combustion_carbon_loss_g_c_per_h[plant], roots.symbiont_combustion_g_c_per_h[root] + root_emitted_c, 1e-12);
    }
    try std.testing.expectApproxEqAbs(initial_c, remaining_c + emitted_c, 1e-12);
    try std.testing.expectApproxEqAbs(initial_n, remaining_n + emitted_n, 1e-12);
    try std.testing.expectApproxEqAbs(initial_p, remaining_p + emitted_p, 1e-12);
    try std.testing.expectApproxEqAbs(initial_salt_mol, remaining_salt_mol + emitted_salt_mol, 1e-12);
    try std.testing.expectApproxEqAbs(emitted_c, fire_exchange.unlimited_combustion_carbon_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(emitted_n, fire_exchange.combusted_nitrogen_g_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(emitted_p, fire_exchange.combusted_phosphorus_g_p[0], 1e-12);
    var ledger_salt_mol: f64 = 0;
    for (0..OrganicMatterFireExchange.salt_species_count) |salt| ledger_salt_mol += fire_exchange.released_salt_mol[salt];
    try std.testing.expectApproxEqAbs(emitted_salt_mol, ledger_salt_mol, 1e-12);
}

test "GROSUB tillage removes runtime host and mycorrhizal roots conservatively" {
    var roots = try RootSystem.State.init(std.testing.allocator, 1, 1, 2);
    defer roots.deinit();
    roots.active_root_axis_count[0] = 2;
    var structural = [3]f64{ 0, 0, 0 };
    var mobile_pool = [3]f64{ 0, 0, 0 };
    for (0..RootSystem.biological_domain_count) |domain| {
        const root = try roots.layerIndex(0, domain, 0);
        roots.mobile_carbon_g[root] = 4 + @as(f64, @floatFromInt(domain));
        roots.mobile_nitrogen_g[root] = 2 + @as(f64, @floatFromInt(domain));
        roots.mobile_phosphorus_g[root] = 1 + @as(f64, @floatFromInt(domain));
        roots.protein_carbon_g[root] = 3;
        roots.secondary_axis_count_total[root] = 9 + @as(f64, @floatFromInt(domain));
        mobile_pool[0] += roots.mobile_carbon_g[root];
        mobile_pool[1] += roots.mobile_nitrogen_g[root];
        mobile_pool[2] += roots.mobile_phosphorus_g[root];
        for (0..2) |axis| {
            const index = try roots.layerAxisIndex(0, domain, 0, axis);
            const scale = @as(f64, @floatFromInt(1 + domain + axis));
            roots.axis_primary_carbon_g[index] = 2 * scale;
            roots.axis_secondary_carbon_g[index] = scale;
            roots.axis_primary_nitrogen_g[index] = scale;
            roots.axis_secondary_nitrogen_g[index] = 0.5 * scale;
            roots.axis_primary_phosphorus_g[index] = 0.2 * scale;
            roots.axis_secondary_phosphorus_g[index] = 0.1 * scale;
            roots.axis_primary_length_m[index] = 10 * scale;
            roots.axis_secondary_length_m[index] = 5 * scale;
            roots.axis_primary_count[index] = scale;
            roots.axis_secondary_count[index] = 2 * scale;
            structural[0] += 3 * scale;
            structural[1] += 1.5 * scale;
            structural[2] += 0.3 * scale;
        }
    }
    const first = LitterPartition.ElementFractions{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const second = LitterPartition.ElementFractions{
        .carbon = .{ 0, 1, 0, 0 },
        .nitrogen = .{ 0, 1, 0, 0 },
        .phosphorus = .{ 0, 1, 0, 0 },
    };
    const third = LitterPartition.ElementFractions{
        .carbon = .{ 0, 0, 1, 0 },
        .nitrogen = .{ 0, 0, 1, 0 },
        .phosphorus = .{ 0, 0, 1, 0 },
    };
    const removed_fraction = 0.25;
    const nonwoody_fraction = 0.4;
    const litter = try calculateHostRootTillage(
        &roots,
        0,
        0,
        RootSystem.biological_domain_count,
        removed_fraction,
        nonwoody_fraction,
        first,
        second,
        third,
    );
    const domain_zero_litter = try calculateHostRootTillageDomain(&roots, 0, 0, 0, removed_fraction, nonwoody_fraction, first, second, third);
    const domain_one_litter = try calculateHostRootTillageDomain(&roots, 0, 1, 0, removed_fraction, nonwoody_fraction, first, second, third);
    try std.testing.expectApproxEqAbs(
        try RootLitterLedger.totalCarbon(litter),
        try RootLitterLedger.totalCarbon(domain_zero_litter) +
            try RootLitterLedger.totalCarbon(domain_one_litter),
        1e-12,
    );
    try std.testing.expectApproxEqAbs(removed_fraction * structural[0] * (1 - nonwoody_fraction), litter.woody_carbon_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(removed_fraction * structural[0] * nonwoody_fraction, litter.nonwoody_carbon_g_c[1], 1e-12);
    try std.testing.expectApproxEqAbs(removed_fraction * mobile_pool[0], litter.nonwoody_carbon_g_c[2], 1e-12);
    try std.testing.expectApproxEqAbs(removed_fraction * (structural[1] + mobile_pool[1]), sumElement(litter.woody_nitrogen_g_n) + sumElement(litter.nonwoody_nitrogen_g_n), 1e-12);
    try std.testing.expectApproxEqAbs(removed_fraction * (structural[2] + mobile_pool[2]), sumElement(litter.woody_phosphorus_g_p) + sumElement(litter.nonwoody_phosphorus_g_p), 1e-12);

    try state_updateHostRootTillage(&roots, 0, 0, RootSystem.biological_domain_count, removed_fraction);
    const retained = 1 - removed_fraction;
    const first_root = try roots.layerIndex(0, 0, 0);
    const first_axis = try roots.layerAxisIndex(0, 0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 4) * retained, roots.mobile_carbon_g[first_root], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2) * retained, roots.axis_primary_carbon_g[first_axis], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10) * retained, roots.axis_primary_length_m[first_axis], 1e-12);
    try std.testing.expectApproxEqAbs(retained, roots.axis_primary_count[first_axis], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 9) * retained, roots.secondary_axis_count_total[first_root], 1e-12);
}

fn sumElement(values: [LitterPartition.kinetic_component_count]f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total;
}
