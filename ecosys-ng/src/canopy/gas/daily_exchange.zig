const std = @import("std");

/// Heap-owned ZCNET/ZHNET/ZONET canopy contributions. Positive exchange is
/// uptake from canopy air into the ecosystem, matching EXTRACT/REDIST.
pub const State = struct {
    allocator: std.mem.Allocator,
    net_carbon_dioxide_uptake_g_c: []f64,
    net_methane_uptake_g_c: []f64,
    net_oxygen_uptake_g_o: []f64,
    fire_carbon_dioxide_emission_g_c: []f64,
    fire_methane_emission_g_c: []f64,
    fire_oxygen_consumption_g_o: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroDailyCanopyGasCells;
        var result: State = undefined;
        result.allocator = allocator;
        inline for (@typeInfo(State).@"struct".fields[1..]) |field| {
            @field(result, field.name) = try allocator.alloc(f64, cell_count);
            errdefer allocator.free(@field(result, field.name));
            @memset(@field(result, field.name), 0);
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields[1..]) |field| self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn reset(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields[1..]) |field| @memset(@field(self, field.name), 0);
    }

    pub fn accumulateHour(
        self: *State,
        cell: usize,
        canopy_net_carbon_fixation_g_c: f64,
        fire_carbon_dioxide_emission_g_c: f64,
        fire_methane_emission_g_c: f64,
        fire_oxygen_consumption_g_o: f64,
        photosynthetic_oxygen_g_o_per_g_c: f64,
    ) !void {
        if (cell >= self.net_carbon_dioxide_uptake_g_c.len) return error.DailyCanopyGasCellOutOfBounds;
        inline for (.{ canopy_net_carbon_fixation_g_c, fire_carbon_dioxide_emission_g_c, fire_methane_emission_g_c, fire_oxygen_consumption_g_o, photosynthetic_oxygen_g_o_per_g_c }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteDailyCanopyGasExchange;
        if (fire_carbon_dioxide_emission_g_c < 0 or fire_methane_emission_g_c < 0 or fire_oxygen_consumption_g_o < 0 or photosynthetic_oxygen_g_o_per_g_c <= 0) return error.InvalidDailyCanopyGasExchange;
        const carbon_dioxide = self.net_carbon_dioxide_uptake_g_c[cell] + canopy_net_carbon_fixation_g_c - fire_carbon_dioxide_emission_g_c;
        const methane = self.net_methane_uptake_g_c[cell] - fire_methane_emission_g_c;
        const oxygen = self.net_oxygen_uptake_g_o[cell] - canopy_net_carbon_fixation_g_c * photosynthetic_oxygen_g_o_per_g_c + fire_oxygen_consumption_g_o;
        const fire_carbon_dioxide = self.fire_carbon_dioxide_emission_g_c[cell] + fire_carbon_dioxide_emission_g_c;
        const fire_methane = self.fire_methane_emission_g_c[cell] + fire_methane_emission_g_c;
        const fire_oxygen = self.fire_oxygen_consumption_g_o[cell] + fire_oxygen_consumption_g_o;
        inline for (.{ carbon_dioxide, methane, oxygen, fire_carbon_dioxide, fire_methane, fire_oxygen }) |value| if (!std.math.isFinite(value)) return error.NonFiniteDailyCanopyGasExchange;
        self.net_carbon_dioxide_uptake_g_c[cell] = carbon_dioxide;
        self.net_methane_uptake_g_c[cell] = methane;
        self.net_oxygen_uptake_g_o[cell] = oxygen;
        self.fire_carbon_dioxide_emission_g_c[cell] = fire_carbon_dioxide;
        self.fire_methane_emission_g_c[cell] = fire_methane;
        self.fire_oxygen_consumption_g_o[cell] = fire_oxygen;
    }
};

test "EXTRACT canopy exchange preserves fixation fire and oxygen signs" {
    var state = try State.init(std.testing.allocator, 7);
    defer state.deinit();
    try state.accumulateHour(6, 10, 2, 3, 4, 2.667);
    try std.testing.expectApproxEqAbs(@as(f64, 8), state.net_carbon_dioxide_uptake_g_c[6], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -3), state.net_methane_uptake_g_c[6], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -22.67), state.net_oxygen_uptake_g_o[6], 1e-12);
    try std.testing.expectEqual(@as(f64, 2), state.fire_carbon_dioxide_emission_g_c[6]);
    try std.testing.expectEqual(@as(f64, 3), state.fire_methane_emission_g_c[6]);
    try std.testing.expectEqual(@as(f64, 4), state.fire_oxygen_consumption_g_o[6]);
    state.reset();
    try std.testing.expectEqual(@as(f64, 0), state.net_carbon_dioxide_uptake_g_c[6]);
    try std.testing.expectEqual(@as(f64, 0), state.fire_carbon_dioxide_emission_g_c[6]);
    try std.testing.expectEqual(@as(f64, 0), state.fire_methane_emission_g_c[6]);
    try std.testing.expectEqual(@as(f64, 0), state.fire_oxygen_consumption_g_o[6]);
}
