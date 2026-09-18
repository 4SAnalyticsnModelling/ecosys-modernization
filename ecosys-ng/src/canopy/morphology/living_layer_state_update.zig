const std = @import("std");

/// Runtime EXTRACT `ARLFT/WGLFT/ARSTT` layer and `ARLFC/ARSTC` cell owner.
/// Layer arrays are cell-major then canopy-layer-major; area is m2 and leaf
/// carbon is g C.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    layer_count: usize,
    leaf_area_m2_by_cell_layer: []f64,
    leaf_carbon_g_c_by_cell_layer: []f64,
    stalk_area_m2_by_cell_layer: []f64,
    leaf_area_m2_by_cell: []f64,
    stalk_area_m2_by_cell: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        layer_count: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or layer_count == 0)
            return error.InvalidLivingCanopyStateUpdateDimensions;
        const count = try std.math.mul(usize, cell_count, layer_count);
        const leaf_area = try allocator.alloc(f64, count);
        errdefer allocator.free(leaf_area);
        const leaf_carbon = try allocator.alloc(f64, count);
        errdefer allocator.free(leaf_carbon);
        const stalk_area = try allocator.alloc(f64, count);
        errdefer allocator.free(stalk_area);
        const cell_leaf_area = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(cell_leaf_area);
        const cell_stalk_area = try allocator.alloc(f64, cell_count);
        @memset(leaf_area, 0);
        @memset(leaf_carbon, 0);
        @memset(stalk_area, 0);
        @memset(cell_leaf_area, 0);
        @memset(cell_stalk_area, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .layer_count = layer_count,
            .leaf_area_m2_by_cell_layer = leaf_area,
            .leaf_carbon_g_c_by_cell_layer = leaf_carbon,
            .stalk_area_m2_by_cell_layer = stalk_area,
            .leaf_area_m2_by_cell = cell_leaf_area,
            .stalk_area_m2_by_cell = cell_stalk_area,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.stalk_area_m2_by_cell);
        self.allocator.free(self.leaf_area_m2_by_cell);
        self.allocator.free(self.stalk_area_m2_by_cell_layer);
        self.allocator.free(self.leaf_carbon_g_c_by_cell_layer);
        self.allocator.free(self.leaf_area_m2_by_cell_layer);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_by_plant: []const bool,
    plant_branch_offsets: []const usize,
    branch_node_offsets: []const usize,
    node_leaf_area_m2_by_layer: []const f64,
    node_leaf_carbon_g_c_by_layer: []const f64,
    branch_stalk_area_m2_by_layer: []const f64,
};

const Totals = struct {
    leaf_area_m2: f64 = 0,
    leaf_carbon_g_c: f64 = 0,
    stalk_area_m2: f64 = 0,
};

/// Exact EXTRACT lines 663–676 and 944–945 state_update. Active plants are
/// traversed in cell, species, layer order; their nodes precede branches as
/// in the source carriers. The full layer/cell result is proven before mutation.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.species_count,
    );
    if (inputs.active_by_plant.len != plant_count or
        inputs.plant_branch_offsets.len != plant_count + 1 or
        inputs.plant_branch_offsets[0] != 0)
        return error.InvalidLivingCanopyStateUpdateDimensions;
    const branch_count = inputs.plant_branch_offsets[plant_count];
    if (inputs.branch_node_offsets.len != branch_count + 1 or
        inputs.branch_node_offsets[0] != 0)
        return error.InvalidLivingCanopyStateUpdateDimensions;
    const node_count = inputs.branch_node_offsets[branch_count];
    const node_layer_count = try std.math.mul(
        usize,
        node_count,
        state.layer_count,
    );
    const branch_layer_count = try std.math.mul(
        usize,
        branch_count,
        state.layer_count,
    );
    if (inputs.node_leaf_area_m2_by_layer.len != node_layer_count or
        inputs.node_leaf_carbon_g_c_by_layer.len != node_layer_count or
        inputs.branch_stalk_area_m2_by_layer.len != branch_layer_count)
        return error.InvalidLivingCanopyStateUpdateDimensions;
    try validateOffsets(inputs.plant_branch_offsets, branch_count);
    try validateOffsets(inputs.branch_node_offsets, node_count);

    for (0..state.cell_count) |cell| {
        _ = try cellAreasFor(state, inputs, cell);
        for (0..state.layer_count) |layer| {
            _ = try totalsFor(state, inputs, cell, layer);
        }
    }

    @memset(state.leaf_area_m2_by_cell_layer, 0);
    @memset(state.leaf_carbon_g_c_by_cell_layer, 0);
    @memset(state.stalk_area_m2_by_cell_layer, 0);
    @memset(state.leaf_area_m2_by_cell, 0);
    @memset(state.stalk_area_m2_by_cell, 0);
    for (0..state.cell_count) |cell| {
        const cell_areas = cellAreasFor(state, inputs, cell) catch unreachable;
        state.leaf_area_m2_by_cell[cell] = cell_areas.leaf_area_m2;
        state.stalk_area_m2_by_cell[cell] = cell_areas.stalk_area_m2;
        for (0..state.layer_count) |layer| {
            const index = cell * state.layer_count + layer;
            const totals =
                totalsFor(state, inputs, cell, layer) catch unreachable;
            state.leaf_area_m2_by_cell_layer[index] = totals.leaf_area_m2;
            state.leaf_carbon_g_c_by_cell_layer[index] =
                totals.leaf_carbon_g_c;
            state.stalk_area_m2_by_cell_layer[index] = totals.stalk_area_m2;
        }
    }
}

fn cellAreasFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
) !Totals {
    var result: Totals = .{};
    for (0..state.layer_count) |layer| {
        const layer_totals = try totalsFor(state, inputs, cell, layer);
        result.leaf_area_m2 += layer_totals.leaf_area_m2;
        result.stalk_area_m2 += layer_totals.stalk_area_m2;
    }
    if (!std.math.isFinite(result.leaf_area_m2) or
        !std.math.isFinite(result.stalk_area_m2))
        return error.NonFiniteLivingCanopyStateUpdate;
    return result;
}

fn validateOffsets(offsets: []const usize, final_count: usize) !void {
    var previous: usize = 0;
    for (offsets) |offset| {
        if (offset < previous or offset > final_count)
            return error.InvalidLivingCanopyStateUpdateTopology;
        previous = offset;
    }
}

fn totalsFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
) !Totals {
    var result: Totals = .{};
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const first_branch = inputs.plant_branch_offsets[plant];
        const end_branch = inputs.plant_branch_offsets[plant + 1];
        for (first_branch..end_branch) |branch| {
            const first_node = inputs.branch_node_offsets[branch];
            const end_node = inputs.branch_node_offsets[branch + 1];
            for (first_node..end_node) |node| {
                const node_layer = node * state.layer_count + layer;
                const area = inputs.node_leaf_area_m2_by_layer[node_layer];
                const carbon =
                    inputs.node_leaf_carbon_g_c_by_layer[node_layer];
                if (!std.math.isFinite(area) or !std.math.isFinite(carbon) or
                    area < 0 or carbon < 0)
                    return error.InvalidLivingCanopyStateUpdateInput;
                result.leaf_area_m2 += area;
                result.leaf_carbon_g_c += carbon;
            }
            const branch_layer = branch * state.layer_count + layer;
            const stalk_area =
                inputs.branch_stalk_area_m2_by_layer[branch_layer];
            if (!std.math.isFinite(stalk_area) or stalk_area < 0)
                return error.InvalidLivingCanopyStateUpdateInput;
            result.stalk_area_m2 += stalk_area;
        }
    }
    inline for (@typeInfo(Totals).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteLivingCanopyStateUpdate;
    return result;
}

test "living canopy state_update conserves active runtime plant layers" {
    var state = try State.init(std.testing.allocator, 2, 2, 2);
    defer state.deinit();
    try refresh(&state, .{
        .active_by_plant = &.{ true, false, true, true },
        .plant_branch_offsets = &.{ 0, 1, 2, 3, 4 },
        .branch_node_offsets = &.{ 0, 1, 2, 3, 4 },
        .node_leaf_area_m2_by_layer = &.{ 1, 2, 10, 20, 3, 4, 5, 6 },
        .node_leaf_carbon_g_c_by_layer = &.{ 2, 4, 20, 40, 6, 8, 10, 12 },
        .branch_stalk_area_m2_by_layer = &.{ 7, 8, 70, 80, 9, 10, 11, 12 },
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ 1, 2, 8, 10 },
        state.leaf_area_m2_by_cell_layer,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 2, 4, 16, 20 },
        state.leaf_carbon_g_c_by_cell_layer,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 7, 8, 20, 22 },
        state.stalk_area_m2_by_cell_layer,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 3, 18 },
        state.leaf_area_m2_by_cell,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 15, 42 },
        state.stalk_area_m2_by_cell,
    );
}

test "late invalid canopy layer leaves complete state_update unchanged" {
    var state = try State.init(std.testing.allocator, 1, 2, 2);
    defer state.deinit();
    @memset(state.leaf_area_m2_by_cell_layer, 7);
    @memset(state.leaf_carbon_g_c_by_cell_layer, 8);
    @memset(state.stalk_area_m2_by_cell_layer, 9);
    @memset(state.leaf_area_m2_by_cell, 10);
    @memset(state.stalk_area_m2_by_cell, 11);
    const invalid = [_]f64{ 1, 2, 3, std.math.nan(f64) };
    try std.testing.expectError(
        error.InvalidLivingCanopyStateUpdateInput,
        refresh(&state, .{
            .active_by_plant = &.{ true, true },
            .plant_branch_offsets = &.{ 0, 1, 2 },
            .branch_node_offsets = &.{ 0, 1, 2 },
            .node_leaf_area_m2_by_layer = &invalid,
            .node_leaf_carbon_g_c_by_layer = &.{ 1, 2, 3, 4 },
            .branch_stalk_area_m2_by_layer = &.{ 1, 2, 3, 4 },
        }),
    );
    try std.testing.expectEqualSlices(f64, &.{ 7, 7 }, state.leaf_area_m2_by_cell_layer);
    try std.testing.expectEqualSlices(f64, &.{ 8, 8 }, state.leaf_carbon_g_c_by_cell_layer);
    try std.testing.expectEqualSlices(f64, &.{ 9, 9 }, state.stalk_area_m2_by_cell_layer);
    try std.testing.expectEqualSlices(f64, &.{10}, state.leaf_area_m2_by_cell);
    try std.testing.expectEqualSlices(f64, &.{11}, state.stalk_area_m2_by_cell);
}
