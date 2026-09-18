// **SUPERSEDED.** FERT-002 (both findings) is now fixed directly in
// `fertilizer_nitrogen_inventory.zig`'s `applyEventNitrogen`, which activates
// the nitrification-inhibitor pair on formulation 3/4 and hard-resets every
// other layer's urease- and nitrification-inhibitor activity, matching
// `hour1.f:931--951`. This module remains unbound and is kept only for
// historical reference; do not bind it, and do not bind against the source
// range it cites (see below -- that citation was always wrong).
//
// Stale citation, named rather than silently corrected: this module's own header
// cites `hour1.f:795--833`. That range is organic-amendment microbial
// allocation and has nothing to do with inhibitors. The block this module
// actually translates is `hour1.f:923--951`, read directly:
// `IF(FERT(3,I,..).GT.0.0.OR.FERT(7,I,..).GT.0.0)` selects the urea release
// class, `IYTYP(0,...)` maps to `IUTYP` 0/1/2, and `ZNHU0`/`ZNHUI` and
// `ZNFN0`/`ZNFNI` are then each set to 1.0 or 0.0. Anyone who followed the
// original citation and found unrelated code was reading a wrong cite, not a
// wrong module.
//
// The family argument in full: unbound `src/management/` is otherwise superseded
// because production replaced per-statement HOUR1 decomposition with three
// runscript-catalog schedule dispatchers, each legacy statement landing in a
// bound applier. Here the split is uneven. The *reset* half has an owner:
// `soil/nutrients/reactive_nitrogen_state.zig:38--41` allocates and zero-fills
// all four inhibition arrays. The *activation* half has none.
// `fertilizer_nitrogen_inventory.zig:14--15` carries only the urease pair, and
// nothing anywhere sets the nitrification pair from an application. A runscript
// can apply a nitrification-inhibited fertilizer and the inhibition never
// switches on.
//
// Divergence direction, stated openly: with the fractions pinned at their
// zero-filled value, nitrification runs uninhibited, so applied ammonium
// converts to nitrate faster than the reference and modelled leaching and
// denitrification losses are biased high.
//
// Read docs/traceability/soil_nutrients_unbound_disposition.md:103--117 first: it
// identified this gap already but no register ID was ever filed, which is why it
// went untracked.
//
// Register: FERT-002 in docs/discrepancy_register.md.
// M2 fertilizer group of
// docs/traceability/management_unbound_family_is_superseded_by_the_schedule_dispatchers.md
const std = @import("std");

pub const UreaRelease = enum {
    fast,
    normal,
    slow,
};

pub const State = struct {
    urea_release: UreaRelease,
    initial_urease_inhibition_fraction: []f64,
    current_urease_inhibition_fraction: []f64,
    initial_nitrification_inhibition_fraction: []f64,
    current_nitrification_inhibition_fraction: []f64,
};

pub const Result = struct {
    urease_reset: bool,
    nitrification_reset: bool,
};

/// Exact HOUR1 fertilizer inhibitor activation from hour1.f:795-833.
pub fn apply(
    state: *State,
    target_layer: usize,
    formulation_code: u8,
    broadcast_urea_g_n_per_m2: f64,
    banded_urea_g_n_per_m2: f64,
) !Result {
    const count = state.initial_urease_inhibition_fraction.len;
    if (count == 0 or target_layer >= count or
        state.current_urease_inhibition_fraction.len != count or
        state.initial_nitrification_inhibition_fraction.len != count or
        state.current_nitrification_inhibition_fraction.len != count)
        return error.FertilizerInhibitorDimensionMismatch;
    inline for (.{
        broadcast_urea_g_n_per_m2,
        banded_urea_g_n_per_m2,
    }) |amount| {
        if (!std.math.isFinite(amount))
            return error.NonFiniteFertilizerInhibitorInput;
        if (amount < 0) return error.InvalidFertilizerInhibitorInput;
    }
    inline for (.{
        state.initial_urease_inhibition_fraction,
        state.current_urease_inhibition_fraction,
        state.initial_nitrification_inhibition_fraction,
        state.current_nitrification_inhibition_fraction,
    }) |values| for (values) |value|
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidFertilizerInhibitorState;

    const urease_reset =
        broadcast_urea_g_n_per_m2 > 0 or banded_urea_g_n_per_m2 > 0;
    const nitrification_reset =
        formulation_code == 3 or formulation_code == 4;
    if (!urease_reset and !nitrification_reset)
        return .{ .urease_reset = false, .nitrification_reset = false };

    if (urease_reset) {
        state.urea_release = switch (formulation_code) {
            0 => .fast,
            1, 3 => .normal,
            else => .slow,
        };
        for (
            state.initial_urease_inhibition_fraction,
            state.current_urease_inhibition_fraction,
            0..,
        ) |*initial, *current, layer| {
            const activity: f64 = if (layer == target_layer) 1 else 0;
            initial.* = activity;
            current.* = activity;
        }
    }
    if (nitrification_reset) {
        for (
            state.initial_nitrification_inhibition_fraction,
            state.current_nitrification_inhibition_fraction,
            0..,
        ) |*initial, *current, layer| {
            const activity: f64 = if (layer == target_layer) 1 else 0;
            initial.* = activity;
            current.* = activity;
        }
    }
    return .{
        .urease_reset = urease_reset,
        .nitrification_reset = nitrification_reset,
    };
}

fn exampleState(
    urease_initial: []f64,
    urease_current: []f64,
    nitrification_initial: []f64,
    nitrification_current: []f64,
) State {
    return .{
        .urea_release = .slow,
        .initial_urease_inhibition_fraction = urease_initial,
        .current_urease_inhibition_fraction = urease_current,
        .initial_nitrification_inhibition_fraction = nitrification_initial,
        .current_nitrification_inhibition_fraction = nitrification_current,
    };
}

test "formulation three with urea resets both inhibitors at target layer" {
    var ui = [_]f64{ 0.2, 0.2, 0.2 };
    var uc = ui;
    var ni = ui;
    var nc = ui;
    var value = exampleState(&ui, &uc, &ni, &nc);
    const result = try apply(&value, 1, 3, 1, 0);
    try std.testing.expect(result.urease_reset);
    try std.testing.expect(result.nitrification_reset);
    try std.testing.expectEqual(UreaRelease.normal, value.urea_release);
    try std.testing.expectEqualDeep([_]f64{ 0, 1, 0 }, ui);
    try std.testing.expectEqualDeep([_]f64{ 0, 1, 0 }, uc);
    try std.testing.expectEqualDeep([_]f64{ 0, 1, 0 }, ni);
    try std.testing.expectEqualDeep([_]f64{ 0, 1, 0 }, nc);
}

test "formulation four activates nitrification inhibitor without urea" {
    var ui = [_]f64{ 0.2, 0.3 };
    var uc = ui;
    var ni = [_]f64{ 0, 0 };
    var nc = ni;
    var value = exampleState(&ui, &uc, &ni, &nc);
    const result = try apply(&value, 0, 4, 0, 0);
    try std.testing.expect(!result.urease_reset);
    try std.testing.expect(result.nitrification_reset);
    try std.testing.expectEqualDeep([_]f64{ 0.2, 0.3 }, ui);
    try std.testing.expectEqualDeep([_]f64{ 1, 0 }, ni);
}

test "urea formulation branches preserve source release mapping" {
    inline for (.{
        .{ @as(u8, 0), UreaRelease.fast },
        .{ @as(u8, 1), UreaRelease.normal },
        .{ @as(u8, 2), UreaRelease.slow },
        .{ @as(u8, 3), UreaRelease.normal },
        .{ @as(u8, 9), UreaRelease.slow },
    }) |case| {
        var ui = [_]f64{0};
        var uc = [_]f64{0};
        var ni = [_]f64{0};
        var nc = [_]f64{0};
        var value = exampleState(&ui, &uc, &ni, &nc);
        _ = try apply(&value, 0, case[0], 0, 1);
        try std.testing.expectEqual(case[1], value.urea_release);
    }
}

test "ordinary non-urea formulation leaves all state unchanged" {
    var ui = [_]f64{0.2};
    var uc = [_]f64{0.3};
    var ni = [_]f64{0.4};
    var nc = [_]f64{0.5};
    var value = exampleState(&ui, &uc, &ni, &nc);
    const result = try apply(&value, 0, 1, 0, 0);
    try std.testing.expect(!result.urease_reset);
    try std.testing.expect(!result.nitrification_reset);
    try std.testing.expectEqual(@as(f64, 0.2), ui[0]);
    try std.testing.expectEqual(@as(f64, 0.5), nc[0]);
}

test "nonfinite late layer leaves every inhibitor array unchanged" {
    var ui = [_]f64{ 0.2, 0.3 };
    var uc = [_]f64{ 0.2, 0.3 };
    var ni = [_]f64{ 0.2, std.math.nan(f64) };
    var nc = [_]f64{ 0.2, 0.3 };
    var value = exampleState(&ui, &uc, &ni, &nc);
    try std.testing.expectError(
        error.InvalidFertilizerInhibitorState,
        apply(&value, 0, 3, 1, 0),
    );
    try std.testing.expectEqual(@as(f64, 0.2), ui[0]);
    try std.testing.expect(std.math.isNan(ni[1]));
}
