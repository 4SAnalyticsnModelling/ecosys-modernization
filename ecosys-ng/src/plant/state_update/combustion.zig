const std = @import("std");

pub const State = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,
    signed_carbon_loss_g_c_per_h_by_plant: []f64,
    charcoal_return_g_c_per_h_by_plant: []f64,
    signed_carbon_balance_g_c_per_h_by_plant: []f64,
    signed_nitrogen_loss_g_n_per_h_by_plant: []f64,
    signed_phosphorus_loss_g_p_per_h_by_plant: []f64,

    pub fn init(allocator: std.mem.Allocator, plant_count: usize) !State {
        if (plant_count == 0) return error.InvalidPlantCombustionStateUpdateDimensions;
        const value_count = try std.math.mul(usize, plant_count, 5);
        const values = try allocator.alloc(f64, value_count);
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .plant_count = plant_count,
            .signed_carbon_loss_g_c_per_h_by_plant = values[0..plant_count],
            .charcoal_return_g_c_per_h_by_plant = values[plant_count .. 2 * plant_count],
            .signed_carbon_balance_g_c_per_h_by_plant = values[2 * plant_count .. 3 * plant_count],
            .signed_nitrogen_loss_g_n_per_h_by_plant = values[3 * plant_count .. 4 * plant_count],
            .signed_phosphorus_loss_g_p_per_h_by_plant = values[4 * plant_count ..],
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(
            self.signed_carbon_loss_g_c_per_h_by_plant.ptr[0 .. 5 * self.plant_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    plant_species_per_cell: usize,
    fire_active_by_cell: []const bool,
    signed_carbon_loss_g_c_per_h_by_plant: []const f64,
    charcoal_return_g_c_per_h_by_plant: []const f64,
    signed_nitrogen_loss_g_n_per_h_by_plant: []const f64,
    signed_phosphorus_loss_g_p_per_h_by_plant: []const f64,
};

/// EXTRACT lines 212–412 state_update of accepted per-plant shoot-combustion
/// losses and the positive charcoal return. The unresolved gaseous/mineral
/// nitrogen and phosphorus product split is deliberately not reconstructed.
pub fn refresh(state: *State, inputs: Inputs) !void {
    if (inputs.plant_species_per_cell == 0)
        return error.InvalidPlantCombustionStateUpdateDimensions;
    const expected_plant_count = std.math.mul(
        usize,
        inputs.fire_active_by_cell.len,
        inputs.plant_species_per_cell,
    ) catch return error.InvalidPlantCombustionStateUpdateDimensions;
    if (expected_plant_count != state.plant_count)
        return error.InvalidPlantCombustionStateUpdateDimensions;
    inline for (@typeInfo(Inputs).@"struct".fields[2..]) |field|
        if (@field(inputs, field.name).len != state.plant_count)
            return error.InvalidPlantCombustionStateUpdateDimensions;

    for (0..state.plant_count) |plant|
        _ = try valuesForPlant(inputs, plant);

    for (0..state.plant_count) |plant| {
        const values = valuesForPlant(inputs, plant) catch unreachable;
        state.signed_carbon_loss_g_c_per_h_by_plant[plant] = values.carbon_loss;
        state.charcoal_return_g_c_per_h_by_plant[plant] = values.charcoal;
        state.signed_carbon_balance_g_c_per_h_by_plant[plant] = values.carbon_balance;
        state.signed_nitrogen_loss_g_n_per_h_by_plant[plant] = values.nitrogen_loss;
        state.signed_phosphorus_loss_g_p_per_h_by_plant[plant] = values.phosphorus_loss;
    }
}

const Values = struct {
    carbon_loss: f64 = 0,
    charcoal: f64 = 0,
    carbon_balance: f64 = 0,
    nitrogen_loss: f64 = 0,
    phosphorus_loss: f64 = 0,
};

fn valuesForPlant(inputs: Inputs, plant: usize) !Values {
    const cell = plant / inputs.plant_species_per_cell;
    if (!inputs.fire_active_by_cell[cell]) return .{};
    const carbon_loss = inputs.signed_carbon_loss_g_c_per_h_by_plant[plant];
    const charcoal = inputs.charcoal_return_g_c_per_h_by_plant[plant];
    const nitrogen_loss = inputs.signed_nitrogen_loss_g_n_per_h_by_plant[plant];
    const phosphorus_loss = inputs.signed_phosphorus_loss_g_p_per_h_by_plant[plant];
    if (!std.math.isFinite(carbon_loss) or carbon_loss > 0 or
        !std.math.isFinite(charcoal) or charcoal < 0 or
        !std.math.isFinite(nitrogen_loss) or nitrogen_loss > 0 or
        !std.math.isFinite(phosphorus_loss) or phosphorus_loss > 0)
        return error.InvalidPlantCombustionStateUpdateInput;
    const carbon_balance = carbon_loss + charcoal;
    if (!std.math.isFinite(carbon_balance))
        return error.NonFinitePlantCombustionStateUpdate;
    return .{
        .carbon_loss = carbon_loss,
        .charcoal = charcoal,
        .carbon_balance = carbon_balance,
        .nitrogen_loss = nitrogen_loss,
        .phosphorus_loss = phosphorus_loss,
    };
}

test "plant combustion state_update preserves runtime plant order and signs" {
    var state = try State.init(std.testing.allocator, 4);
    defer state.deinit();
    try refresh(&state, .{
        .plant_species_per_cell = 2,
        .fire_active_by_cell = &.{ true, false },
        .signed_carbon_loss_g_c_per_h_by_plant = &.{ -10, -20, std.math.nan(f64), 1 },
        .charcoal_return_g_c_per_h_by_plant = &.{ 1, 2, std.math.nan(f64), -1 },
        .signed_nitrogen_loss_g_n_per_h_by_plant = &.{ -3, -4, std.math.nan(f64), 1 },
        .signed_phosphorus_loss_g_p_per_h_by_plant = &.{ -5, -6, std.math.nan(f64), 1 },
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ -9, -18, 0, 0 },
        state.signed_carbon_balance_g_c_per_h_by_plant,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ -3, -4, 0, 0 },
        state.signed_nitrogen_loss_g_n_per_h_by_plant,
    );
}

test "late invalid active plant preserves complete state_update" {
    var state = try State.init(std.testing.allocator, 4);
    defer state.deinit();
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64) @memset(@field(state, field.name), 7);
    try std.testing.expectError(
        error.InvalidPlantCombustionStateUpdateInput,
        refresh(&state, .{
            .plant_species_per_cell = 2,
            .fire_active_by_cell = &.{ true, true },
            .signed_carbon_loss_g_c_per_h_by_plant = &.{ -1, -2, -3, 1 },
            .charcoal_return_g_c_per_h_by_plant = &.{ 0.1, 0.2, 0.3, 0.4 },
            .signed_nitrogen_loss_g_n_per_h_by_plant = &.{ -1, -2, -3, -4 },
            .signed_phosphorus_loss_g_p_per_h_by_plant = &.{ -1, -2, -3, -4 },
        }),
    );
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64)
            for (@field(state, field.name)) |value|
                try std.testing.expectEqual(@as(f64, 7), value);
}
