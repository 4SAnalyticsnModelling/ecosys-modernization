// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 12487--12554 scales the macropore complement of every mixed family.
// No caller.
//
// The whole directory has one importer, `src/module_index.zig`.
// `disturbance_management_dispatch.applyEvent:95` handles `.tillage` for roots
// and plants only, and its `ApplyContext:41--61` carries no soil-column state,
// so the omission is structural. The gap is live: `f25til98` fires codes 10,
// 10, and 8 during 1998, and `day.f:347--349` gives XCORP = 0.0, 0.0, and 0.2,
// all passing the `redist.f:11277` gate.
//
// Binding requires a new soil-side disturbance path and an ordering decision
// against the existing root-side response, which is A1's call under the
// shared-state rule.
//
// write-back group of
// docs/traceability/redistribution_tillage_unbound_family_disposition.md
//
const std = @import("std");

pub const macropore_family_count = 68;
pub const Inputs = struct {
    first_soil_layer: usize,
    last_mixed_layer: usize,
    soil_mixing_remaining_fraction: f64, // XCORP
    layer_thickness_m: []const f64,
    minimum_layer_thickness_m: f64,
    /// Exact REDIST 12487--12554 order: mineral N/P bands, dissolved salts,
    /// complexes, phosphate species, then aqueous gases.
    macropore_families: []const []f64,
};

fn finite(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 12487--12554 for one runtime soil column.
pub fn scale(allocator: std.mem.Allocator, inputs: Inputs) !void {
    const layers = inputs.layer_thickness_m.len;
    if (layers == 0 or inputs.first_soil_layer > inputs.last_mixed_layer or
        inputs.last_mixed_layer >= layers or inputs.macropore_families.len != macropore_family_count)
        return error.TillageMacroporeScalingDimensionMismatch;
    if (!std.math.isFinite(inputs.soil_mixing_remaining_fraction) or
        inputs.soil_mixing_remaining_fraction < 0 or inputs.soil_mixing_remaining_fraction > 1 or
        !std.math.isFinite(inputs.minimum_layer_thickness_m) or inputs.minimum_layer_thickness_m < 0 or
        !finite(inputs.layer_thickness_m))
        return error.InvalidTillageMacroporeScalingInput;
    for (inputs.macropore_families) |values| {
        if (values.len != layers) return error.TillageMacroporeScalingDimensionMismatch;
        if (!finite(values)) return error.InvalidTillageMacroporeScalingInput;
    }

    const staged = try allocator.alloc(f64, macropore_family_count * layers);
    defer allocator.free(staged);
    for (inputs.macropore_families, 0..) |values, family|
        @memcpy(staged[family * layers ..][0..layers], values);
    for (inputs.first_soil_layer..inputs.last_mixed_layer + 1) |layer| {
        if (inputs.layer_thickness_m[layer] <= inputs.minimum_layer_thickness_m) continue;
        for (inputs.macropore_families, 0..) |values, family| {
            staged[family * layers + layer] = inputs.soil_mixing_remaining_fraction * values[layer];
            if (!std.math.isFinite(staged[family * layers + layer]))
                return error.NonFiniteTillageMacroporeScalingResult;
        }
    }
    for (inputs.macropore_families, 0..) |values, family|
        @memcpy(values, staged[family * layers ..][0..layers]);
}

test "REDIST tillage macropore scaling preserves family and layer gates" {
    const thickness = [_]f64{ 0.1, 0.001, 0.2 };
    var backing: [macropore_family_count][3]f64 = @splat(@splat(4));
    var families: [macropore_family_count][]f64 = undefined;
    for (0..macropore_family_count) |family| families[family] = &backing[family];
    try scale(std.testing.allocator, .{
        .first_soil_layer = 0,
        .last_mixed_layer = 2,
        .soil_mixing_remaining_fraction = 0.25,
        .layer_thickness_m = &thickness,
        .minimum_layer_thickness_m = 0.001,
        .macropore_families = &families,
    });
    try std.testing.expectEqual(@as(f64, 1), backing[0][0]);
    try std.testing.expectEqual(@as(f64, 4), backing[0][1]);
    try std.testing.expectEqual(@as(f64, 1), backing[67][2]);
}

test "REDIST tillage macropore validation is atomic" {
    const thickness = [_]f64{ 0.1, 0.2 };
    var backing: [macropore_family_count][2]f64 = @splat(@splat(4));
    backing[67][1] = std.math.inf(f64);
    var families: [macropore_family_count][]f64 = undefined;
    for (0..macropore_family_count) |family| families[family] = &backing[family];
    try std.testing.expectError(error.InvalidTillageMacroporeScalingInput, scale(std.testing.allocator, .{
        .first_soil_layer = 0,
        .last_mixed_layer = 1,
        .soil_mixing_remaining_fraction = 0.25,
        .layer_thickness_m = &thickness,
        .minimum_layer_thickness_m = 0,
        .macropore_families = &families,
    }));
    try std.testing.expectEqual(@as(f64, 4), backing[0][0]);
}
