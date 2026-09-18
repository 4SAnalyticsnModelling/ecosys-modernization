const std = @import("std");

pub const Date = struct {
    day: u8,
    month: u8,
    year: u16,
};

/// ecosys source chronology: every year divisible by four is leap, including
/// century years. This deliberately does not apply Gregorian exceptions.
pub fn isLeapYear(year: u16) bool {
    return year % 4 == 0;
}

pub fn fromDayOfYear(day_of_year: u16, year: u16) !Date {
    if (year == 0) return error.InvalidExecutionCalendarYear;
    const maximum_day: u16 = if (isLeapYear(year)) 366 else 365;
    if (day_of_year == 0 or day_of_year > maximum_day)
        return error.InvalidExecutionCalendarDay;
    const month_lengths = [_]u8{
        31,
        if (isLeapYear(year)) 29 else 28,
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    };
    var remaining = day_of_year;
    for (month_lengths, 0..) |length, month_index| {
        if (remaining <= length) return .{
            .day = @intCast(remaining),
            .month = @intCast(month_index + 1),
            .year = year,
        };
        remaining -= length;
    }
    unreachable;
}

/// Allocation-free DAY `CDATE=DDMMYYYY` formatter.
pub fn formatDdMmYyyy(date: Date) ![8]u8 {
    if (date.year == 0 or date.month == 0 or date.month > 12 or
        date.day == 0)
        return error.InvalidExecutionCalendarDate;
    const round_trip_day = try dayOfYear(date);
    _ = round_trip_day;
    var bytes: [8]u8 = undefined;
    _ = try std.fmt.bufPrint(&bytes, "{d:0>2}{d:0>2}{d:0>4}", .{
        date.day,
        date.month,
        date.year,
    });
    return bytes;
}

pub fn dayOfYear(date: Date) !u16 {
    if (date.year == 0 or date.month == 0 or date.month > 12 or
        date.day == 0)
        return error.InvalidExecutionCalendarDate;
    const month_lengths = [_]u8{
        31,
        if (isLeapYear(date.year)) 29 else 28,
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    };
    if (date.day > month_lengths[date.month - 1])
        return error.InvalidExecutionCalendarDate;
    var result: u16 = date.day;
    for (month_lengths[0 .. date.month - 1]) |length| result += length;
    return result;
}

test "DAY converts ordinary boundaries to DDMMYYYY" {
    const first = try fromDayOfYear(1, 1999);
    const last = try fromDayOfYear(365, 1999);
    try std.testing.expectEqualStrings(
        "01011999",
        &(try formatDdMmYyyy(first)),
    );
    try std.testing.expectEqualStrings(
        "31121999",
        &(try formatDdMmYyyy(last)),
    );
    try std.testing.expectEqual(@as(u16, 365), try dayOfYear(last));
}

test "source modulo-four chronology treats 1900 as leap" {
    try std.testing.expect(isLeapYear(1900));
    const leap_day = try fromDayOfYear(60, 1900);
    try std.testing.expectEqual(@as(u8, 29), leap_day.day);
    try std.testing.expectEqual(@as(u8, 2), leap_day.month);
    try std.testing.expectEqualStrings(
        "29021900",
        &(try formatDdMmYyyy(leap_day)),
    );
    const final = try fromDayOfYear(366, 1900);
    try std.testing.expectEqualStrings(
        "31121900",
        &(try formatDdMmYyyy(final)),
    );
}

test "common year rejects day 366 and invalid calendar dates" {
    try std.testing.expectError(
        error.InvalidExecutionCalendarDay,
        fromDayOfYear(366, 1999),
    );
    try std.testing.expectError(
        error.InvalidExecutionCalendarDate,
        dayOfYear(.{ .day = 29, .month = 2, .year = 1999 }),
    );
    try std.testing.expectError(
        error.InvalidExecutionCalendarDate,
        formatDdMmYyyy(.{ .day = 31, .month = 4, .year = 2000 }),
    );
}

test "all valid days round trip in common and source leap years" {
    inline for (.{ @as(u16, 1999), @as(u16, 2000) }) |year| {
        const maximum: u16 = if (isLeapYear(year)) 366 else 365;
        for (1..@as(usize, maximum) + 1) |day| {
            const date = try fromDayOfYear(@intCast(day), year);
            try std.testing.expectEqual(
                @as(u16, @intCast(day)),
                try dayOfYear(date),
            );
        }
    }
}
