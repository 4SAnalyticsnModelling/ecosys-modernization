// **A8a DISPOSITION: superseded, by making the gate structural instead of a
// predicate.** `redist.f:5056`'s `IF(ABS(TQR).GT.ZEROS)` exists because the
// block beneath it unconditionally divides staged solute masses by a runoff
// volume; the test is there to stop a division by a numerically empty
// denominator. Production never stages a lateral solute flux, so it has no such
// division to guard. `surface/runoff_carrier.zig:84--95` sums the four
// directional volumes for the donor cell, does `continue` when that sum is
// exactly zero, and otherwise divides by the *donor water* it has just
// validated as positive, clamping the transported fraction at
// `maximum_transport_fraction`. The decision this module returns is therefore
// taken per donor cell inside the one routine that could have divided by it,
// and there is nothing left for a separate gate object to decide.
//
// The three bound wrappers that drive that carrier
// (`stages/hourly_science_gas_surface_water.zig:345 surface_mineral_transport`,
// `:367 surface_organic_transport`, `:387 surface_dissolved_gas_transport`) are
// called unconditionally every hour, which is correct precisely because the
// gate moved inward: a cell with no runoff contributes no transfers rather than
// being skipped by a caller-level branch.
//
// Two honest differences, neither filed as a divergence. First, production's
// test is `total_water_m3 == 0` while `redist.f` uses the cell-specific
// `ZEROS` threshold, so production will do arithmetic for a runoff volume that
// legacy would have called negligible; that arithmetic is safe because the
// divisor is the donor's own water and the quotient is clamped, so it yields a
// vanishing transfer rather than an ill-conditioned one. Second, production
// gates on the sum of directional magnitudes whereas `TQR` is the *net*, so a
// cell with equal and opposite lateral exchanges passes production's gate and
// fails legacy's; production is the more physical of the two, since solute is
// genuinely carried both ways.
//
// The nested salt gate at `redist.f:5114`, which this module also returns as
// `apply_salt_updates`, has no production counterpart because the salt overland
// path itself has none. That is already recorded as the SALT family gap in the
// `src/redistribution/surface/` disposition; it is not a residual of this
// module, whose only remaining content would be a boolean nobody can consume.
//
// overland flow group of docs/traceability/redistribution_surface_overland_and_snow_solute_dispositions.md

const std = @import("std");

pub const SaltSimulation = enum { disabled, enabled };

pub const Decision = struct {
    apply_overland_updates: bool,
    apply_salt_updates: bool,
};

/// Exact REDIST.F line 5056 outer predicate and line 5114 nested salt gate,
/// closed at lines 5157--5158. TQR is net runoff volume per model step (m3);
/// ZEROS is the cell-specific negligible-volume threshold (m3).
pub fn decide(
    net_runoff_volume_m3_per_step: f64,
    negligible_volume_m3: f64,
    salt_simulation: SaltSimulation,
) !Decision {
    if (!std.math.isFinite(net_runoff_volume_m3_per_step) or
        !std.math.isFinite(negligible_volume_m3))
        return error.NonFiniteOverlandFlowUpdateGateInput;
    if (negligible_volume_m3 < 0) return error.InvalidOverlandFlowUpdateThreshold;

    const apply_overland = @abs(net_runoff_volume_m3_per_step) > negligible_volume_m3;
    return .{
        .apply_overland_updates = apply_overland,
        .apply_salt_updates = apply_overland and salt_simulation == .enabled,
    };
}

test "REDIST overland update gate uses strict absolute runoff threshold" {
    const positive = try decide(2, 1, .disabled);
    const negative = try decide(-2, 1, .disabled);
    try std.testing.expect(positive.apply_overland_updates);
    try std.testing.expect(negative.apply_overland_updates);
    try std.testing.expect(!positive.apply_salt_updates);
}

test "runoff equal to threshold does not enter REDIST update block" {
    const positive = try decide(1, 1, .enabled);
    const negative = try decide(-1, 1, .enabled);
    try std.testing.expect(!positive.apply_overland_updates);
    try std.testing.expect(!negative.apply_overland_updates);
    try std.testing.expect(!positive.apply_salt_updates);
}

test "nested salt update requires both outer runoff gate and ISALTG" {
    const enabled = try decide(2, 1, .enabled);
    const disabled = try decide(2, 1, .disabled);
    const no_runoff = try decide(0, 1, .enabled);
    try std.testing.expect(enabled.apply_salt_updates);
    try std.testing.expect(!disabled.apply_salt_updates);
    try std.testing.expect(!no_runoff.apply_salt_updates);
}

test "zero threshold retains strict nonzero runoff behavior" {
    try std.testing.expect(!(try decide(0, 0, .enabled)).apply_overland_updates);
    try std.testing.expect((try decide(-1.0e-20, 0, .enabled)).apply_overland_updates);
}

test "invalid gate inputs fail immediately" {
    try std.testing.expectError(error.NonFiniteOverlandFlowUpdateGateInput, decide(std.math.nan(f64), 0, .enabled));
    try std.testing.expectError(error.NonFiniteOverlandFlowUpdateGateInput, decide(1, std.math.inf(f64), .enabled));
    try std.testing.expectError(error.InvalidOverlandFlowUpdateThreshold, decide(1, -1, .enabled));
}
