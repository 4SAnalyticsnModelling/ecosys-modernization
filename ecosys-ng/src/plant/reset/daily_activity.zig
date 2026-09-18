// **A8a DISPOSITION: superseded by the bound HOUR1 daily reset.**
//
// PSILZ is owned by plant_root_water_balance.resetDailyMinimumCanopyWaterPotential
// (src/plant/root/water_balance.zig:72), bound at src/ecosys_ng.zig:3920 under
// begins_day, which is timestamp-derived rather than source-hour-derived. IFLGT is a
// legacy count of active PFTs (hfunc.f:74, accumulated at hfunc.f:117) read only by
// checkpoint I/O (woutp.f:32, routp.f:40); production carries the per-species boolean
// species_alive instead (io/checkpoint/plant_checkpoint_metadata.zig:9) and needs no
// summed counter to reset. Do not bind this module.
// daily reset group of docs/traceability/plant_reset_unbound_family_disposition.md
const std = @import("std");

pub const State = struct {
    active_plant_species_count: usize,
    minimum_daily_canopy_water_potential_megapascal: []f64,
};

/// Exact HOUR1 IFLGT/PSILZ reset from hour1.f:170-175.
///
/// The reset occurs only during the first nonlinear iteration (NFZ==1) of
/// source hour one. The species slice is runtime-sized and may be empty.
pub fn apply(
    state: *State,
    source_hour: u8,
    first_subhourly_iteration: bool,
) !bool {
    if (source_hour < 1 or source_hour > 24)
        return error.InvalidDailyPlantResetSourceHour;
    for (state.minimum_daily_canopy_water_potential_megapascal) |value|
        if (!std.math.isFinite(value))
            return error.NonFiniteDailyPlantResetState;
    if (!first_subhourly_iteration or source_hour != 1) return false;

    state.active_plant_species_count = 0;
    @memset(state.minimum_daily_canopy_water_potential_megapascal, 0);
    return true;
}

test "first iteration of hour one resets runtime species and active count" {
    var potentials = [_]f64{ -1, -2, -3, -4, -5, -6, -7 };
    var state: State = .{
        .active_plant_species_count = 7,
        .minimum_daily_canopy_water_potential_megapascal = &potentials,
    };
    try std.testing.expect(try apply(&state, 1, true));
    try std.testing.expectEqual(@as(usize, 0), state.active_plant_species_count);
    for (potentials) |potential|
        try std.testing.expectEqual(@as(f64, 0), potential);
}

test "later nonlinear iteration of hour one retains resettable state" {
    var potentials = [_]f64{ -1, -2 };
    var state: State = .{
        .active_plant_species_count = 2,
        .minimum_daily_canopy_water_potential_megapascal = &potentials,
    };
    const before = potentials;
    try std.testing.expect(!try apply(&state, 1, false));
    try std.testing.expectEqual(@as(usize, 2), state.active_plant_species_count);
    try std.testing.expectEqualDeep(before, potentials);
}

test "first nonlinear iteration after hour one does not reset daily state" {
    var potentials = [_]f64{ -1, -2 };
    var state: State = .{
        .active_plant_species_count = 2,
        .minimum_daily_canopy_water_potential_megapascal = &potentials,
    };
    const before = potentials;
    try std.testing.expect(!try apply(&state, 2, true));
    try std.testing.expectEqualDeep(before, potentials);
}

test "runtime cell with no plant species still resets active count" {
    var state: State = .{
        .active_plant_species_count = 4,
        .minimum_daily_canopy_water_potential_megapascal = &.{},
    };
    try std.testing.expect(try apply(&state, 1, true));
    try std.testing.expectEqual(@as(usize, 0), state.active_plant_species_count);
}

test "nonfinite late species leaves all daily plant state unchanged" {
    var potentials = [_]f64{ -1, -2, std.math.nan(f64) };
    var state: State = .{
        .active_plant_species_count = 3,
        .minimum_daily_canopy_water_potential_megapascal = &potentials,
    };
    try std.testing.expectError(
        error.NonFiniteDailyPlantResetState,
        apply(&state, 1, true),
    );
    try std.testing.expectEqual(@as(usize, 3), state.active_plant_species_count);
    try std.testing.expectEqual(@as(f64, -1), potentials[0]);
    try std.testing.expectEqual(@as(f64, -2), potentials[1]);
    try std.testing.expect(std.math.isNan(potentials[2]));
}
