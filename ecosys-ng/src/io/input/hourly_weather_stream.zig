const std = @import("std");
const weather = @import("weather.zig");
const disaggregation = @import("daily_weather_disaggregation.zig");

pub const Observation = struct {
    timestamp: weather.Timestamp,
    forcing: weather.HourlyForcing,
};

const Day = struct { timestamp: weather.Timestamp, forcing: weather.DailyForcing };

/// Bounded-memory hourly cursor over either native hourly weather or daily
/// weather. Daily records retain only the previous/current/next forcing needed
/// by DAY/WTHR and emit all 24 hours before reading another record.
pub const Stream = struct {
    source: *weather.WeatherStream,
    altitude_m: f64,
    latitude_degrees_north: f64,
    phytotron: bool,
    daily: bool,
    subhourly: bool,
    three_hourly: bool,
    precipitation_phase: weather.PrecipitationPhase,
    pending_subhourly: ?Observation = null,
    previous_three_hour: ?Observation = null,
    current_three_hour: ?Observation = null,
    three_hour_offset: u8 = 3,
    initialized_daily: bool = false,
    previous_day: Day = undefined,
    current_day: Day = undefined,
    next_day: Day = undefined,
    has_next_day: bool = false,
    hour: u8 = 1,

    pub fn init(source: *weather.WeatherStream, altitude_m: f64, latitude_degrees_north: f64, phytotron: bool, precipitation_phase: weather.PrecipitationPhase) !Stream {
        if (!std.math.isFinite(altitude_m) or !std.math.isFinite(latitude_degrees_north) or latitude_degrees_north < -90 or latitude_degrees_north > 90) return error.InvalidHourlyWeatherStreamGeometry;
        try precipitation_phase.validate();
        source.precipitation_phase = precipitation_phase;
        const temporal_code = std.ascii.toUpper(source.header.temporal_code[0]);
        return .{ .source = source, .altitude_m = altitude_m, .latitude_degrees_north = latitude_degrees_north, .phytotron = phytotron, .daily = temporal_code == 'D', .subhourly = temporal_code == 'S', .three_hourly = temporal_code == '3', .precipitation_phase = precipitation_phase };
    }

    pub fn next(self: *Stream) !?Observation {
        if (!self.daily) {
            // `wthr.f:199` VPK=AMIN1(DWPTH,VPS) caps the ambient vapor pressure
            // against the altitude-adjusted saturation value, and it does so
            // per model hour in WTHR, i.e. *after* READS has built, infilled and
            // interpolated the hourly array. All three non-daily branches
            // therefore cap here rather than inside the readers: capping an
            // endpoint before interpolation is not the same operation, because
            // the interpolated temperature that sets VPS differs from either
            // endpoint's. The daily branch below needs no cap here because
            // `daily_weather_disaggregation` already applies `wthr.f:138`.
            if (self.subhourly) return capVapor(try self.nextAggregatedHour() orelse return null, self.altitude_m);
            if (self.three_hourly) return capVapor(try self.nextExpandedThreeHour() orelse return null, self.altitude_m);
            const observation = try self.source.nextHourly(self.altitude_m) orelse return null;
            return capVapor(.{ .timestamp = observation.timestamp, .forcing = observation.forcing }, self.altitude_m);
        }
        if (!self.initialized_daily) {
            const first = try self.source.nextDaily(self.altitude_m) orelse return null;
            self.current_day = copyDay(first);
            self.previous_day = self.current_day;
            if (try self.source.nextDaily(self.altitude_m)) |next_day| {
                self.next_day = copyDay(next_day);
                self.has_next_day = true;
            } else {
                self.next_day = self.current_day;
            }
            self.initialized_daily = true;
        } else if (self.hour > 24) {
            if (!self.has_next_day) return null;
            self.previous_day = self.current_day;
            self.current_day = self.next_day;
            if (try self.source.nextDaily(self.altitude_m)) |next_day| {
                self.next_day = copyDay(next_day);
                self.has_next_day = true;
            } else {
                self.next_day = self.current_day;
                self.has_next_day = false;
            }
            self.hour = 1;
        }
        const result = try disaggregation.disaggregateHourWithPhase(self.previous_day.forcing, self.current_day.forcing, self.next_day.forcing, self.current_day.timestamp.day_of_year orelse return error.DailyWeatherRequiresDayOfYear, self.current_day.timestamp.year orelse return error.DailyWeatherRequiresYear, self.hour, self.latitude_degrees_north, self.source.header.solar_noon_hour, self.altitude_m, self.phytotron, self.precipitation_phase);
        var timestamp = self.current_day.timestamp;
        timestamp.hour = self.hour;
        timestamp.minute = 0;
        self.hour += 1;
        return .{ .timestamp = timestamp, .forcing = result.forcing };
    }

    /// READS infills each 3-hour endpoint into three hourly records. State
    /// remains bounded: only the previous and current endpoint are retained.
    fn nextExpandedThreeHour(self: *Stream) !?Observation {
        if (self.three_hour_offset >= 3) {
            const source_observation = try self.source.nextHourly(self.altitude_m) orelse return null;
            if (source_observation.timestamp.hour < 3 or @mod(source_observation.timestamp.hour, 3) != 0) return error.InvalidThreeHourlyWeatherEndpoint;
            self.previous_three_hour = self.current_three_hour;
            self.current_three_hour = copyObservation(source_observation);
            self.three_hour_offset = 0;
        }
        const current = self.current_three_hour.?;
        const previous = self.previous_three_hour orelse current;
        const result = try expandThreeHour(previous, current, self.three_hour_offset, self.precipitation_phase);
        self.three_hour_offset += 1;
        return result;
    }

    /// Reduce arbitrarily many source samples in one clock hour to one model
    /// forcing. This keeps I/O bounded and avoids running the ecosystem kernels
    /// at the source sampling interval.
    fn nextAggregatedHour(self: *Stream) !?Observation {
        const first = if (self.pending_subhourly) |pending| blk: {
            self.pending_subhourly = null;
            break :blk pending;
        } else blk: {
            const source_observation = try self.source.nextHourly(self.altitude_m) orelse return null;
            break :blk copyObservation(source_observation);
        };
        var accumulator = HourAccumulator.init(first);
        while (try self.source.nextHourly(self.altitude_m)) |source_observation| {
            const observation = copyObservation(source_observation);
            if (!sameClockHour(first.timestamp, observation.timestamp)) {
                self.pending_subhourly = observation;
                break;
            }
            try accumulator.add(observation.forcing);
        }
        return accumulator.finish();
    }
};

fn expandThreeHour(previous: Observation, current: Observation, offset: u8, phase: weather.PrecipitationPhase) !Observation {
    if (offset >= 3 or current.timestamp.hour < 3) return error.InvalidThreeHourlyWeatherEndpoint;
    const current_weight: f64 = switch (offset) {
        0 => 0.333,
        1 => 0.667,
        2 => 1,
        else => unreachable,
    };
    const previous_weight = 1 - current_weight;
    const interpolate = struct {
        fn value(a: f64, b: f64, wa: f64, wb: f64) f64 {
            return wa * a + wb * b;
        }
    }.value;
    var timestamp = current.timestamp;
    timestamp.hour = current.timestamp.hour - 2 + offset;
    timestamp.minute = 0;
    const temperature_c = interpolate(previous.forcing.air_temperature_c, current.forcing.air_temperature_c, previous_weight, current_weight);
    const precipitation_m = current.forcing.precipitation_m / 3;
    const is_rain = temperature_c > phase.snowfall_temperature_threshold_c;
    const snowfall_m = if (!is_rain and precipitation_m >= phase.minimum_snowfall_water_equivalent_m) precipitation_m else 0;
    const previous_longwave = previous.forcing.longwave_radiation_megajoules_per_m2;
    const current_longwave = current.forcing.longwave_radiation_megajoules_per_m2;
    if ((previous_longwave == null) != (current_longwave == null)) return error.InconsistentThreeHourlyLongwaveRadiation;
    return .{ .timestamp = timestamp, .forcing = .{
        .air_temperature_c = temperature_c,
        .vapor_pressure_kpa = interpolate(previous.forcing.vapor_pressure_kpa, current.forcing.vapor_pressure_kpa, previous_weight, current_weight),
        .precipitation_m = if (is_rain) precipitation_m else snowfall_m,
        .rainfall_m = if (is_rain) precipitation_m else 0,
        .snowfall_water_equivalent_m = snowfall_m,
        .shortwave_radiation_megajoules_per_m2 = interpolate(previous.forcing.shortwave_radiation_megajoules_per_m2, current.forcing.shortwave_radiation_megajoules_per_m2, previous_weight, current_weight),
        .wind_speed_m_per_h = interpolate(previous.forcing.wind_speed_m_per_h, current.forcing.wind_speed_m_per_h, previous_weight, current_weight),
        .longwave_radiation_megajoules_per_m2 = if (current_longwave) |value| interpolate(previous_longwave.?, value, previous_weight, current_weight) else null,
    } };
}

fn copyDay(observation: weather.DailyObservation) Day {
    return .{ .timestamp = observation.timestamp, .forcing = observation.forcing };
}

/// `wthr.f:197--199`. Applied to every hourly-array observation once the model
/// hour's temperature is final.
fn capVapor(observation: Observation, altitude_m: f64) Observation {
    var result = observation;
    result.forcing.vapor_pressure_kpa = @min(
        result.forcing.vapor_pressure_kpa,
        weather.saturatedVaporPressureKpa(result.forcing.air_temperature_c, altitude_m),
    );
    return result;
}

test "hourly observations are capped at the altitude-adjusted saturation vapor pressure" {
    // Ottawa's site altitude is 92 m, so VPS is EXP(-92/7272)=0.98743 of the
    // sea-level saturation value and any relative humidity above 98.743 %
    // exceeds it. 8.42 % of the example's 43896 hourly records do. A record at
    // 100 % RH is the worst case.
    const temperature_c: f64 = 10;
    const altitude_m: f64 = 92;
    const sea_level = 0.61 * @exp(5360.0 * (0.003661 - 1.0 / (273.15 + temperature_c)));
    const observation: Observation = .{
        .timestamp = .{ .year = 1998, .day_of_year = 100, .month = null, .day_of_month = null, .hour = 5, .minute = 0 },
        .forcing = .{
            .air_temperature_c = temperature_c,
            .vapor_pressure_kpa = sea_level,
            .precipitation_m = 0,
            .rainfall_m = 0,
            .snowfall_water_equivalent_m = 0,
            .shortwave_radiation_megajoules_per_m2 = 0,
            .wind_speed_m_per_h = 3600,
            .longwave_radiation_megajoules_per_m2 = null,
        },
    };
    const capped = capVapor(observation, altitude_m);
    // Fortran: VPS=0.61*EXP(5360*(3.661E-03-1/TKA))*EXP(-ALTI/7272).
    try std.testing.expectApproxEqRel(
        sea_level * @exp(-altitude_m / 7272.0),
        capped.forcing.vapor_pressure_kpa,
        1.0e-12,
    );
    // Non-vacuity: the cap must actually bind, i.e. it is strictly below the
    // uncapped input. Before this fix production returned the uncapped value.
    try std.testing.expect(capped.forcing.vapor_pressure_kpa < observation.forcing.vapor_pressure_kpa);
    // An already-subsaturated record must pass through untouched.
    var dry = observation;
    dry.forcing.vapor_pressure_kpa = 0.5 * sea_level;
    try std.testing.expectEqual(
        @as(f64, 0.5 * sea_level),
        capVapor(dry, altitude_m).forcing.vapor_pressure_kpa,
    );
}

fn copyObservation(observation: weather.HourlyObservation) Observation {
    return .{ .timestamp = observation.timestamp, .forcing = observation.forcing };
}

fn sameClockHour(a: weather.Timestamp, b: weather.Timestamp) bool {
    return a.year == b.year and a.day_of_year == b.day_of_year and a.month == b.month and a.day_of_month == b.day_of_month and a.hour == b.hour;
}

const HourAccumulator = struct {
    timestamp: weather.Timestamp,
    count: u32,
    air_temperature_c: f64,
    vapor_pressure_kpa: f64,
    precipitation_m: f64,
    rainfall_m: f64,
    snowfall_water_equivalent_m: f64,
    shortwave_radiation_megajoules_per_m2: f64,
    wind_speed_m_per_h: f64,
    longwave_radiation_megajoules_per_m2: ?f64,

    fn init(observation: Observation) HourAccumulator {
        return .{
            .timestamp = observation.timestamp,
            .count = 1,
            .air_temperature_c = observation.forcing.air_temperature_c,
            .vapor_pressure_kpa = observation.forcing.vapor_pressure_kpa,
            .precipitation_m = observation.forcing.precipitation_m,
            .rainfall_m = observation.forcing.rainfall_m,
            .snowfall_water_equivalent_m = observation.forcing.snowfall_water_equivalent_m,
            .shortwave_radiation_megajoules_per_m2 = observation.forcing.shortwave_radiation_megajoules_per_m2,
            .wind_speed_m_per_h = observation.forcing.wind_speed_m_per_h,
            .longwave_radiation_megajoules_per_m2 = observation.forcing.longwave_radiation_megajoules_per_m2,
        };
    }

    fn add(self: *HourAccumulator, forcing: weather.HourlyForcing) !void {
        if ((self.longwave_radiation_megajoules_per_m2 == null) != (forcing.longwave_radiation_megajoules_per_m2 == null)) return error.InconsistentSubhourlyLongwaveRadiation;
        self.count += 1;
        self.air_temperature_c += forcing.air_temperature_c;
        self.vapor_pressure_kpa += forcing.vapor_pressure_kpa;
        self.precipitation_m += forcing.precipitation_m;
        self.rainfall_m += forcing.rainfall_m;
        self.snowfall_water_equivalent_m += forcing.snowfall_water_equivalent_m;
        self.shortwave_radiation_megajoules_per_m2 += forcing.shortwave_radiation_megajoules_per_m2;
        self.wind_speed_m_per_h += forcing.wind_speed_m_per_h;
        if (forcing.longwave_radiation_megajoules_per_m2) |value| self.longwave_radiation_megajoules_per_m2.? += value;
    }

    fn finish(self: HourAccumulator) Observation {
        const sample_count: f64 = @floatFromInt(self.count);
        var timestamp = self.timestamp;
        timestamp.minute = 0;
        return .{ .timestamp = timestamp, .forcing = .{
            .air_temperature_c = self.air_temperature_c / sample_count,
            .vapor_pressure_kpa = self.vapor_pressure_kpa / sample_count,
            .precipitation_m = self.precipitation_m,
            .rainfall_m = self.rainfall_m,
            .snowfall_water_equivalent_m = self.snowfall_water_equivalent_m,
            .shortwave_radiation_megajoules_per_m2 = self.shortwave_radiation_megajoules_per_m2 / sample_count,
            .wind_speed_m_per_h = self.wind_speed_m_per_h / sample_count,
            .longwave_radiation_megajoules_per_m2 = if (self.longwave_radiation_megajoules_per_m2) |value| value / sample_count else null,
        } };
    }
};

test "subhour samples aggregate without subhour model cycles" {
    const timestamp: weather.Timestamp = .{ .year = 2001, .day_of_year = 2, .month = null, .day_of_month = null, .hour = 3, .minute = 0 };
    const first: Observation = .{ .timestamp = timestamp, .forcing = .{ .air_temperature_c = 2, .vapor_pressure_kpa = 1, .precipitation_m = 0.001, .rainfall_m = 0.001, .shortwave_radiation_megajoules_per_m2 = 0.2, .wind_speed_m_per_h = 3600, .longwave_radiation_megajoules_per_m2 = 0.1 } };
    var accumulator = HourAccumulator.init(first);
    try accumulator.add(.{ .air_temperature_c = 6, .vapor_pressure_kpa = 3, .precipitation_m = 0.002, .snowfall_water_equivalent_m = 0.002, .shortwave_radiation_megajoules_per_m2 = 0.6, .wind_speed_m_per_h = 7200, .longwave_radiation_megajoules_per_m2 = 0.3 });
    const result = accumulator.finish();
    try std.testing.expectEqual(@as(u8, 0), result.timestamp.minute);
    try std.testing.expectApproxEqAbs(@as(f64, 4), result.forcing.air_temperature_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), result.forcing.precipitation_m, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001), result.forcing.rainfall_m, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.002), result.forcing.snowfall_water_equivalent_m, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), result.forcing.shortwave_radiation_megajoules_per_m2, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5400), result.forcing.wind_speed_m_per_h, 1e-12);
}

test "READS three-hour infill interpolates state and conserves precipitation" {
    const previous: Observation = .{
        .timestamp = .{ .year = null, .day_of_year = 1, .month = null, .day_of_month = null, .hour = 3, .minute = 0 },
        .forcing = .{ .air_temperature_c = -2, .vapor_pressure_kpa = 1, .precipitation_m = 0, .shortwave_radiation_megajoules_per_m2 = 0, .wind_speed_m_per_h = 3600, .longwave_radiation_megajoules_per_m2 = 1 },
    };
    const current: Observation = .{
        .timestamp = .{ .year = null, .day_of_year = 1, .month = null, .day_of_month = null, .hour = 6, .minute = 0 },
        .forcing = .{ .air_temperature_c = 1, .vapor_pressure_kpa = 4, .precipitation_m = 0.003, .rainfall_m = 0.003, .shortwave_radiation_megajoules_per_m2 = 3, .wind_speed_m_per_h = 7200, .longwave_radiation_megajoules_per_m2 = 4 },
    };
    const first = try expandThreeHour(previous, current, 0, .{});
    const second = try expandThreeHour(previous, current, 1, .{});
    const third = try expandThreeHour(previous, current, 2, .{});
    try std.testing.expectEqual(@as(u8, 4), first.timestamp.hour);
    try std.testing.expectEqual(@as(u8, 5), second.timestamp.hour);
    try std.testing.expectEqual(@as(u8, 6), third.timestamp.hour);
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), first.forcing.precipitation_m + second.forcing.precipitation_m + third.forcing.precipitation_m, 1e-15);
    try std.testing.expect(first.forcing.snowfall_water_equivalent_m > 0);
    try std.testing.expect(second.forcing.rainfall_m > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 1), third.forcing.air_temperature_c, 1e-15);
}
