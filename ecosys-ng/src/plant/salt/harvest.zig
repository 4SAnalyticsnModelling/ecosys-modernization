const std = @import("std");

/// Salt ordering in the GROSUB harvest/litterfall block. The set is a
/// scientific contract; branch, layer, and root-axis extents remain runtime
/// dimensions.
pub const salt_count = 8;

pub const Salt = enum(usize) {
    aluminum,
    iron,
    calcium,
    magnesium,
    sodium,
    potassium,
    sulfate,
    chloride,
};

/// Heap-owned salt inventories for one plant population. Salt arrays use
/// item-major ordering: `item * salt_count + @intFromEnum(salt)`.
pub const State = struct {
    allocator: std.mem.Allocator,
    layer_root_offsets: []usize,
    branch_salt_mol: []f64,
    root_salt_mol: []f64,
    cumulative_harvest_salt_mol: []f64,
    shoot_litterfall_salt_mol: []f64,
    root_litterfall_salt_mol_by_layer: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        branch_count: usize,
        root_axis_count_by_layer: []const usize,
    ) !State {
        if (branch_count == 0 or root_axis_count_by_layer.len == 0)
            return error.InvalidPlantSaltDimensions;

        const offsets = try allocator.alloc(usize, root_axis_count_by_layer.len + 1);
        errdefer allocator.free(offsets);
        offsets[0] = 0;
        for (root_axis_count_by_layer, 0..) |count, layer| {
            if (count == 0) return error.InvalidPlantSaltDimensions;
            offsets[layer + 1] = std.math.add(usize, offsets[layer], count) catch
                return error.InvalidPlantSaltDimensions;
        }

        const branch_values = std.math.mul(usize, branch_count, salt_count) catch
            return error.InvalidPlantSaltDimensions;
        const root_values = std.math.mul(usize, offsets[offsets.len - 1], salt_count) catch
            return error.InvalidPlantSaltDimensions;
        const litter_values = std.math.mul(usize, root_axis_count_by_layer.len, salt_count) catch
            return error.InvalidPlantSaltDimensions;

        const branch_salt = try allocator.alloc(f64, branch_values);
        errdefer allocator.free(branch_salt);
        const root_salt = try allocator.alloc(f64, root_values);
        errdefer allocator.free(root_salt);
        const harvest_salt = try allocator.alloc(f64, salt_count);
        errdefer allocator.free(harvest_salt);
        const shoot_litter_salt = try allocator.alloc(f64, salt_count);
        errdefer allocator.free(shoot_litter_salt);
        const litter_salt = try allocator.alloc(f64, litter_values);
        errdefer allocator.free(litter_salt);

        @memset(branch_salt, 0);
        @memset(root_salt, 0);
        @memset(harvest_salt, 0);
        @memset(shoot_litter_salt, 0);
        @memset(litter_salt, 0);
        return .{
            .allocator = allocator,
            .layer_root_offsets = offsets,
            .branch_salt_mol = branch_salt,
            .root_salt_mol = root_salt,
            .cumulative_harvest_salt_mol = harvest_salt,
            .shoot_litterfall_salt_mol = shoot_litter_salt,
            .root_litterfall_salt_mol_by_layer = litter_salt,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.root_litterfall_salt_mol_by_layer);
        self.allocator.free(self.shoot_litterfall_salt_mol);
        self.allocator.free(self.cumulative_harvest_salt_mol);
        self.allocator.free(self.root_salt_mol);
        self.allocator.free(self.branch_salt_mol);
        self.allocator.free(self.layer_root_offsets);
        self.* = undefined;
    }

    pub fn layerCount(self: State) usize {
        return self.layer_root_offsets.len - 1;
    }
};

pub const Inputs = struct {
    shoot_carbon_g_c: f64,
    current_harvest_carbon_g_c: f64,
    previous_harvest_carbon_g_c: f64,
    shoot_litterfall_carbon_g_c: f64,
    root_carbon_g_c: []const f64,
    root_litterfall_carbon_g_c_by_layer: []const f64,
    carbon_absolute_tolerance_g_c: f64,
    salt_absolute_tolerance_mol: f64,
    physical_relative_tolerance: f64,
};

/// Direct translation of grosub.f lines 12655–12890 for dynamic plant salts.
/// The routine validates every source and prospective result before mutating
/// any inventory, then retains the source statement and loop order.
pub fn removeForHarvestAndLitterfall(state: *State, inputs: Inputs) !void {
    try validateShapeAndInputs(state.*, inputs);
    try validateProspectiveUpdate(state.*, inputs);
    state_updateShootRemoval(state, inputs);
    state_updateRootRemoval(state, inputs);
}

fn validateShapeAndInputs(state: State, inputs: Inputs) !void {
    const root_count = state.layer_root_offsets[state.layer_root_offsets.len - 1];
    if (state.branch_salt_mol.len % salt_count != 0 or
        state.root_salt_mol.len != root_count * salt_count or
        state.cumulative_harvest_salt_mol.len != salt_count or
        state.shoot_litterfall_salt_mol.len != salt_count or
        state.root_litterfall_salt_mol_by_layer.len != state.layerCount() * salt_count or
        inputs.root_carbon_g_c.len != root_count or
        inputs.root_litterfall_carbon_g_c_by_layer.len != state.layerCount())
        return error.PlantSaltDimensionMismatch;

    inline for (.{
        inputs.shoot_carbon_g_c,
        inputs.current_harvest_carbon_g_c,
        inputs.previous_harvest_carbon_g_c,
        inputs.shoot_litterfall_carbon_g_c,
        inputs.carbon_absolute_tolerance_g_c,
        inputs.salt_absolute_tolerance_mol,
        inputs.physical_relative_tolerance,
    }) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantSaltState;
    if (inputs.shoot_carbon_g_c < 0 or
        inputs.current_harvest_carbon_g_c < 0 or
        inputs.previous_harvest_carbon_g_c < 0 or
        inputs.shoot_litterfall_carbon_g_c < 0 or
        inputs.carbon_absolute_tolerance_g_c < 0 or
        inputs.salt_absolute_tolerance_mol < 0 or
        inputs.physical_relative_tolerance < 0)
        return error.InvalidPlantSaltState;

    for (inputs.root_carbon_g_c) |value|
        if (!std.math.isFinite(value)) return error.NonFinitePlantSaltState else if (value < 0) return error.InvalidPlantSaltState;
    for (inputs.root_litterfall_carbon_g_c_by_layer) |value|
        if (!std.math.isFinite(value)) return error.NonFinitePlantSaltState else if (value < 0) return error.InvalidPlantSaltState;
    for (state.branch_salt_mol) |value|
        if (!std.math.isFinite(value)) return error.NonFinitePlantSaltState else if (value < 0) return error.InvalidPlantSaltState;
    for (state.root_salt_mol) |value|
        if (!std.math.isFinite(value)) return error.NonFinitePlantSaltState else if (value < 0) return error.InvalidPlantSaltState;
    for (state.cumulative_harvest_salt_mol) |value|
        if (!std.math.isFinite(value)) return error.NonFinitePlantSaltState else if (value < 0) return error.InvalidPlantSaltState;
    for (state.shoot_litterfall_salt_mol) |value|
        if (!std.math.isFinite(value)) return error.NonFinitePlantSaltState else if (value < 0) return error.InvalidPlantSaltState;
    for (state.root_litterfall_salt_mol_by_layer) |value|
        if (!std.math.isFinite(value)) return error.NonFinitePlantSaltState else if (value < 0) return error.InvalidPlantSaltState;
}

fn validateProspectiveUpdate(state: State, inputs: Inputs) !void {
    const branch_count = state.branch_salt_mol.len / salt_count;
    if (present(inputs.shoot_carbon_g_c, inputs.carbon_absolute_tolerance_g_c, inputs.physical_relative_tolerance)) {
        const harvest_fraction = @min(
            1.0,
            @max(0.0, inputs.current_harvest_carbon_g_c - inputs.previous_harvest_carbon_g_c) /
                inputs.shoot_carbon_g_c,
        );
        const litter_fraction = @min(1.0, inputs.shoot_litterfall_carbon_g_c / inputs.shoot_carbon_g_c);
        for (0..salt_count) |salt| {
            const total = sumSalt(state.branch_salt_mol, branch_count, salt);
            const removed = (harvest_fraction + litter_fraction) * total;
            if (!std.math.isFinite(removed) or removed > total)
                return error.InvalidPlantSaltRemoval;
            if (!std.math.isFinite(state.cumulative_harvest_salt_mol[salt] + harvest_fraction * total))
                return error.NonFinitePlantSaltState;
        }
    }

    for (0..state.layerCount()) |layer| {
        const start = state.layer_root_offsets[layer];
        const end = state.layer_root_offsets[layer + 1];
        var total_carbon: f64 = 0;
        for (inputs.root_carbon_g_c[start..end]) |carbon| total_carbon += carbon;
        total_carbon += inputs.root_litterfall_carbon_g_c_by_layer[layer];
        if (!std.math.isFinite(total_carbon)) return error.NonFinitePlantSaltState;
        if (present(total_carbon, inputs.carbon_absolute_tolerance_g_c, inputs.physical_relative_tolerance)) {
            const fraction = inputs.root_litterfall_carbon_g_c_by_layer[layer] / total_carbon;
            if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
                return error.InvalidPlantSaltRemoval;
            for (0..salt_count) |salt| {
                const total = sumSalt(
                    state.root_salt_mol[start * salt_count .. end * salt_count],
                    end - start,
                    salt,
                );
                const litter = fraction * total;
                if (!std.math.isFinite(total) or !std.math.isFinite(litter) or litter > total)
                    return error.InvalidPlantSaltRemoval;
            }
        }
    }
}

fn state_updateShootRemoval(state: *State, inputs: Inputs) void {
    const branch_count = state.branch_salt_mol.len / salt_count;
    if (!present(inputs.shoot_carbon_g_c, inputs.carbon_absolute_tolerance_g_c, inputs.physical_relative_tolerance)) {
        @memset(state.shoot_litterfall_salt_mol, 0);
        return;
    }

    const harvest_fraction = @min(
        1.0,
        @max(0.0, inputs.current_harvest_carbon_g_c - inputs.previous_harvest_carbon_g_c) /
            inputs.shoot_carbon_g_c,
    );
    const litter_fraction = @min(1.0, inputs.shoot_litterfall_carbon_g_c / inputs.shoot_carbon_g_c);
    for (0..salt_count) |salt| {
        const total = sumSalt(state.branch_salt_mol, branch_count, salt);
        const harvest = harvest_fraction * total;
        const litter = litter_fraction * total;
        state.cumulative_harvest_salt_mol[salt] += harvest;
        state.shoot_litterfall_salt_mol[salt] = litter;
        if (present(total, inputs.salt_absolute_tolerance_mol, inputs.physical_relative_tolerance)) {
            for (0..branch_count) |branch| {
                const index = branch * salt_count + salt;
                const branch_fraction = state.branch_salt_mol[index] / total;
                state.branch_salt_mol[index] -= (harvest + litter) * branch_fraction;
            }
        }
    }
}

// Uses a single scalar physical-tolerance parameter, already scoped to the
// correct cell, rather than indexing a (plant, row, column) epsilon table.
// Deliberately does not reproduce the legacy f77src/grosub.f:12825
// `ZEROP(NZ,NY,NZ)` wrong-grid-index copy-paste bug (17 sibling guards use
// `ZEROP(NZ,NY,NX)`; only this one substitutes NZ for NX) -- see
// audit/issues/issue-025-grosub-litterfall-salt-zerop-column-index-typo.md.
// This class of cross-index substitution cannot occur here by construction;
// do not "fix" this to reintroduce a per-column epsilon lookup that could
// carry the same bug.
fn state_updateRootRemoval(state: *State, inputs: Inputs) void {
    for (0..state.layerCount()) |layer| {
        const start = state.layer_root_offsets[layer];
        const end = state.layer_root_offsets[layer + 1];
        var total_carbon: f64 = 0;
        for (inputs.root_carbon_g_c[start..end]) |carbon| total_carbon += carbon;
        total_carbon += inputs.root_litterfall_carbon_g_c_by_layer[layer];
        const output = state.root_litterfall_salt_mol_by_layer[layer * salt_count ..][0..salt_count];
        if (!present(total_carbon, inputs.carbon_absolute_tolerance_g_c, inputs.physical_relative_tolerance)) {
            @memset(output, 0);
            continue;
        }
        const litter_fraction = inputs.root_litterfall_carbon_g_c_by_layer[layer] / total_carbon;
        for (0..salt_count) |salt| {
            const total = sumSalt(state.root_salt_mol[start * salt_count .. end * salt_count], end - start, salt);
            const litter = litter_fraction * total;
            output[salt] = litter;
            if (present(total, inputs.salt_absolute_tolerance_mol, inputs.physical_relative_tolerance)) {
                for (start..end) |root| {
                    const index = root * salt_count + salt;
                    const root_fraction = state.root_salt_mol[index] / total;
                    state.root_salt_mol[index] -= litter * root_fraction;
                }
            }
        }
    }
}

fn present(value: f64, absolute_tolerance: f64, relative_tolerance: f64) bool {
    return value > absolute_tolerance + relative_tolerance * @abs(value);
}

fn sumSalt(values: []const f64, item_count: usize, salt: usize) f64 {
    var total: f64 = 0;
    for (0..item_count) |item| total += values[item * salt_count + salt];
    return total;
}

test "GROSUB shoot and root salt removal conserves all eight molar pools" {
    var state = try State.init(std.testing.allocator, 2, &.{ 2, 1 });
    defer state.deinit();
    for (0..salt_count) |salt| {
        state.branch_salt_mol[salt] = @floatFromInt(salt + 1);
        state.branch_salt_mol[salt_count + salt] = @floatFromInt(3 * (salt + 1));
        state.root_salt_mol[salt] = @floatFromInt(salt + 1);
        state.root_salt_mol[salt_count + salt] = @floatFromInt(salt + 1);
        state.root_salt_mol[2 * salt_count + salt] = @floatFromInt(2 * (salt + 1));
    }

    try removeForHarvestAndLitterfall(&state, .{
        .shoot_carbon_g_c = 100,
        .current_harvest_carbon_g_c = 25,
        .previous_harvest_carbon_g_c = 5,
        .shoot_litterfall_carbon_g_c = 10,
        .root_carbon_g_c = &.{ 20, 20, 30 },
        .root_litterfall_carbon_g_c_by_layer = &.{ 10, 10 },
        // Deliberately exceeds every salt inventory: reusing this carbon-unit
        // floor for molar salt redistribution would violate conservation.
        .carbon_absolute_tolerance_g_c = 10,
        .salt_absolute_tolerance_mol = 1e-14,
        .physical_relative_tolerance = 1e-12,
    });

    for (0..salt_count) |salt| {
        const unit: f64 = @floatFromInt(salt + 1);
        try std.testing.expectApproxEqAbs(0.8 * unit, state.cumulative_harvest_salt_mol[salt], 1e-14);
        try std.testing.expectApproxEqAbs(0.4 * unit, state.shoot_litterfall_salt_mol[salt], 1e-14);
        try std.testing.expectApproxEqAbs(0.4 * unit, state.root_litterfall_salt_mol_by_layer[salt], 1e-14);
        try std.testing.expectApproxEqAbs(0.5 * unit, state.root_litterfall_salt_mol_by_layer[salt_count + salt], 1e-14);
        const shoot_remaining = state.branch_salt_mol[salt] + state.branch_salt_mol[salt_count + salt];
        try std.testing.expectApproxEqAbs(4 * unit, shoot_remaining + 0.8 * unit + 0.4 * unit, 1e-13);
        const root_remaining = state.root_salt_mol[salt] +
            state.root_salt_mol[salt_count + salt] +
            state.root_salt_mol[2 * salt_count + salt];
        try std.testing.expectApproxEqAbs(4 * unit, root_remaining + 0.4 * unit + 0.5 * unit, 1e-13);
    }
}

test "GROSUB plant salt removal rejects a late invalid root atomically" {
    var state = try State.init(std.testing.allocator, 1, &.{ 1, 1 });
    defer state.deinit();
    @memset(state.branch_salt_mol, 2);
    @memset(state.root_salt_mol, 3);
    state.root_salt_mol[state.root_salt_mol.len - 1] = std.math.nan(f64);
    @memset(state.cumulative_harvest_salt_mol, 4);
    @memset(state.shoot_litterfall_salt_mol, 5);
    @memset(state.root_litterfall_salt_mol_by_layer, 6);

    const branch_before = try std.testing.allocator.dupe(f64, state.branch_salt_mol);
    defer std.testing.allocator.free(branch_before);
    const root_before = try std.testing.allocator.dupe(f64, state.root_salt_mol);
    defer std.testing.allocator.free(root_before);
    const harvest_before = try std.testing.allocator.dupe(f64, state.cumulative_harvest_salt_mol);
    defer std.testing.allocator.free(harvest_before);
    const shoot_litter_before = try std.testing.allocator.dupe(f64, state.shoot_litterfall_salt_mol);
    defer std.testing.allocator.free(shoot_litter_before);
    const root_litter_before = try std.testing.allocator.dupe(f64, state.root_litterfall_salt_mol_by_layer);
    defer std.testing.allocator.free(root_litter_before);

    try std.testing.expectError(error.NonFinitePlantSaltState, removeForHarvestAndLitterfall(&state, .{
        .shoot_carbon_g_c = 10,
        .current_harvest_carbon_g_c = 2,
        .previous_harvest_carbon_g_c = 1,
        .shoot_litterfall_carbon_g_c = 1,
        .root_carbon_g_c = &.{ 3, 3 },
        .root_litterfall_carbon_g_c_by_layer = &.{ 1, 1 },
        .carbon_absolute_tolerance_g_c = 1e-12,
        .salt_absolute_tolerance_mol = 1e-14,
        .physical_relative_tolerance = 1e-12,
    }));
    try std.testing.expectEqualSlices(f64, branch_before, state.branch_salt_mol);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(root_before),
        std.mem.sliceAsBytes(state.root_salt_mol),
    );
    try std.testing.expectEqualSlices(f64, harvest_before, state.cumulative_harvest_salt_mol);
    try std.testing.expectEqualSlices(f64, shoot_litter_before, state.shoot_litterfall_salt_mol);
    try std.testing.expectEqualSlices(f64, root_litter_before, state.root_litterfall_salt_mol_by_layer);
}
