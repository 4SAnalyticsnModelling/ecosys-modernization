// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 11625--11652 moves surface-litter biomass C, N, and P into the mixing
// totals. Production's litter layer is never debited on a tillage event.
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

const fraction_count = 6;
const group_count = 7;
const component_count = 3;
const pool_count = fraction_count * group_count * component_count;

pub const Pools = struct {
    layer_count: usize,
    carbon_g_c: []f64, // OMC, K,N,M,layer
    nitrogen_g_n: []f64, // OMN
    phosphorus_g_p: []f64, // OMP
};
pub const Workspace = struct {
    carbon_g_c: []f64, // TOMGC, K,N,M
    nitrogen_g_n: []f64, // TOMGN
    phosphorus_g_p: []f64, // TOMGP
};
pub const Result = struct {
    surface_remaining_fraction: f64, // XCORP0
    incorporated_fraction: f64, // CORP0
    remaining_carbon_g_c: f64, // DC
    remaining_nitrogen_g_n: f64, // DN
    remaining_phosphorus_g_p: f64, // DP
    charcoal_remaining_carbon_g_c: f64 = 0, // DCC
    charcoal_remaining_nitrogen_g_n: f64 = 0, // DNC
    charcoal_remaining_phosphorus_g_p: f64 = 0, // DPC
};

fn index(layer_count: usize, k: usize, n: usize, m: usize, layer: usize) usize {
    return (((k * group_count + n) * component_count + m) * layer_count) + layer;
}
fn workspaceIndex(k: usize, n: usize, m: usize) usize {
    return (k * group_count + n) * component_count + m;
}
fn finiteNonnegative(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value) or value < 0) return false;
    return true;
}

/// Direct translation of REDIST 11625--11652 at surface layer 0.
pub fn transfer(surface_heat_capacity_megajoules_k: f64, residue_heat_capacity_threshold_megajoules_k: f64, soil_mixing_remaining_fraction: f64, pools: Pools, workspace: Workspace) !Result {
    const expected = pool_count * pools.layer_count;
    if (pools.layer_count == 0 or pools.carbon_g_c.len != expected or pools.nitrogen_g_n.len != expected or pools.phosphorus_g_p.len != expected or
        workspace.carbon_g_c.len != pool_count or workspace.nitrogen_g_n.len != pool_count or workspace.phosphorus_g_p.len != pool_count)
        return error.TillageSurfaceBiomassDimensionMismatch;
    inline for (.{ surface_heat_capacity_megajoules_k, residue_heat_capacity_threshold_megajoules_k, soil_mixing_remaining_fraction }) |value|
        if (!std.math.isFinite(value)) return error.InvalidTillageSurfaceBiomassInput;
    if (surface_heat_capacity_megajoules_k < 0 or residue_heat_capacity_threshold_megajoules_k < 0 or soil_mixing_remaining_fraction < 0 or soil_mixing_remaining_fraction > 1 or
        !finiteNonnegative(pools.carbon_g_c) or !finiteNonnegative(pools.nitrogen_g_n) or !finiteNonnegative(pools.phosphorus_g_p) or
        !finiteNonnegative(workspace.carbon_g_c) or !finiteNonnegative(workspace.nitrogen_g_n) or !finiteNonnegative(workspace.phosphorus_g_p))
        return error.InvalidTillageSurfaceBiomassInput;

    const remaining_fraction = if (surface_heat_capacity_megajoules_k > residue_heat_capacity_threshold_megajoules_k) @max(0.001, soil_mixing_remaining_fraction) else 1.0;
    const incorporated_fraction = 1.0 - remaining_fraction;
    var staged_carbon: [pool_count]f64 = undefined;
    var staged_nitrogen: [pool_count]f64 = undefined;
    var staged_phosphorus: [pool_count]f64 = undefined;
    var staged_workspace_carbon: [pool_count]f64 = undefined;
    var staged_workspace_nitrogen: [pool_count]f64 = undefined;
    var staged_workspace_phosphorus: [pool_count]f64 = undefined;
    @memcpy(&staged_workspace_carbon, workspace.carbon_g_c);
    @memcpy(&staged_workspace_nitrogen, workspace.nitrogen_g_n);
    @memcpy(&staged_workspace_phosphorus, workspace.phosphorus_g_p);
    var result = Result{ .surface_remaining_fraction = remaining_fraction, .incorporated_fraction = incorporated_fraction, .remaining_carbon_g_c = 0, .remaining_nitrogen_g_n = 0, .remaining_phosphorus_g_p = 0 };
    for (0..fraction_count) |k| {
        if (k == 4) continue;
        for (0..group_count) |n| for (0..component_count) |m| {
            const source = index(pools.layer_count, k, n, m, 0);
            const at = workspaceIndex(k, n, m);
            staged_workspace_carbon[at] = pools.carbon_g_c[source] * incorporated_fraction;
            staged_workspace_nitrogen[at] = pools.nitrogen_g_n[source] * incorporated_fraction;
            staged_workspace_phosphorus[at] = pools.phosphorus_g_p[source] * incorporated_fraction;
            staged_carbon[at] = pools.carbon_g_c[source] * remaining_fraction;
            staged_nitrogen[at] = pools.nitrogen_g_n[source] * remaining_fraction;
            staged_phosphorus[at] = pools.phosphorus_g_p[source] * remaining_fraction;
            result.remaining_carbon_g_c += staged_carbon[at];
            result.remaining_nitrogen_g_n += staged_nitrogen[at];
            result.remaining_phosphorus_g_p += staged_phosphorus[at];
            inline for (.{ staged_workspace_carbon[at], staged_workspace_nitrogen[at], staged_workspace_phosphorus[at], result.remaining_carbon_g_c, result.remaining_nitrogen_g_n, result.remaining_phosphorus_g_p }) |value|
                if (!std.math.isFinite(value)) return error.NonFiniteTillageSurfaceBiomassResult;
        };
    }
    for (0..fraction_count) |k| {
        if (k == 4) continue;
        for (0..group_count) |n| for (0..component_count) |m| {
            const source = index(pools.layer_count, k, n, m, 0);
            const at = workspaceIndex(k, n, m);
            pools.carbon_g_c[source] = staged_carbon[at];
            pools.nitrogen_g_n[source] = staged_nitrogen[at];
            pools.phosphorus_g_p[source] = staged_phosphorus[at];
        };
    }
    @memcpy(workspace.carbon_g_c, &staged_workspace_carbon);
    @memcpy(workspace.nitrogen_g_n, &staged_workspace_nitrogen);
    @memcpy(workspace.phosphorus_g_p, &staged_workspace_phosphorus);
    return result;
}

test "REDIST tillage surface biomass preserves gate nesting K exclusion and C N P" {
    var carbon: [pool_count]f64 = @splat(4);
    var nitrogen: [pool_count]f64 = @splat(2);
    var phosphorus: [pool_count]f64 = @splat(1);
    var work_c: [pool_count]f64 = @splat(0);
    var work_n: [pool_count]f64 = @splat(0);
    var work_p: [pool_count]f64 = @splat(0);
    const result = try transfer(2, 1, 0.25, .{ .layer_count = 1, .carbon_g_c = &carbon, .nitrogen_g_n = &nitrogen, .phosphorus_g_p = &phosphorus }, .{ .carbon_g_c = &work_c, .nitrogen_g_n = &work_n, .phosphorus_g_p = &work_p });
    try std.testing.expectEqual(@as(f64, 0.25), result.surface_remaining_fraction);
    try std.testing.expectEqual(@as(f64, 3), work_c[0]);
    try std.testing.expectEqual(@as(f64, 1), carbon[0]);
    const excluded = workspaceIndex(4, 0, 0);
    try std.testing.expectEqual(@as(f64, 0), work_c[excluded]);
    try std.testing.expectEqual(@as(f64, 4), carbon[excluded]);
    try std.testing.expectApproxEqAbs(@as(f64, 5 * 7 * 3), result.remaining_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5 * 5 * 7 * 3), result.remaining_nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25 * 5 * 7 * 3), result.remaining_phosphorus_g_p, 1e-12);
}

test "REDIST tillage surface biomass late overflow is atomic" {
    var carbon: [pool_count]f64 = @splat(std.math.floatMax(f64));
    var nitrogen: [pool_count]f64 = @splat(1);
    var phosphorus: [pool_count]f64 = @splat(1);
    var work_c: [pool_count]f64 = @splat(0);
    var work_n: [pool_count]f64 = @splat(0);
    var work_p: [pool_count]f64 = @splat(0);
    try std.testing.expectError(error.NonFiniteTillageSurfaceBiomassResult, transfer(2, 1, 1, .{ .layer_count = 1, .carbon_g_c = &carbon, .nitrogen_g_n = &nitrogen, .phosphorus_g_p = &phosphorus }, .{ .carbon_g_c = &work_c, .nitrogen_g_n = &work_n, .phosphorus_g_p = &work_p }));
    try std.testing.expectEqual(std.math.floatMax(f64), carbon[0]);
    try std.testing.expectEqual(@as(f64, 0), work_c[0]);
}
