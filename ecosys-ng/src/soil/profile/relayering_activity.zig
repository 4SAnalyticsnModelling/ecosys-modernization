const std = @import("std");
const inventory = @import("../../validation/landscape_mass_inventory_support.zig");

/// Canonical layer-storage sampler supplied by the conservation composition
/// root. REDIST owns the exact sampling time and donor/recipient identity; the
/// sampler only reconstructs the named authoritative owners at that instant.
pub const SnapshotSource = struct {
    context: *anyopaque,
    capture_fn: *const fn (
        context: *anyopaque,
        cell: usize,
        local_layer: usize,
        live_soil_mass_megagrams: []const f64,
    ) anyerror!inventory.Storage,

    pub fn capture(
        self: SnapshotSource,
        cell: usize,
        local_layer: usize,
        live_soil_mass_megagrams: []const f64,
    ) !inventory.Storage {
        const result = try self.capture_fn(
            self.context,
            cell,
            local_layer,
            live_soil_mass_megagrams,
        );
        try result.validate();
        return result;
    }
};

pub const Binding = struct {
    sidecar: *Sidecar,
    snapshot_source: SnapshotSource,
};

/// Conservation comparison parameters. Absolute floors are quantity-specific
/// and expressed in each `Storage` field's native unit. The relative term is
/// dimensionless. A small representation term scales only with the actual
/// operands; it is not a physical acceptance tolerance.
pub const Tolerance = struct {
    absolute: inventory.Storage = .{},
    relative: f64,
    representation_ulps: u16 = 64,

    pub fn validate(self: Tolerance) !void {
        try self.absolute.validate();
        inline for (std.meta.fields(inventory.Storage)) |field|
            if (@field(self.absolute, field.name) < 0)
                return error.InvalidRelayeringActivityTolerance;
        if (!std.math.isFinite(self.relative) or self.relative < 0 or
            self.representation_ulps == 0)
            return error.InvalidRelayeringActivityTolerance;
    }
};

pub const Direction = enum(u8) {
    none,
    upper_to_lower,
    lower_to_upper,
};

/// One accepted internal face. `transfer` remains split into the canonical
/// storage coordinates until the layer ledger performs its single documented
/// C/N/P aggregation. No signed net is retained.
pub const Record = struct {
    direction: Direction = .none,
    /// Frozen material may carry negative enthalpy against the liquid-at-0-K
    /// reference. Removing it raises donor heat storage and adding it lowers
    /// recipient heat storage, so its ledger direction is then opposite the
    /// material direction. `transfer.heat_megajoules` is always a magnitude.
    heat_direction: Direction = .none,
    transfer: inventory.Storage = .{},
};

/// Attempt-atomic output for all internal soil faces. `accepted` is stable
/// across a failed retry; mutations are accumulated in `staged` and copied
/// only by `commitAttempt` after REDIST and geometry acceptance both succeed.
pub const Sidecar = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    layer_capacity: usize,
    tolerance: Tolerance,
    accepted: []Record,
    staged: []Record,
    attempt_active: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        layer_capacity: usize,
        tolerance: Tolerance,
    ) !Sidecar {
        if (cell_count == 0 or layer_capacity == 0)
            return error.InvalidRelayeringActivityDimensions;
        try tolerance.validate();
        const count = try std.math.mul(usize, cell_count, layer_capacity);
        const accepted = try allocator.alloc(Record, count);
        errdefer allocator.free(accepted);
        const staged = try allocator.alloc(Record, count);
        @memset(accepted, .{});
        @memset(staged, .{});
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .layer_capacity = layer_capacity,
            .tolerance = tolerance,
            .accepted = accepted,
            .staged = staged,
        };
    }

    pub fn deinit(self: *Sidecar) void {
        self.allocator.free(self.staged);
        self.allocator.free(self.accepted);
        self.* = undefined;
    }

    pub fn validateLayout(self: *const Sidecar, cell_count: usize, layer_capacity: usize) !void {
        if (self.cell_count != cell_count or self.layer_capacity != layer_capacity or
            self.accepted.len != try std.math.mul(usize, cell_count, layer_capacity) or
            self.staged.len != self.accepted.len)
            return error.RelayeringActivityDimensionMismatch;
        try self.tolerance.validate();
    }

    pub fn beginAttempt(self: *Sidecar) !void {
        if (self.attempt_active) return error.RelayeringActivityAttemptAlreadyActive;
        @memset(self.staged, .{});
        self.attempt_active = true;
    }

    pub fn abortAttempt(self: *Sidecar) void {
        if (!self.attempt_active) return;
        @memset(self.staged, .{});
        self.attempt_active = false;
    }

    pub fn commitAttempt(self: *Sidecar) !void {
        if (!self.attempt_active) return error.RelayeringActivityAttemptNotActive;
        @memcpy(self.accepted, self.staged);
        self.attempt_active = false;
    }

    pub fn captureLayer(
        self: *const Sidecar,
        snapshot_source: SnapshotSource,
        cell: usize,
        local_layer: usize,
        live_soil_mass_megagrams: []const f64,
    ) !inventory.Storage {
        if (!self.attempt_active) return error.RelayeringActivityAttemptNotActive;
        if (cell >= self.cell_count or local_layer >= self.layer_capacity)
            return error.RelayeringActivityLayerOutOfBounds;
        return snapshot_source.capture(
            cell,
            local_layer,
            live_soil_mass_megagrams,
        );
    }

    /// Accept one source-ordered REDIST boundary. Every canonical quantity
    /// except signed enthalpy must be non-increasing in the named donor,
    /// non-decreasing in the named recipient, and close independently. That is
    /// valid here because a single REDIST boundary is strictly one-way; unlike
    /// tillage, no pooled reverse path exists inside this transaction.
    pub fn stageBoundary(
        self: *Sidecar,
        cell: usize,
        donor_layer: usize,
        recipient_layer: usize,
        donor_before: inventory.Storage,
        recipient_before: inventory.Storage,
        donor_after: inventory.Storage,
        recipient_after: inventory.Storage,
    ) !void {
        if (!self.attempt_active) return error.RelayeringActivityAttemptNotActive;
        if (cell >= self.cell_count or donor_layer >= self.layer_capacity or
            recipient_layer >= self.layer_capacity or donor_layer == recipient_layer or
            @max(donor_layer, recipient_layer) - @min(donor_layer, recipient_layer) != 1)
            return error.InvalidRelayeringActivityBoundary;
        inline for (.{ donor_before, recipient_before, donor_after, recipient_after }) |storage|
            try storage.validate();

        const upper = @min(donor_layer, recipient_layer);
        const index = cell * self.layer_capacity + upper;
        if (self.staged[index].direction != .none)
            return error.DuplicateRelayeringActivityBoundary;
        var transfer: inventory.Storage = .{};
        var heat_direction: Direction = .none;
        inline for (std.meta.fields(inventory.Storage)) |field| {
            const before_donor = @field(donor_before, field.name);
            const after_donor = @field(donor_after, field.name);
            const before_recipient = @field(recipient_before, field.name);
            const after_recipient = @field(recipient_after, field.name);
            const raw_loss = before_donor - after_donor;
            const raw_gain = after_recipient - before_recipient;
            const scale = @max(
                @max(@abs(before_donor), @abs(after_donor)),
                @max(@abs(before_recipient), @abs(after_recipient)),
            );
            const allowed = @field(self.tolerance.absolute, field.name) +
                self.tolerance.relative * scale +
                @as(f64, @floatFromInt(self.tolerance.representation_ulps)) *
                    std.math.floatEps(f64) * scale;
            if (!std.math.isFinite(raw_loss) or !std.math.isFinite(raw_gain) or
                !std.math.isFinite(allowed))
                return error.InvalidRelayeringActivityDelta;
            if (comptime std.mem.eql(u8, field.name, "heat_megajoules")) {
                // Heat is the sole signed storage coordinate. The two signed
                // deltas must still agree; only their ledger direction changes.
                if (@abs(raw_loss - raw_gain) > allowed)
                    return error.RelayeringActivityConservationFailure;
                const signed_amount = if (@abs(raw_loss) > 0) raw_loss else raw_gain;
                @field(transfer, field.name) = @abs(signed_amount);
                heat_direction = if (signed_amount > 0)
                    (if (donor_layer == upper) .upper_to_lower else .lower_to_upper)
                else if (signed_amount < 0)
                    (if (donor_layer == upper) .lower_to_upper else .upper_to_lower)
                else
                    .none;
            } else {
                if (raw_loss < -allowed or raw_gain < -allowed)
                    return error.ReversedRelayeringActivity;
                const loss = if (raw_loss > 0) raw_loss else 0;
                const gain = if (raw_gain > 0) raw_gain else 0;
                if (@abs(loss - gain) > allowed)
                    return error.RelayeringActivityConservationFailure;
                // Donor loss is the producer-side debit. When it rounds to zero
                // but the matching recipient addition remains representable,
                // retain the latter rather than dropping a real sub-ULP transfer.
                @field(transfer, field.name) = if (loss > 0) loss else gain;
            }
        }
        try transfer.validate();
        inline for (std.meta.fields(inventory.Storage)) |field|
            if (@field(transfer, field.name) < 0)
                return error.InvalidRelayeringActivityDelta;
        self.staged[index] = .{
            .direction = if (donor_layer == upper) .upper_to_lower else .lower_to_upper,
            .heat_direction = heat_direction,
            .transfer = transfer,
        };
    }

    pub fn record(self: *const Sidecar, cell: usize, upper_layer: usize) !Record {
        if (cell >= self.cell_count or upper_layer >= self.layer_capacity)
            return error.RelayeringActivityLayerOutOfBounds;
        return self.accepted[cell * self.layer_capacity + upper_layer];
    }
};

test "relayering activity retains exact lower-to-upper donor debit and recipient credit" {
    var sidecar = try Sidecar.init(
        std.testing.allocator,
        1,
        2,
        .{ .relative = 32 * std.math.floatEps(f64) },
    );
    defer sidecar.deinit();
    try sidecar.beginAttempt();
    try sidecar.stageBoundary(
        0,
        1,
        0,
        .{ .water_m3 = 10, .residue_carbon_g = 3 },
        .{ .water_m3 = 2, .residue_carbon_g = 4 },
        .{ .water_m3 = 6, .residue_carbon_g = 2 },
        .{ .water_m3 = 6, .residue_carbon_g = 5 },
    );
    try sidecar.commitAttempt();
    const accepted = try sidecar.record(0, 0);
    try std.testing.expectEqual(Direction.lower_to_upper, accepted.direction);
    try std.testing.expectEqual(@as(f64, 4), accepted.transfer.water_m3);
    try std.testing.expectEqual(@as(f64, 1), accepted.transfer.residue_carbon_g);
}

test "relayering activity rejects reversal and preserves the prior accepted attempt" {
    var sidecar = try Sidecar.init(
        std.testing.allocator,
        1,
        2,
        .{ .relative = 32 * std.math.floatEps(f64) },
    );
    defer sidecar.deinit();
    try sidecar.beginAttempt();
    try sidecar.stageBoundary(
        0,
        0,
        1,
        .{},
        .{},
        .{},
        .{},
    );
    try sidecar.commitAttempt();
    const prior = try sidecar.record(0, 0);

    try sidecar.beginAttempt();
    try std.testing.expectError(
        error.ReversedRelayeringActivity,
        sidecar.stageBoundary(
            0,
            0,
            1,
            .{ .water_m3 = 1 },
            .{ .water_m3 = 1 },
            .{ .water_m3 = 2 },
            .{ .water_m3 = 0 },
        ),
    );
    sidecar.abortAttempt();
    try std.testing.expectEqualDeep(prior, try sidecar.record(0, 0));
}

test "negative transferred enthalpy reverses only the heat ledger direction" {
    var sidecar = try Sidecar.init(
        std.testing.allocator,
        1,
        2,
        .{ .relative = 32 * std.math.floatEps(f64) },
    );
    defer sidecar.deinit();
    try sidecar.beginAttempt();
    try sidecar.stageBoundary(
        0,
        1,
        0,
        .{ .water_m3 = 10, .heat_megajoules = -10 },
        .{ .water_m3 = 2, .heat_megajoules = -2 },
        .{ .water_m3 = 6, .heat_megajoules = -6 },
        .{ .water_m3 = 6, .heat_megajoules = -6 },
    );
    try sidecar.commitAttempt();
    const accepted = try sidecar.record(0, 0);
    try std.testing.expectEqual(Direction.lower_to_upper, accepted.direction);
    try std.testing.expectEqual(Direction.upper_to_lower, accepted.heat_direction);
    try std.testing.expectEqual(@as(f64, 4), accepted.transfer.water_m3);
    try std.testing.expectEqual(@as(f64, 4), accepted.transfer.heat_megajoules);
}

test "production relayering brackets the complete mutation before sidecar publication" {
    const source = @embedFile("relayering.zig");
    const begin = std.mem.indexOf(u8, source, "beginAttempt()") orelse return error.MissingRelayeringActivityBegin;
    const capture_before = std.mem.indexOfPos(u8, source, begin, "const donor_before_activity") orelse return error.MissingRelayeringActivityBefore;
    const water_heat = std.mem.indexOfPos(u8, source, capture_before, "water_heat_remap.transferLayerFractions") orelse return error.MissingRelayeringWaterHeatMutation;
    const root = std.mem.indexOfPos(u8, source, water_heat, "root_remap.transferPondedCellLayerFraction") orelse return error.MissingRelayeringRootMutation;
    const stage = std.mem.indexOfPos(u8, source, root, "stageBoundary(") orelse return error.MissingRelayeringActivityStage;
    const geometry = std.mem.indexOfPos(u8, source, stage, "Geometry.applyDisturbances") orelse return error.MissingRelayeringGeometryCommit;
    const commit = std.mem.indexOfPos(u8, source, geometry, "commitAttempt()") orelse return error.MissingRelayeringActivityCommit;
    try std.testing.expect(begin < capture_before and capture_before < water_heat and water_heat < root and root < stage and stage < geometry and geometry < commit);
}
