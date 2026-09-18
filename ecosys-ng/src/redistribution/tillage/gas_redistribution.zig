// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 12458--12483 writes the gaseous and aqueous CO2, CH4, O2, N2, N2O,
// NH3, and H2 pools back per layer. No caller.
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

pub const gaseous_family_count = 7;
pub const aqueous_family_count = 6;
pub const GaseousFamily = struct { layer_amount_g: []f64, mixed_total_g: f64 };
pub const AqueousFamily = struct { layer_amount_g: []f64, mixed_total_g: f64, held_amount_g: []const f64 };
pub const Inputs = struct {
    first_soil_layer: usize,
    last_mixed_layer: usize,
    mixing_depth_m: f64,
    mixing_fraction: f64,
    cumulative_layer_bottom_m: []const f64,
    layer_thickness_m: []const f64,
    minimum_layer_thickness_m: f64,
    /// CO2G,CH4G,OXYG,Z2GG,Z2OG,ZNH3G,H2GG source order.
    gaseous_families: []const GaseousFamily,
    /// CO2S,CH4S,OXYS,Z2GS,Z2OS,H2GS source order.
    aqueous_families: []const AqueousFamily,
};

fn finite(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 12458--12483 for one runtime soil column.
pub fn redistribute(allocator: std.mem.Allocator, inputs: Inputs) !void {
    const layers = inputs.cumulative_layer_bottom_m.len;
    if (layers == 0 or inputs.first_soil_layer > inputs.last_mixed_layer or inputs.last_mixed_layer >= layers or inputs.layer_thickness_m.len != layers or inputs.gaseous_families.len != gaseous_family_count or inputs.aqueous_families.len != aqueous_family_count) return error.TillageGasRedistributionDimensionMismatch;
    if (!finite(inputs.cumulative_layer_bottom_m) or !finite(inputs.layer_thickness_m)) return error.InvalidTillageGasRedistributionInput;
    inline for (.{ inputs.mixing_depth_m, inputs.mixing_fraction, inputs.minimum_layer_thickness_m }) |value| if (!std.math.isFinite(value)) return error.InvalidTillageGasRedistributionInput;
    if (inputs.mixing_depth_m <= 0 or inputs.mixing_fraction < 0 or inputs.mixing_fraction > 1 or inputs.minimum_layer_thickness_m < 0) return error.InvalidTillageGasRedistributionInput;
    for (inputs.gaseous_families) |family| {
        if (family.layer_amount_g.len != layers) return error.TillageGasRedistributionDimensionMismatch;
        if (!finite(family.layer_amount_g) or !std.math.isFinite(family.mixed_total_g)) return error.InvalidTillageGasRedistributionInput;
    }
    for (inputs.aqueous_families) |family| {
        if (family.layer_amount_g.len != layers or family.held_amount_g.len != layers) return error.TillageGasRedistributionDimensionMismatch;
        if (!finite(family.layer_amount_g) or !finite(family.held_amount_g) or !std.math.isFinite(family.mixed_total_g)) return error.InvalidTillageGasRedistributionInput;
    }

    const gaseous = try allocator.alloc(f64, gaseous_family_count * layers);
    defer allocator.free(gaseous);
    const aqueous = try allocator.alloc(f64, aqueous_family_count * layers);
    defer allocator.free(aqueous);
    for (inputs.gaseous_families, 0..) |family, i| @memcpy(gaseous[i * layers ..][0..layers], family.layer_amount_g);
    for (inputs.aqueous_families, 0..) |family, i| @memcpy(aqueous[i * layers ..][0..layers], family.layer_amount_g);
    for (inputs.first_soil_layer..inputs.last_mixed_layer + 1) |layer| {
        const thickness = inputs.layer_thickness_m[layer];
        if (thickness <= inputs.minimum_layer_thickness_m) continue;
        const overlap = @min(thickness, inputs.mixing_depth_m - (inputs.cumulative_layer_bottom_m[layer] - thickness));
        const fi = overlap / inputs.mixing_depth_m;
        const ti = overlap / thickness;
        const tx = 1.0 - ti;
        for (inputs.gaseous_families, 0..) |family, i| {
            const old = family.layer_amount_g[layer];
            gaseous[i * layers + layer] = ti * old + inputs.mixing_fraction * (fi * family.mixed_total_g - ti * old) + tx * old;
            if (!std.math.isFinite(gaseous[i * layers + layer])) return error.NonFiniteTillageGasRedistributionResult;
        }
        for (inputs.aqueous_families, 0..) |family, i| {
            const old = family.layer_amount_g[layer];
            aqueous[i * layers + layer] = ti * old + inputs.mixing_fraction * (fi * family.mixed_total_g - ti * old) + tx * old + inputs.mixing_fraction * family.held_amount_g[layer];
            if (!std.math.isFinite(aqueous[i * layers + layer])) return error.NonFiniteTillageGasRedistributionResult;
        }
    }
    for (inputs.gaseous_families, 0..) |family, i| @memcpy(family.layer_amount_g, gaseous[i * layers ..][0..layers]);
    for (inputs.aqueous_families, 0..) |family, i| @memcpy(family.layer_amount_g, aqueous[i * layers ..][0..layers]);
}

test "REDIST tillage gas redistribution preserves gaseous and aqueous order" {
    const bottoms = [_]f64{ 0.1, 0.3 };
    const thickness = [_]f64{ 0.1, 0.2 };
    const held = [_]f64{ 0.5, 1 };
    var gas_values: [gaseous_family_count][2]f64 = @splat(@splat(2));
    var aqueous_values: [aqueous_family_count][2]f64 = @splat(@splat(2));
    var gases: [gaseous_family_count]GaseousFamily = undefined;
    var aqueous: [aqueous_family_count]AqueousFamily = undefined;
    for (0..gaseous_family_count) |i| gases[i] = .{ .layer_amount_g = &gas_values[i], .mixed_total_g = 4 };
    for (0..aqueous_family_count) |i| aqueous[i] = .{ .layer_amount_g = &aqueous_values[i], .mixed_total_g = 4, .held_amount_g = &held };
    try redistribute(std.testing.allocator, .{ .first_soil_layer = 0, .last_mixed_layer = 1, .mixing_depth_m = 0.2, .mixing_fraction = 0.5, .cumulative_layer_bottom_m = &bottoms, .layer_thickness_m = &thickness, .minimum_layer_thickness_m = 0.001, .gaseous_families = &gases, .aqueous_families = &aqueous });
    try std.testing.expectEqual(@as(f64, 2), gas_values[0][0]);
    try std.testing.expectEqual(@as(f64, 2.25), aqueous_values[0][0]);
    try std.testing.expectEqual(@as(f64, 3), aqueous_values[5][1]);
}

test "REDIST tillage gas late aqueous overflow is atomic" {
    const bottoms = [_]f64{ 0.1, 0.2 };
    const thickness = [_]f64{ 0.1, 0.1 };
    const held = [_]f64{ 1, std.math.floatMax(f64) };
    var gas_values: [gaseous_family_count][2]f64 = @splat(@splat(2));
    var aqueous_values: [aqueous_family_count][2]f64 = @splat(@splat(2));
    var gases: [gaseous_family_count]GaseousFamily = undefined;
    var aqueous: [aqueous_family_count]AqueousFamily = undefined;
    for (0..gaseous_family_count) |i| gases[i] = .{ .layer_amount_g = &gas_values[i], .mixed_total_g = 4 };
    for (0..aqueous_family_count) |i| aqueous[i] = .{ .layer_amount_g = &aqueous_values[i], .mixed_total_g = 4, .held_amount_g = &held };
    aqueous[aqueous_family_count - 1].mixed_total_g = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteTillageGasRedistributionResult, redistribute(std.testing.allocator, .{ .first_soil_layer = 0, .last_mixed_layer = 1, .mixing_depth_m = 0.2, .mixing_fraction = 1, .cumulative_layer_bottom_m = &bottoms, .layer_thickness_m = &thickness, .minimum_layer_thickness_m = 0, .gaseous_families = &gases, .aqueous_families = &aqueous }));
    try std.testing.expectEqual(@as(f64, 2), gas_values[0][0]);
    try std.testing.expectEqual(@as(f64, 2), aqueous_values[0][0]);
}
