const std = @import("std");
/// OUTSD `VPOXG + VPOXR` for one runtime grid cell. Organic combustion
/// emissions have already been accumulated with their negative source sign,
/// and EXTRACT plant oxidation also retains its negative source sign.
pub fn sourceSignedFlux_g_p(
    cell: usize,
    soil_source_signed_flux_g_p: []const f64,
    plant_oxidation_g_p: []const f64,
    plant_species_count: usize,
) !f64 {
    if (cell >= soil_source_signed_flux_g_p.len or plant_species_count == 0 or plant_oxidation_g_p.len != try std.math.mul(usize, soil_source_signed_flux_g_p.len, plant_species_count)) return error.DailyFirePhosphorusDimensionMismatch;
    var result = soil_source_signed_flux_g_p[cell];
    for (0..plant_species_count) |species| result += plant_oxidation_g_p[cell * plant_species_count + species];
    if (!std.math.isFinite(result)) return error.NonFiniteDailyFirePhosphorus;
    return result;
}

test "VPOXG plus VPOXR preserves source signs across runtime species" {
    var plants = [_]f64{0} ** 14;
    plants[7] = -5;
    plants[13] = -7;
    const result = try sourceSignedFlux_g_p(1, &.{ -100, -14 }, &plants, 7);
    try std.testing.expectEqual(@as(f64, -26), result);
}
