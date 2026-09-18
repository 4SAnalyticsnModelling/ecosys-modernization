const std = @import("std");

/// SOIL.F writes WOUTS/WOUTP/WOUTQ only after the final hourly cycle of a day
/// when `(I/KOUT)*KOUT == I`, and unconditionally after the final scene hour.
/// The accepted-hour counter is the sole unambiguous day-boundary owner: an
/// hour label of 23 can mean either the 23rd source record or native midnight.
/// Publishing from that label alone produced non-resumable partial-day
/// checkpoints whose daily accounting ledgers had not yet been reduced.
pub fn shouldPublish(enabled: bool, interval_days: u16, day_of_year: u16, completed_scene_hours: u64, is_scene_final_hour: bool) !bool {
    if (day_of_year == 0 or day_of_year > 366) return error.InvalidCheckpointScheduleInstant;
    if (!enabled or interval_days == 0) return false;
    if (completed_scene_hours == 0 or @mod(completed_scene_hours, 24) != 0)
        return false;
    return is_scene_final_hour or day_of_year % interval_days == 0;
}

/// A scene requests ROUTS/ROUTP only at its initial boundary. The executable
/// must restore the complete state_updateted bundle before any management or hourly
/// science is applied.
pub fn shouldRestore(resume_enabled: bool, scene_hour_index: usize) bool {
    return resume_enabled and scene_hour_index == 0;
}

test "checkpoint cadence preserves SOIL daily modulo and final-scene rules" {
    try std.testing.expect(!try shouldPublish(true, 10, 20, 47, false));
    try std.testing.expect(try shouldPublish(true, 10, 20, 48, false));
    try std.testing.expect(!try shouldPublish(true, 10, 21, 48, false));
    try std.testing.expect(!try shouldPublish(true, 10, 21, 47, true));
    try std.testing.expect(try shouldPublish(true, 10, 21, 48, true));
    try std.testing.expect(!try shouldPublish(false, 10, 20, 48, true));
    try std.testing.expect(!try shouldPublish(true, 0, 20, 48, true));
}

test "checkpoint restore occurs only before the first scene hour" {
    try std.testing.expect(shouldRestore(true, 0));
    try std.testing.expect(!shouldRestore(true, 1));
    try std.testing.expect(!shouldRestore(false, 0));
}
