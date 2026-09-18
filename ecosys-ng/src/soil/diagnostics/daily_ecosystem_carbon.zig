const std = @import("std");
const grid_module = @import("../../state/grid.zig");
const export_module = @import("daily_carbon_export.zig");

pub const Inputs = struct {
    net_primary_productivity_g_c: f64,
    signed_heterotrophic_respiration_g_c: f64,
    dissolved_organic_carbon_runoff_g_c: f64,
    dissolved_inorganic_carbon_runoff_g_c: f64,
    dissolved_organic_carbon_drainage_g_c: f64,
    dissolved_inorganic_carbon_drainage_g_c: f64,
    dissolved_organic_carbon_input_g_c: f64 = 0,
    dissolved_inorganic_carbon_input_g_c: f64 = 0,
    harvested_carbon_g_c: f64,
    organic_fertilizer_carbon_input_g_c: f64,
};

pub const Result = struct {
    net_biome_productivity_g_c: f64,
    total_dissolved_carbon_export_g_c: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    net_primary_productivity_g_c: []f64,
    net_biome_productivity_g_c: []f64,
    total_dissolved_carbon_export_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroDailyEcosystemCarbonCells;
        const npp = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(npp);
        const nbp = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(nbp);
        const export_g_c = try allocator.alloc(f64, cell_count);
        @memset(npp, 0);
        @memset(nbp, 0);
        @memset(export_g_c, 0);
        return .{ .allocator = allocator, .net_primary_productivity_g_c = npp, .net_biome_productivity_g_c = nbp, .total_dissolved_carbon_export_g_c = export_g_c };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.total_dissolved_carbon_export_g_c);
        self.allocator.free(self.net_biome_productivity_g_c);
        self.allocator.free(self.net_primary_productivity_g_c);
        self.* = undefined;
    }

    /// Runtime-cell REDIST aggregation. TNPP is the exact source identity
    /// `TGPP + TRAU`, summed over all user-selected plant populations.
    pub fn finalizeDay(
        self: *State,
        model_grid: *const grid_module.GridState,
        plant_population_count: usize,
        gross_primary_productivity_g_c_by_plant: []const f64,
        signed_total_respiration_g_c_by_plant: []const f64,
        harvested_carbon_g_c_by_plant: []const f64,
        signed_heterotrophic_respiration_g_c_by_cell: []const f64,
        organic_fertilizer_carbon_input_g_c_by_cell: []const f64,
        carbon_export: *const export_module.State,
    ) !void {
        const plant_count = try std.math.mul(usize, model_grid.cell_count, plant_population_count);
        if (plant_population_count == 0 or gross_primary_productivity_g_c_by_plant.len != plant_count or signed_total_respiration_g_c_by_plant.len != plant_count or harvested_carbon_g_c_by_plant.len != plant_count or signed_heterotrophic_respiration_g_c_by_cell.len != model_grid.cell_count or organic_fertilizer_carbon_input_g_c_by_cell.len != model_grid.cell_count or self.net_biome_productivity_g_c.len != model_grid.cell_count or carbon_export.dissolved_organic_carbon_runoff_g.len != model_grid.cell_count) return error.DailyEcosystemCarbonDimensionMismatch;
        for (0..model_grid.cell_count) |cell| {
            var npp_g_c: f64 = 0;
            var harvest_g_c: f64 = 0;
            for (0..plant_population_count) |species| {
                const plant = cell * plant_population_count + species;
                npp_g_c += gross_primary_productivity_g_c_by_plant[plant] + signed_total_respiration_g_c_by_plant[plant];
                harvest_g_c += harvested_carbon_g_c_by_plant[plant];
            }
            const result = try calculate(.{
                .net_primary_productivity_g_c = npp_g_c,
                .signed_heterotrophic_respiration_g_c = signed_heterotrophic_respiration_g_c_by_cell[cell],
                .dissolved_organic_carbon_runoff_g_c = carbon_export.dissolved_organic_carbon_runoff_g[cell],
                .dissolved_inorganic_carbon_runoff_g_c = carbon_export.dissolved_inorganic_carbon_runoff_g[cell],
                .dissolved_organic_carbon_drainage_g_c = carbon_export.dissolved_organic_carbon_drainage_g[cell],
                .dissolved_inorganic_carbon_drainage_g_c = carbon_export.dissolved_inorganic_carbon_drainage_g[cell],
                .dissolved_organic_carbon_input_g_c = carbon_export.dissolved_organic_carbon_input_g[cell],
                .dissolved_inorganic_carbon_input_g_c = carbon_export.dissolved_inorganic_carbon_input_g[cell],
                .harvested_carbon_g_c = harvest_g_c,
                .organic_fertilizer_carbon_input_g_c = organic_fertilizer_carbon_input_g_c_by_cell[cell],
            });
            self.net_primary_productivity_g_c[cell] = npp_g_c;
            self.net_biome_productivity_g_c[cell] = result.net_biome_productivity_g_c;
            self.total_dissolved_carbon_export_g_c[cell] = result.total_dissolved_carbon_export_g_c;
        }
    }
};

/// REDIST plus HOUR1's eligible external organic-carbon application:
/// `TNBP = TNPP + UORGF + THRE - UDOCQ - UDICQ - UDOCD - UDICD - XHVSTC`.
/// The UORGF term supplied here includes only source manure/residue types
/// which HOUR1 adds to TNBP.
/// `THRE` retains the legacy source sign, so respiration production is
/// negative and is added directly.
/// Legacy drainage terms are signed net losses. Our drainage arrays retain
/// gross outward amounts, so their separately recorded inward transport must
/// be added here. Precipitation and irrigation use separate input ledgers.
pub fn calculate(inputs: Inputs) !Result {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteDailyEcosystemCarbon;
    inline for (.{
        inputs.dissolved_organic_carbon_runoff_g_c,
        inputs.dissolved_inorganic_carbon_runoff_g_c,
        inputs.dissolved_organic_carbon_drainage_g_c,
        inputs.dissolved_inorganic_carbon_drainage_g_c,
        inputs.dissolved_organic_carbon_input_g_c,
        inputs.dissolved_inorganic_carbon_input_g_c,
        inputs.harvested_carbon_g_c,
        inputs.organic_fertilizer_carbon_input_g_c,
    }) |value| if (value < 0) return error.InvalidDailyEcosystemCarbonLoss;
    const export_g_c =
        inputs.dissolved_organic_carbon_runoff_g_c +
        inputs.dissolved_inorganic_carbon_runoff_g_c +
        inputs.dissolved_organic_carbon_drainage_g_c +
        inputs.dissolved_inorganic_carbon_drainage_g_c;
    const net_biome_productivity_g_c =
        inputs.net_primary_productivity_g_c +
        inputs.organic_fertilizer_carbon_input_g_c +
        inputs.dissolved_organic_carbon_input_g_c +
        inputs.dissolved_inorganic_carbon_input_g_c +
        inputs.signed_heterotrophic_respiration_g_c -
        export_g_c -
        inputs.harvested_carbon_g_c;
    if (!std.math.isFinite(export_g_c) or !std.math.isFinite(net_biome_productivity_g_c)) return error.NonFiniteDailyEcosystemCarbon;
    return .{ .net_biome_productivity_g_c = net_biome_productivity_g_c, .total_dissolved_carbon_export_g_c = export_g_c };
}

test "TNBP reproduces exact REDIST identity and signs" {
    const result = try calculate(.{
        .net_primary_productivity_g_c = 100,
        .signed_heterotrophic_respiration_g_c = -30,
        .dissolved_organic_carbon_runoff_g_c = 2,
        .dissolved_inorganic_carbon_runoff_g_c = 3,
        .dissolved_organic_carbon_drainage_g_c = 5,
        .dissolved_inorganic_carbon_drainage_g_c = 7,
        .harvested_carbon_g_c = 11,
        .organic_fertilizer_carbon_input_g_c = 4,
    });
    try std.testing.expectEqual(@as(f64, 17), result.total_dissolved_carbon_export_g_c);
    try std.testing.expectEqual(@as(f64, 46), result.net_biome_productivity_g_c);
}

test "negative outward loss fails instead of silently increasing TNBP" {
    try std.testing.expectError(error.InvalidDailyEcosystemCarbonLoss, calculate(.{
        .net_primary_productivity_g_c = 0,
        .signed_heterotrophic_respiration_g_c = 0,
        .dissolved_organic_carbon_runoff_g_c = -1,
        .dissolved_inorganic_carbon_runoff_g_c = 0,
        .dissolved_organic_carbon_drainage_g_c = 0,
        .dissolved_inorganic_carbon_drainage_g_c = 0,
        .harvested_carbon_g_c = 0,
        .organic_fertilizer_carbon_input_g_c = 0,
    }));
}

test "runtime cell finalization sums arbitrary plant populations into exact TNPP and TNBP" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 7 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    var exports = try export_module.State.init(std.testing.allocator, 1);
    defer exports.deinit();
    exports.dissolved_organic_carbon_runoff_g[0] = 1;
    exports.dissolved_inorganic_carbon_runoff_g[0] = 2;
    exports.dissolved_organic_carbon_drainage_g[0] = 3;
    exports.dissolved_inorganic_carbon_drainage_g[0] = 4;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try state.finalizeDay(&model_grid, 7, &.{ 10, 10, 10, 10, 10, 10, 10 }, &.{ -1, -1, -1, -1, -1, -1, -1 }, &.{ 0, 0, 0, 0, 0, 0, 5 }, &.{-8}, &.{2}, &exports);
    try std.testing.expectEqual(@as(f64, 63), state.net_primary_productivity_g_c[0]);
    try std.testing.expectEqual(@as(f64, 42), state.net_biome_productivity_g_c[0]);
}

test "TNBP includes inward carbon transport while retaining gross drainage" {
    const organic = @import("../organic/transport.zig");
    const dissolved = @import("../gas/dissolved_gas_transport.zig");
    const gaseous = @import("../gas/transport_step.zig");
    const gas = @import("../gas/transport.zig");
    const solutes = @import("../solute/transport_species.zig");
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var exports = try export_module.State.init(std.testing.allocator, 1);
    defer exports.deinit();
    var doc = try organic.State.init(std.testing.allocator, grid.layer_count);
    defer doc.deinit();
    doc.boundary_net_flux_g[@intFromEnum(organic.Component.dissolved_organic_carbon)] = -10;
    doc.boundary_net_flux_g[organic.component_count + @intFromEnum(organic.Component.dissolved_acetate_carbon)] = 17;
    try exports.accumulateOrganicDrainageHour(&grid, &doc);
    var aqueous = try dissolved.State.init(std.testing.allocator, grid.layer_count);
    defer aqueous.deinit();
    aqueous.boundary_net_flux_g[@intFromEnum(gas.Species.carbon_dioxide)] = 11;
    aqueous.boundary_net_flux_g[gas.species_count + @intFromEnum(gas.Species.methane)] = -13;
    try exports.accumulateDissolvedInorganicDrainageHour(&grid, &aqueous);
    var air = try gaseous.State.init(std.testing.allocator, grid.layer_count);
    defer air.deinit();
    air.subsurface_flux_g_per_h[@intFromEnum(gas.Species.methane)] = 7;
    air.subsurface_flux_g_per_h[gas.species_count + @intFromEnum(gas.Species.carbon_dioxide)] = -5;
    air.atmospheric_flux_g_per_h[@intFromEnum(gas.Species.carbon_dioxide)] = -100;
    try exports.accumulateGaseousInorganicDrainageHour(&grid, &air);
    var carbonate = [_]f64{0} ** (2 * solutes.AqueousSpecies.count);
    carbonate[@intFromEnum(solutes.AqueousSpecies.bicarbonate)] = 2;
    carbonate[solutes.AqueousSpecies.count + @intFromEnum(solutes.AqueousSpecies.calcium_carbonate)] = -3;
    try exports.accumulateSoluteCarbonateDrainageHour(&grid, &carbonate, solutes.AqueousSpecies.count, 12);

    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try state.finalizeDay(&grid, 1, &.{0}, &.{0}, &.{0}, &.{-10}, &.{0}, &exports);
    // Source signed net drainage: DOC=-7, aqueous DIC=2, gas DIC=-2,
    // carbonate DIC=12. NBP = -10 - (-7 + 2 - 2 + 12) = -15.
    try std.testing.expectEqual(@as(f64, -15), state.net_biome_productivity_g_c[0]);
    try std.testing.expectEqual(@as(f64, 64), state.total_dissolved_carbon_export_g_c[0]);
    try std.testing.expectEqual(@as(f64, 17), exports.dissolved_organic_carbon_input_g[0]);
    try std.testing.expectEqual(@as(f64, 42), exports.dissolved_inorganic_carbon_input_g[0]);

    var inputs: Inputs = .{ .net_primary_productivity_g_c = 0, .signed_heterotrophic_respiration_g_c = 0, .dissolved_organic_carbon_runoff_g_c = 0, .dissolved_inorganic_carbon_runoff_g_c = 0, .dissolved_organic_carbon_drainage_g_c = 0, .dissolved_inorganic_carbon_drainage_g_c = 0, .harvested_carbon_g_c = 0, .organic_fertilizer_carbon_input_g_c = 0 };
    inline for (.{ "dissolved_organic_carbon_input_g_c", "dissolved_inorganic_carbon_input_g_c" }) |field| {
        @field(inputs, field) = -1;
        try std.testing.expectError(error.InvalidDailyEcosystemCarbonLoss, calculate(inputs));
        @field(inputs, field) = std.math.nan(f64);
        try std.testing.expectError(error.NonFiniteDailyEcosystemCarbon, calculate(inputs));
        @field(inputs, field) = 0;
    }
}
