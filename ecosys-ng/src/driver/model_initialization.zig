const std = @import("std");
const GridState = @import("../state/grid.zig").GridState;
const SoilHydrology = @import("../soil/water/hydrology.zig").SoilHydrology;
const CellRange = @import("../core/compute.zig").CellRange;
const SoilCatalogEntry = @import("../soil/profile/catalog.zig").Entry;
const SoilProfile = @import("../state/soil_profile.zig").SoilProfile;
const ice_units = @import("../core/ice_units.zig");

/// Copies one fully resolved soil profile into one horizontal grid cell. The
/// caller controls profile sharing and tile scheduling; this kernel has no file
/// I/O or global state and is directly portable to a future device backend.
pub fn initializeCellHydrology(grid: *GridState, cell_index: usize, hydrology: SoilHydrology) !void {
    return initializeCellHydrologyWithIceDensity(grid, cell_index, hydrology, ice_units.reference_ice_density_megagrams_per_m3);
}

pub fn initializeCellHydrologyWithIceDensity(grid: *GridState, cell_index: usize, hydrology: SoilHydrology, ice_density_megagrams_per_m3: f64) !void {
    if (cell_index >= grid.cell_count) return error.GridIndexOutOfBounds;
    if (hydrology.layer_count == 0) return error.NoSoilLayers;
    if (hydrology.layer_count > grid.soil_layer_capacity) return error.SoilLayerCountMismatch;
    grid.active_soil_layer_count[cell_index] = hydrology.layer_count;
    grid.maximum_rooting_layer_count[cell_index] = hydrology.maximum_rooting_layer_count;
    for (0..hydrology.layer_count) |layer| {
        const grid_index = try grid.layerIndex(cell_index, layer);
        grid.liquid_water_m3[grid_index] = hydrology.matrix_water_volume_m3[layer] + hydrology.macropore_water_volume_m3[layer];
        grid.ice_water_m3[grid_index] = try ice_units.waterEquivalentM3FromPhysicalVolume(hydrology.matrix_ice_volume_m3[layer] + hydrology.macropore_ice_volume_m3[layer], ice_density_megagrams_per_m3);
        grid.matrix_liquid_water_m3[grid_index] = hydrology.matrix_water_volume_m3[layer];
        grid.macropore_liquid_water_m3[grid_index] = hydrology.macropore_water_volume_m3[layer];
        grid.matrix_ice_water_m3[grid_index] = try ice_units.waterEquivalentM3FromPhysicalVolume(hydrology.matrix_ice_volume_m3[layer], ice_density_megagrams_per_m3);
        grid.macropore_ice_water_m3[grid_index] = try ice_units.waterEquivalentM3FromPhysicalVolume(hydrology.macropore_ice_volume_m3[layer], ice_density_megagrams_per_m3);
        grid.matrix_pore_capacity_m3[grid_index] = hydrology.matrix_pore_volume_m3[layer];
        grid.macropore_pore_capacity_m3[grid_index] = hydrology.macropore_volume_m3[layer];
        grid.matrix_air_volume_m3[grid_index] = hydrology.matrix_air_volume_m3[layer];
        grid.macropore_air_volume_m3[grid_index] = hydrology.macropore_air_volume_m3[layer];
        grid.air_volume_m3[grid_index] = hydrology.air_volume_m3[layer];
    }
    try grid.validateFinite();
}

pub const UniformHydrologyContext = struct {
    grid: *GridState,
    hydrology: SoilHydrology,
    reference_cell_area_m2: f64,
    horizontal_cell_width_m: []const f64,
    vertical_cell_width_m: []const f64,
    ice_density_megagrams_per_m3: f64 = ice_units.reference_ice_density_megagrams_per_m3,
};

/// Tile kernel used when a landscape unit shares one resolved soil profile.
/// More complex domains invoke the same kernel once per profile-backed unit.
pub fn initializeUniformHydrologyTile(context: *UniformHydrologyContext, range: CellRange) !void {
    if (!std.math.isFinite(context.reference_cell_area_m2) or context.reference_cell_area_m2 <= 0.0) return error.InvalidReferenceCellArea;
    if (context.horizontal_cell_width_m.len != context.grid.cell_count or
        context.vertical_cell_width_m.len != context.grid.cell_count)
        return error.CellGeometryDimensionMismatch;
    for (range.first..range.end) |cell_index| {
        const cell_area_m2 = context.horizontal_cell_width_m[cell_index] *
            context.vertical_cell_width_m[cell_index];
        const volume_scale = cell_area_m2 / context.reference_cell_area_m2;
        try initializeCellHydrologyScaled(context.grid, cell_index, context.hydrology, volume_scale, context.ice_density_megagrams_per_m3);
    }
}

fn initializeCellHydrologyScaled(grid: *GridState, cell_index: usize, hydrology: SoilHydrology, volume_scale: f64, ice_density_megagrams_per_m3: f64) !void {
    if (!std.math.isFinite(volume_scale) or volume_scale <= 0.0) return error.InvalidCellVolumeScale;
    if (cell_index >= grid.cell_count) return error.GridIndexOutOfBounds;
    if (hydrology.layer_count > grid.soil_layer_capacity) return error.SoilLayerCountMismatch;
    grid.active_soil_layer_count[cell_index] = hydrology.layer_count;
    grid.maximum_rooting_layer_count[cell_index] = hydrology.maximum_rooting_layer_count;
    for (0..hydrology.layer_count) |layer| {
        const grid_index = try grid.layerIndex(cell_index, layer);
        grid.liquid_water_m3[grid_index] = volume_scale * (hydrology.matrix_water_volume_m3[layer] + hydrology.macropore_water_volume_m3[layer]);
        grid.ice_water_m3[grid_index] = volume_scale * try ice_units.waterEquivalentM3FromPhysicalVolume(hydrology.matrix_ice_volume_m3[layer] + hydrology.macropore_ice_volume_m3[layer], ice_density_megagrams_per_m3);
        grid.matrix_liquid_water_m3[grid_index] = volume_scale * hydrology.matrix_water_volume_m3[layer];
        grid.macropore_liquid_water_m3[grid_index] = volume_scale * hydrology.macropore_water_volume_m3[layer];
        grid.matrix_ice_water_m3[grid_index] = volume_scale * try ice_units.waterEquivalentM3FromPhysicalVolume(hydrology.matrix_ice_volume_m3[layer], ice_density_megagrams_per_m3);
        grid.macropore_ice_water_m3[grid_index] = volume_scale * try ice_units.waterEquivalentM3FromPhysicalVolume(hydrology.macropore_ice_volume_m3[layer], ice_density_megagrams_per_m3);
        grid.matrix_pore_capacity_m3[grid_index] = volume_scale * hydrology.matrix_pore_volume_m3[layer];
        grid.macropore_pore_capacity_m3[grid_index] = volume_scale * hydrology.macropore_volume_m3[layer];
        grid.matrix_air_volume_m3[grid_index] = volume_scale * hydrology.matrix_air_volume_m3[layer];
        grid.macropore_air_volume_m3[grid_index] = volume_scale * hydrology.macropore_air_volume_m3[layer];
        grid.air_volume_m3[grid_index] = volume_scale * hydrology.air_volume_m3[layer];
    }
}

pub const MappedHydrologyContext = struct {
    grid: *GridState,
    catalog_entries: []const SoilCatalogEntry,
    catalog_index_by_cell: []const usize,
    horizontal_cell_width_m: []const f64,
    vertical_cell_width_m: []const f64,
    ice_density_megagrams_per_m3: f64 = ice_units.reference_ice_density_megagrams_per_m3,
};

pub fn initializeMappedHydrologyTile(context: *MappedHydrologyContext, range: CellRange) !void {
    if (context.horizontal_cell_width_m.len != context.grid.cell_count or
        context.vertical_cell_width_m.len != context.grid.cell_count)
        return error.CellGeometryDimensionMismatch;
    for (range.first..range.end) |cell_index| {
        if (cell_index >= context.catalog_index_by_cell.len) return error.SoilCatalogMapOutOfBounds;
        const catalog_index = context.catalog_index_by_cell[cell_index];
        if (catalog_index >= context.catalog_entries.len) return error.SoilCatalogMapOutOfBounds;
        const cell_area_m2 = context.horizontal_cell_width_m[cell_index] *
            context.vertical_cell_width_m[cell_index];
        try initializeCellHydrologyScaled(context.grid, cell_index, context.catalog_entries[catalog_index].hydrology_per_m2, cell_area_m2, context.ice_density_megagrams_per_m3);
    }
}

/// Applies HOUR1's initial natural-water-table branch after mapped hydrology
/// and the adjusted per-cell `DTBLZ` topology are available.
///
/// `adjusted_natural_water_table_depth_m` is deliberately already adjusted by
/// the caller: this kernel neither re-applies terrain elevation nor interprets
/// a site water-table mode. Depths and layer midpoints are measured downward
/// from the local soil surface. Every active layer whose midpoint is at or
/// below the table is liquid saturated regardless of its soil-file water/ice
/// sentinel codes (`hour1.f:2131--2168`).
///
/// The first pass validates the entire domain. The second pass cannot fail, so
/// an invalid later cell cannot leave an earlier cell saturated.
/// HOUR1 applies this saturation ONLY in the ELSE arm of `hour1.f:2055-2056`:
///
///     IF((ISOIL(1,L,NY,NX).EQ.0.AND.ISOIL(2,L,NY,NX).EQ.0)
///    2.OR.DATA(20).EQ.'YES')THEN      <- no saturation
///     ...
///     ELSE                            <- hour1.f:2131-2152 lives here
///
/// Verified by tracing the nesting: the `IF(I.EQ.IBEGIN...)` at `hour1.f:2131`
/// sits at depth 1 inside that ELSE, and the three consecutive `ENDIF`s at
/// `:2163-2165` close `:2153`, `:2131` and `:2055` respectively.
///
/// `readi.f:454-470` defines the flags: "ISOIL=flag for calculating FC(1),
/// WP(2)", set to 1 when the soil file leaves the value negative and 0 when it
/// supplies one. So a layer is saturated only where the soil file left FIELD
/// CAPACITY OR WILTING POINT UNSUPPLIED. `readi.f:535` propagates the flags to
/// extrapolated layers, which `state/soil_profile.zig`'s
/// `expandPhysicalBoundaryLayers` already mirrors by copying `values[layer - 1]`
/// downward, so the negative sentinel is present on every layer here and can be
/// read directly.
///
/// Applying this unconditionally injected 272 mm into the Ottawa deck, whose
/// `f25sol98` supplies both values and therefore takes the THEN arm: layers
/// 10-12 were pinned at exactly porosity with `air_volume_m3 = 0` from hour 1,
/// which broke the `IFLGD` tile-drainage chain (equal matric potentials), held
/// the water table a metre high, and failed `TotalWaterOutsideRetentionDomain`
/// at day 87 once accumulated rounding pushed theta one part in 5e13 past
/// saturation.
///
/// NOT translated here: the `.OR.DATA(20).EQ.'YES'` restart half of the same
/// condition. Domain initialization runs before a checkpoint restore overwrites
/// these carriers, so it is believed moot in this architecture, but it has not
/// been proven and no resume flag is threaded to this call site.
/// `readi.f:454-470`: a negative field capacity or wilting point in the soil
/// file is the "not supplied, calculate it" sentinel that sets `ISOIL(1)` or
/// `ISOIL(2)` to 1. Both non-negative means both were supplied, so
/// `ISOIL(1).EQ.0.AND.ISOIL(2).EQ.0` holds and `hour1.f:2055` takes the THEN
/// arm. `state/soil_profile.zig`'s `expandPhysicalBoundaryLayers` already
/// propagates these values downward into the extrapolated layers exactly as
/// `readi.f:535` propagates the flags, so a direct index is correct for every
/// active layer.
pub fn suppliedRetentionEndpoints(profile: SoilProfile, layer: usize) bool {
    return profile.field_capacity_m3_m3[layer] >= 0 and
        profile.wilting_point_m3_m3[layer] >= 0;
}

/// Fills the grid-indexed `ISOIL(1).EQ.0.AND.ISOIL(2).EQ.0` predicate that
/// `applyInitialNaturalWaterTableSaturation` consumes, resolving each cell
/// through the soil catalog exactly as `initializeMappedHydrologyTile` does.
pub fn fillSuppliedRetentionEndpoints(
    grid: *const GridState,
    catalog_entries: []const SoilCatalogEntry,
    catalog_index_by_cell: []const usize,
    supplied_by_layer: []bool,
) !void {
    if (catalog_index_by_cell.len != grid.cell_count or
        supplied_by_layer.len != grid.layer_count)
        return error.InitialWaterTableDimensionMismatch;
    @memset(supplied_by_layer, false);
    for (0..grid.cell_count) |cell| {
        const catalog_index = catalog_index_by_cell[cell];
        if (catalog_index >= catalog_entries.len) return error.SoilCatalogMapOutOfBounds;
        const profile = catalog_entries[catalog_index].profile;
        const active_layers = grid.active_soil_layer_count[cell];
        if (profile.field_capacity_m3_m3.len < active_layers or
            profile.wilting_point_m3_m3.len < active_layers)
            return error.InitialWaterTableDimensionMismatch;
        for (0..active_layers) |layer| {
            const at = try grid.layerIndex(cell, layer);
            supplied_by_layer[at] = suppliedRetentionEndpoints(profile, layer);
        }
    }
}

pub fn applyInitialNaturalWaterTableSaturation(
    grid: *GridState,
    retention_endpoints_supplied_by_layer: []const bool,
    adjusted_natural_water_table_depth_m: []const f64,
    layer_midpoint_depth_from_surface_m: []const f64,
) !void {
    if (adjusted_natural_water_table_depth_m.len != grid.cell_count or
        layer_midpoint_depth_from_surface_m.len != grid.layer_count)
        return error.InitialWaterTableDimensionMismatch;
    if (retention_endpoints_supplied_by_layer.len != grid.layer_count)
        return error.InitialWaterTableDimensionMismatch;
    try grid.validateFinite();
    for (adjusted_natural_water_table_depth_m) |depth_m|
        if (!std.math.isFinite(depth_m)) return error.NonFiniteInitialWaterTableDepth;
    for (0..grid.cell_count) |cell| {
        const active_layers = grid.active_soil_layer_count[cell];
        if (active_layers > grid.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        for (0..active_layers) |layer| {
            const at = try grid.layerIndex(cell, layer);
            const midpoint_m = layer_midpoint_depth_from_surface_m[at];
            const matrix_capacity_m3 = grid.matrix_pore_capacity_m3[at];
            const macropore_capacity_m3 = grid.macropore_pore_capacity_m3[at];
            if (!std.math.isFinite(midpoint_m))
                return error.NonFiniteInitialSoilLayerMidpoint;
            if (!std.math.isFinite(matrix_capacity_m3) or matrix_capacity_m3 < 0 or
                !std.math.isFinite(macropore_capacity_m3) or macropore_capacity_m3 < 0 or
                !std.math.isFinite(matrix_capacity_m3 + macropore_capacity_m3))
                return error.InvalidInitialSoilPoreCapacity;
        }
    }

    for (0..grid.cell_count) |cell| {
        const table_depth_m = adjusted_natural_water_table_depth_m[cell];
        for (0..grid.active_soil_layer_count[cell]) |layer| {
            const at = grid.layerIndex(cell, layer) catch unreachable;
            if (layer_midpoint_depth_from_surface_m[at] < table_depth_m) continue;
            // ISOIL(1)=ISOIL(2)=0 selects the THEN arm, which does not saturate.
            if (retention_endpoints_supplied_by_layer[at]) continue;
            const matrix_capacity_m3 = grid.matrix_pore_capacity_m3[at];
            const macropore_capacity_m3 = grid.macropore_pore_capacity_m3[at];
            grid.matrix_liquid_water_m3[at] = matrix_capacity_m3;
            grid.macropore_liquid_water_m3[at] = macropore_capacity_m3;
            grid.liquid_water_m3[at] = matrix_capacity_m3 + macropore_capacity_m3;
            grid.matrix_ice_water_m3[at] = 0;
            grid.macropore_ice_water_m3[at] = 0;
            grid.ice_water_m3[at] = 0;
            grid.matrix_air_volume_m3[at] = 0;
            grid.macropore_air_volume_m3[at] = 0;
            grid.air_volume_m3[at] = 0;
            grid.water_vapor_volume_m3[at] = 0;
        }
    }
}

test "executable binds initial DTBLZ saturation after mapped geometry and before gas state" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        std.testing.allocator,
        .limited(12 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    const domain_phase_start = std.mem.indexOf(
        u8,
        source,
        "noinline fn initializeDomainScience(",
    ) orelse return error.InitialWaterTableProductionBindingMissing;
    const domain_phase_end = std.mem.indexOfPos(
        u8,
        source,
        domain_phase_start,
        "const SoilProcessTransportOwners = struct",
    ) orelse return error.InitialWaterTableProductionBindingMissing;
    const domain_phase = source[domain_phase_start..domain_phase_end];
    const process_phase_start = std.mem.indexOf(
        u8,
        source,
        "noinline fn initializeSoilProcessTransport(",
    ) orelse return error.InitialWaterTableProductionBindingMissing;
    const main_start = std.mem.indexOfPos(
        u8,
        source,
        process_phase_start,
        "pub fn main(",
    ) orelse return error.InitialWaterTableProductionBindingMissing;
    const process_phase = source[process_phase_start..main_start];
    const main_source = source[main_start..];

    const mapped_hydrology = std.mem.indexOf(u8, domain_phase, "model_initialization.initializeMappedHydrologyTile") orelse
        return error.InitialWaterTableProductionBindingMissing;
    const topology = std.mem.indexOf(u8, domain_phase, "soil_boundary_topology.State.initMapped") orelse
        return error.InitialWaterTableProductionBindingMissing;
    const geometry = std.mem.indexOf(u8, domain_phase, "soil_layer_geometry.initializeCell") orelse
        return error.InitialWaterTableProductionBindingMissing;
    const bound_surface = std.mem.indexOf(u8, domain_phase, "soil_boundary_topology_state.bindInitialSurfaceBoundaryDepths") orelse
        return error.InitialWaterTableProductionBindingMissing;
    const saturation = std.mem.indexOf(u8, domain_phase, "model_initialization.applyInitialNaturalWaterTableSaturation") orelse
        return error.InitialWaterTableProductionBindingMissing;
    const gas_state = std.mem.indexOf(u8, process_phase, "owners.gas_transport_state = try ecosys.gas_transport.State.init") orelse
        return error.InitialWaterTableProductionBindingMissing;
    const domain_phase_call = std.mem.indexOf(u8, main_source, "try initializeDomainScience(") orelse
        return error.InitialWaterTableProductionBindingMissing;
    const process_phase_call = std.mem.indexOf(u8, main_source, "try initializeSoilProcessTransport(") orelse
        return error.InitialWaterTableProductionBindingMissing;
    const gas_seed = std.mem.indexOf(u8, main_source, "gas_transport.initializeSoilLayerCell") orelse
        return error.InitialWaterTableProductionBindingMissing;
    try std.testing.expect(mapped_hydrology < topology);
    try std.testing.expect(topology < geometry);
    try std.testing.expect(geometry < bound_surface);
    try std.testing.expect(bound_surface < saturation);
    try std.testing.expect(domain_phase_call < process_phase_call);
    try std.testing.expect(process_phase_call < gas_seed);
    const saturation_call = domain_phase[saturation..];
    try std.testing.expect(std.mem.indexOf(
        u8,
        saturation_call,
        "owners.soil_boundary_topology_state.natural_water_table_depth_m",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        saturation_call,
        "owners.soil_geometry_state.layer_midpoint_depth_from_surface_m",
    ) != null);
    _ = gas_state;
    const gas_seed_call = main_source[gas_seed..];
    const adjusted_gas_depth = std.mem.indexOf(
        u8,
        gas_seed_call,
        "soil_boundary_topology_state.natural_water_table_depth_m[depth_cell]",
    ) orelse return error.InitialWaterTableProductionBindingMissing;
    const next_gas_argument = std.mem.indexOf(
        u8,
        gas_seed_call,
        "mean_annual_temperature_k_by_cell[cell]",
    ) orelse return error.InitialWaterTableProductionBindingMissing;
    try std.testing.expect(adjusted_gas_depth < next_gas_argument);
}

test "initial DTBLZ saturation is per cell exact and sentinel independent" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 3, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 3;
    grid.active_soil_layer_count[1] = 3;
    const shared_profile_midpoints_m = [_]f64{ 0.1, 0.5, 0.9, 0.1, 0.5, 0.9 };
    for (0..grid.layer_count) |at| {
        grid.matrix_pore_capacity_m3[at] = @as(f64, @floatFromInt(at + 2));
        grid.macropore_pore_capacity_m3[at] = 0.25;
        // Deliberately unrelated finite sentinels: the below-table branch is
        // controlled only by midpoint and adjusted DTBLZ, never by their value.
        grid.matrix_liquid_water_m3[at] = 0.375;
        grid.macropore_liquid_water_m3[at] = 0.125;
        grid.liquid_water_m3[at] = 0.5;
        grid.matrix_ice_water_m3[at] = 0.25;
        grid.macropore_ice_water_m3[at] = 0.125;
        grid.ice_water_m3[at] = 0.375;
        grid.matrix_air_volume_m3[at] = 1.25;
        grid.macropore_air_volume_m3[at] = 0.125;
        grid.air_volume_m3[at] = 1.375;
        grid.water_vapor_volume_m3[at] = 0.015625;
    }

    // These are already adjusted, surface-relative DTBLZ values. Cell zero's
    // table intersects the second midpoint; cell one's supplied adjusted table
    // is deeper, so the otherwise identical second layer stays unchanged.
    try applyInitialNaturalWaterTableSaturation(
        &grid,
        // Unsupplied FC/WP on every layer, so hour1.f:2056 takes the ELSE arm
        // and this test exercises the saturation geometry as before.
        &[_]bool{false} ** 6,
        &.{ 0.5, 0.8 },
        &shared_profile_midpoints_m,
    );

    const cell_zero_above = try grid.layerIndex(0, 0);
    const cell_one_above = try grid.layerIndex(1, 1);
    try std.testing.expectEqual(@as(f64, 0.375), grid.matrix_liquid_water_m3[cell_zero_above]);
    try std.testing.expectEqual(@as(f64, 0.25), grid.matrix_ice_water_m3[cell_zero_above]);
    try std.testing.expectEqual(@as(f64, 0.375), grid.matrix_liquid_water_m3[cell_one_above]);
    try std.testing.expectEqual(@as(f64, 1.375), grid.air_volume_m3[cell_one_above]);

    for ([_]usize{
        try grid.layerIndex(0, 1),
        try grid.layerIndex(0, 2),
        try grid.layerIndex(1, 2),
    }) |at| {
        try std.testing.expectEqual(grid.matrix_pore_capacity_m3[at], grid.matrix_liquid_water_m3[at]);
        try std.testing.expectEqual(grid.macropore_pore_capacity_m3[at], grid.macropore_liquid_water_m3[at]);
        try std.testing.expectEqual(
            grid.matrix_pore_capacity_m3[at] + grid.macropore_pore_capacity_m3[at],
            grid.liquid_water_m3[at],
        );
        try std.testing.expectEqual(@as(f64, 0), grid.matrix_ice_water_m3[at]);
        try std.testing.expectEqual(@as(f64, 0), grid.macropore_ice_water_m3[at]);
        try std.testing.expectEqual(@as(f64, 0), grid.ice_water_m3[at]);
        try std.testing.expectEqual(@as(f64, 0), grid.matrix_air_volume_m3[at]);
        try std.testing.expectEqual(@as(f64, 0), grid.macropore_air_volume_m3[at]);
        try std.testing.expectEqual(@as(f64, 0), grid.air_volume_m3[at]);
        try std.testing.expectEqual(@as(f64, 0), grid.water_vapor_volume_m3[at]);
    }
}

// hour1.f:2131-2168 sits in the ELSE arm of hour1.f:2055, so a layer whose soil
// file SUPPLIED both field capacity and wilting point (ISOIL(1)=ISOIL(2)=0,
// readi.f:454-470) must not be saturated at all. Applying it unconditionally
// injected 272 mm into the Ottawa deck and pinned its three deepest layers at
// exactly porosity with zero air volume from hour 1.
test "a below-table layer with supplied retention endpoints is never saturated" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.active_soil_layer_count[1] = 1;
    for (0..grid.layer_count) |at| {
        grid.matrix_pore_capacity_m3[at] = 2;
        grid.macropore_pore_capacity_m3[at] = 0.25;
        grid.matrix_liquid_water_m3[at] = 0.375;
        grid.macropore_liquid_water_m3[at] = 0.125;
        grid.liquid_water_m3[at] = 0.5;
        grid.matrix_ice_water_m3[at] = 0.25;
        grid.macropore_ice_water_m3[at] = 0.125;
        grid.ice_water_m3[at] = 0.375;
        grid.matrix_air_volume_m3[at] = 1.25;
        grid.macropore_air_volume_m3[at] = 0.125;
        grid.air_volume_m3[at] = 1.375;
        grid.water_vapor_volume_m3[at] = 0.015625;
    }
    const supplied_cell = try grid.layerIndex(0, 0);
    const unsupplied_cell = try grid.layerIndex(1, 0);

    // Both layers sit at the same depth and both are below their table, so the
    // ONLY difference is the ISOIL predicate.
    try applyInitialNaturalWaterTableSaturation(
        &grid,
        &[_]bool{ true, false },
        &.{ 0.25, 0.25 },
        &.{ 0.5, 0.5 },
    );

    // Supplied endpoints: byte-exact passthrough, and crucially air volume is
    // retained rather than zeroed.
    try std.testing.expectEqual(@as(f64, 0.375), grid.matrix_liquid_water_m3[supplied_cell]);
    try std.testing.expectEqual(@as(f64, 0.5), grid.liquid_water_m3[supplied_cell]);
    try std.testing.expectEqual(@as(f64, 0.375), grid.ice_water_m3[supplied_cell]);
    try std.testing.expectEqual(@as(f64, 1.375), grid.air_volume_m3[supplied_cell]);
    try std.testing.expectEqual(@as(f64, 0.015625), grid.water_vapor_volume_m3[supplied_cell]);

    // Unsupplied endpoints: the oracle's ELSE arm still saturates.
    try std.testing.expectEqual(@as(f64, 2), grid.matrix_liquid_water_m3[unsupplied_cell]);
    try std.testing.expectEqual(@as(f64, 2.25), grid.liquid_water_m3[unsupplied_cell]);
    try std.testing.expectEqual(@as(f64, 0), grid.ice_water_m3[unsupplied_cell]);
    try std.testing.expectEqual(@as(f64, 0), grid.air_volume_m3[unsupplied_cell]);
}

test "the supplied-endpoints predicate follows the readi.f negative sentinel" {
    const source = try @import("../core/test_fixtures.zig").soilProfileSource(
        std.testing.allocator,
        @typeInfo(@import("../state/soil_profile.zig").LayerProperty).@"enum".fields.len,
    );
    defer std.testing.allocator.free(source);
    var profile = try @import("../state/soil_profile.zig").parsePhysicalProfile(std.testing.allocator, source);
    defer profile.deinit();

    // The fixture supplies both endpoints, so the THEN arm applies.
    try std.testing.expect(suppliedRetentionEndpoints(profile, 0));
    // readi.f:460-470 treats either negative value as "calculate it", which sets
    // ISOIL and selects the ELSE arm.
    profile.field_capacity_m3_m3[0] = -1;
    try std.testing.expect(!suppliedRetentionEndpoints(profile, 0));
    profile.field_capacity_m3_m3[0] = 0.3;
    profile.wilting_point_m3_m3[0] = -1;
    try std.testing.expect(!suppliedRetentionEndpoints(profile, 0));
}

test "invalid later DTBLZ cell leaves every earlier phase carrier unchanged" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.active_soil_layer_count[1] = 1;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.macropore_pore_capacity_m3[0] = 0.5;
    grid.matrix_pore_capacity_m3[1] = 3;
    grid.macropore_pore_capacity_m3[1] = 0.75;
    grid.matrix_liquid_water_m3[0] = 0.625;
    grid.macropore_liquid_water_m3[0] = 0.125;
    grid.liquid_water_m3[0] = 0.75;
    grid.matrix_ice_water_m3[0] = 0.25;
    grid.macropore_ice_water_m3[0] = 0.125;
    grid.ice_water_m3[0] = 0.375;
    grid.matrix_air_volume_m3[0] = 1.125;
    grid.macropore_air_volume_m3[0] = 0.25;
    grid.air_volume_m3[0] = 1.375;
    grid.water_vapor_volume_m3[0] = 0.015625;
    const before = [_]f64{
        grid.matrix_liquid_water_m3[0],
        grid.macropore_liquid_water_m3[0],
        grid.liquid_water_m3[0],
        grid.matrix_ice_water_m3[0],
        grid.macropore_ice_water_m3[0],
        grid.ice_water_m3[0],
        grid.matrix_air_volume_m3[0],
        grid.macropore_air_volume_m3[0],
        grid.air_volume_m3[0],
        grid.water_vapor_volume_m3[0],
    };
    try std.testing.expectError(
        error.NonFiniteInitialWaterTableDepth,
        applyInitialNaturalWaterTableSaturation(
            &grid,
            &[_]bool{ false, false },
            &.{ 0, std.math.nan(f64) },
            &.{ 0.5, 0.5 },
        ),
    );
    const after = [_]f64{
        grid.matrix_liquid_water_m3[0],
        grid.macropore_liquid_water_m3[0],
        grid.liquid_water_m3[0],
        grid.matrix_ice_water_m3[0],
        grid.macropore_ice_water_m3[0],
        grid.ice_water_m3[0],
        grid.matrix_air_volume_m3[0],
        grid.macropore_air_volume_m3[0],
        grid.air_volume_m3[0],
        grid.water_vapor_volume_m3[0],
    };
    try std.testing.expectEqualSlices(f64, &before, &after);
}

test "initial DTBLZ saturation leaves inactive layers byte exact" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.macropore_pore_capacity_m3[0] = 0.5;
    const inactive = try grid.layerIndex(0, 1);
    grid.matrix_pore_capacity_m3[inactive] = 9;
    grid.macropore_pore_capacity_m3[inactive] = 1;
    grid.matrix_liquid_water_m3[inactive] = 0.625;
    grid.macropore_liquid_water_m3[inactive] = 0.125;
    grid.liquid_water_m3[inactive] = 0.75;
    grid.matrix_ice_water_m3[inactive] = 0.25;
    grid.macropore_ice_water_m3[inactive] = 0.125;
    grid.ice_water_m3[inactive] = 0.375;
    grid.matrix_air_volume_m3[inactive] = 8.125;
    grid.macropore_air_volume_m3[inactive] = 0.75;
    grid.air_volume_m3[inactive] = 8.875;
    grid.water_vapor_volume_m3[inactive] = 0.015625;
    const before = [_]f64{
        grid.matrix_liquid_water_m3[inactive],
        grid.macropore_liquid_water_m3[inactive],
        grid.liquid_water_m3[inactive],
        grid.matrix_ice_water_m3[inactive],
        grid.macropore_ice_water_m3[inactive],
        grid.ice_water_m3[inactive],
        grid.matrix_air_volume_m3[inactive],
        grid.macropore_air_volume_m3[inactive],
        grid.air_volume_m3[inactive],
        grid.water_vapor_volume_m3[inactive],
    };
    // The inactive layer is geometrically below the supplied table, but it is
    // outside the runtime profile extent and must not be initialized.
    try applyInitialNaturalWaterTableSaturation(&grid, &[_]bool{ false, false }, &.{0.25}, &.{ 0.5, 1.5 });
    const after = [_]f64{
        grid.matrix_liquid_water_m3[inactive],
        grid.macropore_liquid_water_m3[inactive],
        grid.liquid_water_m3[inactive],
        grid.matrix_ice_water_m3[inactive],
        grid.macropore_ice_water_m3[inactive],
        grid.ice_water_m3[inactive],
        grid.matrix_air_volume_m3[inactive],
        grid.macropore_air_volume_m3[inactive],
        grid.air_volume_m3[inactive],
        grid.water_vapor_volume_m3[inactive],
    };
    try std.testing.expectEqualSlices(f64, &before, &after);
}

test "fully saturated DTBLZ layer is an inactive zero-air gas phase" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.macropore_pore_capacity_m3[0] = 0.5;
    const adjusted_natural_table_depth_m: f64 = 0.25;
    const configured_unadjusted_table_depth_m: f64 = 1;
    try applyInitialNaturalWaterTableSaturation(&grid, &[_]bool{false}, &.{adjusted_natural_table_depth_m}, &.{0.5});

    const gas = @import("../soil/gas/transport.zig");
    const coupled = @import("../soil/gas/coupled_gas_solver.zig");
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var raw_depth_control = try gas.State.init(std.testing.allocator, 1);
    defer raw_depth_control.deinit();
    const reference = [gas.species_count]f64{ 0.7391, 0.03156, 0.02925, 0.01510, 0.5241, 285.2, 0.03156 };
    const intercept = [gas.species_count]f64{ 0.843, 0.597, 0.516, 0.456, 0.897, 0.513, 0.597 };
    const temperature_coefficient = [gas.species_count]f64{ 0.0281, 0.0199, 0.0172, 0.0152, 0.0299, 0.0171, 0.0199 };
    const atmospheric_concentration = [gas.species_count]f64{ 0.2144, 0.00096, 300.3, 975, 0.0001, 0.00001, 0.000001 };
    state.air_volume_m3[0] = grid.air_volume_m3[0];
    state.temperature_k[0] = 279.65;
    raw_depth_control.air_volume_m3[0] = grid.air_volume_m3[0];
    raw_depth_control.temperature_k[0] = 279.65;
    try gas.initializeSoilLayerCell(
        &state,
        0,
        grid.air_volume_m3[0],
        grid.liquid_water_m3[0],
        0.5,
        adjusted_natural_table_depth_m,
        279.65,
        atmospheric_concentration,
        .{
            .reference_water_to_air = reference,
            .log_intercept = intercept,
            .temperature_coefficient_per_c = temperature_coefficient,
        },
        0,
        gas.starte_activity_coefficient,
    );
    try gas.initializeSoilLayerCell(
        &raw_depth_control,
        0,
        grid.air_volume_m3[0],
        grid.liquid_water_m3[0],
        0.5,
        configured_unadjusted_table_depth_m,
        279.65,
        atmospheric_concentration,
        .{
            .reference_water_to_air = reference,
            .log_intercept = intercept,
            .temperature_coefficient_per_c = temperature_coefficient,
        },
        0,
        gas.starte_activity_coefficient,
    );
    const oxygen = @intFromEnum(gas.Species.oxygen);
    try std.testing.expectEqual(@as(f64, 0), state.dissolved_mass_g[oxygen]);
    try std.testing.expect(raw_depth_control.dissolved_mass_g[oxygen] > 0);
    const gaseous_before = state.gaseous_mass_g[0..gas.species_count].*;
    const dissolved_before = state.dissolved_mass_g[0..gas.species_count].*;
    const band_before = state.band_dissolved_mass_g[0..gas.species_count].*;
    const solubility = [_]f64{1} ** gas.species_count;
    const exchange = [_]f64{0.75} ** gas.species_count;
    const zero_exchange = [_]f64{0} ** gas.species_count;
    const result = try coupled.solve(
        std.testing.allocator,
        &state,
        .{
            .faces = &.{},
            .face_conductance_m3_per_step = &.{},
            .atmospheric_boundaries = &.{},
            .water_volume_m3 = grid.liquid_water_m3[0..1],
            .band_water_volume_m3 = &.{0},
            .nonband_air_volume_m3 = grid.air_volume_m3[0..1],
            .band_air_volume_m3 = &.{0},
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &exchange,
            .band_gas_water_exchange_rate_per_step = &zero_exchange,
            .bubbling_enabled = &.{false},
        },
        .{ .max_iterations = 80 },
    );
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    try std.testing.expectEqual(@as(u16, 0), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), result.picard_steps);
    try std.testing.expectEqualSlices(f64, &gaseous_before, state.gaseous_mass_g);
    try std.testing.expectEqualSlices(f64, &dissolved_before, state.dissolved_mass_g);
    try std.testing.expectEqualSlices(f64, &band_before, state.band_dissolved_mass_g);
}

test "resolved hydrology populates heap-backed grid state" {
    const allocator = std.testing.allocator;
    const source = try @import("../core/test_fixtures.zig").soilProfileSource(allocator, @typeInfo(@import("../state/soil_profile.zig").LayerProperty).@"enum".fields.len);
    defer allocator.free(source);
    var profile = try @import("../state/soil_profile.zig").parsePhysicalProfile(allocator, source);
    defer profile.deinit();
    var material = try @import("../soil/profile/initialization.zig").SoilMaterial.init(allocator, profile, @import("../soil/profile/derivation.zig").compatibilityParameters());
    defer material.deinit();
    var hydrology = try SoilHydrology.init(allocator, profile, material, 1.0, @import("../soil/water/retention.zig").compatibilityParameters());
    defer hydrology.deinit();
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = profile.total_layer_count, .plant_populations = 8 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    var grid = try GridState.init(allocator, config);
    defer grid.deinit();
    try initializeCellHydrology(&grid, 1, hydrology);
    const first_layer = try grid.layerIndex(1, 0);
    try std.testing.expectApproxEqAbs(
        hydrology.matrix_water_volume_m3[0] + hydrology.macropore_water_volume_m3[0],
        grid.liquid_water_m3[first_layer],
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(hydrology.matrix_water_volume_m3[0], grid.matrix_liquid_water_m3[first_layer], 1.0e-12);
    try std.testing.expectApproxEqAbs(hydrology.macropore_water_volume_m3[0], grid.macropore_liquid_water_m3[first_layer], 1.0e-12);
    try std.testing.expectApproxEqAbs(0.917 * hydrology.matrix_ice_volume_m3[0], grid.matrix_ice_water_m3[first_layer], 1.0e-12);
    try std.testing.expectApproxEqAbs(0.917 * hydrology.macropore_ice_volume_m3[0], grid.macropore_ice_water_m3[first_layer], 1.0e-12);
    try std.testing.expectApproxEqAbs(hydrology.air_volume_m3[0], grid.air_volume_m3[first_layer], 1.0e-12);
}

// Ottawa's own declared retention endpoints, transcribed from
// `examples_ng-prod/Cool Temperate Maize-Soybean ON/runottawa_input_files/
// landscape/f25sol98` lines 5 and 6 (field capacity, then wilting point) as
// measured 2026-09-12. Ten declared layers carrying two distinct pairs.
//
// They are LITERALS here on purpose. The deck is not under version control, so
// a test that read the file would skip in any clone -- the failure mode filed
// as `PRODUCTION-INPUT-LAYOUT-TESTS-VACUOUS-IN-ANY-CLONE-001`. Transcribing the
// values keeps the assertion live everywhere; the cost is that a change to the
// deck would not invalidate it, so the provenance comment above is the contract.
const ottawa_field_capacity_m3_m3 = [_]f64{ 0.28, 0.28, 0.28, 0.28, 0.28, 0.28, 0.33, 0.33, 0.33, 0.33 };
const ottawa_wilting_point_m3_m3 = [_]f64{ 0.15, 0.15, 0.15, 0.15, 0.15, 0.15, 0.20, 0.20, 0.20, 0.20 };
/// Cumulative depths on line 2 differenced into thicknesses; they sum to the
/// declared 1.30 m profile.
const ottawa_layer_thickness_m = [_]f64{ 0.01, 0.015, 0.05, 0.05, 0.05, 0.05, 0.075, 0.2, 0.3, 0.5 };

test "every Ottawa layer supplies both retention endpoints, so the deck takes the non-saturating arm" {
    // The premise the whole 272 mm fix rests on, and until now asserted only in
    // a comment. `readi.f:454-470` makes a NEGATIVE field capacity or wilting
    // point the "not supplied, calculate it" sentinel that sets ISOIL and
    // selects the saturating ELSE arm of `hour1.f:2055`. Every Ottawa value is
    // positive, so ISOIL(1)=ISOIL(2)=0 on every layer and nothing is injected.
    const soil_profile = @import("../state/soil_profile.zig");
    const source = try @import("../core/test_fixtures.zig").soilProfileSource(
        std.testing.allocator,
        @typeInfo(soil_profile.LayerProperty).@"enum".fields.len,
    );
    defer std.testing.allocator.free(source);
    var profile = try soil_profile.parsePhysicalProfile(std.testing.allocator, source);
    defer profile.deinit();

    try std.testing.expectEqual(ottawa_field_capacity_m3_m3.len, ottawa_wilting_point_m3_m3.len);
    try std.testing.expectEqual(ottawa_field_capacity_m3_m3.len, ottawa_layer_thickness_m.len);
    var declared_depth_m: f64 = 0;
    for (ottawa_layer_thickness_m) |thickness_m| declared_depth_m += thickness_m;
    try std.testing.expectApproxEqAbs(@as(f64, 1.30), declared_depth_m, 1e-12);

    // Drive the production predicate with each real pair in turn. The fixture
    // profile carries one layer, which is all the predicate indexes.
    for (ottawa_field_capacity_m3_m3, ottawa_wilting_point_m3_m3) |capacity, wilting| {
        profile.field_capacity_m3_m3[0] = capacity;
        profile.wilting_point_m3_m3[0] = wilting;
        try std.testing.expect(suppliedRetentionEndpoints(profile, 0));
        // A wilting point above field capacity would be nonsense and is not
        // what this deck declares; checked so a bad transcription is visible.
        try std.testing.expect(wilting < capacity);
    }

    // Negative control on the real values: flipping either endpoint to the
    // sentinel selects the saturating arm, so the predicate is reading these
    // numbers rather than returning true unconditionally.
    profile.field_capacity_m3_m3[0] = -ottawa_field_capacity_m3_m3[0];
    profile.wilting_point_m3_m3[0] = ottawa_wilting_point_m3_m3[0];
    try std.testing.expect(!suppliedRetentionEndpoints(profile, 0));
}

test "Ottawa geometry below a surface water table receives exactly zero injected water" {
    // The 272 mm regression, in the units it was reported in. The water table
    // is placed AT the surface so every one of the ten layers is below it --
    // the worst case for the old unconditional port, which pinned the deepest
    // layers at exactly porosity with `air_volume_m3 = 0` from hour 1, broke
    // the IFLGD tile-drainage chain, and failed
    // `TotalWaterOutsideRetentionDomain` at day 87.
    //
    // The air fraction per layer is `porosity - field capacity`, with porosity
    // from the file's own bulk densities against a 2.65 Mg m-3 particle
    // density: 1 - 1.28/2.65 = 0.51698 for layers 1-6 and 1 - 1.30/2.65 =
    // 0.50943 for layers 7-10. That is a RECONSTRUCTION of the deck's initial
    // condition, not the deck's own state, so the control depth below is the
    // same order as the 272 mm measured on the real run rather than a
    // reproduction of it. What is exact, and what this test is for, is the
    // ZERO on the supplied-endpoint path.
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = ottawa_layer_thickness_m.len, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    const area_m2: f64 = 1;
    const particle_density_megagrams_per_m3: f64 = 2.65;

    var supplied_total_m3: f64 = 0;
    var unsupplied_total_m3: f64 = 0;
    var expected_injection_m3: f64 = 0;
    for ([_]bool{ true, false }) |endpoints_supplied| {
        var grid = try GridState.init(std.testing.allocator, config);
        defer grid.deinit();
        grid.active_soil_layer_count[0] = ottawa_layer_thickness_m.len;

        const supplied_by_layer = try std.testing.allocator.alloc(bool, grid.layer_count);
        defer std.testing.allocator.free(supplied_by_layer);
        @memset(supplied_by_layer, endpoints_supplied);
        const midpoint_depth_m = try std.testing.allocator.alloc(f64, grid.layer_count);
        defer std.testing.allocator.free(midpoint_depth_m);

        var top_depth_m: f64 = 0;
        var initial_total_m3: f64 = 0;
        var running_expected_m3: f64 = 0;
        for (ottawa_layer_thickness_m, 0..) |thickness_m, layer| {
            const at = try grid.layerIndex(0, layer);
            const bulk_density_megagrams_per_m3: f64 = if (layer < 6) 1.28 else 1.30;
            const porosity = 1.0 - bulk_density_megagrams_per_m3 / particle_density_megagrams_per_m3;
            const pore_capacity_m3 = porosity * thickness_m * area_m2;
            // Initial water at field capacity, which is what a deck supplying
            // FC is describing.
            const initial_water_m3 = ottawa_field_capacity_m3_m3[layer] * thickness_m * area_m2;
            midpoint_depth_m[at] = top_depth_m + 0.5 * thickness_m;
            top_depth_m += thickness_m;

            grid.matrix_pore_capacity_m3[at] = pore_capacity_m3;
            grid.macropore_pore_capacity_m3[at] = 0;
            grid.matrix_liquid_water_m3[at] = initial_water_m3;
            grid.macropore_liquid_water_m3[at] = 0;
            grid.liquid_water_m3[at] = initial_water_m3;
            grid.matrix_air_volume_m3[at] = pore_capacity_m3 - initial_water_m3;
            grid.macropore_air_volume_m3[at] = 0;
            grid.air_volume_m3[at] = pore_capacity_m3 - initial_water_m3;
            initial_total_m3 += initial_water_m3;
            running_expected_m3 += pore_capacity_m3 - initial_water_m3;
        }
        expected_injection_m3 = running_expected_m3;

        // Table at the surface: every midpoint is at or below it.
        try applyInitialNaturalWaterTableSaturation(
            &grid,
            supplied_by_layer,
            &.{0},
            midpoint_depth_m,
        );

        var after_total_m3: f64 = 0;
        for (0..ottawa_layer_thickness_m.len) |layer|
            after_total_m3 += grid.liquid_water_m3[try grid.layerIndex(0, layer)];
        if (endpoints_supplied) supplied_total_m3 = after_total_m3 - initial_total_m3 else unsupplied_total_m3 = after_total_m3 - initial_total_m3;
    }

    // THE ASSERTION THIS TEST EXISTS FOR: with Ottawa's endpoints supplied,
    // nothing is injected. Not "a little", not "below a tolerance" -- exactly
    // zero, because the layer is skipped before any carrier is written.
    try std.testing.expectEqual(@as(f64, 0), supplied_total_m3);

    // Positive control, so the zero above cannot be an inert test: with the
    // endpoints unsupplied the oracle's ELSE arm still fills every layer to
    // porosity, and that is the water the old unconditional port added.
    try std.testing.expectApproxEqRel(expected_injection_m3, unsupplied_total_m3, 1e-12);
    const injected_depth_millimetre = 1000.0 * unsupplied_total_m3 / area_m2;
    try std.testing.expect(injected_depth_millimetre > 200);
    try std.testing.expect(injected_depth_millimetre < 300);
}
