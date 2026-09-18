const std = @import("std");
const SimulationConfig = @import("../core/config.zig").SimulationConfig;

/// Structure-of-arrays storage keeps individual science kernels contiguous and
/// makes a later GPU backend possible without changing the scientific API.
pub const GridState = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    layer_count: usize,
    soil_layer_capacity: usize,
    active_soil_layer_count: []usize,
    /// Maximum-rooting-layer bound per cell (Fortran oracle's `NJ`, read from
    /// the soil file's `maximum_rooting_layer_index` header field, expressed
    /// in the same 0-based, surface-relative layer numbering as every other
    /// per-layer array here). Distinct from `active_soil_layer_count` (the
    /// oracle's `NL`, the total soil-column layer count including described
    /// and extrapolated layers below the rooting zone). Root-zone-bounded
    /// disturbance handlers (e.g. tillage root/litter mixing) must loop over
    /// this field, not `active_soil_layer_count`, to match `grosub.f`'s
    /// `DO L=NU,NJ` bound.
    maximum_rooting_layer_count: []usize,
    soil_temperature_k: []f64,
    liquid_water_m3: []f64,
    ice_water_m3: []f64,
    matrix_liquid_water_m3: []f64,
    macropore_liquid_water_m3: []f64,
    matrix_ice_water_m3: []f64,
    macropore_ice_water_m3: []f64,
    matrix_pore_capacity_m3: []f64,
    macropore_pore_capacity_m3: []f64,
    matrix_air_volume_m3: []f64,
    macropore_air_volume_m3: []f64,
    air_volume_m3: []f64,
    water_vapor_volume_m3: []f64,
    matric_potential_megapascal: []f64,
    surface_temperature_k: []f64,

    pub fn init(allocator: std.mem.Allocator, cfg: SimulationConfig) !GridState {
        try cfg.validate();
        const cell_count = try std.math.mul(usize, cfg.lon_count, cfg.lat_count);
        const layer_count = try std.math.mul(usize, cell_count, cfg.soil_layers);
        const soil_temperature_k = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(soil_temperature_k);
        const liquid_water_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(liquid_water_m3);
        const ice_water_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(ice_water_m3);
        const matrix_liquid_water_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(matrix_liquid_water_m3);
        const macropore_liquid_water_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(macropore_liquid_water_m3);
        const matrix_ice_water_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(matrix_ice_water_m3);
        const macropore_ice_water_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(macropore_ice_water_m3);
        const matrix_pore_capacity_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(matrix_pore_capacity_m3);
        const macropore_pore_capacity_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(macropore_pore_capacity_m3);
        const matrix_air_volume_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(matrix_air_volume_m3);
        const macropore_air_volume_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(macropore_air_volume_m3);
        const air_volume_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(air_volume_m3);
        const water_vapor_volume_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(water_vapor_volume_m3);
        const matric_potential_megapascal = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(matric_potential_megapascal);
        const surface_temperature_k = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(surface_temperature_k);
        const active_soil_layer_count = try allocator.alloc(usize, cell_count);
        errdefer allocator.free(active_soil_layer_count);
        const maximum_rooting_layer_count = try allocator.alloc(usize, cell_count);
        errdefer allocator.free(maximum_rooting_layer_count);

        @memset(soil_temperature_k, 273.15);
        @memset(liquid_water_m3, 0.0);
        @memset(ice_water_m3, 0.0);
        @memset(matrix_liquid_water_m3, 0.0);
        @memset(macropore_liquid_water_m3, 0.0);
        @memset(matrix_ice_water_m3, 0.0);
        @memset(macropore_ice_water_m3, 0.0);
        @memset(matrix_pore_capacity_m3, 0.0);
        @memset(macropore_pore_capacity_m3, 0.0);
        @memset(matrix_air_volume_m3, 0.0);
        @memset(macropore_air_volume_m3, 0.0);
        @memset(air_volume_m3, 0.0);
        @memset(water_vapor_volume_m3, 0.0);
        @memset(matric_potential_megapascal, 0.0);
        @memset(surface_temperature_k, 273.15);
        @memset(active_soil_layer_count, cfg.soil_layers);
        @memset(maximum_rooting_layer_count, cfg.soil_layers);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .layer_count = layer_count,
            .soil_layer_capacity = cfg.soil_layers,
            .active_soil_layer_count = active_soil_layer_count,
            .maximum_rooting_layer_count = maximum_rooting_layer_count,
            .soil_temperature_k = soil_temperature_k,
            .liquid_water_m3 = liquid_water_m3,
            .ice_water_m3 = ice_water_m3,
            .matrix_liquid_water_m3 = matrix_liquid_water_m3,
            .macropore_liquid_water_m3 = macropore_liquid_water_m3,
            .matrix_ice_water_m3 = matrix_ice_water_m3,
            .macropore_ice_water_m3 = macropore_ice_water_m3,
            .matrix_pore_capacity_m3 = matrix_pore_capacity_m3,
            .macropore_pore_capacity_m3 = macropore_pore_capacity_m3,
            .matrix_air_volume_m3 = matrix_air_volume_m3,
            .macropore_air_volume_m3 = macropore_air_volume_m3,
            .air_volume_m3 = air_volume_m3,
            .water_vapor_volume_m3 = water_vapor_volume_m3,
            .matric_potential_megapascal = matric_potential_megapascal,
            .surface_temperature_k = surface_temperature_k,
        };
    }

    pub fn deinit(self: *GridState) void {
        self.allocator.free(self.maximum_rooting_layer_count);
        self.allocator.free(self.active_soil_layer_count);
        self.allocator.free(self.surface_temperature_k);
        self.allocator.free(self.matric_potential_megapascal);
        self.allocator.free(self.air_volume_m3);
        self.allocator.free(self.water_vapor_volume_m3);
        self.allocator.free(self.macropore_air_volume_m3);
        self.allocator.free(self.matrix_air_volume_m3);
        self.allocator.free(self.macropore_pore_capacity_m3);
        self.allocator.free(self.matrix_pore_capacity_m3);
        self.allocator.free(self.macropore_ice_water_m3);
        self.allocator.free(self.matrix_ice_water_m3);
        self.allocator.free(self.macropore_liquid_water_m3);
        self.allocator.free(self.matrix_liquid_water_m3);
        self.allocator.free(self.ice_water_m3);
        self.allocator.free(self.liquid_water_m3);
        self.allocator.free(self.soil_temperature_k);
        self.* = undefined;
    }

    pub fn layerIndex(self: GridState, cell_index: usize, layer_index: usize) !usize {
        if (cell_index >= self.cell_count or layer_index >= self.soil_layer_capacity) return error.GridIndexOutOfBounds;
        const index = try std.math.add(usize, try std.math.mul(usize, cell_index, self.soil_layer_capacity), layer_index);
        if (index >= self.layer_count) return error.GridIndexOutOfBounds;
        return index;
    }

    pub fn validateFinite(self: GridState) !void {
        try validateField("soil_temperature_k", self.soil_temperature_k);
        try validateField("liquid_water_m3", self.liquid_water_m3);
        try validateField("ice_water_m3", self.ice_water_m3);
        try validateField("matrix_liquid_water_m3", self.matrix_liquid_water_m3);
        try validateField("macropore_liquid_water_m3", self.macropore_liquid_water_m3);
        try validateField("matrix_ice_water_m3", self.matrix_ice_water_m3);
        try validateField("macropore_ice_water_m3", self.macropore_ice_water_m3);
        try validateField("matrix_pore_capacity_m3", self.matrix_pore_capacity_m3);
        try validateField("macropore_pore_capacity_m3", self.macropore_pore_capacity_m3);
        try validateField("matrix_air_volume_m3", self.matrix_air_volume_m3);
        try validateField("macropore_air_volume_m3", self.macropore_air_volume_m3);
        try validateField("air_volume_m3", self.air_volume_m3);
        try validateField("water_vapor_volume_m3", self.water_vapor_volume_m3);
        try validateField("matric_potential_megapascal", self.matric_potential_megapascal);
        try validateField("surface_temperature_k", self.surface_temperature_k);
    }
};

/// Runtime-sized plant storage. No species dimension is compile-time fixed;
/// all fields are flat structure-of-arrays buffers suitable for tiled CPU or
/// future GPU kernels.
pub const PlantState = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_count: usize,
    canopy_temperature_k: []f64,
    canopy_water_potential_megapascal: []f64,
    canopy_water_storage_m_per_m2: []f64,
    leaf_area_index_m2_m2: []f64,
    shoot_carbon_g_m2: []f64,
    root_carbon_g_m2: []f64,

    pub fn init(allocator: std.mem.Allocator, cfg: SimulationConfig) !PlantState {
        try cfg.validate();
        const cell_count = try std.math.mul(usize, cfg.lon_count, cfg.lat_count);
        const cell_species_count = try std.math.mul(usize, cell_count, cfg.plant_populations);
        const root_count = try std.math.mul(usize, cell_species_count, cfg.soil_layers);
        const canopy_temperature_k = try allocator.alloc(f64, cell_species_count);
        errdefer allocator.free(canopy_temperature_k);
        const canopy_water_potential_megapascal = try allocator.alloc(f64, cell_species_count);
        errdefer allocator.free(canopy_water_potential_megapascal);
        const canopy_water_storage_m_per_m2 = try allocator.alloc(f64, cell_species_count);
        errdefer allocator.free(canopy_water_storage_m_per_m2);
        const leaf_area_index_m2_m2 = try allocator.alloc(f64, cell_species_count);
        errdefer allocator.free(leaf_area_index_m2_m2);
        const shoot_carbon_g_m2 = try allocator.alloc(f64, cell_species_count);
        errdefer allocator.free(shoot_carbon_g_m2);
        const root_carbon_g_m2 = try allocator.alloc(f64, root_count);
        errdefer allocator.free(root_carbon_g_m2);
        @memset(canopy_temperature_k, 273.15);
        @memset(canopy_water_potential_megapascal, -0.1);
        @memset(canopy_water_storage_m_per_m2, 0.0);
        @memset(leaf_area_index_m2_m2, 0.0);
        @memset(shoot_carbon_g_m2, 0.0);
        @memset(root_carbon_g_m2, 0.0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = cfg.plant_populations,
            .soil_layer_count = cfg.soil_layers,
            .canopy_temperature_k = canopy_temperature_k,
            .canopy_water_potential_megapascal = canopy_water_potential_megapascal,
            .canopy_water_storage_m_per_m2 = canopy_water_storage_m_per_m2,
            .leaf_area_index_m2_m2 = leaf_area_index_m2_m2,
            .shoot_carbon_g_m2 = shoot_carbon_g_m2,
            .root_carbon_g_m2 = root_carbon_g_m2,
        };
    }

    pub fn deinit(self: *PlantState) void {
        self.allocator.free(self.root_carbon_g_m2);
        self.allocator.free(self.shoot_carbon_g_m2);
        self.allocator.free(self.leaf_area_index_m2_m2);
        self.allocator.free(self.canopy_temperature_k);
        self.allocator.free(self.canopy_water_potential_megapascal);
        self.allocator.free(self.canopy_water_storage_m_per_m2);
        self.* = undefined;
    }

    pub fn speciesIndex(self: PlantState, cell_index: usize, species_index: usize) !usize {
        if (cell_index >= self.cell_count or species_index >= self.species_count) return error.PlantIndexOutOfBounds;
        return try std.math.add(usize, try std.math.mul(usize, cell_index, self.species_count), species_index);
    }

    pub fn rootIndex(self: PlantState, cell_index: usize, species_index: usize, soil_layer_index: usize) !usize {
        if (soil_layer_index >= self.soil_layer_count) return error.PlantIndexOutOfBounds;
        return try std.math.add(usize, try std.math.mul(usize, try self.speciesIndex(cell_index, species_index), self.soil_layer_count), soil_layer_index);
    }

    pub fn validateFinite(self: PlantState) !void {
        try validateField("canopy_temperature_k", self.canopy_temperature_k);
        try validateField("canopy_water_potential_megapascal", self.canopy_water_potential_megapascal);
        try validateField("canopy_water_storage_m_per_m2", self.canopy_water_storage_m_per_m2);
        try validateField("leaf_area_index_m2_m2", self.leaf_area_index_m2_m2);
        try validateField("shoot_carbon_g_m2", self.shoot_carbon_g_m2);
        try validateField("root_carbon_g_m2", self.root_carbon_g_m2);
    }
};

fn validateField(comptime name: []const u8, values: []const f64) !void {
    for (values, 0..) |value, index| {
        if (!std.math.isFinite(value)) {
            std.log.err("non-finite model state: field={s} index={d} value={e}", .{ name, index, value });
            return error.NonFiniteModelState;
        }
    }
}

test "grid state is heap allocated and finite" {
    const config = try testConfig(10, 10, 20, 5);
    var state = try GridState.init(std.testing.allocator, config);
    defer state.deinit();
    try state.validateFinite();
    try std.testing.expectEqual(@as(usize, 2000), state.layer_count);
}

test "plant state supports more than five runtime species" {
    const config = try testConfig(3, 2, 7, 19);
    var state = try PlantState.init(std.testing.allocator, config);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 19), state.species_count);
    try std.testing.expectEqual(@as(usize, 3 * 2 * 19 * 7), state.root_carbon_g_m2.len);
    try std.testing.expectEqual(@as(usize, state.root_carbon_g_m2.len - 1), try state.rootIndex(5, 18, 6));
    try state.validateFinite();
}

fn testConfig(columns: usize, rows: usize, layers: usize, species: usize) !SimulationConfig {
    return SimulationConfig.init(
        .{ .lon_count = columns, .lat_count = rows, .soil_layers = layers, .plant_populations = species },
        .{ .worker_threads = 1, .tile_cells = 64 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
}
