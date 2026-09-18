const std = @import("std");

/// Runtime EXTRACT `ARSDT/ARSDC` owners. Area is m2; layer storage is
/// cell-major then canopy-layer-major.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    plant_species_per_cell: usize,
    canopy_layer_count: usize,
    area_m2_by_cell_layer: []f64,
    area_m2_by_cell: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        plant_species_per_cell: usize,
        canopy_layer_count: usize,
    ) !State {
        if (cell_count == 0 or plant_species_per_cell == 0 or
            canopy_layer_count == 0)
            return error.InvalidStandingDeadAreaStateUpdateDimensions;
        const layer_values = try std.math.mul(
            usize,
            cell_count,
            canopy_layer_count,
        );
        const by_layer = try allocator.alloc(f64, layer_values);
        errdefer allocator.free(by_layer);
        const by_cell = try allocator.alloc(f64, cell_count);
        @memset(by_layer, 0);
        @memset(by_cell, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .plant_species_per_cell = plant_species_per_cell,
            .canopy_layer_count = canopy_layer_count,
            .area_m2_by_cell_layer = by_layer,
            .area_m2_by_cell = by_cell,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.area_m2_by_cell);
        self.allocator.free(self.area_m2_by_cell_layer);
        self.* = undefined;
    }
};

/// Exact EXTRACT reset lines 135/140 and accumulation lines 625–628.
/// Every candidate cell and layer total is preflighted before either broad
/// area owner changes.
pub fn refresh(
    state: *State,
    area_m2_by_plant_layer: []const f64,
) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.plant_species_per_cell,
    );
    const expected = try std.math.mul(
        usize,
        plant_count,
        state.canopy_layer_count,
    );
    if (area_m2_by_plant_layer.len != expected)
        return error.InvalidStandingDeadAreaStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        _ = try totalForCell(state, area_m2_by_plant_layer, cell);
        for (0..state.canopy_layer_count) |layer|
            _ = try totalForLayer(state, area_m2_by_plant_layer, cell, layer);
    }

    @memset(state.area_m2_by_cell_layer, 0);
    @memset(state.area_m2_by_cell, 0);
    for (0..state.cell_count) |cell| {
        state.area_m2_by_cell[cell] =
            totalForCell(state, area_m2_by_plant_layer, cell) catch unreachable;
        for (0..state.canopy_layer_count) |layer| {
            const target = cell * state.canopy_layer_count + layer;
            state.area_m2_by_cell_layer[target] =
                totalForLayer(
                    state,
                    area_m2_by_plant_layer,
                    cell,
                    layer,
                ) catch unreachable;
        }
    }
}

fn totalForCell(
    state: *const State,
    source: []const f64,
    cell: usize,
) !f64 {
    var total_m2: f64 = 0;
    for (0..state.plant_species_per_cell) |species| {
        const plant = cell * state.plant_species_per_cell + species;
        var plant_total_m2: f64 = 0;
        for (0..state.canopy_layer_count) |layer| {
            const area_m2 = source[plant * state.canopy_layer_count + layer];
            try addArea(&plant_total_m2, area_m2);
        }
        try addArea(&total_m2, plant_total_m2);
    }
    return total_m2;
}

fn totalForLayer(
    state: *const State,
    source: []const f64,
    cell: usize,
    layer: usize,
) !f64 {
    var total_m2: f64 = 0;
    for (0..state.plant_species_per_cell) |species| {
        const plant = cell * state.plant_species_per_cell + species;
        const area_m2 = source[plant * state.canopy_layer_count + layer];
        try addArea(&total_m2, area_m2);
    }
    return total_m2;
}

fn addArea(total_m2: *f64, area_m2: f64) !void {
    if (!std.math.isFinite(area_m2) or area_m2 < 0)
        return error.InvalidStandingDeadAreaStateUpdateInput;
    const next = total_m2.* + area_m2;
    if (!std.math.isFinite(next))
        return error.NonFiniteStandingDeadAreaStateUpdate;
    total_m2.* = next;
}

test "standing dead area publishes runtime cells species and layers" {
    var state = try State.init(std.testing.allocator, 2, 2, 3);
    defer state.deinit();
    try refresh(&state, &.{
        1,  2,  3,
        10, 20, 30,
        4,  5,  6,
        40, 50, 60,
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ 11, 22, 33, 44, 55, 66 },
        state.area_m2_by_cell_layer,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 66, 165 },
        state.area_m2_by_cell,
    );
}

test "late invalid standing dead area preserves both owners" {
    var state = try State.init(std.testing.allocator, 2, 2, 1);
    defer state.deinit();
    @memset(state.area_m2_by_cell_layer, 7);
    @memset(state.area_m2_by_cell, 8);
    try std.testing.expectError(
        error.InvalidStandingDeadAreaStateUpdateInput,
        refresh(&state, &.{ 1, 2, 3, std.math.nan(f64) }),
    );
    try std.testing.expectEqualSlices(f64, &.{ 7, 7 }, state.area_m2_by_cell_layer);
    try std.testing.expectEqualSlices(f64, &.{ 8, 8 }, state.area_m2_by_cell);
}
