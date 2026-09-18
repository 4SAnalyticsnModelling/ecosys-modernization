const std = @import("std");

pub const organic_fraction_count: usize = 5;
pub const element_count: usize = 3;

/// EXTRACT element order is C, N, P. Each element contains the five
/// nonstructural organic fractions in source order.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    change_g_element_per_h_by_element_layer_and_fraction: [element_count][]f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootExudateStateUpdateDimensions;
        const layer_fraction_count = try std.math.mul(
            usize,
            try std.math.mul(usize, cell_count, soil_layer_capacity),
            organic_fraction_count,
        );
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, element_count, layer_fraction_count),
        );
        @memset(values, 0);
        var slices: [element_count][]f64 = undefined;
        for (&slices, 0..) |*slice, element| {
            const first = element * layer_fraction_count;
            slice.* = values[first .. first + layer_fraction_count];
        }
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .soil_layer_capacity = soil_layer_capacity,
            .root_domain_capacity = root_domain_capacity,
            .change_g_element_per_h_by_element_layer_and_fraction = slices,
        };
    }

    pub fn deinit(self: *State) void {
        const layer_fraction_count =
            self.cell_count * self.soil_layer_capacity *
            organic_fraction_count;
        self.allocator.free(
            self.change_g_element_per_h_by_element_layer_and_fraction[0]
                .ptr[0 .. element_count * layer_fraction_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    root_domain_count_by_plant: []const u8,
    exchange_g_element_per_h_by_element_root_and_fraction: [element_count][]const f64,
};

/// Exact EXTRACT lines 853–857. The three `TDFOM* -= RDFOM*` operations
/// retain source fraction order and publish atomically.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.species_count,
    );
    const root_count = try std.math.mul(
        usize,
        try std.math.mul(usize, plant_count, state.root_domain_capacity),
        state.soil_layer_capacity,
    );
    const source_count = try std.math.mul(
        usize,
        root_count,
        organic_fraction_count,
    );
    if (inputs.active_soil_layer_count_by_cell.len != state.cell_count or
        inputs.active_by_plant.len != plant_count or
        inputs.root_domain_count_by_plant.len != plant_count)
        return error.InvalidRootExudateStateUpdateDimensions;
    inline for (
        inputs.exchange_g_element_per_h_by_element_root_and_fraction,
    ) |values| if (values.len != source_count)
        return error.InvalidRootExudateStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        const active_layers = inputs.active_soil_layer_count_by_cell[cell];
        if (active_layers > state.soil_layer_capacity)
            return error.InvalidRootExudateStateUpdateDimensions;
        for (0..active_layers) |layer| {
            for (0..element_count) |element| {
                for (0..organic_fraction_count) |fraction|
                    _ = try totalFor(
                        state,
                        inputs,
                        cell,
                        layer,
                        element,
                        fraction,
                    );
            }
        }
    }

    inline for (
        state.change_g_element_per_h_by_element_layer_and_fraction,
    ) |values| @memset(values, 0);
    for (0..state.cell_count) |cell| {
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const output =
                (cell * state.soil_layer_capacity + layer) *
                organic_fraction_count;
            for (0..element_count) |element| {
                for (0..organic_fraction_count) |fraction|
                    state.change_g_element_per_h_by_element_layer_and_fraction[
                        element
                    ][output + fraction] = totalFor(
                        state,
                        inputs,
                        cell,
                        layer,
                        element,
                        fraction,
                    ) catch unreachable;
            }
        }
    }
}

fn totalFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
    element: usize,
    fraction: usize,
) !f64 {
    var total: f64 = 0;
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const domain_count = inputs.root_domain_count_by_plant[plant];
        if (domain_count == 0 or domain_count > state.root_domain_capacity)
            return error.InvalidRootExudateStateUpdateInput;
        for (0..domain_count) |domain| {
            const root =
                (plant * state.root_domain_capacity + domain) *
                state.soil_layer_capacity +
                layer;
            const exchange =
                inputs.exchange_g_element_per_h_by_element_root_and_fraction[
                    element
                ][root * organic_fraction_count + fraction];
            if (!std.math.isFinite(exchange))
                return error.NonFiniteRootExudateStateUpdateInput;
            total -= exchange;
        }
    }
    if (!std.math.isFinite(total))
        return error.NonFiniteRootExudateStateUpdate;
    return total;
}

test "root exudate state_update preserves subtraction and fraction order" {
    var state = try State.init(std.testing.allocator, 1, 2, 1, 2);
    defer state.deinit();
    const carbon = [_]f64{
        1,   2,   3,   4,   5,
        -10, -20, -30, -40, -50,
        999, 999, 999, 999, 999,
        999, 999, 999, 999, 999,
    };
    const nitrogen = [_]f64{
        2,   4,   6,   8,   10,
        -20, -40, -60, -80, -100,
        999, 999, 999, 999, 999,
        999, 999, 999, 999, 999,
    };
    const phosphorus = [_]f64{
        3,   6,   9,   12,   15,
        -30, -60, -90, -120, -150,
        999, 999, 999, 999,  999,
        999, 999, 999, 999,  999,
    };
    try refresh(&state, .{
        .active_soil_layer_count_by_cell = &.{1},
        .active_by_plant = &.{ true, false },
        .root_domain_count_by_plant = &.{ 2, 1 },
        .exchange_g_element_per_h_by_element_root_and_fraction = .{ &carbon, &nitrogen, &phosphorus },
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ 9, 18, 27, 36, 45 },
        state.change_g_element_per_h_by_element_layer_and_fraction[0],
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 18, 36, 54, 72, 90 },
        state.change_g_element_per_h_by_element_layer_and_fraction[1],
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 27, 54, 81, 108, 135 },
        state.change_g_element_per_h_by_element_layer_and_fraction[2],
    );
}

test "late invalid root exudate preserves every element array" {
    var state = try State.init(std.testing.allocator, 1, 1, 1, 1);
    defer state.deinit();
    for (
        state.change_g_element_per_h_by_element_layer_and_fraction,
        0..,
    ) |values, element| @memset(
        values,
        @as(f64, @floatFromInt(element + 1)),
    );
    const valid = [_]f64{ 1, 1, 1, 1, 1 };
    const invalid = [_]f64{ 1, 1, 1, 1, std.math.nan(f64) };
    try std.testing.expectError(
        error.NonFiniteRootExudateStateUpdateInput,
        refresh(&state, .{
            .active_soil_layer_count_by_cell = &.{1},
            .active_by_plant = &.{true},
            .root_domain_count_by_plant = &.{1},
            .exchange_g_element_per_h_by_element_root_and_fraction = .{ &valid, &valid, &invalid },
        }),
    );
    for (
        state.change_g_element_per_h_by_element_layer_and_fraction,
        0..,
    ) |values, element| for (values) |value|
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(element + 1)),
            value,
        );
}
