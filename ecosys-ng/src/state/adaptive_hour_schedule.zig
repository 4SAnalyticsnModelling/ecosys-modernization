/// Persistent numerical-schedule state for the fixed one-hour science step.
///
/// These values do not relax any physical or conservation gate. A retained
/// preferred schedule may be attempted first, but production caps it at 32,
/// permits only one fallback, and uses clean hours to probe coarser schedules.
/// Legacy rungs remain valid so existing checkpoints can migrate safely.
pub const State = struct {
    preferred_substep_count: u8 = 1,
    coarsening_probe_cooldown_hours: u8 = 0,
    freeze_flow_coupling_floor_active: bool = false,

    pub fn validate(self: State) !void {
        switch (self.preferred_substep_count) {
            1, 2, 4, 8, 16, 20, 32, 64 => {},
            else => return error.InvalidAdaptiveHourSubstepCount,
        }
    }
};

test "adaptive hour schedule accepts supported checkpoint rungs" {
    const std = @import("std");
    inline for (.{ 1, 2, 4, 8, 16, 20, 32, 64 }) |substeps|
        try (State{ .preferred_substep_count = substeps }).validate();
    try std.testing.expectError(
        error.InvalidAdaptiveHourSubstepCount,
        (State{ .preferred_substep_count = 3 }).validate(),
    );
}
