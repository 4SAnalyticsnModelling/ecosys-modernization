// **A8a DISPOSITION: SUPERSEDED BY THE BOUND OPERATION-21 RUNTIME OWNER.**
// `management/disturbance_management_dispatch.applyEvent` dispatches operation
// 21 to `surface/litter_removal.applyRuntimeCell`, whose atomic traversal owns
// dissolved and adsorbed acetate plus the associated C/N/P export ledgers.
//
// **HISTORICAL A8a DISPOSITION: GAP, keep unbound and do not banner as settled.**
//
// `redist.f` 11144--11201, verified. Part of REDIST operation 21, which
// production parses and then drops at `disturbance_management_dispatch`'s
// `else => return` (DIST-021), so there is no owner to be superseded by.
//
// This module is the reason DIST-021 cannot simply be closed through the
// designated applier `surface/litter_removal.zig`: it carries the acetate pools
// `OQA`, `OQAH` and `OHA`, which have no counterpart in `litter_removal.Pools`,
// and it reproduces the legacy asymmetry at 11199 where `OQA` and `OQAH` enter
// the retained sum `DC` but only `OHC`, never `OHA`, enters the removed sum
// `OC`. Binding the designated applier as written would silently drop adsorbed
// acetate carbon from a litter-removal event.
//
// Family analysis and what closing DIST-021 requires: docs/traceability/
// redistribution_surface_litter_removal_group_is_a_second_translation_of_a_gap.md

const std = @import("std");

pub const ElementTotals = struct {
    remaining_carbon_g_c: f64,
    remaining_nitrogen_g_n: f64,
    remaining_phosphorus_g_p: f64,
    removed_carbon_g_c: f64,
    removed_nitrogen_g_n: f64,
    removed_phosphorus_g_p: f64,
};
pub const Pools = struct {
    /// ORC/ORN/ORP: K=0..2, M=1..2, then runtime layer.
    residue_carbon_g_c: []f64,
    residue_nitrogen_g_n: []f64,
    residue_phosphorus_g_p: []f64,
    /// OQC/OQA/OQN/OQP: K=0..2, then runtime layer.
    dissolved_carbon_g_c: []f64,
    dissolved_acetate_g_c: []f64,
    dissolved_nitrogen_g_n: []f64,
    dissolved_phosphorus_g_p: []f64,
    /// OQCH/OQAH/OQNH/OQPH.
    humic_dissolved_carbon_g_c: []f64,
    humic_dissolved_acetate_g_c: []f64,
    humic_dissolved_nitrogen_g_n: []f64,
    humic_dissolved_phosphorus_g_p: []f64,
    /// OHC/OHA/OHN/OHP.
    adsorbed_carbon_g_c: []f64,
    adsorbed_acetate_g_c: []f64,
    adsorbed_nitrogen_g_n: []f64,
    adsorbed_phosphorus_g_p: []f64,
};

fn finiteSlice(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value) or value < 0) return false;
    return true;
}
fn residueIndex(layer_count: usize, k: usize, m: usize, layer: usize) usize {
    return ((k * 2 + m) * layer_count) + layer;
}
fn fractionIndex(layer_count: usize, k: usize, layer: usize) usize {
    return k * layer_count + layer;
}

/// Direct translation of REDIST 11144--11201 at surface layer 0.
pub fn remove(layer_count: usize, removal_fraction: f64, pools: Pools, initial: ElementTotals) !ElementTotals {
    if (layer_count == 0 or !std.math.isFinite(removal_fraction) or removal_fraction < 0 or removal_fraction > 0.999)
        return error.InvalidSurfaceLitterSolubleRemovalInput;
    inline for (std.meta.fields(Pools)) |field| {
        const values = @field(pools, field.name);
        const expected = if (std.mem.startsWith(u8, field.name, "residue_")) 6 * layer_count else 3 * layer_count;
        if (values.len != expected) return error.SurfaceLitterSolubleRemovalDimensionMismatch;
        if (!finiteSlice(values)) return error.InvalidSurfaceLitterSolubleRemovalInput;
    }
    inline for (std.meta.fields(ElementTotals)) |field|
        if (!std.math.isFinite(@field(initial, field.name)) or @field(initial, field.name) < 0) return error.InvalidSurfaceLitterSolubleRemovalInput;

    var next = initial;
    var residue_c: [6]f64 = undefined;
    var residue_n: [6]f64 = undefined;
    var residue_p: [6]f64 = undefined;
    var fraction_values: [12][3]f64 = undefined;
    var r: usize = 0;
    for (0..3) |k| {
        for (0..2) |m| {
            const at = residueIndex(layer_count, k, m, 0);
            const removed_c = removal_fraction * pools.residue_carbon_g_c[at];
            const removed_n = removal_fraction * pools.residue_nitrogen_g_n[at];
            const removed_p = removal_fraction * pools.residue_phosphorus_g_p[at];
            residue_c[r] = pools.residue_carbon_g_c[at] - removed_c;
            residue_n[r] = pools.residue_nitrogen_g_n[at] - removed_n;
            residue_p[r] = pools.residue_phosphorus_g_p[at] - removed_p;
            next.remaining_carbon_g_c += residue_c[r];
            next.remaining_nitrogen_g_n += residue_n[r];
            next.remaining_phosphorus_g_p += residue_p[r];
            next.removed_carbon_g_c += removed_c;
            next.removed_nitrogen_g_n += removed_n;
            next.removed_phosphorus_g_p += removed_p;
            r += 1;
        }
        const arrays = .{ pools.dissolved_carbon_g_c, pools.dissolved_acetate_g_c, pools.dissolved_nitrogen_g_n, pools.dissolved_phosphorus_g_p, pools.humic_dissolved_carbon_g_c, pools.humic_dissolved_acetate_g_c, pools.humic_dissolved_nitrogen_g_n, pools.humic_dissolved_phosphorus_g_p, pools.adsorbed_carbon_g_c, pools.adsorbed_acetate_g_c, pools.adsorbed_nitrogen_g_n, pools.adsorbed_phosphorus_g_p };
        inline for (arrays, 0..) |values, pool| {
            const value = values[fractionIndex(layer_count, k, 0)];
            fraction_values[pool][k] = value - removal_fraction * value;
        }
        next.removed_carbon_g_c += removal_fraction * pools.dissolved_carbon_g_c[fractionIndex(layer_count, k, 0)] + removal_fraction * pools.dissolved_acetate_g_c[fractionIndex(layer_count, k, 0)];
        next.removed_nitrogen_g_n += removal_fraction * pools.dissolved_nitrogen_g_n[fractionIndex(layer_count, k, 0)];
        next.removed_phosphorus_g_p += removal_fraction * pools.dissolved_phosphorus_g_p[fractionIndex(layer_count, k, 0)];
        next.removed_carbon_g_c += removal_fraction * pools.humic_dissolved_carbon_g_c[fractionIndex(layer_count, k, 0)] + removal_fraction * pools.humic_dissolved_acetate_g_c[fractionIndex(layer_count, k, 0)];
        next.removed_nitrogen_g_n += removal_fraction * pools.humic_dissolved_nitrogen_g_n[fractionIndex(layer_count, k, 0)];
        next.removed_phosphorus_g_p += removal_fraction * pools.humic_dissolved_phosphorus_g_p[fractionIndex(layer_count, k, 0)];
        next.remaining_carbon_g_c += fraction_values[0][k] + fraction_values[4][k] + fraction_values[8][k] + fraction_values[1][k] + fraction_values[5][k] + fraction_values[9][k];
        next.remaining_nitrogen_g_n += fraction_values[2][k] + fraction_values[6][k] + fraction_values[10][k];
        next.remaining_phosphorus_g_p += fraction_values[3][k] + fraction_values[7][k] + fraction_values[11][k];
        next.removed_carbon_g_c += removal_fraction * pools.adsorbed_carbon_g_c[fractionIndex(layer_count, k, 0)];
        next.removed_nitrogen_g_n += removal_fraction * pools.adsorbed_nitrogen_g_n[fractionIndex(layer_count, k, 0)];
        next.removed_phosphorus_g_p += removal_fraction * pools.adsorbed_phosphorus_g_p[fractionIndex(layer_count, k, 0)];
        inline for (std.meta.fields(ElementTotals)) |field|
            if (!std.math.isFinite(@field(next, field.name))) return error.NonFiniteSurfaceLitterSolubleRemovalResult;
    }
    r = 0;
    for (0..3) |k| {
        for (0..2) |m| {
            const at = residueIndex(layer_count, k, m, 0);
            pools.residue_carbon_g_c[at] = residue_c[r];
            pools.residue_nitrogen_g_n[at] = residue_n[r];
            pools.residue_phosphorus_g_p[at] = residue_p[r];
            r += 1;
        }
        inline for (.{ pools.dissolved_carbon_g_c, pools.dissolved_acetate_g_c, pools.dissolved_nitrogen_g_n, pools.dissolved_phosphorus_g_p, pools.humic_dissolved_carbon_g_c, pools.humic_dissolved_acetate_g_c, pools.humic_dissolved_nitrogen_g_n, pools.humic_dissolved_phosphorus_g_p, pools.adsorbed_carbon_g_c, pools.adsorbed_acetate_g_c, pools.adsorbed_nitrogen_g_n, pools.adsorbed_phosphorus_g_p }, 0..) |values, pool|
            values[fractionIndex(layer_count, k, 0)] = fraction_values[pool][k];
    }
    return next;
}

/// Production-science correction of `remove` (REDIST 11144--11201): line 11199
/// omits removed adsorbed acetate carbon (`OHA`) from the `OC` removal ledger,
/// even though it is removed from the pool at 11188--11192 alongside `OHC`.
/// This variant credits `OAH = removal_fraction * adsorbed_acetate_g_c` into
/// `removed_carbon_g_c` exactly once, closing the carbon ledger. See
/// `docs/discrepancy_register.md` "Surface-litter adsorbed-acetate removal
/// ledger omission" and `docs/model_changes.md` "Surface-litter adsorbed-
/// acetate removal ledger correction". Not yet called by any production path:
/// REDIST operation 21 is currently dropped unbound at DIST-021
/// (`disturbance_management_dispatch`'s `else => return`), and the designated
/// applier `surface/litter_removal.zig` has no acetate-pool counterpart to
/// route through this correction. This function exists so the correction is
/// ready once that binding gap is closed; it is not itself the fix for DIST-021.
pub fn removeCorrected(layer_count: usize, removal_fraction: f64, pools: Pools, initial: ElementTotals) !ElementTotals {
    if (layer_count == 0 or !std.math.isFinite(removal_fraction) or removal_fraction < 0 or removal_fraction > 0.999)
        return error.InvalidSurfaceLitterSolubleRemovalInput;
    inline for (std.meta.fields(Pools)) |field| {
        const values = @field(pools, field.name);
        const expected = if (std.mem.startsWith(u8, field.name, "residue_")) 6 * layer_count else 3 * layer_count;
        if (values.len != expected) return error.SurfaceLitterSolubleRemovalDimensionMismatch;
        if (!finiteSlice(values)) return error.InvalidSurfaceLitterSolubleRemovalInput;
    }
    inline for (std.meta.fields(ElementTotals)) |field|
        if (!std.math.isFinite(@field(initial, field.name)) or @field(initial, field.name) < 0) return error.InvalidSurfaceLitterSolubleRemovalInput;

    var next = initial;
    var residue_c: [6]f64 = undefined;
    var residue_n: [6]f64 = undefined;
    var residue_p: [6]f64 = undefined;
    var fraction_values: [12][3]f64 = undefined;
    var r: usize = 0;
    for (0..3) |k| {
        for (0..2) |m| {
            const at = residueIndex(layer_count, k, m, 0);
            const removed_c = removal_fraction * pools.residue_carbon_g_c[at];
            const removed_n = removal_fraction * pools.residue_nitrogen_g_n[at];
            const removed_p = removal_fraction * pools.residue_phosphorus_g_p[at];
            residue_c[r] = pools.residue_carbon_g_c[at] - removed_c;
            residue_n[r] = pools.residue_nitrogen_g_n[at] - removed_n;
            residue_p[r] = pools.residue_phosphorus_g_p[at] - removed_p;
            next.remaining_carbon_g_c += residue_c[r];
            next.remaining_nitrogen_g_n += residue_n[r];
            next.remaining_phosphorus_g_p += residue_p[r];
            next.removed_carbon_g_c += removed_c;
            next.removed_nitrogen_g_n += removed_n;
            next.removed_phosphorus_g_p += removed_p;
            r += 1;
        }
        const arrays = .{ pools.dissolved_carbon_g_c, pools.dissolved_acetate_g_c, pools.dissolved_nitrogen_g_n, pools.dissolved_phosphorus_g_p, pools.humic_dissolved_carbon_g_c, pools.humic_dissolved_acetate_g_c, pools.humic_dissolved_nitrogen_g_n, pools.humic_dissolved_phosphorus_g_p, pools.adsorbed_carbon_g_c, pools.adsorbed_acetate_g_c, pools.adsorbed_nitrogen_g_n, pools.adsorbed_phosphorus_g_p };
        inline for (arrays, 0..) |values, pool| {
            const value = values[fractionIndex(layer_count, k, 0)];
            fraction_values[pool][k] = value - removal_fraction * value;
        }
        next.removed_carbon_g_c += removal_fraction * pools.dissolved_carbon_g_c[fractionIndex(layer_count, k, 0)] + removal_fraction * pools.dissolved_acetate_g_c[fractionIndex(layer_count, k, 0)];
        next.removed_nitrogen_g_n += removal_fraction * pools.dissolved_nitrogen_g_n[fractionIndex(layer_count, k, 0)];
        next.removed_phosphorus_g_p += removal_fraction * pools.dissolved_phosphorus_g_p[fractionIndex(layer_count, k, 0)];
        next.removed_carbon_g_c += removal_fraction * pools.humic_dissolved_carbon_g_c[fractionIndex(layer_count, k, 0)] + removal_fraction * pools.humic_dissolved_acetate_g_c[fractionIndex(layer_count, k, 0)];
        next.removed_nitrogen_g_n += removal_fraction * pools.humic_dissolved_nitrogen_g_n[fractionIndex(layer_count, k, 0)];
        next.removed_phosphorus_g_p += removal_fraction * pools.humic_dissolved_phosphorus_g_p[fractionIndex(layer_count, k, 0)];
        next.remaining_carbon_g_c += fraction_values[0][k] + fraction_values[4][k] + fraction_values[8][k] + fraction_values[1][k] + fraction_values[5][k] + fraction_values[9][k];
        next.remaining_nitrogen_g_n += fraction_values[2][k] + fraction_values[6][k] + fraction_values[10][k];
        next.remaining_phosphorus_g_p += fraction_values[3][k] + fraction_values[7][k] + fraction_values[11][k];
        // Corrected: credit removed adsorbed acetate carbon (OAH) exactly once,
        // alongside OHC, unlike legacy REDIST 11199.
        next.removed_carbon_g_c += removal_fraction * pools.adsorbed_carbon_g_c[fractionIndex(layer_count, k, 0)] + removal_fraction * pools.adsorbed_acetate_g_c[fractionIndex(layer_count, k, 0)];
        next.removed_nitrogen_g_n += removal_fraction * pools.adsorbed_nitrogen_g_n[fractionIndex(layer_count, k, 0)];
        next.removed_phosphorus_g_p += removal_fraction * pools.adsorbed_phosphorus_g_p[fractionIndex(layer_count, k, 0)];
        inline for (std.meta.fields(ElementTotals)) |field|
            if (!std.math.isFinite(@field(next, field.name))) return error.NonFiniteSurfaceLitterSolubleRemovalResult;
    }
    r = 0;
    for (0..3) |k| {
        for (0..2) |m| {
            const at = residueIndex(layer_count, k, m, 0);
            pools.residue_carbon_g_c[at] = residue_c[r];
            pools.residue_nitrogen_g_n[at] = residue_n[r];
            pools.residue_phosphorus_g_p[at] = residue_p[r];
            r += 1;
        }
        inline for (.{ pools.dissolved_carbon_g_c, pools.dissolved_acetate_g_c, pools.dissolved_nitrogen_g_n, pools.dissolved_phosphorus_g_p, pools.humic_dissolved_carbon_g_c, pools.humic_dissolved_acetate_g_c, pools.humic_dissolved_nitrogen_g_n, pools.humic_dissolved_phosphorus_g_p, pools.adsorbed_carbon_g_c, pools.adsorbed_acetate_g_c, pools.adsorbed_nitrogen_g_n, pools.adsorbed_phosphorus_g_p }, 0..) |values, pool|
            values[fractionIndex(layer_count, k, 0)] = fraction_values[pool][k];
    }
    return next;
}

test "REDIST residue dissolved and adsorbed removal preserves legacy acetate ledger omission" {
    var residue_c: [6]f64 = @splat(4);
    var residue_n: [6]f64 = @splat(2);
    var residue_p: [6]f64 = @splat(1);
    var fractions: [12][3]f64 = @splat(@splat(1));
    const pools = Pools{ .residue_carbon_g_c = &residue_c, .residue_nitrogen_g_n = &residue_n, .residue_phosphorus_g_p = &residue_p, .dissolved_carbon_g_c = &fractions[0], .dissolved_acetate_g_c = &fractions[1], .dissolved_nitrogen_g_n = &fractions[2], .dissolved_phosphorus_g_p = &fractions[3], .humic_dissolved_carbon_g_c = &fractions[4], .humic_dissolved_acetate_g_c = &fractions[5], .humic_dissolved_nitrogen_g_n = &fractions[6], .humic_dissolved_phosphorus_g_p = &fractions[7], .adsorbed_carbon_g_c = &fractions[8], .adsorbed_acetate_g_c = &fractions[9], .adsorbed_nitrogen_g_n = &fractions[10], .adsorbed_phosphorus_g_p = &fractions[11] };
    const result = try remove(1, 0.25, pools, .{ .remaining_carbon_g_c = 0, .remaining_nitrogen_g_n = 0, .remaining_phosphorus_g_p = 0, .removed_carbon_g_c = 0, .removed_nitrogen_g_n = 0, .removed_phosphorus_g_p = 0 });
    // REDIST 11192 removes OHA, but 11199 adds only OCH to OC: 0.75 g C
    // is absent from the legacy removed/remaining carbon ledgers in this case.
    try std.testing.expectApproxEqAbs(@as(f64, 41.25), result.remaining_carbon_g_c + result.removed_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 21), result.remaining_nitrogen_g_n + result.removed_nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 15), result.remaining_phosphorus_g_p + result.removed_phosphorus_g_p, 1e-12);
    try std.testing.expectEqual(@as(f64, 3), residue_c[0]);
    try std.testing.expectEqual(@as(f64, 0.75), fractions[11][2]);
}

test "REDIST removeCorrected closes the carbon ledger the legacy kernel leaves open" {
    var residue_c: [6]f64 = @splat(4);
    var residue_n: [6]f64 = @splat(2);
    var residue_p: [6]f64 = @splat(1);
    var fractions: [12][3]f64 = @splat(@splat(1));
    const pools = Pools{ .residue_carbon_g_c = &residue_c, .residue_nitrogen_g_n = &residue_n, .residue_phosphorus_g_p = &residue_p, .dissolved_carbon_g_c = &fractions[0], .dissolved_acetate_g_c = &fractions[1], .dissolved_nitrogen_g_n = &fractions[2], .dissolved_phosphorus_g_p = &fractions[3], .humic_dissolved_carbon_g_c = &fractions[4], .humic_dissolved_acetate_g_c = &fractions[5], .humic_dissolved_nitrogen_g_n = &fractions[6], .humic_dissolved_phosphorus_g_p = &fractions[7], .adsorbed_carbon_g_c = &fractions[8], .adsorbed_acetate_g_c = &fractions[9], .adsorbed_nitrogen_g_n = &fractions[10], .adsorbed_phosphorus_g_p = &fractions[11] };
    const result = try removeCorrected(1, 0.25, pools, .{ .remaining_carbon_g_c = 0, .remaining_nitrogen_g_n = 0, .remaining_phosphorus_g_p = 0, .removed_carbon_g_c = 0, .removed_nitrogen_g_n = 0, .removed_phosphorus_g_p = 0 });
    // Same fixture as the legacy-preserving test above (initial total carbon 42 g
    // C: 24 g residue + 18 g across the six carbon-bearing fraction pools at 3 g
    // each). Unlike `remove`, no OHA is dropped, so the ledger closes exactly.
    try std.testing.expectApproxEqAbs(@as(f64, 42), result.remaining_carbon_g_c + result.removed_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 21), result.remaining_nitrogen_g_n + result.removed_nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 15), result.remaining_phosphorus_g_p + result.removed_phosphorus_g_p, 1e-12);
}

test "REDIST removeCorrected rejects non-finite input atomically" {
    var residue_c: [6]f64 = @splat(std.math.floatMax(f64));
    var residue_n: [6]f64 = @splat(1);
    var residue_p: [6]f64 = @splat(1);
    var fractions: [12][3]f64 = @splat(@splat(1));
    const pools = Pools{ .residue_carbon_g_c = &residue_c, .residue_nitrogen_g_n = &residue_n, .residue_phosphorus_g_p = &residue_p, .dissolved_carbon_g_c = &fractions[0], .dissolved_acetate_g_c = &fractions[1], .dissolved_nitrogen_g_n = &fractions[2], .dissolved_phosphorus_g_p = &fractions[3], .humic_dissolved_carbon_g_c = &fractions[4], .humic_dissolved_acetate_g_c = &fractions[5], .humic_dissolved_nitrogen_g_n = &fractions[6], .humic_dissolved_phosphorus_g_p = &fractions[7], .adsorbed_carbon_g_c = &fractions[8], .adsorbed_acetate_g_c = &fractions[9], .adsorbed_nitrogen_g_n = &fractions[10], .adsorbed_phosphorus_g_p = &fractions[11] };
    try std.testing.expectError(error.NonFiniteSurfaceLitterSolubleRemovalResult, removeCorrected(1, 0.25, pools, .{ .remaining_carbon_g_c = 0, .remaining_nitrogen_g_n = 0, .remaining_phosphorus_g_p = 0, .removed_carbon_g_c = 0, .removed_nitrogen_g_n = 0, .removed_phosphorus_g_p = 0 }));
    try std.testing.expectEqual(std.math.floatMax(f64), residue_c[0]);
}

test "REDIST removeCorrected rejects an out-of-range removal fraction" {
    var residue_c: [6]f64 = @splat(1);
    var residue_n: [6]f64 = @splat(1);
    var residue_p: [6]f64 = @splat(1);
    var fractions: [12][3]f64 = @splat(@splat(1));
    const pools = Pools{ .residue_carbon_g_c = &residue_c, .residue_nitrogen_g_n = &residue_n, .residue_phosphorus_g_p = &residue_p, .dissolved_carbon_g_c = &fractions[0], .dissolved_acetate_g_c = &fractions[1], .dissolved_nitrogen_g_n = &fractions[2], .dissolved_phosphorus_g_p = &fractions[3], .humic_dissolved_carbon_g_c = &fractions[4], .humic_dissolved_acetate_g_c = &fractions[5], .humic_dissolved_nitrogen_g_n = &fractions[6], .humic_dissolved_phosphorus_g_p = &fractions[7], .adsorbed_carbon_g_c = &fractions[8], .adsorbed_acetate_g_c = &fractions[9], .adsorbed_nitrogen_g_n = &fractions[10], .adsorbed_phosphorus_g_p = &fractions[11] };
    try std.testing.expectError(error.InvalidSurfaceLitterSolubleRemovalInput, removeCorrected(1, 1.5, pools, .{ .remaining_carbon_g_c = 0, .remaining_nitrogen_g_n = 0, .remaining_phosphorus_g_p = 0, .removed_carbon_g_c = 0, .removed_nitrogen_g_n = 0, .removed_phosphorus_g_p = 0 }));
}

test "REDIST soluble removal overflow is atomic" {
    var residue_c: [6]f64 = @splat(std.math.floatMax(f64));
    var residue_n: [6]f64 = @splat(1);
    var residue_p: [6]f64 = @splat(1);
    var fractions: [12][3]f64 = @splat(@splat(1));
    const pools = Pools{ .residue_carbon_g_c = &residue_c, .residue_nitrogen_g_n = &residue_n, .residue_phosphorus_g_p = &residue_p, .dissolved_carbon_g_c = &fractions[0], .dissolved_acetate_g_c = &fractions[1], .dissolved_nitrogen_g_n = &fractions[2], .dissolved_phosphorus_g_p = &fractions[3], .humic_dissolved_carbon_g_c = &fractions[4], .humic_dissolved_acetate_g_c = &fractions[5], .humic_dissolved_nitrogen_g_n = &fractions[6], .humic_dissolved_phosphorus_g_p = &fractions[7], .adsorbed_carbon_g_c = &fractions[8], .adsorbed_acetate_g_c = &fractions[9], .adsorbed_nitrogen_g_n = &fractions[10], .adsorbed_phosphorus_g_p = &fractions[11] };
    try std.testing.expectError(error.NonFiniteSurfaceLitterSolubleRemovalResult, remove(1, 0.25, pools, .{ .remaining_carbon_g_c = 0, .remaining_nitrogen_g_n = 0, .remaining_phosphorus_g_p = 0, .removed_carbon_g_c = 0, .removed_nitrogen_g_n = 0, .removed_phosphorus_g_p = 0 }));
    try std.testing.expectEqual(std.math.floatMax(f64), residue_c[0]);
    try std.testing.expectEqual(@as(f64, 1), fractions[0][0]);
}
