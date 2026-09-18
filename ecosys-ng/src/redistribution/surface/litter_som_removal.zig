// **A8a DISPOSITION: SUPERSEDED BY THE BOUND OPERATION-21 RUNTIME OWNER.**
// `surface/litter_removal.applyRuntimeCell` performs the source-ordered SOM
// traversal, preserves the charcoal split, validates closure, and commits
// atomically through the production disturbance dispatcher.
//
// **HISTORICAL A8a DISPOSITION: GAP, keep unbound and do not banner as settled.**
//
// `redist.f` 11205--11227, verified. Part of REDIST operation 21, which
// production parses and then drops (DIST-021), so no production owner exists to
// supersede this.
//
// The member worth preserving here is the charcoal split: legacy derives
// `DCC`/`DNC`/`DPC` from the fifth SOM complex of `OSC`/`OSN`/`OSP` through
// `IF(M.LE.4)...ELSE` at 11214--11222, not from separate charcoal arrays. This
// module encodes that as an index condition, whereas
// `surface/litter_removal.zig` expects charcoal already separated into its own
// slices, which pushes the split into an adapter nobody has written.
//
// Family analysis and what closing DIST-021 requires: docs/traceability/
// redistribution_surface_litter_removal_group_is_a_second_translation_of_a_gap.md

const std = @import("std");

pub const Totals = struct {
    remaining_carbon_g_c: f64,
    remaining_nitrogen_g_n: f64,
    remaining_phosphorus_g_p: f64,
    removed_carbon_g_c: f64,
    removed_nitrogen_g_n: f64,
    removed_phosphorus_g_p: f64,
    charcoal_remaining_carbon_g_c: f64,
    charcoal_remaining_nitrogen_g_n: f64,
    charcoal_remaining_phosphorus_g_p: f64,
};
pub const Pools = struct {
    layer_count: usize,
    /// M=1..5, K=0..2, then runtime layer.
    soil_organic_carbon_g_c: []f64, // OSC
    colonized_soil_organic_carbon_g_c: []f64, // OSA, subset of OSC
    soil_organic_nitrogen_g_n: []f64, // OSN
    soil_organic_phosphorus_g_p: []f64, // OSP
};

fn index(layer_count: usize, k: usize, m: usize, layer: usize) usize {
    return ((k * 5 + m) * layer_count) + layer;
}
fn finiteNonnegative(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value) or value < 0) return false;
    return true;
}

/// Direct translation of REDIST 11205--11227 at surface layer 0.
pub fn remove(removal_fraction: f64, pools: Pools, initial: Totals) !Totals {
    const expected = 3 * 5 * pools.layer_count;
    if (pools.layer_count == 0 or pools.soil_organic_carbon_g_c.len != expected or
        pools.colonized_soil_organic_carbon_g_c.len != expected or
        pools.soil_organic_nitrogen_g_n.len != expected or pools.soil_organic_phosphorus_g_p.len != expected)
        return error.SurfaceLitterSomDimensionMismatch;
    if (!std.math.isFinite(removal_fraction) or removal_fraction < 0 or removal_fraction > 0.999 or
        !finiteNonnegative(pools.soil_organic_carbon_g_c) or
        !finiteNonnegative(pools.colonized_soil_organic_carbon_g_c) or
        !finiteNonnegative(pools.soil_organic_nitrogen_g_n) or
        !finiteNonnegative(pools.soil_organic_phosphorus_g_p))
        return error.InvalidSurfaceLitterSomInput;
    inline for (std.meta.fields(Totals)) |field|
        if (!std.math.isFinite(@field(initial, field.name)) or @field(initial, field.name) < 0) return error.InvalidSurfaceLitterSomInput;

    var carbon: [15]f64 = undefined;
    var colonized: [15]f64 = undefined;
    var nitrogen: [15]f64 = undefined;
    var phosphorus: [15]f64 = undefined;
    var next = initial;
    var sequential: usize = 0;
    for (0..3) |k| for (0..5) |m| {
        const at = index(pools.layer_count, k, m, 0);
        const removed_c = removal_fraction * pools.soil_organic_carbon_g_c[at];
        const removed_colonized_c = removal_fraction * pools.colonized_soil_organic_carbon_g_c[at];
        const removed_n = removal_fraction * pools.soil_organic_nitrogen_g_n[at];
        const removed_p = removal_fraction * pools.soil_organic_phosphorus_g_p[at];
        carbon[sequential] = pools.soil_organic_carbon_g_c[at] - removed_c;
        colonized[sequential] = pools.colonized_soil_organic_carbon_g_c[at] - removed_colonized_c;
        nitrogen[sequential] = pools.soil_organic_nitrogen_g_n[at] - removed_n;
        phosphorus[sequential] = pools.soil_organic_phosphorus_g_p[at] - removed_p;
        if (m < 4) {
            next.remaining_carbon_g_c += carbon[sequential];
            next.remaining_nitrogen_g_n += nitrogen[sequential];
            next.remaining_phosphorus_g_p += phosphorus[sequential];
        } else {
            next.charcoal_remaining_carbon_g_c += carbon[sequential];
            next.charcoal_remaining_nitrogen_g_n += nitrogen[sequential];
            next.charcoal_remaining_phosphorus_g_p += phosphorus[sequential];
        }
        next.removed_carbon_g_c += removed_c;
        next.removed_nitrogen_g_n += removed_n;
        next.removed_phosphorus_g_p += removed_p;
        inline for (std.meta.fields(Totals)) |field|
            if (!std.math.isFinite(@field(next, field.name))) return error.NonFiniteSurfaceLitterSomResult;
        sequential += 1;
    };
    sequential = 0;
    for (0..3) |k| for (0..5) |m| {
        const at = index(pools.layer_count, k, m, 0);
        pools.soil_organic_carbon_g_c[at] = carbon[sequential];
        pools.colonized_soil_organic_carbon_g_c[at] = colonized[sequential];
        pools.soil_organic_nitrogen_g_n[at] = nitrogen[sequential];
        pools.soil_organic_phosphorus_g_p[at] = phosphorus[sequential];
        sequential += 1;
    };
    return next;
}

test "REDIST surface SOM removal preserves M split and C N P accounting" {
    var carbon: [15]f64 = @splat(4);
    var colonized: [15]f64 = @splat(2);
    var nitrogen: [15]f64 = @splat(2);
    var phosphorus: [15]f64 = @splat(1);
    const result = try remove(0.25, .{ .layer_count = 1, .soil_organic_carbon_g_c = &carbon, .colonized_soil_organic_carbon_g_c = &colonized, .soil_organic_nitrogen_g_n = &nitrogen, .soil_organic_phosphorus_g_p = &phosphorus }, std.mem.zeroes(Totals));
    try std.testing.expectApproxEqAbs(60, result.remaining_carbon_g_c + result.charcoal_remaining_carbon_g_c + result.removed_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(30, result.remaining_nitrogen_g_n + result.charcoal_remaining_nitrogen_g_n + result.removed_nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(15, result.remaining_phosphorus_g_p + result.charcoal_remaining_phosphorus_g_p + result.removed_phosphorus_g_p, 1e-12);
    try std.testing.expectEqual(@as(f64, 3), carbon[0]);
    try std.testing.expectEqual(@as(f64, 1.5), colonized[0]);
    try std.testing.expectEqual(@as(f64, 9), result.charcoal_remaining_carbon_g_c);
}

test "REDIST surface SOM overflow is atomic" {
    var carbon: [15]f64 = @splat(std.math.floatMax(f64));
    var colonized: [15]f64 = @splat(1);
    var nitrogen: [15]f64 = @splat(1);
    var phosphorus: [15]f64 = @splat(1);
    try std.testing.expectError(error.NonFiniteSurfaceLitterSomResult, remove(0.25, .{ .layer_count = 1, .soil_organic_carbon_g_c = &carbon, .colonized_soil_organic_carbon_g_c = &colonized, .soil_organic_nitrogen_g_n = &nitrogen, .soil_organic_phosphorus_g_p = &phosphorus }, std.mem.zeroes(Totals)));
    try std.testing.expectEqual(std.math.floatMax(f64), carbon[0]);
    try std.testing.expectEqual(@as(f64, 1), colonized[0]);
}
