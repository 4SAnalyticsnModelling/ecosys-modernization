// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 12207--12454 writes fertilizer, adsorbed, and precipitated species
// back per layer. No caller.
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

pub const plain_family_count = 55;
pub const held_family_count = 61;
pub const PlainFamily = struct { layer_amount: []f64, mixed_total: f64 };
pub const HeldFamily = struct { layer_amount: []f64, mixed_total: f64, held_amount: []const f64 };
pub const Inputs = struct {
    first_soil_layer: usize,
    last_mixed_layer: usize,
    mixing_depth_m: f64,
    mixing_fraction: f64,
    cumulative_layer_bottom_m: []const f64,
    layer_thickness_m: []const f64,
    minimum_layer_thickness_m: f64,
    /// REDIST source order: fertilizer(8), HYSI(1), adsorbed(20), precipitated(26).
    plain_families: []const PlainFamily,
    /// REDIST source order: mineral N(8), non-band salts(33), phosphate
    /// non-band(10), phosphate band(10).
    held_families: []const HeldFamily,
};

fn finite(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 12207--12454 for one runtime soil column.
pub fn redistribute(allocator: std.mem.Allocator, inputs: Inputs) !void {
    const layers = inputs.cumulative_layer_bottom_m.len;
    if (layers == 0 or inputs.first_soil_layer > inputs.last_mixed_layer or inputs.last_mixed_layer >= layers or inputs.layer_thickness_m.len != layers or inputs.plain_families.len != plain_family_count or inputs.held_families.len != held_family_count) return error.TillageChemicalRedistributionDimensionMismatch;
    if (!finite(inputs.cumulative_layer_bottom_m) or !finite(inputs.layer_thickness_m)) return error.InvalidTillageChemicalRedistributionInput;
    inline for (.{ inputs.mixing_depth_m, inputs.mixing_fraction, inputs.minimum_layer_thickness_m }) |value| if (!std.math.isFinite(value)) return error.InvalidTillageChemicalRedistributionInput;
    if (inputs.mixing_depth_m <= 0 or inputs.mixing_fraction < 0 or inputs.mixing_fraction > 1 or inputs.minimum_layer_thickness_m < 0) return error.InvalidTillageChemicalRedistributionInput;
    for (inputs.plain_families) |family| {
        if (family.layer_amount.len != layers) return error.TillageChemicalRedistributionDimensionMismatch;
        if (!finite(family.layer_amount) or !std.math.isFinite(family.mixed_total)) return error.InvalidTillageChemicalRedistributionInput;
    }
    for (inputs.held_families) |family| {
        if (family.layer_amount.len != layers or family.held_amount.len != layers) return error.TillageChemicalRedistributionDimensionMismatch;
        if (!finite(family.layer_amount) or !finite(family.held_amount) or !std.math.isFinite(family.mixed_total)) return error.InvalidTillageChemicalRedistributionInput;
    }

    const staged_plain = try allocator.alloc(f64, plain_family_count * layers);
    defer allocator.free(staged_plain);
    const staged_held = try allocator.alloc(f64, held_family_count * layers);
    defer allocator.free(staged_held);
    for (inputs.plain_families, 0..) |family, i| @memcpy(staged_plain[i * layers ..][0..layers], family.layer_amount);
    for (inputs.held_families, 0..) |family, i| @memcpy(staged_held[i * layers ..][0..layers], family.layer_amount);
    for (inputs.first_soil_layer..inputs.last_mixed_layer + 1) |layer| {
        const thickness = inputs.layer_thickness_m[layer];
        if (thickness <= inputs.minimum_layer_thickness_m) continue;
        const overlap = @min(thickness, inputs.mixing_depth_m - (inputs.cumulative_layer_bottom_m[layer] - thickness));
        const fi = overlap / inputs.mixing_depth_m;
        const ti = overlap / thickness;
        const tx = 1.0 - ti;
        for (inputs.plain_families, 0..) |family, i| {
            const old = family.layer_amount[layer];
            staged_plain[i * layers + layer] = ti * old + inputs.mixing_fraction * (fi * family.mixed_total - ti * old) + tx * old;
            if (!std.math.isFinite(staged_plain[i * layers + layer])) return error.NonFiniteTillageChemicalRedistributionResult;
        }
        for (inputs.held_families, 0..) |family, i| {
            const old = family.layer_amount[layer];
            staged_held[i * layers + layer] = ti * old + inputs.mixing_fraction * (fi * family.mixed_total - ti * old) + tx * old + inputs.mixing_fraction * family.held_amount[layer];
            if (!std.math.isFinite(staged_held[i * layers + layer])) return error.NonFiniteTillageChemicalRedistributionResult;
        }
    }
    for (inputs.plain_families, 0..) |family, i| @memcpy(family.layer_amount, staged_plain[i * layers ..][0..layers]);
    for (inputs.held_families, 0..) |family, i| @memcpy(family.layer_amount, staged_held[i * layers ..][0..layers]);
}

test "REDIST tillage chemical redistribution preserves plain and held equation order" {
    const bottoms = [_]f64{ 0.1, 0.3 };
    const thickness = [_]f64{ 0.1, 0.2 };
    const held = [_]f64{ 0.5, 1 };
    var plain_values: [plain_family_count][2]f64 = @splat(@splat(2));
    var held_values: [held_family_count][2]f64 = @splat(@splat(2));
    var plain: [plain_family_count]PlainFamily = undefined;
    var held_families: [held_family_count]HeldFamily = undefined;
    for (0..plain_family_count) |i| plain[i] = .{ .layer_amount = &plain_values[i], .mixed_total = 4 };
    for (0..held_family_count) |i| held_families[i] = .{ .layer_amount = &held_values[i], .mixed_total = 4, .held_amount = &held };
    try redistribute(std.testing.allocator, .{ .first_soil_layer = 0, .last_mixed_layer = 1, .mixing_depth_m = 0.2, .mixing_fraction = 0.5, .cumulative_layer_bottom_m = &bottoms, .layer_thickness_m = &thickness, .minimum_layer_thickness_m = 0.001, .plain_families = &plain, .held_families = &held_families });
    try std.testing.expectEqual(@as(f64, 2), plain_values[0][0]);
    try std.testing.expectEqual(@as(f64, 2.25), held_values[0][0]);
    try std.testing.expectApproxEqAbs(@as(f64, 3), held_values[60][1], 1e-12);
}

test "REDIST tillage chemical late held overflow is atomic" {
    const bottoms = [_]f64{ 0.1, 0.2 };
    const thickness = [_]f64{ 0.1, 0.1 };
    const held = [_]f64{ 1, std.math.floatMax(f64) };
    var plain_values: [plain_family_count][2]f64 = @splat(@splat(2));
    var held_values: [held_family_count][2]f64 = @splat(@splat(2));
    var plain: [plain_family_count]PlainFamily = undefined;
    var held_families: [held_family_count]HeldFamily = undefined;
    for (0..plain_family_count) |i| plain[i] = .{ .layer_amount = &plain_values[i], .mixed_total = 4 };
    for (0..held_family_count) |i| held_families[i] = .{ .layer_amount = &held_values[i], .mixed_total = 4, .held_amount = &held };
    held_families[held_family_count - 1].mixed_total = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteTillageChemicalRedistributionResult, redistribute(std.testing.allocator, .{ .first_soil_layer = 0, .last_mixed_layer = 1, .mixing_depth_m = 0.2, .mixing_fraction = 1, .cumulative_layer_bottom_m = &bottoms, .layer_thickness_m = &thickness, .minimum_layer_thickness_m = 0, .plain_families = &plain, .held_families = &held_families }));
    try std.testing.expectEqual(@as(f64, 2), plain_values[0][0]);
    try std.testing.expectEqual(@as(f64, 2), held_values[0][0]);
}
