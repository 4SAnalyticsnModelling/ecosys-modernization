const std = @import("std");
const grid_module = @import("../../state/grid.zig");
const organic = @import("../organic/initialization.zig");
const organic_transport = @import("../organic/transport.zig");
const mineral_transport = @import("../biogeochemistry/mineral_nitrogen_transport.zig");
const dissolved_gas_transport = @import("../gas/dissolved_gas_transport.zig");
const gas = @import("../gas/transport.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    dissolved_organic_nitrogen_runoff_g_n: []f64,
    dissolved_organic_nitrogen_drainage_g_n: []f64,
    dissolved_inorganic_nitrogen_runoff_g_n: []f64,
    dissolved_inorganic_nitrogen_drainage_g_n: []f64,
    dissolved_organic_nitrogen_input_g_n: []f64,
    dissolved_inorganic_nitrogen_input_g_n: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroDailyNitrogenExportCells;
        const storage = try allocator.alloc(f64, try std.math.mul(usize, cell_count, 6));
        @memset(storage, 0);
        return .{
            .allocator = allocator,
            .dissolved_organic_nitrogen_runoff_g_n = storage[0 * cell_count .. 1 * cell_count],
            .dissolved_organic_nitrogen_drainage_g_n = storage[1 * cell_count .. 2 * cell_count],
            .dissolved_inorganic_nitrogen_runoff_g_n = storage[2 * cell_count .. 3 * cell_count],
            .dissolved_inorganic_nitrogen_drainage_g_n = storage[3 * cell_count .. 4 * cell_count],
            .dissolved_organic_nitrogen_input_g_n = storage[4 * cell_count .. 5 * cell_count],
            .dissolved_inorganic_nitrogen_input_g_n = storage[5 * cell_count .. 6 * cell_count],
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.dissolved_organic_nitrogen_runoff_g_n.ptr[0 .. self.dissolved_organic_nitrogen_runoff_g_n.len * 6]);
        self.* = undefined;
    }

    pub fn resetDaily(self: *State) void {
        @memset(self.dissolved_organic_nitrogen_runoff_g_n.ptr[0 .. self.dissolved_organic_nitrogen_runoff_g_n.len * 6], 0);
    }

    pub fn accumulateOrganicDrainageHour(self: *State, model_grid: *const grid_module.GridState, transport: *const organic_transport.State) !void {
        if (self.dissolved_organic_nitrogen_drainage_g_n.len != model_grid.cell_count or transport.layer_count != model_grid.layer_count) return error.DailyNitrogenExportDimensionMismatch;
        for (0..model_grid.cell_count) |cell| {
            var inward_g_n: f64 = 0;
            var outward_g_n: f64 = 0;
            for (0..model_grid.active_soil_layer_count[cell]) |local_layer| {
                const layer = try model_grid.layerIndex(cell, local_layer);
                for (0..organic.substrate_count) |substrate| {
                    const base = layer * organic_transport.component_count + substrate * organic_transport.components_per_substrate;
                    const flux = transport.boundary_net_flux_g[base + @intFromEnum(organic_transport.Component.dissolved_organic_nitrogen)];
                    inward_g_n += @max(0, flux);
                    outward_g_n += @max(0, -flux);
                }
            }
            try add(&self.dissolved_organic_nitrogen_input_g_n[cell], inward_g_n);
            try add(&self.dissolved_organic_nitrogen_drainage_g_n[cell], outward_g_n);
        }
    }

    pub fn accumulateInorganicDrainageHour(self: *State, model_grid: *const grid_module.GridState, transport: *const mineral_transport.State) !void {
        if (transport.cell_count != model_grid.layer_count or self.dissolved_inorganic_nitrogen_drainage_g_n.len != model_grid.cell_count) return error.DailyNitrogenExportDimensionMismatch;
        for (0..model_grid.cell_count) |cell| {
            var outward_g_n: f64 = 0;
            for (0..model_grid.active_soil_layer_count[cell]) |local_layer| outward_g_n += transport.boundary_export_g_n_per_step[try model_grid.layerIndex(cell, local_layer)];
            try add(&self.dissolved_inorganic_nitrogen_drainage_g_n[cell], outward_g_n);
        }
    }

    /// REDIST gas-owned aqueous N2/N2O carried through external profile-water
    /// boundaries. Aqueous NH3 drainage is owned by mineral-N transport.
    pub fn accumulateDissolvedGasDrainageHour(
        self: *State,
        model_grid: *const grid_module.GridState,
        transport: *const dissolved_gas_transport.State,
    ) !void {
        if (transport.layer_count != model_grid.layer_count or
            self.dissolved_inorganic_nitrogen_drainage_g_n.len != model_grid.cell_count)
            return error.DailyNitrogenExportDimensionMismatch;
        for (0..model_grid.cell_count) |cell| {
            var inward_g_n: f64 = 0;
            var outward_g_n: f64 = 0;
            var outward_by_species: [2]f64 = .{ 0, 0 };
            for (0..model_grid.active_soil_layer_count[cell]) |local_layer| {
                const layer = try model_grid.layerIndex(cell, local_layer);
                const base = layer * gas.species_count;
                inline for ([_]gas.Species{ .nitrogen, .nitrous_oxide }, 0..) |species, species_index| {
                    const flux = transport.boundary_net_flux_g[base + @intFromEnum(species)];
                    inward_g_n += @max(0, flux);
                    outward_g_n += @max(0, -flux);
                    outward_by_species[species_index] += @max(0, -flux);
                }
            }
            std.log.debug("dissolved gas nitrogen drainage: n2={e} n2o={e}", .{ outward_by_species[0], outward_by_species[1] });
            try add(&self.dissolved_inorganic_nitrogen_input_g_n[cell], inward_g_n);
            try add(&self.dissolved_inorganic_nitrogen_drainage_g_n[cell], outward_g_n);
        }
    }

    pub fn accumulateRunoffHour(self: *State, organic_outward_g_n: []const f64, inorganic_outward_g_n: []const f64) !void {
        if (organic_outward_g_n.len != self.dissolved_organic_nitrogen_runoff_g_n.len or inorganic_outward_g_n.len != self.dissolved_inorganic_nitrogen_runoff_g_n.len) return error.DailyNitrogenExportDimensionMismatch;
        for (0..organic_outward_g_n.len) |cell| {
            try add(&self.dissolved_organic_nitrogen_runoff_g_n[cell], organic_outward_g_n[cell]);
            try add(&self.dissolved_inorganic_nitrogen_runoff_g_n[cell], inorganic_outward_g_n[cell]);
        }
    }
};

fn add(total: *f64, outward: f64) !void {
    if (!std.math.isFinite(outward) or outward < 0 or !std.math.isFinite(total.* + outward)) return error.NonFiniteDailyNitrogenExport;
    total.* += outward;
}

test "UDOND and UDIND sum only outward nitrogen over runtime layers" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    var organic_state = try organic_transport.State.init(std.testing.allocator, model_grid.layer_count);
    defer organic_state.deinit();
    organic_state.boundary_net_flux_g[@intFromEnum(organic_transport.Component.dissolved_organic_nitrogen)] = -2;
    organic_state.boundary_net_flux_g[organic_transport.components_per_substrate + @intFromEnum(organic_transport.Component.dissolved_organic_nitrogen)] = 1;
    var mineral = try mineral_transport.State.init(std.testing.allocator, model_grid.layer_count);
    defer mineral.deinit();
    mineral.boundary_export_g_n_per_step[1] = 3;
    var daily = try State.init(std.testing.allocator, 1);
    defer daily.deinit();
    try daily.accumulateOrganicDrainageHour(&model_grid, &organic_state);
    try daily.accumulateInorganicDrainageHour(&model_grid, &mineral);
    var dissolved_gas = try dissolved_gas_transport.State.init(
        std.testing.allocator,
        model_grid.layer_count,
    );
    defer dissolved_gas.deinit();
    dissolved_gas.boundary_net_flux_g[@intFromEnum(gas.Species.nitrogen)] = -4;
    dissolved_gas.boundary_net_flux_g[@intFromEnum(gas.Species.nitrous_oxide)] = 1;
    dissolved_gas.boundary_net_flux_g[@intFromEnum(gas.Species.ammonia)] = -2;
    try daily.accumulateDissolvedGasDrainageHour(&model_grid, &dissolved_gas);
    try std.testing.expectEqual(@as(f64, 2), daily.dissolved_organic_nitrogen_drainage_g_n[0]);
    // The stale gas NH3 ledger is intentionally ignored; its canonical route
    // is already included in mineral.boundary_export_g_n_per_step.
    try std.testing.expectEqual(@as(f64, 7), daily.dissolved_inorganic_nitrogen_drainage_g_n[0]);
    try std.testing.expectEqual(@as(f64, 1), daily.dissolved_inorganic_nitrogen_input_g_n[0]);
    try std.testing.expectEqual(@as(f64, 1), daily.dissolved_organic_nitrogen_input_g_n[0]);
}
