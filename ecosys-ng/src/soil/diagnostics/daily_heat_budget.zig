const std = @import("std");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    layer_capacity: usize,
    total_radiation_megajoules_per_m2: []f64,
    maximum_air_temperature_c: []f64,
    minimum_air_temperature_c: []f64,
    maximum_vapor_pressure_kpa: []f64,
    minimum_vapor_pressure_kpa: []f64,
    cumulative_wind_distance_m: []f64,
    total_precipitation_mm: []f64,
    ionic_inflow_mol: []f64,
    ionic_outflow_mol: []f64,
    maximum_soil_temperature_c: []f64,
    minimum_soil_temperature_c: []f64,
    surface_maximum_temperature_c: []f64,
    surface_minimum_temperature_c: []f64,
    sample_count: []u8,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_capacity: usize) !State {
        if (cell_count == 0 or layer_capacity == 0) return error.ZeroDailyHeatExtent;
        const layer_count = try std.math.mul(usize, cell_count, layer_capacity);
        const scalar = try allocator.alloc(f64, try std.math.mul(usize, cell_count, 11));
        errdefer allocator.free(scalar);
        const layers = try allocator.alloc(f64, try std.math.mul(usize, layer_count, 2));
        errdefer allocator.free(layers);
        const samples = try allocator.alloc(u8, cell_count);
        var result: State = .{
            .allocator = allocator,
            .cell_count = cell_count,
            .layer_capacity = layer_capacity,
            .total_radiation_megajoules_per_m2 = scalar[0 * cell_count .. 1 * cell_count],
            .maximum_air_temperature_c = scalar[1 * cell_count .. 2 * cell_count],
            .minimum_air_temperature_c = scalar[2 * cell_count .. 3 * cell_count],
            .maximum_vapor_pressure_kpa = scalar[3 * cell_count .. 4 * cell_count],
            .minimum_vapor_pressure_kpa = scalar[4 * cell_count .. 5 * cell_count],
            .cumulative_wind_distance_m = scalar[5 * cell_count .. 6 * cell_count],
            .total_precipitation_mm = scalar[6 * cell_count .. 7 * cell_count],
            .ionic_inflow_mol = scalar[7 * cell_count .. 8 * cell_count],
            .ionic_outflow_mol = scalar[8 * cell_count .. 9 * cell_count],
            .surface_maximum_temperature_c = scalar[9 * cell_count .. 10 * cell_count],
            .surface_minimum_temperature_c = scalar[10 * cell_count .. 11 * cell_count],
            .maximum_soil_temperature_c = layers[0..layer_count],
            .minimum_soil_temperature_c = layers[layer_count..],
            .sample_count = samples,
        };
        result.reset();
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.sample_count);
        self.allocator.free(self.maximum_soil_temperature_c.ptr[0 .. self.maximum_soil_temperature_c.len * 2]);
        self.allocator.free(self.total_radiation_megajoules_per_m2.ptr[0 .. self.total_radiation_megajoules_per_m2.len * 11]);
        self.* = undefined;
    }

    pub fn reset(self: *State) void {
        @memset(self.total_radiation_megajoules_per_m2, 0);
        @memset(self.cumulative_wind_distance_m, 0);
        @memset(self.total_precipitation_mm, 0);
        @memset(self.ionic_inflow_mol, 0);
        @memset(self.ionic_outflow_mol, 0);
        @memset(self.maximum_air_temperature_c, -std.math.inf(f64));
        @memset(self.minimum_air_temperature_c, std.math.inf(f64));
        @memset(self.maximum_vapor_pressure_kpa, -std.math.inf(f64));
        @memset(self.minimum_vapor_pressure_kpa, std.math.inf(f64));
        @memset(self.surface_maximum_temperature_c, -std.math.inf(f64));
        @memset(self.surface_minimum_temperature_c, std.math.inf(f64));
        @memset(self.maximum_soil_temperature_c, -std.math.inf(f64));
        @memset(self.minimum_soil_temperature_c, std.math.inf(f64));
        @memset(self.sample_count, 0);
    }

    pub fn accumulateHour(
        self: *State,
        cell: usize,
        active_layer_count: usize,
        shortwave_radiation_megajoules_per_m2: f64,
        air_temperature_k: f64,
        vapor_pressure_kpa: f64,
        wind_speed_m_per_h: f64,
        precipitation_m: f64,
        soil_temperature_k: []const f64,
        surface_temperature_k: f64,
        ionic_boundary_inflow_mol: f64,
        ionic_boundary_outflow_mol: f64,
    ) !void {
        if (cell >= self.cell_count or active_layer_count == 0 or active_layer_count > self.layer_capacity or soil_temperature_k.len != active_layer_count) return error.DailyHeatDimensionMismatch;
        inline for (.{ shortwave_radiation_megajoules_per_m2, air_temperature_k, vapor_pressure_kpa, wind_speed_m_per_h, precipitation_m, surface_temperature_k, ionic_boundary_inflow_mol, ionic_boundary_outflow_mol }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteDailyHeatInput;
        if (shortwave_radiation_megajoules_per_m2 < 0 or air_temperature_k <= 0 or vapor_pressure_kpa < 0 or wind_speed_m_per_h < 0 or precipitation_m < 0 or ionic_boundary_inflow_mol < 0 or ionic_boundary_outflow_mol < 0) return error.InvalidDailyHeatInput;
        for (soil_temperature_k) |temperature| if (!std.math.isFinite(temperature) or temperature <= 0) return error.InvalidDailyHeatInput;
        if (self.sample_count[cell] == std.math.maxInt(u8)) return error.DailyHeatSampleCountOverflow;
        const air_c = air_temperature_k - 273.15;
        const surface_c = surface_temperature_k - 273.15;
        self.total_radiation_megajoules_per_m2[cell] = try addFinite(self.total_radiation_megajoules_per_m2[cell], shortwave_radiation_megajoules_per_m2);
        self.cumulative_wind_distance_m[cell] = try addFinite(self.cumulative_wind_distance_m[cell], wind_speed_m_per_h);
        self.total_precipitation_mm[cell] = try addFinite(self.total_precipitation_mm[cell], 1000 * precipitation_m);
        self.ionic_inflow_mol[cell] = try addFinite(self.ionic_inflow_mol[cell], ionic_boundary_inflow_mol);
        self.ionic_outflow_mol[cell] = try addFinite(self.ionic_outflow_mol[cell], ionic_boundary_outflow_mol);
        self.maximum_air_temperature_c[cell] = @max(self.maximum_air_temperature_c[cell], air_c);
        self.minimum_air_temperature_c[cell] = @min(self.minimum_air_temperature_c[cell], air_c);
        self.maximum_vapor_pressure_kpa[cell] = @max(self.maximum_vapor_pressure_kpa[cell], vapor_pressure_kpa);
        self.minimum_vapor_pressure_kpa[cell] = @min(self.minimum_vapor_pressure_kpa[cell], vapor_pressure_kpa);
        self.surface_maximum_temperature_c[cell] = @max(self.surface_maximum_temperature_c[cell], surface_c);
        self.surface_minimum_temperature_c[cell] = @min(self.surface_minimum_temperature_c[cell], surface_c);
        const first = cell * self.layer_capacity;
        for (soil_temperature_k, 0..) |temperature_k, local_layer| {
            const temperature_c = temperature_k - 273.15;
            self.maximum_soil_temperature_c[first + local_layer] = @max(self.maximum_soil_temperature_c[first + local_layer], temperature_c);
            self.minimum_soil_temperature_c[first + local_layer] = @min(self.minimum_soil_temperature_c[first + local_layer], temperature_c);
        }
        self.sample_count[cell] += 1;
    }

    pub fn validateCell(self: *const State, cell: usize) !void {
        if (cell >= self.cell_count) return error.DailyHeatCellOutOfBounds;
        if (self.sample_count[cell] == 0) return error.DailyHeatCellHasNoSamples;
    }
};

fn addFinite(current: f64, increment: f64) !f64 {
    const result = current + increment;
    if (!std.math.isFinite(result)) return error.NonFiniteDailyHeatLedger;
    return result;
}

test "daily heat ledger retains extrema and accepted hourly totals at runtime depth" {
    var state = try State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    try state.accumulateHour(0, 2, 1, 280, 1, 100, 0.028, &.{ 275, 276 }, 278, 5, 3);
    try state.accumulateHour(0, 2, 2, 290, 2, 200, 0.014, &.{ 285, 274 }, 288, 2, 1);
    try state.validateCell(0);
    try std.testing.expectEqual(@as(f64, 3), state.total_radiation_megajoules_per_m2[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 16.85), state.maximum_air_temperature_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6.85), state.minimum_air_temperature_c[0], 1e-12);
    try std.testing.expectEqual(@as(f64, 300), state.cumulative_wind_distance_m[0]);
    try std.testing.expectEqual(@as(f64, 42), state.total_precipitation_mm[0]);
    try std.testing.expectEqual(@as(f64, 7), state.ionic_inflow_mol[0]);
    try std.testing.expectEqual(@as(f64, 4), state.ionic_outflow_mol[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 11.85), state.maximum_soil_temperature_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), state.minimum_soil_temperature_c[1], 1e-12);
}
