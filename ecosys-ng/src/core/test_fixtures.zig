const std = @import("std");

pub const disturbance_schedule_source = "16041998,10,0.15\n16051998,10,0.10\n07111998,8,0.10\n";
pub const fertilizer_schedule_source = "16051998 0 0 13.8 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0\n17051998 0 0 0 0 1.65 0 0 0 0 5.0 0 0 0 0 0 0 0 0 0 0.05 0.76 1 0 0\n15041998 0 0 0 0 0 0 0 0 0 0 0 360 0 0 0 0 0 0 0 0 0 0 0 0\n";
pub const land_management_source = "1 1 1 1\ntillage fertilizer NO\n";
pub const scene_options_source = "01011998\n31121998\n01011998\nNO\nYES\nNO\n1,0,0,1,1,1,1,1,1,1\n1,0,0,1,1,1,1,1,1,1\n1,0,0,1,1,1,1,1,1,1\n1,0,0,1,1,1,1,1,1,1\n20,4,1,1,10,1\nWeAtHeR_PhAsE|-1.5|0.0002\nViSuAlIzAtIoN_YeAr_WiNdOw|1998|1998\n";
pub const plant_assignment_source = "1 1 1 1 1\nmaize management\n";
pub const plant_management_source = "18059999,6.6,0.025\n13100000,1,1,0,0,1,1,1,1,0,0.95,0,0\n";
// Site record 1 is elevation, mean annual air temperature, water-table mode,
// compass aspect, slope, and initial snowpack depth. Latitude and longitude
// are absent: a cell's location comes from the grid-cell input record, which
// is also what resolves its row and column.
pub const site_source = "92 5.4 3 94.6 0.23 0.00\n2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n33 1 3 1 1.0 0.0\n0 1 1 0 10 0 10 0 1 0 1 0 0\n1.5 1.0\n0 10 0 10 0 1 0 1\n1\n1\n";
pub const site_source_2x1 = "92 5.4 3 94.6 0.23 0.00\n2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n33 1 3 1 1.0 0.0\n0 1 1 0 10 0 10 0 1 0 1 0 0\n1.5 1.0\n0 10 0 10 0 1 0 1\n1 1\n1\n";
pub const output_selection_source = "0101\n3112\nYES\nno\nYes\nNO\n";
pub const hourly_weather_source = "HJ0205DHTHPRW\nCRMWS\n5 0 12\n7 0.25 0.75 0.2 0 0 0 0 0 0 0 0\n1 100 -23.1 75.8 0 0 1.51\n2 200 -20 70 1 10 2\n";
pub const three_hour_weather_source = "3J0305XDHTHWPR\nCRSMW\n10 1 17.76\n7 0.03 0.11 0 0 0 0 0 0 0 0 0\n2008 1 3 -34.64 81.70 2.93 0.62 0\n";
pub const daily_weather_source = "DC0307YMDPMNHRXW\nMCCRMXH\n12 0 12\n7 0.25 0.25 0 0 0 0 0 0 0 0 0\n1929 1 1 0 -2.12 -9.22 89.11 2.55 3.68 4.05\n";
pub const unused_weather_columns_source = "DC0309YMDPTXXXHRXW\nMCCXXXXRMXH\n12 0 12\n7 0 0 0 0 0 0 0 0 0 0 0\n2009 1 1 0 -2 -9 0 0 0 89 2.5 3.6\n";
pub const plant_traits_source =
    \\4 2 0 0 0 0 2 0 0 2 2.0
    \\75 15 150 30 810 3 0.040 0.040 405 0.040 0.040 0.45
    \\0.20 0.075 0.20 0.075
    \\0.025 0.015 0 0 0 12.5 0.10
    \\16 5 -1 0.25
    \\0.020 0.300 0.300
    \\0 0 0.50 0.50 0.95 90 90
    \\1.2 6 0.20 0.20 0.50E-03 0
    \\3.75E-04 1.0E-04 0.20 0.10 1.0E+04 1.0E+09 5.0E-02 250 250
    \\1.4E-02 0.40 0.0125
    \\1.4E-02 0.35 0.030
    \\0.3E-02 0.18 0.009
    \\-1.5 -5 2.5E+03
    \\0.72 0.76 0.80 0.88 0.76 0.76 0.88 0.76 0.50
    \\0.10 0.02 0.0075 0.03 0.0125 0.0125 0.04 0.02 0.10
    \\0.010 0.002 0.00075 0.003 0.00125 0.00125 0.004 0.002 0.010
;

/// Builds a complete one-layer soil profile entirely in memory. Unit tests use
/// this instead of depending on files in the optional examples distribution.
pub fn soilProfileSource(allocator: std.mem.Allocator, layer_property_count: usize) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "-0.01,-1.5,0.2,6,11,1.1,0.11,22,2.2,0.22,33,3.3,0.33,8,2,1,1,0,0,0\n");
    const physical_records = [_][]const u8{ "0.1\n", "1.3\n", "van_genuchten_inflection_pressure_head_m 0\n", "0.30\n", "0.10\n", "10\n", "5\n", "400\n", "400\n", "0.05\n", "0\n", "6.5\n", "10\n", "1\n" };
    for (physical_records) |record| try source.appendSlice(allocator, record);
    for (0..layer_property_count) |property_index| try source.appendSlice(allocator, switch (property_index) {
        0 => "14.85\n",
        29 => "1\n",
        30 => "-1\n",
        else => "0\n",
    });
    return source.toOwnedSlice(allocator);
}
