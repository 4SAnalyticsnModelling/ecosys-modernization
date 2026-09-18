const std = @import("std");
const ice_units = @import("../../core/ice_units.zig");
const CellRange = @import("../../core/compute.zig").CellRange;
const GridState = @import("../../state/grid.zig").GridState;
const SoilCatalogEntry = @import("../profile/catalog.zig").Entry;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    soil_layer_capacity: usize,
    layer_volume_m3: []f64,
    layer_thickness_m: []f64,
    porosity_fraction: []f64,
    dry_solid_heat_capacity_megajoules_per_m3_k: []f64,
    solid_thermal_conductivity_numerator_m_megajoules_per_h_k: []f64,
    solid_thermal_conductivity_denominator: []f64,
    total_heat_capacity_megajoules_per_m3_k: []f64,
    thermal_conductivity_m_megajoules_per_h_k: []f64,

    pub fn initMapped(
        allocator: std.mem.Allocator,
        grid: GridState,
        catalog_entries: []const SoilCatalogEntry,
        catalog_index_by_cell: []const usize,
        horizontal_cell_width_m: []const f64,
        vertical_cell_width_m: []const f64,
    ) !State {
        if (catalog_index_by_cell.len != grid.cell_count or
            horizontal_cell_width_m.len != grid.cell_count or
            vertical_cell_width_m.len != grid.cell_count)
            return error.InvalidSoilThermalDimensions;
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = grid.cell_count;
        result.soil_layer_capacity = grid.soil_layer_capacity;
        var allocated: usize = 0;
        errdefer freeAllocated(&result, allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, grid.layer_count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };

        for (catalog_index_by_cell, 0..) |catalog_index, cell| {
            if (catalog_index >= catalog_entries.len) return error.SoilCatalogMapOutOfBounds;
            const entry = catalog_entries[catalog_index];
            if (entry.profile.total_layer_count > grid.soil_layer_capacity) return error.SoilLayerCountMismatch;
            const cell_area_m2 = horizontal_cell_width_m[cell] * vertical_cell_width_m[cell];
            for (0..entry.profile.total_layer_count) |layer| {
                const index = cell * grid.soil_layer_capacity + layer;
                result.layer_volume_m3[index] = entry.hydrology_per_m2.total_layer_volume_m3[layer] * cell_area_m2;
                result.layer_thickness_m[index] = entry.hydrology_per_m2.layer_thickness_m[layer];
                // WATSUB thermal fractions span both matrix and macropore
                // storage over VOLTI. The material porosity applies only to
                // the matrix volume; macropore volume is additional pore
                // space and must be included here.
                result.porosity_fraction[index] = (entry.hydrology_per_m2.matrix_pore_volume_m3[layer] + entry.hydrology_per_m2.macropore_volume_m3[layer]) / entry.hydrology_per_m2.total_layer_volume_m3[layer];
                result.dry_solid_heat_capacity_megajoules_per_m3_k[index] = entry.material.dry_solid_heat_capacity_megajoules_per_m3_k[layer];
                result.solid_thermal_conductivity_numerator_m_megajoules_per_h_k[index] = entry.material.solid_thermal_conductivity_numerator_m_megajoules_per_h_k[layer];
                result.solid_thermal_conductivity_denominator[index] = entry.material.solid_thermal_conductivity_denominator[layer];
            }
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name), 0..) |value, index| {
            if (!std.math.isFinite(value)) {
                std.log.err("non-finite soil thermal state: field={s} index={d} value={e}", .{ field.name, index, value });
                return error.NonFiniteSoilThermalState;
            }
        };
    }

    /// Rebuilds geometry-derived thermal carriers after a checkpoint owner
    /// swap. Runtime soil geometry is authoritative because ponding,
    /// freeze/thaw, erosion, and organic-volume changes can alter layer
    /// thickness long after catalog initialization.
    pub fn refreshGeometry(
        self: *State,
        layer_thickness_m: []const f64,
        east_west_cell_width_m: []const f64,
        north_south_cell_width_m: []const f64,
    ) !void {
        if (layer_thickness_m.len != self.layer_volume_m3.len or
            east_west_cell_width_m.len != self.cell_count or
            north_south_cell_width_m.len != self.cell_count)
            return error.SoilThermalGeometryDimensionMismatch;
        for (0..self.cell_count) |cell| {
            const area_m2 =
                east_west_cell_width_m[cell] *
                north_south_cell_width_m[cell];
            if (!std.math.isFinite(area_m2) or area_m2 <= 0)
                return error.InvalidSoilThermalCellArea;
            const first = cell * self.soil_layer_capacity;
            for (0..self.soil_layer_capacity) |layer| {
                const index = first + layer;
                const thickness_m = layer_thickness_m[index];
                if (!std.math.isFinite(thickness_m) or thickness_m <= 0)
                    return error.InvalidSoilThermalLayerThickness;
                self.layer_thickness_m[index] = thickness_m;
                self.layer_volume_m3[index] = area_m2 * thickness_m;
            }
        }
    }
};

pub const UpdateContext = struct {
    thermal: *State,
    grid: *GridState,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
};

/// Updates WATSUB heat capacity and thermal conductivity from current water,
/// ice and air fractions. Independent cells are safe for parallel dispatch.
pub fn updateTile(context: *UpdateContext, range: CellRange) !void {
    const thermal = context.thermal;
    if (range.end > thermal.cell_count or context.grid.cell_count != thermal.cell_count or context.grid.soil_layer_capacity != thermal.soil_layer_capacity) return error.SoilThermalDimensionMismatch;
    if (!std.math.isFinite(context.liquid_water_heat_capacity_megajoules_per_m3_k) or context.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or !std.math.isFinite(context.ice_heat_capacity_megajoules_per_m3_k) or context.ice_heat_capacity_megajoules_per_m3_k <= 0) return error.InvalidSoilThermalHeatCapacity;
    _ = try ice_units.physicalVolumeM3FromWaterEquivalent(0, context.ice_density_megagrams_per_m3);
    for (range.first..range.end) |cell| {
        const active_layers = context.grid.active_soil_layer_count[cell];
        if (active_layers > thermal.soil_layer_capacity) return error.SoilLayerCountMismatch;
        for (0..active_layers) |layer| {
            const index = cell * thermal.soil_layer_capacity + layer;
            const volume = thermal.layer_volume_m3[index];
            if (!std.math.isFinite(volume) or volume <= 0) return error.InvalidSoilLayerVolume;
            const pore_capacity_m3 =
                context.grid.matrix_pore_capacity_m3[index] +
                context.grid.macropore_pore_capacity_m3[index];
            const porosity_fraction = pore_capacity_m3 / volume;
            if (!std.math.isFinite(pore_capacity_m3) or pore_capacity_m3 < 0 or
                !std.math.isFinite(porosity_fraction) or
                porosity_fraction < 0 or porosity_fraction > 1)
            {
                std.log.err(
                    "invalid soil thermal pore geometry: cell={d} layer={d} matrix_pore_capacity_m3={e} macropore_pore_capacity_m3={e} layer_volume_m3={e} porosity_fraction={e}",
                    .{
                        cell,
                        layer,
                        context.grid.matrix_pore_capacity_m3[index],
                        context.grid.macropore_pore_capacity_m3[index],
                        volume,
                        porosity_fraction,
                    },
                );
                return error.InvalidSoilThermalPoreGeometry;
            }
            // Pore capacities and layer volume are the runtime owners.
            // Surface incorporation, erosion, and pond-layer remapping can
            // change them after initialization, so porosity is refreshed
            // here instead of remaining a stale catalog-derived value.
            thermal.porosity_fraction[index] = porosity_fraction;
            const liquid_water_m3 =
                context.grid.matrix_liquid_water_m3[index] +
                context.grid.macropore_liquid_water_m3[index];
            const ice_water_m3 =
                context.grid.matrix_ice_water_m3[index] +
                context.grid.macropore_ice_water_m3[index];
            context.grid.liquid_water_m3[index] = liquid_water_m3;
            context.grid.ice_water_m3[index] = ice_water_m3;
            const liquid_fraction = liquid_water_m3 / volume;
            const physical_ice_m3 = try ice_units.physicalVolumeM3FromWaterEquivalent(ice_water_m3, context.ice_density_megagrams_per_m3);
            const ice_fraction = physical_ice_m3 / volume;
            const air_fraction = @max(0.0, porosity_fraction - liquid_fraction - ice_fraction);
            // HOUR1 may contract a deep layer's VOLA beneath its preceding
            // accepted water inventory. WATSUB 3604--3606 represents that
            // transition as zero air and retains the current water/ice heat
            // capacity until its vertical mechanical prepass routes the signed
            // deficit. Rejecting it here runs before that conservative owner.
            if (!std.math.isFinite(liquid_fraction) or !std.math.isFinite(ice_fraction) or liquid_fraction < 0 or ice_fraction < 0) {
                std.log.err("invalid soil thermal water state: cell={d} layer={d} liquid_fraction={e} ice_fraction={e} porosity_fraction={e} liquid_water_m3={e} ice_water_m3={e} pore_capacity_m3={e} layer_volume_m3={e}", .{ cell, layer, liquid_fraction, ice_fraction, porosity_fraction, liquid_water_m3, ice_water_m3, pore_capacity_m3, volume });
                return error.InvalidSoilThermalWaterState;
            }
            // WATSUB lines 252--254: VHCP1 = VHCM + 4.19*(VOLW1+VOLV1+VOLWH1)
            //                              + 1.9274*(VOLI1+VOLIH1).
            // The vapor volume VOLV1 carries liquid heat capacity in the
            // oracle, and the EXEC landscape census reconstructs the same
            // definition. Omitting it here gave a layer two different heat
            // capacities depending on which owner was asked, so a conservative
            // layer remap appeared to create energy (EXEC-002).
            const vapor_fraction = context.grid.water_vapor_volume_m3[index] / volume;
            if (!std.math.isFinite(vapor_fraction) or vapor_fraction < 0) return error.InvalidSoilThermalWaterState;
            thermal.total_heat_capacity_megajoules_per_m3_k[index] = thermal.dry_solid_heat_capacity_megajoules_per_m3_k[index] + context.liquid_water_heat_capacity_megajoules_per_m3_k * (liquid_fraction + vapor_fraction) + context.ice_heat_capacity_megajoules_per_m3_k * ice_fraction;
            const air_weight = 1.467 - 0.467 * air_fraction;
            const numerator = thermal.solid_thermal_conductivity_numerator_m_megajoules_per_h_k[index] + liquid_fraction * 2.067e-3 + 0.611 * ice_fraction * 7.844e-3 + air_weight * air_fraction * 9.050e-5;
            const denominator = thermal.solid_thermal_conductivity_denominator[index] + liquid_fraction + 0.611 * ice_fraction + air_weight * air_fraction;
            if (!std.math.isFinite(numerator) or !std.math.isFinite(denominator) or numerator < 0 or denominator <= 0) return error.InvalidSoilThermalConductivity;
            thermal.thermal_conductivity_m_megajoules_per_h_k[index] = numerator / denominator;
        }
    }
}

fn freeAllocated(state: *State, count: usize) void {
    var visited: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        if (visited < count) state.allocator.free(@field(state, field.name));
        visited += 1;
    };
}

test "soil thermal state updates from mapped example water and ice" {
    const allocator = std.testing.allocator;
    const source = try @import("../../core/test_fixtures.zig").soilProfileSource(allocator, @typeInfo(@import("../../state/soil_profile.zig").LayerProperty).@"enum".fields.len);
    defer allocator.free(source);
    var catalog = @import("../profile/catalog.zig").Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("soil", source, @import("../water/retention.zig").compatibilityParameters(), @import("../profile/derivation.zig").compatibilityParameters());
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = catalog.entries.items[0].profile.total_layer_count, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 });
    var grid = try GridState.init(allocator, config);
    defer grid.deinit();
    try @import("../../driver/model_initialization.zig").initializeCellHydrology(&grid, 0, catalog.entries.items[0].hydrology_per_m2);
    var thermal = try State.initMapped(allocator, grid, catalog.entries.items, &.{0}, &.{1.0}, &.{1.0});
    defer thermal.deinit();
    var context: UpdateContext = .{ .thermal = &thermal, .grid = &grid, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .ice_density_megagrams_per_m3 = 0.917 };
    // Exact HOUR1 material-contraction state observed in the production probe:
    // thermal refresh must retain its water capacity with zero air until the
    // following WATSUB mechanical prepass routes the signed deficit.
    thermal.layer_volume_m3[0] = 4.9999999573243925e-1;
    grid.matrix_pore_capacity_m3[0] = 2.5561067029162293e-1;
    grid.matrix_liquid_water_m3[0] = 2.556106976262672e-1;
    grid.matrix_ice_water_m3[0] = 0;
    grid.macropore_pore_capacity_m3[0] = 0;
    grid.macropore_liquid_water_m3[0] = 0;
    grid.macropore_ice_water_m3[0] = 0;
    grid.matrix_air_volume_m3[0] = 0;
    grid.macropore_air_volume_m3[0] = 0;
    grid.air_volume_m3[0] = 0;
    try updateTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(grid.matrix_liquid_water_m3[0] > grid.matrix_pore_capacity_m3[0]);
    try std.testing.expectEqual(@as(f64, 0), grid.matrix_air_volume_m3[0]);
    grid.liquid_water_m3[0] = grid.matrix_pore_capacity_m3[0] * 2;
    grid.ice_water_m3[0] = grid.matrix_pore_capacity_m3[0];
    try updateTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(
        grid.matrix_liquid_water_m3[0] +
            grid.macropore_liquid_water_m3[0],
        grid.liquid_water_m3[0],
    );
    try std.testing.expectEqual(
        grid.matrix_ice_water_m3[0] +
            grid.macropore_ice_water_m3[0],
        grid.ice_water_m3[0],
    );
    try thermal.validateFinite();
    try std.testing.expect(thermal.total_heat_capacity_megajoules_per_m3_k[0] > thermal.dry_solid_heat_capacity_megajoules_per_m3_k[0]);
    const expected_capacity = thermal.dry_solid_heat_capacity_megajoules_per_m3_k[0] +
        4.19 * ((grid.matrix_liquid_water_m3[0] + grid.macropore_liquid_water_m3[0] + grid.water_vapor_volume_m3[0]) / thermal.layer_volume_m3[0]) +
        1.9274 * ((grid.matrix_ice_water_m3[0] + grid.macropore_ice_water_m3[0]) / 0.917 / thermal.layer_volume_m3[0]);
    try std.testing.expectApproxEqRel(expected_capacity, thermal.total_heat_capacity_megajoules_per_m3_k[0], 16 * std.math.floatEps(f64));
    try std.testing.expect(thermal.thermal_conductivity_m_megajoules_per_h_k[0] > 0);

    grid.matrix_pore_capacity_m3[0] += 0.01;
    try updateTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqRel(
        (grid.matrix_pore_capacity_m3[0] +
            grid.macropore_pore_capacity_m3[0]) /
            thermal.layer_volume_m3[0],
        thermal.porosity_fraction[0],
        4 * std.math.floatEps(f64),
    );
}

test "checkpoint geometry refresh replaces catalog layer volumes" {
    var layer_volume_m3 = [_]f64{ 1, 1 };
    var layer_thickness_m = [_]f64{ 1, 1 };
    var state: State = undefined;
    state.cell_count = 1;
    state.soil_layer_capacity = 2;
    state.layer_volume_m3 = &layer_volume_m3;
    state.layer_thickness_m = &layer_thickness_m;
    try state.refreshGeometry(&.{ 0.2, 0.3 }, &.{10}, &.{20});
    try std.testing.expectEqualSlices(f64, &.{ 40, 60 }, &layer_volume_m3);
    try std.testing.expectEqualSlices(f64, &.{ 0.2, 0.3 }, &layer_thickness_m);
}
