const std = @import("std");
const root_metabolism = @import("plant_root_metabolism.zig");

/// Authoritative hourly GROSUB CSNCL root-carbon source, retained at
/// plant × biological-domain × soil-layer resolution.
pub const State = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,
    biological_domain_count: usize,
    soil_layer_count: usize,
    carbon_g_c: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        plant_count: usize,
        biological_domain_count: usize,
        soil_layer_count: usize,
    ) !State {
        if (plant_count == 0 or biological_domain_count == 0 or soil_layer_count == 0)
            return error.InvalidRootLitterLedgerDimensions;
        const count = std.math.mul(
            usize,
            try std.math.mul(usize, plant_count, biological_domain_count),
            soil_layer_count,
        ) catch return error.InvalidRootLitterLedgerDimensions;
        const values = try allocator.alloc(f64, count);
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .plant_count = plant_count,
            .biological_domain_count = biological_domain_count,
            .soil_layer_count = soil_layer_count,
            .carbon_g_c = values,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.carbon_g_c);
        self.* = undefined;
    }

    pub fn resetHourly(self: *State) void {
        @memset(self.carbon_g_c, 0);
    }

    pub fn validateDimensions(
        self: State,
        plant_count: usize,
        biological_domain_count: usize,
        soil_layer_count: usize,
    ) !void {
        if (self.plant_count != plant_count or
            self.biological_domain_count != biological_domain_count or
            self.soil_layer_count != soil_layer_count or
            self.carbon_g_c.len != plant_count * biological_domain_count * soil_layer_count)
            return error.RootLitterLedgerDimensionMismatch;
    }

    pub fn index(self: State, plant: usize, domain: usize, layer: usize) !usize {
        if (plant >= self.plant_count or
            domain >= self.biological_domain_count or
            layer >= self.soil_layer_count)
            return error.RootLitterLedgerIndexOutOfBounds;
        return (plant * self.biological_domain_count + domain) *
            self.soil_layer_count + layer;
    }

    /// Prevalidates and state_updates one already-accepted litter state_update.
    pub fn add(
        self: *State,
        plant: usize,
        domain: usize,
        layer: usize,
        litter: root_metabolism.RootLitter,
    ) !void {
        try self.validateAdd(plant, domain, layer, litter);
        self.addValidated(plant, domain, layer, litter);
    }

    pub fn validateAdd(
        self: State,
        plant: usize,
        domain: usize,
        layer: usize,
        litter: root_metabolism.RootLitter,
    ) !void {
        const carbon = try totalCarbon(litter);
        try self.validateCarbonAdd(plant, domain, layer, carbon);
    }

    pub fn validateCarbonAdd(
        self: State,
        plant: usize,
        domain: usize,
        layer: usize,
        carbon_g_c: f64,
    ) !void {
        if (!std.math.isFinite(carbon_g_c) or carbon_g_c < 0)
            return error.InvalidRootLitterLedgerInput;
        const next = self.carbon_g_c[try self.index(plant, domain, layer)] + carbon_g_c;
        if (!std.math.isFinite(next) or next < 0) return error.NonFiniteRootLitterLedger;
    }

    pub fn addValidated(
        self: *State,
        plant: usize,
        domain: usize,
        layer: usize,
        litter: root_metabolism.RootLitter,
    ) void {
        // Callers use this only after either the corresponding RootLitter has
        // entered the finite, non-negative whole-plant aggregate or the full
        // same-destination management addition was prevalidated explicitly.
        // With dimensions checked before science, no failure remains here.
        const carbon = totalCarbon(litter) catch unreachable;
        const destination = self.index(plant, domain, layer) catch unreachable;
        self.carbon_g_c[destination] += carbon;
    }

    pub fn carbonByPlantLayer(
        self: State,
        plant: usize,
        active_domain_count: usize,
        destination_g_c_by_layer: []f64,
    ) !void {
        if (active_domain_count == 0 or
            active_domain_count > self.biological_domain_count or
            destination_g_c_by_layer.len != self.soil_layer_count)
            return error.RootLitterLedgerDimensionMismatch;
        @memset(destination_g_c_by_layer, 0);
        for (0..self.soil_layer_count) |layer| {
            for (0..active_domain_count) |domain| {
                destination_g_c_by_layer[layer] +=
                    self.carbon_g_c[try self.index(plant, domain, layer)];
                if (!std.math.isFinite(destination_g_c_by_layer[layer]))
                    return error.NonFiniteRootLitterLedger;
            }
        }
    }
};

pub fn totalCarbon(litter: root_metabolism.RootLitter) !f64 {
    var total_g_c: f64 = 0;
    inline for (.{ litter.woody_carbon_g_c, litter.nonwoody_carbon_g_c }) |components| {
        for (components) |carbon_g_c| {
            if (!std.math.isFinite(carbon_g_c) or carbon_g_c < 0)
                return error.InvalidRootLitterLedgerInput;
            total_g_c += carbon_g_c;
            if (!std.math.isFinite(total_g_c)) return error.NonFiniteRootLitterLedger;
        }
    }
    return total_g_c;
}

test "layer-resolved root litter preserves plant domain layer order and conservation" {
    var state = try State.init(std.testing.allocator, 2, 2, 3);
    defer state.deinit();
    var litter = std.mem.zeroes(root_metabolism.RootLitter);
    litter.woody_carbon_g_c = .{ 1, 2, 3, 4 };
    litter.nonwoody_carbon_g_c = .{ 5, 6, 7, 8 };
    try state.add(1, 0, 2, litter);
    try state.add(1, 1, 2, litter);

    var by_layer = [_]f64{0} ** 3;
    try state.carbonByPlantLayer(1, 2, &by_layer);
    try std.testing.expectEqual(@as(f64, 0), by_layer[0]);
    try std.testing.expectEqual(@as(f64, 0), by_layer[1]);
    try std.testing.expectEqual(@as(f64, 72), by_layer[2]);
    for (state.carbon_g_c[0 .. 2 * 3]) |neighbor|
        try std.testing.expectEqual(@as(f64, 0), neighbor);
}

test "late invalid root litter leaves every ledger owner unchanged" {
    var state = try State.init(std.testing.allocator, 2, 2, 2);
    defer state.deinit();
    @memset(state.carbon_g_c, 4);
    const before = try std.testing.allocator.dupe(f64, state.carbon_g_c);
    defer std.testing.allocator.free(before);
    var litter = std.mem.zeroes(root_metabolism.RootLitter);
    litter.nonwoody_carbon_g_c[3] = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidRootLitterLedgerInput,
        state.add(1, 1, 1, litter),
    );
    try std.testing.expectEqualSlices(f64, before, state.carbon_g_c);
}
