// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 11316--11344 collapses the NH4 and NO3 band geometry inside the
// tillage depth. Weaker claim than the rest of the family: production sets all
// three band fractions to zero at runottawa:70 `plant_nutrients,0,0,0,1,1,1,1`
// (see `redistribution/soil/ammonium_band_geometry.zig:1--17`), so there is no
// band to collapse at the reference run even once the soil-side path exists.
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
// band reset group of
// docs/traceability/redistribution_tillage_unbound_family_disposition.md
//
const std = @import("std");

pub const Inputs = struct {
    disturbance_type: i32, // ITILL
    soil_mixing_remaining_fraction: f64, // XCORP
    mixing_gate_tolerance: f64, // ZERO2
    tillage_depth_m: f64, // DCORP
    layer_bottom_depth_m: []const f64, // CDPTHZ
    first_soil_layer: usize, // NUI, converted from Fortran index
};
pub const Geometry = struct {
    ammonium_band_depth_m: []f64, // DPNHB
    ammonium_band_width_m: []f64, // WDNHB
    ammonium_band_volume_fraction: []f64, // VLNHB
    ammonium_nonband_volume_fraction: []f64, // VLNH4
    nitrate_band_depth_m: []f64, // DPNOB
    nitrate_band_width_m: []f64, // WDNOB
    nitrate_band_volume_fraction: []f64, // VLNOB
    nitrate_nonband_volume_fraction: []f64, // VLNO3
};
pub const NitrogenPools = struct {
    ammonium_nonband_g_n: []f64, // ZNH4S
    ammonium_band_g_n: []f64, // ZNH4B
    ammonia_nonband_g_n: []f64, // ZNH3S
    ammonia_band_g_n: []f64, // ZNH3B
    exchangeable_ammonium_nonband_mol: []f64, // XN4
    exchangeable_ammonium_band_mol: []f64, // XNB
    nitrate_nonband_g_n: []f64, // ZNO3S
    nitrate_band_g_n: []f64, // ZNO3B
    nitrite_nonband_g_n: []f64, // ZNO2S
    nitrite_band_g_n: []f64, // ZNO2B
};
const LayerResult = struct {
    eligible: bool = false,
    ammonium_g_n: f64 = 0,
    ammonia_g_n: f64 = 0,
    exchangeable_ammonium_mol: f64 = 0,
    nitrate_g_n: f64 = 0,
    nitrite_g_n: f64 = 0,
};

fn finiteSlice(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 11277--11278 and 11316--11344.
pub fn reset(allocator: std.mem.Allocator, inputs: Inputs, geometry: Geometry, pools: NitrogenPools) !bool {
    const layer_count = inputs.layer_bottom_depth_m.len;
    if (layer_count == 0 or inputs.first_soil_layer >= layer_count) return error.TillageNitrogenBandDimensionMismatch;
    inline for (std.meta.fields(Geometry)) |field|
        if (@field(geometry, field.name).len != layer_count) return error.TillageNitrogenBandDimensionMismatch;
    inline for (std.meta.fields(NitrogenPools)) |field|
        if (@field(pools, field.name).len != layer_count) return error.TillageNitrogenBandDimensionMismatch;
    inline for (.{ inputs.soil_mixing_remaining_fraction, inputs.mixing_gate_tolerance, inputs.tillage_depth_m }) |value|
        if (!std.math.isFinite(value)) return error.InvalidTillageNitrogenBandInput;
    if (!finiteSlice(inputs.layer_bottom_depth_m)) return error.InvalidTillageNitrogenBandInput;
    inline for (std.meta.fields(Geometry)) |field|
        if (!finiteSlice(@field(geometry, field.name))) return error.InvalidTillageNitrogenBandInput;
    inline for (std.meta.fields(NitrogenPools)) |field| {
        const values = @field(pools, field.name);
        if (!finiteSlice(values)) return error.InvalidTillageNitrogenBandInput;
        for (values) |value| if (value < 0) return error.InvalidTillageNitrogenBandInput;
    }
    if (inputs.mixing_gate_tolerance < 0 or inputs.tillage_depth_m < 0) return error.InvalidTillageNitrogenBandInput;
    if (inputs.disturbance_type < 0 or inputs.disturbance_type > 20 or
        inputs.soil_mixing_remaining_fraction >= 1.0 - inputs.mixing_gate_tolerance) return false;

    const results = try allocator.alloc(LayerResult, layer_count);
    defer allocator.free(results);
    @memset(results, .{});
    for (inputs.first_soil_layer..layer_count) |layer| {
        if (inputs.layer_bottom_depth_m[layer] > inputs.tillage_depth_m) continue;
        var result = &results[layer];
        result.eligible = true;
        result.ammonium_g_n = pools.ammonium_nonband_g_n[layer] + pools.ammonium_band_g_n[layer];
        result.ammonia_g_n = pools.ammonia_nonband_g_n[layer] + pools.ammonia_band_g_n[layer];
        result.exchangeable_ammonium_mol = pools.exchangeable_ammonium_nonband_mol[layer] + pools.exchangeable_ammonium_band_mol[layer];
        result.nitrate_g_n = pools.nitrate_nonband_g_n[layer] + pools.nitrate_band_g_n[layer];
        result.nitrite_g_n = pools.nitrite_nonband_g_n[layer] + pools.nitrite_band_g_n[layer];
        inline for (std.meta.fields(LayerResult)) |field| {
            if (comptime std.mem.eql(u8, field.name, "eligible")) continue;
            if (!std.math.isFinite(@field(result.*, field.name))) return error.NonFiniteTillageNitrogenBandResult;
        }
    }
    for (inputs.first_soil_layer..layer_count) |layer| {
        const result = results[layer];
        if (!result.eligible) continue;
        geometry.ammonium_band_depth_m[layer] = 0;
        geometry.ammonium_band_width_m[layer] = 0;
        geometry.ammonium_band_volume_fraction[layer] = 0;
        geometry.ammonium_nonband_volume_fraction[layer] = 1;
        geometry.nitrate_band_depth_m[layer] = 0;
        geometry.nitrate_band_width_m[layer] = 0;
        geometry.nitrate_band_volume_fraction[layer] = 0;
        geometry.nitrate_nonband_volume_fraction[layer] = 1;
        pools.ammonium_nonband_g_n[layer] = result.ammonium_g_n;
        pools.ammonia_nonband_g_n[layer] = result.ammonia_g_n;
        pools.ammonium_band_g_n[layer] = 0;
        pools.ammonia_band_g_n[layer] = 0;
        pools.exchangeable_ammonium_nonband_mol[layer] = result.exchangeable_ammonium_mol;
        pools.exchangeable_ammonium_band_mol[layer] = 0;
        pools.nitrate_nonband_g_n[layer] = result.nitrate_g_n;
        pools.nitrite_nonband_g_n[layer] = result.nitrite_g_n;
        pools.nitrate_band_g_n[layer] = 0;
        pools.nitrite_band_g_n[layer] = 0;
    }
    return true;
}

test "REDIST tillage nitrogen band reset preserves gates depths and mass" {
    const depth = [_]f64{ 0, 0.1, 0.3 };
    var geometry_backing: [8][3]f64 = @splat(@splat(0.5));
    var pool_backing: [10][3]f64 = @splat(@splat(1));
    const geometry = Geometry{ .ammonium_band_depth_m = &geometry_backing[0], .ammonium_band_width_m = &geometry_backing[1], .ammonium_band_volume_fraction = &geometry_backing[2], .ammonium_nonband_volume_fraction = &geometry_backing[3], .nitrate_band_depth_m = &geometry_backing[4], .nitrate_band_width_m = &geometry_backing[5], .nitrate_band_volume_fraction = &geometry_backing[6], .nitrate_nonband_volume_fraction = &geometry_backing[7] };
    const pools = NitrogenPools{ .ammonium_nonband_g_n = &pool_backing[0], .ammonium_band_g_n = &pool_backing[1], .ammonia_nonband_g_n = &pool_backing[2], .ammonia_band_g_n = &pool_backing[3], .exchangeable_ammonium_nonband_mol = &pool_backing[4], .exchangeable_ammonium_band_mol = &pool_backing[5], .nitrate_nonband_g_n = &pool_backing[6], .nitrate_band_g_n = &pool_backing[7], .nitrite_nonband_g_n = &pool_backing[8], .nitrite_band_g_n = &pool_backing[9] };
    try std.testing.expect(try reset(std.testing.allocator, .{ .disturbance_type = 5, .soil_mixing_remaining_fraction = 0.5, .mixing_gate_tolerance = 1e-6, .tillage_depth_m = 0.2, .layer_bottom_depth_m = &depth, .first_soil_layer = 1 }, geometry, pools));
    try std.testing.expectEqual(@as(f64, 2), pool_backing[0][1]);
    try std.testing.expectEqual(@as(f64, 0), pool_backing[1][1]);
    try std.testing.expectEqual(@as(f64, 1), geometry_backing[3][1]);
    try std.testing.expectEqual(@as(f64, 1), pool_backing[0][2]);
    try std.testing.expectEqual(@as(f64, 0.5), geometry_backing[3][2]);
}

test "REDIST tillage nitrogen late layer overflow is atomic" {
    const depth = [_]f64{ 0.1, 0.2 };
    var geometry_backing: [8][2]f64 = @splat(@splat(0.5));
    var pool_backing: [10][2]f64 = @splat(@splat(1));
    pool_backing[0][1] = std.math.floatMax(f64);
    pool_backing[1][1] = std.math.floatMax(f64);
    const geometry = Geometry{ .ammonium_band_depth_m = &geometry_backing[0], .ammonium_band_width_m = &geometry_backing[1], .ammonium_band_volume_fraction = &geometry_backing[2], .ammonium_nonband_volume_fraction = &geometry_backing[3], .nitrate_band_depth_m = &geometry_backing[4], .nitrate_band_width_m = &geometry_backing[5], .nitrate_band_volume_fraction = &geometry_backing[6], .nitrate_nonband_volume_fraction = &geometry_backing[7] };
    const pools = NitrogenPools{ .ammonium_nonband_g_n = &pool_backing[0], .ammonium_band_g_n = &pool_backing[1], .ammonia_nonband_g_n = &pool_backing[2], .ammonia_band_g_n = &pool_backing[3], .exchangeable_ammonium_nonband_mol = &pool_backing[4], .exchangeable_ammonium_band_mol = &pool_backing[5], .nitrate_nonband_g_n = &pool_backing[6], .nitrate_band_g_n = &pool_backing[7], .nitrite_nonband_g_n = &pool_backing[8], .nitrite_band_g_n = &pool_backing[9] };
    try std.testing.expectError(error.NonFiniteTillageNitrogenBandResult, reset(std.testing.allocator, .{ .disturbance_type = 5, .soil_mixing_remaining_fraction = 0.5, .mixing_gate_tolerance = 1e-6, .tillage_depth_m = 0.2, .layer_bottom_depth_m = &depth, .first_soil_layer = 0 }, geometry, pools));
    try std.testing.expectEqual(@as(f64, 1), pool_backing[0][0]);
    try std.testing.expectEqual(@as(f64, 0.5), geometry_backing[3][0]);
}
