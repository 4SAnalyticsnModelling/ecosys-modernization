const std = @import("std");
const delimited_input = @import("../io/input/delimited_input.zig");
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");

pub const Date = struct {
    day: u8,
    month: u8,
    year: u16,

    fn parse(text: []const u8) !Date {
        if (text.len != 8) return error.InvalidCompactDate;
        const result = Date{
            .day = try std.fmt.parseUnsigned(u8, text[0..2], 10),
            .month = try std.fmt.parseUnsigned(u8, text[2..4], 10),
            .year = try std.fmt.parseUnsigned(u16, text[4..8], 10),
        };
        _ = execution_calendar_date.dayOfYear(.{
            .day = result.day,
            .month = result.month,
            .year = result.year,
        }) catch return error.InvalidCompactDate;
        return result;
    }

    pub fn orderKey(self: Date) u32 {
        return @as(u32, self.year) * 10_000 + @as(u32, self.month) * 100 + self.day;
    }
};

pub const SeasonalWeatherChange = struct {
    radiation_fraction: f64,
    maximum_temperature_c: f64,
    minimum_temperature_c: f64,
    humidity_fraction: f64,
    precipitation_fraction: f64,
    irrigation_fraction: f64,
    wind_speed_fraction: f64,
    atmospheric_co2_fraction: f64,
    precipitation_ammonium_fraction: f64,
    precipitation_nitrate_fraction: f64,
};

pub const SceneOptions = struct {
    start_date: Date,
    end_date: Date,
    checkpoint_origin_date: Date,
    visualization_enabled: bool,
    checkpoint_output_enabled: bool,
    resume_from_checkpoint: bool,
    seasonal_weather_changes: [4]SeasonalWeatherChange,
    water_heat_solute_iteration_limit: u16,
    gas_iterations_per_water_heat_solute_iteration: u16,
    hourly_output_interval_hours: u16,
    daily_output_interval_days: u16,
    checkpoint_interval_days: u16,
    climate_change_mode: u8,
    snowfall_temperature_threshold_c: f64,
    minimum_snowfall_water_equivalent_m: f64,
    visualization_start_year: u16,
    visualization_end_year: u16,

    pub fn validate(self: SceneOptions) !void {
        if (self.end_date.orderKey() < self.start_date.orderKey()) return error.SceneEndsBeforeItStarts;
        if (self.water_heat_solute_iteration_limit == 0) return error.ZeroTransportIterations;
        if (self.gas_iterations_per_water_heat_solute_iteration == 0) return error.ZeroGasIterations;
        if (self.hourly_output_interval_hours == 0 or self.hourly_output_interval_hours > 24) return error.InvalidHourlyOutputInterval;
        if (self.climate_change_mode > 2) return error.InvalidClimateChangeMode;
        if (!std.math.isFinite(self.snowfall_temperature_threshold_c) or !std.math.isFinite(self.minimum_snowfall_water_equivalent_m) or self.snowfall_temperature_threshold_c < -273.15 or self.minimum_snowfall_water_equivalent_m < 0) return error.InvalidWeatherPhaseControls;
        if (self.visualization_end_year < self.visualization_start_year)
            return error.InvalidVisualizationYearWindow;
        inline for (self.seasonal_weather_changes) |change| {
            inline for (@typeInfo(SeasonalWeatherChange).@"struct".fields) |field| {
                const value = @field(change, field.name);
                if (!std.math.isFinite(value)) return error.NonFiniteWeatherChange;
                if (comptime !std.mem.endsWith(u8, field.name, "temperature_c")) if (value < 0) return error.NegativeWeatherChangeMultiplier;
            }
            if (change.atmospheric_co2_fraction <= 0) return error.NonPositiveCo2ChangeMultiplier;
        }
    }

    pub fn visualizationIncludesYear(
        self: SceneOptions,
        year: u16,
    ) bool {
        return self.visualization_enabled and
            year >= self.visualization_start_year and
            year <= self.visualization_end_year;
    }
};

pub fn parse(source: []const u8) !SceneOptions {
    var input_records = delimited_input.records(source);
    var result: SceneOptions = undefined;
    result.start_date = try parseSingleDate(&input_records);
    result.end_date = try parseSingleDate(&input_records);
    result.checkpoint_origin_date = try parseSingleDate(&input_records);
    result.visualization_enabled = try parseSingleYesNo(&input_records);
    result.checkpoint_output_enabled = try parseSingleYesNo(&input_records);
    result.resume_from_checkpoint = try parseSingleYesNo(&input_records);
    for (&result.seasonal_weather_changes) |*change| {
        var tokens = try nextRecordTokens(&input_records);
        change.* = .{
            .radiation_fraction = try nextFloat(&tokens),
            .maximum_temperature_c = try nextFloat(&tokens),
            .minimum_temperature_c = try nextFloat(&tokens),
            .humidity_fraction = try nextFloat(&tokens),
            .precipitation_fraction = try nextFloat(&tokens),
            .irrigation_fraction = try nextFloat(&tokens),
            .wind_speed_fraction = try nextFloat(&tokens),
            .atmospheric_co2_fraction = try nextFloat(&tokens),
            .precipitation_ammonium_fraction = try nextFloat(&tokens),
            .precipitation_nitrate_fraction = try nextFloat(&tokens),
        };
        try requireEnd(&tokens);
    }
    var transport = try nextRecordTokens(&input_records);
    result.water_heat_solute_iteration_limit = try nextUnsigned(u16, &transport);
    result.gas_iterations_per_water_heat_solute_iteration = try nextUnsigned(u16, &transport);
    result.hourly_output_interval_hours = try nextUnsigned(u16, &transport);
    result.daily_output_interval_days = try nextUnsigned(u16, &transport);
    result.checkpoint_interval_days = try nextUnsigned(u16, &transport);
    result.climate_change_mode = try nextUnsigned(u8, &transport);
    try requireEnd(&transport);
    var weather_phase = try nextRecordTokens(&input_records);
    if (!std.ascii.eqlIgnoreCase(try next(&weather_phase), "weather_phase")) return error.MissingWeatherPhaseRecord;
    result.snowfall_temperature_threshold_c = try nextFloat(&weather_phase);
    result.minimum_snowfall_water_equivalent_m = try nextFloat(&weather_phase);
    try requireEnd(&weather_phase);
    var visualization_window = try nextRecordTokens(&input_records);
    if (!std.ascii.eqlIgnoreCase(
        try next(&visualization_window),
        "visualization_year_window",
    )) return error.MissingVisualizationYearWindowRecord;
    result.visualization_start_year =
        try nextUnsigned(u16, &visualization_window);
    result.visualization_end_year =
        try nextUnsigned(u16, &visualization_window);
    try requireEnd(&visualization_window);
    if (input_records.next() != null) return error.TrailingOptionsRecord;
    try result.validate();
    return result;
}

fn nextRecordTokens(input_records: *delimited_input.RecordIterator) !delimited_input.TokenIterator {
    const record = input_records.next() orelse return error.UnexpectedEndOfOptions;
    if (hasEmptyExplicitField(record)) return error.EmptyOptionsRecordValue;
    return delimited_input.recordTokens(record);
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
        if (std.mem.trim(u8, trimmed[field_start..index], " \r").len == 0)
            return true;
        field_start = index + 1;
        saw_explicit_delimiter = true;
    }
    return saw_explicit_delimiter and
        std.mem.trim(u8, trimmed[field_start..], " \r").len == 0;
}

fn parseSingleDate(input_records: *delimited_input.RecordIterator) !Date {
    var tokens = try nextRecordTokens(input_records);
    const result = try Date.parse(try next(&tokens));
    try requireEnd(&tokens);
    return result;
}

fn parseSingleYesNo(input_records: *delimited_input.RecordIterator) !bool {
    var tokens = try nextRecordTokens(input_records);
    const result = try parseYesNo(try next(&tokens));
    try requireEnd(&tokens);
    return result;
}

fn requireEnd(tokens: *delimited_input.TokenIterator) !void {
    if (tokens.next() != null) return error.TrailingOptionsRecordData;
}

fn next(tokens: anytype) ![]const u8 {
    return tokens.next() orelse error.UnexpectedEndOfOptions;
}

fn nextFloat(tokens: anytype) !f64 {
    const value = try std.fmt.parseFloat(f64, try next(tokens));
    if (!std.math.isFinite(value)) return error.NonFiniteWeatherChange;
    return value;
}

fn nextUnsigned(comptime T: type, tokens: anytype) !T {
    return std.fmt.parseUnsigned(T, try next(tokens), 10);
}

fn parseYesNo(text: []const u8) !bool {
    return delimited_input.parseYesNo(text) catch return error.InvalidYesNoOption;
}

const test_scene_options_source = "01011998\n31121998\n01011998\nNO\nYES\nNO\n1,0,0,1,1,1,1,1,1,1\n1,0,0,1,1,1,1,1,1,1\n1,0,0,1,1,1,1,1,1,1\n1,0,0,1,1,1,1,1,1,1\n20,4,1,1,10,1\nWeAtHeR_PhAsE|-1.5|0.0002\nViSuAlIzAtIoN_YeAr_WiNdOw|1998|1998\n";

test "parse self-contained scene options" {
    const source = test_scene_options_source;
    const result = try parse(source);
    try std.testing.expectEqual(@as(u16, 1998), result.start_date.year);
    try std.testing.expectEqual(@as(u8, 31), result.end_date.day);
    try std.testing.expectEqual(@as(u16, 20), result.water_heat_solute_iteration_limit);
    try std.testing.expectEqual(@as(u16, 4), result.gas_iterations_per_water_heat_solute_iteration);
    try std.testing.expect(result.checkpoint_output_enabled);
    try std.testing.expect(!result.resume_from_checkpoint);
}

test "reject impossible and reversed scene dates" {
    try std.testing.expectError(error.InvalidCompactDate, Date.parse("31042024"));
    const valid_source =
        "02012024\n01012024\n01012024\nNO\nNO\nNO\n" ++
        ("1 1 1 1 1 1 1 1 1 1\n" ** 4) ++
        "1 1 1 1 1 0\nweather_phase -0.25 0.0001\n" ++
        "visualization_year_window 2024 2024\n";
    try std.testing.expectError(error.SceneEndsBeforeItStarts, parse(valid_source));
}

test "weather phase controls are compulsory case insensitive runtime inputs" {
    const source = test_scene_options_source;
    const result = try parse(source);
    try std.testing.expectApproxEqAbs(@as(f64, -1.5), result.snowfall_temperature_threshold_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0002), result.minimum_snowfall_water_equivalent_m, 1e-15);
}

test "visualization year window is compulsory case insensitive and inclusive" {
    const result = try parse(test_scene_options_source);
    try std.testing.expectEqual(@as(u16, 1998), result.visualization_start_year);
    try std.testing.expectEqual(@as(u16, 1998), result.visualization_end_year);
    try std.testing.expect(!result.visualizationIncludesYear(1998));

    var enabled = result;
    enabled.visualization_enabled = true;
    try std.testing.expect(enabled.visualizationIncludesYear(1998));
    try std.testing.expect(!enabled.visualizationIncludesYear(1997));
    enabled.visualization_end_year = 1997;
    try std.testing.expectError(
        error.InvalidVisualizationYearWindow,
        enabled.validate(),
    );
}

test "options records reject empty explicit delimiter fields" {
    inline for (.{
        "01011998\n31121998\n01011998\nNO\nYES\nNO\n1,,0,1,1,1,1,1,1,1\n",
        "01011998\n31121998\n01011998\nNO\nYES\nNO\n1| |0|1|1|1|1|1|1|1\n",
        "01011998\n31121998\n01011998\nNO\nYES\nNO\n1\t\t0\t1\t1\t1\t1\t1\t1\t1\n",
    }) |source| try std.testing.expectError(
        error.EmptyOptionsRecordValue,
        parse(source),
    );
}

test "options parser follows source modulo-four leap-year rule" {
    const century_source =
        "29021900\n01031900\n29021900\nNO\nYES\nNO\n" ++
        ("1,0,0,1,1,1,1,1,1,1\n" ** 4) ++
        "20 4 1 1 10 1\n" ++
        "WeAtHeR_PhAsE|-1.5|0.0002\n" ++
        "ViSuAlIzAtIoN_YeAr_WiNdOw|1900|1900\n";
    const century = try parse(century_source);
    try std.testing.expectEqual(@as(u16, 1900), century.start_date.year);
    try std.testing.expectEqual(@as(u8, 29), century.start_date.day);

    const non_leap_source =
        "29021901\n01031901\n29021901\nNO\nYES\nNO\n" ++
        ("1,0,0,1,1,1,1,1,1,1\n" ** 4) ++
        "20 4 1 1 10 1\n" ++
        "WeAtHeR_PhAsE|-1.5|0.0002\n" ++
        "ViSuAlIzAtIoN_YeAr_WiNdOw|1901|1901\n";
    try std.testing.expectError(error.InvalidCompactDate, parse(non_leap_source));
}

test "options empty-field check preserves valid spacing and comments" {
    try std.testing.expect(!hasEmptyExplicitField(
        "1  0  0  1  1  1  1  1  1  1 # spaced record",
    ));
    try std.testing.expect(!hasEmptyExplicitField(
        "1, 0 | 0\t1, 1 | 1\t1, 1 | 1\t1 # mixed delimiters",
    ));
    try std.testing.expect(!hasEmptyExplicitField("# comment only"));
}
