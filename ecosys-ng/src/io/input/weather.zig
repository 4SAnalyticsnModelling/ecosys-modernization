const std = @import("std");
const delimited_input = @import("delimited_input.zig");
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");

pub const Header = struct {
    temporal_code: [2]u8,
    integer_column_count: u8,
    real_column_count: u8,
    integer_variable_codes: []const u8,
    weather_variable_codes: []const u8,
    weather_unit_codes: []const u8,
    aerodynamic_roughness_m: f64,
    weather_flag: i32,
    solar_noon_hour: f64,
    precipitation_ph: f64,
    precipitation_ammonium_g_per_m3: f64,
    precipitation_nitrate_g_per_m3: f64,
    precipitation_phosphate_g_per_m3: f64,
    precipitation_aluminum_g_per_m3: f64,
    precipitation_iron_g_per_m3: f64,
    precipitation_calcium_g_per_m3: f64,
    precipitation_magnesium_g_per_m3: f64,
    precipitation_sodium_g_per_m3: f64,
    precipitation_potassium_g_per_m3: f64,
    precipitation_sulfate_sulfur_g_per_m3: f64,
    precipitation_chloride_g_per_m3: f64,

    pub fn validate(self: Header) !void {
        const frequency = std.ascii.toUpper(self.temporal_code[0]);
        const calendar = std.ascii.toUpper(self.temporal_code[1]);
        if (!(frequency == 'S' or frequency == 'H' or frequency == '3' or frequency == 'D')) return error.InvalidWeatherTemporalCode;
        if (!(calendar == 'J' or calendar == 'C')) return error.InvalidWeatherCalendarCode;
        if (self.integer_variable_codes.len != self.integer_column_count or self.weather_variable_codes.len != self.real_column_count or self.weather_unit_codes.len != self.real_column_count) return error.WeatherHeaderColumnMismatch;
        // A calendar-format (month/day) header without an explicit year column
        // would force decodeTimestamp to assume a placeholder leap year to
        // compute day_of_year, silently shifting every date from March onward
        // by one day in any real non-leap year. Julian (day-of-year) headers
        // need no such derivation and remain unaffected.
        if (calendar == 'C') {
            var has_year_code = false;
            for (self.integer_variable_codes) |code| {
                if (std.ascii.toUpper(code) == 'Y') {
                    has_year_code = true;
                    break;
                }
            }
            if (!has_year_code) return error.CalendarWeatherHeaderMissingYear;
        }
        // X is a source-format positional placeholder and may occur more than
        // once (for example year and minute in historical SJ records).
        try uniqueCodes(self.integer_variable_codes, 'X');
        // X denotes an unused/pass-through weather column and may occur more
        // than once in supplied files. Scientific variables remain unique.
        try uniqueCodes(self.weather_variable_codes, 'X');
        if (!std.math.isFinite(self.aerodynamic_roughness_m) or self.aerodynamic_roughness_m < 0 or !std.math.isFinite(self.solar_noon_hour) or self.solar_noon_hour < 0 or self.solar_noon_hour > 24) return error.InvalidWeatherMetadata;
        if (!std.math.isFinite(self.precipitation_ph) or self.precipitation_ph < 0 or self.precipitation_ph > 14) return error.InvalidPrecipitationChemistry;
        inline for (@typeInfo(Header).@"struct".fields) |field| if (comptime std.mem.endsWith(u8, field.name, "_g_per_m3")) {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidPrecipitationChemistry;
        };
    }
};

fn uniqueCodes(codes: []const u8, repeatable_code: ?u8) !void {
    for (codes, 0..) |code, index| {
        if (repeatable_code) |repeatable| if (std.ascii.toUpper(code) == std.ascii.toUpper(repeatable)) continue;
        for (codes[index + 1 ..]) |other| if (std.ascii.toUpper(code) == std.ascii.toUpper(other)) return error.DuplicateWeatherVariable;
    }
}

pub const Summary = struct {
    allocator: std.mem.Allocator,
    header: Header,
    observation_count: usize,

    pub fn deinit(self: *Summary) void {
        self.allocator.free(self.header.integer_variable_codes);
        self.allocator.free(self.header.weather_variable_codes);
        self.allocator.free(self.header.weather_unit_codes);
        self.* = undefined;
    }
};

pub const HourlyObservation = struct {
    time_values: []const i64,
    timestamp: Timestamp,
    forcing: HourlyForcing,
};

pub const DailyObservation = struct {
    time_values: []const i64,
    timestamp: Timestamp,
    forcing: DailyForcing,
};

pub const Timestamp = struct {
    year: ?u16,
    day_of_year: ?u16,
    month: ?u8,
    day_of_month: ?u8,
    hour: u8,
    minute: u8,

    /// Resolve an hourly forcing endpoint to the source model's day / 1..24
    /// clock. READS (reads.f:484--489) assigns next-day 00:00 to previous-day
    /// hour 24. Keep raw timestamps in the input cursor for sequence checking;
    /// normalize once at the hourly driver boundary, before any day consumers.
    pub fn modelHour(self: Timestamp, fallback_year: u16) !Timestamp {
        if (self.hour > 24 or self.minute != 0) return error.InvalidWeatherHour;
        var year = self.year orelse fallback_year;
        if (year == 0) return error.InvalidWeatherYear;
        var observed_day = self.day_of_year;
        if (self.month != null or self.day_of_month != null) {
            const calendar_day = execution_calendar_date.dayOfYear(.{
                .year = year,
                .month = self.month orelse return error.InvalidWeatherDate,
                .day = self.day_of_month orelse return error.InvalidWeatherDate,
            }) catch return error.InvalidWeatherDate;
            if (observed_day) |day| if (day != calendar_day) return error.InvalidWeatherDate;
            observed_day = calendar_day;
        }
        var day = observed_day orelse return error.InvalidWeatherDate;
        if (day == 0 or day > 366) return error.InvalidWeatherDay;
        // A yearless common-year file may end on day 366 at 00:00: that is
        // exactly day 365 hour 24, not a leap-day observation. Explicit-year
        // inputs retain the date validation already enforced by the reader.
        if (self.year != null or self.hour != 0)
            _ = execution_calendar_date.fromDayOfYear(day, year) catch return error.InvalidWeatherDay;
        if (self.hour == 0) {
            if (day == 1) {
                if (year == 1) return error.InvalidWeatherYear;
                year -= 1;
                day = if (execution_calendar_date.isLeapYear(year)) 366 else 365;
            } else day -= 1;
        }
        const date = execution_calendar_date.fromDayOfYear(day, year) catch return error.InvalidWeatherDay;
        return .{
            .year = year,
            .day_of_year = day,
            .month = date.month,
            .day_of_month = date.day,
            .hour = if (self.hour == 0) 24 else self.hour,
            .minute = 0,
        };
    }

    /// Output/checkpoint slots are zero-based hourly intervals, not raw
    /// weather clock labels. Source hours 1 and 24 occupy slots 0 and 23.
    pub fn modelHourIndex(self: Timestamp) !u8 {
        if (self.hour == 0 or self.hour > 24 or self.minute != 0) return error.InvalidWeatherHour;
        return self.hour - 1;
    }

    /// Clock-only science APIs use 0 for midnight, while retaining the owning
    /// model day. This is not the zero-based output/checkpoint interval index.
    pub fn modelClockHour(self: Timestamp) !u8 {
        _ = try self.modelHourIndex();
        return self.hour % 24;
    }

    pub fn sequenceMinute(self: Timestamp) !i64 {
        if (self.hour > 24 or self.minute > 59 or
            (self.hour == 24 and self.minute != 0))
            return error.InvalidWeatherHour;
        if (self.year) |year| {
            if (self.day_of_year) |day| {
                _ = execution_calendar_date.fromDayOfYear(day, year) catch
                    return error.InvalidWeatherDate;
            } else {
                const month = self.month orelse return error.InvalidWeatherDate;
                const day = self.day_of_month orelse
                    return error.InvalidWeatherDate;
                _ = execution_calendar_date.dayOfYear(.{
                    .day = day,
                    .month = month,
                    .year = year,
                }) catch return error.InvalidWeatherDate;
            }
        }
        const day_index: i64 = if (self.day_of_year) |day| day - 1 else blk: {
            const month = self.month orelse return error.InvalidWeatherDate;
            const day = self.day_of_month orelse return error.InvalidWeatherDate;
            const resolved_day = try execution_calendar_date.dayOfYear(.{
                .day = day,
                .month = month,
                .year = self.year orelse 2000,
            });
            break :blk @as(i64, resolved_day - 1);
        };
        var preceding_days: i64 = 0;
        if (self.year) |year| {
            var prior_year: u16 = 0;
            while (prior_year < year) : (prior_year += 1) preceding_days += if (execution_calendar_date.isLeapYear(prior_year)) 366 else 365;
        }
        return (preceding_days + day_index) * 1440 + @as(i64, self.hour) * 60 + self.minute;
    }
};

/// Heap-resident, bounded-memory cursor. It is allocated in place because the
/// buffered reader contains internal pointers and must not move after setup.
pub const WeatherStream = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    reader_buffer: []u8,
    file_reader: std.Io.File.Reader,
    header: Header,
    integer_values: []i64,
    real_values: []f64,
    previous_sequence_minute: ?i64,
    observation_index: usize,
    finished: bool,
    precipitation_phase: PrecipitationPhase = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, reader_buffer_bytes: usize) !*WeatherStream {
        if (reader_buffer_bytes < 256) return error.WeatherReaderBufferTooSmall;
        const self = try allocator.create(WeatherStream);
        errdefer allocator.destroy(self);
        const buffer = try allocator.alloc(u8, reader_buffer_bytes);
        errdefer allocator.free(buffer);
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        self.allocator = allocator;
        self.io = io;
        self.file = file;
        self.reader_buffer = buffer;
        self.file_reader = file.readerStreaming(io, buffer);
        self.header = try readHeader(allocator, &self.file_reader.interface);
        errdefer freeHeader(allocator, self.header);
        self.integer_values = try allocator.alloc(i64, self.header.integer_column_count);
        errdefer allocator.free(self.integer_values);
        self.real_values = try allocator.alloc(f64, self.header.real_column_count);
        self.previous_sequence_minute = null;
        self.observation_index = 0;
        self.finished = false;
        self.precipitation_phase = .{};
        return self;
    }

    pub fn deinit(self: *WeatherStream) void {
        const allocator = self.allocator;
        self.file.close(self.io);
        allocator.free(self.reader_buffer);
        allocator.free(self.integer_values);
        allocator.free(self.real_values);
        freeHeader(allocator, self.header);
        allocator.destroy(self);
    }

    pub fn nextHourly(self: *WeatherStream, altitude_m: f64) !?HourlyObservation {
        if (std.ascii.toUpper(self.header.temporal_code[0]) == 'D') return error.WeatherStreamIsDaily;
        if (self.finished) return null;
        const record = try nextReaderRecordOrNull(&self.file_reader.interface) orelse return null;
        try decodeObservation(record, self.header, self.integer_values, self.real_values);
        const timestamp = try decodeTimestamp(self.header, self.integer_values);
        try self.validateSequence(timestamp);
        return .{
            .time_values = self.integer_values,
            .timestamp = timestamp,
            .forcing = try normalizeHourlyWithPhase(self.header, self.real_values, altitude_m, self.precipitation_phase),
        };
    }

    pub fn nextDaily(self: *WeatherStream, altitude_m: f64) !?DailyObservation {
        if (std.ascii.toUpper(self.header.temporal_code[0]) != 'D') return error.WeatherStreamIsSubdaily;
        if (self.finished) return null;
        const record = try nextReaderRecordOrNull(&self.file_reader.interface) orelse return null;
        try decodeObservation(record, self.header, self.integer_values, self.real_values);
        const timestamp = try decodeTimestamp(self.header, self.integer_values);
        try self.validateSequence(timestamp);
        return .{
            .time_values = self.integer_values,
            .timestamp = timestamp,
            .forcing = try normalizeDaily(self.header, self.real_values, altitude_m),
        };
    }

    fn validateSequence(self: *WeatherStream, timestamp: Timestamp) !void {
        const sequence_minute = try timestamp.sequenceMinute();
        if (self.previous_sequence_minute) |previous| {
            const elapsed = sequence_minute - previous;
            const expected: ?i64 = switch (std.ascii.toUpper(self.header.temporal_code[0])) {
                'H' => 60,
                '3' => 180,
                'D' => 1440,
                else => null,
            };
            if (elapsed <= 0 or (expected != null and elapsed != expected.?)) {
                std.log.err("weather time sequence failure: observation={d} previous_minute={d} current_minute={d} elapsed={d} expected={?}", .{ self.observation_index, previous, sequence_minute, elapsed, expected });
                return error.InvalidWeatherTimeSequence;
            }
        }
        self.previous_sequence_minute = sequence_minute;
        self.observation_index += 1;
    }
};

pub const PrecipitationPhase = struct {
    snowfall_temperature_threshold_c: f64 = -0.25,
    minimum_snowfall_water_equivalent_m: f64 = 0.1e-3,

    pub fn validate(self: PrecipitationPhase) !void {
        if (!std.math.isFinite(self.snowfall_temperature_threshold_c) or !std.math.isFinite(self.minimum_snowfall_water_equivalent_m) or self.snowfall_temperature_threshold_c < -273.15 or self.minimum_snowfall_water_equivalent_m < 0) return error.InvalidWeatherPhaseControls;
    }
};

test "model hour resolves midnight and calendar endpoints without moving the instant" {
    const Case = struct { year: ?u16, day: u16, hour: u8, fallback: u16, expected_year: u16, expected_day: u16, expected_hour: u8 };
    const cases = [_]Case{
        .{ .year = null, .day = 2, .hour = 0, .fallback = 1998, .expected_year = 1998, .expected_day = 1, .expected_hour = 24 },
        .{ .year = null, .day = 1, .hour = 24, .fallback = 1998, .expected_year = 1998, .expected_day = 1, .expected_hour = 24 },
        .{ .year = null, .day = 366, .hour = 0, .fallback = 1998, .expected_year = 1998, .expected_day = 365, .expected_hour = 24 },
        .{ .year = 1999, .day = 1, .hour = 0, .fallback = 2000, .expected_year = 1998, .expected_day = 365, .expected_hour = 24 },
        .{ .year = 1901, .day = 1, .hour = 0, .fallback = 1998, .expected_year = 1900, .expected_day = 366, .expected_hour = 24 },
        .{ .year = 1900, .day = 61, .hour = 0, .fallback = 1998, .expected_year = 1900, .expected_day = 60, .expected_hour = 24 },
        .{ .year = 2000, .day = 366, .hour = 24, .fallback = 1998, .expected_year = 2000, .expected_day = 366, .expected_hour = 24 },
        .{ .year = 1998, .day = 1, .hour = 1, .fallback = 2000, .expected_year = 1998, .expected_day = 1, .expected_hour = 1 },
    };
    for (cases) |case| {
        const raw: Timestamp = .{ .year = case.year, .day_of_year = case.day, .month = null, .day_of_month = null, .hour = case.hour, .minute = 0 };
        const resolved = try raw.modelHour(case.fallback);
        try std.testing.expectEqual(@as(?u16, case.expected_year), resolved.year);
        try std.testing.expectEqual(@as(?u16, case.expected_day), resolved.day_of_year);
        try std.testing.expectEqual(case.expected_hour, resolved.hour);
        try std.testing.expectEqualDeep(resolved, try resolved.modelHour(2024));
        if (case.year != null) try std.testing.expectEqual(try raw.sequenceMinute(), try resolved.sequenceMinute());
    }
    const calendar_midnight: Timestamp = .{ .year = 1900, .day_of_year = null, .month = 3, .day_of_month = 1, .hour = 0, .minute = 0 };
    const resolved = try calendar_midnight.modelHour(1998);
    try std.testing.expectEqual(@as(?u8, 2), resolved.month);
    try std.testing.expectEqual(@as(?u8, 29), resolved.day_of_month);
}

test "model hour rejects invalid dates subhourly endpoints and incomplete calendars" {
    const valid: Timestamp = .{ .year = null, .day_of_year = 2, .month = null, .day_of_month = null, .hour = 0, .minute = 0 };
    var invalid = valid;
    invalid.day_of_year = 0;
    try std.testing.expectError(error.InvalidWeatherDay, invalid.modelHour(1998));
    invalid.day_of_year = 367;
    try std.testing.expectError(error.InvalidWeatherDay, invalid.modelHour(2000));
    invalid.day_of_year = 366;
    invalid.year = 1998;
    try std.testing.expectError(error.InvalidWeatherDay, invalid.modelHour(1998));
    invalid.year = null;
    invalid.hour = 1;
    try std.testing.expectError(error.InvalidWeatherDay, invalid.modelHour(1998));
    invalid = valid;
    invalid.day_of_year = 1;
    try std.testing.expectError(error.InvalidWeatherYear, invalid.modelHour(1));
    try std.testing.expectError(error.InvalidWeatherYear, valid.modelHour(0));
    invalid = valid;
    invalid.hour = 25;
    try std.testing.expectError(error.InvalidWeatherHour, invalid.modelHour(1998));
    invalid = valid;
    invalid.minute = 1;
    try std.testing.expectError(error.InvalidWeatherHour, invalid.modelHour(1998));
    invalid = valid;
    invalid.month = 1;
    try std.testing.expectError(error.InvalidWeatherDate, invalid.modelHour(1998));
    invalid.day_of_month = 3;
    try std.testing.expectError(error.InvalidWeatherDate, invalid.modelHour(1998));
    invalid = valid;
    invalid.day_of_year = null;
    try std.testing.expectError(error.InvalidWeatherDate, invalid.modelHour(1998));
}

test "model hour output slots are bijective and distinct from clock labels" {
    var seen: u32 = 0;
    for (1..25) |hour| {
        const timestamp: Timestamp = .{ .year = 1998, .day_of_year = 1, .month = 1, .day_of_month = 1, .hour = @intCast(hour), .minute = 0 };
        const slot = try timestamp.modelHourIndex();
        const bit = @as(u32, 1) << @as(u5, @intCast(slot));
        try std.testing.expectEqual(@as(u32, 0), seen & bit);
        seen |= bit;
        try std.testing.expectEqual(@as(u8, @intCast(hour - 1)), slot);
        try std.testing.expectEqual(@as(u8, @intCast(hour % 24)), try timestamp.modelClockHour());
    }
    try std.testing.expectEqual(@as(u32, 0xffffff), seen);
    const raw_midnight: Timestamp = .{ .year = 1998, .day_of_year = 2, .month = null, .day_of_month = null, .hour = 0, .minute = 0 };
    try std.testing.expectError(error.InvalidWeatherHour, raw_midnight.modelHourIndex());
    try std.testing.expectError(error.InvalidWeatherHour, raw_midnight.modelClockHour());
}

fn freeHeader(allocator: std.mem.Allocator, header: Header) void {
    allocator.free(header.integer_variable_codes);
    allocator.free(header.weather_variable_codes);
    allocator.free(header.weather_unit_codes);
}

/// Validates a weather stream without retaining observations. This is the
/// intended out-of-core boundary: simulation tiles can later decode only the
/// time window they need.
pub fn scan(allocator: std.mem.Allocator, source: []const u8) !Summary {
    var records = std.mem.splitScalar(u8, source, '\n');
    const descriptor_record = try nextRecord(&records);
    const compact_descriptor = try compactRecord(allocator, descriptor_record);
    defer allocator.free(compact_descriptor);
    if (compact_descriptor.len < 6) return error.InvalidWeatherDescriptor;
    const integer_count = try std.fmt.parseUnsigned(u8, compact_descriptor[2..4], 10);
    const real_count = try std.fmt.parseUnsigned(u8, compact_descriptor[4..6], 10);
    if (integer_count == 0 or real_count == 0) return error.EmptyWeatherColumns;
    const descriptor_length = 6 + @as(usize, integer_count) +
        @as(usize, real_count);
    if (compact_descriptor.len < descriptor_length)
        return error.MissingWeatherVariableCodes;
    if (compact_descriptor.len > descriptor_length)
        return error.TrailingWeatherVariableCodes;
    const integer_codes = try allocator.dupe(u8, compact_descriptor[6 .. 6 + integer_count]);
    var header_owned_by_summary = false;
    errdefer if (!header_owned_by_summary) allocator.free(integer_codes);
    const variable_codes = try allocator.dupe(u8, compact_descriptor[6 + integer_count .. 6 + integer_count + real_count]);
    errdefer if (!header_owned_by_summary) allocator.free(variable_codes);

    const real_descriptor_record = try nextRecord(&records);
    const compact_real_descriptor = try compactRecord(allocator, real_descriptor_record);
    defer allocator.free(compact_real_descriptor);
    if (compact_real_descriptor.len < real_count)
        return error.MissingRealWeatherCodes;
    if (compact_real_descriptor.len > real_count)
        return error.TrailingRealWeatherCodes;
    const unit_codes = try allocator.dupe(u8, compact_real_descriptor[0..real_count]);
    errdefer if (!header_owned_by_summary) allocator.free(unit_codes);

    var metadata = delimited_input.recordTokens(try nextRecord(&records));
    var chemistry = delimited_input.recordTokens(try nextRecord(&records));
    var summary = Summary{
        .allocator = allocator,
        .header = .{
            .temporal_code = .{ compact_descriptor[0], compact_descriptor[1] },
            .integer_column_count = integer_count,
            .real_column_count = real_count,
            .integer_variable_codes = integer_codes,
            .weather_variable_codes = variable_codes,
            .weather_unit_codes = unit_codes,
            .aerodynamic_roughness_m = try number(f64, &metadata),
            .weather_flag = try integralMetadata(i32, &metadata),
            .solar_noon_hour = try number(f64, &metadata),
            .precipitation_ph = try number(f64, &chemistry),
            .precipitation_ammonium_g_per_m3 = try number(f64, &chemistry),
            .precipitation_nitrate_g_per_m3 = try number(f64, &chemistry),
            .precipitation_phosphate_g_per_m3 = try number(f64, &chemistry),
            .precipitation_aluminum_g_per_m3 = try number(f64, &chemistry),
            .precipitation_iron_g_per_m3 = try number(f64, &chemistry),
            .precipitation_calcium_g_per_m3 = try number(f64, &chemistry),
            .precipitation_magnesium_g_per_m3 = try number(f64, &chemistry),
            .precipitation_sodium_g_per_m3 = try number(f64, &chemistry),
            .precipitation_potassium_g_per_m3 = try number(f64, &chemistry),
            .precipitation_sulfate_sulfur_g_per_m3 = try number(f64, &chemistry),
            .precipitation_chloride_g_per_m3 = try number(f64, &chemistry),
        },
        .observation_count = 0,
    };
    header_owned_by_summary = true;
    errdefer summary.deinit();
    if (metadata.next() != null) return error.TrailingWeatherMetadata;
    if (chemistry.next() != null) return error.TrailingWeatherChemistry;
    try summary.header.validate();
    const required_columns: usize = @as(usize, integer_count) + @as(usize, real_count);
    while (try nextRecordOrNull(&records)) |record| {
        var fields = delimited_input.recordTokens(record);
        var column: usize = 0;
        while (column < required_columns) : (column += 1) {
            const text = fields.next() orelse {
                std.log.err("weather observation {d} has fewer than {d} required columns", .{ summary.observation_count, required_columns });
                return error.IncompleteWeatherObservation;
            };
            if (column < integer_count) {
                _ = parseIntegralText(i64, text) catch return error.InvalidWeatherInteger;
            } else {
                const value = std.fmt.parseFloat(f64, text) catch return error.InvalidWeatherReal;
                if (!std.math.isFinite(value)) return error.NonFiniteWeatherObservation;
            }
        }
        if (fields.next() != null) return error.TrailingWeatherObservationData;
        summary.observation_count += 1;
    }
    if (summary.observation_count == 0) return error.NoWeatherObservations;
    return summary;
}

/// Scans directly from a file with bounded memory. `reader_buffer_bytes`
/// limits the longest accepted record and is independent of file size.
pub fn scanFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, reader_buffer_bytes: usize) !Summary {
    if (reader_buffer_bytes < 256) return error.WeatherReaderBufferTooSmall;
    const buffer = try allocator.alloc(u8, reader_buffer_bytes);
    defer allocator.free(buffer);
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var file_reader = file.readerStreaming(io, buffer);
    return scanReader(allocator, &file_reader.interface);
}

fn readHeader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Header {
    const descriptor_record = try nextReaderRecord(reader);
    const compact_descriptor = try compactRecord(allocator, descriptor_record);
    defer allocator.free(compact_descriptor);
    if (compact_descriptor.len < 6) return error.InvalidWeatherDescriptor;
    const integer_count = try std.fmt.parseUnsigned(u8, compact_descriptor[2..4], 10);
    const real_count = try std.fmt.parseUnsigned(u8, compact_descriptor[4..6], 10);
    if (integer_count == 0 or real_count == 0) return error.EmptyWeatherColumns;
    const descriptor_length = 6 + @as(usize, integer_count) +
        @as(usize, real_count);
    if (compact_descriptor.len < descriptor_length)
        return error.MissingWeatherVariableCodes;
    if (compact_descriptor.len > descriptor_length)
        return error.TrailingWeatherVariableCodes;
    const integer_codes = try allocator.dupe(u8, compact_descriptor[6 .. 6 + integer_count]);
    errdefer allocator.free(integer_codes);
    const variable_codes = try allocator.dupe(u8, compact_descriptor[6 + integer_count .. 6 + integer_count + real_count]);
    errdefer allocator.free(variable_codes);
    const units_record = try nextReaderRecord(reader);
    const compact_units = try compactRecord(allocator, units_record);
    defer allocator.free(compact_units);
    if (compact_units.len < real_count) return error.MissingRealWeatherCodes;
    if (compact_units.len > real_count)
        return error.TrailingRealWeatherCodes;
    const unit_codes = try allocator.dupe(u8, compact_units[0..real_count]);
    errdefer allocator.free(unit_codes);
    var metadata = delimited_input.recordTokens(try nextReaderRecord(reader));
    var chemistry = delimited_input.recordTokens(try nextReaderRecord(reader));
    const header: Header = .{
        .temporal_code = .{ compact_descriptor[0], compact_descriptor[1] },
        .integer_column_count = integer_count,
        .real_column_count = real_count,
        .integer_variable_codes = integer_codes,
        .weather_variable_codes = variable_codes,
        .weather_unit_codes = unit_codes,
        .aerodynamic_roughness_m = try number(f64, &metadata),
        .weather_flag = try integralMetadata(i32, &metadata),
        .solar_noon_hour = try number(f64, &metadata),
        .precipitation_ph = try number(f64, &chemistry),
        .precipitation_ammonium_g_per_m3 = try number(f64, &chemistry),
        .precipitation_nitrate_g_per_m3 = try number(f64, &chemistry),
        .precipitation_phosphate_g_per_m3 = try number(f64, &chemistry),
        .precipitation_aluminum_g_per_m3 = try number(f64, &chemistry),
        .precipitation_iron_g_per_m3 = try number(f64, &chemistry),
        .precipitation_calcium_g_per_m3 = try number(f64, &chemistry),
        .precipitation_magnesium_g_per_m3 = try number(f64, &chemistry),
        .precipitation_sodium_g_per_m3 = try number(f64, &chemistry),
        .precipitation_potassium_g_per_m3 = try number(f64, &chemistry),
        .precipitation_sulfate_sulfur_g_per_m3 = try number(f64, &chemistry),
        .precipitation_chloride_g_per_m3 = try number(f64, &chemistry),
    };
    if (metadata.next() != null) return error.TrailingWeatherMetadata;
    if (chemistry.next() != null) return error.TrailingWeatherChemistry;
    try header.validate();
    return header;
}

pub fn scanReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Summary {
    const header = try readHeader(allocator, reader);
    var summary = Summary{
        .allocator = allocator,
        .header = header,
        .observation_count = 0,
    };
    errdefer summary.deinit();
    const required_columns: usize = @as(usize, header.integer_column_count) + @as(usize, header.real_column_count);
    while (try nextReaderRecordOrNull(reader)) |record| {
        var fields = delimited_input.recordTokens(record);
        for (0..required_columns) |column| {
            const text = fields.next() orelse return error.IncompleteWeatherObservation;
            if (column < header.integer_column_count) _ = parseIntegralText(i64, text) catch return error.InvalidWeatherInteger else {
                const value = std.fmt.parseFloat(f64, text) catch return error.InvalidWeatherReal;
                if (!std.math.isFinite(value)) return error.NonFiniteWeatherObservation;
            }
        }
        if (fields.next() != null) return error.TrailingWeatherObservationData;
        summary.observation_count += 1;
    }
    if (summary.observation_count == 0) return error.NoWeatherObservations;
    return summary;
}

fn nextReaderRecord(reader: *std.Io.Reader) ![]const u8 {
    return try nextReaderRecordOrNull(reader) orelse error.UnexpectedEndOfWeatherFile;
}

fn nextReaderRecordOrNull(reader: *std.Io.Reader) !?[]const u8 {
    while (try reader.takeDelimiter('\n')) |record| {
        if (hasEmptyExplicitField(record)) return error.EmptyWeatherRecordValue;
        var fields = delimited_input.recordTokens(record);
        if (fields.next() != null) return record;
    }
    return null;
}

/// Decodes one exact-schema observation into reusable caller-owned buffers.
pub fn decodeObservation(record: []const u8, header: Header, integer_values: []i64, real_values: []f64) !void {
    if (integer_values.len != header.integer_column_count or real_values.len != header.real_column_count) return error.WeatherObservationBufferSizeMismatch;
    var fields = delimited_input.recordTokens(record);
    for (integer_values) |*value| {
        value.* = parseIntegralText(i64, fields.next() orelse return error.IncompleteWeatherObservation) catch return error.InvalidWeatherInteger;
    }
    for (real_values) |*value| {
        value.* = std.fmt.parseFloat(f64, fields.next() orelse return error.IncompleteWeatherObservation) catch return error.InvalidWeatherReal;
        if (!std.math.isFinite(value.*)) return error.NonFiniteWeatherObservation;
    }
    if (fields.next() != null) return error.TrailingWeatherObservationData;
}

pub fn decodeTimestamp(header: Header, integer_values: []const i64) !Timestamp {
    if (integer_values.len != header.integer_column_count) return error.WeatherObservationBufferSizeMismatch;
    const is_daily = std.ascii.toUpper(header.temporal_code[0]) == 'D';
    const is_subhourly = std.ascii.toUpper(header.temporal_code[0]) == 'S';
    const hour_raw = if (is_daily) 0 else try requiredTimeValue(header, integer_values, 'H');
    if (hour_raw < 0 or hour_raw > 2400) return error.InvalidWeatherHour;
    const hour: u8 = if (is_subhourly or hour_raw > 24) @intCast(@divTrunc(hour_raw, 100)) else @intCast(hour_raw);
    const minute: u8 = if (is_subhourly or hour_raw > 24) @intCast(@mod(hour_raw, 100)) else 0;
    if (hour > 24 or minute > 59 or (hour == 24 and minute != 0)) return error.InvalidWeatherHour;
    // READS treats X as an ignored placeholder. It must never be promoted to
    // a calendar year: supplied historical files may change X within a day.
    const year_value = optionalTimeValue(header, integer_values, 'Y');
    const year: ?u16 = if (year_value) |value| if (value > 0 and value <= std.math.maxInt(u16)) @intCast(value) else return error.InvalidWeatherYear else null;
    if (std.ascii.toUpper(header.temporal_code[1]) == 'J') {
        const day_value = try requiredTimeValue(header, integer_values, 'D');
        const resolved_day = std.math.cast(u16, day_value) orelse return error.InvalidWeatherDay;
        const maximum_day: i64 = if (year) |resolved_year| if (execution_calendar_date.isLeapYear(resolved_year)) 366 else 365 else 366;
        if (resolved_day == 0 or resolved_day > maximum_day) return error.InvalidWeatherDay;
        if (year) |resolved_year| _ = execution_calendar_date.fromDayOfYear(resolved_day, resolved_year) catch return error.InvalidWeatherDay;
        return .{ .year = year, .day_of_year = resolved_day, .month = null, .day_of_month = null, .hour = hour, .minute = minute };
    }
    const month_value = try requiredTimeValue(header, integer_values, 'M');
    const day_value = try requiredTimeValue(header, integer_values, 'D');
    const month = std.math.cast(u8, month_value) orelse return error.InvalidWeatherDate;
    if (month == 0 or month > 12) return error.InvalidWeatherDate;
    const day = std.math.cast(u8, day_value) orelse return error.InvalidWeatherDate;
    const validation_year = year orelse 2000;
    const day_of_year = execution_calendar_date.dayOfYear(.{
        .day = day,
        .month = month,
        .year = validation_year,
    }) catch return error.InvalidWeatherDate;
    return .{ .year = year, .day_of_year = day_of_year, .month = month, .day_of_month = day, .hour = hour, .minute = minute };
}

fn requiredTimeValue(header: Header, values: []const i64, code: u8) !i64 {
    return optionalTimeValue(header, values, code) orelse error.MissingRequiredWeatherTimeVariable;
}

fn optionalTimeValue(header: Header, values: []const i64, code: u8) ?i64 {
    for (header.integer_variable_codes, 0..) |candidate, index| if (std.ascii.toUpper(candidate) == std.ascii.toUpper(code)) return values[index];
    return null;
}

test "weather timestamps preserve DAY modulo-four chronology" {
    const leap_julian: Timestamp = .{
        .year = 1900,
        .day_of_year = 366,
        .month = null,
        .day_of_month = null,
        .hour = 12,
        .minute = 0,
    };
    _ = try leap_julian.sequenceMinute();

    var invalid = leap_julian;
    invalid.year = 1901;
    try std.testing.expectError(
        error.InvalidWeatherDate,
        invalid.sequenceMinute(),
    );

    const leap_calendar: Timestamp = .{
        .year = 1900,
        .day_of_year = null,
        .month = 2,
        .day_of_month = 29,
        .hour = 0,
        .minute = 0,
    };
    _ = try leap_calendar.sequenceMinute();

    invalid = leap_julian;
    invalid.year = 0;
    try std.testing.expectError(
        error.InvalidWeatherDate,
        invalid.sequenceMinute(),
    );
}

test "C-calendar timestamps use execution-calendar month/day validation" {
    const header = Header{
        .temporal_code = .{ 'H', 'C' },
        .integer_column_count = 4,
        .real_column_count = 0,
        .integer_variable_codes = "YMDH",
        .weather_variable_codes = "",
        .weather_unit_codes = "",
        .aerodynamic_roughness_m = 5,
        .weather_flag = 0,
        .solar_noon_hour = 12,
        .precipitation_ph = 7,
        .precipitation_ammonium_g_per_m3 = 0,
        .precipitation_nitrate_g_per_m3 = 0,
        .precipitation_phosphate_g_per_m3 = 0,
        .precipitation_aluminum_g_per_m3 = 0,
        .precipitation_iron_g_per_m3 = 0,
        .precipitation_calcium_g_per_m3 = 0,
        .precipitation_magnesium_g_per_m3 = 0,
        .precipitation_sodium_g_per_m3 = 0,
        .precipitation_potassium_g_per_m3 = 0,
        .precipitation_sulfate_sulfur_g_per_m3 = 0,
        .precipitation_chloride_g_per_m3 = 0,
    };
    const leap_invalid = decodeTimestamp(header, &.{ 1999, 2, 29, 6 });
    try std.testing.expectError(error.InvalidWeatherDate, leap_invalid);
    const leap_valid = try decodeTimestamp(header, &.{ 1900, 2, 29, 6 });
    try std.testing.expectEqual(@as(u16, 60), leap_valid.day_of_year.?);
    try header.validate();
}

test "calendar-format header without a Y integer code fails validation instead of silently assuming a leap year" {
    var header = Header{
        .temporal_code = .{ 'H', 'C' },
        .integer_column_count = 3,
        .real_column_count = 0,
        .integer_variable_codes = "MDH",
        .weather_variable_codes = "",
        .weather_unit_codes = "",
        .aerodynamic_roughness_m = 5,
        .weather_flag = 0,
        .solar_noon_hour = 12,
        .precipitation_ph = 7,
        .precipitation_ammonium_g_per_m3 = 0,
        .precipitation_nitrate_g_per_m3 = 0,
        .precipitation_phosphate_g_per_m3 = 0,
        .precipitation_aluminum_g_per_m3 = 0,
        .precipitation_iron_g_per_m3 = 0,
        .precipitation_calcium_g_per_m3 = 0,
        .precipitation_magnesium_g_per_m3 = 0,
        .precipitation_sodium_g_per_m3 = 0,
        .precipitation_potassium_g_per_m3 = 0,
        .precipitation_sulfate_sulfur_g_per_m3 = 0,
        .precipitation_chloride_g_per_m3 = 0,
    };
    try std.testing.expectError(error.CalendarWeatherHeaderMissingYear, header.validate());

    // A Julian (day-of-year) header needs no year-derived day_of_year and
    // must remain unaffected by this check.
    header.temporal_code = .{ 'H', 'J' };
    header.integer_column_count = 2;
    header.integer_variable_codes = "DH";
    try header.validate();
}

pub const HourlyForcing = struct {
    air_temperature_c: f64,
    vapor_pressure_kpa: f64,
    precipitation_m: f64,
    rainfall_m: f64 = 0,
    snowfall_water_equivalent_m: f64 = 0,
    shortwave_radiation_megajoules_per_m2: f64,
    wind_speed_m_per_h: f64,
    longwave_radiation_megajoules_per_m2: ?f64,
};

pub const DailyForcing = struct {
    maximum_air_temperature_c: f64,
    minimum_air_temperature_c: f64,
    mean_vapor_pressure_kpa: f64,
    saturation_vapor_pressure_at_minimum_kpa: f64,
    precipitation_m_per_day: f64,
    shortwave_radiation_megajoules_per_m2_per_day: f64,
    wind_speed_m_per_h: f64,
};

pub fn normalizeDaily(header: Header, real_values: []const f64, altitude_m: f64) !DailyForcing {
    if (std.ascii.toUpper(header.temporal_code[0]) != 'D') return error.NotDailyWeather;
    if (real_values.len != header.real_column_count or !std.math.isFinite(altitude_m)) return error.WeatherObservationBufferSizeMismatch;
    const maximum_index = (try uniqueVariableIndex(header, 'M', true)).?;
    const minimum_index = (try uniqueVariableIndex(header, 'N', true)).?;
    const humidity_index = (try uniqueVariableIndex(header, 'H', true)).?;
    const precipitation_index = (try uniqueVariableIndex(header, 'P', true)).?;
    const radiation_index = (try uniqueVariableIndex(header, 'R', true)).?;
    const wind_index = (try uniqueVariableIndex(header, 'W', true)).?;
    const maximum_c = try temperatureC(real_values[maximum_index], header.weather_unit_codes[maximum_index]);
    const minimum_c = try temperatureC(real_values[minimum_index], header.weather_unit_codes[minimum_index]);
    if (minimum_c > maximum_c) return error.MinimumTemperatureExceedsMaximum;
    const vapor = try dailyVaporPressure(real_values[humidity_index], header.weather_unit_codes[humidity_index], minimum_c, maximum_c, altitude_m);
    const result: DailyForcing = .{
        .maximum_air_temperature_c = maximum_c,
        .minimum_air_temperature_c = minimum_c,
        .mean_vapor_pressure_kpa = vapor.mean,
        .saturation_vapor_pressure_at_minimum_kpa = vapor.at_minimum,
        .precipitation_m_per_day = try precipitationM(real_values[precipitation_index], header.weather_unit_codes[precipitation_index], 'D'),
        .shortwave_radiation_megajoules_per_m2_per_day = try dailyRadiation(real_values[radiation_index], header.weather_unit_codes[radiation_index]),
        .wind_speed_m_per_h = try dailyWind(real_values[wind_index], header.weather_unit_codes[wind_index]),
    };
    inline for (@typeInfo(DailyForcing).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteNormalizedWeather;
    return result;
}

fn dailyVaporPressure(value: f64, unit: u8, minimum_c: f64, maximum_c: f64, altitude_m: f64) !struct { mean: f64, at_minimum: f64 } {
    if (!std.math.isFinite(value)) return error.NonFiniteWeatherObservation;
    const average_c = 0.5 * (minimum_c + maximum_c);
    const saturation_average = saturationKpa(average_c);
    const saturation_minimum = saturationKpa(minimum_c);
    return switch (std.ascii.toUpper(unit)) {
        'D' => blk: {
            const pressure = saturationKpa(value);
            break :blk .{ .mean = pressure, .at_minimum = pressure };
        },
        'F' => blk: {
            const pressure = saturationKpa((value - 32.0) * 0.556);
            break :blk .{ .mean = pressure, .at_minimum = pressure };
        },
        'H' => .{ .mean = saturation_average * std.math.clamp(value, 0.0, 1.0), .at_minimum = saturation_minimum },
        'R' => .{ .mean = saturation_average * std.math.clamp(value, 0.0, 100.0) * 0.01, .at_minimum = saturation_minimum },
        'S' => .{ .mean = mixingRatioVapor(value * 0.001, average_c, altitude_m), .at_minimum = mixingRatioVapor(value * 0.001, minimum_c, altitude_m) },
        'G' => .{ .mean = mixingRatioVapor(value, average_c, altitude_m), .at_minimum = mixingRatioVapor(value, minimum_c, altitude_m) },
        'M' => .{ .mean = @max(0.0, value * 0.1), .at_minimum = @max(0.0, value * 0.1) },
        else => .{ .mean = @max(0.0, value), .at_minimum = @max(0.0, value) },
    };
}

fn saturationKpa(temperature_c: f64) f64 {
    return 0.61 * @exp(5360.0 * (0.003661 - 1.0 / (273.15 + temperature_c)));
}

/// `wthr.f:197--198` VPS: the saturation vapor pressure the hourly-array path
/// caps the ambient value against, including the `EXP(-ALTI/7272)` altitude
/// factor that `saturationKpa` above deliberately omits (its callers convert
/// dewpoint and relative humidity, where legacy applies no altitude factor;
/// see `reads.f:567--572`).
pub fn saturatedVaporPressureKpa(temperature_c: f64, altitude_m: f64) f64 {
    return saturationKpa(temperature_c) * @exp(-altitude_m / 7272.0);
}
fn mixingRatioVapor(value: f64, temperature_c: f64, altitude_m: f64) f64 {
    return @max(0.0, value) * 28.9 / 18.0 * 101.325 * @exp(-altitude_m / 7272.0) * 288.15 / (273.15 + temperature_c);
}
fn dailyRadiation(value: f64, unit: u8) !f64 {
    if (!std.math.isFinite(value)) return error.NonFiniteWeatherObservation;
    const positive = @max(0.0, value);
    return switch (std.ascii.toUpper(unit)) {
        'L' => positive / 23.87,
        'J' => positive * 0.01,
        'W' => positive * 0.0864,
        else => positive,
    };
}
fn dailyWind(value: f64, unit: u8) !f64 {
    if (!std.math.isFinite(value)) return error.NonFiniteWeatherObservation;
    const magnitude = @abs(value);
    return switch (std.ascii.toUpper(unit)) {
        'S' => magnitude * 3600,
        'H' => magnitude * 1000,
        'D' => magnitude * 1000 / 24,
        'M' => magnitude * 1600,
        else => magnitude,
    };
}

pub fn normalizeHourly(header: Header, real_values: []const f64, altitude_m: f64) !HourlyForcing {
    return normalizeHourlyWithPhase(header, real_values, altitude_m, .{});
}

pub fn normalizeHourlyWithPhase(header: Header, real_values: []const f64, altitude_m: f64, phase: PrecipitationPhase) !HourlyForcing {
    try phase.validate();
    if (real_values.len != header.real_column_count or !std.math.isFinite(altitude_m)) return error.WeatherObservationBufferSizeMismatch;
    const temperature_index = try uniqueVariableIndex(header, 'T', true);
    const humidity_index = try uniqueVariableIndex(header, 'H', true);
    const precipitation_index = try uniqueVariableIndex(header, 'P', true);
    const shortwave_index = try uniqueVariableIndex(header, 'R', true);
    const wind_index = try uniqueVariableIndex(header, 'W', true);
    const longwave_index = try uniqueVariableIndex(header, 'L', false);
    const temperature_c = try temperatureC(real_values[temperature_index.?], header.weather_unit_codes[temperature_index.?]);
    const precipitation_m = try precipitationM(real_values[precipitation_index.?], header.weather_unit_codes[precipitation_index.?], header.temporal_code[0]);
    const requires_three_hour_infill = std.ascii.toUpper(header.temporal_code[0]) == '3';
    const is_rain = temperature_c > phase.snowfall_temperature_threshold_c;
    const snowfall_m = if (!is_rain and precipitation_m >= phase.minimum_snowfall_water_equivalent_m) precipitation_m else 0;
    const result: HourlyForcing = .{
        .air_temperature_c = temperature_c,
        .vapor_pressure_kpa = try vaporPressureKpa(real_values[humidity_index.?], header.weather_unit_codes[humidity_index.?], temperature_c, altitude_m),
        // READS first divides a 3-hour precipitation amount among its three
        // infilled hours; WTHR then diagnoses rain/snow from each interpolated
        // hourly temperature. Preserve the unphased endpoint amount here.
        .precipitation_m = if (requires_three_hour_infill) precipitation_m else if (is_rain) precipitation_m else snowfall_m,
        .rainfall_m = if (requires_three_hour_infill) precipitation_m else if (is_rain) precipitation_m else 0,
        .snowfall_water_equivalent_m = if (requires_three_hour_infill) 0 else snowfall_m,
        .shortwave_radiation_megajoules_per_m2 = try radiationMjPerM2(real_values[shortwave_index.?], header.weather_unit_codes[shortwave_index.?]),
        // WTHR enforces UA=AMAX1(3600,WIND); retain the one-metre-per-second
        // aerodynamic floor, including for signed sonic-anemometer records.
        .wind_speed_m_per_h = @max(3600.0, try windMPerH(real_values[wind_index.?], header.weather_unit_codes[wind_index.?])),
        .longwave_radiation_megajoules_per_m2 = if (longwave_index) |index| try radiationMjPerM2(real_values[index], header.weather_unit_codes[index]) else null,
    };
    inline for (@typeInfo(HourlyForcing).@"struct".fields) |field| {
        if (field.type == f64 and !std.math.isFinite(@field(result, field.name))) return error.NonFiniteNormalizedWeather;
    }
    return result;
}

fn uniqueVariableIndex(header: Header, code: u8, required: bool) !?usize {
    var found: ?usize = null;
    for (header.weather_variable_codes, 0..) |candidate, index| if (std.ascii.toUpper(candidate) == std.ascii.toUpper(code)) {
        if (found != null) return error.DuplicateWeatherVariable;
        found = index;
    };
    if (required and found == null) return error.MissingRequiredWeatherVariable;
    return found;
}

fn temperatureC(value: f64, unit: u8) !f64 {
    if (!std.math.isFinite(value)) return error.NonFiniteWeatherObservation;
    return switch (std.ascii.toUpper(unit)) {
        'F' => (value - 32.0) * 0.556,
        'K' => value - 273.16,
        'C' => value,
        else => error.UnsupportedTemperatureUnit,
    };
}

fn vaporPressureKpa(value: f64, unit: u8, temperature_c: f64, altitude_m: f64) !f64 {
    if (!std.math.isFinite(value)) return error.NonFiniteWeatherObservation;
    const saturation = 0.61 * @exp(5360.0 * (0.003661 - 1.0 / (273.15 + temperature_c)));
    return switch (std.ascii.toUpper(unit)) {
        'D' => 0.61 * @exp(5360.0 * (0.003661 - 1.0 / (273.15 + value))),
        'F' => blk: {
            const dewpoint_c = (value - 32.0) * 0.556;
            break :blk 0.61 * @exp(5360.0 * (0.003661 - 1.0 / (273.15 + dewpoint_c)));
        },
        'H' => saturation * std.math.clamp(value, 0.0, 1.0),
        'R' => saturation * std.math.clamp(value, 0.0, 100.0) * 0.01,
        'S' => @max(0.0, value) * 0.0289 / 18.0 * 101.325 * @exp(-altitude_m / 7272.0) * 288.15 / (273.15 + temperature_c),
        'G' => @max(0.0, value) * 28.9 / 18.0 * 101.325 * @exp(-altitude_m / 7272.0) * 288.15 / (273.15 + temperature_c),
        'M' => @max(0.0, value * 0.1),
        else => @max(0.0, value),
    };
}

fn precipitationM(value: f64, unit: u8, temporal_code: u8) !f64 {
    if (!std.math.isFinite(value)) return error.NonFiniteWeatherObservation;
    const positive = @max(0.0, value);
    return switch (std.ascii.toUpper(unit)) {
        'M' => positive / 1000.0,
        'C' => positive / 100.0,
        'I' => positive * 0.0254,
        'S' => if (std.ascii.toUpper(temporal_code) == 'H') positive * 3.6 else error.PrecipitationRateRequiresTemporalAggregation,
        else => positive,
    };
}

fn radiationMjPerM2(value: f64, unit: u8) !f64 {
    if (!std.math.isFinite(value)) return error.NonFiniteWeatherObservation;
    const positive = @max(0.0, value);
    return switch (std.ascii.toUpper(unit)) {
        'W' => positive * 0.0036,
        'J' => positive * 0.01,
        'K' => positive * 0.001,
        'P' => positive * 0.0036 * 0.457,
        else => positive,
    };
}

fn windMPerH(value: f64, unit: u8) !f64 {
    if (!std.math.isFinite(value)) return error.NonFiniteWeatherObservation;
    return switch (std.ascii.toUpper(unit)) {
        'S' => value * 3600.0,
        'H' => value * 1000.0,
        'M' => value * 1600.0,
        else => value,
    };
}

fn compactRecord(allocator: std.mem.Allocator, record: []const u8) ![]u8 {
    const compact = try allocator.alloc(u8, record.len);
    errdefer allocator.free(compact);
    var length: usize = 0;
    for (record) |byte| {
        if (byte == '#') break;
        if (byte == ' ' or byte == '\t' or byte == ',' or byte == '|' or byte == '\r') continue;
        compact[length] = byte;
        length += 1;
    }
    return allocator.realloc(compact, length);
}

fn nextRecord(records: anytype) ![]const u8 {
    return try nextRecordOrNull(records) orelse error.UnexpectedEndOfWeatherFile;
}

fn nextRecordOrNull(records: anytype) !?[]const u8 {
    while (records.next()) |record| {
        if (hasEmptyExplicitField(record))
            return error.EmptyWeatherRecordValue;
        var fields = delimited_input.recordTokens(record);
        if (fields.next() != null) return record;
    }
    return null;
}

fn hasEmptyExplicitField(record: []const u8) bool {
    const content = if (std.mem.indexOfScalar(u8, record, '#')) |comment|
        record[0..comment]
    else
        record;
    const trimmed = std.mem.trim(u8, content, " \r");
    if (trimmed.len == 0) return false;
    var field_start: usize = 0;
    var saw_explicit_delimiter = false;
    for (trimmed, 0..) |byte, index| {
        if (byte != ',' and byte != '|' and byte != '\t') continue;
        if (std.mem.trim(u8, trimmed[field_start..index], " \r").len == 0) return true;
        field_start = index + 1;
        saw_explicit_delimiter = true;
    }
    return saw_explicit_delimiter and
        std.mem.trim(u8, trimmed[field_start..], " \r").len == 0;
}

fn number(comptime T: type, tokens: anytype) !T {
    const text = tokens.next() orelse return error.IncompleteWeatherHeader;
    return switch (@typeInfo(T)) {
        .float => std.fmt.parseFloat(T, text),
        .int => std.fmt.parseInt(T, text, 10),
        else => @compileError("unsupported weather number type"),
    };
}

/// Formatted Fortran weather headers commonly write integer flags through a
/// real edit descriptor (for example `1.00`). Accept that representation only
/// when its numeric value is exactly integral and in range.
fn integralMetadata(comptime T: type, tokens: anytype) !T {
    const text = tokens.next() orelse return error.IncompleteWeatherHeader;
    return parseIntegralText(T, text);
}

fn parseIntegralText(comptime T: type, text: []const u8) !T {
    if (std.fmt.parseInt(T, text, 10)) |value| return value else |_| {}
    const value = try std.fmt.parseFloat(f64, text);
    if (!std.math.isFinite(value) or value != @trunc(value)) return error.InvalidWeatherIntegralMetadata;
    const minimum: f64 = @floatFromInt(std.math.minInt(T));
    const maximum: f64 = @floatFromInt(std.math.maxInt(T));
    if (value < minimum or value > maximum) return error.WeatherIntegralMetadataOutOfRange;
    return @intFromFloat(value);
}

test "Fortran real-formatted integral weather metadata is exact" {
    var accepted = delimited_input.recordTokens("1.00");
    try std.testing.expectEqual(@as(i32, 1), try integralMetadata(i32, &accepted));
    var rejected = delimited_input.recordTokens("1.25");
    try std.testing.expectError(error.InvalidWeatherIntegralMetadata, integralMetadata(i32, &rejected));
}

test "weather scanners accept comments without shifting packed records" {
    const source =
        \\# Packed descriptor and units retain exact character counts.
        \\HJ0205DHTHPRW # two integer and five real columns
        \\CRMWS # five real-unit codes
        \\5 0 12 # roughness, flag, solar noon
        \\7 0.25 0.75 0.2 0 0 0 0 0 0 0 0 # precipitation chemistry
        \\   # Observations remain strict physical records.
        \\1 100 -23.1 75.8 0 0 1.51 # first hour
        \\# End of stream.
        \\
    ;
    var memory_summary = try scan(std.testing.allocator, source);
    defer memory_summary.deinit();
    try std.testing.expectEqual(@as(usize, 1), memory_summary.observation_count);

    var reader: std.Io.Reader = .fixed(source);
    var stream_summary = try scanReader(std.testing.allocator, &reader);
    defer stream_summary.deinit();
    try std.testing.expectEqual(@as(usize, 1), stream_summary.observation_count);
}

test "weather packed descriptors reject every extra mapped character" {
    const common_tail =
        \\5 0 12
        \\7 0.25 0.75 0.2 0 0 0 0 0 0 0 0
        \\1 100 -23.1 75.8 0 0 1.51
        \\
    ;
    try std.testing.expectError(
        error.TrailingWeatherVariableCodes,
        scan(
            std.testing.allocator,
            "HJ0205DHTHPRWX\nCRMWS\n" ++ common_tail,
        ),
    );
    try std.testing.expectError(
        error.TrailingRealWeatherCodes,
        scan(
            std.testing.allocator,
            "HJ0205DHTHPRW\nCRMWSX\n" ++ common_tail,
        ),
    );
}

test "weather scanner rejects surplus unit codes before observations" {
    const source =
        \\HJ0201DHT
        \\PC
        \\0.1,0,12
        \\7,0,0,0,0,0,0,0,0,0,0,0
        \\1,100,5
        \\,,,,,,4.1
        \\,,,,,,17
    ;
    try std.testing.expectError(
        error.TrailingRealWeatherCodes,
        scan(std.testing.allocator, source),
    );
}

test "weather scanner requires every precipitation chemistry value" {
    const source =
        \\HJ0201DHT
        \\P
        \\0.1,0,12
        \\7,0.1,0.2,0.3
        \\1,100,5
    ;
    try std.testing.expectError(error.IncompleteWeatherHeader, scan(std.testing.allocator, source));
}

test "scan self-contained hourly weather without retaining observations" {
    const source = @import("../../core/test_fixtures.zig").hourly_weather_source;
    var summary = try scan(std.testing.allocator, source);
    defer summary.deinit();
    try std.testing.expectEqual(@as(u8, 2), summary.header.integer_column_count);
    try std.testing.expectEqual(@as(u8, 5), summary.header.real_column_count);
    try std.testing.expectEqualStrings("DH", summary.header.integer_variable_codes);
    try std.testing.expectEqualStrings("THPRW", summary.header.weather_variable_codes);
    try std.testing.expectEqualStrings("CRMWS", summary.header.weather_unit_codes);
    try std.testing.expectEqual(@as(usize, 2), summary.observation_count);
}

test "scan self-contained three-hour weather" {
    const source = @import("../../core/test_fixtures.zig").three_hour_weather_source;
    var summary = try scan(std.testing.allocator, source);
    defer summary.deinit();
    try std.testing.expectEqual(@as(u8, 3), summary.header.integer_column_count);
    try std.testing.expectEqual(@as(u8, 5), summary.header.real_column_count);
    try std.testing.expectEqualStrings("THWPR", summary.header.weather_variable_codes);
    try std.testing.expectEqual(@as(usize, 1), summary.observation_count);
}

test "scan weather source without retaining record storage" {
    var summary = try scan(std.testing.allocator, @import("../../core/test_fixtures.zig").hourly_weather_source);
    defer summary.deinit();
    try std.testing.expectEqual(@as(usize, 2), summary.observation_count);
}

test "repeated unused X weather columns are accepted" {
    const source =
        \\DC0309YMDPTXXXHRXW
        \\MCXXXRMXH
        \\12 0 12
        \\7 0 0 0 0 0 0 0 0 0 0 0
        \\2009 1 1 0 -2 -9 0 0 0 89 2.5 3.6
        \\
    ;
    var summary = try scan(std.testing.allocator, source);
    defer summary.deinit();
    try std.testing.expectEqualStrings("PTXXXHRXW", summary.header.weather_variable_codes);
}

test "normalize daily crop weather in descriptor order" {
    const allocator = std.testing.allocator;
    var summary = try scan(allocator, @import("../../core/test_fixtures.zig").daily_weather_source);
    defer summary.deinit();
    const values = [_]f64{ 0, -2.12, -9.22, 89.11, 2.55, 3.68, 4.05 };
    const forcing = try normalizeDaily(summary.header, &values, 645);
    try std.testing.expectEqual(@as(f64, -2.12), forcing.maximum_air_temperature_c);
    try std.testing.expectEqual(@as(f64, -9.22), forcing.minimum_air_temperature_c);
    try std.testing.expectEqual(@as(f64, 2.55), forcing.shortwave_radiation_megajoules_per_m2_per_day);
    try std.testing.expectEqual(@as(f64, 4050), forcing.wind_speed_m_per_h);
}

test "decode observation into runtime-sized reusable buffers" {
    const allocator = std.testing.allocator;
    var summary = try scan(allocator, @import("../../core/test_fixtures.zig").hourly_weather_source);
    defer summary.deinit();
    const integers = try allocator.alloc(i64, summary.header.integer_column_count);
    defer allocator.free(integers);
    const reals = try allocator.alloc(f64, summary.header.real_column_count);
    defer allocator.free(reals);
    try decodeObservation("1 2 3.5 4.5 5.5 6.5 7.5", summary.header, integers, reals);
    try std.testing.expectEqual(@as(i64, 2), integers[1]);
    try std.testing.expectEqual(@as(f64, 7.5), reals[4]);
}

test "weather observations reject explicit empty values" {
    const source =
        \\HJ0205DHTHPRW
        \\CRMWS
        \\5 0 12
        \\7 0.25 0.75 0.2 0 0 0 0 0 0 0 0
        \\1 100 75.8,,1.51
    ;
    try std.testing.expectError(
        error.EmptyWeatherRecordValue,
        scan(std.testing.allocator, source),
    );
    var reader: std.Io.Reader = .fixed(source);
    try std.testing.expectError(
        error.EmptyWeatherRecordValue,
        scanReader(std.testing.allocator, &reader),
    );
}

test "normalize hourly forcing by descriptor rather than column position" {
    const header = Header{
        .temporal_code = .{ 'H', 'J' },
        .integer_column_count = 2,
        .real_column_count = 5,
        .integer_variable_codes = "DH",
        .weather_variable_codes = "THPRW",
        .weather_unit_codes = "CRMWS",
        .aerodynamic_roughness_m = 5,
        .weather_flag = 0,
        .solar_noon_hour = 12,
        .precipitation_ph = 7,
        .precipitation_ammonium_g_per_m3 = 0,
        .precipitation_nitrate_g_per_m3 = 0,
        .precipitation_phosphate_g_per_m3 = 0,
        .precipitation_aluminum_g_per_m3 = 0,
        .precipitation_iron_g_per_m3 = 0,
        .precipitation_calcium_g_per_m3 = 0,
        .precipitation_magnesium_g_per_m3 = 0,
        .precipitation_sodium_g_per_m3 = 0,
        .precipitation_potassium_g_per_m3 = 0,
        .precipitation_sulfate_sulfur_g_per_m3 = 0,
        .precipitation_chloride_g_per_m3 = 0,
    };
    const forcing = try normalizeHourly(header, &.{ 20, 50, 10, 100, 2 }, 500);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), forcing.precipitation_m, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.36), forcing.shortwave_radiation_megajoules_per_m2, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7200), forcing.wind_speed_m_per_h, 1.0e-12);
    var lowercase_header = header;
    lowercase_header.temporal_code = .{ 'h', 'j' };
    lowercase_header.integer_variable_codes = "dh";
    lowercase_header.weather_variable_codes = "thprw";
    lowercase_header.weather_unit_codes = "crmws";
    try lowercase_header.validate();
    const lowercase_forcing = try normalizeHourly(lowercase_header, &.{ 20, 50, 10, 100, 2 }, 500);
    try std.testing.expectEqual(forcing, lowercase_forcing);
}

test "self-contained hourly observation normalizes with runtime buffers" {
    var summary = try scan(std.testing.allocator, @import("../../core/test_fixtures.zig").hourly_weather_source);
    defer summary.deinit();
    const forcing = try normalizeHourly(summary.header, &.{ -23.1, 75.8, 0, 0, 1.51 }, 100);
    const timestamp = try decodeTimestamp(summary.header, &.{ 1, 100 });
    try std.testing.expectEqual(@as(u16, 1), timestamp.day_of_year.?);
    try std.testing.expectEqual(@as(u8, 1), timestamp.hour);
    try std.testing.expectApproxEqAbs(@as(f64, -23.1), forcing.air_temperature_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5436.0), forcing.wind_speed_m_per_h, 1.0e-10);
}

test "X weather descriptor remains an ignored placeholder" {
    const allocator = std.testing.allocator;
    var summary = try scan(allocator, @import("../../core/test_fixtures.zig").three_hour_weather_source);
    defer summary.deinit();
    const timestamp = try decodeTimestamp(summary.header, &.{ 2008, 1, 3 });
    try std.testing.expectEqual(@as(?u16, null), timestamp.year);
    try std.testing.expectEqual(@as(u16, 1), timestamp.day_of_year.?);
    try std.testing.expectEqual(@as(u8, 3), timestamp.hour);
}

test "self-contained daily observation yields typed date and forcing" {
    var summary = try scan(std.testing.allocator, @import("../../core/test_fixtures.zig").daily_weather_source);
    defer summary.deinit();
    const timestamp = try decodeTimestamp(summary.header, &.{ 1929, 1, 1 });
    const forcing = try normalizeDaily(summary.header, &.{ 0, -2.12, -9.22, 89.11, 2.55, 3.68, 4.05 }, 645);
    try std.testing.expectEqual(@as(u16, 1929), timestamp.year.?);
    try std.testing.expectEqual(@as(u8, 1), timestamp.month.?);
    try std.testing.expectEqual(@as(u16, 1), timestamp.day_of_year.?);
    try std.testing.expectApproxEqAbs(@as(f64, -2.12), forcing.maximum_air_temperature_c, 1.0e-12);
}

test "historical weather integer descriptors allow repeated X placeholders" {
    try uniqueCodes("XDXH", 'X');
    try std.testing.expectError(error.DuplicateWeatherVariable, uniqueCodes("YDYH", 'X'));
}
