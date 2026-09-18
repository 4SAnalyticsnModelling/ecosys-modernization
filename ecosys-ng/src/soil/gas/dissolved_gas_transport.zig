const std = @import("std");
const gas = @import("transport.zig");
const hydrology = @import("../../transport/hydrology.zig");
const transport = @import("aqueous_extensive_transport.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    boundary_net_flux_g: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        if (layer_count == 0) return error.ZeroSoilDissolvedGasTransportLayers;
        const ledger = try allocator.alloc(f64, layer_count * gas.species_count);
        @memset(ledger, 0);
        return .{ .allocator = allocator, .layer_count = layer_count, .boundary_net_flux_g = ledger };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.boundary_net_flux_g);
        self.* = undefined;
    }

    pub fn validateFinite(self: *const State) !void {
        for (self.boundary_net_flux_g, 0..) |value, index| {
            if (!std.math.isFinite(value)) {
                std.log.err(
                    "non-finite dissolved-gas boundary ledger: index={d} value={e}",
                    .{ index, value },
                );
                return error.NonFiniteDissolvedGasBoundaryLedger;
            }
        }
    }
};

pub const Inputs = struct {
    faces: *const hydrology.SoilFaces,
    micropore_conductance_m3_per_step: []const f64,
    macropore_conductance_m3_per_step: []const f64,
    micropore_water_m3: []const f64,
    macropore_water_m3: []const f64,
    layer_bulk_volume_m3: []const f64,
    micropore_external_water_flux_m3_per_step: []const f64,
    macropore_external_water_flux_m3_per_step: []const f64,
    macropore_to_matrix_water_flux_m3_per_step: []const f64 = &.{},
    recharge_concentration_g_per_m3: []const f64,
};

/// TRNSFR aqueous transport for the gas-owned dissolved species. Aqueous NH3
/// is deliberately excluded: mineral_nitrogen_transport is the sole owner of
/// ZNH3S/ZNH3B/ZNH3SH/ZNH3BH and transports it in mol N. The gas NH3 slots are
/// transient phase/root-exchange mirrors only.
pub fn advance(allocator: std.mem.Allocator, state: *State, gas_state: *gas.State, inputs: Inputs, options: transport.Options) !transport.Result {
    if (gas_state.cell_count != state.layer_count) return error.SoilDissolvedGasTransportDimensionMismatch;
    if (inputs.faces.active_by_layer.len != state.layer_count or
        inputs.faces.active_by_face.len != inputs.faces.micropore_faces.len)
        return error.SoilDissolvedGasTransportDimensionMismatch;
    const masked_faces = try allocator.dupe(@import("../solute/transport.zig").Face, inputs.faces.micropore_faces);
    defer allocator.free(masked_faces);
    const micro_conductance = try allocator.dupe(f64, inputs.micropore_conductance_m3_per_step);
    defer allocator.free(micro_conductance);
    const macro_conductance = try allocator.dupe(f64, inputs.macropore_conductance_m3_per_step);
    defer allocator.free(macro_conductance);
    for (inputs.faces.active_by_face, 0..) |active, face| {
        if (active) continue;
        masked_faces[face].water_flux_m3_per_step = 0;
        const start = face * gas.species_count;
        if (start + gas.species_count <= micro_conductance.len)
            @memset(micro_conductance[start..][0..gas.species_count], 0);
        if (start + gas.species_count <= macro_conductance.len)
            @memset(macro_conductance[start..][0..gas.species_count], 0);
    }
    const ammonia = @intFromEnum(gas.Species.ammonia);
    const matrix_ammonia = try allocator.alloc(f64, state.layer_count);
    defer allocator.free(matrix_ammonia);
    const macropore_ammonia = try allocator.alloc(f64, state.layer_count);
    defer allocator.free(macropore_ammonia);
    for (0..state.layer_count) |layer| {
        const index = layer * gas.species_count + ammonia;
        matrix_ammonia[layer] = gas_state.dissolved_mass_g[index];
        macropore_ammonia[layer] = gas_state.macropore_dissolved_mass_g[index];
    }
    const result = try transport.advance(
        allocator,
        gas_state.dissolved_mass_g,
        gas_state.macropore_dissolved_mass_g,
        state.boundary_net_flux_g,
        .{
            .species_count = gas.species_count,
            .active_by_layer = inputs.faces.active_by_layer,
            .faces = masked_faces,
            .micropore_conductance_m3_per_step = micro_conductance,
            .macropore_conductance_m3_per_step = macro_conductance,
            .micropore_water_m3 = inputs.micropore_water_m3,
            .macropore_water_m3 = inputs.macropore_water_m3,
            .layer_bulk_volume_m3 = inputs.layer_bulk_volume_m3,
            .micropore_external_water_flux_m3_per_step = inputs.micropore_external_water_flux_m3_per_step,
            .macropore_external_water_flux_m3_per_step = inputs.macropore_external_water_flux_m3_per_step,
            .macropore_to_matrix_water_flux_m3_per_step = inputs.macropore_to_matrix_water_flux_m3_per_step,
            .recharge_concentration_per_m3 = inputs.recharge_concentration_g_per_m3,
        },
        options,
    );
    for (0..state.layer_count) |layer| {
        const index = layer * gas.species_count + ammonia;
        gas_state.dissolved_mass_g[index] = matrix_ammonia[layer];
        gas_state.macropore_dissolved_mass_g[index] = macropore_ammonia[layer];
        state.boundary_net_flux_g[index] = 0;
    }
    if (options.micropore_face_flux_by_component) |values| {
        for (0..inputs.faces.micropore_faces.len) |face|
            values[face * gas.species_count + ammonia] = 0;
    }
    if (options.macropore_face_flux_by_component) |values| {
        for (0..inputs.faces.macropore_faces.len) |face|
            values[face * gas.species_count + ammonia] = 0;
    }
    return result;
}

test "CO2 and CH4 boundary losses retain tracked-carbon grams and source sign" {
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] = 8;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.methane)] = 4;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try @import("../../state/grid.zig").GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    @memset(model_grid.active_soil_layer_count, 1);
    var hydro = try hydrology.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydro.deinit();
    var faces = try hydrology.buildSoilFaces(std.testing.allocator, &hydro, &model_grid);
    defer faces.deinit();
    const zero_recharge = [_]f64{0} ** gas.species_count;
    _ = try advance(std.testing.allocator, &state, &gas_state, .{
        .faces = &faces,
        .micropore_conductance_m3_per_step = &.{},
        .macropore_conductance_m3_per_step = &.{},
        .micropore_water_m3 = &.{1},
        .macropore_water_m3 = &.{0},
        .layer_bulk_volume_m3 = &.{1},
        .micropore_external_water_flux_m3_per_step = &.{0.25},
        .macropore_external_water_flux_m3_per_step = &.{0},
        .recharge_concentration_g_per_m3 = &zero_recharge,
    }, .{ .absolute_tolerance = 1e-12, .relative_tolerance = 1e-8, .picard_relaxation = 0.5, .max_iterations = 20, .pore_exchange_fraction = 0 });
    try std.testing.expectEqual(@as(f64, -2), state.boundary_net_flux_g[@intFromEnum(gas.Species.carbon_dioxide)]);
    try std.testing.expectEqual(@as(f64, -1), state.boundary_net_flux_g[@intFromEnum(gas.Species.methane)]);
}

test "aqueous ammonia mirror never enters generic spatial or boundary transport" {
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    const ammonia = @intFromEnum(gas.Species.ammonia);
    gas_state.dissolved_mass_g[ammonia] = 8;
    gas_state.macropore_dissolved_mass_g[ammonia] = 3;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try @import("../../state/grid.zig").GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    @memset(model_grid.active_soil_layer_count, 1);
    var hydro = try hydrology.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydro.deinit();
    var faces = try hydrology.buildSoilFaces(std.testing.allocator, &hydro, &model_grid);
    defer faces.deinit();
    var recharge = [_]f64{0} ** gas.species_count;
    recharge[ammonia] = 100;
    _ = try advance(std.testing.allocator, &state, &gas_state, .{
        .faces = &faces,
        .micropore_conductance_m3_per_step = &.{},
        .macropore_conductance_m3_per_step = &.{},
        .micropore_water_m3 = &.{1},
        .macropore_water_m3 = &.{1},
        .layer_bulk_volume_m3 = &.{1},
        .micropore_external_water_flux_m3_per_step = &.{0.25},
        .macropore_external_water_flux_m3_per_step = &.{-0.25},
        .recharge_concentration_g_per_m3 = &recharge,
    }, .{ .absolute_tolerance = 1e-12, .relative_tolerance = 1e-8, .picard_relaxation = 0.5, .max_iterations = 20, .pore_exchange_fraction = 1 });
    try std.testing.expectEqual(@as(f64, 8), gas_state.dissolved_mass_g[ammonia]);
    try std.testing.expectEqual(@as(f64, 3), gas_state.macropore_dissolved_mass_g[ammonia]);
    try std.testing.expectEqual(@as(f64, 0), state.boundary_net_flux_g[ammonia]);
}

test "DLYRM inactive dissolved-gas layer has no boundary or pore exchange" {
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    const carbon_dioxide = @intFromEnum(gas.Species.carbon_dioxide);
    gas_state.dissolved_mass_g[carbon_dioxide] = 8;
    gas_state.macropore_dissolved_mass_g[carbon_dioxide] = 4;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try @import("../../state/grid.zig").GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    var hydro = try hydrology.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydro.deinit();
    var faces = try hydrology.buildSoilFaces(std.testing.allocator, &hydro, &model_grid);
    defer faces.deinit();
    faces.active_by_layer[0] = false;
    var recharge = [_]f64{0} ** gas.species_count;
    recharge[carbon_dioxide] = 100;
    _ = try advance(std.testing.allocator, &state, &gas_state, .{
        .faces = &faces,
        .micropore_conductance_m3_per_step = &.{},
        .macropore_conductance_m3_per_step = &.{},
        .micropore_water_m3 = &.{1},
        .macropore_water_m3 = &.{1},
        .layer_bulk_volume_m3 = &.{1},
        .micropore_external_water_flux_m3_per_step = &.{0.25},
        .macropore_external_water_flux_m3_per_step = &.{-0.25},
        .recharge_concentration_g_per_m3 = &recharge,
    }, .{ .absolute_tolerance = 1e-12, .relative_tolerance = 1e-8, .picard_relaxation = 0.5, .max_iterations = 20, .pore_exchange_fraction = 1 });
    try std.testing.expectEqual(@as(f64, 8), gas_state.dissolved_mass_g[carbon_dioxide]);
    try std.testing.expectEqual(@as(f64, 4), gas_state.macropore_dissolved_mass_g[carbon_dioxide]);
    try std.testing.expectEqual(@as(f64, 0), state.boundary_net_flux_g[carbon_dioxide]);
}
