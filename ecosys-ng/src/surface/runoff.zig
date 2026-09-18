const std = @import("std");
const terrain_module = @import("../state/terrain_hydrology.zig");
const spatial_grid = @import("../state/spatial_grid.zig");
const lateral_store = @import("../state/tile_lateral_contribution_store.zig");

pub const Parameters = struct {
    ground_surface_retention_m3_per_m2: f64,
    runoff_roughness_h_per_m_one_third: f64,
    /// Per-step ceiling on the water depth that may enter the Manning solve,
    /// as a depth rather than a volume. Legacy `watsub.f:3841` writes the same
    /// constant as `AMIN1(1.0E-03, .)` against a volume, but its sibling
    /// branch at `:3844` compares it against the raw depth `DTBLX-CDPTH`, and
    /// the quantity it is subtracted from, `VOLWG`, is built at
    /// `hour1.f:2373-2375` as a depth expression times `AREA(3,NU,NY,NX)`. The
    /// two uses agree only where `AREA == 1`, which holds for every legacy
    /// deck in this repository, so the constant's intended unit is a depth and
    /// the absolute-volume reading is an artifact of the unit-area grid.
    maximum_hydraulic_depth_m: f64 = 1.0e-3,
    manning_time_conversion_s_per_h: f64 = 3.6e3,
    negligible_water_m3: f64 = 1.0e-12,
    /// Converts the authoritative surface ice WE carrier to physical volume
    /// for retention, depth, and elevation geometry.
    ice_density_megagrams_per_m3: f64 = 0.917,
};

pub const BoundaryFractions = struct {
    north: []const f64,
    east: []const f64,
    south: []const f64,
    west: []const f64,
};

pub const SurfaceBoundary = struct {
    soil_layer_count: usize,
    bulk_density_megagrams_per_m3: []const f64,
    layer_bottom_depth_m: []const f64,
    layer_thickness_m: []const f64,
    natural_water_table_depth_m: []const f64,
};

/// Authoritative surface enthalpy carriers used by WATSUB `HQR` runoff.
/// The temperature and heat capacity are updated atomically with liquid water;
/// every directional heat flux is evaluated from the immutable donor
/// temperature that generated the runoff snapshot.
pub const ThermalState = struct {
    temperature_k: []f64,
    heat_capacity_megajoules_per_k: []f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    /// HOUR1 `ZM`, refreshed from the accepted disturbed surface each hour.
    surface_roughness_m: []f64,
    excess_surface_water_m3: []f64,
    excess_surface_ice_m3: []f64,
    runoff_velocity_m_per_s: []f64,
    total_runoff_m3_per_step: []f64,
    east_runoff_m3_per_step: []f64,
    west_runoff_m3_per_step: []f64,
    south_runoff_m3_per_step: []f64,
    north_runoff_m3_per_step: []f64,
    water_change_m3: []f64,
    exported_water_m3: []f64,
    east_runoff_heat_megajoules_per_step: []f64,
    west_runoff_heat_megajoules_per_step: []f64,
    south_runoff_heat_megajoules_per_step: []f64,
    north_runoff_heat_megajoules_per_step: []f64,
    incoming_runoff_heat_megajoules_per_step: []f64,
    outgoing_runoff_heat_megajoules_per_step: []f64,
    heat_change_megajoules: []f64,
    exported_heat_megajoules: []f64,

    /// Releases the successfully allocated `[]f64` prefix from `init` in
    /// field order without replicating the reflected cleanup loop at every
    /// allocation failure edge.
    noinline fn deinitAllocatedPrefix(self: *State, allocated_count: usize) void {
        var remaining = allocated_count;
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                if (remaining == 0) return;
                self.allocator.free(@field(self, field.name));
                remaining -= 1;
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, initial_surface_roughness_m: f64) !State {
        if (cell_count == 0) return error.ZeroSurfaceRunoffCellCount;
        if (!std.math.isFinite(initial_surface_roughness_m) or
            initial_surface_roughness_m <= 0)
            return error.InvalidSurfaceRunoffRoughness;
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        var allocated: usize = 0;
        errdefer result.deinitAllocatedPrefix(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, cell_count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };
        @memset(result.surface_roughness_m, initial_surface_roughness_m);
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

test "surface runoff state releases every partial allocation prefix" {
    const allocation_count = comptime count: {
        var count: usize = 0;
        for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) count += 1;
        }
        break :count count;
    };

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            State.init(failing.allocator(), 2, 0.01),
        );
    }
}

/// WATSUB `XVOLW/XVOLI`, Manning `QRM/QRV`, and directional `QRMN`.
/// Every face is generated from the converged hourly surface state and then
/// reduced once; no full ecosystem sub-hour cycle is repeated.
pub fn route(
    state: *State,
    columns: usize,
    rows: usize,
    terrain: *const terrain_module.State,
    cell_area_m2: []const f64,
    surface_water_m3: []f64,
    surface_ice_m3: []const f64,
    litter_retention_capacity_m3: []const f64,
    lateral_connection_mode_by_cell: []const u8,
    boundary_fractions: BoundaryFractions,
    parameters: Parameters,
) !void {
    try calculateFluxesWithSurfaceBoundary(
        state,
        columns,
        rows,
        terrain,
        cell_area_m2,
        surface_water_m3,
        surface_ice_m3,
        litter_retention_capacity_m3,
        lateral_connection_mode_by_cell,
        boundary_fractions,
        parameters,
        null,
    );
    try state_updateWaterChanges(surface_water_m3, state.water_change_m3);
}

/// Complete WATSUB runoff path, including the `BKDS(NU)<=0` ponded-cell
/// hydraulic-depth branch. The water-table geometry selects the Manning
/// depth; the resident surface-water owner remains the conserved donor.
pub fn routeWithSurfaceBoundary(
    state: *State,
    columns: usize,
    rows: usize,
    terrain: *const terrain_module.State,
    cell_area_m2: []const f64,
    surface_water_m3: []f64,
    surface_ice_m3: []const f64,
    litter_retention_capacity_m3: []const f64,
    lateral_connection_mode_by_cell: []const u8,
    boundary_fractions: BoundaryFractions,
    parameters: Parameters,
    surface_boundary: SurfaceBoundary,
    thermal: ThermalState,
) !void {
    try calculateFluxesWithSurfaceBoundary(
        state,
        columns,
        rows,
        terrain,
        cell_area_m2,
        surface_water_m3,
        surface_ice_m3,
        litter_retention_capacity_m3,
        lateral_connection_mode_by_cell,
        boundary_fractions,
        parameters,
        surface_boundary,
    );
    try calculateHeatChanges(state, columns, rows, thermal);
    try state_updateWaterHeatChanges(
        surface_water_m3,
        state.water_change_m3,
        thermal,
        state.heat_change_megajoules,
    );
}

/// Calculates the immutable-source runoff snapshot and signed changes without
/// mutating surface water. This phase can be followed either by the resident
/// state_update or by the two-pass Morton contribution transaction.
pub fn calculateFluxes(
    state: *State,
    columns: usize,
    rows: usize,
    terrain: *const terrain_module.State,
    cell_area_m2: []const f64,
    surface_water_m3: []f64,
    surface_ice_m3: []const f64,
    litter_retention_capacity_m3: []const f64,
    lateral_connection_mode_by_cell: []const u8,
    boundary_fractions: BoundaryFractions,
    parameters: Parameters,
) !void {
    return calculateFluxesWithSurfaceBoundary(
        state,
        columns,
        rows,
        terrain,
        cell_area_m2,
        surface_water_m3,
        surface_ice_m3,
        litter_retention_capacity_m3,
        lateral_connection_mode_by_cell,
        boundary_fractions,
        parameters,
        null,
    );
}

pub fn calculateFluxesWithSurfaceBoundary(
    state: *State,
    columns: usize,
    rows: usize,
    terrain: *const terrain_module.State,
    cell_area_m2: []const f64,
    surface_water_m3: []f64,
    surface_ice_m3: []const f64,
    litter_retention_capacity_m3: []const f64,
    lateral_connection_mode_by_cell: []const u8,
    boundary_fractions: BoundaryFractions,
    parameters: Parameters,
    surface_boundary: ?SurfaceBoundary,
) !void {
    const count = try std.math.mul(usize, columns, rows);
    if (count != state.cell_count or terrain.columns != columns or terrain.rows != rows or cell_area_m2.len != count or surface_water_m3.len != count or surface_ice_m3.len != count or litter_retention_capacity_m3.len != count or lateral_connection_mode_by_cell.len != count or boundary_fractions.north.len != count or boundary_fractions.east.len != count or boundary_fractions.south.len != count or boundary_fractions.west.len != count) return error.SurfaceRunoffDimensionMismatch;
    for (lateral_connection_mode_by_cell) |mode| if (mode != 1 and mode != 3) return error.InvalidLateralConnectionMode;
    for (state.surface_roughness_m) |roughness_m|
        if (!std.math.isFinite(roughness_m) or roughness_m <= 0)
            return error.InvalidSurfaceRunoffRoughness;
    if (surface_boundary) |boundary| {
        const soil_cell_count = try std.math.mul(usize, count, boundary.soil_layer_count);
        if (boundary.soil_layer_count == 0 or
            boundary.bulk_density_megagrams_per_m3.len != soil_cell_count or
            boundary.layer_bottom_depth_m.len != soil_cell_count or
            boundary.layer_thickness_m.len != soil_cell_count or
            boundary.natural_water_table_depth_m.len != count)
            return error.SurfaceRunoffDimensionMismatch;
    }
    try validateParameters(parameters, boundary_fractions);
    inline for (.{ state.excess_surface_water_m3, state.excess_surface_ice_m3, state.runoff_velocity_m_per_s, state.total_runoff_m3_per_step, state.east_runoff_m3_per_step, state.west_runoff_m3_per_step, state.south_runoff_m3_per_step, state.north_runoff_m3_per_step, state.water_change_m3, state.exported_water_m3, state.east_runoff_heat_megajoules_per_step, state.west_runoff_heat_megajoules_per_step, state.south_runoff_heat_megajoules_per_step, state.north_runoff_heat_megajoules_per_step, state.incoming_runoff_heat_megajoules_per_step, state.outgoing_runoff_heat_megajoules_per_step, state.heat_change_megajoules, state.exported_heat_megajoules }) |values| @memset(values, 0);

    for (0..count) |cell| {
        const water = surface_water_m3[cell];
        const ice = surface_ice_m3[cell];
        const retention = litter_retention_capacity_m3[cell];
        const area = cell_area_m2[cell];
        inline for (.{ water, ice, retention, area }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceRunoffState;
        if (area <= 0) return error.InvalidSurfaceRunoffState;
        const physical_ice = ice / parameters.ice_density_megagrams_per_m3;
        const total = water + physical_ice;
        if (total <= parameters.negligible_water_m3) continue;
        const retained_fraction = @min(1, retention / total);
        const retained_water = water * retained_fraction;
        const retained_ice = physical_ice * retained_fraction;
        state.excess_surface_water_m3[cell] = @max(0, water - retained_water);
        state.excess_surface_ice_m3[cell] = @max(0, ice - retained_ice);
        const excess_total = state.excess_surface_water_m3[cell] + state.excess_surface_ice_m3[cell];
        const ground_retention = parameters.ground_surface_retention_m3_per_m2 * area;
        if (state.excess_surface_water_m3[cell] <= parameters.negligible_water_m3) continue;
        const hydraulic_volume_m3 = if (surface_boundary) |boundary| blk: {
            const top = cell * boundary.soil_layer_count;
            const bulk_density = boundary.bulk_density_megagrams_per_m3[top];
            const surface_depth = boundary.layer_bottom_depth_m[top] - boundary.layer_thickness_m[top];
            const water_table_depth = boundary.natural_water_table_depth_m[cell];
            inline for (.{ bulk_density, surface_depth, water_table_depth }) |value|
                if (!std.math.isFinite(value)) return error.InvalidSurfaceRunoffState;
            if (bulk_density < 0) return error.InvalidSurfaceRunoffState;
            if (bulk_density == 0 and surface_depth <= water_table_depth)
                break :blk @min(parameters.maximum_hydraulic_depth_m, water_table_depth - surface_depth) * area;
            if (excess_total <= ground_retention) continue;
            break :blk @min(
                parameters.maximum_hydraulic_depth_m * area,
                (excess_total - ground_retention) * state.excess_surface_water_m3[cell] / excess_total,
            );
        } else blk: {
            if (excess_total <= ground_retention) continue;
            break :blk @min(
                parameters.maximum_hydraulic_depth_m * area,
                (excess_total - ground_retention) * state.excess_surface_water_m3[cell] / excess_total,
            );
        };
        const hydraulic_depth_m = hydraulic_volume_m3 / area;
        const velocity_m_per_s = std.math.pow(f64, hydraulic_depth_m, 0.67) *
            @sqrt(terrain.slope_m_per_m[cell]) / state.surface_roughness_m[cell];
        state.runoff_velocity_m_per_s[cell] = velocity_m_per_s;
        state.total_runoff_m3_per_step[cell] = @min(hydraulic_volume_m3, velocity_m_per_s * hydraulic_depth_m * terrain.flow_width_m[cell] * parameters.manning_time_conversion_s_per_h);
    }

    for (0..rows) |row| for (0..columns) |column| {
        const source = row * columns + column;
        const available = state.total_runoff_m3_per_step[source];
        if (available <= parameters.negligible_water_m3) continue;
        const source_surface_m = terrain.current_surface_elevation_m[source] +
            (state.excess_surface_water_m3[source] + state.excess_surface_ice_m3[source]) / cell_area_m2[source];
        if (terrain.runoff_to_east[source]) state.east_runoff_m3_per_step[source] = try directionalFlux(source, if (column + 1 < columns) source + 1 else null, source_surface_m, available, terrain.east_west_runoff_fraction[source], boundary_fractions.east[source], lateral_connection_mode_by_cell, terrain, cell_area_m2, state);
        if (terrain.runoff_to_west[source]) state.west_runoff_m3_per_step[source] = try directionalFlux(source, if (column > 0) source - 1 else null, source_surface_m, available, terrain.east_west_runoff_fraction[source], boundary_fractions.west[source], lateral_connection_mode_by_cell, terrain, cell_area_m2, state);
        if (terrain.runoff_to_south[source]) state.south_runoff_m3_per_step[source] = try directionalFlux(source, if (row + 1 < rows) source + columns else null, source_surface_m, available, terrain.north_south_runoff_fraction[source], boundary_fractions.south[source], lateral_connection_mode_by_cell, terrain, cell_area_m2, state);
        if (terrain.runoff_to_north[source]) state.north_runoff_m3_per_step[source] = try directionalFlux(source, if (row > 0) source - columns else null, source_surface_m, available, terrain.north_south_runoff_fraction[source], boundary_fractions.north[source], lateral_connection_mode_by_cell, terrain, cell_area_m2, state);
    };

    for (0..rows) |row| for (0..columns) |column| {
        const source = row * columns + column;
        const fluxes = [_]f64{ state.east_runoff_m3_per_step[source], state.west_runoff_m3_per_step[source], state.south_runoff_m3_per_step[source], state.north_runoff_m3_per_step[source] };
        const outgoing = fluxes[0] + fluxes[1] + fluxes[2] + fluxes[3];
        if (outgoing > surface_water_m3[source] + 64 * std.math.floatEps(f64) * @max(1, surface_water_m3[source])) return error.SurfaceRunoffExceedsAvailableWater;
        state.water_change_m3[source] -= outgoing;
        if (column + 1 < columns) state.water_change_m3[source + 1] += fluxes[0] else state.exported_water_m3[source] += fluxes[0];
        if (column > 0) state.water_change_m3[source - 1] += fluxes[1] else state.exported_water_m3[source] += fluxes[1];
        if (row + 1 < rows) state.water_change_m3[source + columns] += fluxes[2] else state.exported_water_m3[source] += fluxes[2];
        if (row > 0) state.water_change_m3[source - columns] += fluxes[3] else state.exported_water_m3[source] += fluxes[3];
    };
    try validateWaterChanges(surface_water_m3, state.water_change_m3);
}

/// WATSUB `HQR1=4.19*TK1(0,source)*QR1`, generalized to the runtime liquid
/// heat capacity used by the authoritative surface enthalpy census. Water
/// directions were calculated from an immutable source snapshot above; this
/// pass likewise reads every donor temperature before any recipient is mixed.
fn calculateHeatChanges(
    state: *State,
    columns: usize,
    rows: usize,
    thermal: ThermalState,
) !void {
    const count = try std.math.mul(usize, columns, rows);
    if (count != state.cell_count or
        thermal.temperature_k.len != count or
        thermal.heat_capacity_megajoules_per_k.len != count)
        return error.SurfaceRunoffThermalDimensionMismatch;
    const liquid_capacity = thermal.liquid_water_heat_capacity_megajoules_per_m3_k;
    if (!std.math.isFinite(liquid_capacity) or liquid_capacity <= 0)
        return error.InvalidSurfaceRunoffHeatCapacity;
    for (thermal.temperature_k, thermal.heat_capacity_megajoules_per_k) |temperature, capacity| {
        if (!std.math.isFinite(temperature) or temperature <= 0 or
            !std.math.isFinite(capacity) or capacity <= 0)
            return error.InvalidSurfaceRunoffThermalState;
    }

    for (0..rows) |row| for (0..columns) |column| {
        const source = row * columns + column;
        const temperature = thermal.temperature_k[source];
        const water_fluxes = [_]f64{
            state.east_runoff_m3_per_step[source],
            state.west_runoff_m3_per_step[source],
            state.south_runoff_m3_per_step[source],
            state.north_runoff_m3_per_step[source],
        };
        var heat_fluxes = [_]f64{0} ** 4;
        for (water_fluxes, &heat_fluxes) |water_flux, *heat_flux| {
            heat_flux.* = liquid_capacity * temperature * water_flux;
            if (!std.math.isFinite(heat_flux.*) or heat_flux.* < 0)
                return error.InvalidSurfaceRunoffHeatFlux;
        }
        state.east_runoff_heat_megajoules_per_step[source] = heat_fluxes[0];
        state.west_runoff_heat_megajoules_per_step[source] = heat_fluxes[1];
        state.south_runoff_heat_megajoules_per_step[source] = heat_fluxes[2];
        state.north_runoff_heat_megajoules_per_step[source] = heat_fluxes[3];
        const outgoing_heat = heat_fluxes[0] + heat_fluxes[1] + heat_fluxes[2] + heat_fluxes[3];
        if (!std.math.isFinite(outgoing_heat)) return error.InvalidSurfaceRunoffHeatFlux;
        state.outgoing_runoff_heat_megajoules_per_step[source] = outgoing_heat;
        state.heat_change_megajoules[source] -= outgoing_heat;

        const destinations = [_]?usize{
            if (column + 1 < columns) source + 1 else null,
            if (column > 0) source - 1 else null,
            if (row + 1 < rows) source + columns else null,
            if (row > 0) source - columns else null,
        };
        for (heat_fluxes, destinations) |heat_flux, destination| {
            if (destination) |target| {
                state.incoming_runoff_heat_megajoules_per_step[target] += heat_flux;
                state.heat_change_megajoules[target] += heat_flux;
                if (!std.math.isFinite(state.incoming_runoff_heat_megajoules_per_step[target]) or
                    !std.math.isFinite(state.heat_change_megajoules[target]))
                    return error.InvalidSurfaceRunoffHeatFlux;
            } else {
                state.exported_heat_megajoules[source] += heat_flux;
                if (!std.math.isFinite(state.exported_heat_megajoules[source]))
                    return error.InvalidSurfaceRunoffHeatFlux;
            }
        }
    };
}

/// Applies water, liquid-water heat capacity, and enthalpy as one validated
/// transaction. A donor that only loses runoff remains at its original
/// temperature; a recipient is mixed from its old enthalpy plus the exact
/// donor-carried `HQR` input.
pub fn state_updateWaterHeatChanges(
    surface_water_m3: []f64,
    water_change_m3: []const f64,
    thermal: ThermalState,
    heat_change_megajoules: []const f64,
) !void {
    try validateWaterHeatChanges(
        surface_water_m3,
        water_change_m3,
        thermal,
        heat_change_megajoules,
    );
    const liquid_capacity = thermal.liquid_water_heat_capacity_megajoules_per_m3_k;
    for (surface_water_m3, water_change_m3, thermal.temperature_k, thermal.heat_capacity_megajoules_per_k, heat_change_megajoules) |*water, water_change, *temperature, *capacity, heat_change| {
        const old_enthalpy = capacity.* * temperature.*;
        capacity.* += liquid_capacity * water_change;
        temperature.* = (old_enthalpy + heat_change) / capacity.*;
        water.* += water_change;
    }
}

fn validateWaterHeatChanges(
    surface_water_m3: []const f64,
    water_change_m3: []const f64,
    thermal: ThermalState,
    heat_change_megajoules: []const f64,
) !void {
    if (surface_water_m3.len != water_change_m3.len or
        thermal.temperature_k.len != surface_water_m3.len or
        thermal.heat_capacity_megajoules_per_k.len != surface_water_m3.len or
        heat_change_megajoules.len != surface_water_m3.len)
        return error.SurfaceRunoffThermalDimensionMismatch;
    const liquid_capacity = thermal.liquid_water_heat_capacity_megajoules_per_m3_k;
    if (!std.math.isFinite(liquid_capacity) or liquid_capacity <= 0)
        return error.InvalidSurfaceRunoffHeatCapacity;
    for (surface_water_m3, water_change_m3, thermal.temperature_k, thermal.heat_capacity_megajoules_per_k, heat_change_megajoules) |water, water_change, temperature, capacity, heat_change| {
        const next_water = water + water_change;
        const next_capacity = capacity + liquid_capacity * water_change;
        const next_enthalpy = capacity * temperature + heat_change;
        const next_temperature = next_enthalpy / next_capacity;
        inline for (.{ water, water_change, temperature, capacity, heat_change, next_water, next_capacity, next_enthalpy, next_temperature }) |value|
            if (!std.math.isFinite(value)) return error.InvalidSurfaceRunoffThermalCandidate;
        if (water < 0 or next_water < 0 or temperature <= 0 or capacity <= 0 or
            next_capacity <= 0 or next_enthalpy <= 0 or next_temperature <= 0)
            return error.InvalidSurfaceRunoffThermalCandidate;
    }
}

pub fn state_updateWaterChanges(
    surface_water_m3: []f64,
    water_change_m3: []const f64,
) !void {
    try validateWaterChanges(surface_water_m3, water_change_m3);
    for (surface_water_m3, water_change_m3) |*water, change|
        water.* += change;
}

fn validateWaterChanges(
    surface_water_m3: []const f64,
    water_change_m3: []const f64,
) !void {
    if (surface_water_m3.len != water_change_m3.len)
        return error.SurfaceRunoffDimensionMismatch;
    for (surface_water_m3, water_change_m3) |water, change|
        if (!std.math.isFinite(water) or !std.math.isFinite(change) or
            water + change < 0)
            return error.InvalidSurfaceRunoffCandidate;
}

pub const lateral_component_count: usize = 2;
pub const water_change_component: usize = 0;
pub const boundary_export_component: usize = 1;

/// Converts the immutable directional runoff snapshot for one source tile
/// into signed endpoint records. Each source cell belongs to exactly one
/// tile, so outgoing water is emitted once; neighboring receipts are carried
/// by the durable contribution sidecar until the destination tile state_updates.
pub fn appendOwnedTileContributions(
    allocator: std.mem.Allocator,
    plan: spatial_grid.TilePlan,
    tile_index: usize,
    state: *const State,
    contributions: *std.ArrayList(lateral_store.Contribution),
) !void {
    if (state.cell_count != plan.lat_count * plan.lon_count)
        return error.SurfaceRunoffDimensionMismatch;
    const owned_cells = try plan.ownedCells(tile_index);
    for (owned_cells) |source| {
        const row = source / plan.lon_count;
        const column = source % plan.lon_count;
        const fluxes = [_]f64{
            state.east_runoff_m3_per_step[source],
            state.west_runoff_m3_per_step[source],
            state.south_runoff_m3_per_step[source],
            state.north_runoff_m3_per_step[source],
        };
        var outgoing_m3: f64 = 0;
        for (fluxes) |flux_m3| {
            if (!std.math.isFinite(flux_m3) or flux_m3 < 0)
                return error.InvalidSurfaceRunoffFlux;
            outgoing_m3 += flux_m3;
        }
        if (outgoing_m3 > 0) try contributions.append(allocator, .{
            .target_cell = source,
            .component = water_change_component,
            .delta = -outgoing_m3,
        });
        const destinations = [_]?usize{
            if (column + 1 < plan.lon_count) source + 1 else null,
            if (column > 0) source - 1 else null,
            if (row + 1 < plan.lat_count)
                source + plan.lon_count
            else
                null,
            if (row > 0) source - plan.lon_count else null,
        };
        for (fluxes, destinations) |flux_m3, destination| {
            if (flux_m3 == 0) continue;
            try contributions.append(allocator, .{
                .target_cell = destination orelse source,
                .component = if (destination == null)
                    boundary_export_component
                else
                    water_change_component,
                .delta = flux_m3,
            });
        }
    }
}

/// StateUpdates only the destination tile's gathered runoff components.
pub fn state_updateOwnedTileContributions(
    plan: spatial_grid.TilePlan,
    tile_index: usize,
    state: *State,
    surface_water_m3: []f64,
    gathered: []const f64,
) !void {
    if (surface_water_m3.len != state.cell_count or
        gathered.len != state.cell_count * lateral_component_count)
        return error.SurfaceRunoffDimensionMismatch;
    const owned_cells = try plan.ownedCells(tile_index);
    for (owned_cells) |cell| {
        const water_change_m3 =
            gathered[cell * lateral_component_count + water_change_component];
        const exported_water_m3 =
            gathered[cell * lateral_component_count + boundary_export_component];
        if (!std.math.isFinite(water_change_m3) or
            !std.math.isFinite(exported_water_m3) or
            exported_water_m3 < 0 or
            surface_water_m3[cell] + water_change_m3 < 0)
            return error.InvalidSurfaceRunoffCandidate;
    }
    for (owned_cells) |cell| {
        const water_change_m3 =
            gathered[cell * lateral_component_count + water_change_component];
        const exported_water_m3 =
            gathered[cell * lateral_component_count + boundary_export_component];
        state.water_change_m3[cell] = water_change_m3;
        state.exported_water_m3[cell] = exported_water_m3;
        surface_water_m3[cell] += water_change_m3;
    }
}

fn directionalFlux(source: usize, destination: ?usize, source_surface_m: f64, available_m3: f64, direction_fraction: f64, boundary_fraction: f64, lateral_connection_mode_by_cell: []const u8, terrain: *const terrain_module.State, cell_area_m2: []const f64, state: *const State) !f64 {
    if (destination) |target| {
        if (lateral_connection_mode_by_cell[source] != 1 or
            lateral_connection_mode_by_cell[target] != 1) return 0;
        const destination_surface_m = terrain.current_surface_elevation_m[target] +
            (state.excess_surface_water_m3[target] + state.excess_surface_ice_m3[target]) / cell_area_m2[target];
        if (source_surface_m <= destination_surface_m) return 0;
        const equilibrium_m3 = @max(0, 0.5 * (source_surface_m - destination_surface_m) * cell_area_m2[source] * cell_area_m2[target] / (cell_area_m2[source] + cell_area_m2[target]));
        return @min(equilibrium_m3, available_m3) * direction_fraction;
    }
    return available_m3 * direction_fraction * boundary_fraction;
}

fn validateParameters(parameters: Parameters, boundaries: BoundaryFractions) !void {
    inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name)) or @field(parameters, field.name) < 0) return error.InvalidSurfaceRunoffParameter;
    if (parameters.runoff_roughness_h_per_m_one_third <= 0 or parameters.maximum_hydraulic_depth_m <= 0 or parameters.manning_time_conversion_s_per_h <= 0 or parameters.ice_density_megagrams_per_m3 <= 0 or parameters.ice_density_megagrams_per_m3 > 1) return error.InvalidSurfaceRunoffParameter;
    inline for (.{ boundaries.north, boundaries.east, boundaries.south, boundaries.west }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSurfaceRunoffBoundary;
}

test "internal Manning runoff conserves water on a runtime grid" {
    const topography = @import("../state/topography.zig");
    var units = [_]topography.LandscapeUnit{.{ .west_column = 1, .north_row = 1, .east_column = 2, .south_row = 1, .compass_aspect_degrees = 90, .geometric_aspect_degrees = 90, .slope_degrees = 5, .initial_snowpack_depth_m = 0, .soil_profile_file = "soil" }};
    var terrain = try terrain_module.State.initMapped(std.testing.allocator, .{ .allocator = std.testing.allocator, .units = &units }, &.{ 0, 0 }, &.{ 1, 1 }, &.{ 1, 1 }, 2, 1);
    defer terrain.deinit();
    // Ensure an unambiguous eastward surface gradient for this carrier test.
    terrain.runoff_to_east[0] = true;
    terrain.runoff_to_west[0] = false;
    terrain.east_west_runoff_fraction[0] = 1;
    terrain.north_south_runoff_fraction[0] = 0;
    try terrain.bindInitialSurfaceElevations(&.{ 1, 0 });
    var state = try State.init(std.testing.allocator, 2, 0.1);
    defer state.deinit();
    var water = [_]f64{ 0.02, 0.01 };
    const initial = water[0] + water[1];
    try route(&state, 2, 1, &terrain, &.{ 1, 1 }, &water, &.{ 0, 0 }, &.{ 0.005, 0.005 }, &.{ 1, 1 }, .{ .north = &.{ 0, 0 }, .east = &.{ 0, 0 }, .south = &.{ 0, 0 }, .west = &.{ 0, 0 } }, .{ .ground_surface_retention_m3_per_m2 = 0, .runoff_roughness_h_per_m_one_third = 0.1 });
    try std.testing.expect(state.east_runoff_m3_per_step[0] > 0);
    try std.testing.expectApproxEqAbs(initial, water[0] + water[1], 1e-15);
    water = .{ 0.02, 0.01 };
    try route(&state, 2, 1, &terrain, &.{ 1, 1 }, &water, &.{ 0, 0 }, &.{ 0.005, 0.005 }, &.{ 3, 1 }, .{ .north = &.{ 0, 0 }, .east = &.{ 0, 0 }, .south = &.{ 0, 0 }, .west = &.{ 0, 0 } }, .{ .ground_surface_retention_m3_per_m2 = 0, .runoff_roughness_h_per_m_one_third = 0.1 });
    try std.testing.expectEqual(@as(f64, 0), state.east_runoff_m3_per_step[0]);
    try std.testing.expectEqual(@as(f64, 0.02), water[0]);
    try std.testing.expectEqual(@as(f64, 0.01), water[1]);
}

test "equal-temperature internal runoff carries exact HQR and conserves local enthalpy" {
    const topography = @import("../state/topography.zig");
    var units = [_]topography.LandscapeUnit{.{ .west_column = 1, .north_row = 1, .east_column = 2, .south_row = 1, .compass_aspect_degrees = 90, .geometric_aspect_degrees = 90, .slope_degrees = 5, .initial_snowpack_depth_m = 0, .soil_profile_file = "soil" }};
    var terrain = try terrain_module.State.initMapped(std.testing.allocator, .{ .allocator = std.testing.allocator, .units = &units }, &.{ 0, 0 }, &.{ 1, 1 }, &.{ 1, 1 }, 2, 1);
    defer terrain.deinit();
    terrain.runoff_to_east[0] = true;
    terrain.runoff_to_west[0] = false;
    terrain.east_west_runoff_fraction[0] = 1;
    terrain.north_south_runoff_fraction[0] = 0;
    try terrain.bindInitialSurfaceElevations(&.{ 1, 0 });
    var state = try State.init(std.testing.allocator, 2, 0.1);
    defer state.deinit();
    var water = [_]f64{ 0.02, 0.01 };
    var temperature = [_]f64{ 280, 280 };
    var capacity = [_]f64{ 1 + 4.19 * water[0], 1 + 4.19 * water[1] };
    const initial_enthalpy = capacity[0] * temperature[0] + capacity[1] * temperature[1];
    try routeWithSurfaceBoundary(
        &state,
        2,
        1,
        &terrain,
        &.{ 1, 1 },
        &water,
        &.{ 0, 0 },
        &.{ 0.005, 0.005 },
        &.{ 1, 1 },
        .{ .north = &.{ 0, 0 }, .east = &.{ 0, 0 }, .south = &.{ 0, 0 }, .west = &.{ 0, 0 } },
        .{ .ground_surface_retention_m3_per_m2 = 0, .runoff_roughness_h_per_m_one_third = 0.1 },
        .{ .soil_layer_count = 1, .bulk_density_megagrams_per_m3 = &.{ 1, 1 }, .layer_bottom_depth_m = &.{ 0.1, 0.1 }, .layer_thickness_m = &.{ 0.1, 0.1 }, .natural_water_table_depth_m = &.{ 1, 1 } },
        .{ .temperature_k = &temperature, .heat_capacity_megajoules_per_k = &capacity, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19 },
    );
    const runoff_m3 = state.east_runoff_m3_per_step[0];
    const expected_heat = 4.19 * 280 * runoff_m3;
    try std.testing.expect(runoff_m3 > 0);
    try std.testing.expectApproxEqAbs(expected_heat, state.east_runoff_heat_megajoules_per_step[0], 1e-15);
    try std.testing.expectApproxEqAbs(expected_heat, state.outgoing_runoff_heat_megajoules_per_step[0], 1e-15);
    try std.testing.expectApproxEqAbs(expected_heat, state.incoming_runoff_heat_megajoules_per_step[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 280), temperature[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 280), temperature[1], 1e-12);
    try std.testing.expectApproxEqAbs(initial_enthalpy, capacity[0] * temperature[0] + capacity[1] * temperature[1], 1e-12);
}

test "unequal-temperature internal runoff mixes recipient with immutable donor heat" {
    const topography = @import("../state/topography.zig");
    var units = [_]topography.LandscapeUnit{.{ .west_column = 1, .north_row = 1, .east_column = 2, .south_row = 1, .compass_aspect_degrees = 90, .geometric_aspect_degrees = 90, .slope_degrees = 5, .initial_snowpack_depth_m = 0, .soil_profile_file = "soil" }};
    var terrain = try terrain_module.State.initMapped(std.testing.allocator, .{ .allocator = std.testing.allocator, .units = &units }, &.{ 0, 0 }, &.{ 1, 1 }, &.{ 1, 1 }, 2, 1);
    defer terrain.deinit();
    terrain.runoff_to_east[0] = true;
    terrain.runoff_to_west[0] = false;
    terrain.east_west_runoff_fraction[0] = 1;
    terrain.north_south_runoff_fraction[0] = 0;
    try terrain.bindInitialSurfaceElevations(&.{ 1, 0 });
    var state = try State.init(std.testing.allocator, 2, 0.1);
    defer state.deinit();
    var water = [_]f64{ 0.02, 0.01 };
    var temperature = [_]f64{ 300, 280 };
    var capacity = [_]f64{ 1 + 4.19 * water[0], 1 + 4.19 * water[1] };
    const destination_capacity_before = capacity[1];
    const initial_enthalpy = capacity[0] * temperature[0] + capacity[1] * temperature[1];
    try routeWithSurfaceBoundary(
        &state,
        2,
        1,
        &terrain,
        &.{ 1, 1 },
        &water,
        &.{ 0, 0 },
        &.{ 0.005, 0.005 },
        &.{ 1, 1 },
        .{ .north = &.{ 0, 0 }, .east = &.{ 0, 0 }, .south = &.{ 0, 0 }, .west = &.{ 0, 0 } },
        .{ .ground_surface_retention_m3_per_m2 = 0, .runoff_roughness_h_per_m_one_third = 0.1 },
        .{ .soil_layer_count = 1, .bulk_density_megagrams_per_m3 = &.{ 1, 1 }, .layer_bottom_depth_m = &.{ 0.1, 0.1 }, .layer_thickness_m = &.{ 0.1, 0.1 }, .natural_water_table_depth_m = &.{ 1, 1 } },
        .{ .temperature_k = &temperature, .heat_capacity_megajoules_per_k = &capacity, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19 },
    );
    const runoff_m3 = state.east_runoff_m3_per_step[0];
    const donor_heat = 4.19 * 300 * runoff_m3;
    const expected_destination_temperature =
        (destination_capacity_before * 280 + donor_heat) /
        (destination_capacity_before + 4.19 * runoff_m3);
    try std.testing.expectApproxEqAbs(donor_heat, state.east_runoff_heat_megajoules_per_step[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 300), temperature[0], 1e-12);
    try std.testing.expectApproxEqAbs(expected_destination_temperature, temperature[1], 1e-12);
    try std.testing.expect(temperature[1] > 280 and temperature[1] < 300);
    try std.testing.expectApproxEqAbs(initial_enthalpy, capacity[0] * temperature[0] + capacity[1] * temperature[1], 1e-12);
}

test "open runoff boundary records positive exports through daily landscape water ledger" {
    const topography = @import("../state/topography.zig");
    var units = [_]topography.LandscapeUnit{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1, .compass_aspect_degrees = 90, .geometric_aspect_degrees = 90, .slope_degrees = 5, .initial_snowpack_depth_m = 0, .soil_profile_file = "soil" }};
    var terrain = try terrain_module.State.initMapped(std.testing.allocator, .{ .allocator = std.testing.allocator, .units = &units }, &.{0}, &.{1}, &.{1}, 1, 1);
    defer terrain.deinit();
    terrain.runoff_to_east[0] = true;
    terrain.east_west_runoff_fraction[0] = 1;
    terrain.north_south_runoff_fraction[0] = 0;
    var state = try State.init(std.testing.allocator, 1, 0.1);
    defer state.deinit();
    var water = [_]f64{0.02};
    try route(&state, 1, 1, &terrain, &.{1}, &water, &.{0}, &.{0.005}, &.{3}, .{ .north = &.{0}, .east = &.{0.5}, .south = &.{0}, .west = &.{0} }, .{ .ground_surface_retention_m3_per_m2 = 0, .runoff_roughness_h_per_m_one_third = 0.1 });
    try std.testing.expect(state.exported_water_m3[0] > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), water[0] + state.exported_water_m3[0], 1e-15);
    const daily_water = @import("../soil/diagnostics/daily_water_budget.zig");
    const landscape_boundary = @import("../validation/landscape_boundary_balance.zig");
    var daily = try daily_water.State.init(std.testing.allocator, 1);
    defer daily.deinit();
    try daily.accumulateCell(0, .{
        .rainfall_m3 = 0,
        .boundary_water_inflow_m3 = 0,
        .evaporation_m3 = 0,
        .runoff_m3 = state.exported_water_m3[0],
        .water_outflow_m3 = 0,
        .lateral_water_outflow_m3 = 0,
        .sediment_outflow_m3 = 0,
        .boundary_water_exchange_gain_m3 = 0,
        .boundary_water_exchange_loss_m3 = 0,
    });
    var landscape: landscape_boundary.State = .{};
    try landscape.accumulateAcceptedWater(
        daily.rainfall_m3,
        daily.boundary_water_inflow_m3,
        daily.runoff_m3,
        daily.evaporation_m3,
        daily.water_outflow_m3,
        daily.lateral_water_outflow_m3,
    );
    // The export must survive both reductions; clamping its negative to zero
    // loses water at the daily audit even when routing closes locally.
    try std.testing.expect(landscape.cumulative.runoff_m3 > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), water[0] + landscape.cumulative.runoff_m3, 1e-15);
}

test "open runoff boundary exports donor sensible heat without changing donor temperature" {
    const topography = @import("../state/topography.zig");
    var units = [_]topography.LandscapeUnit{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1, .compass_aspect_degrees = 90, .geometric_aspect_degrees = 90, .slope_degrees = 5, .initial_snowpack_depth_m = 0, .soil_profile_file = "soil" }};
    var terrain = try terrain_module.State.initMapped(std.testing.allocator, .{ .allocator = std.testing.allocator, .units = &units }, &.{0}, &.{1}, &.{1}, 1, 1);
    defer terrain.deinit();
    terrain.runoff_to_east[0] = true;
    terrain.east_west_runoff_fraction[0] = 1;
    terrain.north_south_runoff_fraction[0] = 0;
    var state = try State.init(std.testing.allocator, 1, 0.1);
    defer state.deinit();
    var water = [_]f64{0.02};
    var temperature = [_]f64{290};
    var capacity = [_]f64{1 + 4.19 * water[0]};
    const initial_enthalpy = capacity[0] * temperature[0];
    try routeWithSurfaceBoundary(
        &state,
        1,
        1,
        &terrain,
        &.{1},
        &water,
        &.{0},
        &.{0.005},
        &.{3},
        .{ .north = &.{0}, .east = &.{0.5}, .south = &.{0}, .west = &.{0} },
        .{ .ground_surface_retention_m3_per_m2 = 0, .runoff_roughness_h_per_m_one_third = 0.1 },
        .{ .soil_layer_count = 1, .bulk_density_megagrams_per_m3 = &.{1}, .layer_bottom_depth_m = &.{0.1}, .layer_thickness_m = &.{0.1}, .natural_water_table_depth_m = &.{1} },
        .{ .temperature_k = &temperature, .heat_capacity_megajoules_per_k = &capacity, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19 },
    );
    const expected_export_heat = 4.19 * 290 * state.exported_water_m3[0];
    try std.testing.expect(state.exported_water_m3[0] > 0);
    try std.testing.expectApproxEqAbs(expected_export_heat, state.exported_heat_megajoules[0], 1e-15);
    try std.testing.expectApproxEqAbs(expected_export_heat, state.outgoing_runoff_heat_megajoules_per_step[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 290), temperature[0], 1e-12);
    try std.testing.expectApproxEqAbs(initial_enthalpy, capacity[0] * temperature[0] + state.exported_heat_megajoules[0], 1e-12);
}

test "water heat update rejects a late invalid cell before changing authoritative state" {
    var water = [_]f64{ 0.02, 0.01 };
    var temperature = [_]f64{ 300, 280 };
    var capacity = [_]f64{ 1.0838, 1.0419 };
    const water_before = water;
    const temperature_before = temperature;
    const capacity_before = capacity;
    try std.testing.expectError(
        error.InvalidSurfaceRunoffThermalCandidate,
        state_updateWaterHeatChanges(
            &water,
            &.{ -0.001, 0.001 },
            .{
                .temperature_k = &temperature,
                .heat_capacity_megajoules_per_k = &capacity,
                .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
            },
            &.{ -4.19 * 300 * 0.001, std.math.nan(f64) },
        ),
    );
    try std.testing.expectEqualDeep(water_before, water);
    try std.testing.expectEqualDeep(temperature_before, temperature);
    try std.testing.expectEqualDeep(capacity_before, capacity);
}

test "WATSUB ponded cell uses natural water-table hydraulic depth and conserves donor water" {
    const topography = @import("../state/topography.zig");
    var units = [_]topography.LandscapeUnit{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1, .compass_aspect_degrees = 90, .geometric_aspect_degrees = 90, .slope_degrees = 5, .initial_snowpack_depth_m = 0, .soil_profile_file = "soil" }};
    var terrain = try terrain_module.State.initMapped(std.testing.allocator, .{ .allocator = std.testing.allocator, .units = &units }, &.{0}, &.{1}, &.{1}, 1, 1);
    defer terrain.deinit();
    terrain.runoff_to_east[0] = true;
    terrain.east_west_runoff_fraction[0] = 1;
    terrain.north_south_runoff_fraction[0] = 0;
    var state = try State.init(std.testing.allocator, 1, 0.1);
    defer state.deinit();
    var water = [_]f64{0.02};
    var temperature = [_]f64{290};
    var heat_capacity = [_]f64{1 + 4.19 * water[0]};
    const initial = water[0];
    try routeWithSurfaceBoundary(
        &state,
        1,
        1,
        &terrain,
        &.{1},
        &water,
        &.{0},
        &.{0},
        &.{3},
        .{ .north = &.{0}, .east = &.{1}, .south = &.{0}, .west = &.{0} },
        .{ .ground_surface_retention_m3_per_m2 = 1, .runoff_roughness_h_per_m_one_third = 0.1 },
        .{
            .soil_layer_count = 1,
            .bulk_density_megagrams_per_m3 = &.{0},
            .layer_bottom_depth_m = &.{0.75},
            .layer_thickness_m = &.{0.5},
            .natural_water_table_depth_m = &.{0.30},
        },
        .{
            .temperature_k = &temperature,
            .heat_capacity_megajoules_per_k = &heat_capacity,
            .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        },
    );
    try std.testing.expectEqual(@as(f64, 0.001), state.total_runoff_m3_per_step[0]);
    try std.testing.expectEqual(state.total_runoff_m3_per_step[0], state.exported_water_m3[0]);
    try std.testing.expectEqual(initial, water[0] + state.exported_water_m3[0]);
}

test "GRID-INV-S1 exported runoff depth is invariant to cell footprint" {
    // One open-boundary cell, same ponded depth and same slope, on footprints
    // spanning four decades. Before the cap was expressed as a depth, the
    // absolute 1e-3 m3 ceiling throttled the 1e4 m2 cell by four orders of
    // magnitude relative to the 1 m2 cell purely by coarsening.
    const topography = @import("../state/topography.zig");
    const ponded_depth_m: f64 = 0.05;
    var reference_depth_m: f64 = undefined;
    for ([_]f64{ 1, 10, 100, 1.0e4 }, 0..) |area_m2, index| {
        const width_m = @sqrt(area_m2);
        var units = [_]topography.LandscapeUnit{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1, .compass_aspect_degrees = 90, .geometric_aspect_degrees = 90, .slope_degrees = 5, .initial_snowpack_depth_m = 0, .soil_profile_file = "soil" }};
        var terrain = try terrain_module.State.initMapped(std.testing.allocator, .{ .allocator = std.testing.allocator, .units = &units }, &.{0}, &.{width_m}, &.{width_m}, 1, 1);
        defer terrain.deinit();
        terrain.runoff_to_east[0] = true;
        terrain.east_west_runoff_fraction[0] = 1;
        terrain.north_south_runoff_fraction[0] = 0;
        var state = try State.init(std.testing.allocator, 1, 0.1);
        defer state.deinit();
        var water = [_]f64{ponded_depth_m * area_m2};
        try route(&state, 1, 1, &terrain, &.{area_m2}, &water, &.{0}, &.{0}, &.{3}, .{ .north = &.{0}, .east = &.{1}, .south = &.{0}, .west = &.{0} }, .{ .ground_surface_retention_m3_per_m2 = 0, .runoff_roughness_h_per_m_one_third = 0.1 });
        try std.testing.expect(state.exported_water_m3[0] > 0);
        const depth_m = state.exported_water_m3[0] / area_m2;
        if (index == 0) reference_depth_m = depth_m;
        try std.testing.expectApproxEqRel(reference_depth_m, depth_m, 1e-12);
    }
}

test "Morton two-pass runoff matches resident conservative state_update across tiles" {
    const topography = @import("../state/topography.zig");
    var units = [_]topography.LandscapeUnit{.{
        .west_column = 1,
        .north_row = 1,
        .east_column = 4,
        .south_row = 1,
        .compass_aspect_degrees = 90,
        .geometric_aspect_degrees = 90,
        .slope_degrees = 5,
        .initial_snowpack_depth_m = 0,
        .soil_profile_file = "soil",
    }};
    var terrain = try terrain_module.State.initMapped(
        std.testing.allocator,
        .{ .allocator = std.testing.allocator, .units = &units },
        &.{ 0, 0, 0, 0 },
        &.{ 1, 1, 1, 1 },
        &.{ 1, 1, 1, 1 },
        4,
        1,
    );
    defer terrain.deinit();
    for (0..4) |cell| {
        terrain.runoff_to_east[cell] = cell + 1 < 4;
        terrain.runoff_to_west[cell] = false;
        terrain.runoff_to_north[cell] = false;
        terrain.runoff_to_south[cell] = false;
        terrain.east_west_runoff_fraction[cell] = 1;
        terrain.north_south_runoff_fraction[cell] = 0;
        terrain.initial_surface_elevation_m[cell] =
            @as(f64, @floatFromInt(4 - cell));
        terrain.current_surface_elevation_m[cell] =
            terrain.initial_surface_elevation_m[cell];
    }
    var state = try State.init(std.testing.allocator, 4, 0.1);
    defer state.deinit();
    const initial_water = [_]f64{ 0.04, 0.03, 0.02, 0.01 };
    var resident_water = initial_water;
    try calculateFluxes(
        &state,
        4,
        1,
        &terrain,
        &.{ 1, 1, 1, 1 },
        &resident_water,
        &.{ 0, 0, 0, 0 },
        &.{ 0, 0, 0, 0 },
        &.{ 1, 1, 1, 1 },
        .{
            .north = &.{ 0, 0, 0, 0 },
            .east = &.{ 0, 0, 0, 0 },
            .south = &.{ 0, 0, 0, 0 },
            .west = &.{ 0, 0, 0, 0 },
        },
        .{
            .ground_surface_retention_m3_per_m2 = 0,
            .runoff_roughness_h_per_m_one_third = 0.1,
        },
    );
    try state_updateWaterChanges(&resident_water, state.water_change_m3);

    var plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        1,
        4,
        1,
        2,
        2,
    );
    defer plan.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try lateral_store.FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        4096,
        30,
        31,
    );
    for (plan.tiles, 0..) |_, tile_index| {
        var contributions =
            std.ArrayList(lateral_store.Contribution).empty;
        defer contributions.deinit(std.testing.allocator);
        try appendOwnedTileContributions(
            std.testing.allocator,
            plan,
            tile_index,
            &state,
            &contributions,
        );
        try store.saveSourceTile(
            plan,
            tile_index,
            lateral_component_count,
            contributions.items,
        );
    }
    try store.publish(plan);
    var tiled_water = initial_water;
    @memset(state.water_change_m3, 0);
    @memset(state.exported_water_m3, 0);
    const gathered = try std.testing.allocator.alloc(
        f64,
        4 * lateral_component_count,
    );
    defer std.testing.allocator.free(gathered);
    @memset(gathered, 0);
    for (plan.tiles, 0..) |_, tile_index| {
        try store.gatherOwnedTile(
            plan,
            tile_index,
            lateral_component_count,
            gathered,
        );
        try state_updateOwnedTileContributions(
            plan,
            tile_index,
            &state,
            &tiled_water,
            gathered,
        );
    }
    try std.testing.expectEqualSlices(f64, &resident_water, &tiled_water);
    var initial_total_m3: f64 = 0;
    var tiled_total_m3: f64 = 0;
    for (initial_water) |water_m3| initial_total_m3 += water_m3;
    for (tiled_water) |water_m3| tiled_total_m3 += water_m3;
    try std.testing.expectApproxEqAbs(
        initial_total_m3,
        tiled_total_m3,
        1e-15,
    );
}
