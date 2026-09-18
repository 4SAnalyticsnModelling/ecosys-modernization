// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 11345--11416 collapses the phosphate band geometry and exchange
// sites. Same band-fraction caveat as `nitrogen_band_reset`: the reference run
// has no phosphate band, so this module is part of the gap but not
// independently consequential today.
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

pub const phosphate_family_count = 20;
pub const BandPair = struct { nonband: []f64, band: []f64 };
pub const PhosphatePools = struct {
    /// Exact REDIST 11345--11364 order: H0PO4,H1PO4,H2PO4,H3PO4,
    /// ZFE1P,ZFE2P,ZCA0P,ZCA1P,ZCA2P,ZMG1P,XOH0,XOH1,XOH2,
    /// XH1P,XH2P,PALPO,PFEPO,PCAPD,PCAPH,PCAPM.
    families: []const BandPair,
};
pub const FertilizerPools = struct {
    ammonium: BandPair, // ZNH4FA/B
    ammonia: BandPair, // ZNH3FA/B
    urea: BandPair, // ZNHUFA/B
    nitrate: BandPair, // ZNO3FA/B
};
pub const Inputs = struct {
    disturbance_type: i32,
    soil_mixing_remaining_fraction: f64,
    mixing_gate_tolerance: f64,
    tillage_depth_m: f64,
    layer_bottom_depth_m: []const f64,
    first_soil_layer: usize,
    phosphate_band_depth_m: []f64, // DPPOB
    phosphate_band_width_m: []f64, // WDPOB
    phosphate_nonband_volume_fraction: []f64, // VLPO4
    phosphate_band_volume_fraction: []f64, // VLPOB
    ammonium_nonband_volume_fraction: []const f64, // VLNH4
    ammonium_band_volume_fraction: []const f64, // VLNHB
    nitrate_nonband_volume_fraction: []const f64, // VLNO3
    nitrate_band_volume_fraction: []const f64, // VLNOB
};

fn finiteSlice(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}
fn validatePair(pair: BandPair, layers: usize) !void {
    if (pair.nonband.len != layers or pair.band.len != layers) return error.TillageBandResetDimensionMismatch;
    if (!finiteSlice(pair.nonband) or !finiteSlice(pair.band)) return error.InvalidTillageBandResetInput;
    for (pair.nonband) |value| if (value < 0) return error.InvalidTillageBandResetInput;
    for (pair.band) |value| if (value < 0) return error.InvalidTillageBandResetInput;
}

/// Direct translation of REDIST 11277--11278 and 11345--11416.
pub fn reset(allocator: std.mem.Allocator, inputs: Inputs, phosphate: PhosphatePools, fertilizer: FertilizerPools) !bool {
    const layers = inputs.layer_bottom_depth_m.len;
    if (layers == 0 or inputs.first_soil_layer >= layers or phosphate.families.len != phosphate_family_count)
        return error.TillageBandResetDimensionMismatch;
    inline for (.{ inputs.phosphate_band_depth_m, inputs.phosphate_band_width_m, inputs.phosphate_nonband_volume_fraction, inputs.phosphate_band_volume_fraction, inputs.ammonium_nonband_volume_fraction, inputs.ammonium_band_volume_fraction, inputs.nitrate_nonband_volume_fraction, inputs.nitrate_band_volume_fraction }) |values| {
        if (values.len != layers) return error.TillageBandResetDimensionMismatch;
        if (!finiteSlice(values)) return error.InvalidTillageBandResetInput;
        for (values) |value| if (value < 0 or value > 1) return error.InvalidTillageBandResetInput;
    }
    for (0..layers) |layer| {
        inline for (.{ .{ inputs.phosphate_nonband_volume_fraction, inputs.phosphate_band_volume_fraction }, .{ inputs.ammonium_nonband_volume_fraction, inputs.ammonium_band_volume_fraction }, .{ inputs.nitrate_nonband_volume_fraction, inputs.nitrate_band_volume_fraction } }) |fractions|
            if (@abs(fractions[0][layer] + fractions[1][layer] - 1.0) > 1e-12)
                return error.InvalidTillageBandResetInput;
    }
    for (phosphate.families) |pair| try validatePair(pair, layers);
    inline for (std.meta.fields(FertilizerPools)) |field| try validatePair(@field(fertilizer, field.name), layers);
    inline for (.{ inputs.soil_mixing_remaining_fraction, inputs.mixing_gate_tolerance, inputs.tillage_depth_m }) |value|
        if (!std.math.isFinite(value)) return error.InvalidTillageBandResetInput;
    if (!finiteSlice(inputs.layer_bottom_depth_m) or inputs.mixing_gate_tolerance < 0 or inputs.tillage_depth_m < 0)
        return error.InvalidTillageBandResetInput;
    if (inputs.disturbance_type < 0 or inputs.disturbance_type > 20 or inputs.soil_mixing_remaining_fraction >= 1.0 - inputs.mixing_gate_tolerance) return false;

    const totals = try allocator.alloc(f64, (phosphate_family_count + 4) * layers);
    defer allocator.free(totals);
    @memset(totals, 0);
    for (inputs.first_soil_layer..layers) |layer| {
        if (inputs.layer_bottom_depth_m[layer] > inputs.tillage_depth_m) continue;
        inputs.phosphate_band_depth_m[layer] = 0;
        inputs.phosphate_band_width_m[layer] = 0;
        inputs.phosphate_band_volume_fraction[layer] = 0;
        inputs.phosphate_nonband_volume_fraction[layer] = 1;
        for (phosphate.families, 0..) |pair, family| {
            totals[family * layers + layer] = pair.nonband[layer] + pair.band[layer];
            if (!std.math.isFinite(totals[family * layers + layer])) return error.NonFiniteTillageBandResetResult;
        }
        totals[phosphate_family_count * layers + layer] = fertilizer.ammonium.nonband[layer] + fertilizer.ammonium.band[layer];
        totals[(phosphate_family_count + 1) * layers + layer] = fertilizer.ammonia.nonband[layer] + fertilizer.ammonia.band[layer];
        totals[(phosphate_family_count + 2) * layers + layer] = fertilizer.urea.nonband[layer] + fertilizer.urea.band[layer];
        // REDIST 11408 names NH4FB here, but that duplicates ammonium and
        // destroys banded nitrate.  The scientifically consistent donor pair
        // is the same species in its two zones.
        totals[(phosphate_family_count + 3) * layers + layer] = fertilizer.nitrate.nonband[layer] + fertilizer.nitrate.band[layer];
        for (0..4) |family|
            if (!std.math.isFinite(totals[(phosphate_family_count + family) * layers + layer])) return error.NonFiniteTillageBandResetResult;
    }
    for (inputs.first_soil_layer..layers) |layer| {
        if (inputs.layer_bottom_depth_m[layer] > inputs.tillage_depth_m) continue;
        for (phosphate.families, 0..) |pair, family| {
            const total = totals[family * layers + layer];
            pair.nonband[layer] = total * inputs.phosphate_nonband_volume_fraction[layer];
            pair.band[layer] = total * inputs.phosphate_band_volume_fraction[layer];
        }
        inline for (.{ fertilizer.ammonium, fertilizer.ammonia, fertilizer.urea }, 0..) |pair, family| {
            const total = totals[(phosphate_family_count + family) * layers + layer];
            pair.nonband[layer] = total * inputs.ammonium_nonband_volume_fraction[layer];
            pair.band[layer] = total * inputs.ammonium_band_volume_fraction[layer];
        }
        const nitrate_total = totals[(phosphate_family_count + 3) * layers + layer];
        fertilizer.nitrate.nonband[layer] = nitrate_total * inputs.nitrate_nonband_volume_fraction[layer];
        fertilizer.nitrate.band[layer] = nitrate_total * inputs.nitrate_band_volume_fraction[layer];
    }
    return true;
}

test "REDIST tillage phosphate and fertilizer reset preserves every band donor" {
    const layers = 2;
    const depth = [_]f64{ 0.1, 0.3 };
    var phosphate_depth = [_]f64{ 0.02, 0.02 };
    var phosphate_width = [_]f64{ 0.03, 0.03 };
    var nonband = [_]f64{ 0.75, 0.75 };
    var band = [_]f64{ 0.25, 0.25 };
    var phosphate_nonband: [phosphate_family_count][layers]f64 = @splat(@splat(3));
    var phosphate_band: [phosphate_family_count][layers]f64 = @splat(@splat(1));
    var pairs: [phosphate_family_count]BandPair = undefined;
    for (0..phosphate_family_count) |family| pairs[family] = .{ .nonband = &phosphate_nonband[family], .band = &phosphate_band[family] };
    var fertilizer_backing: [8][layers]f64 = @splat(@splat(0));
    fertilizer_backing[0] = @splat(2);
    fertilizer_backing[1] = @splat(5);
    fertilizer_backing[2] = @splat(3);
    fertilizer_backing[3] = @splat(1);
    fertilizer_backing[4] = @splat(4);
    fertilizer_backing[5] = @splat(2);
    fertilizer_backing[6] = @splat(7);
    fertilizer_backing[7] = @splat(99);
    const fertilizer = FertilizerPools{ .ammonium = .{ .nonband = &fertilizer_backing[0], .band = &fertilizer_backing[1] }, .ammonia = .{ .nonband = &fertilizer_backing[2], .band = &fertilizer_backing[3] }, .urea = .{ .nonband = &fertilizer_backing[4], .band = &fertilizer_backing[5] }, .nitrate = .{ .nonband = &fertilizer_backing[6], .band = &fertilizer_backing[7] } };
    const ammonium_nonband = [_]f64{ 1, 1 };
    const ammonium_band = [_]f64{ 0, 0 };
    const nitrate_nonband = [_]f64{ 1, 1 };
    const nitrate_band = [_]f64{ 0, 0 };
    try std.testing.expect(try reset(std.testing.allocator, .{ .disturbance_type = 5, .soil_mixing_remaining_fraction = 0.5, .mixing_gate_tolerance = 1e-6, .tillage_depth_m = 0.2, .layer_bottom_depth_m = &depth, .first_soil_layer = 0, .phosphate_band_depth_m = &phosphate_depth, .phosphate_band_width_m = &phosphate_width, .phosphate_nonband_volume_fraction = &nonband, .phosphate_band_volume_fraction = &band, .ammonium_nonband_volume_fraction = &ammonium_nonband, .ammonium_band_volume_fraction = &ammonium_band, .nitrate_nonband_volume_fraction = &nitrate_nonband, .nitrate_band_volume_fraction = &nitrate_band }, .{ .families = &pairs }, fertilizer));
    try std.testing.expectEqual(@as(f64, 4), phosphate_nonband[19][0]);
    try std.testing.expectEqual(@as(f64, 0), phosphate_band[19][0]);
    try std.testing.expectEqual(@as(f64, 106), fertilizer_backing[6][0]);
    try std.testing.expectEqual(@as(f64, 0), fertilizer_backing[7][0]);
    try std.testing.expectEqual(@as(f64, 106), fertilizer_backing[6][0] + fertilizer_backing[7][0]);
    try std.testing.expectEqual(@as(f64, 3), phosphate_nonband[0][1]);
    try std.testing.expectEqual(@as(f64, 99), fertilizer_backing[7][1]);
}

test "REDIST tillage phosphate late overflow is atomic" {
    const depth = [_]f64{ 0.1, 0.2 };
    var phosphate_depth = [_]f64{ 0.02, 0.02 };
    var phosphate_width = [_]f64{ 0.03, 0.03 };
    var nonband = [_]f64{ 1, 1 };
    var band = [_]f64{ 0, 0 };
    var phosphate_nonband: [phosphate_family_count][2]f64 = @splat(@splat(1));
    var phosphate_band: [phosphate_family_count][2]f64 = @splat(@splat(1));
    phosphate_nonband[19][1] = std.math.floatMax(f64);
    phosphate_band[19][1] = std.math.floatMax(f64);
    var pairs: [phosphate_family_count]BandPair = undefined;
    for (0..phosphate_family_count) |family| pairs[family] = .{ .nonband = &phosphate_nonband[family], .band = &phosphate_band[family] };
    var f: [8][2]f64 = @splat(@splat(1));
    const fertilizer = FertilizerPools{ .ammonium = .{ .nonband = &f[0], .band = &f[1] }, .ammonia = .{ .nonband = &f[2], .band = &f[3] }, .urea = .{ .nonband = &f[4], .band = &f[5] }, .nitrate = .{ .nonband = &f[6], .band = &f[7] } };
    try std.testing.expectError(error.NonFiniteTillageBandResetResult, reset(std.testing.allocator, .{ .disturbance_type = 5, .soil_mixing_remaining_fraction = 0.5, .mixing_gate_tolerance = 1e-6, .tillage_depth_m = 0.2, .layer_bottom_depth_m = &depth, .first_soil_layer = 0, .phosphate_band_depth_m = &phosphate_depth, .phosphate_band_width_m = &phosphate_width, .phosphate_nonband_volume_fraction = &nonband, .phosphate_band_volume_fraction = &band, .ammonium_nonband_volume_fraction = &nonband, .ammonium_band_volume_fraction = &band, .nitrate_nonband_volume_fraction = &nonband, .nitrate_band_volume_fraction = &band }, .{ .families = &pairs }, fertilizer));
    try std.testing.expectEqual(@as(f64, 1), phosphate_nonband[0][0]);
    try std.testing.expectEqual(@as(f64, 1), f[0][0]);
}
