const std = @import("std");
const SceneOptions = @import("../../core/options.zig").SceneOptions;
const SeasonalWeatherChange = @import("../../core/options.zig").SeasonalWeatherChange;
const HourlyForcing = @import("weather.zig").HourlyForcing;
const Timestamp = @import("weather.zig").Timestamp;
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");

pub const Modifier = struct {
    maximum_temperature_c: f64 = 0,
    minimum_temperature_c: f64 = 0,
    radiation: f64 = 1,
    humidity: f64 = 1,
    precipitation: f64 = 1,
    irrigation: f64 = 1,
    wind_speed: f64 = 1,
    atmospheric_co2: f64 = 1,
    precipitation_ammonium: f64 = 1,
    precipitation_nitrate: f64 = 1,
};

pub const PrecipitationChemistryMultipliers = struct {
    ammonium: f64,
    nitrate: f64,
};

pub const State = struct {
    modifiers: [4]Modifier = .{ .{}, .{}, .{}, .{} },

    /// Advances transient modifiers by one model day, matching DAY.F. Call
    /// exactly once at the beginning of each simulated day.
    pub fn advanceDay(self: *State, options: SceneOptions, days_in_year: u16) !void {
        if (options.climate_change_mode != 2) return;
        if (days_in_year != 365 and days_in_year != 366) return error.InvalidClimateYearLength;
        const denominator: f64 = @floatFromInt(days_in_year);
        for (&self.modifiers, options.seasonal_weather_changes) |*modifier, target| {
            try validateTarget(target);
            modifier.maximum_temperature_c += target.maximum_temperature_c / denominator;
            modifier.minimum_temperature_c += target.minimum_temperature_c / denominator;
            modifier.radiation += (target.radiation_fraction - 1.0) / denominator;
            modifier.humidity += (target.humidity_fraction - 1.0) / denominator;
            modifier.precipitation += (target.precipitation_fraction - 1.0) / denominator;
            modifier.irrigation += (target.irrigation_fraction - 1.0) / denominator;
            modifier.wind_speed += (target.wind_speed_fraction - 1.0) / denominator;
            modifier.atmospheric_co2 *= @exp(@log(target.atmospheric_co2_fraction) / denominator);
            modifier.precipitation_ammonium += (target.precipitation_ammonium_fraction - 1.0) / denominator;
            modifier.precipitation_nitrate += (target.precipitation_nitrate_fraction - 1.0) / denominator;
        }
    }

    pub fn apply(self: State, forcing: HourlyForcing, options: SceneOptions, timestamp: Timestamp, solar_noon_hour: f64, altitude_m: f64) !HourlyForcing {
        if (options.climate_change_mode == 0) return forcing;
        if (options.climate_change_mode > 2) return error.InvalidClimateChangeMode;
        if (!std.math.isFinite(solar_noon_hour) or !std.math.isFinite(altitude_m)) return error.InvalidClimateGeometry;
        const day_of_year = timestamp.day_of_year orelse return error.ClimateChangeRequiresDayOfYear;
        const season_index = seasonIndex(day_of_year);
        const modifier = if (options.climate_change_mode == 1) try fromTarget(options.seasonal_weather_changes[season_index]) else self.modifiers[season_index];
        const average_change = 0.5 * (modifier.maximum_temperature_c + modifier.minimum_temperature_c);
        const amplitude_change = 0.5 * (modifier.maximum_temperature_c - modifier.minimum_temperature_c);
        const decimal_hour = @as(f64, @floatFromInt(timestamp.hour)) + @as(f64, @floatFromInt(timestamp.minute)) / 60.0;
        const diurnal_effect = @sin(0.2618 * (decimal_hour - (solar_noon_hour + 3.0)) + 1.5708);
        const changed_temperature_c = forcing.air_temperature_c + average_change + amplitude_change * diurnal_effect;
        const old_saturation = saturationVaporPressureKpa(forcing.air_temperature_c, altitude_m);
        const new_saturation = saturationVaporPressureKpa(changed_temperature_c, altitude_m);
        var vapor_pressure = forcing.vapor_pressure_kpa;
        if (modifier.humidity == 1.0 and old_saturation > 0) vapor_pressure *= new_saturation / old_saturation;
        vapor_pressure = @min(new_saturation, vapor_pressure * modifier.humidity);
        const result: HourlyForcing = .{
            .air_temperature_c = changed_temperature_c,
            .vapor_pressure_kpa = vapor_pressure,
            .precipitation_m = forcing.precipitation_m * modifier.precipitation,
            .rainfall_m = forcing.rainfall_m * modifier.precipitation,
            .snowfall_water_equivalent_m = forcing.snowfall_water_equivalent_m * modifier.precipitation,
            .shortwave_radiation_megajoules_per_m2 = forcing.shortwave_radiation_megajoules_per_m2 * modifier.radiation,
            .wind_speed_m_per_h = forcing.wind_speed_m_per_h * modifier.wind_speed,
            .longwave_radiation_megajoules_per_m2 = forcing.longwave_radiation_megajoules_per_m2,
        };
        try validateForcing(result);
        return result;
    }

    /// `wthr.f:392`'s `DTA=0.5*(TDTPX(NY,NX,N)+TDTPN(NY,NX,N))`, exposed
    /// standalone so the mode-2 biological re-acclimation
    /// (`wthr.f:412--431`, bound at the day boundary in the composition
    /// root under `PLANT-ACCLIM-MODE2-001`) can read the same cumulative
    /// seasonal change that `apply` above already forms internally as
    /// `average_change`. Returns `0` outside mode 2, matching `apply`'s
    /// mode-0 pass-through.
    pub fn averageAirTemperatureChangeC(self: State, options: SceneOptions, day_of_year: u16) !f64 {
        if (options.climate_change_mode != 2) return 0;
        const modifier = self.modifiers[seasonIndex(day_of_year)];
        const result = 0.5 * (modifier.maximum_temperature_c + modifier.minimum_temperature_c);
        if (!std.math.isFinite(result)) return error.NonFiniteClimateChangeAirTemperature;
        return result;
    }

    pub fn precipitationChemistryMultipliers(self: State, options: SceneOptions, day_of_year: u16) !PrecipitationChemistryMultipliers {
        if (options.climate_change_mode == 0) return .{ .ammonium = 1, .nitrate = 1 };
        if (options.climate_change_mode > 2) return error.InvalidClimateChangeMode;
        const index = seasonIndex(day_of_year);
        const modifier = if (options.climate_change_mode == 1) try fromTarget(options.seasonal_weather_changes[index]) else self.modifiers[index];
        const result: PrecipitationChemistryMultipliers = .{
            .ammonium = modifier.precipitation_ammonium,
            .nitrate = modifier.precipitation_nitrate,
        };
        if (!std.math.isFinite(result.ammonium) or !std.math.isFinite(result.nitrate) or
            result.ammonium < 0 or result.nitrate < 0)
            return error.InvalidPrecipitationChemistryMultiplier;
        return result;
    }

    pub fn atmosphericCo2Multiplier(self: State, options: SceneOptions, day_of_year: u16) !f64 {
        if (options.climate_change_mode == 0) return 1;
        if (options.climate_change_mode > 2) return error.InvalidClimateChangeMode;
        const index = seasonIndex(day_of_year);
        const modifier = if (options.climate_change_mode == 1) try fromTarget(options.seasonal_weather_changes[index]) else self.modifiers[index];
        if (!std.math.isFinite(modifier.atmospheric_co2) or modifier.atmospheric_co2 <= 0) return error.NonPositiveCo2Multiplier;
        return modifier.atmospheric_co2;
    }

    /// Returns WTHR's seasonal TDIRI multiplier for the current day. The
    /// caller applies it once to the complete extensive irrigation load so
    /// water and every dissolved carrier retain their concentrations.
    pub fn irrigationMultiplier(self: State, options: SceneOptions, day_of_year: u16) !f64 {
        if (options.climate_change_mode == 0) return 1;
        if (options.climate_change_mode > 2) return error.InvalidClimateChangeMode;
        const index = seasonIndex(day_of_year);
        const modifier = if (options.climate_change_mode == 1)
            try fromTarget(options.seasonal_weather_changes[index])
        else
            self.modifiers[index];
        if (!std.math.isFinite(modifier.irrigation) or modifier.irrigation < 0)
            return error.InvalidIrrigationMultiplier;
        return modifier.irrigation;
    }
};

fn fromTarget(target: SeasonalWeatherChange) !Modifier {
    try validateTarget(target);
    return .{
        .maximum_temperature_c = target.maximum_temperature_c,
        .minimum_temperature_c = target.minimum_temperature_c,
        .radiation = target.radiation_fraction,
        .humidity = target.humidity_fraction,
        .precipitation = target.precipitation_fraction,
        .irrigation = target.irrigation_fraction,
        .wind_speed = target.wind_speed_fraction,
        .atmospheric_co2 = target.atmospheric_co2_fraction,
        .precipitation_ammonium = target.precipitation_ammonium_fraction,
        .precipitation_nitrate = target.precipitation_nitrate_fraction,
    };
}

fn validateTarget(target: SeasonalWeatherChange) !void {
    inline for (@typeInfo(SeasonalWeatherChange).@"struct".fields) |field| {
        const value = @field(target, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteClimateChange;
        if (comptime !std.mem.endsWith(u8, field.name, "temperature_c")) if (value < 0) return error.NegativeClimateMultiplier;
    }
    if (target.atmospheric_co2_fraction <= 0) return error.NonPositiveCo2Multiplier;
}

fn seasonIndex(day_of_year: u16) usize {
    return if (day_of_year > 334 or day_of_year <= 59) 0 else if (day_of_year <= 151) 1 else if (day_of_year <= 243) 2 else 3;
}
pub fn daysInYear(year: u16) u16 {
    return if (execution_calendar_date.isLeapYear(year)) 366 else 365;
}
fn saturationVaporPressureKpa(temperature_c: f64, altitude_m: f64) f64 {
    return 0.61 * @exp(5360.0 * (0.003661 - 1.0 / (273.15 + temperature_c))) * @exp(-altitude_m / 7272.0);
}
fn validateForcing(forcing: HourlyForcing) !void {
    inline for (@typeInfo(HourlyForcing).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(forcing, field.name))) return error.NonFiniteClimateForcing;
    if (forcing.air_temperature_c < -273.15 or forcing.vapor_pressure_kpa < 0 or forcing.precipitation_m < 0 or forcing.rainfall_m < 0 or forcing.snowfall_water_equivalent_m < 0 or @abs(forcing.precipitation_m - forcing.rainfall_m - forcing.snowfall_water_equivalent_m) > 1.0e-12 or forcing.shortwave_radiation_megajoules_per_m2 < 0 or forcing.wind_speed_m_per_h < 0) return error.InvalidClimateForcing;
}

test "step climate change follows seasonal Fortran modifiers" {
    var options: SceneOptions = undefined;
    options.climate_change_mode = 1;
    options.seasonal_weather_changes = .{ .{
        .radiation_fraction = 1.1,
        .maximum_temperature_c = 4,
        .minimum_temperature_c = 2,
        .humidity_fraction = 1,
        .precipitation_fraction = 1.2,
        .irrigation_fraction = 1,
        .wind_speed_fraction = 0.5,
        .atmospheric_co2_fraction = 1.1,
        .precipitation_ammonium_fraction = 2,
        .precipitation_nitrate_fraction = 3,
    }, .{
        .radiation_fraction = 1,
        .maximum_temperature_c = 0,
        .minimum_temperature_c = 0,
        .humidity_fraction = 1,
        .precipitation_fraction = 1,
        .irrigation_fraction = 1,
        .wind_speed_fraction = 1,
        .atmospheric_co2_fraction = 1,
        .precipitation_ammonium_fraction = 1,
        .precipitation_nitrate_fraction = 1,
    }, .{
        .radiation_fraction = 1,
        .maximum_temperature_c = 0,
        .minimum_temperature_c = 0,
        .humidity_fraction = 1,
        .precipitation_fraction = 1,
        .irrigation_fraction = 1,
        .wind_speed_fraction = 1,
        .atmospheric_co2_fraction = 1,
        .precipitation_ammonium_fraction = 1,
        .precipitation_nitrate_fraction = 1,
    }, .{
        .radiation_fraction = 1,
        .maximum_temperature_c = 0,
        .minimum_temperature_c = 0,
        .humidity_fraction = 1,
        .precipitation_fraction = 1,
        .irrigation_fraction = 1,
        .wind_speed_fraction = 1,
        .atmospheric_co2_fraction = 1,
        .precipitation_ammonium_fraction = 1,
        .precipitation_nitrate_fraction = 1,
    } };
    const forcing: HourlyForcing = .{ .air_temperature_c = 10, .vapor_pressure_kpa = 0.5, .precipitation_m = 0.01, .rainfall_m = 0.01, .shortwave_radiation_megajoules_per_m2 = 1, .wind_speed_m_per_h = 100, .longwave_radiation_megajoules_per_m2 = null };
    const changed = try (State{}).apply(forcing, options, .{ .year = 2024, .day_of_year = 20, .month = null, .day_of_month = null, .hour = 12, .minute = 0 }, 12, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.012), changed.precipitation_m, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), changed.shortwave_radiation_megajoules_per_m2, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 50), changed.wind_speed_m_per_h, 1.0e-12);
}

test "atmospheric CO2 multiplier follows active season and mode" {
    var options = std.mem.zeroes(SceneOptions);
    options.climate_change_mode = 1;
    options.seasonal_weather_changes = [_]SeasonalWeatherChange{.{
        .maximum_temperature_c = 0,
        .minimum_temperature_c = 0,
        .radiation_fraction = 1,
        .humidity_fraction = 1,
        .precipitation_fraction = 1,
        .irrigation_fraction = 1,
        .wind_speed_fraction = 1,
        .atmospheric_co2_fraction = 1,
        .precipitation_ammonium_fraction = 1,
        .precipitation_nitrate_fraction = 1,
    }} ** 4;
    options.seasonal_weather_changes[1].atmospheric_co2_fraction = 1.25;
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), try (State{}).atmosphericCo2Multiplier(options, 100), 1e-15);
    options.climate_change_mode = 0;
    try std.testing.expectEqual(@as(f64, 1), try (State{}).atmosphericCo2Multiplier(options, 100));
}

test "irrigation multiplier follows active season and mode" {
    var options = std.mem.zeroes(SceneOptions);
    options.climate_change_mode = 1;
    options.seasonal_weather_changes = [_]SeasonalWeatherChange{.{
        .maximum_temperature_c = 0,
        .minimum_temperature_c = 0,
        .radiation_fraction = 1,
        .humidity_fraction = 1,
        .precipitation_fraction = 1,
        .irrigation_fraction = 1,
        .wind_speed_fraction = 1,
        .atmospheric_co2_fraction = 1,
        .precipitation_ammonium_fraction = 1,
        .precipitation_nitrate_fraction = 1,
    }} ** 4;
    options.seasonal_weather_changes[1].irrigation_fraction = 1.75;
    try std.testing.expectEqual(
        @as(f64, 1.75),
        try (State{}).irrigationMultiplier(options, 100),
    );
    options.climate_change_mode = 0;
    try std.testing.expectEqual(
        @as(f64, 1),
        try (State{}).irrigationMultiplier(options, 100),
    );
    options.climate_change_mode = 3;
    try std.testing.expectError(
        error.InvalidClimateChangeMode,
        (State{}).irrigationMultiplier(options, 100),
    );
    options.climate_change_mode = 2;
    var cumulative: State = .{};
    cumulative.modifiers[1].irrigation = 0.625;
    try std.testing.expectEqual(
        @as(f64, 0.625),
        try cumulative.irrigationMultiplier(options, 100),
    );
}

test "precipitation chemistry multipliers follow active season and reject invalid mode" {
    var options = std.mem.zeroes(SceneOptions);
    options.climate_change_mode = 1;
    options.seasonal_weather_changes = [_]SeasonalWeatherChange{.{
        .radiation_fraction = 1,
        .maximum_temperature_c = 0,
        .minimum_temperature_c = 0,
        .humidity_fraction = 1,
        .precipitation_fraction = 1,
        .irrigation_fraction = 1,
        .wind_speed_fraction = 1,
        .atmospheric_co2_fraction = 1,
        .precipitation_ammonium_fraction = 1,
        .precipitation_nitrate_fraction = 1,
    }} ** 4;
    options.seasonal_weather_changes[1].precipitation_ammonium_fraction = 2;
    options.seasonal_weather_changes[1].precipitation_nitrate_fraction = 3;
    const result = try (State{}).precipitationChemistryMultipliers(options, 100);
    try std.testing.expectEqual(@as(f64, 2), result.ammonium);
    try std.testing.expectEqual(@as(f64, 3), result.nitrate);
    options.climate_change_mode = 3;
    try std.testing.expectError(
        error.InvalidClimateChangeMode,
        (State{}).precipitationChemistryMultipliers(options, 100),
    );
}

test "average air temperature change accumulates under mode 2 and is zero otherwise" {
    var options = std.mem.zeroes(SceneOptions);
    options.climate_change_mode = 2;
    options.seasonal_weather_changes = [_]SeasonalWeatherChange{.{
        .radiation_fraction = 1,
        .maximum_temperature_c = 0,
        .minimum_temperature_c = 0,
        .humidity_fraction = 1,
        .precipitation_fraction = 1,
        .irrigation_fraction = 1,
        .wind_speed_fraction = 1,
        .atmospheric_co2_fraction = 1,
        .precipitation_ammonium_fraction = 1,
        .precipitation_nitrate_fraction = 1,
    }} ** 4;
    options.seasonal_weather_changes[1].maximum_temperature_c = 3.65;
    options.seasonal_weather_changes[1].minimum_temperature_c = 1.825;
    var state = State{};
    try state.advanceDay(options, 365);
    // day_of_year=100 falls in season index 1 (60..151), which accumulated
    // 3.65/365 and 1.825/365 of the seasonal target on the one `advanceDay`
    // call above.
    const change = try state.averageAirTemperatureChangeC(options, 100);
    try std.testing.expectApproxEqAbs(0.5 * (3.65 + 1.825) / 365.0, change, 1e-12);
    options.climate_change_mode = 1;
    try std.testing.expectEqual(@as(f64, 0), try state.averageAirTemperatureChangeC(options, 100));
    options.climate_change_mode = 0;
    try std.testing.expectEqual(@as(f64, 0), try state.averageAirTemperatureChangeC(options, 100));
}

test "climate chronology preserves DAY modulo-four leap years" {
    try std.testing.expectEqual(@as(u16, 366), daysInYear(1900));
    try std.testing.expectEqual(@as(u16, 366), daysInYear(2000));
    try std.testing.expectEqual(@as(u16, 366), daysInYear(2100));
    try std.testing.expectEqual(@as(u16, 365), daysInYear(1901));
}
