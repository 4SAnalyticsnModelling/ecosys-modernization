const std = @import("std");
const grid_module = @import("../../state/grid.zig");
const site_module = @import("../../state/site.zig");
const terrain_module = @import("../../state/terrain_hydrology.zig");
const retention_module = @import("../water/retention.zig");

pub const Direction = enum { north, east, south, west, lower };

pub const Face = struct {
    cell_index: usize,
    layer_index: usize,
    direction: Direction,
    direction_sign: f64,
    directional_layer_width_m: f64,
    slope_sine: f64,
    natural_water_table_distance_m: f64,
    natural_exchange_fraction: f64,
    artificial_water_table_distance_m: f64,
    artificial_exchange_fraction: f64,
    surface_runoff_fraction: f64,
    is_lower_boundary: bool,
};

/// Heap-owned perimeter and profile-bottom topology. Its size follows the
/// runtime grid and each cell's active layer count; no historical JX/JY/JZ
/// ceiling survives in this representation.
pub const State = struct {
    allocator: std.mem.Allocator,
    faces: []Face,
    water_table_mode: []u8,
    natural_water_table_reference_depth_m: []f64,
    natural_water_table_depth_m: []f64,
    internal_water_table_depth_m: []f64,
    active_layer_depth_m: []f64,
    artificial_water_table_depth_m: []f64,
    artificial_water_table_reference_depth_m: []f64,
    initial_surface_boundary_depth_m: []f64,
    natural_water_table_surface_slope: []f64,
    artificial_water_table_surface_slope: []f64,

    /// REDIST 11050--11057, operation 23. The runtime table uses the same
    /// depth datum as `layer_midpoint_depth_m`; validate the whole transaction
    /// before replacing the natural/current internal table for this cell.
    pub fn applyNaturalDrainageReset(
        self: *State,
        cell: usize,
        requested_depth_below_surface_m: f64,
        terrain: *const terrain_module.State,
        geometry: *const @import("layer_geometry.zig").State,
    ) !void {
        const inputs = try drainageGeometry(cell, self.water_table_mode.len, requested_depth_below_surface_m, terrain, geometry);
        if (!std.math.isFinite(self.natural_water_table_surface_slope[cell]) or self.natural_water_table_surface_slope[cell] < 0 or self.natural_water_table_surface_slope[cell] > 1)
            return error.InvalidNaturalWaterTableSlope;
        const input_depth_m = requested_depth_below_surface_m + inputs.surface_boundary_depth_m;
        const reference_depth_m = input_depth_m -
            (inputs.reference_elevation_m - inputs.cell_elevation_m) *
                (1 - self.natural_water_table_surface_slope[cell]);
        const current_depth_m = reference_depth_m + inputs.surface_boundary_depth_m;
        inline for (.{ input_depth_m, reference_depth_m, current_depth_m }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteNaturalDrainageReset;
        self.natural_water_table_depth_m[cell] = current_depth_m;
        self.natural_water_table_reference_depth_m[cell] = reference_depth_m;
        self.internal_water_table_depth_m[cell] = current_depth_m;
    }

    /// REDIST 11061--11079, operation 24. The event's continuation record is
    /// the source `RCHG*Z` baseline; installation copies those four distances
    /// and four 0/1 exchange controls onto every lateral face of the cell and
    /// promotes stationary/mobile natural modes 1/2 to artificial modes 3/4.
    pub fn applyArtificialDrainageReset(
        self: *State,
        cell: usize,
        requested_depth_below_surface_m: f64,
        boundaries: @import("../../management/disturbance_schedule.zig").DirectionalDrainage,
        terrain: *const terrain_module.State,
        geometry: *const @import("layer_geometry.zig").State,
    ) !void {
        const inputs = try drainageGeometry(cell, self.water_table_mode.len, requested_depth_below_surface_m, terrain, geometry);
        if (!std.math.isFinite(self.artificial_water_table_surface_slope[cell]) or self.artificial_water_table_surface_slope[cell] < 0 or self.artificial_water_table_surface_slope[cell] > 1)
            return error.InvalidArtificialWaterTableSlope;
        const distances = [_]f64{
            boundaries.north_distance_m,
            boundaries.east_distance_m,
            boundaries.south_distance_m,
            boundaries.west_distance_m,
        };
        for (distances) |distance_m| if (!std.math.isFinite(distance_m) or distance_m < 0)
            return error.InvalidArtificialDrainageBoundaryDistance;
        const input_depth_m = requested_depth_below_surface_m + inputs.surface_boundary_depth_m;
        const reference_depth_m = @max(0.0, input_depth_m -
            (inputs.reference_elevation_m - inputs.cell_elevation_m) *
                (1 - self.artificial_water_table_surface_slope[cell]));
        if (!std.math.isFinite(input_depth_m) or !std.math.isFinite(reference_depth_m))
            return error.NonFiniteArtificialDrainageReset;

        self.water_table_mode[cell] = switch (self.water_table_mode[cell]) {
            1 => 3,
            2 => 4,
            else => self.water_table_mode[cell],
        };
        self.artificial_water_table_depth_m[cell] = reference_depth_m;
        self.artificial_water_table_reference_depth_m[cell] = reference_depth_m;
        for (self.faces) |*face| {
            if (face.cell_index != cell or face.is_lower_boundary) continue;
            const direction_index: usize = switch (face.direction) {
                .north => 0,
                .east => 1,
                .south => 2,
                .west => 3,
                .lower => unreachable,
            };
            face.artificial_water_table_distance_m = distances[direction_index];
            face.artificial_exchange_fraction = if (switch (face.direction) {
                .north => boundaries.north_flow_enabled,
                .east => boundaries.east_flow_enabled,
                .south => boundaries.south_flow_enabled,
                .west => boundaries.west_flow_enabled,
                .lower => unreachable,
            }) 1 else 0;
        }
    }

    /// Binds source CDPTHI after the runtime layer geometry is initialized.
    pub fn bindInitialSurfaceBoundaryDepths(self: *State, geometry: *const @import("layer_geometry.zig").State) !void {
        if (geometry.cell_count != self.water_table_mode.len) return error.SoilBoundaryTopologyDimensionMismatch;
        for (0..geometry.cell_count) |cell| {
            const first = geometry.first_active_layer[cell];
            if (geometry.active_layer_count[cell] == 0 or first >= geometry.layer_capacity) return error.InvalidActiveSoilLayerRange;
            const value = geometry.boundary_depth_m[try geometry.boundaryIndex(cell, first)];
            if (!std.math.isFinite(value)) return error.NonFiniteDrainageResetGeometry;
        }
        for (0..geometry.cell_count) |cell| {
            const first = geometry.first_active_layer[cell];
            self.initial_surface_boundary_depth_m[cell] = geometry.boundary_depth_m[try geometry.boundaryIndex(cell, first)];
        }
    }

    /// HOUR1 2348--2356 refreshes current external heads before WATSUB.
    pub fn refreshExternalWaterTables(self: *State, geometry: *const @import("layer_geometry.zig").State) !void {
        if (geometry.cell_count != self.water_table_mode.len) return error.SoilBoundaryTopologyDimensionMismatch;
        for (0..geometry.cell_count) |cell| {
            const first = geometry.first_active_layer[cell];
            if (geometry.active_layer_count[cell] == 0 or first >= geometry.layer_capacity) return error.InvalidActiveSoilLayerRange;
            const surface_depth_m = geometry.boundary_depth_m[try geometry.boundaryIndex(cell, first)];
            const natural = switch (self.water_table_mode[cell]) {
                2, 4 => self.natural_water_table_reference_depth_m[cell] + surface_depth_m - self.initial_surface_boundary_depth_m[cell],
                else => self.natural_water_table_reference_depth_m[cell],
            };
            const artificial = self.artificial_water_table_reference_depth_m[cell];
            if (!std.math.isFinite(surface_depth_m) or !std.math.isFinite(natural) or !std.math.isFinite(artificial)) return error.NonFiniteExternalWaterTableDepth;
        }
        for (0..geometry.cell_count) |cell| {
            const first = geometry.first_active_layer[cell];
            const surface_depth_m = geometry.boundary_depth_m[try geometry.boundaryIndex(cell, first)];
            self.natural_water_table_depth_m[cell] = switch (self.water_table_mode[cell]) {
                2, 4 => self.natural_water_table_reference_depth_m[cell] + surface_depth_m - self.initial_surface_boundary_depth_m[cell],
                else => self.natural_water_table_reference_depth_m[cell],
            };
            if (self.water_table_mode[cell] == 3 or self.water_table_mode[cell] == 4)
                self.artificial_water_table_depth_m[cell] = self.artificial_water_table_reference_depth_m[cell];
        }
    }

    /// REDIST 11090--11100, once daily at the cell's solar noon. The Zig
    /// boundary ledger is gain-positive, whereas HVOLO is outward-positive,
    /// hence source `-HVOLO/AREA` is `+boundary_gain/AREA` here.
    pub fn advanceMobileTablesAtSolarNoon(self: *State, cell: usize, surface_boundary_depth_m: f64, boundary_water_gain_m3: f64, cell_area_m2: f64) !bool {
        if (cell >= self.water_table_mode.len) return error.DrainageResetDimensionMismatch;
        inline for (.{ surface_boundary_depth_m, boundary_water_gain_m3, cell_area_m2 }) |value| if (!std.math.isFinite(value)) return error.NonFiniteMobileWaterTableInput;
        if (cell_area_m2 <= 0) return error.InvalidMobileWaterTableCellArea;
        const mode = self.water_table_mode[cell];
        if (mode != 2 and mode != 4) return false;
        const specific_gain_m = boundary_water_gain_m3 / cell_area_m2;
        const natural_next = self.natural_water_table_reference_depth_m[cell] + surface_boundary_depth_m + specific_gain_m;
        const artificial_next = if (mode == 4)
            self.artificial_water_table_depth_m[cell] + specific_gain_m -
                0.00167 * (self.artificial_water_table_depth_m[cell] - self.artificial_water_table_reference_depth_m[cell])
        else
            self.artificial_water_table_depth_m[cell];
        if (!std.math.isFinite(natural_next) or !std.math.isFinite(artificial_next)) return error.NonFiniteMobileWaterTableResult;
        self.natural_water_table_depth_m[cell] = natural_next;
        if (mode == 4) self.artificial_water_table_depth_m[cell] = artificial_next;
        return true;
    }

    pub fn initMapped(
        allocator: std.mem.Allocator,
        grid: *const grid_module.GridState,
        terrain: *const terrain_module.State,
        columns: usize,
        rows: usize,
        horizontal_cell_width_m: []const f64,
        vertical_cell_width_m: []const f64,
        site_by_cell: []const site_module.Site,
    ) !State {
        if (columns == 0 or rows == 0 or
            try std.math.mul(usize, columns, rows) != grid.cell_count or
            terrain.columns != columns or terrain.rows != rows or
            horizontal_cell_width_m.len != grid.cell_count or
            vertical_cell_width_m.len != grid.cell_count or
            site_by_cell.len != grid.cell_count)
            return error.SoilBoundaryTopologyDimensionMismatch;
        var face_count: usize = grid.cell_count;
        for (0..grid.cell_count) |cell| {
            const row = cell / columns;
            const column = cell % columns;
            var lateral_edges: usize = 0;
            if (row == 0) lateral_edges += 1;
            if (column + 1 == columns) lateral_edges += 1;
            if (row + 1 == rows) lateral_edges += 1;
            if (column == 0) lateral_edges += 1;
            face_count = try std.math.add(usize, face_count, try std.math.mul(usize, lateral_edges, grid.active_soil_layer_count[cell]));
        }
        const faces = try allocator.alloc(Face, face_count);
        errdefer allocator.free(faces);
        const natural_depth = try allocator.alloc(f64, grid.cell_count);
        errdefer allocator.free(natural_depth);
        const natural_reference_depth = try allocator.alloc(f64, grid.cell_count);
        errdefer allocator.free(natural_reference_depth);
        const artificial_depth = try allocator.alloc(f64, grid.cell_count);
        errdefer allocator.free(artificial_depth);
        const artificial_reference_depth = try allocator.alloc(f64, grid.cell_count);
        errdefer allocator.free(artificial_reference_depth);
        const initial_surface_boundary_depth = try allocator.alloc(f64, grid.cell_count);
        errdefer allocator.free(initial_surface_boundary_depth);
        const internal_depth = try allocator.alloc(f64, grid.cell_count);
        errdefer allocator.free(internal_depth);
        const active_layer_depth = try allocator.alloc(f64, grid.cell_count);
        errdefer allocator.free(active_layer_depth);
        const water_table_mode = try allocator.alloc(u8, grid.cell_count);
        errdefer allocator.free(water_table_mode);
        const natural_slope = try allocator.alloc(f64, grid.cell_count);
        errdefer allocator.free(natural_slope);
        const artificial_slope = try allocator.alloc(f64, grid.cell_count);
        errdefer allocator.free(artificial_slope);
        for (0..grid.cell_count) |cell| {
            const site = site_by_cell[cell];
            const elevation_adjustment_m = terrain.minimum_surface_elevation_m - terrain.relative_surface_elevation_m[cell];
            natural_depth[cell] = site.initial_water_table_depth_m - elevation_adjustment_m * (1 - site.natural_water_table_surface_slope);
            natural_reference_depth[cell] = natural_depth[cell];
            internal_depth[cell] = natural_depth[cell];
            active_layer_depth[cell] = 9999;
            artificial_depth[cell] = if (site.artificial_water_table_depth_m) |depth| @max(0, depth - elevation_adjustment_m * (1 - site.artificial_water_table_surface_slope.?)) else 0;
            artificial_reference_depth[cell] = artificial_depth[cell];
            initial_surface_boundary_depth[cell] = 0;
            water_table_mode[cell] = site.water_table_mode;
            natural_slope[cell] = site.natural_water_table_surface_slope;
            artificial_slope[cell] = site.artificial_water_table_surface_slope orelse 0;
        }
        var next: usize = 0;
        for (0..grid.cell_count) |cell| {
            const site = &site_by_cell[cell];
            const row = cell / columns;
            const column = cell % columns;
            const active_layers = grid.active_soil_layer_count[cell];
            if (active_layers == 0 or active_layers > grid.soil_layer_capacity) return error.InvalidActiveSoilLayerCount;
            for (0..active_layers) |layer| {
                const layer_index = try grid.layerIndex(cell, layer);
                const x_width_m = horizontal_cell_width_m[cell];
                const y_width_m = vertical_cell_width_m[cell];
                if (row == 0) appendLateral(faces, &next, cell, layer_index, .north, 0, y_width_m, terrain.north_south_slope_m_per_m[cell], site);
                if (column + 1 == columns) appendLateral(faces, &next, cell, layer_index, .east, 1, x_width_m, terrain.east_west_slope_m_per_m[cell], site);
                if (row + 1 == rows) appendLateral(faces, &next, cell, layer_index, .south, 2, y_width_m, terrain.north_south_slope_m_per_m[cell], site);
                if (column == 0) appendLateral(faces, &next, cell, layer_index, .west, 3, x_width_m, terrain.east_west_slope_m_per_m[cell], site);
            }
            const bottom_layer_index = try grid.layerIndex(cell, active_layers - 1);
            faces[next] = .{
                .cell_index = cell,
                .layer_index = bottom_layer_index,
                .direction = .lower,
                .direction_sign = -1,
                .directional_layer_width_m = 1,
                .slope_sine = 1,
                .natural_water_table_distance_m = 1,
                .natural_exchange_fraction = site.lower_boundary_exchange_fraction,
                .artificial_water_table_distance_m = 0,
                .artificial_exchange_fraction = 0,
                .surface_runoff_fraction = 0,
                .is_lower_boundary = true,
            };
            next += 1;
        }
        std.debug.assert(next == faces.len);
        return .{ .allocator = allocator, .faces = faces, .water_table_mode = water_table_mode, .natural_water_table_reference_depth_m = natural_reference_depth, .natural_water_table_depth_m = natural_depth, .internal_water_table_depth_m = internal_depth, .active_layer_depth_m = active_layer_depth, .artificial_water_table_depth_m = artificial_depth, .artificial_water_table_reference_depth_m = artificial_reference_depth, .initial_surface_boundary_depth_m = initial_surface_boundary_depth, .natural_water_table_surface_slope = natural_slope, .artificial_water_table_surface_slope = artificial_slope };
    }

    /// HOUR1 DPTHT refresh. A saturated zone must remain continuous downward
    /// until the prescribed natural table is reached; its upper boundary is
    /// placed within the layer above by van Genuchten effective saturation,
    /// `(theta - theta_r) / (theta_s - theta_r)`. The legacy form interpolated
    /// between porosity and the THETS air-entry water content taken off the
    /// HCND conductivity sweep; effective saturation is the same normalised
    /// wetness measured against the retention curve the model integrates, and
    /// needs no air-entry threshold.
    ///
    /// When the crossing layer is the topmost active soil layer (`L<=NU` in
    /// legacy), HOUR1 takes the litter/pond arm of DPTHT rather than the
    /// interior-layer THETPX arm: `CDPTH(NU-1)-max(0,(VOLW(0)-VOLWRX)/AREA(3,0))`.
    /// `CDPTH(NU-1)` is the soil-surface datum (0 here); the subtracted term is
    /// standing water held above the litter's retention capacity, which pins
    /// the table above the surface (negative depth) during full-column
    /// saturation with surface ponding (BOUNDARY-TOPOLOGY-DPTHT-LITTER-001).
    pub fn refreshInternalWaterTable(self: *State, grid: *const grid_module.GridState, matrix_bulk_volume_m3: []const f64, mualem_van_genuchten_parameters: []const retention_module.MualemVanGenuchtenParameters, layer_thickness_m: []const f64, layer_midpoint_depth_m: []const f64, layer_bottom_depth_m: []const f64, air_fraction_threshold: f64, minimum_frozen_pore_fraction: f64, surface_liquid_water_m3: []const f64, litter_water_retention_capacity_m3: []const f64, cell_area_m2: []const f64) !void {
        return self.refreshInternalWaterTableWithIceDensity(grid, matrix_bulk_volume_m3, mualem_van_genuchten_parameters, layer_thickness_m, layer_midpoint_depth_m, layer_bottom_depth_m, air_fraction_threshold, minimum_frozen_pore_fraction, surface_liquid_water_m3, litter_water_retention_capacity_m3, cell_area_m2, 0.917);
    }

    pub fn refreshInternalWaterTableWithIceDensity(self: *State, grid: *const grid_module.GridState, matrix_bulk_volume_m3: []const f64, mualem_van_genuchten_parameters: []const retention_module.MualemVanGenuchtenParameters, layer_thickness_m: []const f64, layer_midpoint_depth_m: []const f64, layer_bottom_depth_m: []const f64, air_fraction_threshold: f64, minimum_frozen_pore_fraction: f64, surface_liquid_water_m3: []const f64, litter_water_retention_capacity_m3: []const f64, cell_area_m2: []const f64, ice_density_megagrams_per_m3: f64) !void {
        const layers = grid.layer_count;
        if (matrix_bulk_volume_m3.len != layers or mualem_van_genuchten_parameters.len != layers or layer_thickness_m.len != layers or layer_midpoint_depth_m.len != layers or layer_bottom_depth_m.len != layers or !std.math.isFinite(air_fraction_threshold) or air_fraction_threshold < 0 or !std.math.isFinite(minimum_frozen_pore_fraction) or minimum_frozen_pore_fraction < 0 or surface_liquid_water_m3.len != grid.cell_count or litter_water_retention_capacity_m3.len != grid.cell_count or cell_area_m2.len != grid.cell_count or !std.math.isFinite(ice_density_megagrams_per_m3) or ice_density_megagrams_per_m3 <= 0 or ice_density_megagrams_per_m3 > 1) return error.SoilBoundaryTopologyDimensionMismatch;
        for (0..grid.cell_count) |cell| {
            const active_layers = grid.active_soil_layer_count[cell];
            self.active_layer_depth_m[cell] = 9999;
            for (0..active_layers) |local_layer| {
                const layer = try grid.layerIndex(cell, local_layer);
                const pore_volume_m3 = grid.matrix_pore_capacity_m3[layer] + grid.macropore_pore_capacity_m3[layer];
                const ice_volume_m3 = (grid.matrix_ice_water_m3[layer] + grid.macropore_ice_water_m3[layer]) / ice_density_megagrams_per_m3;
                if (pore_volume_m3 <= 0 or ice_volume_m3 < minimum_frozen_pore_fraction * pore_volume_m3) continue;
                var lower_layers_frozen = true;
                var lower_local = local_layer + 1;
                while (lower_local < active_layers) : (lower_local += 1) {
                    const lower = try grid.layerIndex(cell, lower_local);
                    const lower_pore_m3 = grid.matrix_pore_capacity_m3[lower] + grid.macropore_pore_capacity_m3[lower];
                    const lower_ice_m3 = (grid.matrix_ice_water_m3[lower] + grid.macropore_ice_water_m3[lower]) / ice_density_megagrams_per_m3;
                    if (lower_pore_m3 > 0 and lower_ice_m3 < minimum_frozen_pore_fraction * lower_pore_m3) {
                        lower_layers_frozen = false;
                        break;
                    }
                }
                if (!lower_layers_frozen) continue;
                self.active_layer_depth_m[cell] = layer_bottom_depth_m[layer] - layer_thickness_m[layer] * std.math.clamp(ice_volume_m3 / pore_volume_m3, 0, 1);
                break;
            }
            if (self.water_table_mode[cell] == 0) continue;
            var found = false;
            for (0..active_layers) |local_layer| {
                const layer = try grid.layerIndex(cell, local_layer);
                const total_pore_volume_m3 = grid.matrix_pore_capacity_m3[layer] + grid.macropore_pore_capacity_m3[layer];
                const air_fraction = if (matrix_bulk_volume_m3[layer] > 0) grid.matrix_air_volume_m3[layer] / matrix_bulk_volume_m3[layer] else 0;
                if (total_pore_volume_m3 <= 0 or (air_fraction >= air_fraction_threshold and local_layer + 1 != active_layers)) continue;
                var continuous = true;
                if (layer_midpoint_depth_m[layer] < self.natural_water_table_depth_m[cell]) {
                    var lower_local = local_layer + 1;
                    while (lower_local < active_layers) : (lower_local += 1) {
                        const lower = try grid.layerIndex(cell, lower_local);
                        const lower_air_fraction = if (matrix_bulk_volume_m3[lower] > 0) grid.matrix_air_volume_m3[lower] / matrix_bulk_volume_m3[lower] else 0;
                        if (lower_air_fraction >= air_fraction_threshold and lower_local + 1 != active_layers) {
                            continuous = false;
                            break;
                        }
                        if (layer_midpoint_depth_m[lower] >= self.natural_water_table_depth_m[cell]) break;
                    }
                }
                if (!continuous) continue;
                if (local_layer == 0) {
                    // HOUR1 DPTHT L<=NU (litter/pond) arm: CDPTH(NU-1) is the
                    // soil-surface datum, 0 in this depth-from-surface
                    // convention, minus any standing water held above the
                    // litter's retention capacity VOLWRX
                    // (`(VOLW(0)-VOLWRX)/AREA(3,0)`), pinning the table above
                    // the surface (negative) rather than at it.
                    if (cell_area_m2[cell] <= 0) return error.InvalidSoilBoundaryTopologyCellArea;
                    self.internal_water_table_depth_m[cell] =
                        -@max(0.0, (surface_liquid_water_m3[cell] - litter_water_retention_capacity_m3[cell]) / cell_area_m2[cell]);
                } else {
                    const above = try grid.layerIndex(cell, local_layer - 1);
                    const water_fraction = grid.matrix_liquid_water_m3[above] / matrix_bulk_volume_m3[above];
                    const saturated_fraction = try mualem_van_genuchten_parameters[above]
                        .effectiveSaturationAtWaterContent(water_fraction);
                    self.internal_water_table_depth_m[cell] = layer_bottom_depth_m[above] - layer_thickness_m[above] * saturated_fraction;
                }
                found = true;
                break;
            }
            if (!found) self.internal_water_table_depth_m[cell] = self.natural_water_table_depth_m[cell];
            if (!std.math.isFinite(self.internal_water_table_depth_m[cell])) return error.NonFiniteInternalWaterTableDepth;
        }
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.faces);
        self.allocator.free(self.artificial_water_table_surface_slope);
        self.allocator.free(self.natural_water_table_surface_slope);
        self.allocator.free(self.water_table_mode);
        self.allocator.free(self.initial_surface_boundary_depth_m);
        self.allocator.free(self.artificial_water_table_reference_depth_m);
        self.allocator.free(self.artificial_water_table_depth_m);
        self.allocator.free(self.internal_water_table_depth_m);
        self.allocator.free(self.active_layer_depth_m);
        self.allocator.free(self.natural_water_table_depth_m);
        self.allocator.free(self.natural_water_table_reference_depth_m);
        self.* = undefined;
    }
};

const DrainageGeometry = struct {
    surface_boundary_depth_m: f64,
    reference_elevation_m: f64,
    cell_elevation_m: f64,
};

fn drainageGeometry(
    cell: usize,
    cell_count: usize,
    requested_depth_below_surface_m: f64,
    terrain: *const terrain_module.State,
    geometry: *const @import("layer_geometry.zig").State,
) !DrainageGeometry {
    if (cell >= cell_count or terrain.initial_surface_elevation_m.len != cell_count or
        geometry.cell_count != cell_count or geometry.first_active_layer.len != cell_count)
        return error.DrainageResetDimensionMismatch;
    if (!std.math.isFinite(requested_depth_below_surface_m) or requested_depth_below_surface_m < 0)
        return error.InvalidDrainageResetDepth;
    const first = geometry.first_active_layer[cell];
    if (geometry.active_layer_count[cell] == 0 or first >= geometry.layer_capacity)
        return error.InvalidActiveSoilLayerRange;
    const surface_boundary_depth_m = geometry.boundary_depth_m[try geometry.boundaryIndex(cell, first)];
    var reference_elevation_m = terrain.initial_surface_elevation_m[0];
    for (terrain.initial_surface_elevation_m) |elevation_m| {
        if (!std.math.isFinite(elevation_m)) return error.NonFiniteDrainageResetGeometry;
        reference_elevation_m = @min(reference_elevation_m, elevation_m);
    }
    const cell_elevation_m = terrain.initial_surface_elevation_m[cell];
    if (!std.math.isFinite(surface_boundary_depth_m) or !std.math.isFinite(cell_elevation_m))
        return error.NonFiniteDrainageResetGeometry;
    return .{
        .surface_boundary_depth_m = surface_boundary_depth_m,
        .reference_elevation_m = reference_elevation_m,
        .cell_elevation_m = cell_elevation_m,
    };
}

fn appendLateral(faces: []Face, next: *usize, cell_index: usize, layer_index: usize, direction: Direction, site_index: usize, directional_layer_width_m: f64, slope_sine: f64, site: *const site_module.Site) void {
    faces[next.*] = .{
        .cell_index = cell_index,
        .layer_index = layer_index,
        .direction = direction,
        // Exact WATSUB XN convention: east/south=-1, west/north=+1.
        .direction_sign = if (direction == .east or direction == .south) -1 else 1,
        .directional_layer_width_m = directional_layer_width_m,
        .slope_sine = slope_sine,
        .natural_water_table_distance_m = site.natural_water_table_distance_m[site_index],
        .natural_exchange_fraction = site.natural_subsurface_exchange_fraction[site_index],
        .artificial_water_table_distance_m = site.artificial_water_table_distance_m[site_index],
        .artificial_exchange_fraction = site.artificial_subsurface_exchange_fraction[site_index],
        .surface_runoff_fraction = site.surface_runoff_boundary_fraction[site_index],
        .is_lower_boundary = false,
    };
    next.* += 1;
}

test "runtime boundary topology preserves READI compass order and WATSUB signs" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    var site = try site_module.parse(std.testing.allocator, @import("../../core/test_fixtures.zig").site_source_2x1, 2, 1);
    defer site.deinit();
    var topography = try @import("../../state/topography.zig").fromUnits(std.testing.allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 2, .south_row = 1 }});
    defer topography.deinit();
    var terrain = try terrain_module.State.initMapped(std.testing.allocator, topography, &.{ 0, 0 }, &.{ 1, 1 }, &.{ 1, 1 }, 2, 1);
    defer terrain.deinit();
    var sites = [_]site_module.Site{ site, site };
    sites[1].initial_water_table_depth_m = 4.0;
    sites[1].water_table_mode = 1;
    sites[1].natural_water_table_distance_m[1] = 25;
    sites[1].natural_subsurface_exchange_fraction[1] = 0.75;
    var state = try State.initMapped(std.testing.allocator, &grid, &terrain, 2, 1, &.{ 1, 1 }, &.{ 1, 1 }, &sites);
    defer state.deinit();
    // Two cells x two layers: N/S on both cells, W on first, E on second,
    // plus one bottom face per cell.
    try std.testing.expectEqual(@as(usize, 14), state.faces.len);
    const east_expected_depth = sites[1].initial_water_table_depth_m -
        (terrain.minimum_surface_elevation_m - terrain.relative_surface_elevation_m[1]) *
            (1 - sites[1].natural_water_table_surface_slope);
    try std.testing.expectEqual(east_expected_depth, state.natural_water_table_depth_m[1]);
    try std.testing.expectEqual(@as(u8, 1), state.water_table_mode[1]);
    try std.testing.expectEqual(Direction.north, state.faces[0].direction);
    try std.testing.expectEqual(@as(f64, 1), state.faces[0].direction_sign);
    try std.testing.expectEqual(@as(f64, 10), state.faces[0].natural_water_table_distance_m);
    var east_found = false;
    var lower_count: usize = 0;
    for (state.faces) |face| {
        if (face.direction == .east) {
            east_found = true;
            try std.testing.expectEqual(@as(f64, -1), face.direction_sign);
            try std.testing.expectEqual(@as(f64, 25), face.natural_water_table_distance_m);
            try std.testing.expectEqual(@as(f64, 0.75), face.natural_exchange_fraction);
        }
        if (face.is_lower_boundary) {
            lower_count += 1;
            try std.testing.expectEqual(site.lower_boundary_exchange_fraction, face.natural_exchange_fraction);
        }
    }
    try std.testing.expect(east_found);
    try std.testing.expectEqual(@as(usize, 2), lower_count);
    const expected_depth = site.initial_water_table_depth_m - (terrain.minimum_surface_elevation_m - terrain.relative_surface_elevation_m[0]) * (1 - site.natural_water_table_surface_slope);
    try std.testing.expectApproxEqAbs(expected_depth, state.natural_water_table_depth_m[0], 1e-12);
}

test "REDIST operations 23 and 24 update live water tables and lateral faces atomically" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    var site = try site_module.parse(std.testing.allocator, @import("../../core/test_fixtures.zig").site_source_2x1, 2, 1);
    defer site.deinit();
    var sites = [_]site_module.Site{ site, site };
    sites[0].water_table_mode = 2;
    sites[0].natural_water_table_surface_slope = 0.25;
    sites[0].artificial_water_table_surface_slope = 0.5;
    var topography = try @import("../../state/topography.zig").fromUnits(std.testing.allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 2, .south_row = 1 }});
    defer topography.deinit();
    var terrain = try terrain_module.State.initMapped(std.testing.allocator, topography, &.{ 0, 0 }, &.{ 1, 1 }, &.{ 1, 1 }, 2, 1);
    defer terrain.deinit();
    try terrain.bindInitialSurfaceElevations(&.{ 100, 90 });
    var geometry = try @import("layer_geometry.zig").State.init(std.testing.allocator, 2, 1);
    defer geometry.deinit();
    try @import("layer_geometry.zig").initializeCell(&geometry, 0, 0, &.{1}, 0.2, 1e-6);
    try @import("layer_geometry.zig").initializeCell(&geometry, 1, 0, &.{1}, 0, 1e-6);
    var state = try State.initMapped(std.testing.allocator, &grid, &terrain, 2, 1, &.{ 1, 1 }, &.{ 1, 1 }, &sites);
    defer state.deinit();
    try state.bindInitialSurfaceBoundaryDepths(&geometry);

    try state.applyNaturalDrainageReset(0, 3, &terrain, &geometry);
    // DCORPW=3+0.2; DTBLZ=3.2-(90-100)*(1-0.25)=10.7;
    // DTBLX=DTBLZ+0.2=10.9.
    try std.testing.expectApproxEqAbs(@as(f64, 10.9), state.natural_water_table_depth_m[0], 1e-12);
    try std.testing.expectEqual(state.natural_water_table_depth_m[0], state.internal_water_table_depth_m[0]);

    const event_boundaries = @import("../../management/disturbance_schedule.zig").DirectionalDrainage{
        .north_distance_m = 11,
        .east_distance_m = 12,
        .south_distance_m = 13,
        .west_distance_m = 14,
        .north_flow_enabled = true,
        .east_flow_enabled = false,
        .south_flow_enabled = true,
        .west_flow_enabled = false,
    };
    try state.applyArtificialDrainageReset(0, 4, event_boundaries, &terrain, &geometry);
    try std.testing.expectEqual(@as(u8, 4), state.water_table_mode[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 9.2), state.artificial_water_table_depth_m[0], 1e-12);
    for (state.faces) |face| if (face.cell_index == 0 and !face.is_lower_boundary) switch (face.direction) {
        .north => {
            try std.testing.expectEqual(@as(f64, 11), face.artificial_water_table_distance_m);
            try std.testing.expectEqual(@as(f64, 1), face.artificial_exchange_fraction);
        },
        .east => {
            try std.testing.expectEqual(@as(f64, 12), face.artificial_water_table_distance_m);
            try std.testing.expectEqual(@as(f64, 0), face.artificial_exchange_fraction);
        },
        .south => {
            try std.testing.expectEqual(@as(f64, 13), face.artificial_water_table_distance_m);
            try std.testing.expectEqual(@as(f64, 1), face.artificial_exchange_fraction);
        },
        .west => {
            try std.testing.expectEqual(@as(f64, 14), face.artificial_water_table_distance_m);
            try std.testing.expectEqual(@as(f64, 0), face.artificial_exchange_fraction);
        },
        .lower => unreachable,
    };

    const before_mode = state.water_table_mode[0];
    const before_depth = state.artificial_water_table_depth_m[0];
    const before_face = state.faces[0];
    var invalid = event_boundaries;
    invalid.north_distance_m = std.math.nan(f64);
    try std.testing.expectError(error.InvalidArtificialDrainageBoundaryDistance, state.applyArtificialDrainageReset(0, 5, invalid, &terrain, &geometry));
    try std.testing.expectEqual(before_mode, state.water_table_mode[0]);
    try std.testing.expectEqual(before_depth, state.artificial_water_table_depth_m[0]);
    try std.testing.expectEqualDeep(before_face, state.faces[0]);

    // HOUR1 follows a changed surface datum for mobile natural tables and
    // resets the artificial current table to its reference. REDIST then adds
    // gain-positive boundary water once at solar noon.
    try @import("layer_geometry.zig").initializeCell(&geometry, 0, 0, &.{1}, 0.5, 1e-6);
    try state.refreshExternalWaterTables(&geometry);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), state.natural_water_table_depth_m[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 9.2), state.artificial_water_table_depth_m[0], 1e-12);
    try std.testing.expect(try state.advanceMobileTablesAtSolarNoon(0, 0.5, 2, 10));
    try std.testing.expectApproxEqAbs(@as(f64, 11.4), state.natural_water_table_depth_m[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 9.4), state.artificial_water_table_depth_m[0], 1e-12);
    try state.refreshExternalWaterTables(&geometry);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), state.natural_water_table_depth_m[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 9.2), state.artificial_water_table_depth_m[0], 1e-12);
}

test "internal water table refresh interpolates HOUR1 DPTHT from runtime saturation" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    var site = try site_module.parse(std.testing.allocator, @import("../../core/test_fixtures.zig").site_source, 1, 1);
    defer site.deinit();
    var topography = try @import("../../state/topography.zig").fromUnits(std.testing.allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1 }});
    defer topography.deinit();
    var terrain = try terrain_module.State.initMapped(std.testing.allocator, topography, &.{0}, &.{1}, &.{1}, 1, 1);
    defer terrain.deinit();
    var state = try State.initMapped(std.testing.allocator, &grid, &terrain, 1, 1, &.{1}, &.{1}, &.{site});
    defer state.deinit();
    state.water_table_mode[0] = 1;
    grid.matrix_pore_capacity_m3[0] = 0.5;
    grid.matrix_pore_capacity_m3[1] = 0.5;
    grid.matrix_liquid_water_m3[0] = 0.4;
    grid.matrix_liquid_water_m3[1] = 0.5;
    grid.matrix_air_volume_m3[0] = 0.1;
    grid.matrix_air_volume_m3[1] = 0;
    grid.air_volume_m3[0] = 0.1;
    grid.air_volume_m3[1] = 0;
    // theta_r = 0.1 and theta_s = 0.7 make the effective saturation of the
    // layer above exactly (0.4 - 0.1) / (0.7 - 0.1) = 0.5, which places the
    // water table half a layer thickness above that layer's bottom.
    const parameters: retention_module.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.1,
        .saturated_water_content_m3_per_m3 = 0.7,
        .alpha_per_m = 2,
        .n = 1.5,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    };
    try state.refreshInternalWaterTable(&grid, &.{ 1, 1 }, &.{ parameters, parameters }, &.{ 0.1, 0.1 }, &.{ 0.05, 0.15 }, &.{ 0.1, 0.2 }, 1e-3, 1e-6, &.{0}, &.{0}, &.{1});
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), state.internal_water_table_depth_m[0], 1e-12);
    grid.matrix_ice_water_m3[1] = 0.25;
    try state.refreshInternalWaterTable(&grid, &.{ 1, 1 }, &.{ parameters, parameters }, &.{ 0.1, 0.1 }, &.{ 0.05, 0.15 }, &.{ 0.1, 0.2 }, 1e-3, 1e-6, &.{0}, &.{0}, &.{1});
    // Ice storage is WE, so 0.25 m3 WE occupies 0.25/rho_ice m3 of pores.
    const expected_active_layer_depth_m = 0.2 - 0.1 * ((0.25 / 0.917) / 0.5);
    try std.testing.expectApproxEqAbs(expected_active_layer_depth_m, state.active_layer_depth_m[0], 1e-12);
}

test "BOUNDARY-TOPOLOGY-DPTHT-LITTER-001 the top-layer DPTHT arm carries the litter ponding term above the surface" {
    // HOUR1 hour1.f:4307-4312: when the crossing layer is the topmost active
    // soil layer (L<=NU), DPTHT is CDPTH(NU-1) (the surface datum, 0 here)
    // minus max(0,(VOLW(0)-VOLWRX)/AREA(3,0)) -- standing litter water above
    // retention capacity pins the table above the surface (negative depth).
    // Before this fix, the branch hard-coded 0 and dropped that term.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    var site = try site_module.parse(std.testing.allocator, @import("../../core/test_fixtures.zig").site_source, 1, 1);
    defer site.deinit();
    var topography = try @import("../../state/topography.zig").fromUnits(std.testing.allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1 }});
    defer topography.deinit();
    var terrain = try terrain_module.State.initMapped(std.testing.allocator, topography, &.{0}, &.{1}, &.{1}, 1, 1);
    defer terrain.deinit();
    var state = try State.initMapped(std.testing.allocator, &grid, &terrain, 1, 1, &.{1}, &.{1}, &.{site});
    defer state.deinit();
    state.water_table_mode[0] = 1;
    const parameters: retention_module.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.1,
        .saturated_water_content_m3_per_m3 = 0.7,
        .alpha_per_m = 2,
        .n = 1.5,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    };
    // A single active soil layer forces local_layer==0 to be the (only,
    // therefore crossing) layer whenever water_table_mode triggers a search.
    grid.matrix_pore_capacity_m3[0] = 0.5;
    grid.matrix_air_volume_m3[0] = 0;
    grid.matrix_liquid_water_m3[0] = 0.5;
    grid.air_volume_m3[0] = 0;
    try state.refreshInternalWaterTable(&grid, &.{1}, &.{parameters}, &.{0.1}, &.{0.05}, &.{0.1}, 1e-3, 1e-6, &.{0}, &.{0}, &.{1});
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.internal_water_table_depth_m[0], 1e-12);
    // Litter water above retention capacity by 0.3 m3 over a 2 m2 cell area
    // ponds 0.15 m of standing water, which must push the table negative.
    try state.refreshInternalWaterTable(&grid, &.{1}, &.{parameters}, &.{0.1}, &.{0.05}, &.{0.1}, 1e-3, 1e-6, &.{0.5}, &.{0.2}, &.{2});
    try std.testing.expectApproxEqAbs(@as(f64, -0.15), state.internal_water_table_depth_m[0], 1e-12);
}

test "GRID-INV-003 a lateral boundary face carries the vertical cross-section, not plan area" {
    // The lateral boundary flux is assembled in `solver_residual.zig` as
    // `boundary_layer_volume_m3[layer] / directional_layer_width_m`. That is a
    // face area only if `directional_layer_width_m` is the cell extent along
    // the flow direction, so that dividing the layer volume `Wx*Wy*t` by it
    // leaves the vertical cross-section `t * W_transverse`.
    //
    // GRID-INV-003 recorded this as plan area `Wx*Wy` bound to lateral faces, a
    // 1000x overstatement at a 100 m cell with a 0.1 m layer. The identity is
    // pinned here so the property is checked rather than assumed, and so that
    // reintroducing plan area fails a test instead of silently rescaling every
    // lateral discharge. The cell is deliberately anisotropic (Wx=100, Wy=25):
    // under plan area the two axes would give the same face area, so an
    // isotropic fixture could not tell the correct area from the defect.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    var site = try site_module.parse(std.testing.allocator, @import("../../core/test_fixtures.zig").site_source, 1, 1);
    defer site.deinit();
    var topography = try @import("../../state/topography.zig").fromUnits(std.testing.allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1 }});
    defer topography.deinit();
    const x_width_m: f64 = 100;
    const y_width_m: f64 = 25;
    var terrain = try terrain_module.State.initMapped(std.testing.allocator, topography, &.{0}, &.{x_width_m}, &.{y_width_m}, 1, 1);
    defer terrain.deinit();
    var state = try State.initMapped(std.testing.allocator, &grid, &terrain, 1, 1, &.{x_width_m}, &.{y_width_m}, &.{site});
    defer state.deinit();

    const thickness_m: f64 = 0.1;
    const layer_volume_m3 = x_width_m * y_width_m * thickness_m;
    const plan_area_m2 = x_width_m * y_width_m;
    var checked: usize = 0;
    for (state.faces) |face| {
        if (face.is_lower_boundary) continue;
        const face_area_m2 = layer_volume_m3 / face.directional_layer_width_m;
        const transverse_m: f64 = switch (face.direction) {
            .east, .west => y_width_m,
            .north, .south => x_width_m,
            .lower => unreachable,
        };
        try std.testing.expectApproxEqRel(thickness_m * transverse_m, face_area_m2, 1e-12);
        // And it is emphatically not the horizontal footprint: 250 or 1000 m2
        // against 2500 m2 here, the ratio being thickness/width and therefore
        // layer-dependent, which is why the defect drifts as layers subside.
        try std.testing.expect(face_area_m2 < plan_area_m2);
        checked += 1;
    }
    // A single cell is the whole perimeter, so all four compass faces exist.
    try std.testing.expectEqual(@as(usize, 4), checked);
}

test "AIRFRAC-F4 the saturation verdict is independent of macropore capacity" {
    // Defect 1 of PR-AIRFRAC-RECONCILE-001: the threshold test divided total
    // (matrix + macropore) air volume by the *matrix* bulk volume, while the
    // pore accounting on the line above included macropores. Mismatched
    // denominators make the effective threshold drift with macroporosity, so
    // two layers with identical matrix wetness could land on opposite sides of
    // the water table purely because one had more macropore space.
    //
    // This holds matrix air volume fixed at exactly the shipped Ottawa
    // threshold and sweeps macropore capacity (and the air it contributes)
    // across four orders of magnitude. The verdict must not move.
    // Mutation check: restoring `grid.air_volume_m3[...]` as the numerator
    // fails this test at the first non-zero macropore entry.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    const parameters: retention_module.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.1,
        .saturated_water_content_m3_per_m3 = 0.7,
        .alpha_per_m = 2,
        .n = 1.5,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    };
    const threshold = 1e-3;
    var reference: f64 = 0;
    for ([_]f64{ 0, 1e-3, 1e-2, 1e-1, 1 }, 0..) |macropore_capacity_m3, case| {
        var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
        defer grid.deinit();
        var site = try site_module.parse(std.testing.allocator, @import("../../core/test_fixtures.zig").site_source, 1, 1);
        defer site.deinit();
        var topography = try @import("../../state/topography.zig").fromUnits(std.testing.allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1 }});
        defer topography.deinit();
        var terrain = try terrain_module.State.initMapped(std.testing.allocator, topography, &.{0}, &.{1}, &.{1}, 1, 1);
        defer terrain.deinit();
        var state = try State.initMapped(std.testing.allocator, &grid, &terrain, 1, 1, &.{1}, &.{1}, &.{site});
        defer state.deinit();
        state.water_table_mode[0] = 1;
        for (0..2) |layer| {
            grid.matrix_pore_capacity_m3[layer] = 0.5;
            grid.macropore_pore_capacity_m3[layer] = macropore_capacity_m3;
            // Matrix air sits below the threshold in the upper layer, so
            // the upper layer is the deciding one; the lower layer is fully
            // saturated in the matrix.
            grid.matrix_air_volume_m3[layer] = if (layer == 0) 0.5 * threshold else 0;
            grid.macropore_air_volume_m3[layer] = macropore_capacity_m3;
            grid.matrix_liquid_water_m3[layer] = 0.5 - grid.matrix_air_volume_m3[layer];
            grid.air_volume_m3[layer] = grid.matrix_air_volume_m3[layer] + grid.macropore_air_volume_m3[layer];
        }
        try state.refreshInternalWaterTable(&grid, &.{ 1, 1 }, &.{ parameters, parameters }, &.{ 0.1, 0.1 }, &.{ 0.05, 0.15 }, &.{ 0.1, 0.2 }, threshold, 1e-6, &.{0}, &.{0}, &.{1});
        if (case == 0) {
            reference = state.internal_water_table_depth_m[0];
        } else {
            try std.testing.expectEqual(reference, state.internal_water_table_depth_m[0]);
        }
    }
}

test "AIRFRAC-F2 no layer is both below the internal water table and an open gas face" {
    // The contradiction stated as a test. Before PR-AIRFRAC-RECONCILE-001 the
    // shipped deck ran the water side at 1e-3 and the gas side at 1e-12, so a
    // layer whose air fraction lay strictly between them was diagnosed as
    // saturated (attracting the `-0.0098 * max(0, z - internal_depth)` back
    // pressure that shuts off lateral discharge in `boundary.zig`) while
    // `face_assembly.zig` still opened its gas faces. Aqueous and gaseous
    // species then partitioned across one face under opposite saturation
    // states, with both budgets closing individually.
    //
    // With one owner, no such air fraction exists: the water side's "below the
    // table" test and the gas side's "face is open" test are exact complements
    // about the same number. This sweeps the whole formerly-contradictory
    // interval and asserts the two verdicts never both fire.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    const parameters: retention_module.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.1,
        .saturated_water_content_m3_per_m3 = 0.7,
        .alpha_per_m = 2,
        .n = 1.5,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    };
    const threshold = 1e-3;
    for ([_]f64{ 1e-12, 1e-10, 1e-8, 1e-6, 1e-4, 5e-4, 9.99e-4 }) |air_fraction| {
        var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
        defer grid.deinit();
        var site = try site_module.parse(std.testing.allocator, @import("../../core/test_fixtures.zig").site_source, 1, 1);
        defer site.deinit();
        var topography = try @import("../../state/topography.zig").fromUnits(std.testing.allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1 }});
        defer topography.deinit();
        var terrain = try terrain_module.State.initMapped(std.testing.allocator, topography, &.{0}, &.{1}, &.{1}, 1, 1);
        defer terrain.deinit();
        var state = try State.initMapped(std.testing.allocator, &grid, &terrain, 1, 1, &.{1}, &.{1}, &.{site});
        defer state.deinit();
        state.water_table_mode[0] = 1;
        for (0..2) |layer| {
            grid.matrix_pore_capacity_m3[layer] = 0.5;
            grid.macropore_pore_capacity_m3[layer] = 0;
            grid.matrix_air_volume_m3[layer] = air_fraction;
            grid.macropore_air_volume_m3[layer] = 0;
            grid.matrix_liquid_water_m3[layer] = 0.5 - air_fraction;
            grid.air_volume_m3[layer] = air_fraction;
        }
        try state.refreshInternalWaterTable(&grid, &.{ 1, 1 }, &.{ parameters, parameters }, &.{ 0.1, 0.1 }, &.{ 0.05, 0.15 }, &.{ 0.1, 0.2 }, threshold, 1e-6, &.{0}, &.{0}, &.{1});
        // Water side: the top layer is at or below the internal water table.
        const below_water_table = state.internal_water_table_depth_m[0] <= 0.05;
        // Gas side, exactly as `face_assembly.appendFace` tests it, using the
        // one reconciled threshold that now reaches both consumers.
        const gas_face_open = air_fraction > threshold;
        try std.testing.expect(!(below_water_table and gas_face_open));
        try std.testing.expect(below_water_table);
    }
}
