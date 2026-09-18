const std = @import("std");
const grid_module = @import("../../state/grid.zig");
const organic_transport = @import("../organic/transport.zig");
const dissolved_gas_transport = @import("../gas/dissolved_gas_transport.zig");
const gaseous_transport = @import("../gas/transport_step.zig");
const gas = @import("../gas/transport.zig");
const solute_species = @import("../solute/transport_species.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    dissolved_organic_carbon_input_g: []f64,
    dissolved_inorganic_carbon_input_g: []f64,
    dissolved_organic_carbon_runoff_g: []f64,
    dissolved_inorganic_carbon_runoff_g: []f64,
    dissolved_organic_carbon_drainage_g: []f64,
    dissolved_inorganic_carbon_drainage_g: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroDailyCarbonExportCells;
        const doc_runoff = try zeroes(allocator, cell_count);
        errdefer allocator.free(doc_runoff);
        const doc_input = try zeroes(allocator, cell_count);
        errdefer allocator.free(doc_input);
        const dic_input = try zeroes(allocator, cell_count);
        errdefer allocator.free(dic_input);
        const dic_runoff = try zeroes(allocator, cell_count);
        errdefer allocator.free(dic_runoff);
        const doc_drainage = try zeroes(allocator, cell_count);
        errdefer allocator.free(doc_drainage);
        const dic_drainage = try zeroes(allocator, cell_count);
        return .{
            .allocator = allocator,
            .dissolved_organic_carbon_input_g = doc_input,
            .dissolved_inorganic_carbon_input_g = dic_input,
            .dissolved_organic_carbon_runoff_g = doc_runoff,
            .dissolved_inorganic_carbon_runoff_g = dic_runoff,
            .dissolved_organic_carbon_drainage_g = doc_drainage,
            .dissolved_inorganic_carbon_drainage_g = dic_drainage,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.dissolved_inorganic_carbon_input_g);
        self.allocator.free(self.dissolved_organic_carbon_input_g);
        self.allocator.free(self.dissolved_inorganic_carbon_drainage_g);
        self.allocator.free(self.dissolved_organic_carbon_drainage_g);
        self.allocator.free(self.dissolved_inorganic_carbon_runoff_g);
        self.allocator.free(self.dissolved_organic_carbon_runoff_g);
        self.* = undefined;
    }

    pub fn resetDaily(self: *State) void {
        @memset(self.dissolved_organic_carbon_input_g, 0);
        @memset(self.dissolved_inorganic_carbon_input_g, 0);
        @memset(self.dissolved_organic_carbon_runoff_g, 0);
        @memset(self.dissolved_inorganic_carbon_runoff_g, 0);
        @memset(self.dissolved_organic_carbon_drainage_g, 0);
        @memset(self.dissolved_inorganic_carbon_drainage_g, 0);
    }

    /// REDIST `UDOCD`: DOC plus acetate lost through all profile boundaries.
    /// The transport ledger is source-signed (positive enters), so only its
    /// negative component is an outward loss.
    pub fn accumulateOrganicDrainageHour(self: *State, model_grid: *const grid_module.GridState, transport: *const organic_transport.State) !void {
        if (self.dissolved_organic_carbon_drainage_g.len != model_grid.cell_count or transport.layer_count != model_grid.layer_count) return error.DailyCarbonExportDimensionMismatch;
        for (0..model_grid.cell_count) |cell| {
            var inward_g_c: f64 = 0;
            var outward_g_c: f64 = 0;
            for (0..model_grid.active_soil_layer_count[cell]) |local_layer| {
                const layer = try model_grid.layerIndex(cell, local_layer);
                for (0..@import("../organic/initialization.zig").substrate_count) |substrate| {
                    const base = layer * organic_transport.component_count + substrate * organic_transport.components_per_substrate;
                    const doc_flux = transport.boundary_net_flux_g[base + @intFromEnum(organic_transport.Component.dissolved_organic_carbon)];
                    const acetate_flux = transport.boundary_net_flux_g[base + @intFromEnum(organic_transport.Component.dissolved_acetate_carbon)];
                    inward_g_c += @max(0, doc_flux) + @max(0, acetate_flux);
                    outward_g_c += @max(0, -doc_flux) + @max(0, -acetate_flux);
                }
            }
            if (!std.math.isFinite(outward_g_c)) return error.NonFiniteDailyCarbonExport;
            const input_after = self.dissolved_organic_carbon_input_g[cell] + inward_g_c;
            const output_after = self.dissolved_organic_carbon_drainage_g[cell] + outward_g_c;
            if (!std.math.isFinite(input_after) or !std.math.isFinite(output_after)) return error.NonFiniteDailyCarbonExport;
            self.dissolved_organic_carbon_input_g[cell] = input_after;
            self.dissolved_organic_carbon_drainage_g[cell] = output_after;
        }
    }

    pub fn accumulateOrganicRunoffHour(self: *State, outward_g_c_by_cell: []const f64) !void {
        if (outward_g_c_by_cell.len != self.dissolved_organic_carbon_runoff_g.len) return error.DailyCarbonExportDimensionMismatch;
        for (self.dissolved_organic_carbon_runoff_g, outward_g_c_by_cell) |*daily, outward| {
            if (!std.math.isFinite(outward) or outward < 0 or !std.math.isFinite(daily.* + outward)) return error.NonFiniteDailyCarbonExport;
            daily.* += outward;
        }
    }

    pub fn accumulateInorganicRunoffHour(self: *State, outward_g_c_by_cell: []const f64) !void {
        if (outward_g_c_by_cell.len != self.dissolved_inorganic_carbon_runoff_g.len) return error.DailyCarbonExportDimensionMismatch;
        for (self.dissolved_inorganic_carbon_runoff_g, outward_g_c_by_cell) |*daily, outward| {
            if (!std.math.isFinite(outward) or outward < 0 or !std.math.isFinite(daily.* + outward)) return error.NonFiniteDailyCarbonExport;
            daily.* += outward;
        }
    }

    /// REDIST aqueous `XCOFLS/XCOFHS/XCHFLS/XCHFHS` contribution to UDICD.
    pub fn accumulateDissolvedInorganicDrainageHour(self: *State, model_grid: *const grid_module.GridState, transport: *const dissolved_gas_transport.State) !void {
        if (transport.layer_count != model_grid.layer_count or self.dissolved_inorganic_carbon_drainage_g.len != model_grid.cell_count) return error.DailyCarbonExportDimensionMismatch;
        for (0..model_grid.cell_count) |cell| {
            var inward_g_c: f64 = 0;
            var outward_g_c: f64 = 0;
            for (0..model_grid.active_soil_layer_count[cell]) |local_layer| {
                const layer = try model_grid.layerIndex(cell, local_layer);
                const base = layer * gas.species_count;
                const co2_flux = transport.boundary_net_flux_g[base + @intFromEnum(gas.Species.carbon_dioxide)];
                const ch4_flux = transport.boundary_net_flux_g[base + @intFromEnum(gas.Species.methane)];
                inward_g_c += @max(0, co2_flux) + @max(0, ch4_flux);
                outward_g_c += @max(0, -co2_flux) + @max(0, -ch4_flux);
            }
            try self.accumulateInorganicBoundary(cell, inward_g_c, outward_g_c);
        }
    }

    /// REDIST gaseous `XCOFLG/XCHFLG` contribution to UDICD. Atmospheric
    /// top-boundary exchange is intentionally excluded; only the separately
    /// classified lateral and profile-bottom ledger is consumed here.
    pub fn accumulateGaseousInorganicDrainageHour(self: *State, model_grid: *const grid_module.GridState, transport: *const gaseous_transport.State) !void {
        if (transport.subsurface_flux_g_per_h.len != try std.math.mul(usize, model_grid.layer_count, gas.species_count) or self.dissolved_inorganic_carbon_drainage_g.len != model_grid.cell_count) return error.DailyCarbonExportDimensionMismatch;
        for (0..model_grid.cell_count) |cell| {
            var inward_g_c: f64 = 0;
            var outward_g_c: f64 = 0;
            for (0..model_grid.active_soil_layer_count[cell]) |local_layer| {
                const layer = try model_grid.layerIndex(cell, local_layer);
                const base = layer * gas.species_count;
                const co2_flux = transport.subsurface_flux_g_per_h[base + @intFromEnum(gas.Species.carbon_dioxide)];
                const ch4_flux = transport.subsurface_flux_g_per_h[base + @intFromEnum(gas.Species.methane)];
                inward_g_c += @max(0, co2_flux) + @max(0, ch4_flux);
                outward_g_c += @max(0, -co2_flux) + @max(0, -ch4_flux);
            }
            try self.accumulateInorganicBoundary(cell, inward_g_c, outward_g_c);
        }
    }

    /// REDIST aqueous carbonate-species contribution to UDICD. Carbonate,
    /// bicarbonate, and complex ions (Ca/Mg/Na carbonate and bicarbonate)
    /// each carry one mol C per mol. Positive boundary flux is external
    /// recharge; negative boundary flux is drainage loss.
    pub fn accumulateSoluteCarbonateDrainageHour(
        self: *State,
        model_grid: *const grid_module.GridState,
        boundary_flux_mol: []const f64,
        aqueous_species_count: usize,
        carbon_g_per_mol: f64,
    ) !void {
        if (aqueous_species_count == 0 or
            boundary_flux_mol.len != try std.math.mul(usize, model_grid.layer_count, aqueous_species_count) or
            self.dissolved_inorganic_carbon_drainage_g.len != model_grid.cell_count)
            return error.DailyCarbonExportDimensionMismatch;
        for (0..model_grid.cell_count) |cell| {
            var inward_g_c: f64 = 0;
            var outward_g_c: f64 = 0;
            for (0..model_grid.active_soil_layer_count[cell]) |local_layer| {
                const layer = try model_grid.layerIndex(cell, local_layer);
                const base = layer * aqueous_species_count;
                inline for (@typeInfo(solute_species.AqueousSpecies).@"enum".fields) |field| {
                    if (field.value < aqueous_species_count) {
                        const species: solute_species.AqueousSpecies = @enumFromInt(field.value);
                        if (isCarbonateCarrier(species)) {
                            const flux = boundary_flux_mol[base + field.value];
                            inward_g_c += @max(0, flux) * carbon_g_per_mol;
                            outward_g_c += @max(0, -flux) * carbon_g_per_mol;
                        }
                    }
                }
            }
            try self.accumulateInorganicBoundary(cell, inward_g_c, outward_g_c);
        }
    }

    fn accumulateInorganicBoundary(self: *State, cell: usize, inward_g_c: f64, outward_g_c: f64) !void {
        const input_after = self.dissolved_inorganic_carbon_input_g[cell] + inward_g_c;
        const output_after = self.dissolved_inorganic_carbon_drainage_g[cell] + outward_g_c;
        if (!std.math.isFinite(input_after) or !std.math.isFinite(output_after)) return error.NonFiniteDailyCarbonExport;
        self.dissolved_inorganic_carbon_input_g[cell] = input_after;
        self.dissolved_inorganic_carbon_drainage_g[cell] = output_after;
    }
};

fn isCarbonateCarrier(species: solute_species.AqueousSpecies) bool {
    return switch (species) {
        .carbonate,
        .bicarbonate,
        .calcium_carbonate,
        .calcium_bicarbonate,
        .magnesium_carbonate,
        .magnesium_bicarbonate,
        .sodium_carbonate,
        => true,
        else => false,
    };
}

fn zeroes(allocator: std.mem.Allocator, count: usize) ![]f64 {
    const values = try allocator.alloc(f64, count);
    @memset(values, 0);
    return values;
}

test "UDOCD sums DOC and acetate outward losses over runtime layers and complexes" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    var transport = try organic_transport.State.init(std.testing.allocator, model_grid.layer_count);
    defer transport.deinit();
    const first = 0;
    const second = organic_transport.component_count;
    transport.boundary_net_flux_g[first + @intFromEnum(organic_transport.Component.dissolved_organic_carbon)] = -2;
    transport.boundary_net_flux_g[first + @intFromEnum(organic_transport.Component.dissolved_acetate_carbon)] = -3;
    transport.boundary_net_flux_g[second + organic_transport.components_per_substrate + @intFromEnum(organic_transport.Component.dissolved_organic_carbon)] = -5;
    transport.boundary_net_flux_g[second + @intFromEnum(organic_transport.Component.dissolved_organic_carbon)] = 17;
    var daily = try State.init(std.testing.allocator, model_grid.cell_count);
    defer daily.deinit();
    try daily.accumulateOrganicDrainageHour(&model_grid, &transport);
    try std.testing.expectApproxEqAbs(@as(f64, 10), daily.dissolved_organic_carbon_drainage_g[0], 1e-15);
}

test "subsurface gas ledger separates inward carbon from UDICD output" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    var transport = try gaseous_transport.State.init(std.testing.allocator, model_grid.layer_count);
    defer transport.deinit();
    transport.subsurface_flux_g_per_h[@intFromEnum(gas.Species.carbon_dioxide)] = -2;
    transport.subsurface_flux_g_per_h[@intFromEnum(gas.Species.methane)] = 7;
    transport.subsurface_flux_g_per_h[gas.species_count + @intFromEnum(gas.Species.methane)] = -3;
    // Surface exchange must never enter profile drainage.
    transport.atmospheric_flux_g_per_h[@intFromEnum(gas.Species.carbon_dioxide)] = -100;
    var daily = try State.init(std.testing.allocator, model_grid.cell_count);
    defer daily.deinit();
    try daily.accumulateGaseousInorganicDrainageHour(&model_grid, &transport);
    try std.testing.expectApproxEqAbs(@as(f64, 7), daily.dissolved_inorganic_carbon_input_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 5), daily.dissolved_inorganic_carbon_drainage_g[0], 1e-15);
}

test "carbonate boundary ledger separates recharge from drainage" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    var flux = [_]f64{0} ** solute_species.AqueousSpecies.count;
    flux[@intFromEnum(solute_species.AqueousSpecies.bicarbonate)] = 2;
    flux[@intFromEnum(solute_species.AqueousSpecies.calcium_carbonate)] = -3;
    var daily = try State.init(std.testing.allocator, model_grid.cell_count);
    defer daily.deinit();
    try daily.accumulateSoluteCarbonateDrainageHour(&model_grid, &flux, solute_species.AqueousSpecies.count, 12);
    try std.testing.expectEqual(@as(f64, 24), daily.dissolved_inorganic_carbon_input_g[0]);
    try std.testing.expectEqual(@as(f64, 36), daily.dissolved_inorganic_carbon_drainage_g[0]);
}
