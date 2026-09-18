const std = @import("std");
const solar_daylength = @import("../../atmosphere/solar_daylength.zig");
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");
const DailyForcing = @import("weather.zig").DailyForcing;
const HourlyForcing = @import("weather.zig").HourlyForcing;

const PrecipitationPhase = @import("weather.zig").PrecipitationPhase;

pub const Result = struct {
    forcing: HourlyForcing,
    rainfall_m: f64,
    snowfall_m: f64,
    daylength_h: f64,
};

/// Exact daily-weather curve equations from DAY.F and WTHR.F. The caller
/// supplies adjacent days; at a file boundary it should repeat the current
/// day, matching the reference boundary behavior.
pub fn disaggregateHour(previous: DailyForcing, current: DailyForcing, next: DailyForcing, day_of_year: u16, execution_year: u16, hour: u8, latitude_degrees_north: f64, solar_noon_hour: f64, altitude_m: f64, phytotron: bool) !Result {
    return disaggregateHourWithPhase(previous, current, next, day_of_year, execution_year, hour, latitude_degrees_north, solar_noon_hour, altitude_m, phytotron, .{});
}

pub fn disaggregateHourWithPhase(previous: DailyForcing, current: DailyForcing, next: DailyForcing, day_of_year: u16, execution_year: u16, hour: u8, latitude_degrees_north: f64, solar_noon_hour: f64, altitude_m: f64, phytotron: bool, phase: PrecipitationPhase) !Result {
    try phase.validate();
    _ = execution_calendar_date.fromDayOfYear(
        day_of_year,
        execution_year,
    ) catch return error.InvalidDailyWeatherTime;
    if (hour < 1 or hour > 24) return error.InvalidDailyWeatherTime;
    if (!std.math.isFinite(latitude_degrees_north) or latitude_degrees_north < -90 or latitude_degrees_north > 90 or !std.math.isFinite(solar_noon_hour) or !std.math.isFinite(altitude_m)) return error.InvalidDailyWeatherGeometry;
    const daylength_h = calculateDaylength(day_of_year, latitude_degrees_north);
    const maximum_radiation = if (phytotron)
        current.shortwave_radiation_megajoules_per_m2_per_day
    else if (daylength_h > 0)
        current.shortwave_radiation_megajoules_per_m2_per_day / (daylength_h * 0.658)
    else
        0.0;
    const hour_f: f64 = @floatFromInt(hour);
    const shortwave = if (phytotron)
        maximum_radiation / 24.0
    else if (daylength_h > 0)
        @max(0.0, maximum_radiation * @sin((hour_f - (solar_noon_hour - daylength_h / 2.0)) * 3.1416 / daylength_h))
    else
        0.0;

    const temperature_curve = curveParameters(
        previous.maximum_air_temperature_c,
        current.maximum_air_temperature_c,
        current.minimum_air_temperature_c,
        next.minimum_air_temperature_c,
    );
    const vapor_curve = curveParameters(
        previous.mean_vapor_pressure_kpa,
        current.mean_vapor_pressure_kpa,
        current.saturation_vapor_pressure_at_minimum_kpa,
        next.saturation_vapor_pressure_at_minimum_kpa,
    );
    const temperature_c = curveValue(temperature_curve, hour_f, solar_noon_hour, daylength_h);
    const raw_vapor = curveValue(vapor_curve, hour_f, solar_noon_hour, daylength_h);
    const saturation = 0.61 * @exp(5360.0 * (0.003661 - 1.0 / (273.15 + temperature_c))) * @exp(-altitude_m / 7272.0);
    const precipitation = if (hour >= 13 and hour <= 16) current.precipitation_m_per_day / 4.0 else 0.0;
    var rainfall: f64 = 0;
    var snowfall: f64 = 0;
    if (temperature_c > phase.snowfall_temperature_threshold_c) rainfall = precipitation else {
        snowfall = precipitation;
        if (snowfall < phase.minimum_snowfall_water_equivalent_m) snowfall = 0;
    }
    const forcing: HourlyForcing = .{
        .air_temperature_c = temperature_c,
        .vapor_pressure_kpa = @min(saturation, raw_vapor),
        .precipitation_m = rainfall + snowfall,
        .rainfall_m = rainfall,
        .snowfall_water_equivalent_m = snowfall,
        .shortwave_radiation_megajoules_per_m2 = shortwave,
        .wind_speed_m_per_h = @max(3600.0, current.wind_speed_m_per_h),
        .longwave_radiation_megajoules_per_m2 = null,
    };
    try validate(forcing);
    return .{ .forcing = forcing, .rainfall_m = rainfall, .snowfall_m = snowfall, .daylength_h = daylength_h };
}

const Curve = struct { average_before: f64, average_current: f64, average_after: f64, amplitude_before: f64, amplitude_current: f64, amplitude_after: f64 };

fn curveParameters(previous_max_or_mean: f64, current_max_or_mean: f64, current_minimum: f64, next_minimum: f64) Curve {
    const average_before = 0.5 * (previous_max_or_mean + current_minimum);
    const average_current = 0.5 * (current_max_or_mean + current_minimum);
    const average_after = 0.5 * (current_max_or_mean + next_minimum);
    return .{
        .average_before = average_before,
        .average_current = average_current,
        .average_after = average_after,
        .amplitude_before = average_before - current_minimum,
        .amplitude_current = average_current - current_minimum,
        .amplitude_after = average_after - next_minimum,
    };
}

fn curveValue(curve: Curve, hour: f64, solar_noon: f64, daylength: f64) f64 {
    const sunrise = solar_noon - daylength / 2.0;
    const denominator = solar_noon + 9.0 - daylength / 2.0;
    if (hour < sunrise) return curve.average_before + curve.amplitude_before * @sin((hour + solar_noon - 3.0) * 3.1416 / denominator + 1.5708);
    if (hour > solar_noon + 3.0) return curve.average_after + curve.amplitude_after * @sin((hour - solar_noon - 3.0) * 3.1416 / denominator + 1.5708);
    return curve.average_current + curve.amplitude_current * @sin((hour - sunrise) * 3.1416 / (3.0 + daylength / 2.0) - 1.5708);
}

/// `day.f:207--218` daylength. This used to be a second, private copy of that
/// block living beside the named owner in `atmosphere/solar_daylength.zig`,
/// which production never called. It now delegates, so there is exactly one
/// copy of the arithmetic in the tree. Kept as a wrapper because
/// `src/ecosys_ng.zig` calls it by this name in three places.
pub fn calculateDaylength(day_of_year: u16, latitude_degrees: f64) f64 {
    return solar_daylength.hours(day_of_year, latitude_degrees, .{});
}

fn validate(forcing: HourlyForcing) !void {
    inline for (@typeInfo(HourlyForcing).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(forcing, field.name))) return error.NonFiniteDisaggregatedWeather;
    if (forcing.air_temperature_c < -273.15 or forcing.vapor_pressure_kpa < 0 or forcing.precipitation_m < 0 or forcing.shortwave_radiation_megajoules_per_m2 < 0 or forcing.wind_speed_m_per_h < 0) return error.InvalidDisaggregatedWeather;
}

test "daily precipitation is assigned to reference hours and conserved when rain" {
    const day: DailyForcing = .{
        .maximum_air_temperature_c = 20,
        .minimum_air_temperature_c = 10,
        .mean_vapor_pressure_kpa = 1,
        .saturation_vapor_pressure_at_minimum_kpa = 1.2,
        .precipitation_m_per_day = 0.02,
        .shortwave_radiation_megajoules_per_m2_per_day = 12,
        .wind_speed_m_per_h = 100,
    };
    var total: f64 = 0;
    for (1..25) |hour| total += (try disaggregateHour(day, day, day, 180, 2000, @intCast(hour), 53.69, 12, 645, false)).rainfall_m;
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), total, 1.0e-12);
}

test "hourly shortwave follows the WTHR sine curve about solar noon" {
    // Duplicate-owner guard for atmosphere/daily_shortwave_curve, which
    // translates the same two branches of wthr.f:96-104. This evaluator is the
    // reachable owner (root -> hourly_weather_stream -> disaggregateHour), so
    // that module must not also be bound.
    //
    // Restated from the Fortran rather than by calling the candidate module, so
    // deleting or dispositioning it cannot make this guard tautological:
    //     RMAX = SRAD/(DYLN*0.658)                              day.f:251
    //     RADN = AMAX1(0.0, RMAX*SIN((J-(ZNOON-DYLN/2))*3.1416/DYLN))
    //                                                           wthr.f:98-99
    const day: DailyForcing = .{
        .maximum_air_temperature_c = 20,
        .minimum_air_temperature_c = 10,
        .mean_vapor_pressure_kpa = 1,
        .saturation_vapor_pressure_at_minimum_kpa = 1.2,
        .precipitation_m_per_day = 0,
        .shortwave_radiation_megajoules_per_m2_per_day = 12,
        .wind_speed_m_per_h = 100,
    };
    const solar_noon_hour: f64 = 12;
    const daylength_h = calculateDaylength(180, 53.69);
    const peak = day.shortwave_radiation_megajoules_per_m2_per_day /
        (daylength_h * 0.658);
    const sunrise = solar_noon_hour - daylength_h / 2.0;

    for (1..25) |hour| {
        const hour_f: f64 = @floatFromInt(hour);
        const expected = @max(0.0, peak *
            @sin((hour_f - sunrise) * 3.1416 / daylength_h));
        const result = try disaggregateHour(
            day,
            day,
            day,
            180,
            2000,
            @intCast(hour),
            53.69,
            solar_noon_hour,
            645,
            false,
        );
        try std.testing.expectApproxEqRel(
            expected,
            result.forcing.shortwave_radiation_megajoules_per_m2,
            1e-12,
        );
    }

    // Phytotron branch: wthr.f:104 RADN = RMAX/24 with RMAX = SRAD unscaled,
    // i.e. flat over the full 24 h rather than the sine curve above.
    const flat = try disaggregateHour(day, day, day, 180, 2000, 3, 53.69, solar_noon_hour, 645, true);
    try std.testing.expectApproxEqRel(
        day.shortwave_radiation_megajoules_per_m2_per_day / 24.0,
        flat.forcing.shortwave_radiation_megajoules_per_m2,
        1e-12,
    );

    // Falsifiability companion: the sine loop only constrains anything because
    // the curve is not flat and does clamp at night. Without these the
    // assertions above would also pass for a constant or an unclamped negative.
    const pre_dawn = try disaggregateHour(day, day, day, 180, 2000, 1, 53.69, solar_noon_hour, 645, false);
    const at_noon = try disaggregateHour(day, day, day, 180, 2000, 12, 53.69, solar_noon_hour, 645, false);
    try std.testing.expectEqual(@as(f64, 0), pre_dawn.forcing.shortwave_radiation_megajoules_per_m2);
    try std.testing.expect(at_noon.forcing.shortwave_radiation_megajoules_per_m2 > 0);
    try std.testing.expect(at_noon.forcing.shortwave_radiation_megajoules_per_m2 !=
        flat.forcing.shortwave_radiation_megajoules_per_m2);
}

test "phytotron sites still use the true geometric daylength, not a pinned 24 h" {
    // day.f:206-219 / wthr.f:96 (IETYP.NE.-2 gates RADN only) / readi.f:233-255
    // (DYLM) never condition daylength itself on IETYP/phytotron -- only the
    // RMAX/RADN radiation formula is phytotron-special-cased. Regression guard
    // for a prior mistranslation that hard-coded daylength_h = 24 for
    // phytotron sites, which silently defeated DYLN-vs-DYLX/DYLM
    // photoperiod/vernalization comparisons in hfunc.f for those sites.
    const day: DailyForcing = .{
        .maximum_air_temperature_c = 20,
        .minimum_air_temperature_c = 10,
        .mean_vapor_pressure_kpa = 1,
        .saturation_vapor_pressure_at_minimum_kpa = 1.2,
        .precipitation_m_per_day = 0,
        .shortwave_radiation_megajoules_per_m2_per_day = 12,
        .wind_speed_m_per_h = 100,
    };
    const expected = calculateDaylength(180, 53.69);
    // A latitude/day-of-year chosen so the true geometric daylength is not 24,
    // so this test cannot pass by accident if the pin regresses.
    try std.testing.expect(expected != 24.0);
    const phytotron_result = try disaggregateHour(day, day, day, 180, 2000, 12, 53.69, 12, 645, true);
    try std.testing.expectEqual(expected, phytotron_result.daylength_h);
}

test "hourly air temperature follows the WTHR three-segment diurnal curve" {
    // Duplicate-owner guard for atmosphere/daily_diurnal_curve, which
    // translates the same three branches of wthr.f:109-118. This evaluator is
    // the reachable owner (root -> hourly_weather_stream -> disaggregateHour),
    // so that module must not also be bound.
    //
    // Restated from the Fortran rather than by calling the candidate module:
    //     TAVG2 = (TMPX+TMPN)/2, AMP2 = TAVG2-TMPN            day.f:264,268
    //     J < ZNOON-DYLN/2:
    //       TCA = TAVG1+AMP1*SIN((J+ZNOON-3)*3.1416
    //                            /(ZNOON+9-DYLN/2)+1.5708)    wthr.f:110-111
    //     J > ZNOON+3:
    //       TCA = TAVG3+AMP3*SIN((J-ZNOON-3)*3.1416
    //                            /(ZNOON+9-DYLN/2)+1.5708)    wthr.f:113-114
    //     otherwise:
    //       TCA = TAVG2+AMP2*SIN((J-(ZNOON-DYLN/2))*3.1416
    //                            /(3+DYLN/2)-1.5708)          wthr.f:116-117
    //
    // Using one repeated day makes TAVG1=TAVG2=TAVG3 and AMP1=AMP2=AMP3, so a
    // single pair of coefficients covers all three segments; the segment
    // selection itself is still exercised because the three formulas differ.
    const maximum_c: f64 = 20;
    const minimum_c: f64 = 10;
    const day: DailyForcing = .{
        .maximum_air_temperature_c = maximum_c,
        .minimum_air_temperature_c = minimum_c,
        .mean_vapor_pressure_kpa = 1,
        .saturation_vapor_pressure_at_minimum_kpa = 1.2,
        .precipitation_m_per_day = 0,
        .shortwave_radiation_megajoules_per_m2_per_day = 12,
        .wind_speed_m_per_h = 100,
    };
    const average = (maximum_c + minimum_c) / 2.0;
    const amplitude = average - minimum_c;
    const solar_noon_hour: f64 = 12;
    const daylength_h = calculateDaylength(180, 53.69);
    const sunrise = solar_noon_hour - daylength_h / 2.0;
    const night_denominator = solar_noon_hour + 9.0 - daylength_h / 2.0;

    var saw_before = false;
    var saw_current = false;
    var saw_after = false;
    for (1..25) |hour| {
        const hour_f: f64 = @floatFromInt(hour);
        const expected = if (hour_f < sunrise) blk: {
            saw_before = true;
            break :blk average + amplitude *
                @sin((hour_f + solar_noon_hour - 3.0) * 3.1416 /
                    night_denominator + 1.5708);
        } else if (hour_f > solar_noon_hour + 3.0) blk: {
            saw_after = true;
            break :blk average + amplitude *
                @sin((hour_f - solar_noon_hour - 3.0) * 3.1416 /
                    night_denominator + 1.5708);
        } else blk: {
            saw_current = true;
            break :blk average + amplitude *
                @sin((hour_f - sunrise) * 3.1416 /
                    (3.0 + daylength_h / 2.0) - 1.5708);
        };
        const result = try disaggregateHour(
            day,
            day,
            day,
            180,
            2000,
            @intCast(hour),
            53.69,
            solar_noon_hour,
            645,
            false,
        );
        try std.testing.expectApproxEqRel(
            expected,
            result.forcing.air_temperature_c,
            1e-12,
        );
    }

    // Falsifiability companion: the loop above would be vacuous if the fixture
    // exercised only one branch, or if the curve were flat. Require all three
    // segments to have been taken, and require the day to actually vary.
    try std.testing.expect(saw_before);
    try std.testing.expect(saw_current);
    try std.testing.expect(saw_after);
    const dawn = try disaggregateHour(day, day, day, 180, 2000, 6, 53.69, solar_noon_hour, 645, false);
    const afternoon = try disaggregateHour(day, day, day, 180, 2000, 15, 53.69, solar_noon_hour, 645, false);
    try std.testing.expect(afternoon.forcing.air_temperature_c >
        dawn.forcing.air_temperature_c);
}

test "polar day and night remain finite" {
    const day: DailyForcing = .{ .maximum_air_temperature_c = -5, .minimum_air_temperature_c = -15, .mean_vapor_pressure_kpa = 0.2, .saturation_vapor_pressure_at_minimum_kpa = 0.1, .precipitation_m_per_day = 0, .shortwave_radiation_megajoules_per_m2_per_day = 5, .wind_speed_m_per_h = 0 };
    const summer = try disaggregateHour(day, day, day, 180, 2000, 12, 81.8, 12, 290, false);
    const winter = try disaggregateHour(day, day, day, 1, 2000, 12, 81.8, 12, 290, false);
    try std.testing.expectEqual(@as(f64, 24), summer.daylength_h);
    try std.testing.expectEqual(@as(f64, 0), winter.daylength_h);
}

test "daily disaggregation preserves DAY modulo-four chronology" {
    const day: DailyForcing = .{ .maximum_air_temperature_c = 5, .minimum_air_temperature_c = -5, .mean_vapor_pressure_kpa = 0.2, .saturation_vapor_pressure_at_minimum_kpa = 0.1, .precipitation_m_per_day = 0, .shortwave_radiation_megajoules_per_m2_per_day = 5, .wind_speed_m_per_h = 3600 };
    _ = try disaggregateHour(day, day, day, 366, 1900, 12, 53.5, 12, 645, false);
    try std.testing.expectError(
        error.InvalidDailyWeatherTime,
        disaggregateHour(day, day, day, 366, 1901, 12, 53.5, 12, 645, false),
    );
}

test "production daylength entry point reproduces day.f:207-218 literally" {
    // Restates the Fortran arithmetic inline rather than calling
    // `solar_daylength.hours`. Calling the delegated-to module would make this
    // a tautology: both sides would run the same code and no edit to the
    // arithmetic could fail it.
    //
    //   IF(I.EQ.366)XI=365.5
    //   DECDAY=XI+100
    //   DECLIN=SIN((DECDAY*0.9863)*1.7453E-02)*(-23.47)
    //   AZI=SIN(LAT*RAD)*SIN(DECLIN*RAD)
    //   DEC=COS(LAT*RAD)*COS(DECLIN*RAD)
    //   IF(AZI/DEC.GE.1.0-TWILGT) DYLN=24.0
    //   ELSEIF(AZI/DEC.LE.-1.0+TWILGT) DYLN=0.0
    //   ELSE DYLN=12.0*(1.0+2.0/3.1416*ASIN(TWILGT+AZI/DEC))
    const twilgt = 0.06976;
    const rad = 1.7453e-2;

    const Case = struct { day: u16, latitude: f64 };
    const cases = [_]Case{
        .{ .day = 100, .latitude = 0 }, // equator, interior branch
        .{ .day = 172, .latitude = 53.69 }, // Ottawa-like summer, interior
        .{ .day = 355, .latitude = 53.69 }, // northern winter, interior
        .{ .day = 172, .latitude = 80 }, // polar day, 24 h branch
        .{ .day = 355, .latitude = 80 }, // polar night, 0 h branch
        .{ .day = 366, .latitude = 53.5 }, // leap-day XI=365.5 substitution
        .{ .day = 1, .latitude = -35 }, // southern hemisphere
    };

    var saw_polar_day = false;
    var saw_polar_night = false;
    var saw_interior = false;
    var saw_leap = false;

    for (cases) |c| {
        const xi: f64 = if (c.day == 366) 365.5 else @floatFromInt(c.day);
        const decday = xi + 100.0;
        const declin = @sin((decday * 0.9863) * rad) * (-23.47);
        const azi = @sin(c.latitude * rad) * @sin(declin * rad);
        const dec = @cos(c.latitude * rad) * @cos(declin * rad);
        const quotient = azi / dec;

        var expected: f64 = undefined;
        if (quotient >= 1.0 - twilgt) {
            expected = 24.0;
            saw_polar_day = true;
        } else if (quotient <= -1.0 + twilgt) {
            expected = 0.0;
            saw_polar_night = true;
        } else {
            expected = 12.0 * (1.0 + 2.0 / 3.1416 *
                std.math.asin(twilgt + quotient));
            saw_interior = true;
        }
        if (c.day == 366) saw_leap = true;

        const actual = calculateDaylength(c.day, c.latitude);
        std.testing.expectApproxEqAbs(expected, actual, 1e-12) catch |err| {
            std.debug.print(
                "daylength mismatch: day={d} lat={d} expected={d} actual={d}\n",
                .{ c.day, c.latitude, expected, actual },
            );
            return err;
        };
    }

    // Falsifiability companion: prove the case list actually reaches every
    // branch of the source expression. Without this, all seven cases could
    // land on one branch and the equivalence above would be nearly vacuous.
    try std.testing.expect(saw_polar_day);
    try std.testing.expect(saw_polar_night);
    try std.testing.expect(saw_interior);
    try std.testing.expect(saw_leap);
}

test "production daylength is the named owner, not an independent copy" {
    // Structural pin: if someone reintroduces a private copy in this file,
    // this equality still holds, so it is deliberately NOT the correctness
    // guard above. What it pins is that the owner is reachable from the
    // production entry point at all -- delete the delegation and this fails
    // to compile.
    try std.testing.expectEqual(
        solar_daylength.hours(172, 53.69, .{}),
        calculateDaylength(172, 53.69),
    );
}
