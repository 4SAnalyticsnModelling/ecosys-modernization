const std = @import("std");
const chemistry_module = @import("../solute/chemistry_state.zig");
const reactive_module = @import("../nutrients/reactive_nitrogen_state.zig");

pub const ZoneFractions = struct {
    ammonium_non_band: f64,
    ammonium_band: f64,
    nitrate_non_band: f64,
    nitrate_band: f64,
};

pub const Result = struct {
    ammonium_nitrogen_g_n: f64,
    nitrate_plus_nitrite_nitrogen_g_n: f64,
};

pub const VolumeTolerances = struct {
    bulk_absolute_m3: f64,
    water_absolute_m3: f64,
    relative: f64,

    fn validate(self: VolumeTolerances) !void {
        inline for (.{ self.bulk_absolute_m3, self.water_absolute_m3, self.relative }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidDailyMineralNitrogenParameter;
    }

    fn bulkPresent(self: VolumeTolerances, value_m3: f64) bool {
        return value_m3 > self.bulk_absolute_m3 + self.relative * @abs(value_m3);
    }

    fn waterPresent(self: VolumeTolerances, value_m3: f64) bool {
        return value_m3 > self.water_absolute_m3 + self.relative * @abs(value_m3);
    }
};

/// Projects OUTSD UNH4/UNO3 and the runtime-depth concentration profiles from
/// authoritative aqueous, exchange, and reactive-N state without allocation.
pub fn calculateInto(
    chemistry: *const chemistry_module.State,
    reactive: *const reactive_module.State,
    first_layer: usize,
    active_layer_count: usize,
    liquid_water_m3: []const f64,
    matrix_bulk_volume_m3: []const f64,
    bulk_density_megagrams_per_m3: []const f64,
    fractions_source: anytype,
    nitrogen_molar_mass_g_per_mol: f64,
    volume_tolerances: VolumeTolerances,
    ammonium_concentration_g_n_per_m3: []f64,
    nitrate_plus_nitrite_concentration_g_n_per_m3: []f64,
) !Result {
    const capacity = ammonium_concentration_g_n_per_m3.len;
    if (capacity != nitrate_plus_nitrite_concentration_g_n_per_m3.len or active_layer_count > capacity or
        first_layer > chemistry.cell_count or capacity > chemistry.cell_count - first_layer or
        reactive.layer_count != chemistry.cell_count or liquid_water_m3.len != chemistry.cell_count or
        matrix_bulk_volume_m3.len != chemistry.cell_count or bulk_density_megagrams_per_m3.len != chemistry.cell_count)
        return error.DailyMineralNitrogenDimensionMismatch;
    if (!std.math.isFinite(nitrogen_molar_mass_g_per_mol) or nitrogen_molar_mass_g_per_mol <= 0)
        return error.InvalidDailyMineralNitrogenParameter;
    try volume_tolerances.validate();

    @memset(ammonium_concentration_g_n_per_m3, 0);
    @memset(nitrate_plus_nitrite_concentration_g_n_per_m3, 0);
    var result: Result = .{ .ammonium_nitrogen_g_n = 0, .nitrate_plus_nitrite_nitrogen_g_n = 0 };
    for (0..active_layer_count) |local_layer| {
        const layer = first_layer + local_layer;
        const fractions = try diagnosticFractionsAt(fractions_source, layer);
        try validateFractions(fractions);
        const water_m3 = liquid_water_m3[layer];
        const bulk_m3 = matrix_bulk_volume_m3[layer];
        const density_megagrams_per_m3 = bulk_density_megagrams_per_m3[layer];
        if (!std.math.isFinite(water_m3) or water_m3 < 0 or !std.math.isFinite(bulk_m3) or bulk_m3 < 0 or
            !std.math.isFinite(density_megagrams_per_m3) or density_megagrams_per_m3 < 0)
            return error.InvalidDailyMineralNitrogenState;
        const aqueous = chemistry.aqueous[layer];
        const exchange = chemistry.cation_exchange_mol_per_megagram[layer];
        const soil_mass_megagrams = bulk_m3 * density_megagrams_per_m3;
        const ammonium_mol =
            water_m3 * (fractions.ammonium_non_band * aqueous.ammonium_non_band + fractions.ammonium_band * aqueous.ammonium_band) +
            soil_mass_megagrams * (fractions.ammonium_non_band * exchange.ammonium_non_band +
                fractions.ammonium_band * exchange.ammonium_band);
        const nitrate_g_n = nitrogen_molar_mass_g_per_mol * water_m3 *
            (fractions.nitrate_non_band * aqueous.nitrate_non_band + fractions.nitrate_band * aqueous.nitrate_band);
        const nitrite_g_n = reactive.non_band_nitrite_g_n[layer] + reactive.band_nitrite_g_n[layer];
        const ammonium_g_n = nitrogen_molar_mass_g_per_mol * ammonium_mol;
        const oxidized_g_n = nitrate_g_n + nitrite_g_n;
        if (!std.math.isFinite(ammonium_g_n) or ammonium_g_n < 0 or !std.math.isFinite(oxidized_g_n) or oxidized_g_n < 0)
            return error.InvalidDailyMineralNitrogenState;
        result.ammonium_nitrogen_g_n += ammonium_g_n;
        result.nitrate_plus_nitrite_nitrogen_g_n += oxidized_g_n;
        ammonium_concentration_g_n_per_m3[local_layer] = concentration(ammonium_g_n, bulk_m3, water_m3, volume_tolerances);
        nitrate_plus_nitrite_concentration_g_n_per_m3[local_layer] = concentration(oxidized_g_n, bulk_m3, water_m3, volume_tolerances);
    }
    if (!std.math.isFinite(result.ammonium_nitrogen_g_n) or !std.math.isFinite(result.nitrate_plus_nitrite_nitrogen_g_n))
        return error.InvalidDailyMineralNitrogenState;
    return result;
}

fn diagnosticFractionsAt(source: anytype, layer: usize) !ZoneFractions {
    if (comptime @TypeOf(source) == ZoneFractions) return source;
    const fractions = try source.scienceZoneFractionsForFlatIndex(layer);
    return .{
        .ammonium_non_band = fractions.ammonium_non_band,
        .ammonium_band = fractions.ammonium_band,
        .nitrate_non_band = fractions.nitrate_non_band,
        .nitrate_band = fractions.nitrate_band,
    };
}

fn concentration(mass_g: f64, bulk_m3: f64, water_m3: f64, tolerances: VolumeTolerances) f64 {
    if (tolerances.bulkPresent(bulk_m3)) return mass_g / bulk_m3;
    if (tolerances.waterPresent(water_m3)) return mass_g / water_m3;
    return 0;
}

fn validateFractions(f: ZoneFractions) !void {
    inline for (.{ f.ammonium_non_band, f.ammonium_band, f.nitrate_non_band, f.nitrate_band }) |value|
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidDailyMineralNitrogenParameter;
    if (@abs(f.ammonium_non_band + f.ammonium_band - 1) > 1e-12 or
        @abs(f.nitrate_non_band + f.nitrate_band - 1) > 1e-12)
        return error.InvalidDailyMineralNitrogenParameter;
}

test "OUTSD mineral nitrogen projection uses runtime depth and source fallback volumes" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 3);
    defer chemistry.deinit();
    var reactive = try reactive_module.State.init(std.testing.allocator, 3, 1);
    defer reactive.deinit();
    chemistry.aqueous[0].ammonium_non_band = 2;
    chemistry.aqueous[0].ammonium_band = 4;
    chemistry.aqueous[0].nitrate_non_band = 3;
    chemistry.cation_exchange_mol_per_megagram[0].ammonium_non_band = 0.5;
    reactive.non_band_nitrite_g_n[0] = 7;
    chemistry.aqueous[1].ammonium_non_band = 100; // inactive
    var ammonium = [_]f64{ 99, 99, 99 };
    var oxidized = [_]f64{ 99, 99, 99 };
    const result = try calculateInto(&chemistry, &reactive, 0, 1, &.{ 2, 1, 1 }, &.{ 4, 4, 4 }, &.{ 1.5, 1.5, 1.5 }, ZoneFractions{
        .ammonium_non_band = 0.75,
        .ammonium_band = 0.25,
        .nitrate_non_band = 0.8,
        .nitrate_band = 0.2,
    }, 14, .{ .bulk_absolute_m3 = 1e-12, .water_absolute_m3 = 1e-12, .relative = 1e-12 }, &ammonium, &oxidized);
    try std.testing.expectEqual(@as(f64, 101.5), result.ammonium_nitrogen_g_n);
    try std.testing.expectApproxEqAbs(@as(f64, 74.2), result.nitrate_plus_nitrite_nitrogen_g_n, 1e-13);
    try std.testing.expectEqual(@as(f64, 25.375), ammonium[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 18.55), oxidized[0], 1e-14);
    try std.testing.expectEqual(@as(f64, 0), ammonium[1]);
    try std.testing.expectEqual(@as(f64, 0), oxidized[2]);
}
