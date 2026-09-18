// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 11653--11716 moves the layer-0 organic pools in literal K-major
// order. No production caller debits them.
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
// surface incorporation group of
// docs/traceability/redistribution_tillage_unbound_family_disposition.md
//
const std = @import("std");
const soluble_module = @import("../surface/litter_soluble_removal.zig");
const som_module = @import("../surface/litter_som_removal.zig");

pub const Totals = struct {
    remaining_carbon_g_c: f64, // DC
    remaining_nitrogen_g_n: f64, // DN
    remaining_phosphorus_g_p: f64, // DP
    charcoal_remaining_carbon_g_c: f64, // DCC
    charcoal_remaining_nitrogen_g_n: f64, // DNC
    charcoal_remaining_phosphorus_g_p: f64, // DPC
};
pub const Pools = struct {
    layer_count: usize,
    surface_residue_carbon_g_c: []f64, // RC0, K=0..2
    soluble: soluble_module.Pools,
    som: som_module.Pools,
};
pub const Workspace = struct {
    residue_carbon_g_c: []f64, // TORXC, 3*2
    residue_nitrogen_g_n: []f64, // TORXN
    residue_phosphorus_g_p: []f64, // TORXP
    /// TOQGC/GN/GP/GA, TOQHC/HN/HP/HA, TOHGC/GN/GP/GA.
    soluble_by_pool_and_fraction: []f64, // 12*3
    /// TOSGC/GA/GN/GP, each M=1..5,K=0..2.
    som_by_pool_m_and_fraction: []f64, // 4*5*3
};

fn residueIndex(layers: usize, k: usize, m: usize) usize {
    return (k * 2 + m) * layers;
}
fn fractionIndex(layers: usize, k: usize) usize {
    return k * layers;
}
fn somIndex(layers: usize, k: usize, m: usize) usize {
    return (k * 5 + m) * layers;
}
fn finiteNonnegative(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value) or value < 0) return false;
    return true;
}
fn validateTotals(t: Totals) !void {
    inline for (std.meta.fields(Totals)) |field|
        if (!std.math.isFinite(@field(t, field.name))) return error.NonFiniteTillageSurfaceOrganicTransferResult;
}

/// Direct translation of REDIST 11653--11716 in literal K-major order.
pub fn transfer(surface_remaining_fraction: f64, pools: Pools, workspace: Workspace, initial: Totals) !Totals {
    const layers = pools.layer_count;
    if (layers == 0 or pools.som.layer_count != layers or pools.surface_residue_carbon_g_c.len != 3 or
        workspace.residue_carbon_g_c.len != 6 or workspace.residue_nitrogen_g_n.len != 6 or workspace.residue_phosphorus_g_p.len != 6 or
        workspace.soluble_by_pool_and_fraction.len != 36 or workspace.som_by_pool_m_and_fraction.len != 60)
        return error.TillageSurfaceOrganicTransferDimensionMismatch;
    inline for (std.meta.fields(soluble_module.Pools)) |field| {
        const values = @field(pools.soluble, field.name);
        const expected = if (std.mem.startsWith(u8, field.name, "residue_")) 6 * layers else 3 * layers;
        if (values.len != expected) return error.TillageSurfaceOrganicTransferDimensionMismatch;
        if (!finiteNonnegative(values)) return error.InvalidTillageSurfaceOrganicTransferInput;
    }
    inline for (std.meta.fields(som_module.Pools)) |field| {
        if (comptime std.mem.eql(u8, field.name, "layer_count")) continue;
        const values = @field(pools.som, field.name);
        if (values.len != 15 * layers) return error.TillageSurfaceOrganicTransferDimensionMismatch;
        if (!finiteNonnegative(values)) return error.InvalidTillageSurfaceOrganicTransferInput;
    }
    inline for (.{ pools.surface_residue_carbon_g_c, workspace.residue_carbon_g_c, workspace.residue_nitrogen_g_n, workspace.residue_phosphorus_g_p, workspace.soluble_by_pool_and_fraction, workspace.som_by_pool_m_and_fraction }) |values|
        if (!finiteNonnegative(values)) return error.InvalidTillageSurfaceOrganicTransferInput;
    if (!std.math.isFinite(surface_remaining_fraction) or surface_remaining_fraction < 0 or surface_remaining_fraction > 1) return error.InvalidTillageSurfaceOrganicTransferInput;
    try validateTotals(initial);
    const incorporated_fraction = 1.0 - surface_remaining_fraction;

    var residue_c: [6]f64 = undefined;
    var residue_n: [6]f64 = undefined;
    var residue_p: [6]f64 = undefined;
    var soluble_values: [12][3]f64 = undefined;
    var som_values: [4][15]f64 = undefined;
    var residue_surface: [3]f64 = undefined;
    var residue_work_c: [6]f64 = undefined;
    var residue_work_n: [6]f64 = undefined;
    var residue_work_p: [6]f64 = undefined;
    var soluble_work: [36]f64 = undefined;
    var som_work: [60]f64 = undefined;
    var totals = initial;
    const soluble_arrays = .{ pools.soluble.dissolved_carbon_g_c, pools.soluble.dissolved_nitrogen_g_n, pools.soluble.dissolved_phosphorus_g_p, pools.soluble.dissolved_acetate_g_c, pools.soluble.humic_dissolved_carbon_g_c, pools.soluble.humic_dissolved_nitrogen_g_n, pools.soluble.humic_dissolved_phosphorus_g_p, pools.soluble.humic_dissolved_acetate_g_c, pools.soluble.adsorbed_carbon_g_c, pools.soluble.adsorbed_nitrogen_g_n, pools.soluble.adsorbed_phosphorus_g_p, pools.soluble.adsorbed_acetate_g_c };
    const som_arrays = .{ pools.som.soil_organic_carbon_g_c, pools.som.colonized_soil_organic_carbon_g_c, pools.som.soil_organic_nitrogen_g_n, pools.som.soil_organic_phosphorus_g_p };
    for (0..3) |k| {
        for (0..2) |m| {
            const source = residueIndex(layers, k, m);
            const at = k * 2 + m;
            residue_work_c[at] = pools.soluble.residue_carbon_g_c[source] * incorporated_fraction;
            residue_work_n[at] = pools.soluble.residue_nitrogen_g_n[source] * incorporated_fraction;
            residue_work_p[at] = pools.soluble.residue_phosphorus_g_p[source] * incorporated_fraction;
            residue_c[at] = pools.soluble.residue_carbon_g_c[source] * surface_remaining_fraction;
            residue_n[at] = pools.soluble.residue_nitrogen_g_n[source] * surface_remaining_fraction;
            residue_p[at] = pools.soluble.residue_phosphorus_g_p[source] * surface_remaining_fraction;
            totals.remaining_carbon_g_c += residue_c[at];
            totals.remaining_nitrogen_g_n += residue_n[at];
            totals.remaining_phosphorus_g_p += residue_p[at];
            try validateTotals(totals);
        }
        const source = fractionIndex(layers, k);
        inline for (soluble_arrays, 0..) |values, pool| {
            soluble_work[pool * 3 + k] = values[source] * incorporated_fraction;
            soluble_values[pool][k] = values[source] * surface_remaining_fraction;
        }
        residue_surface[k] = pools.surface_residue_carbon_g_c[k] * surface_remaining_fraction;
        totals.remaining_carbon_g_c += soluble_values[0][k] + soluble_values[4][k] + soluble_values[8][k] + soluble_values[3][k] + soluble_values[7][k] + soluble_values[11][k];
        totals.remaining_nitrogen_g_n += soluble_values[1][k] + soluble_values[5][k] + soluble_values[9][k];
        totals.remaining_phosphorus_g_p += soluble_values[2][k] + soluble_values[6][k] + soluble_values[10][k];
        for (0..5) |m| {
            const som_source = somIndex(layers, k, m);
            const at = k * 5 + m;
            inline for (som_arrays, 0..) |values, pool| {
                som_work[pool * 15 + at] = values[som_source] * incorporated_fraction;
                som_values[pool][at] = values[som_source] * surface_remaining_fraction;
            }
            if (m < 4) {
                totals.remaining_carbon_g_c += som_values[0][at];
                totals.remaining_nitrogen_g_n += som_values[2][at];
                totals.remaining_phosphorus_g_p += som_values[3][at];
            } else {
                totals.charcoal_remaining_carbon_g_c += som_values[0][at];
                totals.charcoal_remaining_nitrogen_g_n += som_values[2][at];
                totals.charcoal_remaining_phosphorus_g_p += som_values[3][at];
            }
            try validateTotals(totals);
        }
    }
    for (0..3) |k| {
        pools.surface_residue_carbon_g_c[k] = residue_surface[k];
        for (0..2) |m| {
            const source = residueIndex(layers, k, m);
            const at = k * 2 + m;
            pools.soluble.residue_carbon_g_c[source] = residue_c[at];
            pools.soluble.residue_nitrogen_g_n[source] = residue_n[at];
            pools.soluble.residue_phosphorus_g_p[source] = residue_p[at];
        }
        const source = fractionIndex(layers, k);
        inline for (soluble_arrays, 0..) |values, pool| values[source] = soluble_values[pool][k];
        for (0..5) |m| {
            const source_som = somIndex(layers, k, m);
            const at = k * 5 + m;
            inline for (som_arrays, 0..) |values, pool| values[source_som] = som_values[pool][at];
        }
    }
    @memcpy(workspace.residue_carbon_g_c, &residue_work_c);
    @memcpy(workspace.residue_nitrogen_g_n, &residue_work_n);
    @memcpy(workspace.residue_phosphorus_g_p, &residue_work_p);
    @memcpy(workspace.soluble_by_pool_and_fraction, &soluble_work);
    @memcpy(workspace.som_by_pool_m_and_fraction, &som_work);
    return totals;
}

test "REDIST tillage organic transfer preserves K-major cross-domain order and mass" {
    var residue_c: [6]f64 = @splat(4);
    var residue_n: [6]f64 = @splat(2);
    var residue_p: [6]f64 = @splat(1);
    var s: [12][3]f64 = @splat(@splat(1));
    var som_c: [15]f64 = @splat(4);
    var som_a: [15]f64 = @splat(2);
    var som_n: [15]f64 = @splat(2);
    var som_p: [15]f64 = @splat(1);
    var rc0: [3]f64 = @splat(8);
    var wr_c: [6]f64 = @splat(0);
    var wr_n: [6]f64 = @splat(0);
    var wr_p: [6]f64 = @splat(0);
    var ws: [36]f64 = @splat(0);
    var wsom: [60]f64 = @splat(0);
    const soluble = soluble_module.Pools{ .residue_carbon_g_c = &residue_c, .residue_nitrogen_g_n = &residue_n, .residue_phosphorus_g_p = &residue_p, .dissolved_carbon_g_c = &s[0], .dissolved_nitrogen_g_n = &s[1], .dissolved_phosphorus_g_p = &s[2], .dissolved_acetate_g_c = &s[3], .humic_dissolved_carbon_g_c = &s[4], .humic_dissolved_nitrogen_g_n = &s[5], .humic_dissolved_phosphorus_g_p = &s[6], .humic_dissolved_acetate_g_c = &s[7], .adsorbed_carbon_g_c = &s[8], .adsorbed_nitrogen_g_n = &s[9], .adsorbed_phosphorus_g_p = &s[10], .adsorbed_acetate_g_c = &s[11] };
    const result = try transfer(0.25, .{ .layer_count = 1, .surface_residue_carbon_g_c = &rc0, .soluble = soluble, .som = .{ .layer_count = 1, .soil_organic_carbon_g_c = &som_c, .colonized_soil_organic_carbon_g_c = &som_a, .soil_organic_nitrogen_g_n = &som_n, .soil_organic_phosphorus_g_p = &som_p } }, .{ .residue_carbon_g_c = &wr_c, .residue_nitrogen_g_n = &wr_n, .residue_phosphorus_g_p = &wr_p, .soluble_by_pool_and_fraction = &ws, .som_by_pool_m_and_fraction = &wsom }, std.mem.zeroes(Totals));
    try std.testing.expectEqual(@as(f64, 1), residue_c[0]);
    try std.testing.expectEqual(@as(f64, 3), wr_c[0]);
    try std.testing.expectEqual(@as(f64, 0.25), s[11][2]);
    try std.testing.expectEqual(@as(f64, 0.75), ws[11 * 3 + 2]);
    try std.testing.expectApproxEqAbs(@as(f64, 6 + 4.5 + 15), result.remaining_carbon_g_c + result.charcoal_remaining_carbon_g_c, 1e-12);
}

test "REDIST tillage organic transfer late overflow is atomic" {
    var residue_c: [6]f64 = @splat(std.math.floatMax(f64));
    var residue_n: [6]f64 = @splat(1);
    var residue_p: [6]f64 = @splat(1);
    var s: [12][3]f64 = @splat(@splat(1));
    var som_c: [15]f64 = @splat(1);
    var som_a: [15]f64 = @splat(1);
    var som_n: [15]f64 = @splat(1);
    var som_p: [15]f64 = @splat(1);
    var rc0: [3]f64 = @splat(1);
    var wr: [6]f64 = @splat(0);
    var ws: [36]f64 = @splat(0);
    var wsom: [60]f64 = @splat(0);
    const soluble = soluble_module.Pools{ .residue_carbon_g_c = &residue_c, .residue_nitrogen_g_n = &residue_n, .residue_phosphorus_g_p = &residue_p, .dissolved_carbon_g_c = &s[0], .dissolved_nitrogen_g_n = &s[1], .dissolved_phosphorus_g_p = &s[2], .dissolved_acetate_g_c = &s[3], .humic_dissolved_carbon_g_c = &s[4], .humic_dissolved_nitrogen_g_n = &s[5], .humic_dissolved_phosphorus_g_p = &s[6], .humic_dissolved_acetate_g_c = &s[7], .adsorbed_carbon_g_c = &s[8], .adsorbed_nitrogen_g_n = &s[9], .adsorbed_phosphorus_g_p = &s[10], .adsorbed_acetate_g_c = &s[11] };
    try std.testing.expectError(error.NonFiniteTillageSurfaceOrganicTransferResult, transfer(1, .{ .layer_count = 1, .surface_residue_carbon_g_c = &rc0, .soluble = soluble, .som = .{ .layer_count = 1, .soil_organic_carbon_g_c = &som_c, .colonized_soil_organic_carbon_g_c = &som_a, .soil_organic_nitrogen_g_n = &som_n, .soil_organic_phosphorus_g_p = &som_p } }, .{ .residue_carbon_g_c = &wr, .residue_nitrogen_g_n = &wr, .residue_phosphorus_g_p = &wr, .soluble_by_pool_and_fraction = &ws, .som_by_pool_m_and_fraction = &wsom }, std.mem.zeroes(Totals)));
    try std.testing.expectEqual(std.math.floatMax(f64), residue_c[0]);
    try std.testing.expectEqual(@as(f64, 0), wr[0]);
    try std.testing.expectEqual(@as(f64, 1), s[0][0]);
}
