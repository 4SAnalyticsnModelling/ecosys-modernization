const std = @import("std");
const builtin = @import("builtin");
const water_flux = @import("../soil/water/flux.zig");
const surface_water_flow = @import("water_flow.zig");
const retention = @import("../soil/water/retention.zig");
const snow_cover = @import("../soil/water/snow_cover_fraction.zig");
const ice_units = @import("../core/ice_units.zig");

pub const ThermodynamicParameters = struct {
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,

    fn validate(self: ThermodynamicParameters) !void {
        inline for (@typeInfo(ThermodynamicParameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value <= 0) return error.InvalidSurfacePrecipitationThermodynamics;
        }
    }
};

/// Fixture-only values. Production preparation requires the runscript-owned
/// coefficients explicitly.
const test_thermodynamics: ThermodynamicParameters = .{
    .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095,
    .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
};

pub const RuntimeState = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    litter_water_m3: []f64,
    litter_water_capacity_m3: []f64,
    litter_cover_fraction: []f64,
    solid_snow_water_equivalent_m3: []f64,
    rain_to_snow_m3_per_h: []f64,
    snow_to_snow_m3_per_h: []f64,
    water_to_litter_m3_per_h: []f64,
    water_to_matrix_m3_per_h: []f64,
    water_to_macropore_m3_per_h: []f64,
    heat_to_snow_megajoules_per_h: []f64,
    heat_to_litter_megajoules_per_h: []f64,
    heat_to_soil_megajoules_per_h: []f64,
    rainfall_m3_per_h: []f64,
    snowfall_water_equivalent_m3_per_h: []f64,
    intercepted_rain_m3_per_h: []f64,
    snow_cover_fraction: []f64,
    atmospheric_temperature_k: []f64,
    matrix_fraction: []f64,
    macropore_fraction: []f64,
    matrix_air_capacity_m3: []f64,
    macropore_air_capacity_m3: []f64,
    litter_absent_above_water_table: []bool,
    rainfall_impact_energy_j: []f64,
    cumulative_rainfall_impact_energy_j: []f64,
    saturated_hydraulic_conductivity_multiplier: []f64,

    /// Releases the successfully allocated reflected slice prefix from
    /// `init` in field order. Both slice element types follow the same
    /// allocation order; keeping the loop out of line avoids one unrolled
    /// cleanup copy per fallible allocation.
    noinline fn deinitAllocatedPrefix(self: *RuntimeState, allocated_count: usize) void {
        var remaining = allocated_count;
        inline for (@typeInfo(RuntimeState).@"struct".fields) |field| {
            if (field.type == []f64 or field.type == []bool) {
                if (remaining == 0) return;
                self.allocator.free(@field(self, field.name));
                remaining -= 1;
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !RuntimeState {
        if (cell_count == 0) return error.InvalidSurfaceIngressDimensions;
        var result: RuntimeState = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        var allocated: usize = 0;
        errdefer result.deinitAllocatedPrefix(allocated);
        inline for (@typeInfo(RuntimeState).@"struct".fields) |field| if (field.type == []f64 or field.type == []bool) {
            @field(result, field.name) = try allocator.alloc(std.meta.Elem(field.type), cell_count);
            @memset(@field(result, field.name), if (field.type == []bool) false else 0);
            allocated += 1;
        };
        @memset(result.saturated_hydraulic_conductivity_multiplier, 1);
        return result;
    }

    pub fn deinit(self: *RuntimeState) void {
        inline for (@typeInfo(RuntimeState).@"struct".fields) |field| if (field.type == []f64 or field.type == []bool) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

test "surface precipitation state releases every mixed-slice allocation prefix" {
    const allocation_count = comptime count: {
        var count: usize = 0;
        for (@typeInfo(RuntimeState).@"struct".fields) |field| {
            if (field.type == []f64 or field.type == []bool) count += 1;
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
            RuntimeState.init(failing.allocator(), 2),
        );
    }
}

/// Binds WTHR/HOUR1 extensive carriers to the runtime top-soil geometry and
/// then publishes the WATSUB surface ledgers without allocating per hour.
pub fn prepareFromModel(state: *RuntimeState, atmosphere: *const @import("../atmosphere/atmospheric_forcing.zig").State, grid: *const @import("../state/grid.zig").GridState, canopy: ?*const @import("../canopy/energy/precipitation_retention.zig").State, cell_area_m2: []const f64, snow_depth_m: []const f64, full_snow_cover_depth_m: f64, ice_density_megagrams_per_m3: f64, thermodynamics: ThermodynamicParameters) !void {
    try thermodynamics.validate();
    if (atmosphere.cell_count != state.cell_count or grid.cell_count != state.cell_count or cell_area_m2.len != state.cell_count or snow_depth_m.len != state.cell_count or !std.math.isFinite(full_snow_cover_depth_m) or full_snow_cover_depth_m <= 0) return error.SurfaceIngressDimensionMismatch;
    if (canopy) |value| if (value.cell_count != state.cell_count) return error.SurfaceIngressDimensionMismatch;
    for (0..state.cell_count) |cell| {
        const area = cell_area_m2[cell];
        const top = cell * grid.soil_layer_capacity;
        const total_pore_capacity = grid.matrix_pore_capacity_m3[top] + grid.macropore_pore_capacity_m3[top];
        const matrix_ice_volume_m3 = ice_units.physicalVolumeM3FromWaterEquivalent(grid.matrix_ice_water_m3[top], ice_density_megagrams_per_m3) catch return error.InvalidSurfaceIngressModelState;
        const macropore_ice_volume_m3 = ice_units.physicalVolumeM3FromWaterEquivalent(grid.macropore_ice_water_m3[top], ice_density_megagrams_per_m3) catch return error.InvalidSurfaceIngressModelState;
        if (!std.math.isFinite(area) or area <= 0 or !std.math.isFinite(snow_depth_m[cell]) or snow_depth_m[cell] < 0 or total_pore_capacity <= 0) return error.InvalidSurfaceIngressModelState;
        state.rainfall_m3_per_h[cell] = atmosphere.rainfall_m[cell] * area;
        state.snowfall_water_equivalent_m3_per_h[cell] = atmosphere.snowfall_water_equivalent_m[cell] * area;
        state.intercepted_rain_m3_per_h[cell] = if (canopy) |value| value.cell_retention_m3_per_h[cell] else 0;
        // WATSUB `FSNW`, `watsub.f` 386--392. Delegated to the single
        // authoritative owner. This site previously squared the depth ratio
        // where the source takes its SQUARE ROOT, and omitted the `FSNX`
        // `1.0e-3` floor, understating cover by up to 52x for thin snow. See
        // `docs/traceability/watsub_snow_cover_fraction_exponent_defect.md`.
        // Consumers derive the snow-free fraction as `1 - snow_cover_fraction`,
        // which is exact here because the owner returns the covered fraction as
        // the exact complement of the floored snow-free fraction.
        state.snow_cover_fraction[cell] = (try snow_cover.evaluate(snow_depth_m[cell], full_snow_cover_depth_m)).snow_fraction;
        state.atmospheric_temperature_k[cell] = atmosphere.air_temperature_k[cell];
        state.matrix_fraction[cell] = grid.matrix_pore_capacity_m3[top] / total_pore_capacity;
        state.macropore_fraction[cell] = grid.macropore_pore_capacity_m3[top] / total_pore_capacity;
        state.matrix_air_capacity_m3[cell] = @max(
            0,
            grid.matrix_pore_capacity_m3[top] -
                grid.matrix_liquid_water_m3[top] -
                matrix_ice_volume_m3,
        );
        state.macropore_air_capacity_m3[cell] = @max(
            0,
            grid.macropore_pore_capacity_m3[top] -
                grid.macropore_liquid_water_m3[top] -
                macropore_ice_volume_m3,
        );
    }
    try prepareRuntimeIngress(state, .{ .rainfall_m3_per_h = state.rainfall_m3_per_h, .snowfall_water_equivalent_m3_per_h = state.snowfall_water_equivalent_m3_per_h, .intercepted_rain_m3_per_h = state.intercepted_rain_m3_per_h, .snow_cover_fraction = state.snow_cover_fraction, .atmospheric_temperature_k = state.atmospheric_temperature_k, .matrix_fraction = state.matrix_fraction, .macropore_fraction = state.macropore_fraction, .matrix_air_capacity_m3 = state.matrix_air_capacity_m3, .macropore_air_capacity_m3 = state.macropore_air_capacity_m3, .litter_absent_above_water_table = state.litter_absent_above_water_table }, thermodynamics);
}

pub const RuntimeInputs = struct {
    rainfall_m3_per_h: []const f64,
    snowfall_water_equivalent_m3_per_h: []const f64,
    intercepted_rain_m3_per_h: []const f64,
    snow_cover_fraction: []const f64,
    atmospheric_temperature_k: []const f64,
    matrix_fraction: []const f64,
    macropore_fraction: []const f64,
    matrix_air_capacity_m3: []const f64,
    macropore_air_capacity_m3: []const f64,
    litter_absent_above_water_table: []const bool,
};

/// Prepares and atomically publishes WATSUB precipitation carriers for all
/// runtime cells. Soil/snow storage state_update consumes these ledgers separately.
pub fn prepareRuntimeIngress(state: *RuntimeState, inputs: RuntimeInputs, thermodynamics: ThermodynamicParameters) !void {
    try thermodynamics.validate();
    const count = state.cell_count;
    inline for (.{ inputs.rainfall_m3_per_h, inputs.snowfall_water_equivalent_m3_per_h, inputs.intercepted_rain_m3_per_h, inputs.snow_cover_fraction, inputs.atmospheric_temperature_k, inputs.matrix_fraction, inputs.macropore_fraction, inputs.matrix_air_capacity_m3, inputs.macropore_air_capacity_m3 }) |values| if (values.len != count) return error.SurfaceIngressDimensionMismatch;
    if (inputs.litter_absent_above_water_table.len != count) return error.SurfaceIngressDimensionMismatch;
    // Validate every cell before publishing any ledger. Repeating these pure,
    // inexpensive calculations avoids both per-hour allocation and partial
    // flux state_update when a later cell contains invalid data.
    for (0..count) |cell| _ = try calculateRuntimeIngressCell(state, inputs, cell, thermodynamics);
    for (0..count) |cell| {
        const result = try calculateRuntimeIngressCell(state, inputs, cell, thermodynamics);
        const partition = result.partition;
        const redistributed = result.redistributed;
        state.rain_to_snow_m3_per_h[cell] = partition.rain_to_snow_m3_per_h;
        state.snow_to_snow_m3_per_h[cell] = partition.snow_to_snow_m3_per_h;
        state.water_to_litter_m3_per_h[cell] = redistributed.litter_water_m3;
        state.water_to_matrix_m3_per_h[cell] = redistributed.matrix_water_m3;
        state.water_to_macropore_m3_per_h[cell] = redistributed.macropore_water_m3;
        state.heat_to_snow_megajoules_per_h[cell] = partition.heat_to_snow_megajoules_per_h;
        state.heat_to_litter_megajoules_per_h[cell] = redistributed.litter_heat_megajoules;
        state.heat_to_soil_megajoules_per_h[cell] = redistributed.soil_heat_megajoules;
    }
}

fn calculateRuntimeIngressCell(state: *const RuntimeState, inputs: RuntimeInputs, cell: usize, thermodynamics: ThermodynamicParameters) !struct { partition: SurfacePartition, redistributed: Redistribution } {
    const partition = try partitionAtmosphericWater(.{ .rain_and_irrigation_m3_per_h = inputs.rainfall_m3_per_h[cell], .intercepted_rain_m3_per_h = inputs.intercepted_rain_m3_per_h[cell], .snowfall_water_equivalent_m3_per_h = inputs.snowfall_water_equivalent_m3_per_h[cell], .snow_cover_fraction = inputs.snow_cover_fraction[cell], .snow_free_fraction = 1.0 - inputs.snow_cover_fraction[cell], .litter_cover_fraction = state.litter_cover_fraction[cell], .litter_water_capacity_m3 = state.litter_water_capacity_m3[cell], .litter_water_m3 = state.litter_water_m3[cell], .litter_absent_above_water_table = inputs.litter_absent_above_water_table[cell], .atmospheric_temperature_k = inputs.atmospheric_temperature_k[cell], .matrix_fraction = inputs.matrix_fraction[cell], .macropore_fraction = inputs.macropore_fraction[cell] }, thermodynamics);
    const redistributed = try redistribute(.{ .soil_surface_present = true, .rain_and_irrigation_to_matrix_m3 = partition.water_to_matrix_m3_per_h, .rain_and_irrigation_to_macropore_m3 = partition.water_to_macropore_m3_per_h, .rain_and_irrigation_to_litter_m3 = partition.water_to_litter_m3_per_h, .matrix_air_capacity_m3 = inputs.matrix_air_capacity_m3[cell], .macropore_air_capacity_m3 = inputs.macropore_air_capacity_m3[cell], .snow_free_fraction = 1.0 - inputs.snow_cover_fraction[cell], .atmospheric_temperature_k = inputs.atmospheric_temperature_k[cell], .litter_input_heat_megajoules = partition.heat_to_litter_megajoules_per_h, .soil_input_heat_megajoules = partition.heat_to_soil_megajoules_per_h }, thermodynamics);
    return .{ .partition = partition, .redistributed = redistributed };
}

/// Returns FLWQBX at the source-order checkpoint before WATSUB redirects
/// excess micropore/macropore ingress back to litter.  FLQRQ/FLQRI use this
/// value, not the final post-redistribution litter-water carrier.
pub fn preRedistributionLitterWaterM3PerH(
    state: *const RuntimeState,
    cell: usize,
    thermodynamics: ThermodynamicParameters,
) !f64 {
    if (cell >= state.cell_count) return error.SurfaceIngressCellOutOfBounds;
    const partition = try partitionAtmosphericWater(.{
        .rain_and_irrigation_m3_per_h = state.rainfall_m3_per_h[cell],
        .intercepted_rain_m3_per_h = state.intercepted_rain_m3_per_h[cell],
        .snowfall_water_equivalent_m3_per_h = state.snowfall_water_equivalent_m3_per_h[cell],
        .snow_cover_fraction = state.snow_cover_fraction[cell],
        .snow_free_fraction = 1.0 - state.snow_cover_fraction[cell],
        .litter_cover_fraction = state.litter_cover_fraction[cell],
        .litter_water_capacity_m3 = state.litter_water_capacity_m3[cell],
        .litter_water_m3 = state.litter_water_m3[cell],
        .litter_absent_above_water_table = state.litter_absent_above_water_table[cell],
        .atmospheric_temperature_k = state.atmospheric_temperature_k[cell],
        .matrix_fraction = state.matrix_fraction[cell],
        .macropore_fraction = state.macropore_fraction[cell],
    }, thermodynamics);
    return partition.water_to_litter_m3_per_h;
}

pub fn state_updateRuntimeIngress(state: *RuntimeState, timestep_h: f64) !void {
    if (!std.math.isFinite(timestep_h) or timestep_h <= 0) return error.InvalidSurfaceIngressTimestep;
    for (0..state.cell_count) |cell| {
        const next_litter = state.litter_water_m3[cell] + state.water_to_litter_m3_per_h[cell] * timestep_h;
        const next_snow = state.solid_snow_water_equivalent_m3[cell] + (state.rain_to_snow_m3_per_h[cell] + state.snow_to_snow_m3_per_h[cell]) * timestep_h;
        if (!std.math.isFinite(next_litter) or !std.math.isFinite(next_snow) or next_litter < 0 or next_snow < 0) return error.InvalidSurfaceIngressStateUpdate;
    }
    for (0..state.cell_count) |cell| {
        state.litter_water_m3[cell] += state.water_to_litter_m3_per_h[cell] * timestep_h;
        state.solid_snow_water_equivalent_m3[cell] += (state.rain_to_snow_m3_per_h[cell] + state.snow_to_snow_m3_per_h[cell]) * timestep_h;
    }
}

/// Publishes only the accepted liquid litter ingress for an internal coupled
/// substep. Snow is owned by `snow_solute_transport.State` and is mirrored from
/// that owner after acceptance; updating the legacy surface shadow here would
/// double atmospheric snow input.
pub fn state_updateLitterIngress(state: *RuntimeState, timestep_h: f64) !void {
    if (!std.math.isFinite(timestep_h) or timestep_h <= 0 or timestep_h > 1)
        return error.InvalidSurfaceIngressTimestep;
    for (0..state.cell_count) |cell| {
        const increment = state.water_to_litter_m3_per_h[cell] * timestep_h;
        const next = state.litter_water_m3[cell] + increment;
        if (!std.math.isFinite(increment) or increment < 0 or
            !std.math.isFinite(next) or next < 0)
            return error.InvalidSurfaceIngressStateUpdate;
    }
    for (0..state.cell_count) |cell|
        state.litter_water_m3[cell] += state.water_to_litter_m3_per_h[cell] * timestep_h;
}

pub const LitterHeatDestinations = struct {
    heat_capacity_megajoules_per_k: []f64,
    surface_temperature_k: []f64,
    gas_temperature_k: []f64,
    accepted_temperature_k: []f64,
};

/// Complete the direct rain/irrigation part of the accepted litter ingress.
/// Its water is already present, but the retained capacity and temperature
/// still describe the pre-ingress carrier. Snow water is heated separately
/// afterward. Use the captured DIRECT water rate, never the snow-augmented
/// `water_to_litter_m3_per_h`, and publish all thermal mirrors together.
pub fn state_updateLitterHeatIngress(
    state: *const RuntimeState,
    direct_water_m3_per_h: []const f64,
    destination: LitterHeatDestinations,
    timestep_h: f64,
    liquid_heat_capacity_megajoules_per_m3_k: f64,
) !void {
    const cells = state.cell_count;
    if (cells == 0 or state.heat_to_litter_megajoules_per_h.len != cells or direct_water_m3_per_h.len != cells)
        return error.SurfaceIngressDimensionMismatch;
    inline for (std.meta.fields(LitterHeatDestinations)) |field|
        if (@field(destination, field.name).len != cells) return error.SurfaceIngressDimensionMismatch;
    if (!std.math.isFinite(timestep_h) or timestep_h <= 0 or timestep_h > 1)
        return error.InvalidSurfaceIngressTimestep;
    if (!std.math.isFinite(liquid_heat_capacity_megajoules_per_m3_k) or liquid_heat_capacity_megajoules_per_m3_k <= 0)
        return error.InvalidSurfaceIngressHeatCapacity;
    // Preflight every cell before publishing even the first thermal owner.
    for (0..cells) |cell|
        _ = try litterIngressHeatCandidate(state, direct_water_m3_per_h, destination, cell, timestep_h, liquid_heat_capacity_megajoules_per_m3_k);
    for (0..cells) |cell| {
        const candidate = (try litterIngressHeatCandidate(state, direct_water_m3_per_h, destination, cell, timestep_h, liquid_heat_capacity_megajoules_per_m3_k)) orelse continue;
        destination.heat_capacity_megajoules_per_k[cell] = candidate.capacity;
        destination.surface_temperature_k[cell] = candidate.temperature;
        destination.gas_temperature_k[cell] = candidate.temperature;
        destination.accepted_temperature_k[cell] = candidate.temperature;
    }
}

fn litterIngressHeatCandidate(
    state: *const RuntimeState,
    direct_water_m3_per_h: []const f64,
    destination: LitterHeatDestinations,
    cell: usize,
    timestep_h: f64,
    liquid_capacity: f64,
) !?struct { capacity: f64, temperature: f64 } {
    const water_rate = direct_water_m3_per_h[cell];
    const heat_rate = state.heat_to_litter_megajoules_per_h[cell];
    if (!std.math.isFinite(water_rate) or water_rate < 0 or !std.math.isFinite(heat_rate) or heat_rate < 0)
        return error.InvalidSurfaceIngressStateUpdate;
    const water = water_rate * timestep_h;
    const heat = heat_rate * timestep_h;
    if (!std.math.isFinite(water) or water < 0 or !std.math.isFinite(heat) or heat < 0)
        return error.InvalidSurfaceIngressStateUpdate;
    const old_capacity = destination.heat_capacity_megajoules_per_k[cell];
    const old_temperature = destination.surface_temperature_k[cell];
    if (!std.math.isFinite(old_capacity) or old_capacity < 0 or
        !std.math.isFinite(old_temperature) or old_temperature <= 0)
        return error.InvalidSurfaceIngressStateUpdate;
    if (water == 0) {
        if (heat != 0) return error.InvalidSurfaceIngressStateUpdate;
        return null;
    }
    if (heat <= 0) return error.InvalidSurfaceIngressStateUpdate;
    const capacity = old_capacity + liquid_capacity * water;
    const energy = old_capacity * old_temperature + heat;
    const temperature = energy / capacity;
    if (!std.math.isFinite(capacity) or capacity <= 0 or !std.math.isFinite(energy) or
        !std.math.isFinite(temperature) or temperature <= 0)
        return error.InvalidSurfaceIngressStateUpdate;
    return .{ .capacity = capacity, .temperature = temperature };
}

/// Atomically publishes the prepared liquid carriers into authoritative top
/// matrix/macropore storage. All cells validate before any storage changes.
pub fn state_updateSoilIngress(state: *const RuntimeState, grid: *@import("../state/grid.zig").GridState, hydrology: *@import("../transport/hydrology.zig").State, timestep_h: f64, ice_density_megagrams_per_m3: f64) !void {
    if (grid.cell_count != state.cell_count or hydrology.columns * hydrology.rows != state.cell_count or !std.math.isFinite(timestep_h) or timestep_h <= 0) return error.SurfaceIngressDimensionMismatch;
    if (!std.math.isFinite(ice_density_megagrams_per_m3) or ice_density_megagrams_per_m3 <= 0 or ice_density_megagrams_per_m3 > 1) return error.InvalidSurfaceIngressStateUpdate;
    for (0..state.cell_count) |cell| {
        const top = cell * grid.soil_layer_capacity;
        const matrix_input = state.water_to_matrix_m3_per_h[cell] * timestep_h;
        const macropore_input = state.water_to_macropore_m3_per_h[cell] * timestep_h;
        const matrix_air_m3 = grid.matrix_pore_capacity_m3[top] -
            grid.matrix_liquid_water_m3[top] -
            grid.matrix_ice_water_m3[top] / ice_density_megagrams_per_m3;
        const macropore_air_m3 = grid.macropore_pore_capacity_m3[top] -
            grid.macropore_liquid_water_m3[top] -
            grid.macropore_ice_water_m3[top] / ice_density_megagrams_per_m3;
        const matrix_roundoff_m3 =
            poreCapacityRoundoffToleranceM3(
                grid.matrix_pore_capacity_m3[top],
            );
        const macropore_roundoff_m3 =
            poreCapacityRoundoffToleranceM3(
                grid.macropore_pore_capacity_m3[top],
            );
        if (!std.math.isFinite(matrix_input) or
            !std.math.isFinite(macropore_input) or matrix_input < 0 or
            macropore_input < 0 or !std.math.isFinite(matrix_air_m3) or
            !std.math.isFinite(macropore_air_m3) or
            matrix_air_m3 < -matrix_roundoff_m3 or
            macropore_air_m3 < -macropore_roundoff_m3 or
            matrix_input >
                @max(0, matrix_air_m3) + matrix_roundoff_m3 or
            macropore_input >
                @max(0, macropore_air_m3) + macropore_roundoff_m3)
        {
            if (!builtin.is_test)
                std.log.err(
                    "invalid surface ingress state_update: cell={} matrix_input_m3={} matrix_liquid_m3={} matrix_ice_m3={} matrix_pore_capacity_m3={} matrix_air_m3={} macropore_input_m3={} macropore_liquid_m3={} macropore_ice_m3={} macropore_pore_capacity_m3={} macropore_air_m3={}",
                    .{
                        cell,
                        matrix_input,
                        grid.matrix_liquid_water_m3[top],
                        grid.matrix_ice_water_m3[top],
                        grid.matrix_pore_capacity_m3[top],
                        matrix_air_m3,
                        macropore_input,
                        grid.macropore_liquid_water_m3[top],
                        grid.macropore_ice_water_m3[top],
                        grid.macropore_pore_capacity_m3[top],
                        macropore_air_m3,
                    },
                );
            return error.InvalidSurfaceIngressStateUpdate;
        }
    }
    for (0..state.cell_count) |cell| {
        const top = cell * grid.soil_layer_capacity;
        const matrix_input = state.water_to_matrix_m3_per_h[cell] * timestep_h;
        const macropore_input = state.water_to_macropore_m3_per_h[cell] * timestep_h;
        grid.matrix_liquid_water_m3[top] += matrix_input;
        grid.macropore_liquid_water_m3[top] += macropore_input;
        grid.liquid_water_m3[top] += matrix_input + macropore_input;
        grid.matrix_air_volume_m3[top] = @max(
            0,
            grid.matrix_pore_capacity_m3[top] -
                grid.matrix_liquid_water_m3[top] -
                grid.matrix_ice_water_m3[top] / ice_density_megagrams_per_m3,
        );
        grid.macropore_air_volume_m3[top] = @max(
            0,
            grid.macropore_pore_capacity_m3[top] -
                grid.macropore_liquid_water_m3[top] -
                grid.macropore_ice_water_m3[top] / ice_density_megagrams_per_m3,
        );
        grid.air_volume_m3[top] = grid.matrix_air_volume_m3[top] + grid.macropore_air_volume_m3[top];
        hydrology.micropore_water_volume_m3[top] = grid.matrix_liquid_water_m3[top];
        hydrology.macropore_water_volume_m3[top] = grid.macropore_liquid_water_m3[top];
        hydrology.matrix_air_volume_m3[top] = grid.matrix_air_volume_m3[top];
        hydrology.macropore_air_volume_m3[top] = grid.macropore_air_volume_m3[top];
        hydrology.air_volume_m3[top] = grid.air_volume_m3[top];
    }
}

fn poreCapacityRoundoffToleranceM3(capacity_m3: f64) f64 {
    return @max(
        1.0e-12,
        64.0 * std.math.floatEps(f64) *
            @max(1.0, @abs(capacity_m3)),
    );
}

/// Bind only donor heat not already represented by the liquid ingress at
/// the current recipient temperature. Call for each accepted substep using
/// direct precipitation rates, before snow-discharge heat is added separately.
/// The runtime heat-source workspace holds rates, so its caller passes 1 here;
/// the heat solve integrates those rates over the actual substep duration.
pub fn bindSoilHeatIngress(state: *const RuntimeState, grid: *const @import("../state/grid.zig").GridState, soil_heat_source_megajoules: []f64, timestep_h: f64, liquid_heat_capacity_megajoules_per_m3_k: f64) !void {
    if (grid.cell_count != state.cell_count or soil_heat_source_megajoules.len != grid.layer_count or
        state.water_to_matrix_m3_per_h.len != state.cell_count or state.water_to_macropore_m3_per_h.len != state.cell_count or
        state.heat_to_soil_megajoules_per_h.len != state.cell_count or !std.math.isFinite(timestep_h) or timestep_h <= 0)
        return error.SurfaceIngressDimensionMismatch;
    if (!std.math.isFinite(liquid_heat_capacity_megajoules_per_m3_k) or liquid_heat_capacity_megajoules_per_m3_k <= 0)
        return error.InvalidSurfaceIngressHeatCapacity;
    // Validate the entire landscape and its sums before publishing any cell.
    for (0..state.cell_count) |cell| {
        const top = try grid.layerIndex(cell, 0);
        const heat = try soilIngressHeatRemainder(state, grid, cell, timestep_h, liquid_heat_capacity_megajoules_per_m3_k);
        if (!std.math.isFinite(soil_heat_source_megajoules[top]) or !std.math.isFinite(soil_heat_source_megajoules[top] + heat))
            return error.InvalidSurfaceIngressStateUpdate;
    }
    for (0..state.cell_count) |cell|
        soil_heat_source_megajoules[cell * grid.soil_layer_capacity] +=
            try soilIngressHeatRemainder(state, grid, cell, timestep_h, liquid_heat_capacity_megajoules_per_m3_k);
}

fn soilIngressHeatRemainder(state: *const RuntimeState, grid: *const @import("../state/grid.zig").GridState, cell: usize, timestep_h: f64, liquid_heat_capacity_megajoules_per_m3_k: f64) !f64 {
    const matrix_rate = state.water_to_matrix_m3_per_h[cell];
    const macropore_rate = state.water_to_macropore_m3_per_h[cell];
    const temperature = grid.soil_temperature_k[try grid.layerIndex(cell, 0)];
    if (!std.math.isFinite(matrix_rate) or matrix_rate < 0 or !std.math.isFinite(macropore_rate) or macropore_rate < 0 or
        !std.math.isFinite(temperature) or temperature <= 0)
        return error.InvalidSurfaceIngressStateUpdate;
    const represented_heat_rate = liquid_heat_capacity_megajoules_per_m3_k * temperature * (matrix_rate + macropore_rate);
    const remainder = (state.heat_to_soil_megajoules_per_h[cell] - represented_heat_rate) * timestep_h;
    if (!std.math.isFinite(represented_heat_rate) or !std.math.isFinite(remainder)) return error.InvalidSurfaceIngressStateUpdate;
    return remainder;
}

pub const SurfacePartitionInputs = struct {
    rain_and_irrigation_m3_per_h: f64,
    intercepted_rain_m3_per_h: f64,
    snowfall_water_equivalent_m3_per_h: f64,
    snow_cover_fraction: f64,
    snow_free_fraction: f64,
    litter_cover_fraction: f64,
    litter_water_capacity_m3: f64,
    litter_water_m3: f64,
    litter_absent_above_water_table: bool,
    atmospheric_temperature_k: f64,
    matrix_fraction: f64,
    macropore_fraction: f64,
};

pub const SurfacePartition = struct {
    rain_to_snow_m3_per_h: f64,
    snow_to_snow_m3_per_h: f64,
    heat_to_snow_megajoules_per_h: f64,
    water_to_litter_m3_per_h: f64,
    water_to_matrix_m3_per_h: f64,
    water_to_macropore_m3_per_h: f64,
    heat_to_litter_megajoules_per_h: f64,
    heat_to_soil_megajoules_per_h: f64,
};

const fraction_sum_roundoff_ulps: f64 = 64.0;

fn fractionSumRoundoffTolerance(left: f64, right: f64) f64 {
    return fraction_sum_roundoff_ulps * std.math.floatEps(f64) *
        @max(1.0, @max(@abs(left), @abs(right)));
}

fn validComplementaryFractions(left: f64, right: f64) bool {
    return @abs(left + right - 1.0) <=
        fractionSumRoundoffTolerance(left, right);
}

/// WATSUB precipitation partition before the nonlinear soil solve. Physical
/// litter admission is limited by the current one-hour capacity gap; nonlinear
/// iteration ceilings are deliberately absent from this interface.
pub fn partitionAtmosphericWater(inputs: SurfacePartitionInputs, thermodynamics: ThermodynamicParameters) !SurfacePartition {
    try thermodynamics.validate();
    inline for (@typeInfo(SurfacePartitionInputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteSurfacePrecipitationInput;
    // TFLWC is signed: canopy water above its current capacity drains and
    // appears as negative retention, increasing water delivered below canopy.
    if (inputs.rain_and_irrigation_m3_per_h < 0 or inputs.intercepted_rain_m3_per_h > inputs.rain_and_irrigation_m3_per_h or inputs.snowfall_water_equivalent_m3_per_h < 0 or inputs.snow_cover_fraction < 0 or inputs.snow_cover_fraction > 1 or inputs.snow_free_fraction < 0 or inputs.snow_free_fraction > 1 or inputs.litter_cover_fraction < 0 or inputs.litter_cover_fraction > 1 or inputs.litter_water_capacity_m3 < 0 or inputs.litter_water_m3 < 0 or inputs.atmospheric_temperature_k <= 0 or inputs.matrix_fraction < 0 or inputs.macropore_fraction < 0 or !validComplementaryFractions(inputs.snow_cover_fraction, inputs.snow_free_fraction) or !validComplementaryFractions(inputs.matrix_fraction, inputs.macropore_fraction)) return error.InvalidSurfacePrecipitationInput;
    // Normalize only after scaled roundoff validation so accepted fractions
    // preserve exact water closure rather than leaking their representational
    // sum error into physical carriers.
    const snow_fraction_sum = inputs.snow_cover_fraction + inputs.snow_free_fraction;
    const snow_cover_fraction = inputs.snow_cover_fraction / snow_fraction_sum;
    const snow_free_fraction = inputs.snow_free_fraction / snow_fraction_sum;
    const pore_fraction_sum = inputs.matrix_fraction + inputs.macropore_fraction;
    const matrix_fraction = inputs.matrix_fraction / pore_fraction_sum;
    const macropore_fraction = inputs.macropore_fraction / pore_fraction_sum;
    const rain_after_interception = inputs.rain_and_irrigation_m3_per_h - inputs.intercepted_rain_m3_per_h;
    const rain_to_snow = rain_after_interception * snow_cover_fraction;
    const surface_water = rain_after_interception * snow_free_fraction;
    const water_to_litter = if (inputs.litter_absent_above_water_table)
        surface_water
    else
        @max(0.0, @min(surface_water * inputs.litter_cover_fraction, (inputs.litter_water_capacity_m3 - inputs.litter_water_m3) * snow_free_fraction));
    const water_to_soil = surface_water - water_to_litter;
    return .{
        .rain_to_snow_m3_per_h = rain_to_snow,
        .snow_to_snow_m3_per_h = inputs.snowfall_water_equivalent_m3_per_h,
        .heat_to_snow_megajoules_per_h = inputs.atmospheric_temperature_k * (thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * inputs.snowfall_water_equivalent_m3_per_h + thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * rain_to_snow),
        .water_to_litter_m3_per_h = water_to_litter,
        .water_to_matrix_m3_per_h = water_to_soil * matrix_fraction,
        .water_to_macropore_m3_per_h = water_to_soil * macropore_fraction,
        .heat_to_litter_megajoules_per_h = thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * inputs.atmospheric_temperature_k * water_to_litter,
        .heat_to_soil_megajoules_per_h = thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * inputs.atmospheric_temperature_k * water_to_soil,
    };
}

pub const SoluteRemainingDestination = enum { none, snow, soil };

pub const SolutePrecipitationRouting = struct {
    rain_to_litter_m3: f64,
    irrigation_to_litter_m3: f64,
    /// FLQGQ/FLQGI: the non-litter weather/irrigation carrier.  Its owner is
    /// snow when a snowpack is present or created this hour, otherwise soil.
    rain_remaining_m3: f64,
    irrigation_remaining_m3: f64,
    remaining_destination: SoluteRemainingDestination,
};

/// Exact FLQRQ/FLQRI/FLQGQ/FLQGI routing used by TRNSFR and TRNSFRS.
pub fn routePrecipitationSolutes(snowfall_m3_per_h: f64, rain_m3_per_h: f64, combined_rain_m3_per_h: f64, irrigation_m3_per_h: f64, water_to_litter_m3_per_h: f64, snow_heat_capacity_megajoules_per_k: f64, minimum_snow_heat_capacity_megajoules_per_k: f64, timestep_h: f64) !SolutePrecipitationRouting {
    inline for (.{ snowfall_m3_per_h, rain_m3_per_h, combined_rain_m3_per_h, irrigation_m3_per_h, water_to_litter_m3_per_h, snow_heat_capacity_megajoules_per_k, minimum_snow_heat_capacity_megajoules_per_k, timestep_h }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfacePrecipitationInput;
    if (snowfall_m3_per_h < 0 or rain_m3_per_h < 0 or combined_rain_m3_per_h < 0 or irrigation_m3_per_h < 0 or water_to_litter_m3_per_h < 0 or snow_heat_capacity_megajoules_per_k < 0 or minimum_snow_heat_capacity_megajoules_per_k < 0 or timestep_h <= 0) return error.InvalidSurfacePrecipitationInput;
    const combined_scale = @max(1.0, @max(combined_rain_m3_per_h, rain_m3_per_h + snowfall_m3_per_h));
    if (@abs(combined_rain_m3_per_h - (rain_m3_per_h + snowfall_m3_per_h)) >
        32 * std.math.floatEps(f64) * combined_scale)
        return error.SurfacePrecipitationWeatherCarrierMismatch;
    if (snowfall_m3_per_h > 0 or (rain_m3_per_h > 0 and snow_heat_capacity_megajoules_per_k > minimum_snow_heat_capacity_megajoules_per_k)) return .{
        .rain_to_litter_m3 = 0,
        .irrigation_to_litter_m3 = 0,
        .rain_remaining_m3 = combined_rain_m3_per_h * timestep_h,
        .irrigation_remaining_m3 = irrigation_m3_per_h * timestep_h,
        .remaining_destination = .snow,
    };
    const total_liquid = combined_rain_m3_per_h + irrigation_m3_per_h;
    if (total_liquid > 0 and snow_heat_capacity_megajoules_per_k <= minimum_snow_heat_capacity_megajoules_per_k) {
        // Negative TFLWC may add previously retained canopy water to FLWQBX.
        // That internal water has no atmospheric chemistry carrier.  Limit
        // only the source attribution (never a storage state) to the current
        // external volume so FLQG cannot become negative.
        const external_litter_m3_per_h = @min(water_to_litter_m3_per_h, total_liquid);
        const rain_to_litter = external_litter_m3_per_h * combined_rain_m3_per_h / total_liquid * timestep_h;
        const irrigation_to_litter = external_litter_m3_per_h * irrigation_m3_per_h / total_liquid * timestep_h;
        return .{
            .rain_to_litter_m3 = rain_to_litter,
            .irrigation_to_litter_m3 = irrigation_to_litter,
            .rain_remaining_m3 = combined_rain_m3_per_h * timestep_h - rain_to_litter,
            .irrigation_remaining_m3 = irrigation_m3_per_h * timestep_h - irrigation_to_litter,
            .remaining_destination = .soil,
        };
    }
    return .{
        .rain_to_litter_m3 = 0,
        .irrigation_to_litter_m3 = 0,
        .rain_remaining_m3 = 0,
        .irrigation_remaining_m3 = 0,
        .remaining_destination = .none,
    };
}

pub const RedistributionInputs = struct {
    soil_surface_present: bool,
    rain_and_irrigation_to_matrix_m3: f64,
    rain_and_irrigation_to_macropore_m3: f64,
    rain_and_irrigation_to_litter_m3: f64,
    matrix_air_capacity_m3: f64,
    macropore_air_capacity_m3: f64,
    snow_free_fraction: f64,
    atmospheric_temperature_k: f64,
    litter_input_heat_megajoules: f64,
    soil_input_heat_megajoules: f64,
};

pub const Redistribution = struct {
    litter_water_m3: f64,
    matrix_water_m3: f64,
    macropore_water_m3: f64,
    litter_heat_megajoules: f64,
    soil_heat_megajoules: f64,
};

pub fn redistribute(inputs: RedistributionInputs, thermodynamics: ThermodynamicParameters) !Redistribution {
    try thermodynamics.validate();
    inline for (@typeInfo(RedistributionInputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteSurfacePrecipitationInput;
    if (inputs.rain_and_irrigation_to_matrix_m3 < 0 or inputs.rain_and_irrigation_to_macropore_m3 < 0 or inputs.rain_and_irrigation_to_litter_m3 < 0 or inputs.matrix_air_capacity_m3 < 0 or inputs.macropore_air_capacity_m3 < 0 or inputs.snow_free_fraction < 0 or inputs.snow_free_fraction > 1 or inputs.atmospheric_temperature_k <= 0) return error.InvalidSurfacePrecipitationInput;
    if (!inputs.soil_surface_present) return .{ .litter_water_m3 = inputs.rain_and_irrigation_to_litter_m3, .matrix_water_m3 = inputs.rain_and_irrigation_to_matrix_m3, .macropore_water_m3 = inputs.rain_and_irrigation_to_macropore_m3, .litter_heat_megajoules = inputs.litter_input_heat_megajoules, .soil_heat_megajoules = inputs.soil_input_heat_megajoules };
    const matrix_excess = @max(0.0, inputs.rain_and_irrigation_to_matrix_m3 - inputs.matrix_air_capacity_m3 * inputs.snow_free_fraction);
    const macro_excess = @max(0.0, inputs.rain_and_irrigation_to_macropore_m3 - inputs.macropore_air_capacity_m3 * inputs.snow_free_fraction);
    const redirected_heat = thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * inputs.atmospheric_temperature_k * (matrix_excess + macro_excess);
    return .{ .litter_water_m3 = inputs.rain_and_irrigation_to_litter_m3 + matrix_excess + macro_excess, .matrix_water_m3 = inputs.rain_and_irrigation_to_matrix_m3 - matrix_excess, .macropore_water_m3 = inputs.rain_and_irrigation_to_macropore_m3 - macro_excess, .litter_heat_megajoules = inputs.litter_input_heat_megajoules + redirected_heat, .soil_heat_megajoules = inputs.soil_input_heat_megajoules - redirected_heat };
}

pub const GasExchangeParameters = struct {
    reference_time_h: f64,
    wet_exponent: f64,
    dry_exponent: f64,
    transition_water_fraction: f64,
    iteration_fraction: f64,
    aqueous_tortuosity_coefficient: f64,
};

pub const GasExchange = struct { air_water_rate_per_step: f64, aqueous_tortuosity: f64 };

pub fn litterGasExchange(total_pore_volume_m3: f64, physical_ice_volume_m3: f64, water_m3: f64, air_m3: f64, water_retention_capacity_m3: f64, parameters: GasExchangeParameters) !GasExchange {
    inline for (.{ total_pore_volume_m3, physical_ice_volume_m3, water_m3, air_m3, water_retention_capacity_m3 }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfacePrecipitationInput;
    inline for (@typeInfo(GasExchangeParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteSurfacePrecipitationInput;
    if (total_pore_volume_m3 < 0 or physical_ice_volume_m3 < 0 or water_m3 < 0 or air_m3 < 0 or water_retention_capacity_m3 < 0 or parameters.reference_time_h <= 0 or parameters.transition_water_fraction < 0 or parameters.transition_water_fraction > 1 or parameters.iteration_fraction < 0 or parameters.iteration_fraction > 1 or parameters.aqueous_tortuosity_coefficient < 0) return error.InvalidSurfacePrecipitationInput;
    const available_pores = total_pore_volume_m3 - physical_ice_volume_m3;
    var rate: f64 = 0;
    if (available_pores > 0 and air_m3 > 0) {
        const relative_water = std.math.clamp(water_m3 / available_pores, 0, 1);
        const exponent = if (relative_water > parameters.transition_water_fraction) parameters.wet_exponent else parameters.dry_exponent;
        const rate_per_h = 1.0 / ((1.0 / parameters.reference_time_h) * @exp(exponent * (relative_water - parameters.transition_water_fraction)));
        // WATSUB applied DFGS*XNPT explicitly inside repeated gas subcycles.
        // The full-hour local solve instead integrates the same first-order
        // kinetic rate exactly. This remains bounded and removes an artificial
        // donor-clamp discontinuity from the Newton/Picard residual.
        rate = -std.math.expm1(-@max(0.0, rate_per_h) * parameters.iteration_fraction);
    }
    const water_holding_fraction = if (water_retention_capacity_m3 > 0) @min(1.0, water_m3 / water_retention_capacity_m3) else 1.0;
    return .{ .air_water_rate_per_step = rate, .aqueous_tortuosity = parameters.aqueous_tortuosity_coefficient * water_holding_fraction * water_holding_fraction };
}

pub const RainfallImpactParameters = struct {
    direct_energy_intercept_j_per_mm: f64,
    direct_energy_log_coefficient_j_per_mm: f64,
    throughfall_energy_height_coefficient_j_per_mm_sqrt_m: f64,
    throughfall_energy_intercept_j_per_mm: f64,
    maximum_canopy_height_m: f64,
    ponding_attenuation_per_mm: f64,
    conductivity_damage_per_j_per_megagram_per_megagram: f64,
    conductivity_recovery_fraction_per_h: f64,
};

pub const RainfallImpactInputs = struct {
    direct_precipitation_mm_per_h: f64,
    throughfall_mm_per_h: f64,
    total_precipitation_mm_per_h: f64,
    canopy_height_m: f64,
    excess_surface_storage_m3: f64,
    ground_surface_retention_m3: f64,
    surface_area_m2: f64,
    bare_soil_fraction: f64,
    time_fraction: f64,
    surface_silt_megagrams_per_megagram: f64,
    surface_clay_megagrams_per_megagram: f64,
};

pub const RainfallImpact = struct { incremental_energy_j: f64, cumulative_energy_j: f64, saturated_conductivity_multiplier: f64 };

/// Exact WATSUB `ENGYP=ENGYP*(1-FENGYP*XNFH)` surface-conductivity
/// recovery. Energy is J m-2, the recovery coefficient is h-1, and the
/// timestep is h. Apply before adding current-timestep rainfall energy,
/// including on dry timesteps.
pub fn recoverRainfallImpactEnergy(previous_cumulative_energy_j_per_m2: f64, timestep_h: f64, recovery_fraction_per_h: f64) !f64 {
    inline for (.{ previous_cumulative_energy_j_per_m2, timestep_h, recovery_fraction_per_h }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfacePrecipitationInput;
    if (previous_cumulative_energy_j_per_m2 < 0 or timestep_h <= 0 or recovery_fraction_per_h < 0 or recovery_fraction_per_h * timestep_h > 1)
        return error.InvalidSurfacePrecipitationInput;
    const recovered = previous_cumulative_energy_j_per_m2 * (1.0 - recovery_fraction_per_h * timestep_h);
    if (!std.math.isFinite(recovered) or recovered < 0) return error.NonFiniteRainfallImpact;
    return recovered;
}

pub fn rainfallConductivityMultiplier(cumulative_energy_j_per_m2: f64, surface_silt_megagrams_per_megagram: f64, surface_clay_megagrams_per_megagram: f64, damage_per_j_per_megagram_per_megagram: f64) !f64 {
    inline for (.{ cumulative_energy_j_per_m2, surface_silt_megagrams_per_megagram, surface_clay_megagrams_per_megagram, damage_per_j_per_megagram_per_megagram }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfacePrecipitationInput;
    if (cumulative_energy_j_per_m2 < 0 or surface_silt_megagrams_per_megagram < 0 or surface_clay_megagrams_per_megagram < 0 or damage_per_j_per_megagram_per_megagram < 0)
        return error.InvalidSurfacePrecipitationInput;
    const multiplier = @exp(-damage_per_j_per_megagram_per_megagram * (surface_silt_megagrams_per_megagram + surface_clay_megagrams_per_megagram) * cumulative_energy_j_per_m2);
    if (!std.math.isFinite(multiplier)) return error.NonFiniteRainfallImpact;
    return multiplier;
}

pub fn rainfallImpact(previous_cumulative_energy_j: f64, inputs: RainfallImpactInputs, parameters: RainfallImpactParameters) !RainfallImpact {
    if (!std.math.isFinite(previous_cumulative_energy_j) or previous_cumulative_energy_j < 0) return error.InvalidSurfacePrecipitationInput;
    inline for (@typeInfo(RainfallImpactInputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteSurfacePrecipitationInput;
    inline for (@typeInfo(RainfallImpactParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteSurfacePrecipitationInput;
    if (inputs.direct_precipitation_mm_per_h < 0 or inputs.throughfall_mm_per_h < 0 or inputs.total_precipitation_mm_per_h <= 0 or inputs.canopy_height_m < 0 or inputs.excess_surface_storage_m3 < 0 or inputs.ground_surface_retention_m3 < 0 or inputs.surface_area_m2 <= 0 or inputs.bare_soil_fraction < 0 or inputs.bare_soil_fraction > 1 or inputs.time_fraction <= 0 or inputs.time_fraction > 1 or inputs.surface_silt_megagrams_per_megagram < 0 or inputs.surface_clay_megagrams_per_megagram < 0 or parameters.maximum_canopy_height_m < 0 or parameters.ponding_attenuation_per_mm < 0 or parameters.conductivity_damage_per_j_per_megagram_per_megagram < 0 or parameters.conductivity_recovery_fraction_per_h < 0) return error.InvalidSurfacePrecipitationInput;
    const direct_energy = if (inputs.direct_precipitation_mm_per_h > 0) @max(0.0, parameters.direct_energy_intercept_j_per_mm + parameters.direct_energy_log_coefficient_j_per_mm * @log(inputs.total_precipitation_mm_per_h)) else 0;
    const throughfall_energy = if (inputs.throughfall_mm_per_h > 0) @max(0.0, parameters.throughfall_energy_height_coefficient_j_per_mm_sqrt_m * @sqrt(@min(parameters.maximum_canopy_height_m, inputs.canopy_height_m)) - parameters.throughfall_energy_intercept_j_per_mm) else 0;
    const ponded_depth_mm = 1.0e3 * @max(0.0, inputs.excess_surface_storage_m3 - inputs.ground_surface_retention_m3) / inputs.surface_area_m2;
    const incremental = if (direct_energy + throughfall_energy > 0) (direct_energy * inputs.direct_precipitation_mm_per_h + throughfall_energy * inputs.throughfall_mm_per_h) * @exp(-parameters.ponding_attenuation_per_mm * ponded_depth_mm) * inputs.bare_soil_fraction * inputs.time_fraction else 0;
    const cumulative = previous_cumulative_energy_j + incremental;
    const multiplier = try rainfallConductivityMultiplier(cumulative, inputs.surface_silt_megagrams_per_megagram, inputs.surface_clay_megagrams_per_megagram, parameters.conductivity_damage_per_j_per_megagram_per_megagram);
    if (!std.math.isFinite(incremental) or !std.math.isFinite(cumulative) or !std.math.isFinite(multiplier)) return error.NonFiniteRainfallImpact;
    return .{ .incremental_energy_j = incremental, .cumulative_energy_j = cumulative, .saturated_conductivity_multiplier = multiplier };
}

test "the runtime snow cover carrier uses the WATSUB square-root relation" {
    // Regression guard for the exponent defect. `prepareFromModel` is the only
    // writer of `snow_cover_fraction`, and every consumer derives its snow-free
    // fraction as `1 - snow_cover_fraction`, so an inverted exponent here
    // silently mis-partitions rain, heat, and albedo for every thin-snow hour.
    // This test pins the delegation rather than re-deriving the formula.
    const owner = @import("../soil/water/snow_cover_fraction.zig");
    const full_cover_m = 0.07;
    const cover = try owner.evaluate(0.005, full_cover_m);
    // The value production used to produce at this depth.
    const previous_squared = std.math.pow(f64, 0.005 / full_cover_m, 2);
    try std.testing.expect(cover.snow_fraction > previous_squared * 50);
    // And the snow-free complement consumers compute stays a valid fraction.
    const snow_free = 1.0 - cover.snow_fraction;
    try std.testing.expectApproxEqAbs(cover.snow_free_fraction, snow_free, 1e-15);
    try std.testing.expect(snow_free > 0 and snow_free < 1);
}

test "precipitation exceeding pore air is redirected to litter with heat" {
    const result = try redistribute(.{ .soil_surface_present = true, .rain_and_irrigation_to_matrix_m3 = 0.3, .rain_and_irrigation_to_macropore_m3 = 0.2, .rain_and_irrigation_to_litter_m3 = 0.1, .matrix_air_capacity_m3 = 0.1, .macropore_air_capacity_m3 = 0.1, .snow_free_fraction = 1, .atmospheric_temperature_k = 280, .litter_input_heat_megajoules = 1, .soil_input_heat_megajoules = 10 }, test_thermodynamics);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), result.litter_water_m3, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result.matrix_water_m3, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result.macropore_water_m3, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 11), result.litter_heat_megajoules + result.soil_heat_megajoules, 1e-12);
}

test "runtime surface ingress retains separate rain snow litter and pore carriers" {
    var state = try RuntimeState.init(std.testing.allocator, 2);
    defer state.deinit();
    state.litter_water_capacity_m3[0] = 0.2;
    state.litter_water_capacity_m3[1] = 0.2;
    state.litter_cover_fraction[0] = 0.5;
    state.litter_cover_fraction[1] = 0.5;
    try prepareRuntimeIngress(&state, .{ .rainfall_m3_per_h = &.{ 1, 0.5 }, .snowfall_water_equivalent_m3_per_h = &.{ 0.2, 0 }, .intercepted_rain_m3_per_h = &.{ 0.1, 0 }, .snow_cover_fraction = &.{ 0.25, 0 }, .atmospheric_temperature_k = &.{ 280, 285 }, .matrix_fraction = &.{ 0.8, 0.7 }, .macropore_fraction = &.{ 0.2, 0.3 }, .matrix_air_capacity_m3 = &.{ 0.1, 1 }, .macropore_air_capacity_m3 = &.{ 0.1, 1 }, .litter_absent_above_water_table = &.{ false, false } }, test_thermodynamics);
    const first_liquid = state.rain_to_snow_m3_per_h[0] + state.water_to_litter_m3_per_h[0] + state.water_to_matrix_m3_per_h[0] + state.water_to_macropore_m3_per_h[0];
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), first_liquid, 1.0e-12);
    try state_updateRuntimeIngress(&state, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2) + state.rain_to_snow_m3_per_h[0], state.solid_snow_water_equivalent_m3[0], 1.0e-12);
    try std.testing.expect(state.litter_water_m3[0] > 0);
}

test "top-soil ingress state_update validates every runtime cell before mutation" {
    const config = try @import("../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try @import("../state/grid.zig").GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var hydrology = try @import("../transport/hydrology.zig").State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    var state = try RuntimeState.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(grid.matrix_pore_capacity_m3, 1);
    @memset(grid.macropore_pore_capacity_m3, 1);
    @memset(grid.matrix_air_volume_m3, 1);
    @memset(grid.macropore_air_volume_m3, 1);
    @memset(grid.air_volume_m3, 2);
    state.water_to_matrix_m3_per_h[0] = 0.2;
    state.water_to_matrix_m3_per_h[1] = 2;
    try std.testing.expectError(error.InvalidSurfaceIngressStateUpdate, state_updateSoilIngress(&state, &grid, &hydrology, 1, 0.917));
    try std.testing.expectEqual(@as(f64, 0), grid.matrix_liquid_water_m3[0]);
    state.water_to_matrix_m3_per_h[1] = 0.3;
    state.water_to_macropore_m3_per_h[1] = 0.4;
    try state_updateSoilIngress(&state, &grid, &hydrology, 1, 0.917);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), grid.matrix_liquid_water_m3[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), grid.liquid_water_m3[1], 1e-15);
    try std.testing.expectApproxEqAbs(grid.matrix_liquid_water_m3[1], hydrology.micropore_water_volume_m3[1], 1e-15);
}

test "direct litter precipitation heat closes before separately heated snow at every substep" {
    const snow_heat = @import("../soil/water/snow_surface_transfer_heat.zig");
    var state = try RuntimeState.init(std.testing.allocator, 3);
    defer state.deinit();
    const areas = [_]f64{ 0.5, 1, 3 };
    const liquid_capacity: f64 = 4.19;
    const dry_capacity_per_area: f64 = 2.496e-6 * 0.09658210019802958;
    const vapor_water_per_area: f64 = 0.01779133424860828 * 18 / 1e6;
    const rain_temperature = [_]f64{ 287.75, 275.15, 295.15 };
    var direct_water_rate: [3]f64 = undefined;
    var snow_water_rate: [3]f64 = undefined;
    var temperature = [_]f64{ 281.677966962551, 289.15, 278.15 };
    var gas_temperature = temperature;
    var accepted_temperature = temperature;
    var capacity: [3]f64 = undefined;
    for (areas, 0..) |area, cell| {
        state.litter_water_m3[cell] = 0.0006411606959533904 * area;
        direct_water_rate[cell] = 0.0003037676209287055 * area;
        snow_water_rate[cell] = 0.00012 * area;
        state.water_to_litter_m3_per_h[cell] = direct_water_rate[cell] + snow_water_rate[cell];
        state.heat_to_litter_megajoules_per_h[cell] = liquid_capacity * rain_temperature[cell] * direct_water_rate[cell];
        capacity[cell] = dry_capacity_per_area * area + liquid_capacity * (state.litter_water_m3[cell] + vapor_water_per_area * area);
    }
    // Use the actual production water publisher and snow recipient candidate
    // in their coupled-substep order. The first failing Ottawa surface hour
    // demonstrates why direct rain must have its own intervening heat owner.
    for ([_]f64{ 0.0625, 0.1875, 0.25, 0.5 }) |dt| {
        var before: [3]f64 = undefined;
        for (areas, 0..) |area, cell|
            before[cell] = (dry_capacity_per_area * area + liquid_capacity * (state.litter_water_m3[cell] + vapor_water_per_area * area)) * temperature[cell];
        try state_updateLitterIngress(&state, dt);
        try state_updateLitterHeatIngress(&state, &direct_water_rate, .{
            .heat_capacity_megajoules_per_k = &capacity,
            .surface_temperature_k = &temperature,
            .gas_temperature_k = &gas_temperature,
            .accepted_temperature_k = &accepted_temperature,
        }, dt, liquid_capacity);
        try std.testing.expectEqualSlices(f64, &temperature, &gas_temperature);
        try std.testing.expectEqualSlices(f64, &temperature, &accepted_temperature);
        for (areas, 0..) |area, cell| {
            const snow_water = snow_water_rate[cell] * dt;
            const snow_input_heat = liquid_capacity * 273.15 * snow_water;
            const candidate = try snow_heat.acceptedLitterCandidate(capacity[cell], temperature[cell], snow_water, snow_input_heat, liquid_capacity);
            capacity[cell] = candidate.heat_capacity_megajoules_per_k;
            temperature[cell] = candidate.temperature_k;
            const actual_capacity = dry_capacity_per_area * area + liquid_capacity * (state.litter_water_m3[cell] + vapor_water_per_area * area);
            const after = actual_capacity * temperature[cell];
            const expected = before[cell] + state.heat_to_litter_megajoules_per_h[cell] * dt + snow_input_heat;
            try std.testing.expectApproxEqAbs(expected, after, 2e-14 * area);
            try std.testing.expectApproxEqAbs(actual_capacity, capacity[cell], 2e-17 * area);
        }
    }
}

test "direct litter precipitation heat starts dry carriers and preserves zero-input mirrors" {
    var state = try RuntimeState.init(std.testing.allocator, 2);
    defer state.deinit();
    const liquid_capacity: f64 = 5.7;
    const direct_water = [_]f64{ 0.002, 0 };
    state.litter_water_m3[0] = 0.001;
    state.heat_to_litter_megajoules_per_h[0] = liquid_capacity * 300 * direct_water[0];
    const water_before = try std.testing.allocator.dupe(f64, state.litter_water_m3);
    defer std.testing.allocator.free(water_before);
    var capacity = [_]f64{ 0, 0 };
    var temperature = [_]f64{ 270, 280 };
    var gas_temperature = [_]f64{ 271, 281 };
    var accepted_temperature = [_]f64{ 272, 282 };
    try state_updateLitterHeatIngress(&state, &direct_water, .{
        .heat_capacity_megajoules_per_k = &capacity,
        .surface_temperature_k = &temperature,
        .gas_temperature_k = &gas_temperature,
        .accepted_temperature_k = &accepted_temperature,
    }, 0.5, liquid_capacity);
    try std.testing.expectEqualSlices(f64, water_before, state.litter_water_m3);
    try std.testing.expectApproxEqAbs(liquid_capacity * 0.001, capacity[0], 1e-17);
    try std.testing.expectApproxEqAbs(@as(f64, 300), temperature[0], 1e-12);
    try std.testing.expectEqual(temperature[0], gas_temperature[0]);
    try std.testing.expectEqual(temperature[0], accepted_temperature[0]);
    try std.testing.expectEqual(@as(f64, 0), capacity[1]);
    try std.testing.expectEqual(@as(f64, 280), temperature[1]);
    try std.testing.expectEqual(@as(f64, 281), gas_temperature[1]);
    try std.testing.expectEqual(@as(f64, 282), accepted_temperature[1]);
}

test "direct litter precipitation heat rejects invalid final lanes without partial publication" {
    var state = try RuntimeState.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.heat_to_litter_megajoules_per_h, 1.2);
    var water_rate = [_]f64{ 0.001, 0.001 };
    var capacity = [_]f64{ 0.004, 0.008 };
    var temperature = [_]f64{ 280, 290 };
    var gas_temperature = [_]f64{ 281, 291 };
    var accepted_temperature = [_]f64{ 282, 292 };
    const destination: LitterHeatDestinations = .{
        .heat_capacity_megajoules_per_k = &capacity,
        .surface_temperature_k = &temperature,
        .gas_temperature_k = &gas_temperature,
        .accepted_temperature_k = &accepted_temperature,
    };
    const before_capacity = capacity;
    const before_temperature = temperature;
    const before_gas = gas_temperature;
    const before_accepted = accepted_temperature;
    for (0..6) |invalid_case| {
        water_rate[1] = 0.001;
        state.heat_to_litter_megajoules_per_h[1] = 1.2;
        capacity[1] = before_capacity[1];
        temperature[1] = before_temperature[1];
        switch (invalid_case) {
            0 => state.heat_to_litter_megajoules_per_h[1] = std.math.nan(f64),
            1 => water_rate[1] = -0.001,
            2 => capacity[1] = -0.008,
            3 => temperature[1] = 0,
            4 => water_rate[1] = 0, // No water may carry nonzero rain heat.
            5 => state.heat_to_litter_megajoules_per_h[1] = 0,
            else => unreachable,
        }
        const invalid_capacity = capacity;
        const invalid_temperature = temperature;
        try std.testing.expectError(error.InvalidSurfaceIngressStateUpdate, state_updateLitterHeatIngress(&state, &water_rate, destination, 0.5, 4.19));
        try std.testing.expectEqualSlices(f64, &invalid_capacity, &capacity);
        try std.testing.expectEqualSlices(f64, &invalid_temperature, &temperature);
        try std.testing.expectEqualSlices(f64, &before_gas, &gas_temperature);
        try std.testing.expectEqualSlices(f64, &before_accepted, &accepted_temperature);
    }
    try std.testing.expectError(error.InvalidSurfaceIngressTimestep, state_updateLitterHeatIngress(&state, &water_rate, destination, 0, 4.19));
    try std.testing.expectError(error.InvalidSurfaceIngressHeatCapacity, state_updateLitterHeatIngress(&state, &water_rate, destination, 0.5, 0));
    try std.testing.expectError(error.SurfaceIngressDimensionMismatch, state_updateLitterHeatIngress(&state, &.{0.001}, destination, 0.5, 4.19));
}

test "direct precipitation heat pairs with current soil ingress carrier at every substep" {
    const config = try @import("../core/config.zig").SimulationConfig.init(.{ .lon_count = 3, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 3 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try @import("../state/grid.zig").GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var hydrology = try @import("../transport/hydrology.zig").State.init(std.testing.allocator, 3, 1, 2, 1);
    defer hydrology.deinit();
    var state = try RuntimeState.init(std.testing.allocator, 3);
    defer state.deinit();
    @memcpy(grid.active_soil_layer_count, &[_]usize{ 1, 2, 1 });
    const areas = [_]f64{ 0.5, 1, 3 };
    const donor_temperatures = [_]f64{ 275, 285, 301 };
    for ([_]f64{ 4.19, 3.87 }) |liquid_heat_capacity| {
        for ([_]usize{ 1, 4, 20 }) |substeps| {
            @memset(grid.matrix_liquid_water_m3, 0);
            @memset(grid.macropore_liquid_water_m3, 0);
            @memset(grid.liquid_water_m3, 0);
            @memset(grid.matrix_ice_water_m3, 0);
            @memset(grid.macropore_ice_water_m3, 0);
            @memset(grid.matrix_pore_capacity_m3, 1);
            @memset(grid.macropore_pore_capacity_m3, 1);
            for (areas, 0..) |area, cell| {
                const top = cell * grid.soil_layer_capacity;
                grid.matrix_liquid_water_m3[top] = 0.01 * area;
                grid.macropore_liquid_water_m3[top] = 0.002 * area;
                grid.liquid_water_m3[top] = 0.012 * area;
                state.water_to_matrix_m3_per_h[cell] = 1e-5 * area;
                state.water_to_macropore_m3_per_h[cell] = 5e-6 * area;
                state.heat_to_soil_megajoules_per_h[cell] = liquid_heat_capacity *
                    donor_temperatures[cell] * 1.5e-5 * area;
            }
            const dt = 1 / @as(f64, @floatFromInt(substeps));
            for (0..substeps) |step| {
                var source = [_]f64{0.05} ** 6;
                var before_liquid_heat: [3]f64 = undefined;
                for (0..3) |cell| {
                    const top = cell * grid.soil_layer_capacity;
                    // Changed accepted recipient temperatures require fresh
                    // pricing; a remainder frozen at hour entry cannot pass.
                    grid.soil_temperature_k[top] = 280 + 4 * @as(f64, @floatFromInt(cell)) +
                        0.125 * @as(f64, @floatFromInt(step));
                    before_liquid_heat[cell] = liquid_heat_capacity * grid.soil_temperature_k[top] *
                        (grid.matrix_liquid_water_m3[top] + grid.macropore_liquid_water_m3[top]);
                }
                try bindSoilHeatIngress(&state, &grid, &source, 1, liquid_heat_capacity);
                try state_updateSoilIngress(&state, &grid, &hydrology, dt, 0.917);
                for (0..3) |cell| {
                    const top = cell * grid.soil_layer_capacity;
                    const after_liquid_heat = liquid_heat_capacity * grid.soil_temperature_k[top] *
                        (grid.matrix_liquid_water_m3[top] + grid.macropore_liquid_water_m3[top]);
                    // Solids, ice and vapor are unchanged by these owners.
                    // Their canonical enthalpy cancels, leaving this exact
                    // independent water-carrier plus heat-source balance.
                    const received_heat = after_liquid_heat - before_liquid_heat[cell] +
                        dt * (source[top] - 0.05);
                    try std.testing.expectApproxEqAbs(
                        state.heat_to_soil_megajoules_per_h[cell] * dt,
                        received_heat,
                        1e-12,
                    );
                    try std.testing.expectEqual(@as(f64, 0.05), source[top + 1]);
                    try std.testing.expectEqual(grid.matrix_liquid_water_m3[top], hydrology.micropore_water_volume_m3[top]);
                    try std.testing.expectEqual(grid.macropore_liquid_water_m3[top], hydrology.macropore_water_volume_m3[top]);
                }
            }
        }
    }
}

test "direct precipitation heat rejects invalid final cells before any source publication" {
    const config = try @import("../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try @import("../state/grid.zig").GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var state = try RuntimeState.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(grid.soil_temperature_k, 285);
    @memset(state.water_to_matrix_m3_per_h, 1e-5);
    @memset(state.heat_to_soil_megajoules_per_h, 4.19 * 280 * 1e-5);
    const original = [_]f64{ 0.5, 0.75 };
    var source = original;
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -1 }) |invalid| {
        state.water_to_macropore_m3_per_h[1] = invalid;
        try std.testing.expectError(error.InvalidSurfaceIngressStateUpdate, bindSoilHeatIngress(&state, &grid, &source, 1, 4.19));
        try std.testing.expectEqualSlices(f64, &original, &source);
    }
    state.water_to_macropore_m3_per_h[1] = 0;
    state.heat_to_soil_megajoules_per_h[1] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidSurfaceIngressStateUpdate, bindSoilHeatIngress(&state, &grid, &source, 1, 4.19));
    try std.testing.expectEqualSlices(f64, &original, &source);
    state.heat_to_soil_megajoules_per_h[1] = 4.19 * 280 * 1e-5;
    try std.testing.expectError(error.InvalidSurfaceIngressHeatCapacity, bindSoilHeatIngress(&state, &grid, &source, 1, 0));
    try std.testing.expectEqualSlices(f64, &original, &source);
    try bindSoilHeatIngress(&state, &grid, &source, 1, 4.19);
    try std.testing.expect(source[0] < original[0] and source[1] < original[1]);
    @memset(state.water_to_matrix_m3_per_h, 0);
    @memset(state.heat_to_soil_megajoules_per_h, 0);
    source = original;
    try bindSoilHeatIngress(&state, &grid, &source, 1, 4.19);
    try std.testing.expectEqualSlices(f64, &original, &source);
}

test "direct precipitation heat excludes the separately heated snow ingress" {
    const config = try @import("../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try @import("../state/grid.zig").GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var hydrology = try @import("../transport/hydrology.zig").State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    var state = try RuntimeState.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(grid.soil_temperature_k, 282);
    @memset(grid.matrix_pore_capacity_m3, 1);
    @memset(grid.macropore_pore_capacity_m3, 1);
    @memset(grid.matrix_liquid_water_m3, 0.01);
    @memset(grid.liquid_water_m3, 0.01);
    var direct_matrix_rates = [_]f64{ 2e-5, 0 };
    var direct_macropore_rates = [_]f64{ 1e-5, 0 };
    const snow_rates = [_]f64{ 0.001, 0.002 };
    const dt = 0.05;
    const liquid_heat_capacity = 4.19;
    for (0..2) |cell| {
        state.water_to_matrix_m3_per_h[cell] = direct_matrix_rates[cell] + snow_rates[cell];
        state.water_to_macropore_m3_per_h[cell] = direct_macropore_rates[cell];
        state.heat_to_soil_megajoules_per_h[cell] = liquid_heat_capacity * 289 *
            (direct_matrix_rates[cell] + direct_macropore_rates[cell]);
    }
    var direct = state;
    direct.water_to_matrix_m3_per_h = &direct_matrix_rates;
    direct.water_to_macropore_m3_per_h = &direct_macropore_rates;
    var source = [_]f64{ 0, 0 };
    try bindSoilHeatIngress(&direct, &grid, &source, 1, liquid_heat_capacity);
    try std.testing.expectEqual(@as(f64, 0), source[1]);
    try state_updateSoilIngress(&state, &grid, &hydrology, dt, 0.917);
    for (0..2) |cell| {
        const snow_water = snow_rates[cell] * dt;
        const snow_heat = liquid_heat_capacity * 274 * snow_water;
        source[cell] += try @import("../soil/water/snow_surface_transfer_heat.zig").acceptedTopsoilHeatRemainder(
            snow_water,
            snow_heat,
            grid.soil_temperature_k[cell],
            liquid_heat_capacity,
        ) / dt;
        const carrier_heat = liquid_heat_capacity * grid.soil_temperature_k[cell] *
            (grid.matrix_liquid_water_m3[cell] + grid.macropore_liquid_water_m3[cell] - 0.01);
        try std.testing.expectApproxEqAbs(state.heat_to_soil_megajoules_per_h[cell] * dt + snow_heat, carrier_heat + source[cell] * dt, 1e-12);
        try std.testing.expectEqual(direct_matrix_rates[cell] + snow_rates[cell], state.water_to_matrix_m3_per_h[cell]);
    }
}

test "atmospheric rain snow litter and pore partition conserves liquid water and heat" {
    const result = try partitionAtmosphericWater(.{ .rain_and_irrigation_m3_per_h = 1, .intercepted_rain_m3_per_h = 0.1, .snowfall_water_equivalent_m3_per_h = 0.2, .snow_cover_fraction = 0.25, .snow_free_fraction = 0.75, .litter_cover_fraction = 0.5, .litter_water_capacity_m3 = 1, .litter_water_m3 = 0.9, .litter_absent_above_water_table = false, .atmospheric_temperature_k = 280, .matrix_fraction = 0.8, .macropore_fraction = 0.2 }, test_thermodynamics);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), result.rain_to_snow_m3_per_h + result.water_to_litter_m3_per_h + result.water_to_matrix_m3_per_h + result.water_to_macropore_m3_per_h, 1e-12);
    try std.testing.expectApproxEqAbs(4.19 * 280 * 0.9 + 2.095 * 280 * 0.2, result.heat_to_snow_megajoules_per_h + result.heat_to_litter_megajoules_per_h + result.heat_to_soil_megajoules_per_h, 1e-10);
}

test "precipitation heat uses explicit non-default thermodynamic coefficients" {
    const thermodynamics: ThermodynamicParameters = .{
        .solid_snow_heat_capacity_megajoules_per_m3_k = 3.25,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 5.5,
    };
    const temperature_k = 280.0;
    const result = try partitionAtmosphericWater(.{
        .rain_and_irrigation_m3_per_h = 1,
        .intercepted_rain_m3_per_h = 0,
        .snowfall_water_equivalent_m3_per_h = 0.2,
        .snow_cover_fraction = 0.25,
        .snow_free_fraction = 0.75,
        .litter_cover_fraction = 0,
        .litter_water_capacity_m3 = 0,
        .litter_water_m3 = 0,
        .litter_absent_above_water_table = false,
        .atmospheric_temperature_k = temperature_k,
        .matrix_fraction = 0.8,
        .macropore_fraction = 0.2,
    }, thermodynamics);
    const expected = temperature_k * (thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k +
        thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * 0.2);
    try std.testing.expectApproxEqAbs(expected, result.heat_to_snow_megajoules_per_h + result.heat_to_litter_megajoules_per_h + result.heat_to_soil_megajoules_per_h, 1e-12);
}

test "nonlinear iteration ceilings cannot affect precipitation partition physics" {
    inline for (@typeInfo(SurfacePartitionInputs).@"struct".fields) |field|
        try std.testing.expect(!std.mem.eql(u8, field.name, "maximum_iterations"));
    inline for (@typeInfo(RuntimeInputs).@"struct".fields) |field|
        try std.testing.expect(!std.mem.eql(u8, field.name, "maximum_iterations"));

    const result = try partitionAtmosphericWater(.{
        .rain_and_irrigation_m3_per_h = 1,
        .intercepted_rain_m3_per_h = 0,
        .snowfall_water_equivalent_m3_per_h = 0,
        .snow_cover_fraction = 0,
        .snow_free_fraction = 1,
        .litter_cover_fraction = 1,
        .litter_water_capacity_m3 = 0.2,
        .litter_water_m3 = 0.15,
        .litter_absent_above_water_table = false,
        .atmospheric_temperature_k = 280,
        .matrix_fraction = 0.8,
        .macropore_fraction = 0.2,
    }, test_thermodynamics);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), result.water_to_litter_m3_per_h, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.water_to_litter_m3_per_h + result.water_to_matrix_m3_per_h + result.water_to_macropore_m3_per_h, 1e-15);
}

test "partition fraction sums use scaled roundoff validation and normalized closure" {
    const roundoff = 8.0 * std.math.floatEps(f64);
    const result = try partitionAtmosphericWater(.{
        .rain_and_irrigation_m3_per_h = 1,
        .intercepted_rain_m3_per_h = 0.1,
        .snowfall_water_equivalent_m3_per_h = 0,
        .snow_cover_fraction = 0.25,
        .snow_free_fraction = 0.75 + roundoff,
        .litter_cover_fraction = 0,
        .litter_water_capacity_m3 = 0,
        .litter_water_m3 = 0,
        .litter_absent_above_water_table = false,
        .atmospheric_temperature_k = 280,
        .matrix_fraction = 0.8,
        .macropore_fraction = 0.2 + roundoff,
    }, test_thermodynamics);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), result.rain_to_snow_m3_per_h + result.water_to_matrix_m3_per_h + result.water_to_macropore_m3_per_h, 4.0 * std.math.floatEps(f64));

    try std.testing.expectError(error.InvalidSurfacePrecipitationInput, partitionAtmosphericWater(.{
        .rain_and_irrigation_m3_per_h = 1,
        .intercepted_rain_m3_per_h = 0,
        .snowfall_water_equivalent_m3_per_h = 0,
        .snow_cover_fraction = 0,
        .snow_free_fraction = 1,
        .litter_cover_fraction = 0,
        .litter_water_capacity_m3 = 0,
        .litter_water_m3 = 0,
        .litter_absent_above_water_table = false,
        .atmospheric_temperature_k = 280,
        .matrix_fraction = 0.8,
        .macropore_fraction = 0.200001,
    }, test_thermodynamics));
}

test "solute precipitation routing follows snow presence and dry-surface branches" {
    const snow = try routePrecipitationSolutes(0.1, 0.5, 0.6, 0.4, 0.2, 0, 0, 0.5);
    try std.testing.expectEqual(@as(f64, 0), snow.rain_to_litter_m3);
    try std.testing.expectEqual(SoluteRemainingDestination.snow, snow.remaining_destination);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), snow.rain_remaining_m3, 1e-12);
    const surface = try routePrecipitationSolutes(0, 0.6, 0.6, 0.4, 0.2, 0, 0, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), surface.rain_to_litter_m3, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.04), surface.irrigation_to_litter_m3, 1e-12);
    try std.testing.expectEqual(SoluteRemainingDestination.soil, surface.remaining_destination);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), surface.rain_remaining_m3 + surface.irrigation_remaining_m3 + surface.rain_to_litter_m3 + surface.irrigation_to_litter_m3, 1e-12);
}

test "canopy drainage carries no new atmospheric chemistry and cannot make FLQG negative" {
    const dry_drainage = try routePrecipitationSolutes(0, 0, 0, 0, 0.3, 0, 1, 1);
    try std.testing.expectEqual(SoluteRemainingDestination.none, dry_drainage.remaining_destination);
    try std.testing.expectEqual(@as(f64, 0), dry_drainage.rain_to_litter_m3 + dry_drainage.irrigation_to_litter_m3 + dry_drainage.rain_remaining_m3 + dry_drainage.irrigation_remaining_m3);

    const rain_plus_drainage = try routePrecipitationSolutes(0, 0.6, 0.6, 0.4, 1.25, 0, 1, 1);
    try std.testing.expectEqual(SoluteRemainingDestination.soil, rain_plus_drainage.remaining_destination);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), rain_plus_drainage.rain_to_litter_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), rain_plus_drainage.irrigation_to_litter_m3, 1e-15);
    try std.testing.expectEqual(@as(f64, 0), rain_plus_drainage.rain_remaining_m3);
    try std.testing.expectEqual(@as(f64, 0), rain_plus_drainage.irrigation_remaining_m3);
}

test "rainfall impact attenuates conductivity and accumulates after recovery" {
    const recovered = try recoverRainfallImpactEnergy(10, 1, 5.0e-4);
    const result = try rainfallImpact(recovered, .{ .direct_precipitation_mm_per_h = 2, .throughfall_mm_per_h = 1, .total_precipitation_mm_per_h = 3, .canopy_height_m = 2, .excess_surface_storage_m3 = 0, .ground_surface_retention_m3 = 0, .surface_area_m2 = 1, .bare_soil_fraction = 1, .time_fraction = 1, .surface_silt_megagrams_per_megagram = 0.2, .surface_clay_megagrams_per_megagram = 0.2 }, .{ .direct_energy_intercept_j_per_mm = 8.95, .direct_energy_log_coefficient_j_per_mm = 8.44, .throughfall_energy_height_coefficient_j_per_mm_sqrt_m = 15.8, .throughfall_energy_intercept_j_per_mm = 5.87, .maximum_canopy_height_m = 2.5, .ponding_attenuation_per_mm = 2, .conductivity_damage_per_j_per_megagram_per_megagram = 1e-3, .conductivity_recovery_fraction_per_h = 5.0e-4 });
    try std.testing.expectApproxEqAbs(@as(f64, 9.995), recovered, 2.0e-15);
    try std.testing.expect(result.incremental_energy_j > 0);
    try std.testing.expect(result.cumulative_energy_j > recovered);
    try std.testing.expect(result.saturated_conductivity_multiplier > 0 and result.saturated_conductivity_multiplier < 1);
}

test "WATSUB rainfall impact recovery advances on dry hours and rejects overshoot" {
    try std.testing.expectApproxEqAbs(@as(f64, 37.48125), try recoverRainfallImpactEnergy(37.5, 1, 5.0e-4), 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 37.490625), try recoverRainfallImpactEnergy(37.5, 0.5, 5.0e-4), 1.0e-14);
    try std.testing.expectError(error.InvalidSurfacePrecipitationInput, recoverRainfallImpactEnergy(1, 2, 0.6));
    try std.testing.expectError(error.NonFiniteSurfacePrecipitationInput, recoverRainfallImpactEnergy(std.math.nan(f64), 1, 5.0e-4));
}

test "litter gas exchange response is bounded on dry branch" {
    const result = try litterGasExchange(1, 0, 0.1, 0.9, 0.5, .{ .reference_time_h = 1, .wet_exponent = 2, .dry_exponent = -2, .transition_water_fraction = 0.5, .iteration_fraction = 1, .aqueous_tortuosity_coefficient = 0.7 });
    try std.testing.expect(result.air_water_rate_per_step >= 0 and result.air_water_rate_per_step <= 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.028), result.aqueous_tortuosity, 1e-12);
}

test "whole-step gas exchange integrates legacy substep kinetics exponentially" {
    const result = try litterGasExchange(1, 0, 0.8, 0.2, 1, .{
        .reference_time_h = 2,
        .wet_exponent = 0,
        .dry_exponent = 0,
        .transition_water_fraction = 0.5,
        .iteration_fraction = 1,
        .aqueous_tortuosity_coefficient = 0.7,
    });
    try std.testing.expectApproxEqAbs(-std.math.expm1(@as(f64, -2.0)), result.air_water_rate_per_step, 1e-15);
    try std.testing.expect(result.air_water_rate_per_step < 1);
}

test "litter-soil flux uses litter donor temperature when flow is into soil" {
    const litter_parameters = try retention.carselParrishDefault(.silt_loam, 0.8);
    const soil_parameters = try retention.carselParrishDefault(.loam, null);
    const result = try surface_water_flow.litterSoilFlux(.{
        .litter_water_m3 = 0.7,
        .soil_matrix_water_m3 = 0.2,
        .litter_air_m3 = 0.1,
        .soil_matrix_air_m3 = 0.5,
        .litter_volume_m3 = 1,
        .soil_matrix_bulk_volume_m3 = 1,
        // Water content alone does not order two pools by potential: the
        // litter's theta_s is 0.8, so it must be near-saturated on its own
        // curve to sit above a soil at theta = 0.2.
        .litter_water_fraction = 0.7,
        .soil_water_fraction = 0.2,
        .litter_parameters = litter_parameters,
        .soil_parameters = soil_parameters,
        .litter_external_water_potential_megapascal = 0,
        .soil_external_water_potential_megapascal = 0,
        .litter_thickness_m = 0.05,
        .soil_thickness_m = 0.05,
        .soil_face_area_m2 = 1,
        .litter_cover_fraction = 1,
        .wet_litter_cover_fraction = 1,
        .time_fraction = 1,
        .soil_excess_pore_volume_m3 = 0,
        .litter_temperature_k = 300,
        .soil_temperature_k = 280,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 5.5,
    });
    // The wetter litter is at the higher (less negative) matric potential on
    // its own curve, so water must move down into the drier soil.
    try std.testing.expect(result.water_m3 > 0);
    try std.testing.expectApproxEqAbs(
        5.5 * 300 * result.water_m3,
        result.convective_heat_megajoules,
        1e-12,
    );
}

test "litter-soil flux uses soil donor temperature when flow is upward" {
    const litter_parameters = try retention.carselParrishDefault(.silt_loam, 0.8);
    const soil_parameters = try retention.carselParrishDefault(.silt_loam, 0.8);
    const inputs = surface_water_flow.LitterSoilInputs{
        .litter_water_m3 = 0.2,
        .soil_matrix_water_m3 = 1,
        .litter_air_m3 = 0.5,
        .soil_matrix_air_m3 = 0.5,
        .litter_volume_m3 = 1,
        .soil_matrix_bulk_volume_m3 = 1,
        .litter_water_fraction = 0.2,
        .soil_water_fraction = 0.4,
        .litter_parameters = litter_parameters,
        .soil_parameters = soil_parameters,
        .litter_external_water_potential_megapascal = 0,
        .soil_external_water_potential_megapascal = 0,
        .litter_thickness_m = 0.05,
        .soil_thickness_m = 0.05,
        .soil_face_area_m2 = 1,
        .litter_cover_fraction = 1,
        .wet_litter_cover_fraction = 1,
        .time_fraction = 1,
        .soil_excess_pore_volume_m3 = 0,
        .litter_temperature_k = 300,
        .soil_temperature_k = 280,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    };
    const result = try surface_water_flow.litterSoilFlux(inputs);
    try std.testing.expect(result.water_m3 <= 0);
    try std.testing.expectApproxEqAbs(
        4.19 * 280 * result.water_m3,
        result.convective_heat_megajoules,
        1e-15,
    );
}
