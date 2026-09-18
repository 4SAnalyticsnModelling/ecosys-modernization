const std = @import("std");
const reactive = @import("../nutrients/reactive_nitrogen_state.zig");

/// REDIST ZNO2S/ZNO2B transfer. Competition histories and inhibition controls
/// are not pond contents and remain attached to their current runtime layer.
pub fn transferLayerFraction(state: *reactive.State, source: usize, destination: usize, destination_band_fraction: f64, fraction: f64) !void {
    try validateLayerFraction(state, source, destination, destination_band_fraction, fraction);
    transferPair(state.non_band_nitrite_g_n, source, destination, fraction);
    if (destination_band_fraction > 0) transferPair(state.band_nitrite_g_n, source, destination, fraction);
}

pub fn validateLayerFraction(state: *const reactive.State, source: usize, destination: usize, destination_band_fraction: f64, fraction: f64) !void {
    if (source >= state.layer_count or destination >= state.layer_count or source == destination) return error.NitriteLayerRemapIndexOutOfBounds;
    if (!std.math.isFinite(destination_band_fraction) or destination_band_fraction < 0 or destination_band_fraction > 1 or !std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidNitriteLayerRemapInput;
    try validatePair(state.non_band_nitrite_g_n[source], state.non_band_nitrite_g_n[destination], fraction);
    if (destination_band_fraction > 0) try validatePair(state.band_nitrite_g_n[source], state.band_nitrite_g_n[destination], fraction);
}

fn validatePair(source: f64, destination: f64, fraction: f64) !void {
    const moved = fraction * source;
    inline for (.{ source, destination, moved, source - moved, destination + moved }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidNitriteLayerRemapState;
}

fn transferPair(values: []f64, source: usize, destination: usize, fraction: f64) void {
    const moved = fraction * values[source];
    values[source] -= moved;
    values[destination] += moved;
}

test "REDIST nitrite moves non-band and gates band by recipient geometry" {
    var state = try reactive.State.init(std.testing.allocator, 3, 2);
    defer state.deinit();
    state.non_band_nitrite_g_n[0] = 8;
    state.band_nitrite_g_n[0] = 4;
    state.previous_total_non_band_nitrite_demand_g_n[0] = 7;
    try transferLayerFraction(&state, 0, 1, 0, 0.25);
    try std.testing.expectEqual(@as(f64, 6), state.non_band_nitrite_g_n[0]);
    try std.testing.expectEqual(@as(f64, 2), state.non_band_nitrite_g_n[1]);
    try std.testing.expectEqual(@as(f64, 4), state.band_nitrite_g_n[0]);
    try std.testing.expectEqual(@as(f64, 0), state.band_nitrite_g_n[1]);
    try std.testing.expectEqual(@as(f64, 7), state.previous_total_non_band_nitrite_demand_g_n[0]);
    try transferLayerFraction(&state, 0, 2, 1, 0.5);
    try std.testing.expectEqual(@as(f64, 2), state.band_nitrite_g_n[0]);
    try std.testing.expectEqual(@as(f64, 2), state.band_nitrite_g_n[2]);
}
