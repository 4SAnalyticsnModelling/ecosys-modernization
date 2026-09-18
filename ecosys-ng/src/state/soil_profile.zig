const std = @import("std");
const delimited_input = @import("../io/input/delimited_input.zig");

const RecordIterator = @TypeOf(std.mem.splitScalar(u8, "", '\n'));
const RecordTokens = @TypeOf(delimited_input.recordTokens(""));

pub const LayerProperty = enum {
    total_organic_carbon_kg_per_megagram,
    particulate_organic_carbon_kg_per_megagram,
    organic_nitrogen_g_per_megagram,
    organic_phosphorus_g_per_megagram,
    ammonium_g_per_megagram,
    nitrate_g_per_megagram,
    phosphate_g_per_megagram,
    aluminum_g_per_megagram,
    iron_g_per_megagram,
    calcium_g_per_megagram,
    magnesium_g_per_megagram,
    sodium_g_per_megagram,
    potassium_g_per_megagram,
    sulfate_sulfur_g_per_megagram,
    chloride_g_per_megagram,
    aluminum_phosphate_p_g_per_megagram,
    iron_phosphate_p_g_per_megagram,
    calcium_hydrogen_phosphate_p_g_per_megagram,
    apatite_phosphorus_g_per_megagram,
    aluminum_hydroxide_al_g_per_megagram,
    iron_hydroxide_fe_g_per_megagram,
    calcium_carbonate_ca_g_per_megagram,
    calcium_sulfate_ca_g_per_megagram,
    gapon_calcium_ammonium,
    gapon_calcium_hydrogen,
    gapon_calcium_aluminum,
    gapon_calcium_magnesium,
    gapon_calcium_sodium,
    gapon_calcium_potassium,
    initial_liquid_water,
    initial_ice_water,
    fine_litter_carbon_g_m2,
    fine_litter_nitrogen_g_m2,
    fine_litter_phosphorus_g_m2,
    woody_litter_carbon_g_m2,
    woody_litter_nitrogen_g_m2,
    woody_litter_phosphorus_g_m2,
    manure_carbon_g_m2,
    manure_nitrogen_g_m2,
    manure_phosphorus_g_m2,
};

pub const SoilProfile = struct {
    allocator: std.mem.Allocator,
    field_capacity_potential_megapascal: f64,
    wilting_point_potential_megapascal: f64,
    wet_soil_albedo: f64,
    surface_litter_ph: f64,
    surface_fine_litter_carbon_g_c_per_m2: f64,
    surface_fine_litter_nitrogen_g_n_per_m2: f64,
    surface_fine_litter_phosphorus_g_p_per_m2: f64,
    surface_woody_litter_carbon_g_c_per_m2: f64,
    surface_woody_litter_nitrogen_g_n_per_m2: f64,
    surface_woody_litter_phosphorus_g_p_per_m2: f64,
    surface_manure_carbon_g_c_per_m2: f64,
    surface_manure_nitrogen_g_n_per_m2: f64,
    surface_manure_phosphorus_g_p_per_m2: f64,
    surface_plant_litter_type: i32,
    surface_manure_type: i32,
    surface_layer_index: usize,
    maximum_rooting_layer_index: usize,
    described_layer_count: usize,
    total_layer_count: usize,
    reconstructed_profile: bool,
    /// Required original van Genuchten inflection pressure-head record. A
    /// user-supplied zero explicitly requests runtime texture defaults.
    van_genuchten_inflection_pressure_head_m: []f64,
    depth_to_layer_bottom_m: []f64,
    initial_bulk_density_megagrams_per_m3: []f64,
    field_capacity_m3_m3: []f64,
    wilting_point_m3_m3: []f64,
    vertical_saturated_conductivity_mm_h: []f64,
    lateral_saturated_conductivity_mm_h: []f64,
    sand_kg_per_megagram: []f64,
    silt_kg_per_megagram: []f64,
    macropore_fraction: []f64,
    rock_fraction: []f64,
    ph: []f64,
    cation_exchange_capacity_cmol_kg: []f64,
    anion_exchange_capacity_cmol_kg: []f64,
    layer_properties: []f64,

    pub fn deinit(self: *SoilProfile) void {
        inline for (@typeInfo(SoilProfile).@"struct".fields) |field| {
            if (field.type == []f64) self.allocator.free(@field(self, field.name));
        }
        self.* = undefined;
    }

    pub fn property(self: SoilProfile, layer_property: LayerProperty) []const f64 {
        const property_index: usize = @intFromEnum(layer_property);
        const start = property_index * self.total_layer_count;
        return self.layer_properties[start .. start + self.total_layer_count];
    }
};

/// Reads the surface header and physical/hydrologic profile records used at
/// the start of READI. Remaining chemistry records stay available for the next
/// translation stage and are not silently interpreted as another format.
pub fn parsePhysicalProfile(allocator: std.mem.Allocator, source: []const u8) !SoilProfile {
    var records = std.mem.splitScalar(u8, source, '\n');
    var header = delimited_input.recordTokens(try nextRecord(&records));
    var result: SoilProfile = undefined;
    result.allocator = allocator;
    try parsePhysicalProfileHeader(&result, &header);

    var allocated_fields: usize = 0;
    errdefer freeAllocatedFields(&result, allocated_fields);
    try parsePhysicalLayerRecords(allocator, &records, &result, &allocated_fields);
    try parseLayerProperties(allocator, &records, &result);
    errdefer allocator.free(result.layer_properties);
    if (try nextRecordOrNull(&records) != null) return error.TrailingSoilProfileRecord;
    try validate(result);
    return result;
}

noinline fn parsePhysicalProfileHeader(result: *SoilProfile, header: *RecordTokens) !void {
    result.field_capacity_potential_megapascal = try number(f64, header);
    result.wilting_point_potential_megapascal = try number(f64, header);
    result.wet_soil_albedo = try number(f64, header);
    result.surface_litter_ph = try number(f64, header);
    result.surface_fine_litter_carbon_g_c_per_m2 = try number(f64, header);
    result.surface_fine_litter_nitrogen_g_n_per_m2 = try number(f64, header);
    result.surface_fine_litter_phosphorus_g_p_per_m2 = try number(f64, header);
    result.surface_woody_litter_carbon_g_c_per_m2 = try number(f64, header);
    result.surface_woody_litter_nitrogen_g_n_per_m2 = try number(f64, header);
    result.surface_woody_litter_phosphorus_g_p_per_m2 = try number(f64, header);
    result.surface_manure_carbon_g_c_per_m2 = try number(f64, header);
    result.surface_manure_nitrogen_g_n_per_m2 = try number(f64, header);
    result.surface_manure_phosphorus_g_p_per_m2 = try number(f64, header);
    result.surface_plant_litter_type = try number(i32, header);
    result.surface_manure_type = try number(i32, header);
    result.surface_layer_index = try number(usize, header);
    result.maximum_rooting_layer_index = try number(usize, header);
    const additional_described_layers = try number(usize, header);
    const additional_extrapolated_layers = try number(usize, header);
    result.reconstructed_profile = (try number(i32, header)) != 0;
    try requireEnd(header);
    if (result.surface_layer_index == 0 or result.maximum_rooting_layer_index < result.surface_layer_index) return error.InvalidSoilLayerRange;
    const maximum_described_layer = try std.math.add(usize, result.maximum_rooting_layer_index, additional_described_layers);
    result.described_layer_count = try std.math.add(usize, maximum_described_layer - result.surface_layer_index, 1);
    result.total_layer_count = try std.math.add(usize, maximum_described_layer, additional_extrapolated_layers);
}

noinline fn parsePhysicalLayerRecords(
    allocator: std.mem.Allocator,
    records: *RecordIterator,
    result: *SoilProfile,
    allocated_fields: *usize,
) !void {
    result.van_genuchten_inflection_pressure_head_m =
        try allocator.alloc(f64, result.described_layer_count);
    allocated_fields.* += 1;
    result.depth_to_layer_bottom_m =
        try parseLayerRecord(allocator, records, result.described_layer_count);
    allocated_fields.* += 1;
    result.initial_bulk_density_megagrams_per_m3 =
        try parseLayerRecord(allocator, records, result.described_layer_count);
    allocated_fields.* += 1;

    // This compulsory named record is immediately above field capacity.
    var inflection_tokens = delimited_input.recordTokens(try nextRecord(records));
    const record_name = inflection_tokens.next() orelse return error.IncompleteSoilProfileRecord;
    if (!std.ascii.eqlIgnoreCase(
        record_name,
        "van_genuchten_inflection_pressure_head_m",
    )) return error.MissingVanGenuchtenInflectionPressureHeadRecord;
    for (result.van_genuchten_inflection_pressure_head_m) |*pressure_head_m|
        pressure_head_m.* = try number(f64, &inflection_tokens);
    try requireEnd(&inflection_tokens);
    result.field_capacity_m3_m3 =
        try parseLayerRecord(allocator, records, result.described_layer_count);
    allocated_fields.* += 1;
    inline for ([_][]const u8{
        "wilting_point_m3_m3",
        "vertical_saturated_conductivity_mm_h",
        "lateral_saturated_conductivity_mm_h",
        "sand_kg_per_megagram",
        "silt_kg_per_megagram",
        "macropore_fraction",
        "rock_fraction",
        "ph",
        "cation_exchange_capacity_cmol_kg",
        "anion_exchange_capacity_cmol_kg",
    }) |field_name| {
        @field(result, field_name) = try parseLayerRecord(allocator, records, result.described_layer_count);
        allocated_fields.* += 1;
    }
    try expandPhysicalBoundaryLayers(result);
}

noinline fn parseLayerProperties(
    allocator: std.mem.Allocator,
    records: *RecordIterator,
    result: *SoilProfile,
) !void {
    const property_count = @typeInfo(LayerProperty).@"enum".fields.len;
    result.layer_properties = try allocator.alloc(f64, try std.math.mul(usize, property_count, result.total_layer_count));
    errdefer allocator.free(result.layer_properties);
    inline for (@typeInfo(LayerProperty).@"enum".fields, 0..) |property_field, property_index| {
        const start = property_index * result.total_layer_count;
        const values = result.layer_properties[start .. start + result.total_layer_count];
        var fields = delimited_input.recordTokens(try nextRecord(records));
        for (values[0..result.described_layer_count]) |*value| {
            value.* = try number(f64, &fields);
            if (!std.math.isFinite(value.*)) {
                std.log.err("non-finite soil property: property={s}", .{property_field.name});
                return error.NonFiniteSoilProperty;
            }
        }
        try requireEnd(&fields);
        var layer = result.described_layer_count;
        while (layer < result.total_layer_count) : (layer += 1) {
            const property: LayerProperty = @enumFromInt(property_index);
            values[layer] = switch (property) {
                .total_organic_carbon_kg_per_megagram,
                .particulate_organic_carbon_kg_per_megagram,
                .organic_nitrogen_g_per_megagram,
                .organic_phosphorus_g_per_megagram,
                => 0.25 * values[layer - 1],
                .fine_litter_carbon_g_m2,
                .fine_litter_nitrogen_g_m2,
                .fine_litter_phosphorus_g_m2,
                .woody_litter_carbon_g_m2,
                .woody_litter_nitrogen_g_m2,
                .woody_litter_phosphorus_g_m2,
                .manure_carbon_g_m2,
                .manure_nitrogen_g_m2,
                .manure_phosphorus_g_m2,
                => 0.0,
                else => values[layer - 1],
            };
        }
    }
}

fn expandPhysicalBoundaryLayers(profile: *SoilProfile) !void {
    if (profile.total_layer_count == profile.described_layer_count) return;
    inline for ([_][]const u8{
        "van_genuchten_inflection_pressure_head_m",
        "depth_to_layer_bottom_m",
        "initial_bulk_density_megagrams_per_m3",
        "field_capacity_m3_m3",
        "wilting_point_m3_m3",
        "vertical_saturated_conductivity_mm_h",
        "lateral_saturated_conductivity_mm_h",
        "sand_kg_per_megagram",
        "silt_kg_per_megagram",
        "macropore_fraction",
        "rock_fraction",
        "ph",
        "cation_exchange_capacity_cmol_kg",
        "anion_exchange_capacity_cmol_kg",
    }) |field_name| {
        @field(profile, field_name) = try profile.allocator.realloc(@field(profile, field_name), profile.total_layer_count);
        const values = @field(profile, field_name);
        var layer = profile.described_layer_count;
        while (layer < profile.total_layer_count) : (layer += 1) {
            values[layer] = if (comptime std.mem.eql(u8, field_name, "depth_to_layer_bottom_m"))
                2.0 * values[layer - 1] - values[layer - 2]
            else
                values[layer - 1];
        }
    }
}

fn validate(profile: SoilProfile) !void {
    inline for (.{
        profile.surface_fine_litter_carbon_g_c_per_m2,
        profile.surface_fine_litter_nitrogen_g_n_per_m2,
        profile.surface_fine_litter_phosphorus_g_p_per_m2,
        profile.surface_woody_litter_carbon_g_c_per_m2,
        profile.surface_woody_litter_nitrogen_g_n_per_m2,
        profile.surface_woody_litter_phosphorus_g_p_per_m2,
        profile.surface_manure_carbon_g_c_per_m2,
        profile.surface_manure_nitrogen_g_n_per_m2,
        profile.surface_manure_phosphorus_g_p_per_m2,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceOrganicMatter;
    var previous_depth_m: f64 = 0;
    for (profile.depth_to_layer_bottom_m, 0..) |depth_m, index| {
        if (!std.math.isFinite(depth_m) or depth_m <= previous_depth_m) {
            std.log.err("soil layer bottoms must increase: layer={d} previous_m={e} current_m={e}", .{ index, previous_depth_m, depth_m });
            return error.NonIncreasingSoilDepth;
        }
        previous_depth_m = depth_m;
    }
    for (profile.initial_bulk_density_megagrams_per_m3) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidBulkDensity;
    for (profile.van_genuchten_inflection_pressure_head_m) |pressure_head_m| {
        if (!std.math.isFinite(pressure_head_m) or pressure_head_m > 0)
            return error.InvalidVanGenuchtenInflectionPressureHead;
    }
    for (profile.sand_kg_per_megagram, profile.silt_kg_per_megagram) |sand, silt| {
        if (!std.math.isFinite(sand) or !std.math.isFinite(silt) or sand < 0 or silt < 0 or sand + silt > 1000) return error.InvalidSoilTexture;
    }
}

fn parseLayerRecord(allocator: std.mem.Allocator, records: anytype, count: usize) ![]f64 {
    return parseLayerRecordText(allocator, try nextRecord(records), count);
}

fn parseLayerRecordText(allocator: std.mem.Allocator, record: []const u8, count: usize) ![]f64 {
    var fields = delimited_input.recordTokens(record);
    const values = try allocator.alloc(f64, count);
    errdefer allocator.free(values);
    for (values) |*value| value.* = try number(f64, &fields);
    try requireEnd(&fields);
    return values;
}

fn freeAllocatedFields(profile: *SoilProfile, count: usize) void {
    const names = [_][]const u8{
        "van_genuchten_inflection_pressure_head_m",
        "depth_to_layer_bottom_m",
        "initial_bulk_density_megagrams_per_m3",
        "field_capacity_m3_m3",
        "wilting_point_m3_m3",
        "vertical_saturated_conductivity_mm_h",
        "lateral_saturated_conductivity_mm_h",
        "sand_kg_per_megagram",
        "silt_kg_per_megagram",
        "macropore_fraction",
        "rock_fraction",
        "ph",
        "cation_exchange_capacity_cmol_kg",
        "anion_exchange_capacity_cmol_kg",
    };
    inline for (names, 0..) |name, index| {
        if (index < count) profile.allocator.free(@field(profile, name));
    }
}

fn nextRecord(records: anytype) ![]const u8 {
    return try nextRecordOrNull(records) orelse error.UnexpectedEndOfSoilProfile;
}

fn nextRecordOrNull(records: anytype) !?[]const u8 {
    while (records.next()) |record| {
        if (hasEmptyExplicitField(record))
            return error.EmptySoilProfileRecordValue;
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
        if (std.mem.trim(u8, trimmed[field_start..index], " \r").len == 0)
            return true;
        field_start = index + 1;
        saw_explicit_delimiter = true;
    }
    return saw_explicit_delimiter and
        std.mem.trim(u8, trimmed[field_start..], " \r").len == 0;
}

fn requireEnd(tokens: anytype) !void {
    if (tokens.next() != null) return error.TrailingSoilProfileRecordData;
}

fn number(comptime T: type, tokens: anytype) !T {
    const text = tokens.next() orelse return error.IncompleteSoilProfileRecord;
    return switch (@typeInfo(T)) {
        .float => std.fmt.parseFloat(T, text),
        .int => std.fmt.parseInt(T, text, 10),
        else => @compileError("unsupported soil-profile number type"),
    };
}

test "parse physical properties from self-contained soil profile" {
    const source = try testSoilProfileSource(
        std.testing.allocator,
        @typeInfo(LayerProperty).@"enum".fields.len,
    );
    defer std.testing.allocator.free(source);
    var profile = try parsePhysicalProfile(std.testing.allocator, source);
    defer profile.deinit();
    try std.testing.expectEqual(@as(usize, 1), profile.described_layer_count);
    try std.testing.expectEqual(@as(usize, 1), profile.total_layer_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), profile.depth_to_layer_bottom_m[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 400), profile.sand_kg_per_megagram[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 14.85), profile.property(.total_organic_carbon_kg_per_megagram)[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 11), profile.surface_fine_litter_carbon_g_c_per_m2, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 22), profile.surface_woody_litter_carbon_g_c_per_m2, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 33), profile.surface_manure_carbon_g_c_per_m2, 1.0e-12);
    try std.testing.expectEqual(@as(i32, 8), profile.surface_plant_litter_type);
    try std.testing.expectEqual(@as(i32, 2), profile.surface_manure_type);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), profile.property(.initial_liquid_water)[0], 1.0e-12);
    try std.testing.expectEqual(@typeInfo(LayerProperty).@"enum".fields.len, profile.layer_properties.len);
    try std.testing.expectEqual(@as(f64, 0.0), profile.property(.fine_litter_carbon_g_m2)[0]);
}

test "required van Genuchten inflection record is case insensitive and pipe delimited" {
    const source = try testSoilProfileSource(
        std.testing.allocator,
        @typeInfo(LayerProperty).@"enum".fields.len,
    );
    defer std.testing.allocator.free(source);
    var insertion_index: usize = 0;
    for (0..3) |_| {
        const relative_end = std.mem.indexOfScalar(
            u8,
            source[insertion_index..],
            '\n',
        ) orelse return error.IncompleteTestSoilProfile;
        insertion_index += relative_end + 1;
    }
    const existing_record_end = insertion_index + (std.mem.indexOfScalar(
        u8,
        source[insertion_index..],
        '\n',
    ) orelse return error.IncompleteTestSoilProfile) + 1;
    const extended = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}Van_Genuchten_Inflection_Pressure_Head_M|-0.25\n{s}",
        .{ source[0..insertion_index], source[existing_record_end..] },
    );
    defer std.testing.allocator.free(extended);
    var profile = try parsePhysicalProfile(std.testing.allocator, extended);
    defer profile.deinit();
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.25),
        profile.van_genuchten_inflection_pressure_head_m[0],
        1.0e-15,
    );
}

fn testSoilProfileSource(
    allocator: std.mem.Allocator,
    layer_property_count: usize,
) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "-0.01,-1.5,0.2,6,11,1.1,0.11,22,2.2,0.22,33,3.3,0.33,8,2,1,1,0,0,0\n");
    const physical_records = [_][]const u8{
        "0.1\n",                                        "1.3\n",
        "van_genuchten_inflection_pressure_head_m 0\n", "0.30\n",
        "0.10\n",                                       "10\n",
        "5\n",                                          "400\n",
        "400\n",                                        "0.05\n",
        "0\n",                                          "6.5\n",
        "10\n",                                         "1\n",
    };
    for (physical_records) |record|
        try source.appendSlice(allocator, record);
    for (0..layer_property_count) |property_index|
        try source.appendSlice(allocator, switch (property_index) {
            0 => "14.85\n",
            29 => "1\n",
            30 => "-1\n",
            else => "0\n",
        });
    return source.toOwnedSlice(allocator);
}

test "soil profile records reject empty explicit delimiter fields" {
    inline for (.{
        "-0.01,-1.5,,0.2,6,11,1.1,0.11,22,2.2,0.22,33,3.3,0.33,8,2,1,1,0,0,0\n",
        "-0.01|-1.5| |0.2|6|11|1.1|0.11|22|2.2|0.22|33|3.3|0.33|8|2|1|1|0|0|0\n",
        "-0.01\t-1.5\t\t0.2\t6\t11\t1.1\t0.11\t22\t2.2\t0.22\t33\t3.3\t0.33\t8\t2\t1\t1\t0\t0\t0\n",
    }) |source| try std.testing.expectError(
        error.EmptySoilProfileRecordValue,
        parsePhysicalProfile(std.testing.allocator, source),
    );
}

test "soil profile empty-field check preserves spacing and comments" {
    try std.testing.expect(!hasEmptyExplicitField(
        "0.1  1.3  0.3 # valid spaces",
    ));
    try std.testing.expect(!hasEmptyExplicitField(
        "0.1, 1.3 | 0.3\t0.2 # mixed delimiters",
    ));
    try std.testing.expect(!hasEmptyExplicitField("# comment only"));
}
