const std = @import("std");
const roots = @import("../root/plant_root_system.zig");

/// Exact accepted cross-scope plant transfer. Positive values are extensive
/// amounts, never signed nets. C/N/P are grams of element and the eight
/// dynamic plant salts retain their native molar units and source order.
pub const Transfer = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
    salt_mol: [roots.salt_species_count]f64 = [_]f64{0} ** roots.salt_species_count,
};

/// Producer-owned, direction-separated sidecar for GROSUB transfers between
/// the canopy inventory and resolved root-layer inventories. Indexing is
/// horizontal cell major, soil layer minor. It is reset for every fixed hour
/// and published once, atomically, into layer-local conservation.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    soil_layer_count: usize,
    canopy_to_root: []Transfer,
    root_to_canopy: []Transfer,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, soil_layer_count: usize) !State {
        if (cell_count == 0 or soil_layer_count == 0)
            return error.InvalidPlantInternalActivityDimensions;
        const count = try std.math.mul(usize, cell_count, soil_layer_count);
        const canopy_to_root = try allocator.alloc(Transfer, count);
        errdefer allocator.free(canopy_to_root);
        const root_to_canopy = try allocator.alloc(Transfer, count);
        @memset(canopy_to_root, .{});
        @memset(root_to_canopy, .{});
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .soil_layer_count = soil_layer_count,
            .canopy_to_root = canopy_to_root,
            .root_to_canopy = root_to_canopy,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.root_to_canopy);
        self.allocator.free(self.canopy_to_root);
        self.* = undefined;
    }

    pub fn reset(self: *State) void {
        @memset(self.canopy_to_root, .{});
        @memset(self.root_to_canopy, .{});
    }

    fn index(self: *const State, cell: usize, layer: usize) !usize {
        if (cell >= self.cell_count or layer >= self.soil_layer_count)
            return error.PlantInternalActivityIndexOutOfBounds;
        return cell * self.soil_layer_count + layer;
    }

    pub fn recordCanopyToRoot(self: *State, cell: usize, layer: usize, transfer: Transfer) !void {
        const index_value = try self.index(cell, layer);
        var next = self.canopy_to_root[index_value];
        try add(&next, transfer);
        self.canopy_to_root[index_value] = next;
    }

    pub fn recordRootToCanopy(self: *State, cell: usize, layer: usize, transfer: Transfer) !void {
        const index_value = try self.index(cell, layer);
        var next = self.root_to_canopy[index_value];
        try add(&next, transfer);
        self.root_to_canopy[index_value] = next;
    }

    /// Positive components move canopy to root; negative components move root
    /// to canopy. Each element keeps its own direction because GROSUB permits
    /// C, N, P and individual salt gradients to oppose one another.
    pub fn recordSignedCanopyToRoot(self: *State, cell: usize, layer: usize, signed: Transfer) !void {
        var canopy_to_root: Transfer = .{};
        var root_to_canopy: Transfer = .{};
        inline for (.{ "carbon_g_c", "nitrogen_g_n", "phosphorus_g_p" }) |field| {
            const value = @field(signed, field);
            if (!std.math.isFinite(value)) return error.InvalidPlantInternalActivity;
            if (value >= 0)
                @field(canopy_to_root, field) = value
            else
                @field(root_to_canopy, field) = -value;
        }
        for (signed.salt_mol, 0..) |value, salt| {
            if (!std.math.isFinite(value)) return error.InvalidPlantInternalActivity;
            if (value >= 0)
                canopy_to_root.salt_mol[salt] = value
            else
                root_to_canopy.salt_mol[salt] = -value;
        }
        // Preflight both destinations so one direction can never be published
        // without the other when opposing element gradients occur.
        const index_value = try self.index(cell, layer);
        var next_canopy_to_root = self.canopy_to_root[index_value];
        var next_root_to_canopy = self.root_to_canopy[index_value];
        try add(&next_canopy_to_root, canopy_to_root);
        try add(&next_root_to_canopy, root_to_canopy);
        self.canopy_to_root[index_value] = next_canopy_to_root;
        self.root_to_canopy[index_value] = next_root_to_canopy;
    }
};

fn add(destination: *Transfer, increment: Transfer) !void {
    inline for (.{ "carbon_g_c", "nitrogen_g_n", "phosphorus_g_p" }) |field| {
        const value = @field(increment, field);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPlantInternalActivity;
        const next = @field(destination, field) + value;
        if (!std.math.isFinite(next)) return error.PlantInternalActivityOverflow;
        @field(destination, field) = next;
    }
    for (increment.salt_mol, 0..) |value, salt| {
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPlantInternalActivity;
        const next = destination.salt_mol[salt] + value;
        if (!std.math.isFinite(next)) return error.PlantInternalActivityOverflow;
        destination.salt_mol[salt] = next;
    }
}

test "plant internal sidecar retains opposing element directions atomically" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    var signed: Transfer = .{
        .carbon_g_c = 2,
        .nitrogen_g_n = -0.25,
        .phosphorus_g_p = 0.1,
    };
    signed.salt_mol[0] = -3;
    signed.salt_mol[1] = 4;
    try state.recordSignedCanopyToRoot(0, 1, signed);
    try std.testing.expectEqual(@as(f64, 2), state.canopy_to_root[1].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0.25), state.root_to_canopy[1].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 3), state.root_to_canopy[1].salt_mol[0]);
    try std.testing.expectEqual(@as(f64, 4), state.canopy_to_root[1].salt_mol[1]);

    const before = state.canopy_to_root[1];
    signed.phosphorus_g_p = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidPlantInternalActivity,
        state.recordSignedCanopyToRoot(0, 1, signed),
    );
    try std.testing.expectEqualDeep(before, state.canopy_to_root[1]);

    var directional: Transfer = .{ .carbon_g_c = 7, .nitrogen_g_n = 2 };
    directional.salt_mol[roots.salt_species_count - 1] = std.math.nan(f64);
    const before_directional = state.root_to_canopy[1];
    try std.testing.expectError(
        error.InvalidPlantInternalActivity,
        state.recordRootToCanopy(0, 1, directional),
    );
    try std.testing.expectEqualDeep(before_directional, state.root_to_canopy[1]);
}
