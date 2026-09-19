const std = @import("std");
const inventory = @import("landscape_mass_inventory.zig");
const group_gas = @import("landscape_mass_inventory_gas.zig");
const group_misc = @import("landscape_mass_inventory_misc.zig");
const group_nitrogen = @import("landscape_mass_inventory_nitrogen.zig");
const group_organic = @import("landscape_mass_inventory_organic.zig");
const group_phosphorus = @import("landscape_mass_inventory_phosphorus_ions.zig");
const group_plant = @import("landscape_mass_inventory_plant.zig");
const group_snow = @import("landscape_mass_inventory_snow.zig");
const group_surface = @import("landscape_mass_inventory_surface.zig");
const group_canopy = @import("landscape_mass_inventory_canopy.zig");
const runtime = @import("landscape_mass_balance_runtime.zig");
const local = @import("layer_local_conservation.zig");
const tillage_activity = @import("../redistribution/tillage/activity.zig");
const litter_salt_ingress = @import("../plant/salt/litter_ingress.zig");

/// Reconstructs every independently accepted spatial scope from the same
/// authoritative owners as `landscape_mass_balance_runtime.reconstructCells`.
/// The final partition identity is mandatory: no local owner may be omitted,
/// duplicated, or moved between surface/canopy/soil/snow without failing.
pub fn reconstructScopes(
    inputs: runtime.Inputs,
    layout: local.Layout,
    storage_by_scope: []inventory.Storage,
    canonical_cells_scratch: []inventory.Storage,
) !void {
    const scope_count = try layout.scopeCount();
    if (layout.cell_count != inputs.grid.cell_count or
        layout.soil_layer_capacity != inputs.grid.soil_layer_capacity or
        layout.snow_layer_capacity != inputs.snow.layer_capacity or
        storage_by_scope.len != scope_count or
        canonical_cells_scratch.len != inputs.grid.cell_count)
        return error.LayerInventoryDimensionMismatch;
    if (inputs.snow.cell_count != inputs.grid.cell_count)
        return error.LayerInventoryDimensionMismatch;
    if (inputs.root_gas) |roots|
        if (roots.soil_layer_count != layout.soil_layer_capacity)
            return error.LayerInventoryRootTopologyMismatch;

    // This validates every canonical owner and fills the caller-owned soil
    // mass carrier before the local chemistry reconstruction below.
    try runtime.reconstructCells(inputs, canonical_cells_scratch);
    @memset(storage_by_scope, .{});

    for (0..layout.cell_count) |cell| {
        const active_soil = inputs.grid.active_soil_layer_count[cell];
        if (active_soil > layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        for (0..layout.soil_layer_capacity) |layer| {
            var soil: inventory.Storage = .{};
            try soil.add(try group_gas.aggregateSoilPhysicalAndGasLayer(
                inputs.grid,
                inputs.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k,
                inputs.soil_thermal.layer_volume_m3,
                inputs.parameters.surface_physical.liquid_water_heat_capacity_megajoules_per_m3_k,
                inputs.parameters.surface_physical.ice_heat_capacity_megajoules_per_m3_k,
                inputs.parameters.surface_physical.ice_density_megagrams_per_m3,
                inputs.parameters.soil_latent_heat_of_fusion_megajoules_per_m3,
                inputs.parameters.surface_physical.pure_water_melting_temperature_k,
                inputs.soil_gas,
                cell,
                layer,
            ));
            try soil.add(try group_misc.aggregateSoilMineralTextureLayer(
                inputs.grid,
                inputs.soil_properties,
                cell,
                layer,
            ));
            try soil.add(try group_organic.aggregateSoilOrganicLayer(
                inputs.soil_organic,
                inputs.grid,
                cell,
                layer,
            ));
            try soil.add(try group_organic.aggregateSoilOrganicTransportMacroporeLayer(
                inputs.soil_organic_transport,
                inputs.grid,
                cell,
                layer,
            ));
            try soil.add(try group_nitrogen.aggregateProfileMineralNitrogenLayer(
                inputs.grid,
                inputs.mineral_nitrogen,
                inputs.soil_chemistry,
                inputs.nitrogen_fertilizer,
                inputs.soil_mass_megagrams_scratch,
                inputs.fertilizer_band,
                inputs.parameters.nitrogen_g_per_mol,
                cell,
                layer,
            ));
            try soil.add(try group_phosphorus.aggregateProfilePhosphorusAndIonsLayer(
                inputs.grid,
                inputs.micropore_solutes,
                inputs.macropore_solutes,
                inputs.soil_chemistry,
                inputs.mineral_fertilizer,
                inputs.grid.matrix_liquid_water_m3,
                inputs.soil_mass_megagrams_scratch,
                inputs.fertilizer_band,
                inputs.parameters.carbon_g_per_mol,
                inputs.parameters.phosphorus_g_per_mol,
                inputs.cell_area_m2,
                cell,
                layer,
            ));
            try soil.add(try group_phosphorus.aggregatePendingPlantLitterSaltExchangeLayer(
                inputs.plant_litter_salt_ingress,
                cell,
                layer + 1,
            ));

            var roots: inventory.Storage = .{};
            if (inputs.root_gas) |root_state|
                try roots.add(try group_gas.aggregateRootGasLayer(
                    root_state,
                    inputs.plants.species_count,
                    cell,
                    layer,
                ));
            if (inputs.plant_canopy) |canopy| {
                const root_state = inputs.root_gas orelse
                    return error.PlantInventoryRequiresRootState;
                try roots.add(try group_plant.aggregatePlantRootsLayer(
                    canopy,
                    root_state,
                    cell,
                    layer,
                ));
            }
            // The legacy whole census includes all root capacity slots. Keep
            // that exact partition, but reject stale conserved root material
            // below the live soil profile rather than silently dropping it.
            if (layer >= active_soil and !storageIsExactlyZero(roots))
                return error.ConservedRootStorageBelowActiveSoil;
            try soil.add(roots);
            try soil.validate();
            storage_by_scope[try layout.index(.{ .kind = .soil_layer, .cell = cell, .layer = layer })] = soil;
        }

        for (0..layout.snow_layer_capacity) |layer| {
            const snow = try group_snow.aggregateSnowEnthalpyLayer(
                inputs.snow,
                inputs.parameters.snow_ice_density_megagrams_per_m3,
                inputs.parameters.snow_latent_heat_of_fusion_megajoules_per_m3,
                inputs.parameters.snow_solid_heat_capacity_megajoules_per_m3_k,
                inputs.parameters.surface_physical.liquid_water_heat_capacity_megajoules_per_m3_k,
                inputs.parameters.surface_physical.ice_heat_capacity_megajoules_per_m3_k,
                inputs.parameters.surface_physical.pure_water_melting_temperature_k,
                .{
                    .nitrogen = inputs.parameters.nitrogen_g_per_mol,
                    .phosphorus = inputs.parameters.phosphorus_g_per_mol,
                    .ions = inputs.parameters.snow_ion_molar_mass_g_per_mol,
                },
                cell,
                layer,
            );
            const flat_snow = cell * layout.snow_layer_capacity + layer;
            if (!inputs.snow.active[flat_snow] and !storageIsExactlyZero(snow))
                return error.ConservedStorageInInactiveSnowLayer;
            storage_by_scope[try layout.index(.{ .kind = .snow_layer, .cell = cell, .layer = layer })] = snow;
        }

        var surface: inventory.Storage = .{};
        try surface.add(try group_misc.aggregateSuspendedConstituentsCell(
            inputs.suspended_constituents,
            inputs.soil_organic,
            inputs.parameters.carbon_g_per_mol,
            inputs.parameters.nitrogen_g_per_mol,
            inputs.parameters.phosphorus_g_per_mol,
            cell,
        ));
        try surface.add(try group_organic.aggregateSurfaceOrganicCell(inputs.surface_organic, cell));
        try surface.add(try group_surface.aggregatePendingSurfaceFireCell(
            inputs.surface_fire_exchange,
            inputs.parameters.nitrogen_g_per_mol,
            inputs.parameters.phosphorus_g_per_mol,
            cell,
        ));
        try surface.add(try group_phosphorus.aggregatePendingSurfaceMineralsCell(
            inputs.mineral_fertilizer,
            inputs.parameters.carbon_g_per_mol,
            inputs.parameters.phosphorus_g_per_mol,
            cell,
        ));
        try surface.add(try group_phosphorus.aggregatePendingPlantLitterSaltExchangeLayer(
            inputs.plant_litter_salt_ingress,
            cell,
            0,
        ));
        try surface.add(try group_surface.aggregateSurfaceChemistryCell(
            inputs.surface_chemistry,
            inputs.surface_fertilizer,
            inputs.surface_denitrification_nitrite_g_n,
            inputs.surface.litter_water_m3,
            inputs.surface_litter_dry_mass_megagrams,
            inputs.parameters.carbon_g_per_mol,
            inputs.parameters.nitrogen_g_per_mol,
            inputs.parameters.phosphorus_g_per_mol,
            cell,
        ));
        try surface.add(try group_surface.aggregateSurfaceTransportComplexesCell(
            inputs.surface_solutes,
            inputs.parameters.carbon_g_per_mol,
            inputs.parameters.phosphorus_g_per_mol,
            cell,
        ));
        try surface.add(try group_surface.aggregateSurfacePhysicalAndGasCell(
            inputs.surface,
            inputs.surface_ice_water_equivalent_m3,
            inputs.grid,
            inputs.surface_gas,
            inputs.surface_organic,
            inputs.parameters.surface_physical,
            cell,
        ));
        try surface.validate();
        storage_by_scope[try layout.index(.{ .kind = .surface, .cell = cell })] = surface;

        var canopy_scope: inventory.Storage = .{};
        if (inputs.plant_canopy) |canopy| {
            const root_state = inputs.root_gas orelse
                return error.PlantInventoryRequiresRootState;
            try canopy_scope.add(try group_plant.aggregatePlantShootsCell(canopy, root_state, cell));
        }
        if (inputs.canopy_retention) |retention|
            try canopy_scope.add(try group_canopy.aggregateCanopyWaterAndHeatCell(
                inputs.plants,
                retention,
                inputs.cell_area_m2,
                cell,
            ));
        try canopy_scope.validate();
        storage_by_scope[try layout.index(.{ .kind = .canopy, .cell = cell })] = canopy_scope;
    }

    try requireExactCellPartition(layout, storage_by_scope, canonical_cells_scratch);
}

/// Repeats each horizontal cell area over its soil, snow, surface and canopy
/// scopes. This keeps scaled absolute tolerances in native per-area units.
pub fn fillScopeAreas(layout: local.Layout, cell_area_m2: []const f64, scope_area_m2: []f64) !void {
    if (cell_area_m2.len != layout.cell_count or scope_area_m2.len != try layout.scopeCount())
        return error.LayerInventoryDimensionMismatch;
    for (scope_area_m2, 0..) |*area, scope| {
        const cell = (try layout.address(scope)).cell;
        const value = cell_area_m2[cell];
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidLandscapeCellArea;
        area.* = value;
    }
}

/// Mandatory roundoff-only partition identity. Its bound scales with the
/// number and magnitude of local addends, not with conservation acceptance
/// tolerances; a missing scientific owner cannot be hidden by loosening it.
pub fn requireExactCellPartition(
    layout: local.Layout,
    storage_by_scope: []const inventory.Storage,
    canonical_cells: []const inventory.Storage,
) !void {
    if (storage_by_scope.len != try layout.scopeCount() or canonical_cells.len != layout.cell_count)
        return error.LayerInventoryDimensionMismatch;
    const addend_count = layout.soil_layer_capacity + layout.snow_layer_capacity + 2;
    for (canonical_cells, 0..) |expected, cell| {
        var observed: inventory.Storage = .{};
        var absolute_sum: inventory.Storage = .{};
        for (storage_by_scope, 0..) |scope_storage, scope| {
            if ((try layout.address(scope)).cell != cell) continue;
            try observed.add(scope_storage);
            inline for (std.meta.fields(inventory.Storage)) |field|
                @field(absolute_sum, field.name) += @abs(@field(scope_storage, field.name));
        }
        inline for (std.meta.fields(inventory.Storage)) |field| {
            const actual = @field(observed, field.name);
            const target = @field(expected, field.name);
            const scale = @max(1, @max(@field(absolute_sum, field.name), @max(@abs(actual), @abs(target))));
            const roundoff_bound = 128 * std.math.floatEps(f64) * @as(f64, @floatFromInt(addend_count)) * scale;
            if (!std.math.isFinite(roundoff_bound) or @abs(actual - target) > roundoff_bound)
                return error.LayerInventoryPartitionMismatch;
        }
    }
}

fn storageIsExactlyZero(storage: inventory.Storage) bool {
    inline for (std.meta.fields(inventory.Storage)) |field|
        if (@field(storage, field.name) != 0) return false;
    return true;
}

test "roundoff partition identity rejects an omitted owner field" {
    const layout = try local.Layout.init(1, 2, 1);
    var scopes = [_]inventory.Storage{.{}} ** 5;
    scopes[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })].water_m3 = 2;
    scopes[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })].water_m3 = 3;
    const canonical = [_]inventory.Storage{.{ .water_m3 = 5 }};
    try requireExactCellPartition(layout, &scopes, &canonical);
    scopes[0].water_m3 -= 1.0e-8;
    try std.testing.expectError(
        error.LayerInventoryPartitionMismatch,
        requireExactCellPartition(layout, &scopes, &canonical),
    );
}

test "scope areas retain the source cell area" {
    const layout = try local.Layout.init(2, 1, 1);
    var area: [8]f64 = undefined;
    try fillScopeAreas(layout, &.{ 2, 7 }, &area);
    for (area, 0..) |value, scope|
        try std.testing.expectEqual(([_]f64{ 2, 7 })[(try layout.address(scope)).cell], value);
}

test "dry pending litter salt closes through exact tillage layer activity" {
    const layout = try local.Layout.init(1, 2, 1);
    var pending = try litter_salt_ingress.State.init(std.testing.allocator, 1, 2);
    defer pending.deinit();
    const lower_aluminum = (2 * litter_salt_ingress.salt_count) + 0;
    const upper_aluminum = (1 * litter_salt_ingress.salt_count) + 0;
    pending.pending_mol[lower_aluminum] = 2;

    var before = [_]inventory.Storage{.{}} ** 5;
    before[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })] =
        try group_phosphorus.aggregatePendingPlantLitterSaltExchangeLayer(&pending, 0, 1);
    before[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })] =
        try group_phosphorus.aggregatePendingPlantLitterSaltExchangeLayer(&pending, 0, 2);
    const canonical_before = [_]inventory.Storage{
        try group_phosphorus.aggregatePendingPlantLitterSaltsCell(&pending, 0),
    };
    try requireExactCellPartition(layout, &before, &canonical_before);

    pending.pending_mol[lower_aluminum] = 1;
    pending.pending_mol[upper_aluminum] = 1;
    var after = [_]inventory.Storage{.{}} ** 5;
    after[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })] =
        try group_phosphorus.aggregatePendingPlantLitterSaltExchangeLayer(&pending, 0, 1);
    after[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })] =
        try group_phosphorus.aggregatePendingPlantLitterSaltExchangeLayer(&pending, 0, 2);
    const canonical_after = [_]inventory.Storage{
        try group_phosphorus.aggregatePendingPlantLitterSaltsCell(&pending, 0),
    };
    try requireExactCellPartition(layout, &after, &canonical_after);

    var sidecar = try tillage_activity.Sidecar.init(
        std.testing.allocator,
        1,
        2,
        .{ .relative = 64 * std.math.floatEps(f64) },
    );
    defer sidecar.deinit();
    try sidecar.beginAttempt();
    try sidecar.stageCell(
        0,
        0,
        1,
        0.2,
        1,
        &.{ 0.1, 0.2 },
        &.{ 0.1, 0.1 },
        0,
        &.{ before[0], before[1] },
        .{},
        .{},
        &.{ after[0], after[1] },
        .{},
    );
    try sidecar.commitAttempt();
    var ledger = try local.Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    try local.accumulateTillageActivity(&ledger, &sidecar);
    var report = try local.evaluate(
        std.testing.allocator,
        &before,
        &after,
        ledger.activity,
        &.{ 1, 1, 1, 1, 1 },
        .{ .absolute_per_area = .{}, .relative = 1e-12 },
    );
    defer report.deinit(std.testing.allocator);
    try local.requireAccepted(report);
}

test "scope reconstruction validates layout before touching scientific owners" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 2 },
    );
    var grid = try @import("../state/grid.zig").GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var inputs: runtime.Inputs = undefined;
    inputs.grid = &grid;
    const mismatched_layout = try local.Layout.init(2, 1, 1);
    var scopes: [0]inventory.Storage = .{};
    var cells: [0]inventory.Storage = .{};
    try std.testing.expectError(
        error.LayerInventoryDimensionMismatch,
        reconstructScopes(inputs, mismatched_layout, &scopes, &cells),
    );
}
