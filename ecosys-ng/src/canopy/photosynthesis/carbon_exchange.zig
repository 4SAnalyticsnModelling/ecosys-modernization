const std = @import("std");
const Canopy = @import("photosynthesis.zig").State;

/// Heap-owned HCNET-equivalent hourly branch ledger. Positive values denote
/// atmospheric carbon fixed by the canopy; respiration, leakage, and
/// disturbance removals reduce net fixation.
pub const State = struct {
    allocator: std.mem.Allocator,
    fixed_carbon_g_c_per_h: []f64,
    shoot_respiration_g_c_per_h: []f64,
    c4_leakage_g_c_per_h: []f64,
    symbiont_respiration_g_c_per_h: []f64,
    disturbance_carbon_g_c_per_h: []f64,

    pub fn init(allocator: std.mem.Allocator, branch_count: usize) !State {
        if (branch_count == 0) return error.ZeroCanopyCarbonExchangeBranches;
        var result: State = undefined;
        result.allocator = allocator;
        inline for (@typeInfo(State).@"struct".fields[1..]) |field| {
            @field(result, field.name) = try allocator.alloc(f64, branch_count);
            errdefer allocator.free(@field(result, field.name));
            @memset(@field(result, field.name), 0);
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields[1..]) |field| self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn clone(self: *const State, allocator: std.mem.Allocator) !State {
        var result = try State.init(allocator, self.branchCount());
        errdefer result.deinit();
        inline for (@typeInfo(State).@"struct".fields[1..]) |field|
            @memcpy(@field(result, field.name), @field(self, field.name));
        return result;
    }

    pub fn reset(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields[1..]) |field| @memset(@field(self, field.name), 0);
    }

    pub fn branchCount(self: State) usize {
        return self.fixed_carbon_g_c_per_h.len;
    }

    pub fn netFixationForCell(self: State, canopy: *const Canopy, cell: usize) !f64 {
        if (cell >= canopy.cell_count or self.branchCount() != canopy.branch_node_offsets.len - 1) return error.CanopyCarbonExchangeDimensionMismatch;
        var net: f64 = 0;
        for (0..canopy.species_count) |species| {
            const plant = try canopy.plantIndex(cell, species);
            const branches = try canopy.branchRange(plant);
            for (branches.first..branches.end) |branch| {
                net += self.fixed_carbon_g_c_per_h[branch] -
                    self.shoot_respiration_g_c_per_h[branch] -
                    self.c4_leakage_g_c_per_h[branch] -
                    self.symbiont_respiration_g_c_per_h[branch] -
                    self.disturbance_carbon_g_c_per_h[branch];
            }
        }
        if (!std.math.isFinite(net)) return error.NonFiniteCanopyCarbonExchange;
        return net;
    }

    pub const PlantFlux = struct {
        net_co2_g_c_per_h: f64,
        signed_aboveground_respiration_g_c_per_h: f64,
    };

    /// Aggregates the source HCNET and signed TCO2A terms for one plant.
    pub fn fluxForPlant(self: State, canopy: *const Canopy, plant: usize) !PlantFlux {
        if (plant >= canopy.cell_count * canopy.species_count or self.branchCount() != canopy.branch_node_offsets.len - 1) return error.CanopyCarbonExchangeDimensionMismatch;
        const branches = try canopy.branchRange(plant);
        var net: f64 = 0;
        var respiration: f64 = 0;
        for (branches.first..branches.end) |branch| {
            const respiratory_loss = self.shoot_respiration_g_c_per_h[branch] +
                self.c4_leakage_g_c_per_h[branch] +
                self.symbiont_respiration_g_c_per_h[branch];
            respiration -= respiratory_loss;
            net += self.fixed_carbon_g_c_per_h[branch] - respiratory_loss -
                self.disturbance_carbon_g_c_per_h[branch];
        }
        if (!std.math.isFinite(net) or !std.math.isFinite(respiration)) return error.NonFiniteCanopyCarbonExchange;
        return .{ .net_co2_g_c_per_h = net, .signed_aboveground_respiration_g_c_per_h = respiration };
    }
};

test "HCNET branch ledger aggregates arbitrary runtime species and branches" {
    var canopy = try Canopy.init(std.testing.allocator, 1, 2, &.{ 2, 1 }, &.{ 1, 1, 1 }, &.{ 1, 1, 1 });
    defer canopy.deinit();
    var ledger = try State.init(std.testing.allocator, 3);
    defer ledger.deinit();
    ledger.fixed_carbon_g_c_per_h[0..3].* = .{ 10, 4, 2 };
    ledger.shoot_respiration_g_c_per_h[0..3].* = .{ 1, 1, 0.5 };
    ledger.c4_leakage_g_c_per_h[1] = 0.25;
    ledger.symbiont_respiration_g_c_per_h[2] = 0.5;
    ledger.disturbance_carbon_g_c_per_h[0] = 2;
    try std.testing.expectApproxEqAbs(@as(f64, 10.75), try ledger.netFixationForCell(&canopy, 0), 1e-15);
    const first_plant = try ledger.fluxForPlant(&canopy, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 9.75), first_plant.net_co2_g_c_per_h, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -2.25), first_plant.signed_aboveground_respiration_g_c_per_h, 1e-15);
    ledger.reset();
    try std.testing.expectEqual(@as(f64, 0), try ledger.netFixationForCell(&canopy, 0));
}
