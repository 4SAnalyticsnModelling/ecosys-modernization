//! **A5 DISPOSITION: never production bound.**
//!
//! Legacy source: `ecosys_f77/hour1.f` lines 4092--4106. This module is an exact,
//! tested, source-order translation of that range and is imported only by
//! `src/module_index.zig`, so it is reachable by `zig build test` and unreachable
//! from `executeHourlyScience`. That is intentional and must stay that way.
//!
//! Classification: architecturally superseded. Production stores the same physics in a
//! different representation, deliberately, with the deviation recorded in
//! `docs/model_changes.md`. Binding this kernel would reintroduce the
//! formulation the project chose to leave behind, as a second writer.
//!
//! Superseded by: `gas_transport.surfaceSolubilityWaterToAir`, called at `ecosys_ng.zig:3574` and `:7733`.
//!
//! Production computes the water-to-air solubility ratio at the point of
//! exchange rather than storing a per-layer solubility field, so the stored
//! field would be a second copy that can go stale between the temperature
//! update and the exchange.
//!
//! Do not bind this module, and do not delete it: the tests are a source-order
//! comparison oracle for the range above. Full argument and the census behind
//! it: `docs/traceability/hour1_2039_5200_binding_survey.md`.
const std = @import("std");

pub const SolubilitiesAt25C = struct {
    carbon_dioxide_ratio: f64,
    methane_ratio: f64,
    oxygen_ratio: f64,
    nitrogen_ratio: f64,
    nitrous_oxide_ratio: f64,
    ammonia_ratio: f64,
    hydrogen_ratio: f64,
};

pub const Activities = struct {
    carbon_dioxide: f64,
    methane: f64,
    oxygen: f64,
    nitrogen: f64,
    nitrous_oxide: f64,
    ammonia: f64,
    hydrogen: f64,
};

pub const Result = struct {
    water_solute_fraction: f64,
    carbon_dioxide_ratio: f64,
    methane_ratio: f64,
    oxygen_ratio: f64,
    nitrogen_ratio: f64,
    nitrous_oxide_ratio: f64,
    ammonia_ratio: f64,
    hydrogen_ratio: f64,
};

pub const SolubilityError = error{
    NonFiniteInput,
    NegativeIonActivity,
    InvalidSoilTemperature,
    NegativeSolubility,
    NonFiniteResult,
};

/// Translates `hour1.f` lines 4092--4106. Solubilities are dimensionless
/// g m-3 aqueous per g m-3 gaseous ratios.
pub fn calculate(
    total_ion_activity_mol_m3: f64,
    soil_temperature_c: f64,
    base: SolubilitiesAt25C,
    activity: Activities,
) SolubilityError!Result {
    if (!std.math.isFinite(total_ion_activity_mol_m3) or
        !std.math.isFinite(soil_temperature_c))
    {
        return error.NonFiniteInput;
    }
    if (total_ion_activity_mol_m3 < 0.0) return error.NegativeIonActivity;
    if (soil_temperature_c <= -273.15) return error.InvalidSoilTemperature;
    inline for (std.meta.fields(SolubilitiesAt25C)) |field| {
        const value = @field(base, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteInput;
        if (value < 0.0) return error.NegativeSolubility;
    }
    inline for (std.meta.fields(Activities)) |field| {
        if (!std.math.isFinite(@field(activity, field.name))) {
            return error.NonFiniteInput;
        }
    }

    const water_solute_fraction =
        5.56e4 / (5.56e4 + total_ion_activity_mol_m3);
    const result = Result{
        .water_solute_fraction = water_solute_fraction,
        .carbon_dioxide_ratio = base.carbon_dioxide_ratio /
            @exp(activity.carbon_dioxide) *
            @exp(0.843 - 0.0281 * soil_temperature_c) * water_solute_fraction,
        .methane_ratio = base.methane_ratio / @exp(activity.methane) *
            @exp(0.597 - 0.0199 * soil_temperature_c) * water_solute_fraction,
        .oxygen_ratio = base.oxygen_ratio / @exp(activity.oxygen) *
            @exp(0.516 - 0.0172 * soil_temperature_c) * water_solute_fraction,
        .nitrogen_ratio = base.nitrogen_ratio / @exp(activity.nitrogen) *
            @exp(0.456 - 0.0152 * soil_temperature_c) * water_solute_fraction,
        .nitrous_oxide_ratio = base.nitrous_oxide_ratio /
            @exp(activity.nitrous_oxide) *
            @exp(0.897 - 0.0299 * soil_temperature_c) * water_solute_fraction,
        .ammonia_ratio = base.ammonia_ratio / @exp(activity.ammonia) *
            @exp(0.513 - 0.0171 * soil_temperature_c) * water_solute_fraction,
        .hydrogen_ratio = base.hydrogen_ratio / @exp(activity.hydrogen) *
            @exp(0.597 - 0.0199 * soil_temperature_c) * water_solute_fraction,
    };
    inline for (std.meta.fields(Result)) |field| {
        const value = @field(result, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteResult;
        if (value < 0.0) return error.NegativeSolubility;
    }
    return result;
}

test "soil gas solubility preserves legacy temperature and activity order" {
    const base = SolubilitiesAt25C{
        .carbon_dioxide_ratio = 1.0,
        .methane_ratio = 1.0,
        .oxygen_ratio = 1.0,
        .nitrogen_ratio = 1.0,
        .nitrous_oxide_ratio = 1.0,
        .ammonia_ratio = 1.0,
        .hydrogen_ratio = 1.0,
    };
    const activity = Activities{
        .carbon_dioxide = 0.1,
        .methane = 0.1,
        .oxygen = 0.1,
        .nitrogen = 0.1,
        .nitrous_oxide = 0.1,
        .ammonia = 0.1,
        .hydrogen = 0.1,
    };
    const result = try calculate(100.0, 20.0, base, activity);
    const water_fraction = 5.56e4 / (5.56e4 + 100.0);
    const expected_co2 =
        1.0 / @exp(0.1) * @exp(0.843 - 0.0281 * 20.0) * water_fraction;
    try std.testing.expectEqual(water_fraction, result.water_solute_fraction);
    try std.testing.expectApproxEqAbs(expected_co2, result.carbon_dioxide_ratio, 1.0e-15);
}

test "zero ion activity gives unit water-solute fraction" {
    const zero_base = std.mem.zeroes(SolubilitiesAt25C);
    const zero_activity = std.mem.zeroes(Activities);
    const result = try calculate(0.0, 25.0, zero_base, zero_activity);
    try std.testing.expectEqual(@as(f64, 1.0), result.water_solute_fraction);
}
