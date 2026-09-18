const std = @import("std");
const grid_module = @import("../../state/grid.zig");
const organic = @import("../organic/initialization.zig");
const organic_transport = @import("../organic/transport.zig");
const solute_species = @import("../solute/transport_species.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    dissolved_organic_phosphorus_runoff_g_p: []f64,
    dissolved_organic_phosphorus_drainage_g_p: []f64,
    dissolved_inorganic_phosphorus_runoff_g_p: []f64,
    dissolved_inorganic_phosphorus_drainage_g_p: []f64,
    dissolved_organic_phosphorus_input_g_p: []f64,
    dissolved_inorganic_phosphorus_input_g_p: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroDailyPhosphorusExportCells;
        const dop_runoff = try zeroes(allocator, cell_count);
        errdefer allocator.free(dop_runoff);
        const dop_drainage = try zeroes(allocator, cell_count);
        errdefer allocator.free(dop_drainage);
        const dip_runoff = try zeroes(allocator, cell_count);
        errdefer allocator.free(dip_runoff);
        const dip_drainage = try zeroes(allocator, cell_count);
        errdefer allocator.free(dip_drainage);
        const dop_input = try zeroes(allocator, cell_count);
        errdefer allocator.free(dop_input);
        const dip_input = try zeroes(allocator, cell_count);
        return .{
            .allocator = allocator,
            .dissolved_organic_phosphorus_runoff_g_p = dop_runoff,
            .dissolved_organic_phosphorus_drainage_g_p = dop_drainage,
            .dissolved_inorganic_phosphorus_runoff_g_p = dip_runoff,
            .dissolved_inorganic_phosphorus_drainage_g_p = dip_drainage,
            .dissolved_organic_phosphorus_input_g_p = dop_input,
            .dissolved_inorganic_phosphorus_input_g_p = dip_input,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.dissolved_inorganic_phosphorus_input_g_p);
        self.allocator.free(self.dissolved_organic_phosphorus_input_g_p);
        self.allocator.free(self.dissolved_inorganic_phosphorus_drainage_g_p);
        self.allocator.free(self.dissolved_inorganic_phosphorus_runoff_g_p);
        self.allocator.free(self.dissolved_organic_phosphorus_drainage_g_p);
        self.allocator.free(self.dissolved_organic_phosphorus_runoff_g_p);
        self.* = undefined;
    }

    pub fn resetDaily(self: *State) void {
        @memset(self.dissolved_organic_phosphorus_runoff_g_p, 0);
        @memset(self.dissolved_organic_phosphorus_drainage_g_p, 0);
        @memset(self.dissolved_inorganic_phosphorus_runoff_g_p, 0);
        @memset(self.dissolved_inorganic_phosphorus_drainage_g_p, 0);
        @memset(self.dissolved_organic_phosphorus_input_g_p, 0);
        @memset(self.dissolved_inorganic_phosphorus_input_g_p, 0);
    }

    /// REDIST UDOPD: state_updateted DOP losses through runtime profile boundaries.
    pub fn accumulateOrganicDrainageHour(self: *State, model_grid: *const grid_module.GridState, transport: *const organic_transport.State) !void {
        if (self.dissolved_organic_phosphorus_drainage_g_p.len != model_grid.cell_count or transport.layer_count != model_grid.layer_count) return error.DailyPhosphorusExportDimensionMismatch;
        for (0..model_grid.cell_count) |cell| {
            var outward_g_p: f64 = 0;
            var inward_g_p: f64 = 0;
            for (0..model_grid.active_soil_layer_count[cell]) |local_layer| {
                const layer = try model_grid.layerIndex(cell, local_layer);
                for (0..organic.substrate_count) |substrate| {
                    const base = layer * organic_transport.component_count + substrate * organic_transport.components_per_substrate;
                    const flux_g_p = transport.boundary_net_flux_g[base + @intFromEnum(organic_transport.Component.dissolved_organic_phosphorus)];
                    outward_g_p += @max(0, -flux_g_p);
                    inward_g_p += @max(0, flux_g_p);
                }
            }
            try add(&self.dissolved_organic_phosphorus_drainage_g_p[cell], outward_g_p);
            try add(&self.dissolved_organic_phosphorus_input_g_p[cell], inward_g_p);
        }
    }

    /// REDIST UDIPD: all transported aqueous phosphate forms crossing runtime
    /// profile boundaries, converted from mol P with the runtime molar mass.
    pub fn accumulateInorganicDrainageHour(self: *State, model_grid: *const grid_module.GridState, boundary_net_flux_mol: []const f64, phosphorus_molar_mass_g_per_mol: f64) !void {
        const species_count = @typeInfo(solute_species.AqueousSpecies).@"enum".fields.len;
        if (boundary_net_flux_mol.len != try std.math.mul(usize, model_grid.layer_count, species_count) or self.dissolved_inorganic_phosphorus_drainage_g_p.len != model_grid.cell_count or !std.math.isFinite(phosphorus_molar_mass_g_per_mol) or phosphorus_molar_mass_g_per_mol <= 0) return error.DailyPhosphorusExportDimensionMismatch;
        for (0..model_grid.cell_count) |cell| {
            var outward_mol_p: f64 = 0;
            var inward_mol_p: f64 = 0;
            for (0..model_grid.active_soil_layer_count[cell]) |local_layer| {
                const layer = try model_grid.layerIndex(cell, local_layer);
                const base = layer * species_count;
                inline for (@typeInfo(solute_species.AqueousSpecies).@"enum".fields) |field| {
                    const species: solute_species.AqueousSpecies = @enumFromInt(field.value);
                    if (solute_species.diffusivityClass(species) == .phosphate) {
                        const flux_mol_p = boundary_net_flux_mol[base + field.value];
                        outward_mol_p += @max(0, -flux_mol_p);
                        inward_mol_p += @max(0, flux_mol_p);
                    }
                }
            }
            try add(&self.dissolved_inorganic_phosphorus_drainage_g_p[cell], outward_mol_p * phosphorus_molar_mass_g_per_mol);
            try add(&self.dissolved_inorganic_phosphorus_input_g_p[cell], inward_mol_p * phosphorus_molar_mass_g_per_mol);
        }
    }

    pub fn accumulateRunoffHour(self: *State, organic_outward_g_p: []const f64, inorganic_outward_g_p: []const f64) !void {
        if (organic_outward_g_p.len != self.dissolved_organic_phosphorus_runoff_g_p.len or inorganic_outward_g_p.len != self.dissolved_inorganic_phosphorus_runoff_g_p.len) return error.DailyPhosphorusExportDimensionMismatch;
        for (0..organic_outward_g_p.len) |cell| {
            try add(&self.dissolved_organic_phosphorus_runoff_g_p[cell], organic_outward_g_p[cell]);
            try add(&self.dissolved_inorganic_phosphorus_runoff_g_p[cell], inorganic_outward_g_p[cell]);
        }
    }
};

fn add(total: *f64, outward: f64) !void {
    if (!std.math.isFinite(outward) or outward < 0 or !std.math.isFinite(total.* + outward)) return error.NonFiniteDailyPhosphorusExport;
    total.* += outward;
}

fn zeroes(allocator: std.mem.Allocator, count: usize) ![]f64 {
    const values = try allocator.alloc(f64, count);
    @memset(values, 0);
    return values;
}

test "UDOPD and UDIPD sum only outward phosphorus over runtime layers" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    var transport = try organic_transport.State.init(std.testing.allocator, model_grid.layer_count);
    defer transport.deinit();
    transport.boundary_net_flux_g[@intFromEnum(organic_transport.Component.dissolved_organic_phosphorus)] = -2;
    transport.boundary_net_flux_g[organic_transport.components_per_substrate + @intFromEnum(organic_transport.Component.dissolved_organic_phosphorus)] = 4;
    transport.boundary_net_flux_g[organic_transport.component_count + organic_transport.components_per_substrate + @intFromEnum(organic_transport.Component.dissolved_organic_phosphorus)] = -3;
    var boundary = [_]f64{0} ** (2 * @typeInfo(solute_species.AqueousSpecies).@"enum".fields.len);
    boundary[@intFromEnum(solute_species.AqueousSpecies.non_band_phosphate)] = -0.1;
    boundary[@intFromEnum(solute_species.AqueousSpecies.band_phosphate)] = 0.4;
    boundary[@typeInfo(solute_species.AqueousSpecies).@"enum".fields.len + @intFromEnum(solute_species.AqueousSpecies.band_phosphoric_acid)] = -0.2;
    var daily = try State.init(std.testing.allocator, 1);
    defer daily.deinit();
    try daily.accumulateOrganicDrainageHour(&model_grid, &transport);
    try daily.accumulateInorganicDrainageHour(&model_grid, &boundary, 31);
    try std.testing.expectEqual(@as(f64, 5), daily.dissolved_organic_phosphorus_drainage_g_p[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 9.3), daily.dissolved_inorganic_phosphorus_drainage_g_p[0], 1e-14);
    try std.testing.expectEqual(@as(f64, 4), daily.dissolved_organic_phosphorus_input_g_p[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 12.4), daily.dissolved_inorganic_phosphorus_input_g_p[0], 1e-14);
}
