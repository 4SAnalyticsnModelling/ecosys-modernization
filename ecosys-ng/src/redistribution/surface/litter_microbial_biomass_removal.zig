// **A8a DISPOSITION: SUPERSEDED BY THE BOUND OPERATION-21 RUNTIME OWNER.**
// `surface/litter_removal.applyRuntimeCell` owns the complete microbial K/N/M
// sweep on authoritative runtime pools and is reached by the production
// disturbance dispatcher for operation 21.
//
// **HISTORICAL A8a DISPOSITION: GAP, keep unbound and do not banner as settled.**
//
// `redist.f` 11019 and 11107--11140, verified. This is REDIST disturbance
// operation 21, which production parses and then silently drops:
// `management/disturbance_schedule.zig` decodes and clamps code 21 (`:18`,
// `:28`, `:76`) but `disturbance_management_dispatch.applyEvent` ends its switch
// with `else => return`, at both `ecosys_ng.zig:3855` and `:4124`. That is
// DIST-021, so nothing here is superseded; the operation has no production
// effect at all.
//
// This module names `OMC`/`OMN`/`OMP` with the literal `K,N,M` layout and
// reproduces the gate `IF(NFZ.EQ.1.AND.J.EQ.INT(ZNOON))`. It also surfaces
// rather than launders the legacy hazard at 11130--11132: Fortran writes the
// reduced biomass to `OMC(M,N,K,L,...)` while reading layer 0, and `L` is never
// set inside operation 21, so on entry it still holds `NL+1` from `DO 2850
// L=0,NL` at 10707. `destination_layer` is that `L`, and choosing 0 is a
// deliberate divergence from legacy rather than a translation.
//
// Family analysis, the acetate and `TNBP` omissions in the designated applier,
// and what closing DIST-021 requires: docs/traceability/
// redistribution_surface_litter_removal_group_is_a_second_translation_of_a_gap.md

const std = @import("std");

const carbon_fraction_count = 3; // K=0..2
const microbial_group_count = 7; // N=1..7
const microbial_component_count = 3; // M=1..3
const pool_count = carbon_fraction_count * microbial_group_count * microbial_component_count;

pub const Schedule = struct {
    event_count: usize,
    cell_count: usize,
    disturbance_type: []const i32, // ITILL, event-major then cell
    removal_fraction: []const f64, // DCORP, event-major then cell
    solar_noon_h: []const f64, // ZNOON, cell-major
};
pub const Pools = struct {
    layer_count: usize,
    /// K,N,M,layer layout; amounts are g C, g N, and g P per cell.
    carbon_g_c: []f64, // OMC
    nitrogen_g_n: []f64, // OMN
    phosphorus_g_p: []f64, // OMP
};
pub const RemovalTotals = struct {
    remaining_carbon_g_c: f64 = 0, // DC
    remaining_nitrogen_g_n: f64 = 0, // DN
    remaining_phosphorus_g_p: f64 = 0, // DP
    removed_carbon_g_c: f64 = 0, // OC
    removed_nitrogen_g_n: f64 = 0, // ON
    removed_phosphorus_g_p: f64 = 0, // OP
    charcoal_remaining_carbon_g_c: f64 = 0, // DCC
    charcoal_remaining_nitrogen_g_n: f64 = 0, // DNC
    charcoal_remaining_phosphorus_g_p: f64 = 0, // DPC
    colonized_removed_carbon_g_c: f64 = 0, // OCC
    colonized_removed_nitrogen_g_n: f64 = 0, // ONC
    colonized_removed_phosphorus_g_p: f64 = 0, // OPC
};

fn poolIndex(layer_count: usize, k: usize, n: usize, m: usize, layer: usize) usize {
    return (((k * microbial_group_count + n) * microbial_component_count + m) * layer_count) + layer;
}
fn finiteSlice(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 11019 and 11107--11140 for one event and cell.
/// `destination_layer` represents the retained Fortran L used at 11130--11132.
pub fn applyCell(first_daily_cycle: i32, hour: i32, event: usize, cell: usize, destination_layer: usize, schedule: Schedule, pools: Pools) !?RemovalTotals {
    if (schedule.event_count == 0 or schedule.cell_count == 0 or event >= schedule.event_count or cell >= schedule.cell_count or
        schedule.disturbance_type.len != schedule.event_count * schedule.cell_count or
        schedule.removal_fraction.len != schedule.event_count * schedule.cell_count or
        schedule.solar_noon_h.len != schedule.cell_count or pools.layer_count == 0 or destination_layer >= pools.layer_count)
        return error.SurfaceLitterBiomassDimensionMismatch;
    const expected_pool_len = pool_count * pools.layer_count;
    if (pools.carbon_g_c.len != expected_pool_len or pools.nitrogen_g_n.len != expected_pool_len or pools.phosphorus_g_p.len != expected_pool_len)
        return error.SurfaceLitterBiomassDimensionMismatch;
    if (!finiteSlice(schedule.removal_fraction) or !finiteSlice(schedule.solar_noon_h) or
        !finiteSlice(pools.carbon_g_c) or !finiteSlice(pools.nitrogen_g_n) or !finiteSlice(pools.phosphorus_g_p))
        return error.InvalidSurfaceLitterBiomassInput;
    inline for (.{ pools.carbon_g_c, pools.nitrogen_g_n, pools.phosphorus_g_p }) |values|
        for (values) |value| if (value < 0) return error.InvalidSurfaceLitterBiomassInput;
    const at = event * schedule.cell_count + cell;
    if (schedule.removal_fraction[at] < 0 or schedule.solar_noon_h[cell] < 0 or schedule.solar_noon_h[cell] > 24)
        return error.InvalidSurfaceLitterBiomassInput;
    const solar_noon_integer: i32 = @intFromFloat(schedule.solar_noon_h[cell]);
    if (first_daily_cycle != 1 or hour != solar_noon_integer or schedule.disturbance_type[at] != 21) return null;

    const removal_fraction = @min(0.999, schedule.removal_fraction[at]); // DCORPC
    var next_carbon: [pool_count]f64 = undefined;
    var next_nitrogen: [pool_count]f64 = undefined;
    var next_phosphorus: [pool_count]f64 = undefined;
    var totals: RemovalTotals = .{}; // REDIST 11109--11120
    var sequential_index: usize = 0;
    for (0..carbon_fraction_count) |k| for (0..microbial_group_count) |n| for (0..microbial_component_count) |m| {
        const source = poolIndex(pools.layer_count, k, n, m, 0);
        const carbon_removed = removal_fraction * pools.carbon_g_c[source];
        const nitrogen_removed = removal_fraction * pools.nitrogen_g_n[source];
        const phosphorus_removed = removal_fraction * pools.phosphorus_g_p[source];
        next_carbon[sequential_index] = pools.carbon_g_c[source] - carbon_removed;
        next_nitrogen[sequential_index] = pools.nitrogen_g_n[source] - nitrogen_removed;
        next_phosphorus[sequential_index] = pools.phosphorus_g_p[source] - phosphorus_removed;
        totals.remaining_carbon_g_c += if (destination_layer == 0) next_carbon[sequential_index] else pools.carbon_g_c[source];
        totals.remaining_nitrogen_g_n += if (destination_layer == 0) next_nitrogen[sequential_index] else pools.nitrogen_g_n[source];
        totals.remaining_phosphorus_g_p += if (destination_layer == 0) next_phosphorus[sequential_index] else pools.phosphorus_g_p[source];
        totals.removed_carbon_g_c += carbon_removed;
        totals.removed_nitrogen_g_n += nitrogen_removed;
        totals.removed_phosphorus_g_p += phosphorus_removed;
        inline for (.{ next_carbon[sequential_index], next_nitrogen[sequential_index], next_phosphorus[sequential_index], totals.remaining_carbon_g_c, totals.remaining_nitrogen_g_n, totals.remaining_phosphorus_g_p, totals.removed_carbon_g_c, totals.removed_nitrogen_g_n, totals.removed_phosphorus_g_p }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteSurfaceLitterBiomassResult;
        sequential_index += 1;
    };
    sequential_index = 0;
    for (0..carbon_fraction_count) |k| for (0..microbial_group_count) |n| for (0..microbial_component_count) |m| {
        const destination = poolIndex(pools.layer_count, k, n, m, destination_layer);
        pools.carbon_g_c[destination] = next_carbon[sequential_index];
        pools.nitrogen_g_n[destination] = next_nitrogen[sequential_index];
        pools.phosphorus_g_p[destination] = next_phosphorus[sequential_index];
        sequential_index += 1;
    };
    return totals;
}

test "REDIST surface litter microbial biomass removes exact fraction and conserves C N P" {
    const disturbance = [_]i32{21};
    const fraction = [_]f64{0.25};
    const noon = [_]f64{12.9};
    var carbon: [pool_count]f64 = @splat(4);
    var nitrogen: [pool_count]f64 = @splat(2);
    var phosphorus: [pool_count]f64 = @splat(1);
    const result = (try applyCell(1, 12, 0, 0, 0, .{ .event_count = 1, .cell_count = 1, .disturbance_type = &disturbance, .removal_fraction = &fraction, .solar_noon_h = &noon }, .{ .layer_count = 1, .carbon_g_c = &carbon, .nitrogen_g_n = &nitrogen, .phosphorus_g_p = &phosphorus })).?;
    try std.testing.expectEqual(@as(f64, 3), carbon[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 4 * pool_count), result.remaining_carbon_g_c + result.removed_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2 * pool_count), result.remaining_nitrogen_g_n + result.removed_nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1 * pool_count), result.remaining_phosphorus_g_p + result.removed_phosphorus_g_p, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), result.colonized_removed_carbon_g_c);
}

test "REDIST retained L destination is explicit and failed overflow is atomic" {
    const disturbance = [_]i32{21};
    const fraction = [_]f64{0.999};
    const noon = [_]f64{12};
    var carbon: [pool_count * 2]f64 = @splat(1);
    var nitrogen: [pool_count * 2]f64 = @splat(1);
    var phosphorus: [pool_count * 2]f64 = @splat(1);
    carbon[poolIndex(2, 2, 6, 2, 0)] = std.math.floatMax(f64);
    carbon[poolIndex(2, 2, 6, 1, 0)] = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteSurfaceLitterBiomassResult, applyCell(1, 12, 0, 0, 1, .{ .event_count = 1, .cell_count = 1, .disturbance_type = &disturbance, .removal_fraction = &fraction, .solar_noon_h = &noon }, .{ .layer_count = 2, .carbon_g_c = &carbon, .nitrogen_g_n = &nitrogen, .phosphorus_g_p = &phosphorus }));
    try std.testing.expectEqual(@as(f64, 1), carbon[poolIndex(2, 0, 0, 0, 1)]);
    try std.testing.expectEqual(@as(f64, 1), nitrogen[poolIndex(2, 0, 0, 0, 1)]);
}
