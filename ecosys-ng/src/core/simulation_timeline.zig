const std = @import("std");
const options = @import("options.zig");
const runscript = @import("../driver/runscript.zig");
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");

pub const Summary = struct {
    unique_scene_days: usize,
    scenario_weighted_days: usize,
    execution_weighted_days: usize,
    execution_weighted_hours: usize,
};

pub const ScenePass = struct {
    scene_index: usize,
    execution_iteration: usize,
    scenario_index: usize,
    scenario_iteration: usize,
};

/// Zero-allocation traversal of the runscript's nested execution, scenario,
/// repetition, and scene structure.
pub const PassIterator = struct {
    scenarios: []const runscript.Scenario,
    execution_repeat_count: usize,
    execution_iteration: usize = 0,
    scenario_index: usize = 0,
    scenario_iteration: usize = 0,
    scene_offset: usize = 0,

    pub fn init(scenarios: []const runscript.Scenario, execution_repeat_count: usize) !PassIterator {
        if (scenarios.len == 0 or execution_repeat_count == 0) return error.EmptySimulationTimeline;
        for (scenarios) |scenario| if (scenario.scene_count == 0 or scenario.repeat_count == 0) return error.InvalidTimelineScenario;
        return .{ .scenarios = scenarios, .execution_repeat_count = execution_repeat_count };
    }

    pub fn next(self: *PassIterator) ?ScenePass {
        if (self.execution_iteration >= self.execution_repeat_count) return null;
        const scenario = self.scenarios[self.scenario_index];
        const result: ScenePass = .{
            .scene_index = scenario.first_scene_index + self.scene_offset,
            .execution_iteration = self.execution_iteration,
            .scenario_index = self.scenario_index,
            .scenario_iteration = self.scenario_iteration,
        };
        self.scene_offset += 1;
        if (self.scene_offset == scenario.scene_count) {
            self.scene_offset = 0;
            self.scenario_iteration += 1;
            if (self.scenario_iteration == scenario.repeat_count) {
                self.scenario_iteration = 0;
                self.scenario_index += 1;
                if (self.scenario_index == self.scenarios.len) {
                    self.scenario_index = 0;
                    self.execution_iteration += 1;
                }
            }
        }
        return result;
    }
};

pub fn summarize(scene_options: []const options.SceneOptions, scenarios: []const runscript.Scenario, execution_repeat_count: usize) !Summary {
    if (scene_options.len == 0 or scenarios.len == 0 or execution_repeat_count == 0) return error.EmptySimulationTimeline;
    var unique_days: usize = 0;
    for (scene_options) |scene| unique_days = try std.math.add(usize, unique_days, try inclusiveDays(scene.start_date, scene.end_date));

    var weighted_days: usize = 0;
    for (scenarios) |scenario| {
        const end = try std.math.add(usize, scenario.first_scene_index, scenario.scene_count);
        if (end > scene_options.len or scenario.scene_count == 0 or scenario.repeat_count == 0) return error.InvalidTimelineScenario;
        var scenario_days: usize = 0;
        for (scene_options[scenario.first_scene_index..end]) |scene| scenario_days = try std.math.add(usize, scenario_days, try inclusiveDays(scene.start_date, scene.end_date));
        weighted_days = try std.math.add(usize, weighted_days, try std.math.mul(usize, scenario_days, scenario.repeat_count));
    }
    const execution_days = try std.math.mul(usize, weighted_days, execution_repeat_count);
    return .{
        .unique_scene_days = unique_days,
        .scenario_weighted_days = weighted_days,
        .execution_weighted_days = execution_days,
        .execution_weighted_hours = try std.math.mul(usize, execution_days, 24),
    };
}

pub fn inclusiveDays(start: options.Date, end: options.Date) !usize {
    const first = try ordinalDay(start);
    const last = try ordinalDay(end);
    if (last < first) return error.SceneEndsBeforeItStarts;
    return @intCast(last - first + 1);
}

fn ordinalDay(date: options.Date) !i64 {
    const day_of_year = execution_calendar_date.dayOfYear(.{
        .day = date.day,
        .month = date.month,
        .year = date.year,
    }) catch return error.InvalidTimelineDate;
    const completed_years: i64 = date.year - 1;
    const days = completed_years * 365 + @divTrunc(completed_years, 4);
    return days + day_of_year - 1;
}

test "timeline includes leap day and runtime repetitions" {
    const scenes = [_]options.SceneOptions{
        undefined,
        undefined,
    };
    var configured = scenes;
    configured[0].start_date = .{ .day = 28, .month = 2, .year = 2024 };
    configured[0].end_date = .{ .day = 1, .month = 3, .year = 2024 };
    configured[1].start_date = .{ .day = 1, .month = 1, .year = 2025 };
    configured[1].end_date = .{ .day = 2, .month = 1, .year = 2025 };
    const scenarios = [_]runscript.Scenario{.{ .first_scene_index = 0, .scene_count = 2, .repeat_count = 3 }};
    const result = try summarize(&configured, &scenarios, 2);
    try std.testing.expectEqual(@as(usize, 5), result.unique_scene_days);
    try std.testing.expectEqual(@as(usize, 30), result.execution_weighted_days);
    try std.testing.expectEqual(@as(usize, 720), result.execution_weighted_hours);
}

test "scene pass iterator preserves nested repetition order" {
    const scenarios = [_]runscript.Scenario{
        .{ .first_scene_index = 0, .scene_count = 2, .repeat_count = 2 },
        .{ .first_scene_index = 2, .scene_count = 1, .repeat_count = 1 },
    };
    var iterator = try PassIterator.init(&scenarios, 2);
    const expected = [_]usize{ 0, 1, 0, 1, 2, 0, 1, 0, 1, 2 };
    for (expected) |scene_index| try std.testing.expectEqual(scene_index, iterator.next().?.scene_index);
    try std.testing.expect(iterator.next() == null);
}

test "timeline preserves DAY modulo-four century chronology" {
    try std.testing.expectEqual(
        @as(usize, 3),
        try inclusiveDays(
            .{ .day = 28, .month = 2, .year = 1900 },
            .{ .day = 1, .month = 3, .year = 1900 },
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try inclusiveDays(
            .{ .day = 28, .month = 2, .year = 1901 },
            .{ .day = 1, .month = 3, .year = 1901 },
        ),
    );
    try std.testing.expectError(
        error.InvalidTimelineDate,
        inclusiveDays(
            .{ .day = 29, .month = 2, .year = 1901 },
            .{ .day = 1, .month = 3, .year = 1901 },
        ),
    );
}
