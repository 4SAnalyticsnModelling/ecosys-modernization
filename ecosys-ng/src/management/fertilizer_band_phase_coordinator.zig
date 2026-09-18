const std = @import("std");
const geometry_module = @import("hourly_fertilizer_band_geometry.zig");
const repartition_module = @import("fertilizer_band_inventory_repartition.zig");

pub const Family = enum(u2) {
    ammonium = 0,
    nitrate = 1,
    phosphate = 2,
};

pub const HourToken = struct {
    value: u64,
};

pub const Phase = enum(u8) {
    idle,
    preparing,
    intervening_science,
    consuming,
};

pub const PersistentMetadata = struct {
    phase: Phase,
    current_token: u64,
    last_completed_token: u64,
    next_prepare_family: usize,
    next_consume_family: usize,
    active_by_family: [3]bool,
    first_active_layer_by_family: [3]usize,
    last_active_layer_by_family: [3]usize,
};

/// Persistent two-phase coordination state for one runtime grid cell.
///
/// FVL and disappearance flags must survive the science executed between
/// HOUR1 preparation and SOLUTE consumption. Geometry and chemistry remain in
/// their authoritative owners and are supplied through typed adapters.
pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    phase: Phase,
    current_token: u64,
    last_completed_token: u64,
    next_prepare_family: usize,
    next_consume_family: usize,
    relative_non_band_change: []f64,
    band_disappeared: []bool,
    active_by_family: [3]bool,
    first_active_layer_by_family: [3]usize,
    last_active_layer_by_family: [3]usize,

    pub fn init(
        allocator: std.mem.Allocator,
        layer_count: usize,
    ) !Coordinator {
        if (layer_count == 0) return error.ZeroFertilizerBandLayerCount;
        const extent = try std.math.mul(usize, 3, layer_count);
        const relative = try allocator.alloc(f64, extent);
        errdefer allocator.free(relative);
        const disappeared = try allocator.alloc(bool, extent);
        @memset(relative, 0);
        @memset(disappeared, false);
        return .{
            .allocator = allocator,
            .layer_count = layer_count,
            .phase = .idle,
            .current_token = 0,
            .last_completed_token = 0,
            .next_prepare_family = 0,
            .next_consume_family = 0,
            .relative_non_band_change = relative,
            .band_disappeared = disappeared,
            .active_by_family = .{ false, false, false },
            .first_active_layer_by_family = .{ 0, 0, 0 },
            .last_active_layer_by_family = .{ 0, 0, 0 },
        };
    }

    pub fn deinit(self: *Coordinator) void {
        self.allocator.free(self.band_disappeared);
        self.allocator.free(self.relative_non_band_change);
        self.* = undefined;
    }

    pub fn beginHour(self: *Coordinator, token: HourToken) !void {
        if (self.phase != .idle) return error.FertilizerBandHourStillPending;
        if (token.value == 0 or token.value <= self.last_completed_token)
            return error.StaleFertilizerBandHourToken;
        self.phase = .preparing;
        self.current_token = token.value;
        self.next_prepare_family = 0;
        self.next_consume_family = 0;
        @memset(self.relative_non_band_change, 0);
        @memset(self.band_disappeared, false);
    }

    /// HOUR1 phase. Calls must retain source family order NH4, NO3, PO4.
    pub fn prepareFamily(
        self: *Coordinator,
        token: HourToken,
        family: Family,
        state: *geometry_module.State,
        layer_geometry: geometry_module.LayerGeometry,
        forcing: geometry_module.Forcing,
        workspace: *geometry_module.Workspace,
    ) !void {
        try self.requireTokenAndPhase(token, .preparing);
        const family_index = @intFromEnum(family);
        if (family_index != self.next_prepare_family)
            return error.FertilizerBandPrepareOrderViolation;
        if (state.band_depth_m.len != self.layer_count)
            return error.FertilizerBandCoordinatorDimensionMismatch;
        try geometry_module.update(
            state,
            layer_geometry,
            forcing,
            .{
                .relative_non_band_change = self.relativeSlice(family),
                .band_disappeared = self.disappearedSlice(family),
            },
            workspace,
        );
        self.active_by_family[family_index] = state.active;
        self.first_active_layer_by_family[family_index] =
            layer_geometry.first_active_layer;
        self.last_active_layer_by_family[family_index] =
            layer_geometry.last_active_layer;
        self.next_prepare_family += 1;
        if (self.next_prepare_family == 3)
            self.phase = .intervening_science;
    }

    /// Barrier called only after all source-ordered intervening science has
    /// completed and immediately before SOLUTE band repartition.
    pub fn markInterveningScienceComplete(
        self: *Coordinator,
        token: HourToken,
    ) !void {
        try self.requireTokenAndPhase(token, .intervening_science);
        self.phase = .consuming;
        self.next_consume_family = 0;
    }

    /// SOLUTE phase. Calls must retain source family order NH4, NO3, PO4.
    pub fn consumeFamily(
        self: *Coordinator,
        token: HourToken,
        family: Family,
        pools_in_source_order: []const repartition_module.Pool,
    ) !repartition_module.Result {
        try self.requireTokenAndPhase(token, .consuming);
        const family_index = @intFromEnum(family);
        if (family_index != self.next_consume_family)
            return error.FertilizerBandConsumeOrderViolation;
        const result = try repartition_module.repartition(.{
            .relative_non_band_change = self.relativeSlice(family),
            .band_active = self.active_by_family[family_index],
            .first_active_layer = self.first_active_layer_by_family[family_index],
            .last_active_layer = self.last_active_layer_by_family[family_index],
        }, pools_in_source_order);
        self.next_consume_family += 1;
        if (self.next_consume_family == 3) {
            self.last_completed_token = self.current_token;
            self.current_token = 0;
            self.phase = .idle;
        }
        return result;
    }

    pub fn pendingToken(self: *const Coordinator) ?HourToken {
        if (self.phase == .idle) return null;
        return .{ .value = self.current_token };
    }

    pub fn persistentMetadata(self: *const Coordinator) PersistentMetadata {
        return .{
            .phase = self.phase,
            .current_token = self.current_token,
            .last_completed_token = self.last_completed_token,
            .next_prepare_family = self.next_prepare_family,
            .next_consume_family = self.next_consume_family,
            .active_by_family = self.active_by_family,
            .first_active_layer_by_family = self.first_active_layer_by_family,
            .last_active_layer_by_family = self.last_active_layer_by_family,
        };
    }

    /// Validate exactly the persistent state emitted by the checkpoint writer.
    /// Keeping this public lets serialization reject a state that its reader
    /// could not resume.
    pub fn validatePersistent(self: *const Coordinator) !void {
        try validatePersistentState(
            self.layer_count,
            self.persistentMetadata(),
            self.relative_non_band_change,
            self.band_disappeared,
        );
    }

    pub fn restorePersistent(
        self: *Coordinator,
        metadata: PersistentMetadata,
        relative_non_band_change: []const f64,
        band_disappeared: []const bool,
    ) !void {
        try validatePersistentState(
            self.layer_count,
            metadata,
            relative_non_band_change,
            band_disappeared,
        );
        self.phase = metadata.phase;
        self.current_token = metadata.current_token;
        self.last_completed_token = metadata.last_completed_token;
        self.next_prepare_family = metadata.next_prepare_family;
        self.next_consume_family = metadata.next_consume_family;
        self.active_by_family = metadata.active_by_family;
        self.first_active_layer_by_family =
            metadata.first_active_layer_by_family;
        self.last_active_layer_by_family =
            metadata.last_active_layer_by_family;
        @memcpy(
            self.relative_non_band_change,
            relative_non_band_change,
        );
        @memcpy(self.band_disappeared, band_disappeared);
    }

    pub fn persistentRelativeChanges(
        self: *const Coordinator,
    ) []const f64 {
        return self.relative_non_band_change;
    }

    pub fn persistentDisappearanceFlags(
        self: *const Coordinator,
    ) []const bool {
        return self.band_disappeared;
    }

    fn requireTokenAndPhase(
        self: *const Coordinator,
        token: HourToken,
        expected_phase: Phase,
    ) !void {
        if (token.value != self.current_token)
            return error.FertilizerBandHourTokenMismatch;
        if (self.phase != expected_phase)
            return error.InvalidFertilizerBandCoordinatorPhase;
    }

    fn relativeSlice(self: *Coordinator, family: Family) []f64 {
        const start = @intFromEnum(family) * self.layer_count;
        return self.relative_non_band_change[start..][0..self.layer_count];
    }

    fn disappearedSlice(self: *Coordinator, family: Family) []bool {
        const start = @intFromEnum(family) * self.layer_count;
        return self.band_disappeared[start..][0..self.layer_count];
    }
};

fn validatePersistentState(
    layer_count: usize,
    metadata: PersistentMetadata,
    relative_non_band_change: []const f64,
    band_disappeared: []const bool,
) !void {
    const expected = std.math.mul(usize, 3, layer_count) catch
        return error.FertilizerBandCoordinatorDimensionMismatch;
    if (relative_non_band_change.len != expected or band_disappeared.len != expected)
        return error.FertilizerBandCoordinatorDimensionMismatch;
    if (metadata.next_prepare_family > 3 or metadata.next_consume_family > 3)
        return error.InvalidFertilizerBandCoordinatorCheckpoint;
    switch (metadata.phase) {
        .idle => if (metadata.current_token != 0 or
            (metadata.last_completed_token == 0 and
                (metadata.next_prepare_family != 0 or metadata.next_consume_family != 0)) or
            (metadata.last_completed_token != 0 and
                (metadata.next_prepare_family != 3 or metadata.next_consume_family != 3)))
            return error.InvalidFertilizerBandCoordinatorCheckpoint,
        .preparing => if (metadata.current_token == 0 or
            metadata.current_token <= metadata.last_completed_token or
            metadata.next_prepare_family >= 3 or
            metadata.next_consume_family != 0)
            return error.InvalidFertilizerBandCoordinatorCheckpoint,
        .intervening_science => if (metadata.current_token == 0 or
            metadata.current_token <= metadata.last_completed_token or
            metadata.next_prepare_family != 3 or
            metadata.next_consume_family != 0)
            return error.InvalidFertilizerBandCoordinatorCheckpoint,
        .consuming => if (metadata.current_token == 0 or
            metadata.current_token <= metadata.last_completed_token or
            metadata.next_prepare_family != 3 or
            metadata.next_consume_family >= 3)
            return error.InvalidFertilizerBandCoordinatorCheckpoint,
    }
    for (relative_non_band_change) |value|
        if (!std.math.isFinite(value) or value <= -1 or value > 0)
            return error.InvalidFertilizerBandCoordinatorCheckpoint;
    for (
        metadata.first_active_layer_by_family,
        metadata.last_active_layer_by_family,
    ) |first, last| if (first > last or last >= layer_count)
        return error.InvalidFertilizerBandCoordinatorCheckpoint;
}

fn stateFixture(
    depth: []f64,
    width: []f64,
    band: []f64,
    non_band: []f64,
) geometry_module.State {
    return .{
        .active = true,
        .row_spacing_m = 0.1,
        .upper_edge_depth_m = 0.04,
        .lower_edge_depth_m = 0.06,
        .band_depth_m = depth,
        .band_width_m = width,
        .band_volume_fraction = band,
        .non_band_volume_fraction = non_band,
    };
}

fn layerGeometryFixture() geometry_module.LayerGeometry {
    return .{
        .upper_depth_m = &.{ 0, 0.1 },
        .lower_depth_m = &.{ 0.1, 0.2 },
        .thickness_m = &.{ 0.1, 0.1 },
        .first_active_layer = 0,
        .last_active_layer = 1,
        .minimum_active_thickness_m = 1e-6,
        .structural_presence_threshold = 1e-12,
    };
}

fn forcingFixture() geometry_module.Forcing {
    return .{
        .diffusivity_m2_per_h = &.{ 0.0001, 0.0001 },
        .tortuosity = &.{ 1, 1 },
        .timestep_h = 1,
    };
}

test "prepare persists FVL across intervening science and consume uses current inventory" {
    var coordinator = try Coordinator.init(std.testing.allocator, 2);
    defer coordinator.deinit();
    var geometry_workspace =
        try geometry_module.Workspace.init(std.testing.allocator, 2);
    defer geometry_workspace.deinit();

    var depths = [3][2]f64{
        .{ 0.02, 0 },
        .{ 0.02, 0 },
        .{ 0.02, 0 },
    };
    var widths = depths;
    var bands = [3][2]f64{
        .{ 0.004, 0 },
        .{ 0.004, 0 },
        .{ 0.004, 0 },
    };
    var non_bands = [3][2]f64{
        .{ 0.996, 1 },
        .{ 0.996, 1 },
        .{ 0.996, 1 },
    };
    var states = [3]geometry_module.State{
        stateFixture(&depths[0], &widths[0], &bands[0], &non_bands[0]),
        stateFixture(&depths[1], &widths[1], &bands[1], &non_bands[1]),
        stateFixture(&depths[2], &widths[2], &bands[2], &non_bands[2]),
    };
    const token: HourToken = .{ .value = 42 };
    try coordinator.beginHour(token);
    try coordinator.prepareFamily(
        token,
        .ammonium,
        &states[0],
        layerGeometryFixture(),
        forcingFixture(),
        &geometry_workspace,
    );
    try coordinator.prepareFamily(
        token,
        .nitrate,
        &states[1],
        layerGeometryFixture(),
        forcingFixture(),
        &geometry_workspace,
    );
    try coordinator.prepareFamily(
        token,
        .phosphate,
        &states[2],
        layerGeometryFixture(),
        forcingFixture(),
        &geometry_workspace,
    );

    // Represents source-ordered biology and SOLUTE reaction assembly.
    var dissolved_ammonium_g_n = [_]f64{ 14, 0 };
    dissolved_ammonium_g_n[0] = 28;
    try coordinator.markInterveningScienceComplete(token);

    var non_change = [_]f64{ 0, 0 };
    var band_change = [_]f64{ 0, 0 };
    const ammonium_pools = [_]repartition_module.Pool{
        .{
            .name = "dissolved ammonium",
            .inventory_unit = .grams_nitrogen,
            .storage = .{ .deferred = .{
                .non_band_inventory = &dissolved_ammonium_g_n,
                .non_band_change = &non_change,
                .band_change = &band_change,
                .change_unit = .moles,
                .inventory_units_per_change_unit = 14,
            } },
        },
    };
    const ammonium_result = try coordinator.consumeFamily(
        token,
        .ammonium,
        &ammonium_pools,
    );
    try std.testing.expectEqual(@as(usize, 1), ammonium_result.layers_repartitioned);
    const prepared_fvl = coordinator.relativeSlice(.ammonium)[0];
    try std.testing.expectApproxEqAbs(
        prepared_fvl * 2,
        non_change[0],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        non_change[0] + band_change[0],
        1e-15,
    );

    _ = try coordinator.consumeFamily(token, .nitrate, &.{});
    _ = try coordinator.consumeFamily(token, .phosphate, &.{});
    try std.testing.expectEqual(@as(?HourToken, null), coordinator.pendingToken());
    var restored = try Coordinator.init(std.testing.allocator, 2);
    defer restored.deinit();
    try restored.restorePersistent(
        coordinator.persistentMetadata(),
        coordinator.persistentRelativeChanges(),
        coordinator.persistentDisappearanceFlags(),
    );
    try restored.beginHour(.{ .value = token.value + 1 });
}

test "tokens and source family order prevent stale or double consumption" {
    var coordinator = try Coordinator.init(std.testing.allocator, 1);
    defer coordinator.deinit();
    var workspace =
        try geometry_module.Workspace.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var depth = [3][1]f64{ .{0.02}, .{0.02}, .{0.02} };
    var width = depth;
    var band = [3][1]f64{ .{0.004}, .{0.004}, .{0.004} };
    var non_band = [3][1]f64{ .{0.996}, .{0.996}, .{0.996} };
    var states = [3]geometry_module.State{
        stateFixture(&depth[0], &width[0], &band[0], &non_band[0]),
        stateFixture(&depth[1], &width[1], &band[1], &non_band[1]),
        stateFixture(&depth[2], &width[2], &band[2], &non_band[2]),
    };
    const geometry: geometry_module.LayerGeometry = .{
        .upper_depth_m = &.{0},
        .lower_depth_m = &.{0.1},
        .thickness_m = &.{0.1},
        .first_active_layer = 0,
        .last_active_layer = 0,
        .minimum_active_thickness_m = 0,
        .structural_presence_threshold = 0,
    };
    const forcing: geometry_module.Forcing = .{
        .diffusivity_m2_per_h = &.{0},
        .tortuosity = &.{1},
        .timestep_h = 1,
    };
    const token: HourToken = .{ .value = 7 };
    try coordinator.beginHour(token);
    try std.testing.expectError(
        error.FertilizerBandPrepareOrderViolation,
        coordinator.prepareFamily(
            token,
            .nitrate,
            &states[1],
            geometry,
            forcing,
            &workspace,
        ),
    );
    inline for (.{ Family.ammonium, Family.nitrate, Family.phosphate }, 0..) |
        family,
        index,
    | try coordinator.prepareFamily(
        token,
        family,
        &states[index],
        geometry,
        forcing,
        &workspace,
    );
    try coordinator.markInterveningScienceComplete(token);
    try std.testing.expectError(
        error.FertilizerBandHourTokenMismatch,
        coordinator.consumeFamily(.{ .value = 8 }, .ammonium, &.{}),
    );
    _ = try coordinator.consumeFamily(token, .ammonium, &.{});
    try std.testing.expectError(
        error.FertilizerBandConsumeOrderViolation,
        coordinator.consumeFamily(token, .ammonium, &.{}),
    );
    _ = try coordinator.consumeFamily(token, .nitrate, &.{});
    _ = try coordinator.consumeFamily(token, .phosphate, &.{});
    try std.testing.expectError(
        error.StaleFertilizerBandHourToken,
        coordinator.beginHour(token),
    );
}

test "completed idle coordinator checkpoint restores after a nonzero token" {
    var coordinator = try Coordinator.init(std.testing.allocator, 1);
    defer coordinator.deinit();
    const relative = [_]f64{0} ** 3;
    const disappeared = [_]bool{false} ** 3;
    const completed: PersistentMetadata = .{
        .phase = .idle,
        .current_token = 0,
        .last_completed_token = 7,
        .next_prepare_family = 3,
        .next_consume_family = 3,
        .active_by_family = .{ false, false, false },
        .first_active_layer_by_family = .{ 0, 0, 0 },
        .last_active_layer_by_family = .{ 0, 0, 0 },
    };
    try coordinator.restorePersistent(completed, &relative, &disappeared);
    try std.testing.expectEqual(completed, coordinator.persistentMetadata());
    try std.testing.expectEqual(@as(?HourToken, null), coordinator.pendingToken());
    try coordinator.beginHour(.{ .value = 8 });

    var corrupt = completed;
    corrupt.next_prepare_family = 0;
    try std.testing.expectError(
        error.InvalidFertilizerBandCoordinatorCheckpoint,
        coordinator.restorePersistent(corrupt, &relative, &disappeared),
    );
    corrupt = completed;
    corrupt.phase = .preparing;
    corrupt.current_token = completed.last_completed_token;
    corrupt.next_prepare_family = 1;
    try std.testing.expectError(
        error.InvalidFertilizerBandCoordinatorCheckpoint,
        coordinator.restorePersistent(corrupt, &relative, &disappeared),
    );
    corrupt.current_token = completed.last_completed_token + 1;
    corrupt.next_consume_family = 1;
    try std.testing.expectError(
        error.InvalidFertilizerBandCoordinatorCheckpoint,
        coordinator.restorePersistent(corrupt, &relative, &disappeared),
    );
    corrupt = completed;
    corrupt.last_active_layer_by_family[0] = 1;
    try std.testing.expectError(
        error.InvalidFertilizerBandCoordinatorCheckpoint,
        coordinator.restorePersistent(corrupt, &relative, &disappeared),
    );
}
