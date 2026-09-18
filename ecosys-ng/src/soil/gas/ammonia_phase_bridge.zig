//! Single-owner bridge for aqueous soil ammonia.
//!
//! TRNSFR owns ZNH3S/ZNH3B in the mineral-N matrix inventory.  The generic
//! gas state retains aqueous NH3 slots only as transient inputs/outputs of the
//! root and gas/water exchange kernels; they are never a second inventory.

const std = @import("std");
const gas = @import("transport.zig");
const gas_step = @import("transport_step.zig");
const grid_module = @import("../../state/grid.zig");
const hydrology_module = @import("../../transport/hydrology.zig");
const geometry_module = @import("../water/face_geometry.zig");
const mineral = @import("../biogeochemistry/mineral_nitrogen_transport.zig");

pub fn refreshTransientFromMineral(
    mineral_state: *const mineral.State,
    gas_state: *gas.State,
    nitrogen_molar_mass_g_per_mol: f64,
) !void {
    try validateDimensions(mineral_state, gas_state, nitrogen_molar_mass_g_per_mol);
    for (0..mineral_state.cell_count) |cell| {
        const mineral_first = cell * mineral.species_count;
        const nonband = mineral_state.matrix.amount_mol[mineral_first + @intFromEnum(mineral.Species.ammonia_non_band)] * nitrogen_molar_mass_g_per_mol;
        const band = mineral_state.matrix.amount_mol[mineral_first + @intFromEnum(mineral.Species.ammonia_band)] * nitrogen_molar_mass_g_per_mol;
        inline for (.{ nonband, band }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidMineralAmmoniaInventory;
    }
    for (0..mineral_state.cell_count) |cell| {
        const mineral_first = cell * mineral.species_count;
        const gas_index = cell * gas.species_count + @intFromEnum(gas.Species.ammonia);
        gas_state.dissolved_mass_g[gas_index] = mineral_state.matrix.amount_mol[mineral_first + @intFromEnum(mineral.Species.ammonia_non_band)] * nitrogen_molar_mass_g_per_mol;
        gas_state.band_dissolved_mass_g[gas_index] = mineral_state.matrix.amount_mol[mineral_first + @intFromEnum(mineral.Species.ammonia_band)] * nitrogen_molar_mass_g_per_mol;
        // ZNH3SH/ZNH3BH are owned by the mineral macropore state.  The gas
        // solver has no independent macropore NH3 phase-exchange equation.
        gas_state.macropore_dissolved_mass_g[gas_index] = 0;
    }
}

pub fn publishTransientToMineral(
    mineral_state: *mineral.State,
    gas_state: *const gas.State,
    nitrogen_molar_mass_g_per_mol: f64,
) !void {
    try validateDimensions(mineral_state, gas_state, nitrogen_molar_mass_g_per_mol);
    for (0..mineral_state.cell_count) |cell| {
        const gas_index = cell * gas.species_count + @intFromEnum(gas.Species.ammonia);
        inline for (.{ gas_state.dissolved_mass_g[gas_index], gas_state.band_dissolved_mass_g[gas_index] }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidTransientAmmoniaInventory;
        if (!std.math.isFinite(gas_state.macropore_dissolved_mass_g[gas_index]) or
            gas_state.macropore_dissolved_mass_g[gas_index] != 0)
            return error.NoncanonicalTransientMacroporeAmmonia;
    }
    for (0..mineral_state.cell_count) |cell| {
        const mineral_first = cell * mineral.species_count;
        const gas_index = cell * gas.species_count + @intFromEnum(gas.Species.ammonia);
        mineral_state.matrix.amount_mol[mineral_first + @intFromEnum(mineral.Species.ammonia_non_band)] =
            gas_state.dissolved_mass_g[gas_index] / nitrogen_molar_mass_g_per_mol;
        mineral_state.matrix.amount_mol[mineral_first + @intFromEnum(mineral.Species.ammonia_band)] =
            gas_state.band_dissolved_mass_g[gas_index] / nitrogen_molar_mass_g_per_mol;
    }
}

/// Removes restart-stale transient NH3 mirrors without touching gaseous NH3.
pub fn clearTransient(gas_state: *gas.State) !void {
    try gas_state.validateShape();
    for (0..gas_state.cell_count) |cell| {
        const index = cell * gas.species_count + @intFromEnum(gas.Species.ammonia);
        gas_state.dissolved_mass_g[index] = 0;
        gas_state.band_dissolved_mass_g[index] = 0;
        gas_state.macropore_dissolved_mass_g[index] = 0;
    }
}

fn validateDimensions(mineral_state: *const mineral.State, gas_state: *const gas.State, nitrogen_molar_mass_g_per_mol: f64) !void {
    if (!std.math.isFinite(nitrogen_molar_mass_g_per_mol) or nitrogen_molar_mass_g_per_mol <= 0)
        return error.InvalidNitrogenMolarMass;
    if (mineral_state.cell_count == 0 or gas_state.cell_count != mineral_state.cell_count)
        return error.AmmoniaPhaseBridgeDimensionMismatch;
    try mineral_state.validate();
    try gas_state.validateShape();
}

test "mineral ammonia is the sole owner and transient round trip is exact" {
    var mineral_state = try mineral.State.init(std.testing.allocator, 2);
    defer mineral_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    mineral_state.matrix.amount_mol[@intFromEnum(mineral.Species.ammonia_non_band)] = 2;
    mineral_state.matrix.amount_mol[@intFromEnum(mineral.Species.ammonia_band)] = 3;
    const second = mineral.species_count;
    mineral_state.matrix.amount_mol[second + @intFromEnum(mineral.Species.ammonia_non_band)] = 5;
    mineral_state.matrix.amount_mol[second + @intFromEnum(mineral.Species.ammonia_band)] = 7;

    try refreshTransientFromMineral(&mineral_state, &gas_state, 14.01);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    try std.testing.expectApproxEqAbs(@as(f64, 28.02), gas_state.dissolved_mass_g[ammonia], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 42.03), gas_state.band_dissolved_mass_g[ammonia], 1e-14);
    gas_state.dissolved_mass_g[ammonia] -= 1.401;
    gas_state.band_dissolved_mass_g[ammonia] += 1.401;
    try publishTransientToMineral(&mineral_state, &gas_state, 14.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.9), mineral_state.matrix.amount_mol[@intFromEnum(mineral.Species.ammonia_non_band)], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 3.1), mineral_state.matrix.amount_mol[@intFromEnum(mineral.Species.ammonia_band)], 1e-14);
}

test "same-hour reaction ammonia refresh reaches the root gas consumer" {
    const chemistry_module = @import("../solute/chemistry_state.zig");
    const reactive_module = @import("../nutrients/reactive_nitrogen_state.zig");
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var reactive = try reactive_module.State.init(std.testing.allocator, 1, 1);
    defer reactive.deinit();
    var mineral_state = try mineral.State.init(std.testing.allocator, 1);
    defer mineral_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();

    // Represent an hour-start mirror which predates NITRO, then publish the
    // current reaction result. The production bridge must consume the latter.
    mineral_state.matrix.amount_mol[@intFromEnum(mineral.Species.ammonia_non_band)] = 99;
    mineral_state.matrix.amount_mol[@intFromEnum(mineral.Species.ammonia_band)] = 88;
    chemistry.aqueous[0].ammonia_non_band = 3;
    chemistry.aqueous[0].ammonia_band = 4;
    const fractions: mineral.ZoneFractions = .{
        .ammonium_non_band = 0.75,
        .ammonium_band = 0.25,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
    };
    try mineral_state.refreshMatrixFromReactionState(
        &chemistry,
        &reactive,
        &.{2},
        fractions,
        14,
    );
    try refreshTransientFromMineral(&mineral_state, &gas_state, 14);

    const ammonia = @intFromEnum(gas.Species.ammonia);
    try std.testing.expectEqual(@as(f64, 3 * 2 * 0.75 * 14), gas_state.dissolved_mass_g[ammonia]);
    try std.testing.expectEqual(@as(f64, 4 * 2 * 0.25 * 14), gas_state.band_dissolved_mass_g[ammonia]);
}

test "invalid later transient cell leaves every mineral ammonia owner unchanged" {
    var mineral_state = try mineral.State.init(std.testing.allocator, 2);
    defer mineral_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    mineral_state.matrix.amount_mol[@intFromEnum(mineral.Species.ammonia_non_band)] = 2;
    mineral_state.matrix.amount_mol[mineral.species_count + @intFromEnum(mineral.Species.ammonia_non_band)] = 5;
    try refreshTransientFromMineral(&mineral_state, &gas_state, 14);
    const bad = gas.species_count + @intFromEnum(gas.Species.ammonia);
    gas_state.dissolved_mass_g[bad] = std.math.nan(f64);
    const before = try std.testing.allocator.dupe(f64, mineral_state.matrix.amount_mol);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(error.InvalidTransientAmmoniaInventory, publishTransientToMineral(&mineral_state, &gas_state, 14));
    try std.testing.expectEqualSlices(f64, before, mineral_state.matrix.amount_mol);
}

test "accepted volatilization debits the sole mineral ammonia owner and books the gas boundary once" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 80 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.matrix_air_volume_m3, 0.25);
    @memset(grid.air_volume_m3, 0.25);
    @memset(grid.matrix_liquid_water_m3, 0.25);
    @memset(grid.soil_temperature_k, 298.15);

    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var geometry = try geometry_module.State.initMapped(std.testing.allocator, &grid, &faces, &.{1}, &.{1}, &.{1});
    defer geometry.deinit();
    var mineral_state = try mineral.State.init(std.testing.allocator, 1);
    defer mineral_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var step = try gas_step.State.init(std.testing.allocator, 1);
    defer step.deinit();

    const ammonia = @intFromEnum(gas.Species.ammonia);
    const nitrogen = @intFromEnum(gas.Species.nitrogen);
    const nitrogen_molar_mass_g_per_mol = 14.0;
    // Fill the pore air to its ideal-gas dry-air capacity with N2 so the
    // boundary response measures NH3 volatilization, not initialization of an
    // artificially empty air phase.
    const dry_air_capacity_mol = 1.2194e4 * grid.matrix_air_volume_m3[0] / grid.soil_temperature_k[0];
    gas_state.gaseous_mass_g[nitrogen] = dry_air_capacity_mol * gas.g_per_mol_tracked[nitrogen];
    mineral_state.matrix.amount_mol[@intFromEnum(mineral.Species.ammonia_non_band)] = 0.1;
    mineral_state.matrix.amount_mol[@intFromEnum(mineral.Species.ammonia_band)] = 0.05;
    try refreshTransientFromMineral(&mineral_state, &gas_state, nitrogen_molar_mass_g_per_mol);
    const initial_nitrogen_g = gas_state.gaseous_mass_g[ammonia] +
        gas_state.dissolved_mass_g[ammonia] + gas_state.band_dissolved_mass_g[ammonia];

    var reference_water_to_air = [_]f64{1e-12} ** gas.species_count;
    reference_water_to_air[ammonia] = 1;
    const solubility = gas.SurfaceSolubilityParameters{
        .reference_water_to_air = reference_water_to_air,
        .log_intercept = [_]f64{0} ** gas.species_count,
        .temperature_coefficient_per_c = [_]f64{0} ** gas.species_count,
    };
    var atmosphere = [_]f64{0} ** gas.species_count;
    atmosphere[nitrogen] = gas_state.gaseous_mass_g[nitrogen] / grid.matrix_air_volume_m3[0];
    var request: gas_step.AdvanceRequest = .{
        .grid = &grid,
        .hydrology = &hydrology,
        .soil_faces = &faces,
        .geometry = &geometry,
        .matrix_bulk_volume_m3 = &.{1},
        .total_porosity_fraction = &.{0.5},
        .field_capacity_fraction = &.{0.3},
        .gas_state = &gas_state,
        .solubility_parameters = solubility,
        .exchange_parameters = .{ .reference_time_h = 1, .wet_exponent = 12, .dry_exponent = 12, .transition_water_fraction = 0.5, .iteration_fraction = 0, .aqueous_tortuosity_coefficient = 0.7 },
        .ammonium_band_fraction = 0.25,
        .surface_boundary_inputs = .{
            .atmospheric_conductance_m3_per_step = &.{0.1},
            .cell_area_m2 = &.{2},
            .top_layer_thickness_m = &.{1},
            .atmospheric_concentration_g_per_m3 = &atmosphere,
        },
        .subsurface_boundary_inputs = null,
        .parameters = .{},
        .solver_options = .{
            .absolute_tolerance_g_by_species = .{ 1e-10, 1e-10, 1e-9, 1e-10, 1e-10, 1e-12, 1e-12 },
            .relative_tolerance = 1e-9,
            .max_iterations = 1,
        },
    };
    const gaseous_before = gas_state.gaseous_mass_g[0..gas.species_count].*;
    const dissolved_before = gas_state.dissolved_mass_g[0..gas.species_count].*;
    const band_before = gas_state.band_dissolved_mass_g[0..gas.species_count].*;
    if (step.advance(request)) |_| return error.ExpectedCoupledGasFailure else |_| {}
    try std.testing.expectEqualSlices(f64, &gaseous_before, gas_state.gaseous_mass_g);
    try std.testing.expectEqualSlices(f64, &dissolved_before, gas_state.dissolved_mass_g);
    try std.testing.expectEqualSlices(f64, &band_before, gas_state.band_dissolved_mass_g);
    for (step.atmospheric_flux_g_per_h) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (step.subsurface_flux_g_per_h) |value| try std.testing.expectEqual(@as(f64, 0), value);

    request.solver_options.max_iterations = 80;
    _ = try step.advance(request);
    try publishTransientToMineral(&mineral_state, &gas_state, nitrogen_molar_mass_g_per_mol);

    const final_mineral_nitrogen_g = nitrogen_molar_mass_g_per_mol *
        (mineral_state.matrix.amount_mol[@intFromEnum(mineral.Species.ammonia_non_band)] +
            mineral_state.matrix.amount_mol[@intFromEnum(mineral.Species.ammonia_band)]);
    const final_nitrogen_g = gas_state.gaseous_mass_g[ammonia] + final_mineral_nitrogen_g;
    const boundary_input_g = step.atmospheric_flux_g_per_h[ammonia];
    try std.testing.expect(boundary_input_g < 0);
    try std.testing.expectApproxEqAbs(initial_nitrogen_g + boundary_input_g, final_nitrogen_g, 1e-9);
}

test "production order brackets the gas solve and rollback owns both ammonia representations" {
    const source = @embedFile("../../stages/hourly_heat_water_solute.zig");
    const mineral_advance = std.mem.indexOf(u8, source, "ecosys.mineral_nitrogen_transport.advance") orelse return error.MissingMineralNitrogenAdvance;
    const refresh = std.mem.indexOf(u8, source, "soil_ammonia_phase_bridge.refreshTransientFromMineral") orelse return error.MissingAmmoniaRefresh;
    const generic_gas = std.mem.indexOf(u8, source, "soil_dissolved_gas_transport.advance") orelse return error.MissingGenericDissolvedGasAdvance;
    const coupled_gas = std.mem.indexOf(u8, source, "context.soil_gas_transport.advance") orelse return error.MissingCoupledGasAdvance;
    const publish = std.mem.indexOf(u8, source, "soil_ammonia_phase_bridge.publishTransientToMineral") orelse return error.MissingAmmoniaPublish;
    const gas_ledger = std.mem.indexOfPos(u8, source, publish, "addFiniteSlices(self.gas_atmospheric_total_g") orelse return error.MissingAcceptedAmmoniaBoundaryLedger;
    try std.testing.expect(mineral_advance < refresh);
    try std.testing.expect(refresh < generic_gas);
    try std.testing.expect(generic_gas < coupled_gas);
    try std.testing.expect(coupled_gas < publish);
    try std.testing.expect(publish < gas_ledger);

    const transaction_fields = std.mem.indexOf(u8, source, "fn captureStageTransactionalFields(") orelse return error.MissingStageTransactionOwner;
    try std.testing.expect(std.mem.indexOfPos(u8, source, transaction_fields, "\"gas_transport\"") != null);
    try std.testing.expect(std.mem.indexOfPos(u8, source, transaction_fields, "\"mineral_nitrogen_transport\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "SoilGasStepSnapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "schedule_snapshot.restore()") != null);
}
