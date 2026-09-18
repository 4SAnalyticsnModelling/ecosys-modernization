const std = @import("std");
const Grid = @import("../../state/grid.zig");
const SoilChemistry = @import("../solute/chemistry_state.zig");
const SurfaceChemistry = @import("../../surface/litter_chemistry.zig");
const Phosphate = @import("../solute/phosphate_network.zig");
const ZoneFractions = @import("../solute/charge_classification.zig").ZoneFractions;

/// REDIST UPP4 inventory. Surface minerals use their persistent mineral-water
/// reference, which remains authoritative while live litter water is zero.
/// Soil fertilizer zones use their runtime water fractions before applying
/// the exact 1/1/1/3/2 phosphorus stoichiometry.
pub fn precipitatedPhosphorus_g_p(
    grid: *const Grid.GridState,
    soil: *const SoilChemistry.State,
    surface: *const SurfaceChemistry.State,
    soil_water_m3: []const f64,
    litter_water_m3: []const f64,
    cell: usize,
    fractions_source: anytype,
    phosphorus_molar_mass_g_per_mol: f64,
) !f64 {
    if (cell >= grid.cell_count or soil.cell_count != grid.layer_count or surface.cells.len != grid.cell_count or surface.mineral_reference_water_m3.len != grid.cell_count or soil_water_m3.len != grid.layer_count or litter_water_m3.len != grid.cell_count) return error.PhosphateInventoryDimensionMismatch;
    if (!std.math.isFinite(phosphorus_molar_mass_g_per_mol) or phosphorus_molar_mass_g_per_mol <= 0) return error.InvalidPhosphateInventory;
    var phosphorus_mol: f64 = 0;
    const surface_water = litter_water_m3[cell];
    const surface_mineral_reference = surface.mineral_reference_water_m3[cell];
    if (!std.math.isFinite(surface_water) or surface_water < 0 or
        !std.math.isFinite(surface_mineral_reference) or surface_mineral_reference < 0)
        return error.InvalidPhosphateInventory;
    const surface_minerals = surface.cells[cell].phosphate_minerals;
    phosphorus_mol += surface_mineral_reference * (surface_minerals.aluminum_phosphate_mol_per_m3 + surface_minerals.iron_phosphate_mol_per_m3 + surface_minerals.dicalcium_phosphate_mol_per_m3 + 3 * surface_minerals.hydroxyapatite_mol_per_m3 + 2 * surface_minerals.monocalcium_phosphate_mol_per_m3);
    for (0..grid.active_soil_layer_count[cell]) |local_layer| {
        const layer = try grid.layerIndex(cell, local_layer);
        const fractions = try phosphateFractionsAt(fractions_source, layer);
        try validateFractions(fractions);
        const water = soil_water_m3[layer];
        if (!std.math.isFinite(water) or water < 0) return error.InvalidPhosphateInventory;
        phosphorus_mol += water * (fractions.phosphate_non_band * solidPhosphorus_mol_per_m3(soil.non_band_phosphate[layer]) + fractions.phosphate_band * solidPhosphorus_mol_per_m3(soil.band_phosphate[layer]));
    }
    const result = phosphorus_mol * phosphorus_molar_mass_g_per_mol;
    if (!std.math.isFinite(result) or result < 0) return error.InvalidPhosphateInventory;
    return result;
}

fn solidPhosphorus_mol_per_m3(state: Phosphate.State) f64 {
    return state.aluminum_phosphate_solid_mol_per_m3 +
        state.iron_phosphate_solid_mol_per_m3 +
        state.dicalcium_phosphate_solid_mol_per_m3 +
        3 * state.hydroxyapatite_solid_mol_per_m3 +
        2 * state.monocalcium_phosphate_solid_mol_per_m3;
}

/// REDIST UPX4 inventory: adsorbed HPO4 plus H2PO4 on litter and soil
/// phosphate surfaces. Surface and soil concentrations are both mol P/Mg,
/// but use their distinct runtime dry-mass owners.
pub fn exchangeablePhosphorus_g_p(
    grid: *const Grid.GridState,
    soil: *const SoilChemistry.State,
    surface: *const SurfaceChemistry.State,
    matrix_bulk_volume_m3: []const f64,
    bulk_density_megagrams_per_m3: []const f64,
    litter_dry_mass_megagrams: []const f64,
    cell: usize,
    fractions_source: anytype,
    phosphorus_molar_mass_g_per_mol: f64,
) !f64 {
    if (cell >= grid.cell_count or soil.cell_count != grid.layer_count or surface.cells.len != grid.cell_count or matrix_bulk_volume_m3.len != grid.layer_count or bulk_density_megagrams_per_m3.len != grid.layer_count or litter_dry_mass_megagrams.len != grid.cell_count) return error.PhosphateInventoryDimensionMismatch;
    if (!std.math.isFinite(phosphorus_molar_mass_g_per_mol) or phosphorus_molar_mass_g_per_mol <= 0) return error.InvalidPhosphateInventory;
    const litter_mass = litter_dry_mass_megagrams[cell];
    if (!std.math.isFinite(litter_mass) or litter_mass < 0) return error.InvalidPhosphateInventory;
    const litter_sites = surface.cells[cell].phosphate_surface;
    var phosphorus_mol = litter_mass * (litter_sites.adsorbed_hpo4_mol_p_per_megagram + litter_sites.adsorbed_h2po4_mol_p_per_megagram);
    for (0..grid.active_soil_layer_count[cell]) |local_layer| {
        const layer = try grid.layerIndex(cell, local_layer);
        const fractions = try phosphateFractionsAt(fractions_source, layer);
        try validateFractions(fractions);
        const volume = matrix_bulk_volume_m3[layer];
        const density = bulk_density_megagrams_per_m3[layer];
        if (!std.math.isFinite(volume) or volume < 0 or !std.math.isFinite(density) or density < 0) return error.InvalidPhosphateInventory;
        const non_band = soil.non_band_phosphate[layer];
        const band = soil.band_phosphate[layer];
        phosphorus_mol += volume * density * (fractions.phosphate_non_band * (non_band.adsorbed_hpo4_mol_p_per_megagram + non_band.adsorbed_h2po4_mol_p_per_megagram) + fractions.phosphate_band * (band.adsorbed_hpo4_mol_p_per_megagram + band.adsorbed_h2po4_mol_p_per_megagram));
    }
    const result = phosphorus_mol * phosphorus_molar_mass_g_per_mol;
    if (!std.math.isFinite(result) or result < 0) return error.InvalidPhosphateInventory;
    return result;
}

/// REDIST UPO4: soluble HPO4 plus H2PO4 in surface litter and both runtime
/// soil fertilizer zones.
pub fn solublePhosphorus_g_p(
    grid: *const Grid.GridState,
    soil: *const SoilChemistry.State,
    surface: *const SurfaceChemistry.State,
    soil_water_m3: []const f64,
    litter_water_m3: []const f64,
    cell: usize,
    fractions_source: anytype,
    phosphorus_molar_mass_g_per_mol: f64,
) !f64 {
    if (cell >= grid.cell_count or soil.cell_count != grid.layer_count or surface.cells.len != grid.cell_count or surface.dry_reference_water_m3.len != grid.cell_count or soil_water_m3.len != grid.layer_count or litter_water_m3.len != grid.cell_count) return error.PhosphateInventoryDimensionMismatch;
    if (!std.math.isFinite(phosphorus_molar_mass_g_per_mol) or phosphorus_molar_mass_g_per_mol <= 0) return error.InvalidPhosphateInventory;
    const litter_water = litter_water_m3[cell];
    const dry_reference_water = surface.dry_reference_water_m3[cell];
    if (!std.math.isFinite(litter_water) or litter_water < 0 or
        !std.math.isFinite(dry_reference_water) or dry_reference_water < 0)
        return error.InvalidPhosphateInventory;
    const litter_aqueous_carrier = if (litter_water > 0) litter_water else dry_reference_water;
    const litter = surface.cells[cell];
    var phosphorus_mol = litter_aqueous_carrier * (litter.hpo4_mol_p_per_m3 + litter.h2po4_mol_p_per_m3);
    for (0..grid.active_soil_layer_count[cell]) |local_layer| {
        const layer = try grid.layerIndex(cell, local_layer);
        const fractions = try phosphateFractionsAt(fractions_source, layer);
        try validateFractions(fractions);
        const water = soil_water_m3[layer];
        if (!std.math.isFinite(water) or water < 0) return error.InvalidPhosphateInventory;
        const non_band = soil.non_band_phosphate[layer];
        const band = soil.band_phosphate[layer];
        phosphorus_mol += water * (fractions.phosphate_non_band * (non_band.dissolved_hpo4_mol_p_per_m3 + non_band.dissolved_h2po4_mol_p_per_m3) + fractions.phosphate_band * (band.dissolved_hpo4_mol_p_per_m3 + band.dissolved_h2po4_mol_p_per_m3));
    }
    const result = phosphorus_mol * phosphorus_molar_mass_g_per_mol;
    if (!std.math.isFinite(result) or result < 0) return error.InvalidPhosphateInventory;
    return result;
}

fn phosphateFractionsAt(source: anytype, layer: usize) !ZoneFractions {
    if (comptime @TypeOf(source) == ZoneFractions) return source;
    return source.scienceZoneFractionsForFlatIndex(layer);
}

fn validateFractions(fractions: ZoneFractions) !void {
    inline for (.{ fractions.phosphate_non_band, fractions.phosphate_band }) |value|
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidPhosphateInventory;
    if (@abs(fractions.phosphate_non_band + fractions.phosphate_band - 1) > 1e-12)
        return error.InvalidPhosphateInventory;
}

test "UPP4 applies exact phosphate mineral stoichiometry across runtime zones and surface" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try Grid.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var soil = try SoilChemistry.State.init(std.testing.allocator, grid.layer_count);
    defer soil.deinit();
    var surface = try SurfaceChemistry.State.init(std.testing.allocator, grid.cell_count);
    defer surface.deinit();
    soil.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3 = 2;
    soil.band_phosphate[0].hydroxyapatite_solid_mol_per_m3 = 4;
    soil.non_band_phosphate[1].monocalcium_phosphate_solid_mol_per_m3 = 3;
    surface.mineral_reference_water_m3[0] = 2;
    surface.cells[0].phosphate_minerals.iron_phosphate_mol_per_m3 = 5;
    const result = try precipitatedPhosphorus_g_p(&grid, &soil, &surface, &.{ 10, 20 }, &.{2}, 0, ZoneFractions{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 0.75, .phosphate_band = 0.25 }, 31);
    // surface 10 mol P; layer 0: 10*(1.5+3); layer 1: 20*4.5 mol P
    try std.testing.expectEqual(@as(f64, 145 * 31), result);
}

test "UPX4 uses distinct litter and soil masses with runtime phosphate zones" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try Grid.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var soil = try SoilChemistry.State.init(std.testing.allocator, grid.layer_count);
    defer soil.deinit();
    var surface = try SurfaceChemistry.State.init(std.testing.allocator, grid.cell_count);
    defer surface.deinit();
    surface.cells[0].phosphate_surface.adsorbed_hpo4_mol_p_per_megagram = 2;
    soil.non_band_phosphate[0].adsorbed_h2po4_mol_p_per_megagram = 4;
    soil.band_phosphate[1].adsorbed_hpo4_mol_p_per_megagram = 8;
    const result = try exchangeablePhosphorus_g_p(&grid, &soil, &surface, &.{ 10, 20 }, &.{ 2, 3 }, &.{5}, 0, ZoneFractions{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 0.75, .phosphate_band = 0.25 }, 31);
    // litter 10; layer 0 60; layer 1 120 = 190 mol P.
    try std.testing.expectEqual(@as(f64, 190 * 31), result);
}

test "UPO4 sums surface and runtime-zone soluble phosphate inventories" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try Grid.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var soil = try SoilChemistry.State.init(std.testing.allocator, grid.layer_count);
    defer soil.deinit();
    var surface = try SurfaceChemistry.State.init(std.testing.allocator, grid.cell_count);
    defer surface.deinit();
    surface.dry_reference_water_m3[0] = 5;
    surface.cells[0].h2po4_mol_p_per_m3 = 2;
    soil.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = 4;
    soil.band_phosphate[1].dissolved_h2po4_mol_p_per_m3 = 8;
    const result = try solublePhosphorus_g_p(&grid, &soil, &surface, &.{ 10, 20 }, &.{5}, 0, ZoneFractions{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 0.75, .phosphate_band = 0.25 }, 31);
    try std.testing.expectEqual(@as(f64, 80 * 31), result);
}

test "UPP4 and UPO4 retain dry surface phosphate on native references" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try Grid.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var soil = try SoilChemistry.State.init(std.testing.allocator, grid.layer_count);
    defer soil.deinit();
    var surface = try SurfaceChemistry.State.init(std.testing.allocator, grid.cell_count);
    defer surface.deinit();
    surface.dry_reference_water_m3[0] = 3;
    surface.mineral_reference_water_m3[0] = 4;
    surface.cells[0].h2po4_mol_p_per_m3 = 2;
    surface.cells[0].phosphate_minerals.hydroxyapatite_mol_per_m3 = 5;
    const fractions = ZoneFractions{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 };
    try std.testing.expectEqual(@as(f64, 6 * 31), try solublePhosphorus_g_p(&grid, &soil, &surface, &.{0}, &.{0}, 0, fractions, 31));
    try std.testing.expectEqual(@as(f64, 60 * 31), try precipitatedPhosphorus_g_p(&grid, &soil, &surface, &.{0}, &.{0}, 0, fractions, 31));
}
