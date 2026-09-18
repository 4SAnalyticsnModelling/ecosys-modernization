//! Execution identities derived from the production timeline, including repeats.
//! Calendar dates alone cannot identify an hour when forcing is replayed.
const std = @import("std");
const timeline = @import("simulation_timeline.zig");
const options = @import("options.zig");
const runscript = @import("../driver/runscript.zig");
const calendar = @import("../driver/execution_calendar_date.zig");

/// All execution indices and hour numbers in evidence are one-based.
pub const Pass = struct {
    execution: usize,
    scenario: usize,
    repeat: usize,
    scene: usize,
    start_year: u16,
    start_day: u16,
    end_year: u16,
    end_day: u16,
    hours: usize,
    first_total_hour: usize,
    last_total_hour: usize,
    identity_sha256: [32]u8 = @splat(0),
};

pub const Identity = struct {
    execution: usize,
    scenario: usize,
    repeat: usize,
    scene: usize,
    scene_hour: usize,
    total_hour: usize,
    year: u16,
    day: u16,
    hour: u8,

    pub fn canonical(self: Identity, buffer: []u8) ![]u8 {
        return std.fmt.bufPrint(buffer, "{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
            self.execution,  self.scenario, self.repeat, self.scene, self.scene_hour,
            self.total_hour, self.year,     self.day,    self.hour,
        });
    }
};

pub const Plan = struct {
    expected_hours: usize,
    passes: []Pass,

    pub fn init(allocator: std.mem.Allocator, scenes: []const options.SceneOptions, scenarios: []const runscript.Scenario, execution_repeats: usize) !Plan {
        const summary = try timeline.summarize(scenes, scenarios, execution_repeats);
        var iterator = try timeline.PassIterator.init(scenarios, execution_repeats);
        var passes: std.ArrayList(Pass) = .empty;
        errdefer passes.deinit(allocator);
        var completed: usize = 0;
        while (iterator.next()) |pass| {
            const scene = scenes[pass.scene_index];
            const hours = try std.math.mul(usize, try timeline.inclusiveDays(scene.start_date, scene.end_date), 24);
            const last = try std.math.add(usize, completed, hours);
            try passes.append(allocator, .{
                .execution = pass.execution_iteration + 1,
                .scenario = pass.scenario_index + 1,
                .repeat = pass.scenario_iteration + 1,
                .scene = pass.scene_index + 1,
                .start_year = scene.start_date.year,
                .start_day = try calendar.dayOfYear(.{ .year = scene.start_date.year, .month = scene.start_date.month, .day = scene.start_date.day }),
                .end_year = scene.end_date.year,
                .end_day = try calendar.dayOfYear(.{ .year = scene.end_date.year, .month = scene.end_date.month, .day = scene.end_date.day }),
                .hours = hours,
                .first_total_hour = completed + 1,
                .last_total_hour = last,
            });
            completed = last;
        }
        if (completed != summary.execution_weighted_hours) return error.ExecutionTimelineSummaryMismatch;
        var plan: Plan = .{ .expected_hours = completed, .passes = try passes.toOwnedSlice(allocator) };
        errdefer plan.deinit(allocator);
        // Freeze the exact hourly identities from the model calendar. Offline
        // verification can hash observed identities without implementing a
        // second calendar or trusting a maximum observed date.
        for (plan.passes) |*pass| {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            for (pass.first_total_hour..pass.last_total_hour + 1) |hour| {
                var buffer: [256]u8 = undefined;
                hasher.update(try (try plan.identityAt(hour)).canonical(&buffer));
            }
            hasher.final(&pass.identity_sha256);
        }
        return plan;
    }

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.passes);
        self.* = undefined;
    }

    pub fn writeJson(self: Plan, writer: *std.Io.Writer) !void {
        try std.json.Stringify.value(.{
            .schema = "ecosys-ng-execution-plan-v1",
            .calendar = "ecosys-modulo-four",
            .index_base = @as(u8, 1),
            .expected_hours = self.expected_hours,
            .passes = self.passes,
        }, .{}, writer);
        try writer.writeByte('\n');
    }

    pub fn identityAt(self: Plan, total_hour: usize) !Identity {
        if (total_hour == 0 or total_hour > self.expected_hours) return error.ExecutionHourOutsidePlan;
        for (self.passes) |pass| {
            if (total_hour > pass.last_total_hour) continue;
            const offset = total_hour - pass.first_total_hour;
            var day: usize = pass.start_day + offset / 24;
            var year = pass.start_year;
            while (true) {
                const days: usize = if (calendar.isLeapYear(year)) 366 else 365;
                if (day <= days) break;
                day -= days;
                year = try std.math.add(u16, year, 1);
            }
            return .{
                .execution = pass.execution,
                .scenario = pass.scenario,
                .repeat = pass.repeat,
                .scene = pass.scene,
                .scene_hour = offset + 1,
                .total_hour = total_hour,
                .year = year,
                .day = @intCast(day),
                .hour = @intCast(offset % 24 + 1),
            };
        }
        return error.ExecutionHourOutsidePlan;
    }
};

/// An opt-in buffered journal. It is outside model rollback: failed attempts
/// must remain observable. Acceptance follows successful output publication,
/// including the daily conservation audit; commit alone is insufficient.
pub const Journal = struct {
    plan: *const Plan,
    writer: *std.Io.Writer,
    accepted_hours: usize,
    current: ?Identity = null,
    phase: enum { ready, attempted, committed, complete } = .ready,

    pub fn start(plan: *const Plan, writer: *std.Io.Writer, run_id: []const u8, restored_hours: usize, production_mode: bool) !Journal {
        if (restored_hours > plan.expected_hours) return error.ExecutionHourOutsidePlan;
        try std.json.Stringify.value(.{
            .schema = "ecosys-ng-execution-journal-v1",
            .event = "start",
            .run_id = run_id,
            .expected_hours = plan.expected_hours,
            .restored_hours = restored_hours,
            .production_mode = production_mode,
        }, .{}, writer);
        try writer.writeByte('\n');
        try writer.flush();
        return .{ .plan = plan, .writer = writer, .accepted_hours = restored_hours };
    }

    pub fn attempt(self: *Journal, identity: Identity) !void {
        if (self.phase != .ready) return error.ExecutionEvidencePhaseOrder;
        const expected = try self.plan.identityAt(self.accepted_hours + 1);
        if (!std.meta.eql(expected, identity)) {
            if (!@import("builtin").is_test) std.log.err("execution identity mismatch: expected={any} observed={any}", .{ expected, identity });
            return error.ExecutionEvidenceIdentityMismatch;
        }
        self.current = identity;
        try self.writeHour("attempted");
        self.phase = .attempted;
    }

    pub fn commit(self: *Journal) !void {
        if (self.phase != .attempted) return error.ExecutionEvidencePhaseOrder;
        try self.writeHour("committed");
        self.phase = .committed;
    }

    pub fn accept(self: *Journal) !void {
        if (self.phase != .committed) return error.ExecutionEvidencePhaseOrder;
        try self.writeHour("accepted");
        self.accepted_hours = self.current.?.total_hour;
        self.phase = .ready;
        if (self.current.?.hour == 24) try self.writer.flush();
    }

    pub fn finish(self: *Journal) !void {
        if (self.phase != .ready or self.accepted_hours != self.plan.expected_hours) return error.ExecutionEvidenceIncomplete;
        try std.json.Stringify.value(.{ .event = "complete", .accepted_hours = self.accepted_hours }, .{}, self.writer);
        try self.writer.writeByte('\n');
        try self.writer.flush();
        self.phase = .complete;
    }

    fn writeHour(self: *Journal, event: []const u8) !void {
        try std.json.Stringify.value(.{ .event = event, .identity = self.current.? }, .{}, self.writer);
        try self.writer.writeByte('\n');
    }
};

test "execution evidence cannot complete after a missing repeat or skipped hour" {
    var scenes: [1]options.SceneOptions = undefined;
    scenes[0].start_date = .{ .year = 2001, .month = 1, .day = 1 };
    scenes[0].end_date = scenes[0].start_date;
    const scenarios = [_]runscript.Scenario{.{ .first_scene_index = 0, .scene_count = 1, .repeat_count = 2 }};
    var plan = try Plan.init(std.testing.allocator, &scenes, &scenarios, 1);
    defer plan.deinit(std.testing.allocator);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var journal = try Journal.start(&plan, &output.writer, "test-run", 0, true);
    try std.testing.expectError(error.ExecutionEvidenceIdentityMismatch, journal.attempt(try plan.identityAt(2)));
    try std.testing.expectError(error.ExecutionEvidencePhaseOrder, journal.commit());
    for (1..49) |hour| {
        if (hour == 25) try std.testing.expectError(error.ExecutionEvidenceIncomplete, journal.finish());
        const identity = try plan.identityAt(hour);
        try journal.attempt(identity);
        try std.testing.expectError(error.ExecutionEvidencePhaseOrder, journal.attempt(identity));
        try std.testing.expectError(error.ExecutionEvidencePhaseOrder, journal.accept());
        try journal.commit();
        try std.testing.expectError(error.ExecutionEvidenceIncomplete, journal.finish());
        try journal.accept();
    }
    try journal.finish();
    try std.testing.expectError(error.ExecutionEvidenceIncomplete, journal.finish());
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "{\"event\":\"complete\",\"accepted_hours\":48}\n"));
}

test "execution evidence expands Ottawa six forcing years and five repeats" {
    var scenes: [6]options.SceneOptions = undefined;
    for (&scenes, 0..) |*scene, index| {
        scene.* = undefined;
        scene.start_date = .{ .year = @intCast(1998 + index), .month = 1, .day = 1 };
        scene.end_date = .{ .year = @intCast(1998 + index), .month = 12, .day = 31 };
    }
    const scenarios = [_]runscript.Scenario{.{ .first_scene_index = 0, .scene_count = 6, .repeat_count = 5 }};
    var plan = try Plan.init(std.testing.allocator, &scenes, &scenarios, 1);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 262920), plan.expected_hours);
    try std.testing.expectEqual(@as(usize, 30), plan.passes.len);
    const first_pass_end = try plan.identityAt(52584);
    const repeat_start = try plan.identityAt(52585);
    try std.testing.expectEqual(@as(usize, 1), first_pass_end.repeat);
    try std.testing.expectEqual(@as(usize, 2), repeat_start.repeat);
    try std.testing.expectEqual(@as(u16, 1998), repeat_start.year);
    try std.testing.expectEqual(@as(usize, 1), repeat_start.scene_hour);
    const final = try plan.identityAt(262920);
    try std.testing.expectEqual(@as(usize, 5), final.repeat);
    try std.testing.expectEqual(@as(u16, 2003), final.year);
    try std.testing.expectEqual(@as(u16, 365), final.day);
    try std.testing.expectEqual(@as(u8, 24), final.hour);
    try std.testing.expectError(error.ExecutionHourOutsidePlan, plan.identityAt(0));
    try std.testing.expectError(error.ExecutionHourOutsidePlan, plan.identityAt(262921));
}

test "model hour journal still rejects duplicated and skipped midnight endpoints" {
    const weather = @import("../io/input/weather.zig");
    var scenes: [1]options.SceneOptions = undefined;
    scenes[0].start_date = .{ .year = 1998, .month = 1, .day = 1 };
    scenes[0].end_date = .{ .year = 1998, .month = 1, .day = 2 };
    const scenarios = [_]runscript.Scenario{.{ .first_scene_index = 0, .scene_count = 1, .repeat_count = 1 }};
    var plan = try Plan.init(std.testing.allocator, &scenes, &scenarios, 1);
    defer plan.deinit(std.testing.allocator);
    var buffer: [4096]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&buffer);
    var journal = try Journal.start(&plan, &sink.writer, "observed-midnight", 0, true);
    for (1..25) |hour| {
        const raw: weather.Timestamp = .{ .year = null, .day_of_year = if (hour == 24) 2 else 1, .month = null, .day_of_month = null, .hour = @intCast(hour % 24), .minute = 0 };
        const normalized = try raw.modelHour(1998);
        try journal.attempt(.{ .execution = 1, .scenario = 1, .repeat = 1, .scene = 1, .scene_hour = hour, .total_hour = hour, .year = normalized.year.?, .day = normalized.day_of_year.?, .hour = normalized.hour });
        try journal.commit();
        try journal.accept();
    }
    // D1/24 and D2/00 are equivalent. Receiving the former now is a duplicate,
    // even if the caller has incremented its counters to the next hour.
    try std.testing.expectError(error.ExecutionEvidenceIdentityMismatch, journal.attempt(.{ .execution = 1, .scenario = 1, .repeat = 1, .scene = 1, .scene_hour = 25, .total_hour = 25, .year = 1998, .day = 1, .hour = 24 }));
    try std.testing.expectError(error.ExecutionEvidenceIdentityMismatch, journal.attempt(.{ .execution = 1, .scenario = 1, .repeat = 1, .scene = 1, .scene_hour = 25, .total_hour = 25, .year = 1998, .day = 2, .hour = 2 }));
    try std.testing.expectError(error.ExecutionEvidenceIncomplete, journal.finish());
    try journal.attempt(.{ .execution = 1, .scenario = 1, .repeat = 1, .scene = 1, .scene_hour = 25, .total_hour = 25, .year = 1998, .day = 2, .hour = 1 });
    try journal.commit();
    try journal.accept();
    try std.testing.expectEqual(@as(usize, 25), journal.accepted_hours);
}

test "execution evidence preserves century leap day and nested execution order" {
    var scenes: [1]options.SceneOptions = undefined;
    scenes[0].start_date = .{ .year = 1900, .month = 2, .day = 28 };
    scenes[0].end_date = .{ .year = 1900, .month = 3, .day = 1 };
    const scenarios = [_]runscript.Scenario{.{ .first_scene_index = 0, .scene_count = 1, .repeat_count = 2 }};
    var plan = try Plan.init(std.testing.allocator, &scenes, &scenarios, 2);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 288), plan.expected_hours);
    try std.testing.expectEqual(@as(u16, 60), (try plan.identityAt(25)).day);
    const next_execution = try plan.identityAt(145);
    try std.testing.expectEqual(@as(usize, 2), next_execution.execution);
    try std.testing.expectEqual(@as(usize, 1), next_execution.repeat);
    try std.testing.expectEqual(@as(u16, 59), next_execution.day);
    var rendered: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer rendered.deinit();
    try plan.writeJson(&rendered.writer);
    const decoded = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered.written(), .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(i64, 288), decoded.value.object.get("expected_hours").?.integer);
    try std.testing.expectEqual(@as(usize, 4), decoded.value.object.get("passes").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 32), decoded.value.object.get("passes").?.array.items[0].object.get("identity_sha256").?.array.items.len);
}
