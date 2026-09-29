const std = @import("std");

/// nitro.f 3942-3946 removes the residue microbes' supply-limited topsoil
/// uptake (RINO3R etc., already bounded by the zone TOTAL, 2382-2383) as
/// uptake*FNO3S from the non-band zone and uptake*FNO3B from the band zone.
/// That is a uniform concentration decrement, which drives a thin, poorer
/// zone negative while the other still holds almost all of the total
/// (Ottawa hour 3295: NO3 band fraction 0.0028). Keep the legacy split, but
/// cap each zone's share at its own mass and take the remainder from the other
/// zone. Returns concentration decrements `{ non_band, band }`; identical to
/// legacy whenever legacy stays nonnegative. Releases (negative totals) keep
/// the legacy uniform split.
pub fn zoneConcentrationDecrements(total_g: f64, carrier_g_per_mol_m3: f64, non_band_fraction: f64, band_fraction: f64, non_band_concentration: f64, band_concentration: f64) [2]f64 {
    if (!(carrier_g_per_mol_m3 > 0)) return .{ 0, 0 };
    var non_band_g = total_g * non_band_fraction;
    var band_g = total_g * band_fraction;
    if (total_g > 0) {
        const non_band_available_g = carrier_g_per_mol_m3 * non_band_fraction * @max(0, non_band_concentration);
        const band_available_g = carrier_g_per_mol_m3 * band_fraction * @max(0, band_concentration);
        if (band_g > band_available_g) {
            non_band_g += band_g - band_available_g;
            band_g = band_available_g;
        } else if (non_band_g > non_band_available_g) {
            band_g += non_band_g - non_band_available_g;
            non_band_g = non_band_available_g;
        }
    }
    return .{
        if (non_band_fraction > 0) non_band_g / (carrier_g_per_mol_m3 * non_band_fraction) else 0,
        if (band_fraction > 0) band_g / (carrier_g_per_mol_m3 * band_fraction) else 0,
    };
}

test "residue topsoil uptake keeps the legacy zone split but never overdraws one zone" {
    // Legacy uniform decrement when both zones can pay it.
    const uniform = zoneConcentrationDecrements(1.0, 10.0, 0.75, 0.25, 1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), uniform[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), uniform[1], 1e-15);
    // Ottawa hour 3295 shape: thin poor band; its excess moves to non-band.
    const carrier = 4.538836259429897e-3 * 14.0;
    const band_c = 1.47e-5;
    const step = zoneConcentrationDecrements(1.17e-6, carrier, 0.9972, 0.0028, 0.0615, band_c);
    try std.testing.expectApproxEqAbs(band_c, step[1], 1e-18);
    const removed_g = carrier * (0.9972 * step[0] + 0.0028 * step[1]);
    try std.testing.expectApproxEqRel(@as(f64, 1.17e-6), removed_g, 1e-12);
    // Releases keep the uniform split.
    const release = zoneConcentrationDecrements(-1.0, 10.0, 0.5, 0.5, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, -0.1), release[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.1), release[1], 1e-15);
}
