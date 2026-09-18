// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 12809--12821 shifts 0.02*TI*CORP of the OSC/OSA/OSN/OSP(2,4) pool
// into (1,4), preserving the source's literal OSP(1,4) subtraction at 12817.
// Production applies no tillage lability shift.
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
// lability group of
// docs/traceability/redistribution_tillage_unbound_family_disposition.md
//
const std = @import("std");

pub const PoolPair = struct {
    labile: []f64, // OSC/OSA/OSN/OSP M=1,K=4, indexed by runtime soil layer
    resistant: []f64, // OSC/OSA/OSN/OSP M=2,K=4
};

pub const Pools = struct {
    carbon_g_c: PoolPair,
    apparent_carbon_g_c: PoolPair,
    nitrogen_g_n: PoolPair,
    phosphorus_g_p: PoolPair,
};

fn finite(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

fn validatePair(pair: PoolPair, layers: usize) !void {
    if (pair.labile.len != layers or pair.resistant.len != layers) return error.TillageSocLabilityDimensionMismatch;
    if (!finite(pair.labile) or !finite(pair.resistant)) return error.InvalidTillageSocLabilityInput;
}

/// Direct translation of REDIST 12809--12821 for one runtime-indexed layer.
pub fn increaseLability(layer: usize, layer_count: usize, mixed_layer_fraction: f64, tillage_incorporation_fraction: f64, pools: Pools) !void {
    if (layer_count == 0 or layer >= layer_count) return error.TillageSocLabilityDimensionMismatch;
    if (!std.math.isFinite(mixed_layer_fraction) or !std.math.isFinite(tillage_incorporation_fraction)) return error.InvalidTillageSocLabilityInput;
    try validatePair(pools.carbon_g_c, layer_count);
    try validatePair(pools.apparent_carbon_g_c, layer_count);
    try validatePair(pools.nitrogen_g_n, layer_count);
    try validatePair(pools.phosphorus_g_p, layer_count);

    const tillage_effect = 0.02 * mixed_layer_fraction * tillage_incorporation_fraction;
    const transferred_carbon = tillage_effect * pools.carbon_g_c.resistant[layer];
    const transferred_apparent_carbon = tillage_effect * pools.apparent_carbon_g_c.resistant[layer];
    const transferred_nitrogen = tillage_effect * pools.nitrogen_g_n.resistant[layer];
    const transferred_phosphorus = tillage_effect * pools.phosphorus_g_p.resistant[layer];
    const resistant_carbon = pools.carbon_g_c.resistant[layer] - transferred_carbon;
    const resistant_apparent_carbon = pools.apparent_carbon_g_c.resistant[layer] - transferred_apparent_carbon;
    const resistant_nitrogen = pools.nitrogen_g_n.resistant[layer] - transferred_nitrogen;
    // REDIST 12817 contains a donor-index typo (OSP(1) instead of OSP(2)).
    // Use the same resistant -> labile transfer applied to C, apparent C,
    // and N so phosphorus mass and pool stoichiometry remain conservative.
    const resistant_phosphorus = pools.phosphorus_g_p.resistant[layer] - transferred_phosphorus;
    const labile_carbon = pools.carbon_g_c.labile[layer] + transferred_carbon;
    const labile_apparent_carbon = pools.apparent_carbon_g_c.labile[layer] + transferred_apparent_carbon;
    const labile_nitrogen = pools.nitrogen_g_n.labile[layer] + transferred_nitrogen;
    const labile_phosphorus = pools.phosphorus_g_p.labile[layer] + transferred_phosphorus;
    inline for (.{ tillage_effect, transferred_carbon, transferred_apparent_carbon, transferred_nitrogen, transferred_phosphorus, resistant_carbon, resistant_apparent_carbon, resistant_nitrogen, resistant_phosphorus, labile_carbon, labile_apparent_carbon, labile_nitrogen, labile_phosphorus }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteTillageSocLabilityResult;
    }

    pools.carbon_g_c.resistant[layer] = resistant_carbon;
    pools.apparent_carbon_g_c.resistant[layer] = resistant_apparent_carbon;
    pools.nitrogen_g_n.resistant[layer] = resistant_nitrogen;
    pools.phosphorus_g_p.resistant[layer] = resistant_phosphorus;
    pools.carbon_g_c.labile[layer] = labile_carbon;
    pools.apparent_carbon_g_c.labile[layer] = labile_apparent_carbon;
    pools.nitrogen_g_n.labile[layer] = labile_nitrogen;
    pools.phosphorus_g_p.labile[layer] = labile_phosphorus;
}

test "REDIST SOC lability conserves C N P donor recipient transfers" {
    var c_labile = [_]f64{ 10, 20 };
    var c_resistant = [_]f64{ 100, 200 };
    var a_labile = [_]f64{ 11, 21 };
    var a_resistant = [_]f64{ 110, 210 };
    var n_labile = [_]f64{ 12, 22 };
    var n_resistant = [_]f64{ 120, 220 };
    var p_labile = [_]f64{ 13, 23 };
    var p_resistant = [_]f64{ 130, 230 };
    try increaseLability(0, 2, 0.5, 0.4, .{
        .carbon_g_c = .{ .labile = &c_labile, .resistant = &c_resistant },
        .apparent_carbon_g_c = .{ .labile = &a_labile, .resistant = &a_resistant },
        .nitrogen_g_n = .{ .labile = &n_labile, .resistant = &n_resistant },
        .phosphorus_g_p = .{ .labile = &p_labile, .resistant = &p_resistant },
    });
    try std.testing.expectApproxEqAbs(@as(f64, 99.6), c_resistant[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10.4), c_labile[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 109.56), a_resistant[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 11.44), a_labile[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 119.52), n_resistant[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 12.48), n_labile[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 129.48), p_resistant[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 13.52), p_labile[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 143), p_resistant[0] + p_labile[0], 1.0e-12);
    try std.testing.expectEqual(@as(f64, 200), c_resistant[1]);
}

test "REDIST SOC lability validates all results before mutation" {
    var c_labile = [_]f64{1};
    var c_resistant = [_]f64{std.math.floatMax(f64)};
    var normal_labile = [_]f64{1};
    var normal_resistant = [_]f64{1};
    try std.testing.expectError(error.NonFiniteTillageSocLabilityResult, increaseLability(0, 1, 1, std.math.floatMax(f64), .{
        .carbon_g_c = .{ .labile = &c_labile, .resistant = &c_resistant },
        .apparent_carbon_g_c = .{ .labile = &normal_labile, .resistant = &normal_resistant },
        .nitrogen_g_n = .{ .labile = &normal_labile, .resistant = &normal_resistant },
        .phosphorus_g_p = .{ .labile = &normal_labile, .resistant = &normal_resistant },
    }));
    try std.testing.expectEqual(@as(f64, 1), c_labile[0]);
    try std.testing.expectEqual(std.math.floatMax(f64), c_resistant[0]);
}
