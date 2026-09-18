const std = @import("std");
const grid = @import("../../state/grid.zig");

/// Runtime-sized OUTSD THRE ledger. The legacy sign is retained: net
/// microbial gas uptake is positive and net production is negative.
pub const State = struct {
    allocator: std.mem.Allocator,
    surface_hourly_signed_g_c: []f64,
    soil_hourly_signed_g_c: []f64,
    surface_hourly_carbon_dioxide_production_g_c: []f64,
    soil_hourly_carbon_dioxide_production_g_c: []f64,
    daily_signed_g_c: []f64,
    daily_carbon_dioxide_production_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_count: usize) !State {
        const surface = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(surface);
        const soil = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(soil);
        const surface_production = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(surface_production);
        const soil_production = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(soil_production);
        const daily = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(daily);
        const daily_production = try allocator.alloc(f64, cell_count);
        @memset(surface, 0);
        @memset(soil, 0);
        @memset(surface_production, 0);
        @memset(soil_production, 0);
        @memset(daily, 0);
        @memset(daily_production, 0);
        return .{ .allocator = allocator, .surface_hourly_signed_g_c = surface, .soil_hourly_signed_g_c = soil, .surface_hourly_carbon_dioxide_production_g_c = surface_production, .soil_hourly_carbon_dioxide_production_g_c = soil_production, .daily_signed_g_c = daily, .daily_carbon_dioxide_production_g_c = daily_production };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.surface_hourly_signed_g_c);
        self.allocator.free(self.soil_hourly_signed_g_c);
        self.allocator.free(self.daily_carbon_dioxide_production_g_c);
        self.allocator.free(self.daily_signed_g_c);
        self.allocator.free(self.soil_hourly_carbon_dioxide_production_g_c);
        self.allocator.free(self.surface_hourly_carbon_dioxide_production_g_c);
        self.* = undefined;
    }

    pub fn resetDaily(self: *State) void {
        @memset(self.daily_signed_g_c, 0);
        @memset(self.daily_carbon_dioxide_production_g_c, 0);
    }

    pub fn accumulateHour(self: *State, model_grid: *const grid.GridState) !void {
        if (self.surface_hourly_signed_g_c.len != model_grid.cell_count or self.soil_hourly_signed_g_c.len != model_grid.layer_count or self.daily_signed_g_c.len != model_grid.cell_count)
            return error.HeterotrophicRespirationGridDimensionMismatch;
        for (0..model_grid.cell_count) |cell| {
            var signed_g_c = self.surface_hourly_signed_g_c[cell];
            var production_g_c = self.surface_hourly_carbon_dioxide_production_g_c[cell];
            for (0..model_grid.active_soil_layer_count[cell]) |layer| {
                const index = try model_grid.layerIndex(cell, layer);
                signed_g_c += self.soil_hourly_signed_g_c[index];
                production_g_c += self.soil_hourly_carbon_dioxide_production_g_c[index];
            }
            if (!std.math.isFinite(signed_g_c)) return error.NonFiniteHeterotrophicRespiration;
            if (!std.math.isFinite(production_g_c) or production_g_c < 0) return error.InvalidBiologicalCarbonDioxideProduction;
            const after = self.daily_signed_g_c[cell] + signed_g_c;
            const production_after = self.daily_carbon_dioxide_production_g_c[cell] + production_g_c;
            if (!std.math.isFinite(after) or !std.math.isFinite(production_after)) return error.NonFiniteDailyHeterotrophicRespiration;
            self.daily_signed_g_c[cell] = after;
            self.daily_carbon_dioxide_production_g_c[cell] = production_after;
        }
    }
};

test "daily ledger aggregates surface and runtime soil layers" {
    const allocator = std.testing.allocator;
    const config = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 },
    );
    var model_grid = try grid.GridState.init(allocator, config);
    defer model_grid.deinit();
    var state = try State.init(allocator, model_grid.cell_count, model_grid.layer_count);
    defer state.deinit();
    state.surface_hourly_signed_g_c[0] = -1;
    state.surface_hourly_signed_g_c[1] = 0.5;
    state.soil_hourly_signed_g_c[try model_grid.layerIndex(0, 0)] = -2;
    state.soil_hourly_signed_g_c[try model_grid.layerIndex(0, 1)] = 0.25;
    state.soil_hourly_signed_g_c[try model_grid.layerIndex(1, 0)] = -3;
    state.surface_hourly_carbon_dioxide_production_g_c[0] = 1;
    state.soil_hourly_carbon_dioxide_production_g_c[try model_grid.layerIndex(0, 1)] = 2;
    try state.accumulateHour(&model_grid);
    try std.testing.expectApproxEqAbs(@as(f64, -2.75), state.daily_signed_g_c[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -2.5), state.daily_signed_g_c[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), state.daily_carbon_dioxide_production_g_c[0], 1e-15);
}
