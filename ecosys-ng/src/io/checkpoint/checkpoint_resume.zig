// **A8a DISPOSITION: split verdict. The seek half is SUPERSEDED; the
// validation half was a GENUINE GAP and is now bound.**
//
// `Cursor` / `WeatherInstant` are superseded. Production resumes by advancing
// each hourly stream exactly `manifest.completed_scene_hours` times at
// `ecosys_ng.zig:3535--3545` and then asserting the stopped-on record's
// year/day/hour against the manifest at `:3546--3551`, which is a stronger
// postcondition than `observe` reaches, plus a cross-stream timestamp check at
// `:3543` this cursor has no notion of. Hour-convention folding is inline at
// `:3550`. `rebuildClimateBeforeObserve` is superseded twice over: the DAY.F
// climate accumulator is checkpointed state, swapped in whole at
// `bundle_reader.zig:138`, so replaying it would be less accurate than what
// production already does. Do not wire this half.
//
// `validatePlantMetadata` was the real finding: correct, complete and with no
// caller anywhere. `bundle_reader.zig:175` checks only year, day of year and
// `cells.len`, all of which a checkpoint written for a different crop at equal
// cell and species counts satisfies, so a resume silently reinterpreted every
// per-species array under the wrong crop's parameters. Now called from
// `ecosys_ng.zig:3393`, before `swapIntoLive`, so the run aborts before any
// restored state reaches the live model.
//
// Non-vacuity is the mismatch test at the bottom of this file; no example
// resumes from a checkpoint, so the gate cannot exercise the binding.
//
// io_checkpoint group of docs/traceability/io_checkpoint_unbound_disposition.md
const std = @import("std");
const manifest_module = @import("manifest.zig");
const metadata_module = @import("plant_checkpoint_metadata.zig");
const climate_change = @import("../input/climate_change.zig");
const SceneOptions = @import("../../core/options.zig").SceneOptions;
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");

pub const WeatherInstant = struct {
    pub const HourConvention = enum { source_one_through_24, native_zero_through_23 };

    year: i32,
    day_of_year: u16,
    hour: u8,
    hour_convention: HourConvention = .source_one_through_24,

    pub fn canonical(self: WeatherInstant) !WeatherInstant {
        const calendar_year = std.math.cast(u16, self.year) orelse
            return error.InvalidResumeWeatherInstant;
        const maximum_day: u16 =
            if (execution_calendar_date.isLeapYear(calendar_year)) 366 else 365;
        if (calendar_year == 0 or self.day_of_year == 0 or
            self.day_of_year > maximum_day)
            return error.InvalidResumeWeatherInstant;
        const canonical_hour: u8 = switch (self.hour_convention) {
            .source_one_through_24 => if (self.hour >= 1 and self.hour <= 24) self.hour - 1 else return error.InvalidResumeWeatherInstant,
            .native_zero_through_23 => if (self.hour <= 23) self.hour else return error.InvalidResumeWeatherInstant,
        };
        return .{ .year = self.year, .day_of_year = self.day_of_year, .hour = canonical_hour, .hour_convention = .native_zero_through_23 };
    }
};

pub const Decision = enum { skip, execute };

/// Stateful weather seek used before any resumed science. The checkpoint hour
/// itself is already state_updateted, so it and every earlier record are skipped.
/// Advancing beyond the target without observing it is fatal.
pub const Cursor = struct {
    target: manifest_module.SimulationInstant,
    observed_target: bool = false,
    previous: ?WeatherInstant = null,

    pub fn init(target: manifest_module.SimulationInstant) !Cursor {
        _ = try (WeatherInstant{ .year = target.year, .day_of_year = target.day_of_year, .hour = target.hour, .hour_convention = .native_zero_through_23 }).canonical();
        return .{ .target = target };
    }

    pub fn observe(self: *Cursor, input: WeatherInstant) !Decision {
        const instant = try input.canonical();
        if (self.previous) |previous| {
            if (compareWeather(instant, previous) != .gt) return error.NonIncreasingResumeWeather;
        }
        self.previous = instant;
        const order = compare(instant, self.target);
        if (order == .lt) return .skip;
        if (order == .eq) {
            self.observed_target = true;
            return .skip;
        }
        if (!self.observed_target) return error.CheckpointInstantNotFoundInWeather;
        return .execute;
    }

    /// Reconstructs the transient DAY.F climate accumulator while seeking.
    /// Management and model science must remain disabled for skipped records.
    /// Call immediately before `observe` for the same input record.
    pub fn rebuildClimateBeforeObserve(self: Cursor, climate: *climate_change.State, options: SceneOptions, input: WeatherInstant) !void {
        const instant = try input.canonical();
        if (compare(instant, self.target) == .gt) return error.CannotRebuildClimateAfterCheckpoint;
        const begins_day = if (self.previous) |previous| previous.year != instant.year or previous.day_of_year != instant.day_of_year else true;
        if (begins_day and options.climate_change_mode == 2) {
            const year: u16 = std.math.cast(u16, instant.year) orelse return error.InvalidResumeWeatherYear;
            try climate.advanceDay(options, climate_change.daysInYear(year));
        }
    }
};

pub fn validatePlantMetadata(expected: []const metadata_module.CellView, restored: metadata_module.Metadata, instant: manifest_module.SimulationInstant) !void {
    if (restored.year != instant.year or restored.day_of_year != instant.day_of_year) return error.CheckpointMetadataInstantMismatch;
    if (restored.cells.len != expected.len) return error.CheckpointMetadataCellMismatch;
    for (expected, restored.cells, 0..) |expected_cell, restored_cell, cell| {
        if (expected_cell.species_names.len != expected_cell.species_alive.len or restored_cell.species_names.len != restored_cell.species_alive.len or expected_cell.species_names.len != restored_cell.species_names.len) return error.CheckpointMetadataSpeciesMismatch;
        for (expected_cell.species_names, restored_cell.species_names, 0..) |expected_name, restored_name, species| {
            if (!std.mem.eql(u8, expected_name, restored_name)) {
                // Logged at warn, not err: the returned error is what aborts the
                // run and is reported by the caller, and the Zig test harness
                // fails any test that emits a log at error level, which would
                // make the guard untestable.
                std.log.warn("checkpoint species does not match runscript assignment: cell={d} species={d} checkpoint='{s}' runscript='{s}'", .{ cell, species, restored_name, expected_name });
                return error.CheckpointMetadataSpeciesNameMismatch;
            }
        }
    }
}

/// Daily diagnostic/accounting ledgers are reduced and reset immediately
/// before a production checkpoint is published. They are intentionally not
/// duplicate checkpoint owners, so a bundle captured between those reset
/// boundaries cannot be resumed without inventing the missing partial-day
/// flux history.
pub fn validateCompletedDayBoundary(completed_scene_hours: u64) !void {
    if (completed_scene_hours == 0 or @mod(completed_scene_hours, 24) != 0)
        return error.CheckpointMissingPartialDayAccountingState;
}

fn compare(left: WeatherInstant, right: manifest_module.SimulationInstant) std.math.Order {
    if (left.year != right.year) return std.math.order(left.year, right.year);
    if (left.day_of_year != right.day_of_year) return std.math.order(left.day_of_year, right.day_of_year);
    return std.math.order(left.hour, right.hour);
}

fn compareWeather(left: WeatherInstant, right: WeatherInstant) std.math.Order {
    if (left.year != right.year) return std.math.order(left.year, right.year);
    if (left.day_of_year != right.day_of_year) return std.math.order(left.day_of_year, right.day_of_year);
    return std.math.order(left.hour, right.hour);
}

test "resume cursor skips through exact checkpoint and accepts following hour" {
    var cursor = try Cursor.init(.{ .year = 2001, .day_of_year = 10, .hour = 23 });
    try std.testing.expectEqual(Decision.skip, try cursor.observe(.{ .year = 2001, .day_of_year = 9, .hour = 24 }));
    try std.testing.expectEqual(Decision.skip, try cursor.observe(.{ .year = 2001, .day_of_year = 10, .hour = 24 }));
    try std.testing.expectEqual(Decision.execute, try cursor.observe(.{ .year = 2001, .day_of_year = 11, .hour = 1 }));
}

test "source and native hour conventions have a collision-free canonical mapping" {
    const source_23 = try (WeatherInstant{ .year = 2001, .day_of_year = 10, .hour = 23 }).canonical();
    const source_24 = try (WeatherInstant{ .year = 2001, .day_of_year = 10, .hour = 24 }).canonical();
    const native_23 = try (WeatherInstant{ .year = 2001, .day_of_year = 10, .hour = 23, .hour_convention = .native_zero_through_23 }).canonical();
    try std.testing.expectEqual(@as(u8, 22), source_23.hour);
    try std.testing.expectEqual(@as(u8, 23), source_24.hour);
    try std.testing.expectEqual(@as(u8, 23), native_23.hour);
}

test "resume weather validation preserves DAY modulo-four chronology" {
    const century = try (WeatherInstant{
        .year = 1900,
        .day_of_year = 366,
        .hour = 24,
    }).canonical();
    try std.testing.expectEqual(@as(u16, 366), century.day_of_year);
    try std.testing.expectEqual(@as(u8, 23), century.hour);
    try std.testing.expectError(
        error.InvalidResumeWeatherInstant,
        (WeatherInstant{
            .year = 1901,
            .day_of_year = 366,
            .hour = 24,
        }).canonical(),
    );
    try std.testing.expectError(
        error.InvalidResumeWeatherInstant,
        Cursor.init(.{ .year = 1901, .day_of_year = 366, .hour = 23 }),
    );
}

test "resume cursor rejects a weather gap over checkpoint" {
    var cursor = try Cursor.init(.{ .year = 2001, .day_of_year = 10, .hour = 12 });
    try std.testing.expectEqual(Decision.skip, try cursor.observe(.{ .year = 2001, .day_of_year = 10, .hour = 12 }));
    try std.testing.expectError(error.CheckpointInstantNotFoundInWeather, cursor.observe(.{ .year = 2001, .day_of_year = 10, .hour = 14 }));
}

test "resume cursor rejects duplicate or decreasing weather instants" {
    var cursor = try Cursor.init(.{ .year = 2001, .day_of_year = 10, .hour = 12 });
    try std.testing.expectEqual(Decision.skip, try cursor.observe(.{ .year = 2001, .day_of_year = 10, .hour = 10 }));
    try std.testing.expectError(error.NonIncreasingResumeWeather, cursor.observe(.{ .year = 2001, .day_of_year = 10, .hour = 10 }));
}

test "resume metadata requires exact runtime species topology but restores alive flags" {
    const names = [_][]const u8{ "maize", "soybean" };
    const current_alive = [_]bool{ false, false };
    const expected = [_]metadata_module.CellView{.{ .species_names = &names, .species_alive = &current_alive }};
    const restored_names = try std.testing.allocator.alloc([]u8, 2);
    restored_names[0] = try std.testing.allocator.dupe(u8, "maize");
    restored_names[1] = try std.testing.allocator.dupe(u8, "soybean");
    const restored_alive = try std.testing.allocator.dupe(bool, &.{ true, false });
    const cells = try std.testing.allocator.alloc(metadata_module.OwnedCell, 1);
    cells[0] = .{ .species_names = restored_names, .species_alive = restored_alive };
    var restored = metadata_module.Metadata{ .allocator = std.testing.allocator, .day_of_year = 20, .year = 2001, .cells = cells };
    defer restored.deinit();
    try validatePlantMetadata(&expected, restored, .{ .year = 2001, .day_of_year = 20, .hour = 23 });
}

test "resume metadata rejects a checkpoint written for a different species" {
    // Non-vacuity for the production call site added at `ecosys_ng.zig:3393`.
    // Resuming a maize/soybean checkpoint into a maize/wheat runscript keeps
    // every per-species array shape identical, so nothing else in the bundle
    // reader can detect it; only the name comparison can. Without this guard the
    // run would proceed and silently reinterpret soybean state as wheat.
    const names = [_][]const u8{ "maize", "wheat" };
    const current_alive = [_]bool{ false, false };
    const expected = [_]metadata_module.CellView{.{ .species_names = &names, .species_alive = &current_alive }};
    const restored_names = try std.testing.allocator.alloc([]u8, 2);
    restored_names[0] = try std.testing.allocator.dupe(u8, "maize");
    restored_names[1] = try std.testing.allocator.dupe(u8, "soybean");
    const restored_alive = try std.testing.allocator.dupe(bool, &.{ true, false });
    const cells = try std.testing.allocator.alloc(metadata_module.OwnedCell, 1);
    cells[0] = .{ .species_names = restored_names, .species_alive = restored_alive };
    var restored = metadata_module.Metadata{ .allocator = std.testing.allocator, .day_of_year = 20, .year = 2001, .cells = cells };
    defer restored.deinit();
    try std.testing.expectError(
        error.CheckpointMetadataSpeciesNameMismatch,
        validatePlantMetadata(&expected, restored, .{ .year = 2001, .day_of_year = 20, .hour = 23 }),
    );
    // A count difference is caught earlier, by a different error, so the two
    // failure modes stay distinguishable in logs.
    const short_names = [_][]const u8{"maize"};
    const short_alive = [_]bool{false};
    const short_expected = [_]metadata_module.CellView{.{ .species_names = &short_names, .species_alive = &short_alive }};
    try std.testing.expectError(
        error.CheckpointMetadataSpeciesMismatch,
        validatePlantMetadata(&short_expected, restored, .{ .year = 2001, .day_of_year = 20, .hour = 23 }),
    );
}

test "resume rejects partial-day checkpoints without persisted daily accounting" {
    try validateCompletedDayBoundary(24);
    try validateCompletedDayBoundary(48);
    try std.testing.expectError(
        error.CheckpointMissingPartialDayAccountingState,
        validateCompletedDayBoundary(47),
    );
    try std.testing.expectError(
        error.CheckpointMissingPartialDayAccountingState,
        validateCompletedDayBoundary(0),
    );
}
