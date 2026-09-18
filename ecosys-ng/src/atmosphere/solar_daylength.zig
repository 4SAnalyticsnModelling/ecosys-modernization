const std = @import("std");
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");

pub const State = struct {
    previous_daylength_h: f64,
    current_daylength_h: f64,
};

pub const Parameters = struct {
    civil_twilight_sine: f64 = 0.06976,
    degrees_to_radians: f64 = 1.7453e-2,
    orbital_degrees_per_day: f64 = 0.9863,
    declination_amplitude_degrees: f64 = -23.47,
    declination_phase_days: f64 = 100,
    pi: f64 = 3.1416,
};

/// Pure `day.f:207--218` daylength geometry, with no state and no
/// validation, so callers that already own their own validation can reach the
/// same arithmetic. `update` is this function plus the DAY state rotation.
///
/// Returns hours in [0, 24]. The 24 and 0 results are the source's exact polar
/// day and polar night branches, not clamps.
pub fn hours(
    day_of_year: u16,
    latitude_degrees_north: f64,
    parameters: Parameters,
) f64 {
    const orbital_day: f64 = if (day_of_year == 366)
        365.5
    else
        @floatFromInt(day_of_year);
    const declination_degrees =
        @sin((orbital_day + parameters.declination_phase_days) *
            parameters.orbital_degrees_per_day *
            parameters.degrees_to_radians) *
        parameters.declination_amplitude_degrees;
    const latitude_radians =
        latitude_degrees_north * parameters.degrees_to_radians;
    const declination_radians =
        declination_degrees * parameters.degrees_to_radians;
    const azimuth_term =
        @sin(latitude_radians) * @sin(declination_radians);
    const declination_term =
        @cos(latitude_radians) * @cos(declination_radians);
    const ratio = azimuth_term / declination_term;
    if (ratio >= 1 - parameters.civil_twilight_sine) return 24;
    if (ratio <= -1 + parameters.civil_twilight_sine) return 0;
    return 12 * (1 + 2 / parameters.pi *
        std.math.asin(parameters.civil_twilight_sine + ratio));
}

/// Exact DAY daylength update, including the source day-366 substitution
/// XI=365.5 and polar day/night branches.
pub fn update(
    state: *State,
    day_of_year: u16,
    execution_year: u16,
    latitude_degrees_north: f64,
    parameters: Parameters,
) !void {
    _ = execution_calendar_date.fromDayOfYear(
        day_of_year,
        execution_year,
    ) catch return error.InvalidDaylengthCalendarDate;
    inline for (@typeInfo(State).@"struct".fields) |field| {
        const value = @field(state.*, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 24)
            return error.InvalidDaylengthState;
    }
    if (!std.math.isFinite(latitude_degrees_north) or
        latitude_degrees_north < -90 or latitude_degrees_north > 90)
        return error.InvalidDaylengthLatitude;
    inline for (@typeInfo(Parameters).@"struct".fields) |field|
        if (!std.math.isFinite(@field(parameters, field.name)))
            return error.NonFiniteDaylengthParameter;
    if (parameters.civil_twilight_sine < 0 or
        parameters.civil_twilight_sine >= 1 or
        parameters.degrees_to_radians <= 0 or
        parameters.orbital_degrees_per_day <= 0 or
        parameters.pi <= 0)
        return error.InvalidDaylengthParameter;

    // The stateful entry point promises a distinguishable error rather than a
    // NaN when the source's AZI/DEC quotient is singular, so it reproduces the
    // same two terms `hours` divides and rejects a zero or non-finite
    // denominator before delegating. `hours` itself stays branch-free on this
    // so callers that have already validated their inputs pay nothing.
    {
        const orbital_day: f64 = if (day_of_year == 366)
            365.5
        else
            @floatFromInt(day_of_year);
        const declination_degrees =
            @sin((orbital_day + parameters.declination_phase_days) *
                parameters.orbital_degrees_per_day *
                parameters.degrees_to_radians) *
            parameters.declination_amplitude_degrees;
        const latitude_radians =
            latitude_degrees_north * parameters.degrees_to_radians;
        const declination_radians =
            declination_degrees * parameters.degrees_to_radians;
        const azimuth_term =
            @sin(latitude_radians) * @sin(declination_radians);
        const declination_term =
            @cos(latitude_radians) * @cos(declination_radians);
        if (!std.math.isFinite(azimuth_term) or
            !std.math.isFinite(declination_term) or declination_term == 0)
            return error.DaylengthGeometrySingular;
    }
    const current_h: f64 =
        hours(day_of_year, latitude_degrees_north, parameters);
    if (!std.math.isFinite(current_h) or current_h < 0 or current_h > 24)
        return error.DaylengthCalculationFailure;
    state.* = .{
        .previous_daylength_h = state.current_daylength_h,
        .current_daylength_h = current_h,
    };
}

test "equatorial DAY daylength includes source civil twilight" {
    var state: State = .{
        .previous_daylength_h = 11,
        .current_daylength_h = 12,
    };
    try update(&state, 100, 1999, 0, .{});
    try std.testing.expectEqual(@as(f64, 12), state.previous_daylength_h);
    try std.testing.expect(state.current_daylength_h > 12);
    try std.testing.expect(state.current_daylength_h < 13);
}

test "polar branches produce exact zero and twenty-four hours" {
    var summer: State = .{
        .previous_daylength_h = 0,
        .current_daylength_h = 0,
    };
    var winter = summer;
    try update(&summer, 172, 1999, 80, .{});
    try update(&winter, 355, 1999, 80, .{});
    try std.testing.expectEqual(@as(f64, 24), summer.current_daylength_h);
    try std.testing.expectEqual(@as(f64, 0), winter.current_daylength_h);
}

test "leap day uses exact source orbital day 365.5 and DAY chronology" {
    var leap: State = .{
        .previous_daylength_h = 0,
        .current_daylength_h = 12,
    };
    try update(&leap, 366, 1900, 53.5, .{});
    // The source phase correction keeps leap-day geometry between the
    // neighboring ordinary orbital phases and finite at high latitude.
    try std.testing.expect(leap.current_daylength_h > 7);
    try std.testing.expect(leap.current_daylength_h < 9);

    const before = leap;
    try std.testing.expectError(
        error.InvalidDaylengthCalendarDate,
        update(&leap, 366, 1901, 53.5, .{}),
    );
    try std.testing.expectEqualDeep(before, leap);
}

test "invalid latitude rolls back both daylength fields" {
    var state: State = .{
        .previous_daylength_h = 10,
        .current_daylength_h = 11,
    };
    const before = state;
    try std.testing.expectError(
        error.InvalidDaylengthLatitude,
        update(&state, 100, 1999, 91, .{}),
    );
    try std.testing.expectEqualDeep(before, state);
}
