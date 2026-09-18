// **A8a DISPOSITION: superseded, but it earned its keep first.**
// The hourly forcing that WTHR assembles is produced in production by
// `io/input/hourly_weather_stream.zig:43` together with
// `io/input/weather.normalizeHourlyWithPhase`, which cover every unit code and every
// record cadence this module handles. Nothing here is bound and nothing needs to be.
// Note the ordering, though: this module was correct and production was not. Reading its
// `@min` against the bound reader is what exposed the missing `wthr.f:199`
// `VPK=AMIN1(DWPTH,VPS)` cap, now applied at `hourly_weather_stream.zig:174`. The verdict
// is supersession only because the fix went into the owner, not because the candidate was
// redundant.
// WTHR-VPS-001 group of
// docs/traceability/hourly_vapor_pressure_was_never_capped_at_saturation.md

const std = @import("std");

pub const Inputs = struct {
    shortwave_radiation_megajoules_per_m2_h: f64,
    air_temperature_c: f64,
    ambient_vapor_pressure_kpa: f64,
    wind_speed_m_per_h: f64,
    precipitation_water_equivalent_m: f64,
    altitude_m: f64,
    snowfall_temperature_threshold_c: f64,
    minimum_snowfall_water_equivalent_m: f64 = 0.1e-3,
    minimum_wind_speed_m_per_h: f64 = 3600,
};

pub const Observation = struct {
    shortwave_radiation_megajoules_per_m2_h: f64,
    air_temperature_c: f64,
    air_temperature_k: f64,
    saturated_vapor_pressure_kpa: f64,
    ambient_vapor_pressure_kpa: f64,
    wind_speed_m_per_h: f64,
    rainfall_m: f64,
    snowfall_water_equivalent_m: f64,
};

/// Exact hourly-record normalization from wthr.f:187-209.
pub fn normalize(inputs: Inputs) !Observation {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteHourlyWeatherObservation;
    }
    const air_temperature_k = inputs.air_temperature_c + 273.15;
    if (air_temperature_k <= 0 or
        inputs.shortwave_radiation_megajoules_per_m2_h < 0 or
        inputs.ambient_vapor_pressure_kpa < 0 or
        inputs.wind_speed_m_per_h < 0 or
        inputs.precipitation_water_equivalent_m < 0 or
        inputs.minimum_snowfall_water_equivalent_m < 0 or
        inputs.minimum_wind_speed_m_per_h < 0)
        return error.InvalidHourlyWeatherObservation;

    const saturated_vapor_pressure_kpa =
        0.61 * @exp(5360.0 * (3.661e-3 - 1.0 / air_temperature_k)) *
        @exp(-inputs.altitude_m / 7272.0);
    if (!std.math.isFinite(saturated_vapor_pressure_kpa))
        return error.HourlyWeatherObservationOverflow;

    var rainfall_m: f64 = 0;
    var snowfall_water_equivalent_m: f64 = 0;
    if (inputs.air_temperature_c > inputs.snowfall_temperature_threshold_c) {
        rainfall_m = inputs.precipitation_water_equivalent_m;
    } else {
        snowfall_water_equivalent_m =
            inputs.precipitation_water_equivalent_m;
        if (snowfall_water_equivalent_m <
            inputs.minimum_snowfall_water_equivalent_m)
            snowfall_water_equivalent_m = 0;
    }

    return .{
        .shortwave_radiation_megajoules_per_m2_h = inputs.shortwave_radiation_megajoules_per_m2_h,
        .air_temperature_c = inputs.air_temperature_c,
        .air_temperature_k = air_temperature_k,
        .saturated_vapor_pressure_kpa = saturated_vapor_pressure_kpa,
        .ambient_vapor_pressure_kpa = @min(
            inputs.ambient_vapor_pressure_kpa,
            saturated_vapor_pressure_kpa,
        ),
        .wind_speed_m_per_h = @max(
            inputs.minimum_wind_speed_m_per_h,
            inputs.wind_speed_m_per_h,
        ),
        .rainfall_m = rainfall_m,
        .snowfall_water_equivalent_m = snowfall_water_equivalent_m,
    };
}

fn exampleInputs() Inputs {
    return .{
        .shortwave_radiation_megajoules_per_m2_h = 0.8,
        .air_temperature_c = 10,
        .ambient_vapor_pressure_kpa = 20,
        .wind_speed_m_per_h = 100,
        .precipitation_water_equivalent_m = 0.002,
        .altitude_m = 727.2,
        .snowfall_temperature_threshold_c = 0,
    };
}

test "hourly observation caps vapor and enforces source wind floor" {
    const result = try normalize(exampleInputs());
    try std.testing.expectEqual(
        @as(f64, 3600),
        result.wind_speed_m_per_h,
    );
    try std.testing.expectEqual(
        result.saturated_vapor_pressure_kpa,
        result.ambient_vapor_pressure_kpa,
    );
    try std.testing.expectEqual(@as(f64, 0.002), result.rainfall_m);
    try std.testing.expectEqual(
        @as(f64, 0),
        result.snowfall_water_equivalent_m,
    );
}

test "temperature equality follows source snowfall branch" {
    var inputs = exampleInputs();
    inputs.air_temperature_c = 0;
    const result = try normalize(inputs);
    try std.testing.expectEqual(@as(f64, 0), result.rainfall_m);
    try std.testing.expectEqual(
        @as(f64, 0.002),
        result.snowfall_water_equivalent_m,
    );
}

test "snow cutoff is strict and equality is retained" {
    var inputs = exampleInputs();
    inputs.air_temperature_c = -1;
    inputs.precipitation_water_equivalent_m = 0.000099;
    var result = try normalize(inputs);
    try std.testing.expectEqual(
        @as(f64, 0),
        result.snowfall_water_equivalent_m,
    );
    inputs.precipitation_water_equivalent_m = 0.0001;
    result = try normalize(inputs);
    try std.testing.expectEqual(
        @as(f64, 0.0001),
        result.snowfall_water_equivalent_m,
    );
}

test "altitude attenuation matches exact WTHR exponential" {
    var inputs = exampleInputs();
    inputs.ambient_vapor_pressure_kpa = 0;
    const result = try normalize(inputs);
    const expected =
        0.61 * @exp(5360.0 * (3.661e-3 - 1.0 / 283.15)) *
        @exp(-727.2 / 7272.0);
    try std.testing.expectApproxEqAbs(
        expected,
        result.saturated_vapor_pressure_kpa,
        3e-15,
    );
}

test "nonfinite late input fails before returning observation" {
    var inputs = exampleInputs();
    inputs.snowfall_temperature_threshold_c = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteHourlyWeatherObservation,
        normalize(inputs),
    );
}
