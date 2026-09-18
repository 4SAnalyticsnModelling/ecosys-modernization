// **A8a DISPOSITION: SUPERSEDED by the bound operation-21 runtime owner.**
//
// This retained compatibility oracle translates `redist.f` 11121--11227.
// Production operation 21 is hard-bound through
// `surface/litter_removal.zig.applyRuntimeCell`, which owns the authoritative
// runtime shapes, accounting, and atomic publication. Keep this oracle exact:
// REDIST finishes the complete K=0..2 microbial-biomass sweep before beginning
// the separate K=0..2 residue/dissolved/adsorbed/SOM sweep.

const std = @import("std");
const biomass_module = @import("litter_microbial_biomass_removal.zig");
const soluble_module = @import("litter_soluble_removal.zig");
const som_module = @import("litter_som_removal.zig");

pub const Totals = biomass_module.RemovalTotals;
pub const Pools = struct {
    biomass: biomass_module.Pools,
    soluble: soluble_module.Pools,
    som: som_module.Pools,
};

fn cloneSlice(allocator: std.mem.Allocator, values: []const f64) ![]f64 {
    return allocator.dupe(f64, values);
}
fn cloneBiomass(allocator: std.mem.Allocator, pools: biomass_module.Pools) !biomass_module.Pools {
    return .{ .layer_count = pools.layer_count, .carbon_g_c = try cloneSlice(allocator, pools.carbon_g_c), .nitrogen_g_n = try cloneSlice(allocator, pools.nitrogen_g_n), .phosphorus_g_p = try cloneSlice(allocator, pools.phosphorus_g_p) };
}
fn cloneSoluble(allocator: std.mem.Allocator, p: soluble_module.Pools) !soluble_module.Pools {
    return .{
        .residue_carbon_g_c = try cloneSlice(allocator, p.residue_carbon_g_c),
        .residue_nitrogen_g_n = try cloneSlice(allocator, p.residue_nitrogen_g_n),
        .residue_phosphorus_g_p = try cloneSlice(allocator, p.residue_phosphorus_g_p),
        .dissolved_carbon_g_c = try cloneSlice(allocator, p.dissolved_carbon_g_c),
        .dissolved_acetate_g_c = try cloneSlice(allocator, p.dissolved_acetate_g_c),
        .dissolved_nitrogen_g_n = try cloneSlice(allocator, p.dissolved_nitrogen_g_n),
        .dissolved_phosphorus_g_p = try cloneSlice(allocator, p.dissolved_phosphorus_g_p),
        .humic_dissolved_carbon_g_c = try cloneSlice(allocator, p.humic_dissolved_carbon_g_c),
        .humic_dissolved_acetate_g_c = try cloneSlice(allocator, p.humic_dissolved_acetate_g_c),
        .humic_dissolved_nitrogen_g_n = try cloneSlice(allocator, p.humic_dissolved_nitrogen_g_n),
        .humic_dissolved_phosphorus_g_p = try cloneSlice(allocator, p.humic_dissolved_phosphorus_g_p),
        .adsorbed_carbon_g_c = try cloneSlice(allocator, p.adsorbed_carbon_g_c),
        .adsorbed_acetate_g_c = try cloneSlice(allocator, p.adsorbed_acetate_g_c),
        .adsorbed_nitrogen_g_n = try cloneSlice(allocator, p.adsorbed_nitrogen_g_n),
        .adsorbed_phosphorus_g_p = try cloneSlice(allocator, p.adsorbed_phosphorus_g_p),
    };
}
fn cloneSom(allocator: std.mem.Allocator, p: som_module.Pools) !som_module.Pools {
    return .{ .layer_count = p.layer_count, .soil_organic_carbon_g_c = try cloneSlice(allocator, p.soil_organic_carbon_g_c), .colonized_soil_organic_carbon_g_c = try cloneSlice(allocator, p.colonized_soil_organic_carbon_g_c), .soil_organic_nitrogen_g_n = try cloneSlice(allocator, p.soil_organic_nitrogen_g_n), .soil_organic_phosphorus_g_p = try cloneSlice(allocator, p.soil_organic_phosphorus_g_p) };
}
fn biomassIndex(layers: usize, k: usize, n: usize, m: usize, layer: usize) usize {
    return (((k * 7 + n) * 3 + m) * layers) + layer;
}
fn residueIndex(layers: usize, k: usize, m: usize) usize {
    return (k * 2 + m) * layers;
}
fn fractionIndex(layers: usize, k: usize) usize {
    return k * layers;
}
fn somIndex(layers: usize, k: usize, m: usize) usize {
    return (k * 5 + m) * layers;
}
fn validateTotals(t: Totals) !void {
    inline for (std.meta.fields(Totals)) |field|
        if (!std.math.isFinite(@field(t, field.name))) return error.NonFiniteSurfaceLitterCompatibilityResult;
}
fn validatePools(pools: Pools, destination_layer: usize) !void {
    const layers = pools.biomass.layer_count;
    if (layers == 0 or destination_layer >= layers or pools.som.layer_count != layers or
        pools.biomass.carbon_g_c.len != 63 * layers or pools.biomass.nitrogen_g_n.len != 63 * layers or pools.biomass.phosphorus_g_p.len != 63 * layers or
        pools.som.soil_organic_carbon_g_c.len != 15 * layers or pools.som.colonized_soil_organic_carbon_g_c.len != 15 * layers or pools.som.soil_organic_nitrogen_g_n.len != 15 * layers or pools.som.soil_organic_phosphorus_g_p.len != 15 * layers)
        return error.SurfaceLitterCompatibilityDimensionMismatch;
    inline for (std.meta.fields(soluble_module.Pools)) |field| {
        const values = @field(pools.soluble, field.name);
        const expected = if (std.mem.startsWith(u8, field.name, "residue_")) 6 * layers else 3 * layers;
        if (values.len != expected) return error.SurfaceLitterCompatibilityDimensionMismatch;
    }
    inline for (.{ pools.biomass.carbon_g_c, pools.biomass.nitrogen_g_n, pools.biomass.phosphorus_g_p, pools.som.soil_organic_carbon_g_c, pools.som.colonized_soil_organic_carbon_g_c, pools.som.soil_organic_nitrogen_g_n, pools.som.soil_organic_phosphorus_g_p }) |values|
        for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceLitterCompatibilityInput;
    inline for (std.meta.fields(soluble_module.Pools)) |field|
        for (@field(pools.soluble, field.name)) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceLitterCompatibilityInput;
}

fn removeBiomassK(k: usize, fraction: f64, destination_layer: usize, pools: biomass_module.Pools, totals: *Totals) !void {
    for (0..7) |n| for (0..3) |m| {
        const source = biomassIndex(pools.layer_count, k, n, m, 0);
        const destination = biomassIndex(pools.layer_count, k, n, m, destination_layer);
        const removed_c = fraction * pools.carbon_g_c[source];
        const removed_n = fraction * pools.nitrogen_g_n[source];
        const removed_p = fraction * pools.phosphorus_g_p[source];
        pools.carbon_g_c[destination] = pools.carbon_g_c[source] - removed_c;
        pools.nitrogen_g_n[destination] = pools.nitrogen_g_n[source] - removed_n;
        pools.phosphorus_g_p[destination] = pools.phosphorus_g_p[source] - removed_p;
        totals.remaining_carbon_g_c += pools.carbon_g_c[source];
        totals.remaining_nitrogen_g_n += pools.nitrogen_g_n[source];
        totals.remaining_phosphorus_g_p += pools.phosphorus_g_p[source];
        totals.removed_carbon_g_c += removed_c;
        totals.removed_nitrogen_g_n += removed_n;
        totals.removed_phosphorus_g_p += removed_p;
        try validateTotals(totals.*);
    };
}

fn removeSolubleK(k: usize, layers: usize, fraction: f64, p: soluble_module.Pools, t: *Totals) !void {
    for (0..2) |m| {
        const at = residueIndex(layers, k, m);
        const rc = fraction * p.residue_carbon_g_c[at];
        const rn = fraction * p.residue_nitrogen_g_n[at];
        const rp = fraction * p.residue_phosphorus_g_p[at];
        p.residue_carbon_g_c[at] -= rc;
        p.residue_nitrogen_g_n[at] -= rn;
        p.residue_phosphorus_g_p[at] -= rp;
        t.remaining_carbon_g_c += p.residue_carbon_g_c[at];
        t.remaining_nitrogen_g_n += p.residue_nitrogen_g_n[at];
        t.remaining_phosphorus_g_p += p.residue_phosphorus_g_p[at];
        t.removed_carbon_g_c += rc;
        t.removed_nitrogen_g_n += rn;
        t.removed_phosphorus_g_p += rp;
        try validateTotals(t.*);
    }
    const at = fractionIndex(layers, k);
    inline for (.{ .{ p.dissolved_carbon_g_c, p.dissolved_acetate_g_c, p.dissolved_nitrogen_g_n, p.dissolved_phosphorus_g_p }, .{ p.humic_dissolved_carbon_g_c, p.humic_dissolved_acetate_g_c, p.humic_dissolved_nitrogen_g_n, p.humic_dissolved_phosphorus_g_p } }) |group| {
        const rc = fraction * group[0][at];
        const ra = fraction * group[1][at];
        const rn = fraction * group[2][at];
        const rp = fraction * group[3][at];
        group[0][at] -= rc;
        group[1][at] -= ra;
        group[2][at] -= rn;
        group[3][at] -= rp;
        t.removed_carbon_g_c += rc + ra;
        t.removed_nitrogen_g_n += rn;
        t.removed_phosphorus_g_p += rp;
    }
    const ac = fraction * p.adsorbed_carbon_g_c[at];
    const aa = fraction * p.adsorbed_acetate_g_c[at];
    const an = fraction * p.adsorbed_nitrogen_g_n[at];
    const ap = fraction * p.adsorbed_phosphorus_g_p[at];
    p.adsorbed_carbon_g_c[at] -= ac;
    p.adsorbed_acetate_g_c[at] -= aa;
    p.adsorbed_nitrogen_g_n[at] -= an;
    p.adsorbed_phosphorus_g_p[at] -= ap;
    t.remaining_carbon_g_c += p.dissolved_carbon_g_c[at] + p.humic_dissolved_carbon_g_c[at] + p.adsorbed_carbon_g_c[at] + p.dissolved_acetate_g_c[at] + p.humic_dissolved_acetate_g_c[at] + p.adsorbed_acetate_g_c[at];
    t.remaining_nitrogen_g_n += p.dissolved_nitrogen_g_n[at] + p.humic_dissolved_nitrogen_g_n[at] + p.adsorbed_nitrogen_g_n[at];
    t.remaining_phosphorus_g_p += p.dissolved_phosphorus_g_p[at] + p.humic_dissolved_phosphorus_g_p[at] + p.adsorbed_phosphorus_g_p[at];
    t.removed_carbon_g_c += ac; // REDIST 11199 intentionally omits removed OHA (aa).
    t.removed_nitrogen_g_n += an;
    t.removed_phosphorus_g_p += ap;
    try validateTotals(t.*);
}

fn removeSomK(k: usize, fraction: f64, p: som_module.Pools, t: *Totals) !void {
    for (0..5) |m| {
        const at = somIndex(p.layer_count, k, m);
        const rc = fraction * p.soil_organic_carbon_g_c[at];
        const ra = fraction * p.colonized_soil_organic_carbon_g_c[at];
        const rn = fraction * p.soil_organic_nitrogen_g_n[at];
        const rp = fraction * p.soil_organic_phosphorus_g_p[at];
        p.soil_organic_carbon_g_c[at] -= rc;
        p.colonized_soil_organic_carbon_g_c[at] -= ra;
        p.soil_organic_nitrogen_g_n[at] -= rn;
        p.soil_organic_phosphorus_g_p[at] -= rp;
        if (m < 4) {
            t.remaining_carbon_g_c += p.soil_organic_carbon_g_c[at];
            t.remaining_nitrogen_g_n += p.soil_organic_nitrogen_g_n[at];
            t.remaining_phosphorus_g_p += p.soil_organic_phosphorus_g_p[at];
        } else {
            t.charcoal_remaining_carbon_g_c += p.soil_organic_carbon_g_c[at];
            t.charcoal_remaining_nitrogen_g_n += p.soil_organic_nitrogen_g_n[at];
            t.charcoal_remaining_phosphorus_g_p += p.soil_organic_phosphorus_g_p[at];
        }
        t.removed_carbon_g_c += rc;
        t.removed_nitrogen_g_n += rn;
        t.removed_phosphorus_g_p += rp;
        try validateTotals(t.*);
    }
}

/// Atomic compatibility translation of REDIST 11121--11227 in literal source order.
pub fn removeAtomic(allocator: std.mem.Allocator, removal_fraction: f64, destination_layer: usize, pools: Pools) !Totals {
    if (!std.math.isFinite(removal_fraction) or removal_fraction < 0 or removal_fraction > 0.999) return error.InvalidSurfaceLitterCompatibilityInput;
    try validatePools(pools, destination_layer);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const staged = Pools{ .biomass = try cloneBiomass(arena.allocator(), pools.biomass), .soluble = try cloneSoluble(arena.allocator(), pools.soluble), .som = try cloneSom(arena.allocator(), pools.som) };
    var totals: Totals = .{};
    for (0..3) |k|
        try removeBiomassK(k, removal_fraction, destination_layer, staged.biomass, &totals);
    for (0..3) |k| {
        try removeSolubleK(k, staged.biomass.layer_count, removal_fraction, staged.soluble, &totals);
        try removeSomK(k, removal_fraction, staged.som, &totals);
    }
    inline for (std.meta.fields(biomass_module.Pools)) |field| if (comptime !std.mem.eql(u8, field.name, "layer_count")) @memcpy(@field(pools.biomass, field.name), @field(staged.biomass, field.name));
    inline for (std.meta.fields(soluble_module.Pools)) |field| @memcpy(@field(pools.soluble, field.name), @field(staged.soluble, field.name));
    inline for (std.meta.fields(som_module.Pools)) |field| if (comptime !std.mem.eql(u8, field.name, "layer_count")) @memcpy(@field(pools.som, field.name), @field(staged.som, field.name));
    return totals;
}

test "REDIST compatibility coordinator removed carbon is bitwise literal source order" {
    var bc: [63]f64 = undefined;
    var bn: [63]f64 = @splat(1);
    var bp: [63]f64 = @splat(1);
    for (&bc, 0..) |*value, i| value.* = if (i % 21 == 0) 1.0e16 else @as(f64, @floatFromInt(i + 1));
    var rc: [6]f64 = @splat(3);
    var rn: [6]f64 = @splat(1);
    var rp: [6]f64 = @splat(1);
    var s: [12][3]f64 = @splat(@splat(2));
    var sc: [15]f64 = undefined;
    var sa: [15]f64 = @splat(1);
    var sn: [15]f64 = @splat(1);
    var sp: [15]f64 = @splat(1);
    for (&sc, 0..) |*value, i| value.* = @floatFromInt(i + 1);
    const pools = Pools{
        .biomass = .{ .layer_count = 1, .carbon_g_c = &bc, .nitrogen_g_n = &bn, .phosphorus_g_p = &bp },
        .soluble = .{ .residue_carbon_g_c = &rc, .residue_nitrogen_g_n = &rn, .residue_phosphorus_g_p = &rp, .dissolved_carbon_g_c = &s[0], .dissolved_acetate_g_c = &s[1], .dissolved_nitrogen_g_n = &s[2], .dissolved_phosphorus_g_p = &s[3], .humic_dissolved_carbon_g_c = &s[4], .humic_dissolved_acetate_g_c = &s[5], .humic_dissolved_nitrogen_g_n = &s[6], .humic_dissolved_phosphorus_g_p = &s[7], .adsorbed_carbon_g_c = &s[8], .adsorbed_acetate_g_c = &s[9], .adsorbed_nitrogen_g_n = &s[10], .adsorbed_phosphorus_g_p = &s[11] },
        .som = .{ .layer_count = 1, .soil_organic_carbon_g_c = &sc, .colonized_soil_organic_carbon_g_c = &sa, .soil_organic_nitrogen_g_n = &sn, .soil_organic_phosphorus_g_p = &sp },
    };
    var literal_removed_c: f64 = 0;
    for (0..3) |k|
        for (0..7) |n| for (0..3) |m| {
            literal_removed_c += 0.25 * bc[biomassIndex(1, k, n, m, 0)];
        };
    for (0..3) |k| {
        for (0..2) |m| literal_removed_c += 0.25 * rc[residueIndex(1, k, m)];
        const at = fractionIndex(1, k);
        literal_removed_c += 0.25 * s[0][at] + 0.25 * s[1][at];
        literal_removed_c += 0.25 * s[4][at] + 0.25 * s[5][at];
        literal_removed_c += 0.25 * s[8][at]; // OHA omission is literal.
        for (0..5) |m| literal_removed_c += 0.25 * sc[somIndex(1, k, m)];
    }
    const totals = try removeAtomic(std.testing.allocator, 0.25, 0, pools);
    try std.testing.expectEqual(@as(u64, @bitCast(literal_removed_c)), @as(u64, @bitCast(totals.removed_carbon_g_c)));
    try std.testing.expectEqual(@as(f64, 1.5), s[9][0]);
}

test "REDIST compatibility coordinator outer transaction is atomic" {
    var bc: [63]f64 = @splat(std.math.floatMax(f64));
    var bn: [63]f64 = @splat(1);
    var bp: [63]f64 = @splat(1);
    var rc: [6]f64 = @splat(1);
    var rn: [6]f64 = @splat(1);
    var rp: [6]f64 = @splat(1);
    var s: [12][3]f64 = @splat(@splat(1));
    var sc: [15]f64 = @splat(1);
    var sa: [15]f64 = @splat(1);
    var sn: [15]f64 = @splat(1);
    var sp: [15]f64 = @splat(1);
    const pools = Pools{ .biomass = .{ .layer_count = 1, .carbon_g_c = &bc, .nitrogen_g_n = &bn, .phosphorus_g_p = &bp }, .soluble = .{ .residue_carbon_g_c = &rc, .residue_nitrogen_g_n = &rn, .residue_phosphorus_g_p = &rp, .dissolved_carbon_g_c = &s[0], .dissolved_acetate_g_c = &s[1], .dissolved_nitrogen_g_n = &s[2], .dissolved_phosphorus_g_p = &s[3], .humic_dissolved_carbon_g_c = &s[4], .humic_dissolved_acetate_g_c = &s[5], .humic_dissolved_nitrogen_g_n = &s[6], .humic_dissolved_phosphorus_g_p = &s[7], .adsorbed_carbon_g_c = &s[8], .adsorbed_acetate_g_c = &s[9], .adsorbed_nitrogen_g_n = &s[10], .adsorbed_phosphorus_g_p = &s[11] }, .som = .{ .layer_count = 1, .soil_organic_carbon_g_c = &sc, .colonized_soil_organic_carbon_g_c = &sa, .soil_organic_nitrogen_g_n = &sn, .soil_organic_phosphorus_g_p = &sp } };
    try std.testing.expectError(error.NonFiniteSurfaceLitterCompatibilityResult, removeAtomic(std.testing.allocator, 0.25, 0, pools));
    try std.testing.expectEqual(std.math.floatMax(f64), bc[0]);
    try std.testing.expectEqual(@as(f64, 1), rc[0]);
    try std.testing.expectEqual(@as(f64, 1), sc[0]);
}
