// **PRODUCTION BOUND.** GROSUB 2709--2714's independent FSNCS cap is called
// by the atomic selected-node transaction in `photosynthesis_node_layer`,
// reached from `shoot_growth_runtime.applyTile`. Unsafe below-threshold source
// overdraw remains an explicit failure.
const std = @import("std");

pub const Inputs = struct {
    selected_node: usize,
    requested_remobilization_fraction: f64,
    snapshot_sheath_carbon_g_c: f64,
    structural_presence_threshold_g_c: f64,
};

/// grosub.f lines 2709--2714. Calculates FSNCS independently from the leaf
/// fraction by comparing requested removal from the sheath snapshot against the
/// current selected logical node. Runtime node ordinals replace ring slots.
pub fn calculate(current_sheath_carbon_g_c: []const f64, inputs: Inputs) !f64 {
    if (inputs.selected_node >= current_sheath_carbon_g_c.len)
        return error.SheathSenescenceFractionNodeIndexOutOfBounds;
    inline for (.{
        inputs.requested_remobilization_fraction,
        inputs.snapshot_sheath_carbon_g_c,
        inputs.structural_presence_threshold_g_c,
        current_sheath_carbon_g_c[inputs.selected_node],
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteSheathSenescenceFractionInput;
    if (inputs.requested_remobilization_fraction < 0 or
        inputs.snapshot_sheath_carbon_g_c < 0 or
        inputs.structural_presence_threshold_g_c < 0 or
        current_sheath_carbon_g_c[inputs.selected_node] < 0)
        return error.InvalidSheathSenescenceFractionInput;

    var fraction = inputs.requested_remobilization_fraction;
    if (inputs.requested_remobilization_fraction * inputs.snapshot_sheath_carbon_g_c >
        current_sheath_carbon_g_c[inputs.selected_node] and
        inputs.snapshot_sheath_carbon_g_c > inputs.structural_presence_threshold_g_c)
        fraction = @max(
            0.0,
            current_sheath_carbon_g_c[inputs.selected_node] /
                inputs.snapshot_sheath_carbon_g_c,
        );

    // The source does not cap a below-threshold snapshot and could overdraw it.
    // ecosys-ng rejects that unsafe state before downstream pool state_update.
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
        return error.SheathSenescenceFractionExceedsAvailableMass;
    return fraction;
}

test "GROSUB sheath cap uses current mass divided by snapshot mass" {
    const current = [_]f64{ 9, 2, 7 };
    const fraction = try calculate(&current, .{
        .selected_node = 1,
        .requested_remobilization_fraction = 0.8,
        .snapshot_sheath_carbon_g_c = 4,
        .structural_presence_threshold_g_c = 1.0e-9,
    });
    // 0.8*4 exceeds current 2, so FSNCS is 2/4 rather than min(1,0.8).
    try std.testing.expectEqual(@as(f64, 0.5), fraction);
}

test "uncapped request is retained when current mass is sufficient" {
    const current = [_]f64{4};
    try std.testing.expectEqual(@as(f64, 0.25), try calculate(&current, .{
        .selected_node = 0,
        .requested_remobilization_fraction = 0.25,
        .snapshot_sheath_carbon_g_c = 4,
        .structural_presence_threshold_g_c = 1.0e-9,
    }));
}

test "logical runtime node beyond source ring is selected directly" {
    var current: [31]f64 = @splat(0);
    current[30] = 3;
    try std.testing.expectEqual(@as(f64, 0.75), try calculate(&current, .{
        .selected_node = 30,
        .requested_remobilization_fraction = 1,
        .snapshot_sheath_carbon_g_c = 4,
        .structural_presence_threshold_g_c = 0,
    }));
}

test "below-threshold over-removal fails instead of producing negative mass" {
    const current = [_]f64{0.5};
    try std.testing.expectError(
        error.SheathSenescenceFractionExceedsAvailableMass,
        calculate(&current, .{
            .selected_node = 0,
            .requested_remobilization_fraction = 1.2,
            .snapshot_sheath_carbon_g_c = 0.5,
            .structural_presence_threshold_g_c = 0.5,
        }),
    );
}

test "invalid runtime index and non-finite state fail explicitly" {
    const current = [_]f64{1};
    try std.testing.expectError(error.SheathSenescenceFractionNodeIndexOutOfBounds, calculate(&current, .{
        .selected_node = 1,
        .requested_remobilization_fraction = 0.1,
        .snapshot_sheath_carbon_g_c = 1,
        .structural_presence_threshold_g_c = 0,
    }));
    const invalid = [_]f64{std.math.nan(f64)};
    try std.testing.expectError(error.NonFiniteSheathSenescenceFractionInput, calculate(&invalid, .{
        .selected_node = 0,
        .requested_remobilization_fraction = 0.1,
        .snapshot_sheath_carbon_g_c = 1,
        .structural_presence_threshold_g_c = 0,
    }));
}
