const std = @import("std");
const HourlyForcing = @import("../io/input/weather.zig").HourlyForcing;
const Timestamp = @import("../io/input/weather.zig").Timestamp;
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");
const sky_radiative_properties = @import("sky_radiative_properties.zig");

pub const Result = struct {
    forcing: HourlyForcing,
    solar_angle_sine: f64,
    next_hour_solar_angle_sine: f64,
    solar_azimuth_radians: f64,
    extraterrestrial_shortwave_megajoules_per_m2: f64,
    cloudiness_fraction: f64,
    sky_emissivity: f64,
};

pub fn prepare(forcing: HourlyForcing, timestamp: Timestamp, latitude_degrees_north: f64, solar_noon_hour: f64, phytotron: bool) !Result {
    const day = try validateRadiationDay(timestamp);
    if (!std.math.isFinite(latitude_degrees_north) or latitude_degrees_north < -90 or latitude_degrees_north > 90 or !std.math.isFinite(solar_noon_hour)) return error.InvalidRadiationGeometry;
    const air_temperature_k = forcing.air_temperature_c + 273.15;
    if (!std.math.isFinite(air_temperature_k) or air_temperature_k <= 0 or !std.math.isFinite(forcing.vapor_pressure_kpa) or forcing.vapor_pressure_kpa < 0) return error.InvalidRadiationForcing;
    var adjusted = forcing;
    var solar_sine: f64 = 0;
    var next_sine: f64 = 0;
    var extraterrestrial: f64 = 0;
    var solar_azimuth_radians: f64 = 0;
    var cloudiness: f64 = 0;
    var emissivity: f64 = 0;
    if (!phytotron) {
        const geometry = solarGeometry(day, latitude_degrees_north);
        const hour: f64 = @as(f64, @floatFromInt(timestamp.hour)) + @as(f64, @floatFromInt(timestamp.minute)) / 60.0;
        solar_azimuth_radians = (std.math.pi / 12.0) * (solar_noon_hour - hour) + 3.0 * std.math.pi / 2.0;
        solar_sine = @max(0.0, geometry.azimuth_component + geometry.declination_component * @cos(0.2618 * (solar_noon_hour - (hour - 0.5))));
        next_sine = @max(0.0, geometry.azimuth_component + geometry.declination_component * @cos(0.2618 * (solar_noon_hour - (hour + 0.5))));
        if (adjusted.shortwave_radiation_megajoules_per_m2 <= 0) solar_sine = 0;
        extraterrestrial = 4.896 * @max(0.0, solar_sine);
        adjusted.shortwave_radiation_megajoules_per_m2 = @min(extraterrestrial, adjusted.shortwave_radiation_megajoules_per_m2);
        const sky = try sky_radiative_properties.derive(.{
            .outdoors = true,
            .extraterrestrial_shortwave_megajoules_per_m2_h = extraterrestrial,
            .incoming_shortwave_megajoules_per_m2_h = adjusted.shortwave_radiation_megajoules_per_m2,
            .atmospheric_vapor_pressure_kpa = forcing.vapor_pressure_kpa,
            .air_temperature_k = air_temperature_k,
        });
        cloudiness = sky.cloudiness_fraction;
        emissivity = sky.sky_emissivity_fraction;
    } else {
        solar_sine = if (adjusted.shortwave_radiation_megajoules_per_m2 > 0) 1 else 0;
        next_sine = 1;
        const sky = try sky_radiative_properties.derive(.{
            .outdoors = false,
            .extraterrestrial_shortwave_megajoules_per_m2_h = 0,
            .incoming_shortwave_megajoules_per_m2_h = 0,
            .atmospheric_vapor_pressure_kpa = forcing.vapor_pressure_kpa,
            .air_temperature_k = air_temperature_k,
        });
        cloudiness = sky.cloudiness_fraction;
        emissivity = sky.sky_emissivity_fraction;
    }
    adjusted.longwave_radiation_megajoules_per_m2 = if (forcing.longwave_radiation_megajoules_per_m2) |observed|
        if (observed > 0) observed else emissivity * 2.04e-10 * std.math.pow(f64, air_temperature_k, 4)
    else
        emissivity * 2.04e-10 * std.math.pow(f64, air_temperature_k, 4);
    try validate(adjusted);
    return .{
        .forcing = adjusted,
        .solar_angle_sine = solar_sine,
        .next_hour_solar_angle_sine = next_sine,
        .solar_azimuth_radians = solar_azimuth_radians,
        .extraterrestrial_shortwave_megajoules_per_m2 = extraterrestrial,
        .cloudiness_fraction = cloudiness,
        .sky_emissivity = emissivity,
    };
}

fn validateRadiationDay(timestamp: Timestamp) !u16 {
    const day = timestamp.day_of_year orelse
        return error.RadiationRequiresDayOfYear;
    const maximum_day: u16 = if (timestamp.year) |year| maximum: {
        if (year == 0) return error.InvalidRadiationGeometry;
        break :maximum if (execution_calendar_date.isLeapYear(year)) 366 else 365;
    } else 366;
    if (day == 0 or day > maximum_day) return error.InvalidRadiationGeometry;
    return day;
}

fn solarGeometry(day_of_year: u16, latitude_degrees: f64) struct { azimuth_component: f64, declination_component: f64 } {
    const effective_day = if (day_of_year == 366) 365.5 else @as(f64, @floatFromInt(day_of_year));
    const declination_degrees = @sin((effective_day + 100.0) * 0.9863 * 1.7453e-2) * -23.47;
    const latitude = latitude_degrees * 1.7453e-2;
    const declination = declination_degrees * 1.7453e-2;
    return .{ .azimuth_component = @sin(latitude) * @sin(declination), .declination_component = @cos(latitude) * @cos(declination) };
}

fn validate(forcing: HourlyForcing) !void {
    inline for (@typeInfo(HourlyForcing).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(forcing, field.name))) return error.NonFiniteAtmosphericRadiation;
    if (forcing.shortwave_radiation_megajoules_per_m2 < 0 or forcing.longwave_radiation_megajoules_per_m2.? < 0) return error.InvalidAtmosphericRadiation;
}

test "outdoor radiation is capped and longwave is finite" {
    const forcing: HourlyForcing = .{ .air_temperature_c = 20, .vapor_pressure_kpa = 1, .precipitation_m = 0, .shortwave_radiation_megajoules_per_m2 = 100, .wind_speed_m_per_h = 3600, .longwave_radiation_megajoules_per_m2 = null };
    const result = try prepare(forcing, .{ .year = 2024, .day_of_year = 180, .month = null, .day_of_month = null, .hour = 12, .minute = 0 }, 53.69, 12, false);
    try std.testing.expect(result.forcing.shortwave_radiation_megajoules_per_m2 <= result.extraterrestrial_shortwave_megajoules_per_m2);
    try std.testing.expect(result.forcing.longwave_radiation_megajoules_per_m2.? > 0);
}

test "observed longwave is retained" {
    const forcing: HourlyForcing = .{ .air_temperature_c = 5, .vapor_pressure_kpa = 0.5, .precipitation_m = 0, .shortwave_radiation_megajoules_per_m2 = 0, .wind_speed_m_per_h = 3600, .longwave_radiation_megajoules_per_m2 = 0.8 };
    const result = try prepare(forcing, .{ .year = null, .day_of_year = 1, .month = null, .day_of_month = null, .hour = 1, .minute = 0 }, 81.8, 12, false);
    try std.testing.expectEqual(@as(f64, 0.8), result.forcing.longwave_radiation_megajoules_per_m2.?);
}

test "radiation dates preserve DAY modulo-four chronology" {
    try std.testing.expectEqual(
        @as(u16, 366),
        try validateRadiationDay(.{ .year = 1900, .day_of_year = 366, .month = null, .day_of_month = null, .hour = 1, .minute = 0 }),
    );
    try std.testing.expectError(
        error.InvalidRadiationGeometry,
        validateRadiationDay(.{ .year = 1901, .day_of_year = 366, .month = null, .day_of_month = null, .hour = 1, .minute = 0 }),
    );
    try std.testing.expectError(
        error.InvalidRadiationGeometry,
        validateRadiationDay(.{ .year = 0, .day_of_year = 1, .month = null, .day_of_month = null, .hour = 1, .minute = 0 }),
    );
    try std.testing.expectEqual(
        @as(u16, 366),
        try validateRadiationDay(.{ .year = null, .day_of_year = 366, .month = null, .day_of_month = null, .hour = 1, .minute = 0 }),
    );
}

test "sky properties still match the literal wthr.f arithmetic after extraction" {
    // `wthr.f:243--252` (outdoor) and `wthr.f:259--261` (phytotron):
    //   CLD = AMIN1(1.0,AMAX1(0.2,2.33-3.33*RADN/RADZ))   [RADZ>ZERO]
    //   CLD = 0.2                                          [otherwise]
    //   EMM = 0.625*AMAX1(1.0,(1.0E+03*VPK/TKA)**0.131)
    //   EMM = EMM*(1.0+0.242*CLD**0.583)
    //   phytotron: CLD = 0.0, EMM = 0.97
    //
    // This module used to compute CLD and EMM inline while
    // `atmosphere/sky_radiative_properties.zig` held the same arithmetic as an
    // unbound module; the duplicate-owner screen flagged the pair at score 2.56
    // / jaccard 0.35. The inline copy was deleted and the named owner is now
    // the single production owner.
    //
    // Deliberately compared against the source expression written out here,
    // NOT against a second call into the owner. Calling the owner again would
    // be tautological now that `prepare` delegates to it: it would pass no
    // matter what either side computed. Restating the Fortran is what makes
    // this guard able to fail.
    //
    // Cases span all three CLD branches (the AMAX1 floor, the interior linear
    // regime, the AMIN1 ceiling), the RADZ<=ZERO dark hour, and the phytotron
    // branch.
    const cases = [_]struct { f64, f64, f64, u8, bool }{
        .{ 20, 1.0, 100, 12, false }, // capped at RADZ: CLD hits the 0.2 floor
        .{ 20, 1.0, 2.2, 12, false }, // interior linear regime
        .{ 20, 1.0, 0.05, 12, false }, // near-dark daytime: CLD hits the 1.0 ceiling
        .{ -5, 0.2, 0, 0, false }, // night: RADZ = 0, dark-hour branch
        .{ 20, 1.0, 2.0, 12, true }, // phytotron: fixed CLD = 0, EMM = 0.97
    };
    for (cases) |case| {
        const forcing: HourlyForcing = .{
            .air_temperature_c = case[0],
            .vapor_pressure_kpa = case[1],
            .precipitation_m = 0,
            .shortwave_radiation_megajoules_per_m2 = case[2],
            .wind_speed_m_per_h = 3600,
            .longwave_radiation_megajoules_per_m2 = null,
        };
        const result = try prepare(forcing, .{ .year = 2024, .day_of_year = 180, .month = null, .day_of_month = null, .hour = case[3], .minute = 0 }, 53.69, 12, case[4]);

        var expected_cloudiness: f64 = undefined;
        var expected_emissivity: f64 = undefined;
        if (case[4]) {
            expected_cloudiness = 0.0;
            expected_emissivity = 0.97;
        } else {
            // RADN is capped at RADZ before CLD is formed (`wthr.f:235`), so
            // read the capped value back out of the result.
            const radz = result.extraterrestrial_shortwave_megajoules_per_m2;
            const radn = result.forcing.shortwave_radiation_megajoules_per_m2;
            expected_cloudiness = if (radz > 0)
                @min(1.0, @max(0.2, 2.33 - 3.33 * radn / radz))
            else
                0.2;
            const air_temperature_k = case[0] + 273.15;
            expected_emissivity = 0.625 * @max(1.0, std.math.pow(f64, 1.0e3 * case[1] / air_temperature_k, 0.131));
            expected_emissivity *= 1.0 + 0.242 * std.math.pow(f64, expected_cloudiness, 0.583);
        }
        try std.testing.expectEqual(expected_cloudiness, result.cloudiness_fraction);
        try std.testing.expectEqual(expected_emissivity, result.sky_emissivity);
    }
}

test "cloudiness branches are actually all exercised by the substitution guard" {
    // Falsifiability companion to the guard above: assert the case list really
    // reaches the floor, the interior, and the ceiling. Without this, a change
    // to the geometry or to RADZ could collapse every case onto one branch and
    // the equivalence guard would still pass while testing almost nothing.
    var saw_floor = false;
    var saw_interior = false;
    var saw_ceiling = false;
    const shortwave = [_]f64{ 100, 2.2, 0.05 };
    for (shortwave) |value| {
        const forcing: HourlyForcing = .{
            .air_temperature_c = 20,
            .vapor_pressure_kpa = 1.0,
            .precipitation_m = 0,
            .shortwave_radiation_megajoules_per_m2 = value,
            .wind_speed_m_per_h = 3600,
            .longwave_radiation_megajoules_per_m2 = null,
        };
        const result = try prepare(forcing, .{ .year = 2024, .day_of_year = 180, .month = null, .day_of_month = null, .hour = 12, .minute = 0 }, 53.69, 12, false);
        if (result.cloudiness_fraction == 0.2) saw_floor = true;
        if (result.cloudiness_fraction == 1.0) saw_ceiling = true;
        if (result.cloudiness_fraction > 0.2 and result.cloudiness_fraction < 1.0) saw_interior = true;
    }
    try std.testing.expect(saw_floor);
    try std.testing.expect(saw_interior);
    try std.testing.expect(saw_ceiling);
}
