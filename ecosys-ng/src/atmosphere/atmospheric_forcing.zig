const std = @import("std");
const compute = @import("../core/compute.zig");
const CellRange = compute.CellRange;
const spatial_grid = @import("../state/spatial_grid.zig");
const HourlyForcing = @import("../io/input/weather.zig").HourlyForcing;

/// Heap-backed structure-of-arrays boundary between streamed weather and
/// per-cell surface/canopy kernels.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    air_temperature_k: []f64,
    vapor_pressure_kpa: []f64,
    precipitation_m: []f64,
    rainfall_m: []f64,
    snowfall_water_equivalent_m: []f64,
    shortwave_radiation_megajoules_per_m2: []f64,
    wind_speed_m_per_h: []f64,
    longwave_radiation_megajoules_per_m2: []f64,
    longwave_is_observed: []bool,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.EmptyGrid;
        var result: State = .{
            .allocator = allocator,
            .cell_count = cell_count,
            .air_temperature_k = try allocator.alloc(f64, cell_count),
            .vapor_pressure_kpa = undefined,
            .precipitation_m = undefined,
            .rainfall_m = undefined,
            .snowfall_water_equivalent_m = undefined,
            .shortwave_radiation_megajoules_per_m2 = undefined,
            .wind_speed_m_per_h = undefined,
            .longwave_radiation_megajoules_per_m2 = undefined,
            .longwave_is_observed = undefined,
        };
        errdefer allocator.free(result.air_temperature_k);
        result.vapor_pressure_kpa = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.vapor_pressure_kpa);
        result.precipitation_m = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.precipitation_m);
        result.rainfall_m = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.rainfall_m);
        result.snowfall_water_equivalent_m = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.snowfall_water_equivalent_m);
        result.shortwave_radiation_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.shortwave_radiation_megajoules_per_m2);
        result.wind_speed_m_per_h = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.wind_speed_m_per_h);
        result.longwave_radiation_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.longwave_radiation_megajoules_per_m2);
        result.longwave_is_observed = try allocator.alloc(bool, cell_count);
        @memset(result.air_temperature_k, 273.15);
        @memset(result.vapor_pressure_kpa, 0);
        @memset(result.precipitation_m, 0);
        @memset(result.rainfall_m, 0);
        @memset(result.snowfall_water_equivalent_m, 0);
        @memset(result.shortwave_radiation_megajoules_per_m2, 0);
        @memset(result.wind_speed_m_per_h, 0);
        @memset(result.longwave_radiation_megajoules_per_m2, 0);
        @memset(result.longwave_is_observed, false);
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.longwave_is_observed);
        self.allocator.free(self.longwave_radiation_megajoules_per_m2);
        self.allocator.free(self.wind_speed_m_per_h);
        self.allocator.free(self.shortwave_radiation_megajoules_per_m2);
        self.allocator.free(self.precipitation_m);
        self.allocator.free(self.snowfall_water_equivalent_m);
        self.allocator.free(self.rainfall_m);
        self.allocator.free(self.vapor_pressure_kpa);
        self.allocator.free(self.air_temperature_k);
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            for (@field(self, field.name), 0..) |value, index| if (!std.math.isFinite(value)) {
                std.log.err("non-finite atmospheric state: field={s} cell={d} value={e}", .{ field.name, index, value });
                return error.NonFiniteAtmosphericState;
            };
        };
    }
};

pub const ApplyContext = struct { state: *State, forcing: HourlyForcing };
pub const MappedApplyContext = struct {
    state: *State,
    forcing_by_cell: []const HourlyForcing,
};

/// Independent cell tile; suitable for the CPU executor and a future GPU
/// dispatch because it performs no allocation, file I/O, or synchronization.
pub fn applyUniformTile(context: *ApplyContext, range: CellRange) !void {
    const forcing = context.forcing;
    inline for (@typeInfo(HourlyForcing).@"struct".fields) |field| if (field.type == f64) {
        if (!std.math.isFinite(@field(forcing, field.name))) return error.NonFiniteWeatherForcing;
    };
    if (forcing.air_temperature_c < -273.15 or forcing.vapor_pressure_kpa < 0 or forcing.precipitation_m < 0 or forcing.rainfall_m < 0 or forcing.snowfall_water_equivalent_m < 0 or @abs(forcing.precipitation_m - forcing.rainfall_m - forcing.snowfall_water_equivalent_m) > 1.0e-12 or forcing.shortwave_radiation_megajoules_per_m2 < 0 or forcing.wind_speed_m_per_h < 0) return error.InvalidWeatherForcing;
    if (range.end > context.state.cell_count) return error.AtmosphericTileOutOfBounds;
    for (range.first..range.end) |cell| {
        context.state.air_temperature_k[cell] = forcing.air_temperature_c + 273.15;
        context.state.vapor_pressure_kpa[cell] = forcing.vapor_pressure_kpa;
        context.state.precipitation_m[cell] = forcing.precipitation_m;
        context.state.rainfall_m[cell] = forcing.rainfall_m;
        context.state.snowfall_water_equivalent_m[cell] = forcing.snowfall_water_equivalent_m;
        context.state.shortwave_radiation_megajoules_per_m2[cell] = forcing.shortwave_radiation_megajoules_per_m2;
        context.state.wind_speed_m_per_h[cell] = forcing.wind_speed_m_per_h;
        context.state.longwave_is_observed[cell] = forcing.longwave_radiation_megajoules_per_m2 != null;
        context.state.longwave_radiation_megajoules_per_m2[cell] = forcing.longwave_radiation_megajoules_per_m2 orelse 0;
    }
}

pub fn applyMappedTile(context: *MappedApplyContext, range: CellRange) !void {
    if (context.forcing_by_cell.len != context.state.cell_count or
        range.end > context.state.cell_count) return error.AtmosphericTileOutOfBounds;
    for (range.first..range.end) |cell| {
        const forcing = context.forcing_by_cell[cell];
        inline for (@typeInfo(HourlyForcing).@"struct".fields) |field| {
            if (field.type == f64 and !std.math.isFinite(@field(forcing, field.name)))
                return error.NonFiniteWeatherForcing;
        }
        if (forcing.air_temperature_c < -273.15 or forcing.vapor_pressure_kpa < 0 or forcing.precipitation_m < 0 or forcing.rainfall_m < 0 or forcing.snowfall_water_equivalent_m < 0 or @abs(forcing.precipitation_m - forcing.rainfall_m - forcing.snowfall_water_equivalent_m) > 1.0e-12 or forcing.shortwave_radiation_megajoules_per_m2 < 0 or forcing.wind_speed_m_per_h < 0) return error.InvalidWeatherForcing;
        context.state.air_temperature_k[cell] = forcing.air_temperature_c + 273.15;
        context.state.vapor_pressure_kpa[cell] = forcing.vapor_pressure_kpa;
        context.state.precipitation_m[cell] = forcing.precipitation_m;
        context.state.rainfall_m[cell] = forcing.rainfall_m;
        context.state.snowfall_water_equivalent_m[cell] = forcing.snowfall_water_equivalent_m;
        context.state.shortwave_radiation_megajoules_per_m2[cell] = forcing.shortwave_radiation_megajoules_per_m2;
        context.state.wind_speed_m_per_h[cell] = forcing.wind_speed_m_per_h;
        context.state.longwave_is_observed[cell] = forcing.longwave_radiation_megajoules_per_m2 != null;
        context.state.longwave_radiation_megajoules_per_m2[cell] = forcing.longwave_radiation_megajoules_per_m2 orelse 0;
    }
}

test "serial tiles apply forcing with owned-cell parallelism across runtime grid" {
    const allocator = std.testing.allocator;
    var state = try State.init(allocator, 10_003);
    defer state.deinit();
    var context = ApplyContext{ .state = &state, .forcing = .{
        .air_temperature_c = 12.5,
        .vapor_pressure_kpa = 1.2,
        .precipitation_m = 0.003,
        .rainfall_m = 0.003,
        .shortwave_radiation_megajoules_per_m2 = 0.7,
        .wind_speed_m_per_h = 3600,
        .longwave_radiation_megajoules_per_m2 = null,
    } };
    var plan = try spatial_grid.TilePlan.init(allocator, 1, state.cell_count, 1, 113, 2);
    defer plan.deinit();
    const executor = try compute.CpuExecutor.init(allocator, 7, plan.ownedCellExecutorPlan());
    defer executor.deinit();
    for (plan.tiles, 0..) |_, tile_index|
        try executor.runOwnedCells(try plan.ownedCellTile(tile_index), &context, applyUniformTile);
    try state.validateFinite();
    try std.testing.expectEqual(@as(f64, 285.65), state.air_temperature_k[10_002]);
    try std.testing.expect(!state.longwave_is_observed[10_002]);
}

test "mapped forcing preserves distinct weather for adjacent cells" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    const forcing = [_]HourlyForcing{
        .{ .air_temperature_c = 1, .vapor_pressure_kpa = 0.5, .precipitation_m = 0, .shortwave_radiation_megajoules_per_m2 = 0, .wind_speed_m_per_h = 100, .longwave_radiation_megajoules_per_m2 = null },
        .{ .air_temperature_c = 20, .vapor_pressure_kpa = 2, .precipitation_m = 0.001, .rainfall_m = 0.001, .shortwave_radiation_megajoules_per_m2 = 1, .wind_speed_m_per_h = 500, .longwave_radiation_megajoules_per_m2 = null },
    };
    var context = MappedApplyContext{ .state = &state, .forcing_by_cell = &forcing };
    try applyMappedTile(&context, .{ .first = 0, .end = 2 });
    try std.testing.expectEqual(@as(f64, 274.15), state.air_temperature_k[0]);
    try std.testing.expectEqual(@as(f64, 293.15), state.air_temperature_k[1]);
    try std.testing.expectEqual(@as(f64, 0.001), state.rainfall_m[1]);
}
