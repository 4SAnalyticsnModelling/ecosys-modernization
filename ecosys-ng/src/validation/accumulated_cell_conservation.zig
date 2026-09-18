const std = @import("std");
const hourly = @import("hourly_cell_conservation.zig");
const inventory = @import("landscape_mass_inventory.zig");

/// Persisted, independently reconstructible conservation identity for every
/// horizontal cell. Baseline/latest storage and every direction-separated
/// input/output/internal term are retained; no domain reduction or accounting
/// reset participates in accumulated acceptance.
pub const State = struct {
    allocator: std.mem.Allocator,
    baseline_storage: []inventory.Storage,
    latest_storage: []inventory.Storage,
    cumulative_activity: []hourly.BoundaryActivity,
    accepted_hour_count: u64,

    pub fn initEmpty(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.AccumulatedCellConservationDimensionMismatch;
        const baseline = try allocator.alloc(inventory.Storage, cell_count);
        errdefer allocator.free(baseline);
        const latest = try allocator.alloc(inventory.Storage, cell_count);
        errdefer allocator.free(latest);
        const activity = try allocator.alloc(hourly.BoundaryActivity, cell_count);
        errdefer allocator.free(activity);
        return .{
            .allocator = allocator,
            .baseline_storage = baseline,
            .latest_storage = latest,
            .cumulative_activity = activity,
            .accepted_hour_count = 0,
        };
    }

    pub fn clone(self: State, allocator: std.mem.Allocator) !State {
        try self.validate();
        var result = try initEmpty(allocator, self.baseline_storage.len);
        errdefer result.deinit();
        @memcpy(result.baseline_storage, self.baseline_storage);
        @memcpy(result.latest_storage, self.latest_storage);
        @memcpy(result.cumulative_activity, self.cumulative_activity);
        result.accepted_hour_count = self.accepted_hour_count;
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.cumulative_activity);
        self.allocator.free(self.latest_storage);
        self.allocator.free(self.baseline_storage);
        self.* = undefined;
    }

    pub fn validate(self: State) !void {
        const cell_count = self.baseline_storage.len;
        if (cell_count == 0 or self.latest_storage.len != cell_count or
            self.cumulative_activity.len != cell_count or self.accepted_hour_count == 0)
            return error.InvalidAccumulatedCellConservationState;
        for (self.baseline_storage, self.latest_storage, self.cumulative_activity) |baseline, latest, activity| {
            try baseline.validate();
            try latest.validate();
            inline for (std.meta.fields(hourly.BoundaryActivity)) |field| {
                const value = @field(activity, field.name);
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidAccumulatedCellConservationState;
            }
        }
    }
};

/// Preview, locally gate, then atomically commit one accepted hour. The first
/// call captures the immutable storage baseline. Later calls separately gate
/// continuity from the last accepted storage before adding the current hour,
/// preventing between-hour mutations from hiding in the accumulated result.
pub fn evaluateAndCommit(
    slot: *?State,
    owner_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    storage_before: []const inventory.Storage,
    storage_after: []const inventory.Storage,
    hourly_activity: []const hourly.BoundaryActivity,
    cell_area_m2: []const f64,
    tolerances: hourly.Tolerances,
    expected_previous_hour_count: u64,
) !hourly.Report {
    const cell_count = storage_before.len;
    if (cell_count == 0 or storage_after.len != cell_count or
        hourly_activity.len != cell_count or cell_area_m2.len != cell_count)
        return error.AccumulatedCellConservationDimensionMismatch;

    if (slot.*) |*live| {
        try live.validate();
        if (live.baseline_storage.len != cell_count or
            live.accepted_hour_count != expected_previous_hour_count)
            return error.AccumulatedCellConservationHistoryMismatch;
        const next_hour_count = std.math.add(u64, live.accepted_hour_count, 1) catch
            return error.AccumulatedCellConservationHistoryOverflow;
        const candidate_activity = try scratch_allocator.alloc(hourly.BoundaryActivity, cell_count);
        defer scratch_allocator.free(candidate_activity);

        @memset(candidate_activity, .{});
        var continuity = try hourly.evaluateForScope(
            scratch_allocator,
            live.latest_storage,
            storage_before,
            candidate_activity,
            cell_area_m2,
            tolerances,
            .accumulated_continuity,
        );
        defer continuity.deinit(scratch_allocator);
        if (!continuity.accepted())
            return error.AccumulatedCellStorageDiscontinuity;

        for (candidate_activity, live.cumulative_activity, hourly_activity) |*candidate, accumulated, current|
            candidate.* = try hourly.addActivities(accumulated, current);
        var report = try hourly.evaluateForScope(
            scratch_allocator,
            live.baseline_storage,
            storage_after,
            candidate_activity,
            cell_area_m2,
            tolerances,
            .accumulated,
        );
        errdefer report.deinit(scratch_allocator);
        if (!report.accepted())
            return error.AccumulatedCellConservationFailure;
        @memcpy(live.cumulative_activity, candidate_activity);
        @memcpy(live.latest_storage, storage_after);
        live.accepted_hour_count = next_hour_count;
        return report;
    }

    if (expected_previous_hour_count != 0)
        return error.AccumulatedCellConservationHistoryMismatch;
    var candidate = try State.initEmpty(owner_allocator, cell_count);
    errdefer candidate.deinit();
    @memcpy(candidate.baseline_storage, storage_before);
    @memcpy(candidate.latest_storage, storage_after);
    for (candidate.cumulative_activity, hourly_activity) |*destination, source|
        destination.* = try hourly.addActivities(.{}, source);
    candidate.accepted_hour_count = 1;
    var report = try hourly.evaluateForScope(
        scratch_allocator,
        candidate.baseline_storage,
        candidate.latest_storage,
        candidate.cumulative_activity,
        cell_area_m2,
        tolerances,
        .accumulated,
    );
    errdefer report.deinit(scratch_allocator);
    if (!report.accepted())
        return error.AccumulatedCellConservationFailure;
    slot.* = candidate;
    return report;
}

fn testTolerances() hourly.Tolerances {
    return .{
        .absolute_per_area = .{ .water_m = 1.0e-3 },
        .relative = 1.0e-12,
    };
}

test "water storage update arithmetic provenance survives accumulated cell commit" {
    var state: ?State = null;
    defer if (state) |*value| value.deinit();
    const before = [_]inventory.Storage{.{
        .water_m3 = 2.5563198907705675e-1,
    }};
    const after = [_]inventory.Storage{.{
        .water_m3 = 2.55631946964604e-1,
    }};
    const provenance = 1.8163748302758886e-15;
    const activity = [_]hourly.BoundaryActivity{.{
        .water_input_m3 = 1.6767668503669952e-10,
        .water_output_m3 = 4.228012845386431e-8,
        .water_storage_update_roundoff_allowance_m3 = provenance,
    }};
    var report = try evaluateAndCommit(
        &state,
        std.testing.allocator,
        std.testing.allocator,
        &before,
        &after,
        &activity,
        &.{1},
        .{
            .absolute_per_area = .{ .water_m = 0 },
            .relative = 1.0e-9,
        },
        0,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.accepted());
    try std.testing.expectEqual(
        provenance,
        state.?.cumulative_activity[0]
            .water_storage_update_roundoff_allowance_m3,
    );
}

test "equal and opposite cell errors cannot pass through domain cancellation" {
    var state: ?State = null;
    defer if (state) |*value| value.deinit();
    const before = [_]inventory.Storage{ .{ .water_m3 = 10 }, .{ .water_m3 = 10 } };
    const after = [_]inventory.Storage{ .{ .water_m3 = 10.01 }, .{ .water_m3 = 9.99 } };
    const activity = [_]hourly.BoundaryActivity{ .{}, .{} };
    try std.testing.expectApproxEqAbs(@as(f64, 0), (after[0].water_m3 - before[0].water_m3) +
        (after[1].water_m3 - before[1].water_m3), 1.0e-14);
    try std.testing.expectError(
        error.AccumulatedCellConservationFailure,
        evaluateAndCommit(
            &state,
            std.testing.allocator,
            std.testing.allocator,
            &before,
            &after,
            &activity,
            &.{ 1, 1 },
            testTolerances(),
            0,
        ),
    );
    try std.testing.expect(state == null);
}

test "same sign sub-hour residuals accumulate until the local gate rejects" {
    var state: ?State = null;
    defer if (state) |*value| value.deinit();
    const activity = [_]hourly.BoundaryActivity{.{}};
    const initial = [_]inventory.Storage{.{ .water_m3 = 10 }};
    const first = [_]inventory.Storage{.{ .water_m3 = 10.0006 }};
    var first_hour = try hourly.evaluate(
        std.testing.allocator,
        &initial,
        &first,
        &activity,
        &.{1},
        testTolerances(),
    );
    defer first_hour.deinit(std.testing.allocator);
    try std.testing.expect(first_hour.accepted());
    var first_accumulated = try evaluateAndCommit(
        &state,
        std.testing.allocator,
        std.testing.allocator,
        &initial,
        &first,
        &activity,
        &.{1},
        testTolerances(),
        0,
    );
    first_accumulated.deinit(std.testing.allocator);
    var snapshot = try state.?.clone(std.testing.allocator);
    defer snapshot.deinit();

    const second = [_]inventory.Storage{.{ .water_m3 = 10.0012 }};
    var second_hour = try hourly.evaluate(
        std.testing.allocator,
        &first,
        &second,
        &activity,
        &.{1},
        testTolerances(),
    );
    defer second_hour.deinit(std.testing.allocator);
    try std.testing.expect(second_hour.accepted());
    try std.testing.expectError(
        error.AccumulatedCellConservationFailure,
        evaluateAndCommit(
            &state,
            std.testing.allocator,
            std.testing.allocator,
            &first,
            &second,
            &activity,
            &.{1},
            testTolerances(),
            1,
        ),
    );
    try std.testing.expectEqual(snapshot.accepted_hour_count, state.?.accepted_hour_count);
    try std.testing.expectEqualDeep(snapshot.baseline_storage, state.?.baseline_storage);
    try std.testing.expectEqualDeep(snapshot.latest_storage, state.?.latest_storage);
    try std.testing.expectEqualDeep(snapshot.cumulative_activity, state.?.cumulative_activity);
}

test "direction separated activity accumulates without netting" {
    var state: ?State = null;
    defer if (state) |*value| value.deinit();
    const storage = [_]inventory.Storage{.{ .water_m3 = 5 }};
    const first_activity = [_]hourly.BoundaryActivity{.{ .water_input_m3 = 2, .water_output_m3 = 2 }};
    var first = try evaluateAndCommit(
        &state,
        std.testing.allocator,
        std.testing.allocator,
        &storage,
        &storage,
        &first_activity,
        &.{1},
        testTolerances(),
        0,
    );
    first.deinit(std.testing.allocator);
    const second_activity = [_]hourly.BoundaryActivity{.{ .water_input_m3 = 3, .water_output_m3 = 3 }};
    var second = try evaluateAndCommit(
        &state,
        std.testing.allocator,
        std.testing.allocator,
        &storage,
        &storage,
        &second_activity,
        &.{1},
        testTolerances(),
        1,
    );
    second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 5), state.?.cumulative_activity[0].water_input_m3);
    try std.testing.expectEqual(@as(f64, 5), state.?.cumulative_activity[0].water_output_m3);
}

test "production gate commits accumulated local closure before domain reduction" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "accumulated_cell_conservation.evaluateAndCommit("),
    );
    const accept_start = std.mem.indexOf(
        u8,
        source,
        "noinline fn acceptHourAndPublish(",
    ) orelse return error.MissingAcceptHourPhase;
    const prepare_start = std.mem.indexOfPos(
        u8,
        source,
        accept_start,
        "noinline fn prepareHourlyScience(",
    ) orelse return error.MissingPrepareHourlySciencePhase;
    const accept_phase = source[accept_start..prepare_start];
    const hourly_gate = std.mem.indexOf(
        u8,
        accept_phase,
        "hourly_cell_conservation.requireAccepted(hourly_cell_conservation_report)",
    ) orelse return error.MissingHourlyCellConservationGate;
    const accumulated_gate = std.mem.indexOfPos(
        u8,
        accept_phase,
        hourly_gate,
        "accumulated_cell_conservation.evaluateAndCommit(",
    ) orelse return error.MissingAccumulatedCellConservationGate;
    const domain_reduction = std.mem.indexOfPos(
        u8,
        accept_phase,
        accumulated_gate,
        ".accumulateAcceptedHourlyCellElements(",
    ) orelse return error.MissingDomainCellActivityReduction;
    const commit = std.mem.indexOfPos(
        u8,
        accept_phase,
        domain_reduction,
        "outer_hour_transaction.*.commit();",
    ) orelse return error.MissingOuterHourCommit;
    try std.testing.expect(hourly_gate < accumulated_gate);
    try std.testing.expect(accumulated_gate < domain_reduction);
    try std.testing.expect(domain_reduction < commit);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(
        u8,
        source,
        "resources.ownDeinit(&owners.landscape_mass_balance_state);",
    ));
    const advance_start = std.mem.indexOf(u8, source, "noinline fn advanceHour(") orelse return error.MissingAdvanceHourPhase;
    const timeline_start = std.mem.indexOfPos(u8, source, advance_start, "noinline fn runTimeline(") orelse return error.MissingTimelinePhase;
    const advance_phase = source[advance_start..timeline_start];
    const post_call = std.mem.indexOf(u8, advance_phase, "try postScienceAccounting(driver_context,") orelse return error.MissingPostScienceCall;
    const accept_call = std.mem.indexOfPos(u8, advance_phase, post_call, "try acceptHourAndPublish(driver_context,") orelse return error.MissingAcceptHourCall;
    try std.testing.expect(post_call < accept_call);
}
