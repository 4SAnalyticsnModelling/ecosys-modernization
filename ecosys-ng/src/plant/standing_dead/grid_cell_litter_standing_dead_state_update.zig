const std = @import("std");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    plant_species_per_cell: usize,
    aboveground_litter_carbon_g_c_per_h_by_cell: []f64,
    aboveground_litter_nitrogen_g_n_per_h_by_cell: []f64,
    aboveground_litter_phosphorus_g_p_per_h_by_cell: []f64,
    standing_dead_carbon_g_c_by_cell: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        plant_species_per_cell: usize,
    ) !State {
        if (cell_count == 0 or plant_species_per_cell == 0)
            return error.InvalidCellLitterStateUpdateDimensions;
        const value_count = try std.math.mul(usize, cell_count, 4);
        const values = try allocator.alloc(f64, value_count);
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .plant_species_per_cell = plant_species_per_cell,
            .aboveground_litter_carbon_g_c_per_h_by_cell = values[0..cell_count],
            .aboveground_litter_nitrogen_g_n_per_h_by_cell = values[cell_count .. 2 * cell_count],
            .aboveground_litter_phosphorus_g_p_per_h_by_cell = values[2 * cell_count .. 3 * cell_count],
            .standing_dead_carbon_g_c_by_cell = values[3 * cell_count .. 4 * cell_count],
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(
            self.aboveground_litter_carbon_g_c_per_h_by_cell.ptr[0 .. 4 * self.cell_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    aboveground_litter_carbon_g_c_per_h_by_plant: []const f64,
    aboveground_litter_nitrogen_g_n_per_h_by_plant: []const f64,
    aboveground_litter_phosphorus_g_p_per_h_by_plant: []const f64,
    standing_dead_carbon_g_c_by_plant: []const f64,
};

/// Exact EXTRACT lines 60–63 plant-order accumulation. Every cell total is
/// preflighted before any of the four broad state_update arrays changes.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.plant_species_per_cell,
    );
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (@field(inputs, field.name).len != plant_count)
            return error.InvalidCellLitterStateUpdateDimensions;

    for (0..state.cell_count) |cell|
        _ = try totalsForCell(state, inputs, cell);

    for (0..state.cell_count) |cell| {
        const totals = totalsForCell(state, inputs, cell) catch unreachable;
        state.aboveground_litter_carbon_g_c_per_h_by_cell[cell] = totals.litter_carbon;
        state.aboveground_litter_nitrogen_g_n_per_h_by_cell[cell] = totals.litter_nitrogen;
        state.aboveground_litter_phosphorus_g_p_per_h_by_cell[cell] = totals.litter_phosphorus;
        state.standing_dead_carbon_g_c_by_cell[cell] = totals.standing_dead_carbon;
    }
}

const Totals = struct {
    litter_carbon: f64,
    litter_nitrogen: f64,
    litter_phosphorus: f64,
    standing_dead_carbon: f64,
};

fn totalsForCell(state: *const State, inputs: Inputs, cell: usize) !Totals {
    const first = cell * state.plant_species_per_cell;
    var totals: Totals = .{
        .litter_carbon = 0,
        .litter_nitrogen = 0,
        .litter_phosphorus = 0,
        .standing_dead_carbon = 0,
    };
    for (first..first + state.plant_species_per_cell) |plant| {
        const values = .{
            inputs.aboveground_litter_carbon_g_c_per_h_by_plant[plant],
            inputs.aboveground_litter_nitrogen_g_n_per_h_by_plant[plant],
            inputs.aboveground_litter_phosphorus_g_p_per_h_by_plant[plant],
            inputs.standing_dead_carbon_g_c_by_plant[plant],
        };
        inline for (values) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidCellLitterStateUpdateInput;
        totals.litter_carbon += values[0];
        totals.litter_nitrogen += values[1];
        totals.litter_phosphorus += values[2];
        totals.standing_dead_carbon += values[3];
        inline for (@typeInfo(Totals).@"struct".fields) |field|
            if (!std.math.isFinite(@field(totals, field.name)))
                return error.NonFiniteCellLitterStateUpdate;
    }
    return totals;
}

test "EXTRACT litter and standing dead state_update preserves plant order" {
    var state = try State.init(std.testing.allocator, 2, 3);
    defer state.deinit();
    try refresh(&state, .{
        .aboveground_litter_carbon_g_c_per_h_by_plant = &.{ 1, 2, 3, 4, 5, 6 },
        .aboveground_litter_nitrogen_g_n_per_h_by_plant = &.{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 },
        .aboveground_litter_phosphorus_g_p_per_h_by_plant = &.{ 0.01, 0.02, 0.03, 0.04, 0.05, 0.06 },
        .standing_dead_carbon_g_c_by_plant = &.{ 10, 20, 30, 40, 50, 60 },
    });
    try std.testing.expectEqualSlices(f64, &.{ 6, 15 }, state.aboveground_litter_carbon_g_c_per_h_by_cell);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), state.aboveground_litter_nitrogen_g_n_per_h_by_cell[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), state.aboveground_litter_phosphorus_g_p_per_h_by_cell[1], 1e-15);
    try std.testing.expectEqualSlices(f64, &.{ 60, 150 }, state.standing_dead_carbon_g_c_by_cell);
}

test "late invalid plant preserves all cell state_update owners" {
    var state = try State.init(std.testing.allocator, 2, 2);
    defer state.deinit();
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64) @memset(@field(state, field.name), 9);
    try std.testing.expectError(
        error.InvalidCellLitterStateUpdateInput,
        refresh(&state, .{
            .aboveground_litter_carbon_g_c_per_h_by_plant = &.{ 1, 2, 3, 4 },
            .aboveground_litter_nitrogen_g_n_per_h_by_plant = &.{ 1, 2, 3, 4 },
            .aboveground_litter_phosphorus_g_p_per_h_by_plant = &.{ 1, 2, 3, 4 },
            .standing_dead_carbon_g_c_by_plant = &.{ 1, 2, 3, std.math.nan(f64) },
        }),
    );
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64)
            for (@field(state, field.name)) |value|
                try std.testing.expectEqual(@as(f64, 9), value);
}
