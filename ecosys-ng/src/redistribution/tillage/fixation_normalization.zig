// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 12828--12838 normalizes the surface fixation state after mixing,
// including surface index zero. No caller.
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
// normalization group of
// docs/traceability/redistribution_tillage_unbound_family_disposition.md
//
const std = @import("std");

pub const Inputs = struct {
    first_soil_layer: usize, // NU
    last_soil_layer: usize, // LL
    zero_threshold: f64, // runtime legacy ZERO threshold
    initial_fixation_fraction: []f64, // ZNFN0, layer index includes surface layer 0
    current_fixation_fraction: []f64, // ZNFNI
    mixed_initial_surface_fraction: f64, // ZNFNX0
    surface_incorporation_factor: f64, // XCORP0
    previous_fixation_total: f64, // TZNFN2
    target_fixation_total: f64, // TZNFNI
    incorporated_fixation_total: f64, // TZNFNG
};

pub const Totals = struct {
    previous_fixation_total: f64,
    target_fixation_total: f64,
};

fn finite(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 12828--12838, including surface index zero.
pub fn normalize(allocator: std.mem.Allocator, inputs: Inputs) !Totals {
    const layers = inputs.current_fixation_fraction.len;
    if (layers == 0 or inputs.initial_fixation_fraction.len != layers or inputs.first_soil_layer > inputs.last_soil_layer or inputs.last_soil_layer >= layers) return error.TillageFixationNormalizationDimensionMismatch;
    if (!finite(inputs.initial_fixation_fraction) or !finite(inputs.current_fixation_fraction)) return error.InvalidTillageFixationNormalizationInput;
    inline for (.{ inputs.zero_threshold, inputs.mixed_initial_surface_fraction, inputs.surface_incorporation_factor, inputs.previous_fixation_total, inputs.target_fixation_total, inputs.incorporated_fixation_total }) |value| {
        if (!std.math.isFinite(value)) return error.InvalidTillageFixationNormalizationInput;
    }
    if (inputs.zero_threshold < 0) return error.InvalidTillageFixationNormalizationInput;

    const staged_initial = try allocator.dupe(f64, inputs.initial_fixation_fraction);
    defer allocator.free(staged_initial);
    const staged_current = try allocator.dupe(f64, inputs.current_fixation_fraction);
    defer allocator.free(staged_current);
    staged_initial[0] = inputs.mixed_initial_surface_fraction;
    staged_current[0] = staged_current[0] * inputs.surface_incorporation_factor;
    const previous_total = inputs.previous_fixation_total + inputs.incorporated_fixation_total;
    const target_total = inputs.target_fixation_total + inputs.incorporated_fixation_total;
    inline for (.{ staged_initial[0], staged_current[0], previous_total, target_total }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteTillageFixationNormalizationResult;
    }
    for (inputs.first_soil_layer..inputs.last_soil_layer + 1) |layer| {
        if (previous_total > inputs.zero_threshold) {
            staged_current[layer] = staged_current[layer] * target_total / previous_total;
            if (!std.math.isFinite(staged_current[layer])) return error.NonFiniteTillageFixationNormalizationResult;
            staged_current[layer] = staged_current[layer] + 0.5 * (staged_initial[layer] - staged_current[layer]);
            if (!std.math.isFinite(staged_current[layer])) return error.NonFiniteTillageFixationNormalizationResult;
        }
    }
    @memcpy(inputs.initial_fixation_fraction, staged_initial);
    @memcpy(inputs.current_fixation_fraction, staged_current);
    return .{ .previous_fixation_total = previous_total, .target_fixation_total = target_total };
}

test "REDIST fixation normalization preserves surface-first and two-step layer order" {
    var initial = [_]f64{ 1, 10, 20 };
    var current = [_]f64{ 2, 4, 8 };
    const totals = try normalize(std.testing.allocator, .{
        .first_soil_layer = 1,
        .last_soil_layer = 2,
        .zero_threshold = 1.0e-15,
        .initial_fixation_fraction = &initial,
        .current_fixation_fraction = &current,
        .mixed_initial_surface_fraction = 3,
        .surface_incorporation_factor = 0.25,
        .previous_fixation_total = 6,
        .target_fixation_total = 12,
        .incorporated_fixation_total = 2,
    });
    try std.testing.expectEqual(@as(f64, 3), initial[0]);
    try std.testing.expectEqual(@as(f64, 0.5), current[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), current[1], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 17), current[2], 1.0e-12);
    try std.testing.expectEqual(@as(f64, 8), totals.previous_fixation_total);
    try std.testing.expectEqual(@as(f64, 14), totals.target_fixation_total);
}

test "REDIST fixation normalization skips soil rescaling at legacy ZERO threshold" {
    var initial = [_]f64{ 1, 10 };
    var current = [_]f64{ 2, 4 };
    _ = try normalize(std.testing.allocator, .{
        .first_soil_layer = 1,
        .last_soil_layer = 1,
        .zero_threshold = 1.0e-15,
        .initial_fixation_fraction = &initial,
        .current_fixation_fraction = &current,
        .mixed_initial_surface_fraction = 3,
        .surface_incorporation_factor = 0.25,
        .previous_fixation_total = 0,
        .target_fixation_total = 12,
        .incorporated_fixation_total = 1.0e-16,
    });
    try std.testing.expectEqual(@as(f64, 0.5), current[0]);
    try std.testing.expectEqual(@as(f64, 4), current[1]);
}

test "REDIST fixation normalization rejects overflow atomically" {
    var initial = [_]f64{ 1, 10 };
    var current = [_]f64{ 2, std.math.floatMax(f64) };
    try std.testing.expectError(error.NonFiniteTillageFixationNormalizationResult, normalize(std.testing.allocator, .{
        .first_soil_layer = 1,
        .last_soil_layer = 1,
        .zero_threshold = 0,
        .initial_fixation_fraction = &initial,
        .current_fixation_fraction = &current,
        .mixed_initial_surface_fraction = 3,
        .surface_incorporation_factor = 1,
        .previous_fixation_total = 1,
        .target_fixation_total = 2,
        .incorporated_fixation_total = 0,
    }));
    try std.testing.expectEqual(@as(f64, 1), initial[0]);
    try std.testing.expectEqual(@as(f64, 2), current[0]);
    try std.testing.expectEqual(std.math.floatMax(f64), current[1]);
}
