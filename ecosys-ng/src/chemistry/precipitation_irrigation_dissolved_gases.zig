const std = @import("std");

pub const AtmosphericMassConcentrations = struct {
    carbon_dioxide_g_m3: f64,
    methane_g_m3: f64,
    oxygen_g_m3: f64,
    nitrogen_g_m3: f64,
    nitrous_oxide_g_m3: f64,
};

pub const SolubilitiesAt25C = struct {
    carbon_dioxide_ratio: f64,
    methane_ratio: f64,
    oxygen_ratio: f64,
    nitrogen_ratio: f64,
    nitrous_oxide_ratio: f64,
};

pub const Activities = struct {
    carbon_dioxide: f64,
    methane: f64,
    oxygen: f64,
    nitrogen: f64,
    nitrous_oxide: f64,
};

pub const DissolvedGasConcentrations = struct {
    carbon_dioxide_g_m3: f64,
    methane_g_m3: f64,
    oxygen_g_m3: f64,
    nitrogen_g_m3: f64,
    nitrous_oxide_g_m3: f64,
};

pub const Result = struct {
    precipitation: DissolvedGasConcentrations,
    irrigation: DissolvedGasConcentrations,
};

pub const DissolutionError = error{
    NonFiniteInput,
    InvalidAtmosphericConcentration,
    InvalidSolubility,
    InvalidAirTemperature,
    NonFiniteResult,
};

/// Translates `hour1.f` lines 2463--2482. Concentrations are g m-3,
/// solubilities are g m-3 per g m-3, and canopy temperature is degrees C.
pub fn calculate(
    atmospheric: AtmosphericMassConcentrations,
    solubility: SolubilitiesAt25C,
    activity: Activities,
    canopy_air_temperature_c: f64,
) DissolutionError!Result {
    inline for (std.meta.fields(AtmosphericMassConcentrations)) |field| {
        const value = @field(atmospheric, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteInput;
        if (value < 0.0) return error.InvalidAtmosphericConcentration;
    }
    inline for (std.meta.fields(SolubilitiesAt25C)) |field| {
        const value = @field(solubility, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteInput;
        if (value < 0.0) return error.InvalidSolubility;
    }
    inline for (std.meta.fields(Activities)) |field| {
        if (!std.math.isFinite(@field(activity, field.name))) return error.NonFiniteInput;
    }
    if (!std.math.isFinite(canopy_air_temperature_c)) return error.NonFiniteInput;
    if (canopy_air_temperature_c <= -273.15) return error.InvalidAirTemperature;

    const precipitation = DissolvedGasConcentrations{
        .carbon_dioxide_g_m3 = atmospheric.carbon_dioxide_g_m3 *
            solubility.carbon_dioxide_ratio / @exp(activity.carbon_dioxide) *
            @exp(0.843 - 0.0281 * canopy_air_temperature_c),
        .methane_g_m3 = atmospheric.methane_g_m3 *
            solubility.methane_ratio / @exp(activity.methane) *
            @exp(0.597 - 0.0199 * canopy_air_temperature_c),
        .oxygen_g_m3 = atmospheric.oxygen_g_m3 *
            solubility.oxygen_ratio / @exp(activity.oxygen) *
            @exp(0.516 - 0.0172 * canopy_air_temperature_c),
        .nitrogen_g_m3 = atmospheric.nitrogen_g_m3 *
            solubility.nitrogen_ratio / @exp(activity.nitrogen) *
            @exp(0.456 - 0.0152 * canopy_air_temperature_c),
        .nitrous_oxide_g_m3 = atmospheric.nitrous_oxide_g_m3 *
            solubility.nitrous_oxide_ratio / @exp(activity.nitrous_oxide) *
            @exp(0.897 - 0.0299 * canopy_air_temperature_c),
    };
    const irrigation = DissolvedGasConcentrations{
        .carbon_dioxide_g_m3 = atmospheric.carbon_dioxide_g_m3 *
            solubility.carbon_dioxide_ratio / @exp(activity.carbon_dioxide) *
            @exp(0.843 - 0.0281 * canopy_air_temperature_c),
        .methane_g_m3 = atmospheric.methane_g_m3 *
            solubility.methane_ratio / @exp(activity.methane) *
            @exp(0.597 - 0.0199 * canopy_air_temperature_c),
        .oxygen_g_m3 = atmospheric.oxygen_g_m3 *
            solubility.oxygen_ratio / @exp(activity.oxygen) *
            @exp(0.516 - 0.0172 * canopy_air_temperature_c),
        .nitrogen_g_m3 = atmospheric.nitrogen_g_m3 *
            solubility.nitrogen_ratio / @exp(activity.nitrogen) *
            @exp(0.456 - 0.0152 * canopy_air_temperature_c),
        .nitrous_oxide_g_m3 = atmospheric.nitrous_oxide_g_m3 *
            solubility.nitrous_oxide_ratio / @exp(activity.nitrous_oxide) *
            @exp(0.897 - 0.0299 * canopy_air_temperature_c),
    };

    inline for (std.meta.fields(DissolvedGasConcentrations)) |field| {
        if (!std.math.isFinite(@field(precipitation, field.name)) or
            !std.math.isFinite(@field(irrigation, field.name)))
        {
            return error.NonFiniteResult;
        }
    }
    return .{ .precipitation = precipitation, .irrigation = irrigation };
}

test "precipitation and irrigation retain identical legacy initialization" {
    const result = try calculate(
        .{
            .carbon_dioxide_g_m3 = 0.2,
            .methane_g_m3 = 0.001,
            .oxygen_g_m3 = 300.0,
            .nitrogen_g_m3 = 970.0,
            .nitrous_oxide_g_m3 = 0.0004,
        },
        .{
            .carbon_dioxide_ratio = 0.8,
            .methane_ratio = 0.7,
            .oxygen_ratio = 0.6,
            .nitrogen_ratio = 0.5,
            .nitrous_oxide_ratio = 0.4,
        },
        .{
            .carbon_dioxide = 0.1,
            .methane = 0.2,
            .oxygen = 0.3,
            .nitrogen = 0.4,
            .nitrous_oxide = 0.5,
        },
        20.0,
    );

    inline for (std.meta.fields(DissolvedGasConcentrations)) |field| {
        try std.testing.expectEqual(
            @field(result.precipitation, field.name),
            @field(result.irrigation, field.name),
        );
        try std.testing.expect(@field(result.precipitation, field.name) >= 0.0);
    }
    const expected_co2 = 0.2 * 0.8 / @exp(0.1) * @exp(0.843 - 0.0281 * 20.0);
    try std.testing.expectEqual(expected_co2, result.precipitation.carbon_dioxide_g_m3);
}

test "absolute-zero canopy temperature is rejected" {
    const atmospheric = AtmosphericMassConcentrations{
        .carbon_dioxide_g_m3 = 0.0,
        .methane_g_m3 = 0.0,
        .oxygen_g_m3 = 0.0,
        .nitrogen_g_m3 = 0.0,
        .nitrous_oxide_g_m3 = 0.0,
    };
    const solubility = SolubilitiesAt25C{
        .carbon_dioxide_ratio = 0.0,
        .methane_ratio = 0.0,
        .oxygen_ratio = 0.0,
        .nitrogen_ratio = 0.0,
        .nitrous_oxide_ratio = 0.0,
    };
    const activity = Activities{
        .carbon_dioxide = 0.0,
        .methane = 0.0,
        .oxygen = 0.0,
        .nitrogen = 0.0,
        .nitrous_oxide = 0.0,
    };
    try std.testing.expectError(
        error.InvalidAirTemperature,
        calculate(atmospheric, solubility, activity, -273.15),
    );
}
