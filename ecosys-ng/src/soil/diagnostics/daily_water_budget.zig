const std = @import("std");

/// Heap-owned OUTSD daily water carriers. All fields remain extensive until
/// output so local AREA and landscape TAREA normalization cannot be confused.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    rainfall_m3: []f64,
    boundary_water_inflow_m3: []f64,
    evaporation_m3: []f64,
    runoff_m3: []f64,
    water_outflow_m3: []f64,
    lateral_water_outflow_m3: []f64,
    sediment_outflow_m3: []f64,
    /// Full natural+artificial boundary water exchange (free-drainage,
    /// recharge, water-table exchange), split into non-negative gain/loss to
    /// match this ledger's magnitude-only convention. Unlike
    /// `lateral_water_outflow_m3` (artificial-drainage subset only), this
    /// pair covers the entire boundary term a per-cell closure check needs.
    /// CONSERVATION-PER-CELL-CLOSURE-001.
    boundary_water_exchange_gain_m3: []f64,
    boundary_water_exchange_loss_m3: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.EmptyDailyWaterGrid;
        const storage = try allocator.alloc(f64, try std.math.mul(usize, cell_count, 9));
        @memset(storage, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .rainfall_m3 = storage[0 * cell_count .. 1 * cell_count],
            .boundary_water_inflow_m3 = storage[1 * cell_count .. 2 * cell_count],
            .evaporation_m3 = storage[2 * cell_count .. 3 * cell_count],
            .runoff_m3 = storage[3 * cell_count .. 4 * cell_count],
            .water_outflow_m3 = storage[4 * cell_count .. 5 * cell_count],
            .lateral_water_outflow_m3 = storage[5 * cell_count .. 6 * cell_count],
            .sediment_outflow_m3 = storage[6 * cell_count .. 7 * cell_count],
            .boundary_water_exchange_gain_m3 = storage[7 * cell_count .. 8 * cell_count],
            .boundary_water_exchange_loss_m3 = storage[8 * cell_count .. 9 * cell_count],
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.rainfall_m3.ptr[0 .. self.cell_count * 9]);
        self.* = undefined;
    }

    pub fn resetDaily(self: *State) void {
        @memset(self.rainfall_m3.ptr[0 .. self.cell_count * 9], 0);
    }

    pub fn accumulateHour(self: *State, inputs: HourlyInputs) !void {
        inline for (.{
            inputs.rainfall_m3,
            inputs.boundary_water_inflow_m3,
            inputs.evaporation_m3,
            inputs.runoff_m3,
            inputs.water_outflow_m3,
            inputs.lateral_water_outflow_m3,
            inputs.sediment_outflow_m3,
            inputs.boundary_water_exchange_gain_m3,
            inputs.boundary_water_exchange_loss_m3,
        }) |values| if (values.len != self.cell_count) return error.DailyWaterDimensionMismatch;

        // Validate the complete transaction before changing any accumulator.
        for (0..self.cell_count) |cell| inline for (.{
            inputs.rainfall_m3,
            inputs.boundary_water_inflow_m3,
            inputs.evaporation_m3,
            inputs.runoff_m3,
            inputs.water_outflow_m3,
            inputs.lateral_water_outflow_m3,
            inputs.sediment_outflow_m3,
            inputs.boundary_water_exchange_gain_m3,
            inputs.boundary_water_exchange_loss_m3,
        }) |values| {
            if (!std.math.isFinite(values[cell]) or values[cell] < 0) return error.InvalidHourlyWaterAmount;
        };

        for (0..self.cell_count) |cell| {
            self.rainfall_m3[cell] += inputs.rainfall_m3[cell];
            self.boundary_water_inflow_m3[cell] += inputs.boundary_water_inflow_m3[cell];
            self.evaporation_m3[cell] += inputs.evaporation_m3[cell];
            self.runoff_m3[cell] += inputs.runoff_m3[cell];
            self.water_outflow_m3[cell] += inputs.water_outflow_m3[cell];
            self.lateral_water_outflow_m3[cell] += inputs.lateral_water_outflow_m3[cell];
            self.sediment_outflow_m3[cell] += inputs.sediment_outflow_m3[cell];
            self.boundary_water_exchange_gain_m3[cell] += inputs.boundary_water_exchange_gain_m3[cell];
            self.boundary_water_exchange_loss_m3[cell] += inputs.boundary_water_exchange_loss_m3[cell];
        }
        try self.validateFinite();
    }

    pub fn accumulateCell(self: *State, cell: usize, inputs: CellHourlyInputs) !void {
        if (cell >= self.cell_count) return error.DailyWaterCellOutOfBounds;
        inline for (std.meta.fields(CellHourlyInputs)) |field| {
            const value = @field(inputs, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidHourlyWaterAmount;
        }
        self.rainfall_m3[cell] += inputs.rainfall_m3;
        self.boundary_water_inflow_m3[cell] += inputs.boundary_water_inflow_m3;
        self.evaporation_m3[cell] += inputs.evaporation_m3;
        self.runoff_m3[cell] += inputs.runoff_m3;
        self.water_outflow_m3[cell] += inputs.water_outflow_m3;
        self.lateral_water_outflow_m3[cell] += inputs.lateral_water_outflow_m3;
        self.sediment_outflow_m3[cell] += inputs.sediment_outflow_m3;
        self.boundary_water_exchange_gain_m3[cell] += inputs.boundary_water_exchange_gain_m3;
        self.boundary_water_exchange_loss_m3[cell] += inputs.boundary_water_exchange_loss_m3;
        inline for (.{
            self.rainfall_m3[cell],
            self.boundary_water_inflow_m3[cell],
            self.evaporation_m3[cell],
            self.runoff_m3[cell],
            self.water_outflow_m3[cell],
            self.lateral_water_outflow_m3[cell],
            self.sediment_outflow_m3[cell],
            self.boundary_water_exchange_gain_m3[cell],
            self.boundary_water_exchange_loss_m3[cell],
        }) |value| if (!std.math.isFinite(value)) return error.InvalidDailyWaterLedger;
    }

    pub fn validateFinite(self: State) !void {
        inline for (.{
            self.rainfall_m3,
            self.boundary_water_inflow_m3,
            self.evaporation_m3,
            self.runoff_m3,
            self.water_outflow_m3,
            self.lateral_water_outflow_m3,
            self.sediment_outflow_m3,
            self.boundary_water_exchange_gain_m3,
            self.boundary_water_exchange_loss_m3,
        }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidDailyWaterLedger;
    }
};

pub const HourlyInputs = struct {
    rainfall_m3: []const f64,
    boundary_water_inflow_m3: []const f64,
    evaporation_m3: []const f64,
    runoff_m3: []const f64,
    water_outflow_m3: []const f64,
    lateral_water_outflow_m3: []const f64,
    sediment_outflow_m3: []const f64,
    boundary_water_exchange_gain_m3: []const f64,
    boundary_water_exchange_loss_m3: []const f64,
};

pub const CellHourlyInputs = struct {
    rainfall_m3: f64,
    boundary_water_inflow_m3: f64,
    evaporation_m3: f64,
    runoff_m3: f64,
    water_outflow_m3: f64,
    lateral_water_outflow_m3: f64,
    sediment_outflow_m3: f64,
    boundary_water_exchange_gain_m3: f64,
    boundary_water_exchange_loss_m3: f64,
};

test "OUTSD water ledger accumulates runtime cells and resets without allocation" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    const rainfall = [_]f64{ 1, 2 };
    const zero = [_]f64{ 0, 0 };
    const evaporation = [_]f64{ 0.1, 0.2 };
    const runoff = [_]f64{ 0.01, 0.02 };
    const outflow = [_]f64{ 0.03, 0.04 };
    const lateral = [_]f64{ 0.05, 0.06 };
    const sediment = [_]f64{ 0.07, 0.08 };
    const boundary_gain = [_]f64{ 0.09, 0.10 };
    const boundary_loss = [_]f64{ 0.11, 0.12 };
    const inputs: HourlyInputs = .{
        .rainfall_m3 = &rainfall,
        .boundary_water_inflow_m3 = &zero,
        .evaporation_m3 = &evaporation,
        .runoff_m3 = &runoff,
        .water_outflow_m3 = &outflow,
        .lateral_water_outflow_m3 = &lateral,
        .sediment_outflow_m3 = &sediment,
        .boundary_water_exchange_gain_m3 = &boundary_gain,
        .boundary_water_exchange_loss_m3 = &boundary_loss,
    };
    try state.accumulateHour(inputs);
    try state.accumulateHour(inputs);
    try std.testing.expectEqual(@as(f64, 4), state.rainfall_m3[1]);
    try std.testing.expectEqual(@as(f64, 0.16), state.sediment_outflow_m3[1]);
    try std.testing.expectEqual(@as(f64, 0.20), state.boundary_water_exchange_gain_m3[1]);
    try std.testing.expectEqual(@as(f64, 0.24), state.boundary_water_exchange_loss_m3[1]);
    state.resetDaily();
    try std.testing.expectEqual(@as(f64, 0), state.rainfall_m3[1]);
    try std.testing.expectEqual(@as(f64, 0), state.boundary_water_exchange_gain_m3[1]);
}

test "OUTSD water ledger rejects a late nonfinite input atomically" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    const zero = [_]f64{ 0, 0 };
    const invalid = [_]f64{ 0, std.math.nan(f64) };
    try std.testing.expectError(error.InvalidHourlyWaterAmount, state.accumulateHour(.{
        .rainfall_m3 = &zero,
        .boundary_water_inflow_m3 = &zero,
        .evaporation_m3 = &zero,
        .runoff_m3 = &zero,
        .water_outflow_m3 = &zero,
        .lateral_water_outflow_m3 = &zero,
        .sediment_outflow_m3 = &invalid,
        .boundary_water_exchange_gain_m3 = &zero,
        .boundary_water_exchange_loss_m3 = &zero,
    }));
    try std.testing.expectEqual(@as(f64, 0), state.rainfall_m3[0]);
}
