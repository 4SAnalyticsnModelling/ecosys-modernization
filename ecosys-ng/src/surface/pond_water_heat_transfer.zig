const std = @import("std");
const GridState = @import("../state/grid.zig").GridState;
const thermal_module = @import("../soil/heat/thermal.zig");
const surface_geometry_module = @import("litter_geometry_step.zig");
const conservation_sidecar = @import("pond_conservation_sidecar.zig");

pub const Parameters = struct {
    dry_organic_heat_capacity_megajoules_per_g_c_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    minimum_heat_capacity_megajoules_per_k: f64,
    ice_density_megagrams_per_m3: f64 = 0.917,
};

pub const Owners = struct {
    surface_liquid_water_m3: []f64,
    surface_ice_m3: []f64,
    surface_temperature_k: []f64,
    surface_geometry: *surface_geometry_module.State,
    grid: *GridState,
    soil_thermal: *thermal_module.State,
};

pub const Inputs = struct {
    cell: usize,
    destination_soil_layer: usize,
    fraction: f64,
    surface_organic_carbon_g_c: f64,
    /// Canonical surface water-vapor storage expressed as liquid-water-
    /// equivalent m3. The full pond-domain transaction derives this from its
    /// gas-owner mol with configured molar mass and density.
    surface_vapor_water_equivalent_m3: f64 = 0,
    parameters: Parameters,
};

const Candidate = struct {
    surface_liquid_water_m3: f64,
    surface_ice_m3: f64,
    surface_temperature_k: f64,
    surface_water_retention_capacity_m3: f64,
    surface_dry_litter_volume_m3: f64,
    surface_total_volume_m3: f64,
    surface_dry_mass_megagrams: f64,
    surface_pore_volume_m3: f64,
    surface_air_volume_m3: f64,
    soil_matrix_liquid_water_m3: f64,
    soil_matrix_ice_water_m3: f64,
    soil_matrix_pore_capacity_m3: f64,
    soil_matrix_air_volume_m3: f64,
    soil_water_vapor_volume_m3: f64,
    soil_layer_volume_m3: f64,
    soil_dry_heat_capacity_megajoules_per_k: f64,
    soil_total_heat_capacity_megajoules_per_k: f64,
    soil_temperature_k: f64,
};

pub fn transferSurfaceFractionToSoil(owners: Owners, inputs: Inputs) !void {
    const next = try calculate(owners, inputs);
    const destination = inputs.cell * owners.grid.soil_layer_capacity + inputs.destination_soil_layer;
    owners.surface_liquid_water_m3[inputs.cell] = next.surface_liquid_water_m3;
    owners.surface_ice_m3[inputs.cell] = next.surface_ice_m3;
    owners.surface_temperature_k[inputs.cell] = next.surface_temperature_k;
    owners.surface_geometry.water_retention_capacity_m3[inputs.cell] = next.surface_water_retention_capacity_m3;
    owners.surface_geometry.dry_litter_volume_m3[inputs.cell] = next.surface_dry_litter_volume_m3;
    owners.surface_geometry.expanded_total_volume_m3[inputs.cell] = next.surface_total_volume_m3;
    owners.surface_geometry.dry_mass_megagrams[inputs.cell] = next.surface_dry_mass_megagrams;
    owners.surface_geometry.pore_volume_m3[inputs.cell] = next.surface_pore_volume_m3;
    owners.surface_geometry.air_volume_m3[inputs.cell] = next.surface_air_volume_m3;
    // A pond/litter redistribution is an IFLGS disturbance. The next HOUR1
    // consumes that cycle's signed DORGCC while advancing ORGCCX every cycle.
    owners.surface_geometry.retention_refresh_pending[inputs.cell] = 1;
    owners.grid.matrix_liquid_water_m3[destination] = next.soil_matrix_liquid_water_m3;
    owners.grid.matrix_ice_water_m3[destination] = next.soil_matrix_ice_water_m3;
    owners.grid.matrix_pore_capacity_m3[destination] = next.soil_matrix_pore_capacity_m3;
    owners.grid.matrix_air_volume_m3[destination] = next.soil_matrix_air_volume_m3;
    owners.grid.water_vapor_volume_m3[destination] = next.soil_water_vapor_volume_m3;
    owners.grid.liquid_water_m3[destination] = next.soil_matrix_liquid_water_m3 + owners.grid.macropore_liquid_water_m3[destination];
    owners.grid.ice_water_m3[destination] = next.soil_matrix_ice_water_m3 + owners.grid.macropore_ice_water_m3[destination];
    owners.grid.air_volume_m3[destination] = next.soil_matrix_air_volume_m3 + owners.grid.macropore_air_volume_m3[destination];
    owners.grid.soil_temperature_k[destination] = next.soil_temperature_k;
    owners.soil_thermal.layer_volume_m3[destination] = next.soil_layer_volume_m3;
    owners.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k[destination] = next.soil_dry_heat_capacity_megajoules_per_k / next.soil_layer_volume_m3;
    owners.soil_thermal.total_heat_capacity_megajoules_per_m3_k[destination] = next.soil_total_heat_capacity_megajoules_per_k / next.soil_layer_volume_m3;
    owners.soil_thermal.porosity_fraction[destination] = (next.soil_matrix_pore_capacity_m3 + owners.grid.macropore_pore_capacity_m3[destination]) / next.soil_layer_volume_m3;
}

pub fn validateSurfaceFractionToSoil(owners: Owners, inputs: Inputs) !void {
    _ = try calculate(owners, inputs);
}

/// Exact accepted water-equivalent and sensible-energy transfer produced by
/// the same capped-pore calculation as the state update. Ice owners are stored
/// in ice-volume units here, so `/ ice_density` converts only the conservation
/// sidecar to liquid-water-equivalent m3.
pub fn acceptedTransfer(owners: Owners, inputs: Inputs) !conservation_sidecar.Transfer {
    const next = try calculate(owners, inputs);
    const liquid_m3 = owners.surface_liquid_water_m3[inputs.cell] - next.surface_liquid_water_m3;
    const ice_m3 = owners.surface_ice_m3[inputs.cell] - next.surface_ice_m3;
    const vapor_water_equivalent_m3 = inputs.fraction * inputs.surface_vapor_water_equivalent_m3;
    const dry_capacity = inputs.fraction *
        inputs.parameters.dry_organic_heat_capacity_megajoules_per_g_c_k *
        inputs.surface_organic_carbon_g_c;
    const heat_capacity = dry_capacity +
        liquid_m3 * inputs.parameters.liquid_water_heat_capacity_megajoules_per_m3_k +
        vapor_water_equivalent_m3 * inputs.parameters.liquid_water_heat_capacity_megajoules_per_m3_k +
        ice_m3 * inputs.parameters.ice_heat_capacity_megajoules_per_m3_k /
            inputs.parameters.ice_density_megagrams_per_m3;
    const result: conservation_sidecar.Transfer = .{
        .water_m3 = liquid_m3 + ice_m3 / inputs.parameters.ice_density_megagrams_per_m3 + vapor_water_equivalent_m3,
        .heat_megajoules = heat_capacity * owners.surface_temperature_k[inputs.cell],
    };
    try result.validate();
    return result;
}

fn calculate(owners: Owners, inputs: Inputs) !Candidate {
    if (inputs.cell >= owners.grid.cell_count or inputs.destination_soil_layer >= owners.grid.soil_layer_capacity or inputs.cell >= owners.surface_liquid_water_m3.len or inputs.cell >= owners.surface_ice_m3.len or inputs.cell >= owners.surface_temperature_k.len or inputs.cell >= owners.surface_geometry.cell_count) return error.SurfacePondWaterHeatIndexOutOfBounds;
    const destination = inputs.cell * owners.grid.soil_layer_capacity + inputs.destination_soil_layer;
    if (destination >= owners.grid.layer_count or destination >= owners.soil_thermal.layer_volume_m3.len) return error.SurfacePondWaterHeatDimensionMismatch;
    inline for (.{
        inputs.fraction,                                                              inputs.surface_organic_carbon_g_c,
        inputs.surface_vapor_water_equivalent_m3,                                     inputs.parameters.dry_organic_heat_capacity_megajoules_per_g_c_k,
        inputs.parameters.liquid_water_heat_capacity_megajoules_per_m3_k,             inputs.parameters.ice_heat_capacity_megajoules_per_m3_k,
        inputs.parameters.minimum_heat_capacity_megajoules_per_k,                     owners.surface_liquid_water_m3[inputs.cell],
        owners.surface_ice_m3[inputs.cell],                                           owners.surface_temperature_k[inputs.cell],
        owners.surface_geometry.water_retention_capacity_m3[inputs.cell],             owners.surface_geometry.dry_litter_volume_m3[inputs.cell],
        owners.surface_geometry.expanded_total_volume_m3[inputs.cell],                owners.surface_geometry.dry_mass_megagrams[inputs.cell],
        owners.surface_geometry.pore_volume_m3[inputs.cell],                          owners.surface_geometry.air_volume_m3[inputs.cell],
        owners.grid.matrix_liquid_water_m3[destination],                              owners.grid.matrix_ice_water_m3[destination],
        owners.grid.matrix_pore_capacity_m3[destination],                             owners.grid.matrix_air_volume_m3[destination],
        owners.grid.soil_temperature_k[destination],                                  owners.soil_thermal.layer_volume_m3[destination],
        owners.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k[destination], owners.soil_thermal.total_heat_capacity_megajoules_per_m3_k[destination],
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfacePondWaterHeatState;
    if (inputs.fraction < 0 or inputs.fraction > 1 or inputs.parameters.dry_organic_heat_capacity_megajoules_per_g_c_k <= 0 or inputs.parameters.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or inputs.parameters.ice_heat_capacity_megajoules_per_m3_k <= 0 or inputs.parameters.minimum_heat_capacity_megajoules_per_k < 0 or inputs.parameters.ice_density_megagrams_per_m3 <= 0 or inputs.parameters.ice_density_megagrams_per_m3 > 1 or owners.surface_temperature_k[inputs.cell] <= 0 or owners.grid.soil_temperature_k[destination] <= 0 or owners.soil_thermal.layer_volume_m3[destination] <= 0) return error.InvalidSurfacePondWaterHeatState;

    const fraction = inputs.fraction;
    const remaining = 1 - fraction;
    const ice_capacity_per_water_equivalent_m3_k = inputs.parameters.ice_heat_capacity_megajoules_per_m3_k / inputs.parameters.ice_density_megagrams_per_m3;
    const surface_dry_heat_capacity = inputs.parameters.dry_organic_heat_capacity_megajoules_per_g_c_k * inputs.surface_organic_carbon_g_c;
    const surface_vapor_water_equivalent_m3 = inputs.surface_vapor_water_equivalent_m3;
    const soil_dry_heat_capacity = owners.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k[destination] * owners.soil_thermal.layer_volume_m3[destination];
    // HEAT-001: reconstruct the destination layer's incoming capacity from the
    // live carriers, using the identical WATSUB 252--254 definition applied to
    // the outgoing capacity below and by the EXEC landscape census
    // (`landscape_mass_inventory.zig` 230--235). Reading the cached
    // `total_heat_capacity_megajoules_per_m3_k` table here made this transaction
    // asymmetric: production refreshes that table at `ecosys_ng.zig:4247`,
    // *before* the soil water/heat solve state_updates at `4278`, so by the time the
    // pond transaction runs the table lags the carriers by one solve. The
    // destination temperature was then solved against a capacity the census does
    // not agree with, which creates or destroys sensible heat at census level
    // even though this kernel's own books balance.
    const soil_heat_capacity_before = soil_dry_heat_capacity +
        inputs.parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
            (owners.grid.matrix_liquid_water_m3[destination] +
                owners.grid.macropore_liquid_water_m3[destination] +
                owners.grid.water_vapor_volume_m3[destination]) +
        ice_capacity_per_water_equivalent_m3_k *
            (owners.grid.matrix_ice_water_m3[destination] +
                owners.grid.macropore_ice_water_m3[destination]);
    // Pore capacity grows only by the dry structural pore space of the incorporated
    // litter fraction. Water carried above that capacity stays at the surface and
    // drains through normal gravity-driven soil flow in subsequent steps. Allowing
    // pore capacity to track water volume created a positive feedback: expanded
    // pores refilled by the water table → saturated soil → all precipitation
    // overflowed to litter → pond transition expanded pores further each hour.
    const natural_new_pore = owners.grid.matrix_pore_capacity_m3[destination] +
        fraction * owners.surface_geometry.pore_volume_m3[inputs.cell];
    const existing_soil_water_ice =
        owners.grid.matrix_liquid_water_m3[destination] + owners.grid.matrix_ice_water_m3[destination] / inputs.parameters.ice_density_megagrams_per_m3;
    const litter_liquid = owners.surface_liquid_water_m3[inputs.cell];
    const litter_ice = owners.surface_ice_m3[inputs.cell];
    const wanted_water_ice = fraction * (litter_liquid + litter_ice / inputs.parameters.ice_density_megagrams_per_m3);
    const water_transfer_scale = if (wanted_water_ice > 0.0)
        @min(1.0, @max(0.0, natural_new_pore - existing_soil_water_ice) / wanted_water_ice)
    else
        1.0;
    const actual_liquid_in = fraction * litter_liquid * water_transfer_scale;
    const actual_ice_in = fraction * litter_ice * water_transfer_scale;
    const actual_vapor_in = fraction * surface_vapor_water_equivalent_m3;
    const rejected_liquid = fraction * litter_liquid - actual_liquid_in;
    const rejected_ice = fraction * litter_ice - actual_ice_in;
    const moved_surface_energy = (fraction * surface_dry_heat_capacity +
        actual_liquid_in * inputs.parameters.liquid_water_heat_capacity_megajoules_per_m3_k +
        actual_vapor_in * inputs.parameters.liquid_water_heat_capacity_megajoules_per_m3_k +
        actual_ice_in * ice_capacity_per_water_equivalent_m3_k) *
        owners.surface_temperature_k[inputs.cell];

    var result: Candidate = .{
        .surface_liquid_water_m3 = remaining * litter_liquid + rejected_liquid,
        .surface_ice_m3 = remaining * litter_ice + rejected_ice,
        .surface_temperature_k = undefined,
        .surface_water_retention_capacity_m3 = remaining * owners.surface_geometry.water_retention_capacity_m3[inputs.cell],
        .surface_dry_litter_volume_m3 = remaining * owners.surface_geometry.dry_litter_volume_m3[inputs.cell],
        .surface_total_volume_m3 = remaining * owners.surface_geometry.expanded_total_volume_m3[inputs.cell],
        .surface_dry_mass_megagrams = remaining * owners.surface_geometry.dry_mass_megagrams[inputs.cell],
        .surface_pore_volume_m3 = remaining * owners.surface_geometry.pore_volume_m3[inputs.cell],
        .surface_air_volume_m3 = remaining * owners.surface_geometry.air_volume_m3[inputs.cell],
        .soil_matrix_liquid_water_m3 = owners.grid.matrix_liquid_water_m3[destination] + actual_liquid_in,
        .soil_matrix_ice_water_m3 = owners.grid.matrix_ice_water_m3[destination] + actual_ice_in,
        .soil_matrix_pore_capacity_m3 = undefined,
        .soil_matrix_air_volume_m3 = undefined,
        .soil_water_vapor_volume_m3 = owners.grid.water_vapor_volume_m3[destination] + actual_vapor_in,
        .soil_layer_volume_m3 = owners.soil_thermal.layer_volume_m3[destination] + fraction * owners.surface_geometry.dry_litter_volume_m3[inputs.cell],
        .soil_dry_heat_capacity_megajoules_per_k = soil_dry_heat_capacity + fraction * surface_dry_heat_capacity,
        .soil_total_heat_capacity_megajoules_per_k = undefined,
        .soil_temperature_k = undefined,
    };
    result.soil_matrix_pore_capacity_m3 = natural_new_pore;
    if (result.soil_matrix_pore_capacity_m3 >
        result.soil_layer_volume_m3 + 1e-12)
        return error.SurfacePondWaterExceedsTransferredLayerVolume;
    result.soil_matrix_air_volume_m3 = @max(
        0,
        result.soil_matrix_pore_capacity_m3 -
            result.soil_matrix_liquid_water_m3 -
            result.soil_matrix_ice_water_m3 / inputs.parameters.ice_density_megagrams_per_m3,
    );
    // WATSUB lines 252--254 give the vapor volume `VOLV1` liquid heat capacity,
    // and both `soil_thermal` and the EXEC census reconstruct it that way. The
    // `soil_heat_capacity_before` above reads the cached table, which includes
    // that term, so omitting it here would delete the destination layer's vapor
    // capacity on every surface-to-soil transfer. This transaction now moves
    // the accepted surface-vapor water equivalent and its enthalpy into the
    // canonical soil vapor volume; the gas-state molar field is rebound as a
    // mirror by the enclosing pond-domain transaction.
    result.soil_total_heat_capacity_megajoules_per_k = result.soil_dry_heat_capacity_megajoules_per_k +
        inputs.parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (result.soil_matrix_liquid_water_m3 + owners.grid.macropore_liquid_water_m3[destination] + result.soil_water_vapor_volume_m3) +
        ice_capacity_per_water_equivalent_m3_k * (result.soil_matrix_ice_water_m3 + owners.grid.macropore_ice_water_m3[destination]);
    result.soil_temperature_k = if (result.soil_total_heat_capacity_megajoules_per_k > inputs.parameters.minimum_heat_capacity_megajoules_per_k)
        (soil_heat_capacity_before * owners.grid.soil_temperature_k[destination] + moved_surface_energy) / result.soil_total_heat_capacity_megajoules_per_k
    else
        owners.surface_temperature_k[inputs.cell];
    const remaining_surface_heat_capacity = surface_dry_heat_capacity * remaining +
        inputs.parameters.liquid_water_heat_capacity_megajoules_per_m3_k * result.surface_liquid_water_m3 +
        inputs.parameters.liquid_water_heat_capacity_megajoules_per_m3_k * remaining * surface_vapor_water_equivalent_m3 +
        ice_capacity_per_water_equivalent_m3_k * result.surface_ice_m3;
    result.surface_temperature_k = if (remaining_surface_heat_capacity > inputs.parameters.minimum_heat_capacity_megajoules_per_k)
        owners.surface_temperature_k[inputs.cell]
    else
        result.soil_temperature_k;
    inline for (.{ result.soil_total_heat_capacity_megajoules_per_k, result.soil_temperature_k, result.surface_temperature_k, result.soil_layer_volume_m3 }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSurfacePondWaterHeatResult;
    return result;
}

test "surface pond water heat and matrix geometry transfer conserve energy" {
    const config = try @import("../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var geometry = try surface_geometry_module.State.init(std.testing.allocator, 1);
    defer geometry.deinit();
    var thermal: thermal_module.State = undefined;
    var layer_volume = [_]f64{2};
    var dry_capacity = [_]f64{1};
    var total_capacity = [_]f64{2};
    var porosity = [_]f64{0.5};
    thermal.layer_volume_m3 = &layer_volume;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_capacity;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_capacity;
    thermal.porosity_fraction = &porosity;
    var surface_water = [_]f64{0.4};
    var surface_ice = [_]f64{0.2};
    grid.surface_temperature_k[0] = 280;
    grid.soil_temperature_k[0] = 290;
    grid.matrix_liquid_water_m3[0] = 0.3;
    grid.matrix_ice_water_m3[0] = 0.1;
    // pore_capacity = 1.0 → natural_new_pore = 1.3, available = 0.9 > wanted = 0.3 → transfer_scale = 1.0
    grid.matrix_pore_capacity_m3[0] = 1.0;
    geometry.dry_litter_volume_m3[0] = 0.2;
    geometry.expanded_total_volume_m3[0] = 1;
    geometry.water_retention_capacity_m3[0] = 0.3;
    geometry.dry_mass_megagrams[0] = 0.01;
    geometry.pore_volume_m3[0] = 0.6;
    geometry.air_volume_m3[0] = 0.2;
    const parameters: Parameters = .{ .dry_organic_heat_capacity_megajoules_per_g_c_k = 2.496e-6, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .minimum_heat_capacity_megajoules_per_k = 0 };
    const surface_vapor_water_equivalent_m3 = 0.1;
    const surface_capacity = parameters.dry_organic_heat_capacity_megajoules_per_g_c_k * 100 + parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (0.4 + surface_vapor_water_equivalent_m3) + parameters.ice_heat_capacity_megajoules_per_m3_k / parameters.ice_density_megagrams_per_m3 * 0.2;
    // HEAT-001: the destination's incoming capacity is the census definition of
    // the live carriers, not the cached `total_capacity` table. This test
    // previously asserted against the cached `2 * 2 = 4`, which is exactly the
    // asymmetry that let the pond transaction create sensible heat at census
    // level. Seed the cached table consistently so both readings agree.
    const soil_capacity_before = dry_capacity[0] * layer_volume[0] +
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (grid.matrix_liquid_water_m3[0] + grid.macropore_liquid_water_m3[0] + grid.water_vapor_volume_m3[0]) +
        parameters.ice_heat_capacity_megajoules_per_m3_k / parameters.ice_density_megagrams_per_m3 * (grid.matrix_ice_water_m3[0] + grid.macropore_ice_water_m3[0]);
    total_capacity[0] = soil_capacity_before / layer_volume[0];
    const initial_energy = surface_capacity * 280 + soil_capacity_before * 290;
    const owners: Owners = .{ .surface_liquid_water_m3 = &surface_water, .surface_ice_m3 = &surface_ice, .surface_temperature_k = grid.surface_temperature_k, .surface_geometry = &geometry, .grid = &grid, .soil_thermal = &thermal };
    const transfer = try acceptedTransfer(owners, .{ .cell = 0, .destination_soil_layer = 0, .fraction = 0.5, .surface_organic_carbon_g_c = 100, .surface_vapor_water_equivalent_m3 = surface_vapor_water_equivalent_m3, .parameters = parameters });
    try transferSurfaceFractionToSoil(owners, .{ .cell = 0, .destination_soil_layer = 0, .fraction = 0.5, .surface_organic_carbon_g_c = 100, .surface_vapor_water_equivalent_m3 = surface_vapor_water_equivalent_m3, .parameters = parameters });
    const remaining_surface_capacity = 0.5 * surface_capacity;
    const final_energy = remaining_surface_capacity * grid.surface_temperature_k[0] +
        thermal.total_heat_capacity_megajoules_per_m3_k[0] * thermal.layer_volume_m3[0] * grid.soil_temperature_k[0];
    try std.testing.expectApproxEqAbs(initial_energy, final_energy, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), grid.water_vapor_volume_m3[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2 + 0.1 / parameters.ice_density_megagrams_per_m3 + 0.05), transfer.water_m3, 1e-15);
    try std.testing.expectApproxEqAbs(0.5 * surface_capacity * 280, transfer.heat_megajoules, 1e-12);
    try std.testing.expectEqual(@as(f64, 0.2), surface_water[0]);
    try std.testing.expectEqual(@as(f64, 0.5), geometry.expanded_total_volume_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.15), geometry.water_retention_capacity_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.005), geometry.dry_mass_megagrams[0]);
}

test "surface pond transfer conserves census energy against a stale capacity table" {
    // HEAT-001 regression. Production refreshes `soil_thermal` at
    // `ecosys_ng.zig:4247`, before the soil water/heat solve state_updates at `4278`,
    // so when this transaction runs the cached
    // `total_heat_capacity_megajoules_per_m3_k` lags the live carriers. Reading
    // that table for the destination's incoming capacity therefore solved the
    // destination temperature against a capacity the EXEC census does not agree
    // with. This asserts the result is independent of the cached table's value.
    const config = try @import("../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    const parameters: Parameters = .{ .dry_organic_heat_capacity_megajoules_per_g_c_k = 2.496e-6, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .minimum_heat_capacity_megajoules_per_k = 0 };

    // Two runs, identical live carriers, cached table stale by different amounts.
    var results: [2]f64 = undefined;
    for ([_]f64{ 1.0, 0.4 }, 0..) |staleness_scale, run| {
        var grid = try GridState.init(std.testing.allocator, config);
        defer grid.deinit();
        var geometry = try surface_geometry_module.State.init(std.testing.allocator, 1);
        defer geometry.deinit();
        var thermal: thermal_module.State = undefined;
        var layer_volume = [_]f64{2};
        var dry_capacity = [_]f64{1};
        var total_capacity = [_]f64{0};
        var porosity = [_]f64{0.5};
        thermal.layer_volume_m3 = &layer_volume;
        thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_capacity;
        thermal.total_heat_capacity_megajoules_per_m3_k = &total_capacity;
        thermal.porosity_fraction = &porosity;
        var surface_water = [_]f64{0.4};
        var surface_ice = [_]f64{0.2};
        grid.surface_temperature_k[0] = 280;
        grid.soil_temperature_k[0] = 290;
        grid.matrix_liquid_water_m3[0] = 0.3;
        grid.matrix_ice_water_m3[0] = 0.1;
        grid.matrix_pore_capacity_m3[0] = 1.0;
        grid.water_vapor_volume_m3[0] = 0.05;
        geometry.dry_litter_volume_m3[0] = 0.2;
        geometry.expanded_total_volume_m3[0] = 1;
        geometry.water_retention_capacity_m3[0] = 0.3;
        geometry.dry_mass_megagrams[0] = 0.01;
        geometry.pore_volume_m3[0] = 0.6;
        geometry.air_volume_m3[0] = 0.2;

        const census_capacity_before = dry_capacity[0] * layer_volume[0] +
            parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (grid.matrix_liquid_water_m3[0] + grid.macropore_liquid_water_m3[0] + grid.water_vapor_volume_m3[0]) +
            parameters.ice_heat_capacity_megajoules_per_m3_k / parameters.ice_density_megagrams_per_m3 * (grid.matrix_ice_water_m3[0] + grid.macropore_ice_water_m3[0]);
        // Deliberately stale: `staleness_scale != 1` is what a pre-solve refresh
        // leaves behind once the solve has moved the carriers.
        total_capacity[0] = staleness_scale * census_capacity_before / layer_volume[0];

        const surface_capacity = parameters.dry_organic_heat_capacity_megajoules_per_g_c_k * 100 +
            parameters.liquid_water_heat_capacity_megajoules_per_m3_k * 0.4 +
            parameters.ice_heat_capacity_megajoules_per_m3_k / parameters.ice_density_megagrams_per_m3 * 0.2;
        const initial_census_energy = surface_capacity * 280 + census_capacity_before * 290;

        const owners: Owners = .{ .surface_liquid_water_m3 = &surface_water, .surface_ice_m3 = &surface_ice, .surface_temperature_k = grid.surface_temperature_k, .surface_geometry = &geometry, .grid = &grid, .soil_thermal = &thermal };
        try transferSurfaceFractionToSoil(owners, .{ .cell = 0, .destination_soil_layer = 0, .fraction = 0.5, .surface_organic_carbon_g_c = 100, .parameters = parameters });

        const census_capacity_after = thermal.dry_solid_heat_capacity_megajoules_per_m3_k[0] * thermal.layer_volume_m3[0] +
            parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (grid.matrix_liquid_water_m3[0] + grid.macropore_liquid_water_m3[0] + grid.water_vapor_volume_m3[0]) +
            parameters.ice_heat_capacity_megajoules_per_m3_k / parameters.ice_density_megagrams_per_m3 * (grid.matrix_ice_water_m3[0] + grid.macropore_ice_water_m3[0]);
        const final_census_energy = 0.5 * surface_capacity * grid.surface_temperature_k[0] + census_capacity_after * grid.soil_temperature_k[0];
        // The census must close regardless of the cached table's staleness.
        try std.testing.expectApproxEqRel(initial_census_energy, final_census_energy, 1e-12);
        results[run] = grid.soil_temperature_k[0];
    }
    // And the accepted destination temperature must not depend on the stale table.
    try std.testing.expectApproxEqRel(results[0], results[1], 1e-12);
}

test "surface pond transfer keeps the destination layer's vapor heat capacity" {
    // The census and `soil_thermal` both give `water_vapor_volume_m3` liquid heat
    // capacity, per WATSUB lines 252--254, and `soil_heat_capacity_before` reads
    // that cached table. Reconstructing the destination capacity without the
    // vapor term silently deleted it on every transfer.
    const config = try @import("../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var geometry = try surface_geometry_module.State.init(std.testing.allocator, 1);
    defer geometry.deinit();
    var thermal: thermal_module.State = undefined;
    var layer_volume = [_]f64{2};
    var dry_capacity = [_]f64{1};
    var total_capacity = [_]f64{0};
    var porosity = [_]f64{0.5};
    thermal.layer_volume_m3 = &layer_volume;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_capacity;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_capacity;
    thermal.porosity_fraction = &porosity;
    var surface_water = [_]f64{0.4};
    var surface_ice = [_]f64{0.2};
    grid.surface_temperature_k[0] = 280;
    grid.soil_temperature_k[0] = 290;
    grid.matrix_liquid_water_m3[0] = 0.3;
    grid.matrix_ice_water_m3[0] = 0.1;
    grid.matrix_pore_capacity_m3[0] = 1.0;
    // The destination layer holds vapor.
    grid.water_vapor_volume_m3[0] = 0.05;
    geometry.dry_litter_volume_m3[0] = 0.2;
    geometry.expanded_total_volume_m3[0] = 1;
    geometry.water_retention_capacity_m3[0] = 0.3;
    geometry.dry_mass_megagrams[0] = 0.01;
    geometry.pore_volume_m3[0] = 0.6;
    geometry.air_volume_m3[0] = 0.2;
    const parameters: Parameters = .{ .dry_organic_heat_capacity_megajoules_per_g_c_k = 2.496e-6, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .minimum_heat_capacity_megajoules_per_k = 0 };

    // Seed the cached table the way `soil_thermal.refresh` does, including vapor.
    const soil_capacity_before = dry_capacity[0] * layer_volume[0] +
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (grid.matrix_liquid_water_m3[0] + grid.macropore_liquid_water_m3[0] + grid.water_vapor_volume_m3[0]) +
        parameters.ice_heat_capacity_megajoules_per_m3_k / parameters.ice_density_megagrams_per_m3 * (grid.matrix_ice_water_m3[0] + grid.macropore_ice_water_m3[0]);
    total_capacity[0] = soil_capacity_before / layer_volume[0];

    const surface_capacity = parameters.dry_organic_heat_capacity_megajoules_per_g_c_k * 100 +
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k * 0.4 +
        parameters.ice_heat_capacity_megajoules_per_m3_k / parameters.ice_density_megagrams_per_m3 * 0.2;
    const initial_energy = surface_capacity * 280 + soil_capacity_before * 290;

    const owners: Owners = .{ .surface_liquid_water_m3 = &surface_water, .surface_ice_m3 = &surface_ice, .surface_temperature_k = grid.surface_temperature_k, .surface_geometry = &geometry, .grid = &grid, .soil_thermal = &thermal };
    try transferSurfaceFractionToSoil(owners, .{ .cell = 0, .destination_soil_layer = 0, .fraction = 0.5, .surface_organic_carbon_g_c = 100, .parameters = parameters });

    // The published capacity must equal the census definition of the same layer,
    // which includes vapor. Asserting only self-consistent energy would pass
    // either way, because the temperature is solved against whatever capacity the
    // transfer chose.
    const census_capacity_after = thermal.dry_solid_heat_capacity_megajoules_per_m3_k[0] * thermal.layer_volume_m3[0] +
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (grid.matrix_liquid_water_m3[0] + grid.macropore_liquid_water_m3[0] + grid.water_vapor_volume_m3[0]) +
        parameters.ice_heat_capacity_megajoules_per_m3_k / parameters.ice_density_megagrams_per_m3 * (grid.matrix_ice_water_m3[0] + grid.macropore_ice_water_m3[0]);
    const published_capacity_after = thermal.total_heat_capacity_megajoules_per_m3_k[0] * thermal.layer_volume_m3[0];
    try std.testing.expectApproxEqRel(census_capacity_after, published_capacity_after, 1e-12);

    // And energy is conserved against the census reading of both owners.
    const final_energy = 0.5 * surface_capacity * grid.surface_temperature_k[0] + census_capacity_after * grid.soil_temperature_k[0];
    try std.testing.expectApproxEqRel(initial_energy, final_energy, 1e-12);
}
