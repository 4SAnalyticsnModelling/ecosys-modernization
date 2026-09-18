const std = @import("std");

/// Publishes REDIST `TSEDER` from the authoritative extensive mineral owner.
/// Positive is deposition and negative is erosion.
pub fn publishAcceptedNetSedimentMg(hour_start_surface_soil_mass_megagrams: []const f64, final_surface_soil_mass_megagrams: []const f64, net_sediment_megagrams: []f64) !void {
    if (hour_start_surface_soil_mass_megagrams.len != final_surface_soil_mass_megagrams.len or net_sediment_megagrams.len != final_surface_soil_mass_megagrams.len) return error.NetSedimentLedgerDimensionMismatch;
    for (hour_start_surface_soil_mass_megagrams, final_surface_soil_mass_megagrams) |initial_mass_megagrams, final_mass_megagrams| {
        const change_megagrams = final_mass_megagrams - initial_mass_megagrams;
        if (!std.math.isFinite(initial_mass_megagrams) or initial_mass_megagrams <= 0 or !std.math.isFinite(final_mass_megagrams) or final_mass_megagrams <= 0 or !std.math.isFinite(change_megagrams)) return error.InvalidNetSedimentLedgerState;
    }
    for (hour_start_surface_soil_mass_megagrams, final_surface_soil_mass_megagrams, net_sediment_megagrams) |initial_mass_megagrams, final_mass_megagrams, *change_megagrams| change_megagrams.* = final_mass_megagrams - initial_mass_megagrams;
}

test "REDIST TSEDER retains deposition sign and publishes atomically" {
    var change = [_]f64{ 8, 9, 10 };
    try publishAcceptedNetSedimentMg(&.{ 10, 20, 30 }, &.{ 9, 22, 30 }, &change);
    try std.testing.expectEqualSlices(f64, &.{ -1, 2, 0 }, &change);
    change = .{ 8, 9, 10 };
    try std.testing.expectError(error.InvalidNetSedimentLedgerState, publishAcceptedNetSedimentMg(&.{ 10, 20, 30 }, &.{ 9, std.math.nan(f64), 30 }, &change));
    try std.testing.expectEqualSlices(f64, &.{ 8, 9, 10 }, &change);
}
