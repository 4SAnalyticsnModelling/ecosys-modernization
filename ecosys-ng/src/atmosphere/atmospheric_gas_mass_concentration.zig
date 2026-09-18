// **A8a DISPOSITION: BOUND; ATMOS-TKQ-001 is closed for HOUR1 conversion.**
//
// This is a faithful translation of `hour1.f:2443--2449`, verified statement by
// statement, and legacy runs it every hour against `TKQ`, the radiation-weighted
// canopy air temperature blended at `redist.f:4373--4374`.
// `atmosphere/canopy_gas_state.State.refreshMassConcentrations` calls `convert`
// for every cell at the start of every accepted hour, using the prior-hour
// carried TKQ and CO2Q/CH4Q/OXYQ plus current background ratios for the
// remaining species. It stages the complete seven-species array before
// publication. The downstream precipitation dissolved-gas boundary and gas
// transport consumers read this hourly mass carrier directly.

const std = @import("std");

pub const MixingRatios = struct {
    carbon_dioxide_umol_mol: f64,
    methane_umol_mol: f64,
    oxygen_umol_mol: f64,
    nitrogen_umol_mol: f64,
    nitrous_oxide_umol_mol: f64,
    ammonia_umol_mol: f64,
    hydrogen_umol_mol: f64,
};

pub const MassConcentrations = struct {
    carbon_dioxide_g_m3: f64,
    methane_g_m3: f64,
    oxygen_g_m3: f64,
    nitrogen_g_m3: f64,
    nitrous_oxide_g_m3: f64,
    ammonia_g_m3: f64,
    hydrogen_g_m3: f64,
};

pub const ConversionError = error{
    NonFiniteInput,
    InvalidMixingRatio,
    InvalidAirTemperature,
    NonFiniteResult,
};

/// Translates `hour1.f` lines 2443--2449. Constants and arithmetic order remain
/// unchanged from the legacy gas conversion at the reference 273.15 K.
pub fn convert(
    mixing_ratios: MixingRatios,
    canopy_air_temperature_k: f64,
) ConversionError!MassConcentrations {
    inline for (std.meta.fields(MixingRatios)) |field| {
        const value = @field(mixing_ratios, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteInput;
        if (value < 0.0) return error.InvalidMixingRatio;
    }
    if (!std.math.isFinite(canopy_air_temperature_k)) return error.NonFiniteInput;
    if (canopy_air_temperature_k <= 0.0) return error.InvalidAirTemperature;

    const concentrations = MassConcentrations{
        .carbon_dioxide_g_m3 = mixing_ratios.carbon_dioxide_umol_mol *
            5.36e-4 * 273.15 / canopy_air_temperature_k,
        .methane_g_m3 = mixing_ratios.methane_umol_mol *
            5.36e-4 * 273.15 / canopy_air_temperature_k,
        .oxygen_g_m3 = mixing_ratios.oxygen_umol_mol *
            1.43e-3 * 273.15 / canopy_air_temperature_k,
        .nitrogen_g_m3 = mixing_ratios.nitrogen_umol_mol *
            1.25e-3 * 273.15 / canopy_air_temperature_k,
        .nitrous_oxide_g_m3 = mixing_ratios.nitrous_oxide_umol_mol *
            1.25e-3 * 273.15 / canopy_air_temperature_k,
        .ammonia_g_m3 = mixing_ratios.ammonia_umol_mol *
            6.25e-4 * 273.15 / canopy_air_temperature_k,
        .hydrogen_g_m3 = mixing_ratios.hydrogen_umol_mol *
            8.92e-5 * 273.15 / canopy_air_temperature_k,
    };
    inline for (std.meta.fields(MassConcentrations)) |field| {
        if (!std.math.isFinite(@field(concentrations, field.name))) {
            return error.NonFiniteResult;
        }
    }
    return concentrations;
}

test "reference temperature preserves legacy conversion coefficients" {
    const concentrations = try convert(.{
        .carbon_dioxide_umol_mol = 400.0,
        .methane_umol_mol = 2.0,
        .oxygen_umol_mol = 210_000.0,
        .nitrogen_umol_mol = 780_000.0,
        .nitrous_oxide_umol_mol = 0.33,
        .ammonia_umol_mol = 0.02,
        .hydrogen_umol_mol = 0.5,
    }, 273.15);

    try std.testing.expectApproxEqAbs(@as(f64, 0.2144), concentrations.carbon_dioxide_g_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001072), concentrations.methane_g_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 300.3), concentrations.oxygen_g_m3, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 975.0), concentrations.nitrogen_g_m3, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0004125), concentrations.nitrous_oxide_g_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0000125), concentrations.ammonia_g_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0000446), concentrations.hydrogen_g_m3, 1.0e-15);
}

test "zero kelvin is rejected before division" {
    const zero = MixingRatios{
        .carbon_dioxide_umol_mol = 0.0,
        .methane_umol_mol = 0.0,
        .oxygen_umol_mol = 0.0,
        .nitrogen_umol_mol = 0.0,
        .nitrous_oxide_umol_mol = 0.0,
        .ammonia_umol_mol = 0.0,
        .hydrogen_umol_mol = 0.0,
    };
    try std.testing.expectError(error.InvalidAirTemperature, convert(zero, 0.0));
}
