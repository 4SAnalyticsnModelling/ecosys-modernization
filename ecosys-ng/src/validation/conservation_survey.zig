//! Records conservation breaches across a whole run instead of halting on the
//! first one.
//!
//! **No tolerance is relaxed anywhere in this file.** The audits are evaluated
//! at exactly their production limits and their verdicts are taken verbatim;
//! the only difference is that a failing verdict is tallied and the run
//! continues. That is the entire mechanism.
//!
//! Why it exists. The Ottawa deck stops at day 14 of a 30-year horizon on a
//! single heat-balance breach, and a run that aborts at the first breach can
//! only ever reveal one defect per run. Surveying converts "fix one, rebuild,
//! rerun, discover the next" into one pass that names every balance defect and
//! ranks them by magnitude and by how early they appear.
//!
//! What a surveyed run is NOT. It is not production evidence, and it cannot be
//! made into production evidence by any later argument. After the first breach
//! the simulation continues from a state the model itself judged
//! non-conserving, so every subsequent number is downstream of an unreconciled
//! error. The first breach is the only one whose magnitude is trustworthy; the
//! rest are ordered hints, not measurements. `summary` says so in its own
//! output so that a log read six months from now cannot be mistaken for a
//! passing run.

const std = @import("std");

/// One audited quantity's breach history over the run.
pub const QuantityTally = struct {
    breaches: u64 = 0,
    first_hour: ?u64 = null,
    last_hour: ?u64 = null,
    /// Largest absolute residual seen, in that quantity's own unit.
    worst_absolute: f64 = 0,
    /// Largest residual relative to the interval activity that scaled it.
    worst_normalized_relative: f64 = 0,
    worst_hour: ?u64 = null,
    /// Hours in which this quantity had ANY boundary activity, and the largest
    /// activity seen. Without these a clean verdict is unreadable.
    ///
    /// The acceptance limit is
    /// `absolute_tolerance_per_area + relative_tolerance * interval_activity / area`
    /// (`validation/mass_balance_audit.zig:588`), and every field of
    /// `core/conservation_tolerance.zig`'s `AbsolutePerArea` DEFAULTS TO ZERO --
    /// its `validate()` rejects only negatives. So for a quantity with no
    /// activity in the interval the limit is exactly 0, the residual is exactly
    /// 0, and `0 <= 0` passes. That pass asserts nothing: nothing moved.
    ///
    /// Counting such quantities as audited overstates coverage. These two
    /// fields make the difference visible, so a report can separate "conserved
    /// while active" from "never moved".
    active_hours: u64 = 0,
    largest_activity: f64 = 0,
};

pub const Survey = struct {
    /// Indexed by the audit's own quantity enum value, so this module needs no
    /// knowledge of the quantity list and cannot drift out of step with it.
    tallies: []QuantityTally,
    names: []const []const u8,
    /// Hours in which at least one quantity breached, which is the figure that
    /// says whether the run was broadly or narrowly broken.
    breaching_hours: u64 = 0,
    observed_hours: u64 = 0,
    /// Whether ANY caller ever reported activity. Without this the report
    /// cannot tell "no quantity moved" from "no caller measured movement", and
    /// an unwired instrument would print every quantity as inert -- a false
    /// alarm exactly as misleading as the vacuous pass it exists to expose.
    /// This is the same positive-control idea as
    /// `validation/stage_execution_census.zig`'s `census_positive_control`.
    activity_instrumented: bool = false,

    pub fn init(allocator: std.mem.Allocator, names: []const []const u8) !Survey {
        const tallies = try allocator.alloc(QuantityTally, names.len);
        @memset(tallies, .{});
        return .{ .tallies = tallies, .names = names };
    }

    pub fn deinit(self: *Survey, allocator: std.mem.Allocator) void {
        allocator.free(self.tallies);
        self.* = undefined;
    }

    pub fn observeHour(self: *Survey, simulated_hour: u64) void {
        if (simulated_hour > self.observed_hours) self.observed_hours = simulated_hour;
    }

    /// Records that a quantity had boundary activity this hour, whether or not
    /// it breached. This is what distinguishes a meaningful pass from a vacuous
    /// one: see `QuantityTally.active_hours`.
    ///
    /// `activity` is the audit's own interval activity, taken verbatim, so the
    /// survey cannot disagree with the scale the verdict was computed against.
    /// Zero or non-finite activity is NOT counted as active -- a non-finite
    /// activity would otherwise make an inert quantity look exercised.
    pub fn observeActivity(self: *Survey, quantity_index: usize, activity: f64) void {
        if (quantity_index >= self.tallies.len) return;
        // Set even for a zero or non-finite reading: the caller DID report, and
        // that is what `activity_instrumented` records. Distinguishing "nothing
        // moved" from "nobody looked" is the whole point -- see `summary`.
        self.activity_instrumented = true;
        if (!std.math.isFinite(activity) or activity == 0) return;
        const tally = &self.tallies[quantity_index];
        if (tally.active_hours != std.math.maxInt(u64)) tally.active_hours += 1;
        const magnitude = @abs(activity);
        if (magnitude > tally.largest_activity) tally.largest_activity = magnitude;
    }

    /// How many audited quantities never moved, and are therefore passing
    /// vacuously rather than being conserved.
    pub fn inertCount(self: *const Survey) usize {
        var count: usize = 0;
        for (self.tallies) |tally| count += @intFromBool(tally.active_hours == 0);
        return count;
    }

    /// Records one failing quantity. `absolute` and `normalized_relative` are
    /// taken from the audit's own closure report, not recomputed here, so a
    /// survey can never disagree with the verdict it is recording.
    pub fn record(
        self: *Survey,
        quantity_index: usize,
        simulated_hour: u64,
        absolute: f64,
        normalized_relative: f64,
    ) void {
        if (quantity_index >= self.tallies.len) return;
        const tally = &self.tallies[quantity_index];
        if (tally.breaches != std.math.maxInt(u64)) tally.breaches += 1;
        if (tally.first_hour == null) tally.first_hour = simulated_hour;
        tally.last_hour = simulated_hour;
        if (absolute > tally.worst_absolute) {
            tally.worst_absolute = absolute;
            tally.worst_hour = simulated_hour;
        }
        if (normalized_relative > tally.worst_normalized_relative)
            tally.worst_normalized_relative = normalized_relative;
    }

    pub fn noteBreachingHour(self: *Survey) void {
        if (self.breaching_hours != std.math.maxInt(u64)) self.breaching_hours += 1;
    }

    pub fn breachedQuantityCount(self: *const Survey) usize {
        var total: usize = 0;
        for (self.tallies) |tally| total += @intFromBool(tally.breaches != 0);
        return total;
    }

    /// Ranked by first appearance, because the earliest breach is the only one
    /// whose magnitude is trustworthy and is therefore the one to fix first.
    pub fn summary(self: *const Survey, writer: *std.Io.Writer) !void {
        try writer.print(
            "conservation survey: {d} of {d} audited quantities breached, in {d} of {d} simulated hour(s)\n",
            .{ self.breachedQuantityCount(), self.tallies.len, self.breaching_hours, self.observed_hours },
        );
        try writer.writeAll(
            "  THIS RUN IS NOT PRODUCTION EVIDENCE. After the first breach the model\n" ++
                "  continued from a state it judged non-conserving, so only the EARLIEST\n" ++
                "  breach has a trustworthy magnitude; later ones are ordered hints.\n",
        );
        // Coverage before verdicts. A quantity with no boundary activity has an
        // acceptance limit of exactly zero and a residual of exactly zero, so
        // it passes without asserting anything -- see
        // `QuantityTally.active_hours`. Reporting the audited count alone
        // overstates coverage by however many of these there are, which is why
        // this prints even when nothing breached.
        const inert = self.inertCount();
        if (!self.activity_instrumented) {
            try writer.print(
                "  coverage: UNKNOWN. Activity was never reported for any of the {d} audited\n" ++
                    "  quantities, so this run cannot say which passes are real and which are\n" ++
                    "  vacuous. Absence of activity here is NOT evidence that nothing moved.\n",
                .{self.tallies.len},
            );
        } else try writer.print(
            "  coverage: {d} of {d} audited quantities had ANY boundary activity; {d} never moved\n",
            .{ self.tallies.len - inert, self.tallies.len, inert },
        );
        if (self.activity_instrumented and inert != 0) {
            try writer.writeAll(
                "  a quantity that never moved PASSES VACUOUSLY: its limit is 0 and its\n" ++
                    "  residual is 0. Those passes are not evidence of conservation.\n",
            );
            for (self.tallies, 0..) |tally, index| {
                if (tally.active_hours != 0) continue;
                try writer.print("    inert (never moved): {s}\n", .{self.names[index]});
            }
        }
        if (self.breachedQuantityCount() == 0) {
            if (self.activity_instrumented) try writer.print(
                "  no breach recorded among the {d} quantity(s) that did move\n",
                .{self.tallies.len - inert},
            ) else try writer.writeAll("  no breach recorded\n");
            return;
        }
        // Selection sort by first_hour. The quantity count is small, so this
        // avoids allocating inside a diagnostic. The emitted set is a LOCAL
        // bitset: an earlier draft made it a struct-level `var`, which is
        // global mutable state and, worse, would not have reset between calls,
        // so a second summary would have printed nothing.
        var emitted_already = [_]bool{false} ** 256;
        if (self.tallies.len > emitted_already.len) {
            try writer.writeAll("  (too many quantities to rank; listing unordered)\n");
            for (self.tallies, 0..) |tally, index| {
                if (tally.breaches == 0) continue;
                try writer.print("  {s}: breaches={d}\n", .{ self.names[index], tally.breaches });
            }
            return;
        }
        while (true) {
            var best: ?usize = null;
            for (self.tallies, 0..) |tally, index| {
                if (tally.breaches == 0 or emitted_already[index]) continue;
                const first = tally.first_hour orelse continue;
                if (best) |current| {
                    if (first < (self.tallies[current].first_hour orelse continue)) best = index;
                } else best = index;
            }
            const index = best orelse break;
            emitted_already[index] = true;
            const tally = self.tallies[index];
            try writer.print(
                "  {s}: breaches={d} first_hour={?d} last_hour={?d} worst_absolute={e} at_hour={?d} worst_normalized_relative={e}\n",
                .{
                    self.names[index],
                    tally.breaches,
                    tally.first_hour,
                    tally.last_hour,
                    tally.worst_absolute,
                    tally.worst_hour,
                    tally.worst_normalized_relative,
                },
            );
        }
    }
};

test "a fresh survey records nothing and says so" {
    var survey = try Survey.init(std.testing.allocator, &.{ "water", "heat" });
    defer survey.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), survey.breachedQuantityCount());
}

test "record keeps first, last and worst separately" {
    var survey = try Survey.init(std.testing.allocator, &.{ "water", "heat" });
    defer survey.deinit(std.testing.allocator);
    survey.observeHour(400);
    survey.record(1, 100, 5.0e-11, 3.0e-9);
    survey.record(1, 250, 9.0e-11, 1.0e-9);
    survey.record(1, 300, 2.0e-11, 8.0e-9);

    const heat = survey.tallies[1];
    try std.testing.expectEqual(@as(u64, 3), heat.breaches);
    try std.testing.expectEqual(@as(?u64, 100), heat.first_hour);
    try std.testing.expectEqual(@as(?u64, 300), heat.last_hour);
    // Worst absolute and worst relative can occur in different hours, so they
    // are tracked independently; collapsing them would mislabel the worst hour.
    try std.testing.expectEqual(@as(f64, 9.0e-11), heat.worst_absolute);
    try std.testing.expectEqual(@as(?u64, 250), heat.worst_hour);
    try std.testing.expectEqual(@as(f64, 8.0e-9), heat.worst_normalized_relative);
    try std.testing.expectEqual(@as(usize, 1), survey.breachedQuantityCount());
}

test "an out-of-range quantity index is ignored rather than corrupting a tally" {
    var survey = try Survey.init(std.testing.allocator, &.{"water"});
    defer survey.deinit(std.testing.allocator);
    survey.record(99, 10, 1, 1);
    try std.testing.expectEqual(@as(usize, 0), survey.breachedQuantityCount());
}

test "summary always states the run is not production evidence" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var survey = try Survey.init(std.testing.allocator, &.{ "water", "heat" });
    defer survey.deinit(std.testing.allocator);
    survey.observeHour(346);
    survey.record(1, 346, 7.1e-12, 3.8e-9);
    survey.noteBreachingHour();
    try survey.summary(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "NOT PRODUCTION EVIDENCE") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "heat: breaches=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "in 1 of 346 simulated hour(s)") != null);
}

test "summary is repeatable -- the emitted set must not persist between calls" {
    // Regression for a real defect in the first draft: the emitted-set was a
    // struct-level `var`, so a second summary printed the header and no rows.
    var buffer: [4096]u8 = undefined;
    var survey = try Survey.init(std.testing.allocator, &.{ "water", "heat" });
    defer survey.deinit(std.testing.allocator);
    survey.observeHour(10);
    survey.record(0, 5, 1e-9, 1e-8);
    survey.record(1, 7, 2e-9, 2e-8);

    var first = std.Io.Writer.fixed(&buffer);
    try survey.summary(&first);
    const first_text = try std.testing.allocator.dupe(u8, first.buffered());
    defer std.testing.allocator.free(first_text);

    var second = std.Io.Writer.fixed(&buffer);
    try survey.summary(&second);
    try std.testing.expectEqualStrings(first_text, second.buffered());
    try std.testing.expect(std.mem.indexOf(u8, first_text, "water: breaches=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_text, "heat: breaches=1") != null);
    // First-appearance order: water breached at hour 5, heat at 7.
    try std.testing.expect(
        std.mem.indexOf(u8, first_text, "water:").? < std.mem.indexOf(u8, first_text, "heat:").?,
    );
}

test "an inert quantity is reported as vacuous rather than counted as conserved" {
    // The defect this guards: the acceptance limit is
    // `absolute_tolerance_per_area + relative * interval_activity / area`, and
    // every AbsolutePerArea field defaults to 0, so a quantity with no activity
    // gets limit 0 against residual 0 and passes. Counting that as one of "22
    // audited quantities" overstates coverage.
    const names = [_][]const u8{ "water", "heat", "carbon" };
    var survey = try Survey.init(std.testing.allocator, &names);
    defer survey.deinit(std.testing.allocator);
    survey.observeHour(10);
    // water moved and stayed within its limit; heat moved and breached;
    // carbon never moved at all.
    survey.observeActivity(0, 1234.5);
    survey.observeActivity(1, 42.0);
    survey.record(1, 7, 1e-3, 1e-4);
    survey.noteBreachingHour();

    try std.testing.expectEqual(@as(usize, 1), survey.inertCount());
    try std.testing.expectEqual(@as(u64, 1), survey.tallies[0].active_hours);
    try std.testing.expectApproxEqAbs(@as(f64, 1234.5), survey.tallies[0].largest_activity, 0);
    try std.testing.expectEqual(@as(u64, 0), survey.tallies[2].active_hours);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try survey.summary(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "2 of 3 audited quantities had ANY boundary activity; 1 never moved") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "PASSES VACUOUSLY") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "inert (never moved): carbon") != null);
    // The quantity that moved and stayed inside its limit must NOT be listed
    // as inert, or the report would cry wolf on real coverage.
    try std.testing.expect(std.mem.indexOf(u8, text, "inert (never moved): water") == null);
}

test "zero and non-finite activity do not count as movement" {
    // A non-finite activity would otherwise make an inert quantity look
    // exercised, which is the opposite of what this instrument is for.
    const names = [_][]const u8{"water"};
    var survey = try Survey.init(std.testing.allocator, &names);
    defer survey.deinit(std.testing.allocator);
    survey.observeActivity(0, 0);
    survey.observeActivity(0, std.math.nan(f64));
    survey.observeActivity(0, std.math.inf(f64));
    try std.testing.expectEqual(@as(u64, 0), survey.tallies[0].active_hours);
    try std.testing.expectEqual(@as(usize, 1), survey.inertCount());
    // Out-of-range index is ignored rather than trapping, matching `record`.
    survey.observeActivity(99, 1);
    try std.testing.expectEqual(@as(u64, 0), survey.tallies[0].active_hours);
}

test "an unwired activity instrument reports UNKNOWN coverage, not universal inertness" {
    // The false alarm this prevents. `observeActivity` is not yet called from
    // production (the audit's `Report` carries no interval activity to pass),
    // so every tally reads active_hours == 0. Reporting that as "22 never
    // moved" would be exactly as misleading as the vacuous pass this
    // instrument exists to expose -- it would be absence of evidence printed
    // as evidence of absence.
    const names = [_][]const u8{ "water", "heat" };
    var survey = try Survey.init(std.testing.allocator, &names);
    defer survey.deinit(std.testing.allocator);
    survey.observeHour(5);
    try std.testing.expect(!survey.activity_instrumented);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try survey.summary(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "coverage: UNKNOWN") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "NOT evidence that nothing moved") != null);
    // It must NOT claim inertness for either quantity.
    try std.testing.expect(std.mem.indexOf(u8, text, "inert (never moved)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "never moved\n") == null);
}

test "one activity report flips the instrument live even if it reads zero" {
    // A caller reporting genuine zero activity IS a measurement, so coverage
    // becomes knowable and the quantity is correctly named inert.
    const names = [_][]const u8{"water"};
    var survey = try Survey.init(std.testing.allocator, &names);
    defer survey.deinit(std.testing.allocator);
    survey.observeActivity(0, 0);
    try std.testing.expect(survey.activity_instrumented);
    try std.testing.expectEqual(@as(usize, 1), survey.inertCount());

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try survey.summary(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "coverage: UNKNOWN") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "inert (never moved): water") != null);
}
