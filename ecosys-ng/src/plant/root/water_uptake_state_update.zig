const std = @import("std");

const water_heat_capacity_megajoules_per_m3_k = 4.19;

/// Runtime EXTRACT `RTDNT/TUPWTR/TUPHT` owner. Arrays use cell-major then
/// soil-layer-major order.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    root_length_density_m_per_m3: []f64,
    water_uptake_m3_per_h: []f64,
    convective_water_heat_megajoules_per_h: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootWaterStateUpdateDimensions;
        const layer_count = try std.math.mul(
            usize,
            cell_count,
            soil_layer_capacity,
        );
        const density = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(density);
        const water = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(water);
        const heat = try allocator.alloc(f64, layer_count);
        @memset(density, 0);
        @memset(water, 0);
        @memset(heat, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .soil_layer_capacity = soil_layer_capacity,
            .root_domain_capacity = root_domain_capacity,
            .root_length_density_m_per_m3 = density,
            .water_uptake_m3_per_h = water,
            .convective_water_heat_megajoules_per_h = heat,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.convective_water_heat_megajoules_per_h);
        self.allocator.free(self.water_uptake_m3_per_h);
        self.allocator.free(self.root_length_density_m_per_m3);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    root_domain_count_by_plant: []const u8,
    plant_population_count: []const f64,
    cell_area_m2: []const f64,
    soil_temperature_k_by_layer: []const f64,
    root_length_density_m_per_m3: []const f64,
    water_uptake_m3_per_h: []const f64,
};

const Totals = struct {
    root_length_density_m_per_m3: f64 = 0,
    water_uptake_m3_per_h: f64 = 0,
    convective_water_heat_megajoules_per_h: f64 = 0,
};

/// Exact EXTRACT lines 680–703 state_update. Active plants traverse root
/// domains then layers; only domain zero contributes RTDNT. Water and heat
/// preserve the signed UPWTR source convention.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.species_count,
    );
    const layer_count = try std.math.mul(
        usize,
        state.cell_count,
        state.soil_layer_capacity,
    );
    const root_count = try std.math.mul(
        usize,
        try std.math.mul(usize, plant_count, state.root_domain_capacity),
        state.soil_layer_capacity,
    );
    inline for (.{
        inputs.active_soil_layer_count_by_cell.len == state.cell_count,
        inputs.active_by_plant.len == plant_count,
        inputs.root_domain_count_by_plant.len == plant_count,
        inputs.plant_population_count.len == plant_count,
        inputs.cell_area_m2.len == state.cell_count,
        inputs.soil_temperature_k_by_layer.len == layer_count,
        inputs.root_length_density_m_per_m3.len == root_count,
        inputs.water_uptake_m3_per_h.len == root_count,
    }) |valid| if (!valid) return error.InvalidRootWaterStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        const active_layers = inputs.active_soil_layer_count_by_cell[cell];
        if (active_layers > state.soil_layer_capacity)
            return error.InvalidRootWaterStateUpdateDimensions;
        for (0..active_layers) |layer|
            _ = try totalsFor(state, inputs, cell, layer);
    }

    @memset(state.root_length_density_m_per_m3, 0);
    @memset(state.water_uptake_m3_per_h, 0);
    @memset(state.convective_water_heat_megajoules_per_h, 0);
    for (0..state.cell_count) |cell| {
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const output = cell * state.soil_layer_capacity + layer;
            const totals = totalsFor(state, inputs, cell, layer) catch unreachable;
            state.root_length_density_m_per_m3[output] =
                totals.root_length_density_m_per_m3;
            state.water_uptake_m3_per_h[output] =
                totals.water_uptake_m3_per_h;
            state.convective_water_heat_megajoules_per_h[output] =
                totals.convective_water_heat_megajoules_per_h;
        }
    }
}

fn totalsFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
) !Totals {
    const area = inputs.cell_area_m2[cell];
    const soil = cell * state.soil_layer_capacity + layer;
    const temperature = inputs.soil_temperature_k_by_layer[soil];
    if (!std.math.isFinite(area) or area <= 0 or
        !std.math.isFinite(temperature) or temperature <= 0)
        return error.InvalidRootWaterStateUpdateInput;
    var result: Totals = .{};
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const population = inputs.plant_population_count[plant];
        const domain_count = inputs.root_domain_count_by_plant[plant];
        if (!std.math.isFinite(population) or population < 0 or
            domain_count == 0 or domain_count > state.root_domain_capacity)
            return error.InvalidRootWaterStateUpdateInput;
        for (0..domain_count) |domain| {
            const root =
                (plant * state.root_domain_capacity + domain) *
                state.soil_layer_capacity +
                layer;
            const density = inputs.root_length_density_m_per_m3[root];
            const water = inputs.water_uptake_m3_per_h[root];
            if (!std.math.isFinite(density) or density < 0 or
                !std.math.isFinite(water))
                return error.InvalidRootWaterStateUpdateInput;
            if (domain == 0)
                result.root_length_density_m_per_m3 +=
                    density * population / area;
            result.water_uptake_m3_per_h += water;
            result.convective_water_heat_megajoules_per_h +=
                water * water_heat_capacity_megajoules_per_m3_k * temperature;
        }
    }
    inline for (@typeInfo(Totals).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteRootWaterStateUpdate;
    return result;
}

test "root water state_update preserves domain order signs and heat closure" {
    var state = try State.init(std.testing.allocator, 1, 2, 2, 2);
    defer state.deinit();
    try refresh(&state, .{
        .active_soil_layer_count_by_cell = &.{2},
        .active_by_plant = &.{ true, true },
        .root_domain_count_by_plant = &.{ 2, 1 },
        .plant_population_count = &.{ 10, 20 },
        .cell_area_m2 = &.{5},
        .soil_temperature_k_by_layer = &.{ 280, 290 },
        .root_length_density_m_per_m3 = &.{ 1, 2, 10, 20, 3, 4, 30, 40 },
        .water_uptake_m3_per_h = &.{ -1, -2, -0.1, -0.2, -3, -4, 99, 99 },
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ 14, 20 },
        state.root_length_density_m_per_m3,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ -4.1, -6.2 },
        state.water_uptake_m3_per_h,
    );
    try std.testing.expectApproxEqAbs(
        state.water_uptake_m3_per_h[1] * 4.19 * 290,
        state.convective_water_heat_megajoules_per_h[1],
        1e-12,
    );
}

test "late invalid root water leaves full state_update unchanged" {
    var state = try State.init(std.testing.allocator, 1, 1, 2, 1);
    defer state.deinit();
    @memset(state.root_length_density_m_per_m3, 7);
    @memset(state.water_uptake_m3_per_h, 8);
    @memset(state.convective_water_heat_megajoules_per_h, 9);
    try std.testing.expectError(
        error.InvalidRootWaterStateUpdateInput,
        refresh(&state, .{
            .active_soil_layer_count_by_cell = &.{2},
            .active_by_plant = &.{true},
            .root_domain_count_by_plant = &.{1},
            .plant_population_count = &.{1},
            .cell_area_m2 = &.{1},
            .soil_temperature_k_by_layer = &.{ 280, 290 },
            .root_length_density_m_per_m3 = &.{ 1, 2 },
            .water_uptake_m3_per_h = &.{ -1, std.math.nan(f64) },
        }),
    );
    try std.testing.expectEqualSlices(f64, &.{ 7, 7 }, state.root_length_density_m_per_m3);
    try std.testing.expectEqualSlices(f64, &.{ 8, 8 }, state.water_uptake_m3_per_h);
    try std.testing.expectEqualSlices(f64, &.{ 9, 9 }, state.convective_water_heat_megajoules_per_h);
}
