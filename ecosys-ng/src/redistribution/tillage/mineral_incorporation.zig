// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 12725--12760 adds the incorporated mineral totals into each layer. No
// caller.
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
// incorporation group of
// docs/traceability/redistribution_tillage_unbound_family_disposition.md
//
const std = @import("std");

pub const incorporated_family_count = 30;

pub const Inputs = struct {
    layer: usize,
    layer_count: usize,
    incorporation_fraction: f64, // FI, dimensionless
    mixed_layer_fraction: f64, // TI, dimensionless
    unmixed_layer_fraction: f64, // TX, dimensionless
    tillage_incorporation_fraction: f64, // CORP, dimensionless
    /// REDIST 12725--12754 source order. Each slice is indexed by soil layer;
    /// totals have the corresponding pool units for the mixed soil column.
    layer_amounts: [incorporated_family_count][]f64,
    mixed_totals: [incorporated_family_count]f64,
    urea_hydrolysis_initial: []f64, // ZNHU0
    urea_hydrolysis_current: []f64, // ZNHUI
    fertilizer_fixation_initial: []f64, // ZNFN0
    fertilizer_fixation_current: []f64, // ZNFNI
    mixed_urea_hydrolysis_initial: f64, // ZNHUX0
    mixed_urea_hydrolysis_current: f64, // ZNHUXI
    mixed_fertilizer_fixation_initial: f64, // ZNFNX0
    mixed_fertilizer_fixation_current: f64, // TZNFNI
    incorporated_fertilizer_fixation: f64, // TZNFNG
    cumulative_fertilizer_fixation: *f64, // TZNFN2
};

fn finite(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 12725--12760 for one runtime-indexed layer.
pub fn incorporate(allocator: std.mem.Allocator, inputs: Inputs) !void {
    if (inputs.layer_count == 0 or inputs.layer >= inputs.layer_count) return error.TillageMineralIncorporationDimensionMismatch;
    inline for (.{ inputs.incorporation_fraction, inputs.mixed_layer_fraction, inputs.unmixed_layer_fraction, inputs.tillage_incorporation_fraction, inputs.mixed_urea_hydrolysis_initial, inputs.mixed_urea_hydrolysis_current, inputs.mixed_fertilizer_fixation_initial, inputs.mixed_fertilizer_fixation_current, inputs.incorporated_fertilizer_fixation, inputs.cumulative_fertilizer_fixation.* }) |value| {
        if (!std.math.isFinite(value)) return error.InvalidTillageMineralIncorporationInput;
    }
    if (inputs.incorporation_fraction == 0) return error.ZeroTillageMineralIncorporationFraction;
    for (inputs.layer_amounts) |amounts| {
        if (amounts.len != inputs.layer_count) return error.TillageMineralIncorporationDimensionMismatch;
        if (!finite(amounts)) return error.InvalidTillageMineralIncorporationInput;
    }
    inline for (.{ inputs.urea_hydrolysis_initial, inputs.urea_hydrolysis_current, inputs.fertilizer_fixation_initial, inputs.fertilizer_fixation_current }) |values| {
        if (values.len != inputs.layer_count) return error.TillageMineralIncorporationDimensionMismatch;
        if (!finite(values)) return error.InvalidTillageMineralIncorporationInput;
    }
    if (!finite(&inputs.mixed_totals)) return error.InvalidTillageMineralIncorporationInput;

    const staged = try allocator.alloc(f64, incorporated_family_count);
    defer allocator.free(staged);
    for (inputs.layer_amounts, inputs.mixed_totals, 0..) |amounts, total, family| {
        staged[family] = amounts[inputs.layer] + inputs.incorporation_fraction * total;
        if (!std.math.isFinite(staged[family])) return error.NonFiniteTillageMineralIncorporationResult;
    }
    const staged_fixation = (inputs.mixed_layer_fraction * inputs.fertilizer_fixation_current[inputs.layer] + inputs.tillage_incorporation_fraction * (inputs.incorporation_fraction * inputs.mixed_fertilizer_fixation_current - inputs.mixed_layer_fraction * inputs.fertilizer_fixation_current[inputs.layer]) + inputs.unmixed_layer_fraction * inputs.fertilizer_fixation_current[inputs.layer] + inputs.incorporation_fraction * inputs.incorporated_fertilizer_fixation) / inputs.incorporation_fraction;
    const staged_cumulative = inputs.cumulative_fertilizer_fixation.* + staged_fixation;
    if (!std.math.isFinite(staged_fixation) or !std.math.isFinite(staged_cumulative)) return error.NonFiniteTillageMineralIncorporationResult;

    for (inputs.layer_amounts, 0..) |amounts, family| amounts[inputs.layer] = staged[family];
    inputs.urea_hydrolysis_initial[inputs.layer] = inputs.mixed_urea_hydrolysis_initial;
    inputs.urea_hydrolysis_current[inputs.layer] = inputs.mixed_urea_hydrolysis_current;
    inputs.fertilizer_fixation_initial[inputs.layer] = inputs.mixed_fertilizer_fixation_initial;
    inputs.fertilizer_fixation_current[inputs.layer] = staged_fixation;
    inputs.cumulative_fertilizer_fixation.* = staged_cumulative;
}

test "REDIST mineral incorporation preserves source-order additions and fixation equation" {
    var amounts_storage: [incorporated_family_count][2]f64 = @splat(.{ 2, 3 });
    var amounts: [incorporated_family_count][]f64 = undefined;
    for (0..incorporated_family_count) |family| amounts[family] = &amounts_storage[family];
    const totals: [incorporated_family_count]f64 = @splat(4);
    var znhu0 = [_]f64{ 1, 2 };
    var znhui = [_]f64{ 3, 4 };
    var znfn0 = [_]f64{ 5, 6 };
    var znfni = [_]f64{ 7, 8 };
    var cumulative: f64 = 11;
    try incorporate(std.testing.allocator, .{
        .layer = 1,
        .layer_count = 2,
        .incorporation_fraction = 0.5,
        .mixed_layer_fraction = 0.25,
        .unmixed_layer_fraction = 0.75,
        .tillage_incorporation_fraction = 0.4,
        .layer_amounts = amounts,
        .mixed_totals = totals,
        .urea_hydrolysis_initial = &znhu0,
        .urea_hydrolysis_current = &znhui,
        .fertilizer_fixation_initial = &znfn0,
        .fertilizer_fixation_current = &znfni,
        .mixed_urea_hydrolysis_initial = 10,
        .mixed_urea_hydrolysis_current = 12,
        .mixed_fertilizer_fixation_initial = 14,
        .mixed_fertilizer_fixation_current = 16,
        .incorporated_fertilizer_fixation = 18,
        .cumulative_fertilizer_fixation = &cumulative,
    });
    try std.testing.expectEqual(@as(f64, 5), amounts_storage[0][1]);
    try std.testing.expectEqual(@as(f64, 2), amounts_storage[0][0]);
    try std.testing.expectEqual(@as(f64, 10), znhu0[1]);
    try std.testing.expectEqual(@as(f64, 12), znhui[1]);
    try std.testing.expectEqual(@as(f64, 14), znfn0[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 38.8), znfni[1], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 49.8), cumulative, 1.0e-12);
}

test "REDIST mineral incorporation rejects non-finite results atomically" {
    var amounts_storage: [incorporated_family_count][1]f64 = @splat(.{1});
    var amounts: [incorporated_family_count][]f64 = undefined;
    for (0..incorporated_family_count) |family| amounts[family] = &amounts_storage[family];
    var totals: [incorporated_family_count]f64 = @splat(1);
    totals[29] = std.math.floatMax(f64);
    var scalar = [_]f64{1};
    var cumulative: f64 = 1;
    try std.testing.expectError(error.NonFiniteTillageMineralIncorporationResult, incorporate(std.testing.allocator, .{
        .layer = 0,
        .layer_count = 1,
        .incorporation_fraction = 2,
        .mixed_layer_fraction = 1,
        .unmixed_layer_fraction = 0,
        .tillage_incorporation_fraction = 1,
        .layer_amounts = amounts,
        .mixed_totals = totals,
        .urea_hydrolysis_initial = &scalar,
        .urea_hydrolysis_current = &scalar,
        .fertilizer_fixation_initial = &scalar,
        .fertilizer_fixation_current = &scalar,
        .mixed_urea_hydrolysis_initial = 1,
        .mixed_urea_hydrolysis_current = 1,
        .mixed_fertilizer_fixation_initial = 1,
        .mixed_fertilizer_fixation_current = 1,
        .incorporated_fertilizer_fixation = 1,
        .cumulative_fertilizer_fixation = &cumulative,
    }));
    try std.testing.expectEqual(@as(f64, 1), amounts_storage[0][0]);
    try std.testing.expectEqual(@as(f64, 1), cumulative);
}
