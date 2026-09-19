/// Persistent numerical-schedule state for the fixed one-hour science step.
///
/// These values do not relax any physical or conservation gate. A retained
/// preferred schedule may be attempted first, but production caps it at 32,
/// permits only one fallback, and uses clean hours to probe coarser schedules.
/// Legacy rungs remain valid so existing checkpoints can migrate safely.
const heat_step = @import("../soil/water/heat_step.zig");

pub const State = struct {
    preferred_substep_count: u8 = 1,
    coarsening_probe_cooldown_hours: u8 = 0,
    freeze_flow_coupling_floor_active: bool = false,

    pub fn validate(self: State) !void {
        // Delegates to the authoritative ladder membership check
        // (`heat_step.recovery_substep_counts` via
        // `isRecoverySubstepCountMember`) instead of a hand-maintained
        // literal switch. The literal switch was found during issue-059's
        // sibling sweep to be a third independent, unsynchronized copy of
        // the ladder's contents (after the two issue-058 already fixed) --
        // a future ladder extension would have made this checkpoint
        // validator silently reject a legitimate restored
        // `preferred_substep_count` instead of accepting it.
        if (!heat_step.isRecoverySubstepCountMember(self.preferred_substep_count))
            return error.InvalidAdaptiveHourSubstepCount;
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

test "adaptive hour schedule validate is genuinely ladder-derived, not a hardcoded duplicate (issue-059 sibling fix)" {
    const std = @import("std");
    // Every current ladder member must validate, and every current
    // non-member must not -- proving `validate` actually consults
    // `heat_step.recovery_substep_counts` (via `isRecoverySubstepCountMember`)
    // rather than re-deriving its own independent copy of the set.
    for (heat_step.recovery_substep_counts) |member|
        try (State{ .preferred_substep_count = member }).validate();
    for ([_]u8{ 0, 3, 5, 17, 21, 63, 65, 128, 255 }) |non_member| {
        try std.testing.expect(!heat_step.isRecoverySubstepCountMember(non_member));
        try std.testing.expectError(
            error.InvalidAdaptiveHourSubstepCount,
            (State{ .preferred_substep_count = non_member }).validate(),
        );
    }
}
