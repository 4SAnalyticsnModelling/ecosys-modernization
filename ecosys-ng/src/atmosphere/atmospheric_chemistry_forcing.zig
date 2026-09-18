// **A8a DISPOSITION: BOUND, gap closed 2026-08-17.** This module is the
// `wthr.f:482--484` block, scaling the three
// immutable baselines `CO2EI`, `CN4RI`, `CNORI` by their climate multipliers.
// Its own note that the baselines are immutable and never re-scaled from an
// already-modified carrier is correct and is the subtle part of that Fortran.
//
// One third of it is owned. `CO2E` (`wthr.f:482`) is
// `src/ecosys_ng.zig:3890`, `site.atmospheric_co2_umol_mol *
// climate_state.atmosphericCo2Multiplier(...)`, which reads the baseline each
// hour exactly as legacy does.
//
// `climate_change.State.precipitationChemistryMultipliers` now supplies the
// seasonal `TDCN4`/`TDCNO` values to `hourly_process_driver`, which calls this
// owner on the immutable header baselines before
// `precipitation_nutrient_speciation`. Thus total ammoniacal N is scaled before
// the pH-dependent NH4/NH3 partition, and repeated hours never compound the
// multiplier. The production binding is adjacent to the snow/direct-rain
// atmospheric input transaction and therefore feeds both accepted routes.

const std = @import("std");

pub const Baseline = struct {
    atmospheric_co2_umol_per_mol: f64,
    precipitation_ammonium_g_n_per_m3: f64,
    precipitation_nitrate_g_n_per_m3: f64,
};

pub const Multipliers = struct {
    atmospheric_co2_fraction: f64,
    precipitation_ammonium_fraction: f64,
    precipitation_nitrate_fraction: f64,
};

pub const Forcing = struct {
    atmospheric_co2_umol_per_mol: f64,
    precipitation_ammonium_g_n_per_m3: f64,
    precipitation_nitrate_g_n_per_m3: f64,
};

/// Exact WTHR atmospheric chemistry forcing from wthr.f:481-483.
///
/// CO2EI, CN4RI, and CNORI are immutable baselines. Climate multipliers are
/// applied to them each hour; previously modified carriers are never reused.
pub fn derive(baseline: Baseline, multipliers: Multipliers) !Forcing {
    inline for (@typeInfo(Baseline).@"struct".fields) |field| {
        const value = @field(baseline, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteAtmosphericChemistryBaseline;
        if (value < 0)
            return error.InvalidAtmosphericChemistryBaseline;
    }
    inline for (@typeInfo(Multipliers).@"struct".fields) |field| {
        const value = @field(multipliers, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteAtmosphericChemistryMultiplier;
        if (value < 0)
            return error.InvalidAtmosphericChemistryMultiplier;
    }
    const forcing: Forcing = .{
        .atmospheric_co2_umol_per_mol = baseline.atmospheric_co2_umol_per_mol *
            multipliers.atmospheric_co2_fraction,
        .precipitation_ammonium_g_n_per_m3 = baseline.precipitation_ammonium_g_n_per_m3 *
            multipliers.precipitation_ammonium_fraction,
        .precipitation_nitrate_g_n_per_m3 = baseline.precipitation_nitrate_g_n_per_m3 *
            multipliers.precipitation_nitrate_fraction,
    };
    inline for (@typeInfo(Forcing).@"struct".fields) |field|
        if (!std.math.isFinite(@field(forcing, field.name)))
            return error.AtmosphericChemistryForcingOverflow;
    return forcing;
}

fn exampleBaseline() Baseline {
    return .{
        .atmospheric_co2_umol_per_mol = 400,
        .precipitation_ammonium_g_n_per_m3 = 0.1,
        .precipitation_nitrate_g_n_per_m3 = 0.2,
    };
}

test "WTHR multipliers derive all chemistry carriers from baselines" {
    const result = try derive(exampleBaseline(), .{
        .atmospheric_co2_fraction = 1.25,
        .precipitation_ammonium_fraction = 2,
        .precipitation_nitrate_fraction = 3,
    });
    try std.testing.expectEqual(
        @as(f64, 500),
        result.atmospheric_co2_umol_per_mol,
    );
    try std.testing.expectEqual(
        @as(f64, 0.2),
        result.precipitation_ammonium_g_n_per_m3,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.6),
        result.precipitation_nitrate_g_n_per_m3,
        1e-15,
    );
}

test "repeated derivation never compounds modified forcing" {
    const multipliers: Multipliers = .{
        .atmospheric_co2_fraction = 1.1,
        .precipitation_ammonium_fraction = 1.2,
        .precipitation_nitrate_fraction = 1.3,
    };
    const first = try derive(exampleBaseline(), multipliers);
    const second = try derive(exampleBaseline(), multipliers);
    try std.testing.expectEqualDeep(first, second);
    try std.testing.expectApproxEqAbs(
        @as(f64, 440),
        second.atmospheric_co2_umol_per_mol,
        1e-12,
    );
}

test "zero multipliers explicitly disable chemistry carriers" {
    const result = try derive(exampleBaseline(), .{
        .atmospheric_co2_fraction = 0,
        .precipitation_ammonium_fraction = 0,
        .precipitation_nitrate_fraction = 0,
    });
    try std.testing.expectEqualDeep(std.mem.zeroes(Forcing), result);
}

test "nonfinite late multiplier fails before returning forcing" {
    try std.testing.expectError(
        error.NonFiniteAtmosphericChemistryMultiplier,
        derive(exampleBaseline(), .{
            .atmospheric_co2_fraction = 1,
            .precipitation_ammonium_fraction = 1,
            .precipitation_nitrate_fraction = std.math.nan(f64),
        }),
    );
}

test "multiplication overflow cannot silently enter precipitation chemistry" {
    var large = exampleBaseline();
    large.precipitation_nitrate_g_n_per_m3 = std.math.floatMax(f64);
    try std.testing.expectError(
        error.AtmosphericChemistryForcingOverflow,
        derive(large, .{
            .atmospheric_co2_fraction = 1,
            .precipitation_ammonium_fraction = 1,
            .precipitation_nitrate_fraction = 2,
        }),
    );
}
