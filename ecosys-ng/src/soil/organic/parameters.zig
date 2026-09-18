const std = @import("std");
const delimited_input = @import("../../io/input/delimited_input.zig");
const organic = @import("initialization.zig");

const Record = enum {
    initialization_scalars,
    microbial_kinetic_fraction,
    microbial_residue_fraction,
    microbial_carbon_budget_fraction,
    residue_carbon_budget_fraction,
    dissolved_carbon_fraction,
    adsorbed_carbon_fraction,
    heterotroph_population_fraction,
    autotroph_population_fraction,
    microbial_nitrogen_to_carbon,
    microbial_phosphorus_to_carbon,
    substrate_nitrogen_to_carbon,
    substrate_phosphorus_to_carbon,
    residue_structural_fraction,
    particulate_structural_fraction,
    surface_woody_structural_fraction,
    surface_plant_structural_fraction,
    surface_manure_structural_fraction,
    surface_residue_nitrogen_weight,
    surface_residue_phosphorus_weight,
    soil_organic_sorption,
    soil_organic_decomposition,
    soil_organic_priming,
};

pub const SoilOrganicDecompositionParameters = struct {
    structural_rate_g_c_per_g_activity_h: [organic.substrate_count][organic.structural_fraction_count]f64,
    microbial_residue_rate_g_c_per_g_activity_h: [organic.residue_fraction_count]f64,
    sorbed_organic_rate_g_c_per_g_activity_h: f64,
    sorbed_acetate_rate_g_c_per_g_activity_h: f64,
    environment: @import("../biogeochemistry/organic_substrate_decomposition.zig").EnvironmentParameters,
};

pub const OwnedParameters = struct {
    allocator: std.mem.Allocator,
    residue_microbial_fraction: f64,
    humus_microbial_half_saturation_g_c_per_megagram: f64,
    less_resistant_humus_fraction_at_surface: f64,
    nutrient_protection_exponent: f64,
    phosphorus_nutrient_weight: f64,
    reference_accumulation_fraction: f64,
    maximum_reference_humus_g_c_per_m2: f64,
    fraction_at_reference_accumulation: f64,
    surface_litter_dry_mass_megagrams_per_g_c: f64,
    surface_litter_water_capacity_m3_per_g_c: f64,
    microbial_kinetic_fraction: []f64,
    microbial_residue_fraction: []f64,
    microbial_carbon_budget_fraction: []f64,
    residue_carbon_budget_fraction: []f64,
    dissolved_carbon_fraction: []f64,
    adsorbed_carbon_fraction: []f64,
    heterotroph_population_fraction: []f64,
    autotroph_population_fraction: []f64,
    microbial_nitrogen_to_carbon: []f64,
    microbial_phosphorus_to_carbon: []f64,
    substrate_nitrogen_to_carbon: []f64,
    substrate_phosphorus_to_carbon: []f64,
    residue_structural_fraction: []f64,
    particulate_structural_fraction: []f64,
    surface_woody_structural_fraction: []f64,
    surface_plant_structural_fraction: []f64,
    surface_manure_structural_fraction: []f64,
    surface_residue_nitrogen_weight: []f64,
    surface_residue_phosphorus_weight: []f64,
    soil_organic_sorption_rate_per_h: f64,
    soil_organic_adsorption_coefficient: f64,
    soil_organic_decomposition: SoilOrganicDecompositionParameters,
    soil_dissolved_priming_rate_per_h: f64,
    soil_microbial_priming_rate_per_h: f64,

    pub fn deinit(self: *OwnedParameters) void {
        inline for (@typeInfo(OwnedParameters).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn mapped(self: *const OwnedParameters, depth_partition_factor_by_layer: []const f64, wetland_layer_by_layer: []const bool) organic.MappedRuntimeParameters {
        return .{
            .pool_allocation = .{
                .microbial_kinetic_fraction = self.microbial_kinetic_fraction,
                .residue_fraction = self.microbial_residue_fraction,
                .dissolved_fraction = self.dissolved_carbon_fraction,
                .adsorbed_fraction = self.adsorbed_carbon_fraction,
                .heterotroph_population_fraction = self.heterotroph_population_fraction,
                .autotroph_population_fraction = self.autotroph_population_fraction,
                .microbial_nitrogen_to_carbon = self.surfaceMicrobialNitrogenToCarbon(),
                .microbial_phosphorus_to_carbon = self.surfaceMicrobialPhosphorusToCarbon(),
            },
            .microbial_derivation = .{
                .residue_microbial_fraction = self.residue_microbial_fraction,
                .humus_microbial_half_saturation_g_c_per_megagram = self.humus_microbial_half_saturation_g_c_per_megagram,
                .depth_partition_factor = 0,
                .microbial_budget_fraction = self.microbial_carbon_budget_fraction,
                .residue_budget_fraction = self.residue_carbon_budget_fraction,
                .dissolved_budget_fraction = self.dissolved_carbon_fraction,
                .adsorbed_budget_fraction = self.adsorbed_carbon_fraction,
                .microbial_kinetic_fraction = self.microbial_kinetic_fraction,
                .microbial_nitrogen_to_carbon = self.surfaceMicrobialNitrogenToCarbon(),
                .microbial_phosphorus_to_carbon = self.surfaceMicrobialPhosphorusToCarbon(),
                .residue_nitrogen_to_carbon = self.substrate_nitrogen_to_carbon,
                .residue_phosphorus_to_carbon = self.substrate_phosphorus_to_carbon,
            },
            .depth_partition_factor_by_layer = depth_partition_factor_by_layer,
            .wetland_layer_by_layer = wetland_layer_by_layer,
            .default_complex_nitrogen_to_carbon = self.substrate_nitrogen_to_carbon,
            .default_complex_phosphorus_to_carbon = self.substrate_phosphorus_to_carbon,
            .residue_structural_fraction = self.residue_structural_fraction,
            .manure_structural_fraction_by_type = self.surface_manure_structural_fraction,
            .particulate_structural_fraction = self.particulate_structural_fraction,
            .less_resistant_humus_fraction_at_surface = self.less_resistant_humus_fraction_at_surface,
            .nutrient_protection_exponent = self.nutrient_protection_exponent,
            .phosphorus_nutrient_weight = self.phosphorus_nutrient_weight,
        };
    }

    pub fn humusDepthParameters(self: *const OwnedParameters) organic.HumusDepthPartitionParameters {
        return .{
            .reference_accumulation_fraction = self.reference_accumulation_fraction,
            .maximum_reference_humus_g_c_per_m2 = self.maximum_reference_humus_g_c_per_m2,
            .fraction_at_reference_accumulation = self.fraction_at_reference_accumulation,
        };
    }

    pub fn surface(self: *const OwnedParameters) organic.SurfaceRuntimeParameters {
        return .{
            .pool_allocation = self.mapped(&.{}, &.{}).pool_allocation,
            .residue_microbial_fraction = self.residue_microbial_fraction,
            .default_complex_nitrogen_to_carbon = self.substrate_nitrogen_to_carbon,
            .default_complex_phosphorus_to_carbon = self.substrate_phosphorus_to_carbon,
            .woody_structural_fraction = self.surface_woody_structural_fraction,
            .plant_structural_fraction_by_type = self.surface_plant_structural_fraction,
            .manure_structural_fraction_by_type = self.surface_manure_structural_fraction,
            .residue_nitrogen_weight = self.surface_residue_nitrogen_weight,
            .residue_phosphorus_weight = self.surface_residue_phosphorus_weight,
        };
    }

    pub fn surfaceMicrobialNitrogenToCarbon(self: *const OwnedParameters) []const f64 {
        return self.microbial_nitrogen_to_carbon[0 .. organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count];
    }

    pub fn surfaceMicrobialPhosphorusToCarbon(self: *const OwnedParameters) []const f64 {
        return self.microbial_phosphorus_to_carbon[0 .. organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count];
    }
};

pub noinline fn parse(allocator: std.mem.Allocator, source: []const u8) !OwnedParameters {
    var result: OwnedParameters = undefined;
    result.allocator = allocator;
    var allocated: usize = 0;
    errdefer freeAllocated(&result, allocated);
    inline for (@typeInfo(OwnedParameters).@"struct".fields) |field| if (field.type == []f64) {
        @field(result, field.name) = try allocator.alloc(f64, expectedCount(field.name));
        allocated += 1;
    };
    var seen = [_]bool{false} ** @typeInfo(Record).@"enum".fields.len;
    var records = std.mem.splitScalar(u8, source, '\n');
    while (records.next()) |line| {
        if (hasEmptyExplicitField(line))
            return error.EmptyOrganicParameterValue;
        var tokens = delimited_input.recordTokens(line);
        const label = tokens.next() orelse continue;
        if (label[0] == '#') continue;
        const record = recordFromLabel(label) orelse return error.UnknownOrganicParameterRecord;
        const record_index: usize = @intFromEnum(record);
        if (seen[record_index]) return error.DuplicateOrganicParameterRecord;
        seen[record_index] = true;
        switch (record) {
            .initialization_scalars => {
                result.residue_microbial_fraction = try nextFinite(&tokens);
                result.humus_microbial_half_saturation_g_c_per_megagram = try nextFinite(&tokens);
                result.less_resistant_humus_fraction_at_surface = try nextFinite(&tokens);
                result.nutrient_protection_exponent = try nextFinite(&tokens);
                result.phosphorus_nutrient_weight = try nextFinite(&tokens);
                result.reference_accumulation_fraction = try nextFinite(&tokens);
                result.maximum_reference_humus_g_c_per_m2 = try nextFinite(&tokens);
                result.fraction_at_reference_accumulation = try nextFinite(&tokens);
                result.surface_litter_dry_mass_megagrams_per_g_c = try nextFinite(&tokens);
                result.surface_litter_water_capacity_m3_per_g_c = try nextFinite(&tokens);
                if (tokens.next() != null) return error.TooManyOrganicParameterValues;
            },
            .soil_organic_sorption => {
                result.soil_organic_sorption_rate_per_h = try nextFinite(&tokens);
                result.soil_organic_adsorption_coefficient = try nextFinite(&tokens);
                if (tokens.next() != null) return error.TooManyOrganicParameterValues;
            },
            .soil_organic_decomposition => {
                for (&result.soil_organic_decomposition.structural_rate_g_c_per_g_activity_h) |*substrate| {
                    for (substrate) |*value| value.* = try nextFinite(&tokens);
                }
                for (&result.soil_organic_decomposition.microbial_residue_rate_g_c_per_g_activity_h) |*value| value.* = try nextFinite(&tokens);
                result.soil_organic_decomposition.sorbed_organic_rate_g_c_per_g_activity_h = try nextFinite(&tokens);
                result.soil_organic_decomposition.sorbed_acetate_rate_g_c_per_g_activity_h = try nextFinite(&tokens);
                inline for (@typeInfo(@TypeOf(result.soil_organic_decomposition.environment)).@"struct".fields) |field| @field(result.soil_organic_decomposition.environment, field.name) = try nextFinite(&tokens);
                if (tokens.next() != null) return error.TooManyOrganicParameterValues;
            },
            .soil_organic_priming => {
                result.soil_dissolved_priming_rate_per_h = try nextFinite(&tokens);
                result.soil_microbial_priming_rate_per_h = try nextFinite(&tokens);
                if (tokens.next() != null) return error.TooManyOrganicParameterValues;
            },
            inline else => |kind| try parseArrayRecord(&tokens, arrayFor(&result, kind)),
        }
    }
    for (seen) |present| if (!present) return error.MissingOrganicParameterRecord;
    try validate(&result);
    return result;
}

fn hasEmptyExplicitField(line: []const u8) bool {
    const content = if (std.mem.indexOfScalar(u8, line, '#')) |comment|
        line[0..comment]
    else
        line;
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

pub fn sourceParameters(allocator: std.mem.Allocator) !OwnedParameters {
    var result: OwnedParameters = undefined;
    result.allocator = allocator;
    var allocated: usize = 0;
    errdefer freeAllocated(&result, allocated);
    inline for (@typeInfo(OwnedParameters).@"struct".fields) |field| if (field.type == []f64) {
        @field(result, field.name) = try allocator.alloc(f64, expectedCount(field.name));
        @memset(@field(result, field.name), 0);
        allocated += 1;
    };
    result.residue_microbial_fraction = 0.25;
    result.humus_microbial_half_saturation_g_c_per_megagram = 2.5e4;
    result.less_resistant_humus_fraction_at_surface = 0.20;
    result.nutrient_protection_exponent = 5;
    result.phosphorus_nutrient_weight = 10;
    result.reference_accumulation_fraction = 0.25;
    result.maximum_reference_humus_g_c_per_m2 = 5.0e3;
    result.fraction_at_reference_accumulation = 0.5;
    result.surface_litter_dry_mass_megagrams_per_g_c = 1.82e-6;
    result.surface_litter_water_capacity_m3_per_g_c = 8.0e-6;
    @memcpy(result.microbial_kinetic_fraction[0..15], &[_]f64{
        0.010, 0.050, 0.005, 0.050, 0.050, 0.005, 0.050, 0.050, 0.005,
        0.010, 0.050, 0.005, 0.010, 0.050, 0.005,
    });
    @memcpy(result.microbial_residue_fraction[0..10], &[_]f64{ 0.01, 0.05, 0.01, 0.05, 0.01, 0.05, 0.001, 0.005, 0.001, 0.005 });
    @memset(result.microbial_carbon_budget_fraction[0..5], 0.01);
    @memset(result.residue_carbon_budget_fraction[0..5], 0.25);
    @memset(result.dissolved_carbon_fraction[0..5], 0.005);
    @memset(result.adsorbed_carbon_fraction[0..5], 0.05);
    @memcpy(result.heterotroph_population_fraction, &[_]f64{ 0.20, 0.20, 0.30, 0.20, 0.050, 0.025, 0.025 });
    @memcpy(result.autotroph_population_fraction, &[_]f64{ 0.06, 0.02, 0.01, 0, 0.01, 0, 0 });
    const substrate_n = [_]f64{ 0.0333, 0.0333, 0.0333, 0.05, 0.167 };
    const substrate_p = [_]f64{ 0.00333, 0.00333, 0.00333, 0.005, 0.0167 };
    @memcpy(result.substrate_nitrogen_to_carbon, &substrate_n);
    @memcpy(result.substrate_phosphorus_to_carbon, &substrate_p);
    for (0..organic.microbial_substrate_count) |substrate| {
        for (0..organic.microbial_population_count) |population| {
            const fungus = substrate <= 4 and population == 2;
            const labile_n: f64 = if (fungus) 0.111 else 0.167;
            const resistant_n: f64 = if (fungus) 0.083 else 0.125;
            const labile_p: f64 = if (fungus) 0.0111 else 0.0167;
            const resistant_p: f64 = if (fungus) 0.0083 else 0.0125;
            const index = (substrate * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
            @memcpy(result.microbial_nitrogen_to_carbon[index..][0..3], &[_]f64{ labile_n, resistant_n, 0.55 * labile_n + 0.45 * resistant_n });
            @memcpy(result.microbial_phosphorus_to_carbon[index..][0..3], &[_]f64{ labile_p, resistant_p, 0.55 * labile_p + 0.45 * resistant_p });
        }
    }
    @memcpy(result.residue_structural_fraction, &[_]f64{
        0,     0,     0.20,  0.80,  0,
        0.02,  0.06,  0.34,  0.58,  0,
        0.138, 0.401, 0.316, 0.145, 0,
    });
    @memcpy(result.particulate_structural_fraction, &[_]f64{ 1, 0, 0, 0, 0 });
    @memcpy(result.surface_woody_structural_fraction, &[_]f64{ 0, 0.045, 0.660, 0.295, 0 });
    // STARTS 847--916, IXTYP 1..11 then the default row: maize, wheat, soybean,
    // new straw, old straw, compost, green manure, new deciduous forest, new
    // coniferous forest, old deciduous, old coniferous, default.
    //
    // Three rows previously held HOUR1 values instead of STARTS ones: IXTYP 4 and
    // 5 were transposed, and IXTYP 8 was {0, 1, 0, 0}, which is HOUR1's "simple
    // substrate" row and not a forest litter at all. The confusion had a single
    // cause, fixed in FERT-001: organic_fertilizer_application indexed this STARTS
    // array with a HOUR1 litter code, and a test asserted the two agreed on
    // exactly these rows, so this table had been bent to fit the wrong consumer.
    // With that consumer now reading its own codebook, this table is free to state
    // STARTS correctly. See FERT-001 in docs/discrepancy_register.md.
    //
    // Impact is confined to tests: production parses these fields from
    // runtime_parameters/starts_organic.txt, which already carried the STARTS
    // values, so sourceParameters() is a test-only default provider.
    const plant_rows = [_][5]f64{
        .{ 0.080, 0.245, 0.613, 0.062, 0 }, .{ 0.125, 0.171, 0.560, 0.144, 0 },
        .{ 0.138, 0.426, 0.316, 0.120, 0 }, .{ 0.036, 0.044, 0.767, 0.153, 0 },
        .{ 0.075, 0.125, 0.550, 0.250, 0 }, .{ 0.143, 0.015, 0.640, 0.202, 0 },
        .{ 0.202, 0.013, 0.560, 0.225, 0 }, .{ 0.07, 0.41, 0.36, 0.16, 0 },
        .{ 0.07, 0.25, 0.38, 0.30, 0 },     .{ 0.02, 0.06, 0.34, 0.58, 0 },
        .{ 0.02, 0.06, 0.34, 0.58, 0 },     .{ 0.075, 0.125, 0.550, 0.250, 0 },
    };
    for (plant_rows, 0..) |row, row_index| {
        @memcpy(result.surface_plant_structural_fraction[row_index * 5 ..][0..5], &row);
    }
    @memcpy(result.surface_manure_structural_fraction, &[_]f64{ 0.036, 0.044, 0.630, 0.290, 0, 0.138, 0.401, 0.316, 0.145, 0 });
    @memcpy(result.surface_residue_nitrogen_weight, &[_]f64{ 0.005, 0.005, 0.005, 0.020, 0, 0.020, 0.020, 0.020, 0.020, 0, 0.020, 0.020, 0.020, 0.020, 0 });
    @memcpy(result.surface_residue_phosphorus_weight, &[_]f64{ 0.0005, 0.0005, 0.0005, 0.0020, 0, 0.0020, 0.0020, 0.0020, 0.0020, 0, 0.0020, 0.0020, 0.0020, 0.0020, 0 });
    result.soil_organic_sorption_rate_per_h = 0.1;
    result.soil_organic_adsorption_coefficient = 1;
    result.soil_organic_decomposition = .{
        .structural_rate_g_c_per_g_activity_h = .{
            .{ 7.5, 7.5, 1.5, 0.5, 0.0015 },   .{ 7.5, 7.5, 1.5, 0.5, 0.0015 },
            .{ 7.5, 7.5, 1.5, 0.5, 0.0015 },   .{ 0.125, 0, 0, 0, 0.0015 },
            .{ 0.0375, 0.0075, 0, 0, 0.0015 },
        },
        .microbial_residue_rate_g_c_per_g_activity_h = .{ 7.5, 1.5 },
        .sorbed_organic_rate_g_c_per_g_activity_h = 0.25,
        .sorbed_acetate_rate_g_c_per_g_activity_h = 0.25,
        .environment = .{
            .surface_activity_half_saturation_g_c_per_m3 = 10,
            .soil_activity_half_saturation_g_c_per_m3 = 10,
            .surface_activity_inhibition_g_c_per_m3_per_step = 50,
            .soil_activity_inhibition_g_c_per_m3_per_step = 50,
            .dissolved_carbon_product_inhibition_g_c_per_m3 = 1200,
        },
    };
    result.soil_dissolved_priming_rate_per_h = 0.01;
    result.soil_microbial_priming_rate_per_h = 0.001;
    try validate(&result);
    return result;
}

fn validate(parameters: *const OwnedParameters) !void {
    inline for (.{ parameters.residue_microbial_fraction, parameters.humus_microbial_half_saturation_g_c_per_megagram, parameters.less_resistant_humus_fraction_at_surface, parameters.nutrient_protection_exponent, parameters.phosphorus_nutrient_weight, parameters.reference_accumulation_fraction, parameters.maximum_reference_humus_g_c_per_m2, parameters.fraction_at_reference_accumulation, parameters.surface_litter_dry_mass_megagrams_per_g_c, parameters.surface_litter_water_capacity_m3_per_g_c, parameters.soil_organic_sorption_rate_per_h, parameters.soil_organic_adsorption_coefficient }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicParameter;
    for (parameters.soil_organic_decomposition.structural_rate_g_c_per_g_activity_h) |rates| for (rates) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicParameter;
    for (parameters.soil_organic_decomposition.microbial_residue_rate_g_c_per_g_activity_h) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicParameter;
    inline for (.{ parameters.soil_organic_decomposition.sorbed_organic_rate_g_c_per_g_activity_h, parameters.soil_organic_decomposition.sorbed_acetate_rate_g_c_per_g_activity_h }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicParameter;
    inline for (.{ parameters.soil_dissolved_priming_rate_per_h, parameters.soil_microbial_priming_rate_per_h }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicParameter;
    inline for (@typeInfo(@TypeOf(parameters.soil_organic_decomposition.environment)).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters.soil_organic_decomposition.environment, field.name)) or @field(parameters.soil_organic_decomposition.environment, field.name) <= 0) return error.InvalidOrganicParameter;
    if (parameters.humus_microbial_half_saturation_g_c_per_megagram <= 0 or parameters.less_resistant_humus_fraction_at_surface > 1 or parameters.reference_accumulation_fraction > 1 or parameters.fraction_at_reference_accumulation <= 0 or parameters.fraction_at_reference_accumulation > 1 or parameters.surface_litter_dry_mass_megagrams_per_g_c <= 0 or parameters.surface_litter_water_capacity_m3_per_g_c <= 0) return error.InvalidOrganicParameter;
    inline for (@typeInfo(OwnedParameters).@"struct".fields) |field| if (field.type == []f64) for (@field(parameters, field.name)) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidOrganicParameter;
    for (0..3) |substrate| {
        var sum: f64 = 0;
        for (parameters.residue_structural_fraction[substrate * organic.structural_fraction_count ..][0..organic.structural_fraction_count]) |value| sum += value;
        if (@abs(sum - 1) > 1.0e-12) return error.InvalidOrganicStructuralFractions;
    }
    var particulate_sum: f64 = 0;
    for (parameters.particulate_structural_fraction) |value| particulate_sum += value;
    if (@abs(particulate_sum - 1) > 1.0e-12) return error.InvalidOrganicStructuralFractions;
    var woody_sum: f64 = 0;
    for (parameters.surface_woody_structural_fraction) |value| woody_sum += value;
    if (@abs(woody_sum - 1) > 1.0e-12) return error.InvalidOrganicStructuralFractions;
    for (0..12) |litter_type| {
        var sum: f64 = 0;
        for (parameters.surface_plant_structural_fraction[litter_type * organic.structural_fraction_count ..][0..organic.structural_fraction_count]) |value| sum += value;
        if (@abs(sum - 1) > 1.0e-12) return error.InvalidOrganicStructuralFractions;
    }
    for (0..2) |manure_type| {
        var sum: f64 = 0;
        for (parameters.surface_manure_structural_fraction[manure_type * organic.structural_fraction_count ..][0..organic.structural_fraction_count]) |value| sum += value;
        if (@abs(sum - 1) > 1.0e-12) return error.InvalidOrganicStructuralFractions;
    }
}

fn parseArrayRecord(tokens: anytype, destination: []f64) !void {
    for (destination) |*value| value.* = try nextFinite(tokens);
    if (tokens.next() != null) return error.TooManyOrganicParameterValues;
}

fn nextFinite(tokens: anytype) !f64 {
    const token = tokens.next() orelse return error.MissingOrganicParameterValue;
    const value = std.fmt.parseFloat(f64, token) catch return error.InvalidOrganicParameterNumber;
    if (!std.math.isFinite(value)) return error.NonFiniteOrganicParameter;
    return value;
}

fn recordFromLabel(label: []const u8) ?Record {
    inline for (@typeInfo(Record).@"enum".fields) |field| if (std.ascii.eqlIgnoreCase(label, field.name)) return @enumFromInt(field.value);
    return null;
}

fn arrayFor(parameters: *OwnedParameters, record: Record) []f64 {
    return switch (record) {
        .initialization_scalars, .soil_organic_sorption, .soil_organic_decomposition, .soil_organic_priming => unreachable,
        .microbial_kinetic_fraction => parameters.microbial_kinetic_fraction,
        .microbial_residue_fraction => parameters.microbial_residue_fraction,
        .microbial_carbon_budget_fraction => parameters.microbial_carbon_budget_fraction,
        .residue_carbon_budget_fraction => parameters.residue_carbon_budget_fraction,
        .dissolved_carbon_fraction => parameters.dissolved_carbon_fraction,
        .adsorbed_carbon_fraction => parameters.adsorbed_carbon_fraction,
        .heterotroph_population_fraction => parameters.heterotroph_population_fraction,
        .autotroph_population_fraction => parameters.autotroph_population_fraction,
        .microbial_nitrogen_to_carbon => parameters.microbial_nitrogen_to_carbon,
        .microbial_phosphorus_to_carbon => parameters.microbial_phosphorus_to_carbon,
        .substrate_nitrogen_to_carbon => parameters.substrate_nitrogen_to_carbon,
        .substrate_phosphorus_to_carbon => parameters.substrate_phosphorus_to_carbon,
        .residue_structural_fraction => parameters.residue_structural_fraction,
        .particulate_structural_fraction => parameters.particulate_structural_fraction,
        .surface_woody_structural_fraction => parameters.surface_woody_structural_fraction,
        .surface_plant_structural_fraction => parameters.surface_plant_structural_fraction,
        .surface_manure_structural_fraction => parameters.surface_manure_structural_fraction,
        .surface_residue_nitrogen_weight => parameters.surface_residue_nitrogen_weight,
        .surface_residue_phosphorus_weight => parameters.surface_residue_phosphorus_weight,
    };
}

fn expectedCount(comptime name: []const u8) usize {
    if (std.mem.eql(u8, name, "microbial_kinetic_fraction")) return organic.substrate_count * organic.kinetic_fraction_count;
    if (std.mem.eql(u8, name, "microbial_residue_fraction")) return organic.substrate_count * organic.residue_fraction_count;
    if (std.mem.eql(u8, name, "heterotroph_population_fraction") or std.mem.eql(u8, name, "autotroph_population_fraction")) return organic.microbial_population_count;
    if (std.mem.eql(u8, name, "microbial_nitrogen_to_carbon") or std.mem.eql(u8, name, "microbial_phosphorus_to_carbon")) return organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    if (std.mem.eql(u8, name, "residue_structural_fraction")) return 3 * organic.structural_fraction_count;
    if (std.mem.eql(u8, name, "particulate_structural_fraction")) return organic.structural_fraction_count;
    if (std.mem.eql(u8, name, "surface_woody_structural_fraction")) return organic.structural_fraction_count;
    if (std.mem.eql(u8, name, "surface_plant_structural_fraction")) return 12 * organic.structural_fraction_count;
    if (std.mem.eql(u8, name, "surface_manure_structural_fraction")) return 2 * organic.structural_fraction_count;
    if (std.mem.eql(u8, name, "surface_residue_nitrogen_weight") or std.mem.eql(u8, name, "surface_residue_phosphorus_weight")) return 3 * organic.structural_fraction_count;
    return organic.substrate_count;
}

fn freeAllocated(parameters: *OwnedParameters, count: usize) void {
    var visited: usize = 0;
    inline for (@typeInfo(OwnedParameters).@"struct".fields) |field| if (field.type == []f64) {
        if (visited < count) parameters.allocator.free(@field(parameters, field.name));
        visited += 1;
    };
}

fn appendRecord(source: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8, count: usize, value: f64, delimiter: []const u8) !void {
    try source.appendSlice(allocator, label);
    for (0..count) |_| {
        try source.appendSlice(allocator, delimiter);
        const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
        defer allocator.free(text);
        try source.appendSlice(allocator, text);
    }
    try source.append(allocator, '\n');
}

test "organic parameters accept mixed delimiters and casing without external files" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "INITIALIZATION_SCALARS,0.25,25000,0.2,5,10,0.25,5000,0.5,1.82e-6,8e-6\n");
    try appendRecord(&source, allocator, "Microbial_Kinetic_Fraction", 15, 0.01, "|");
    try appendRecord(&source, allocator, "microbial_residue_fraction", 10, 0.01, "\t");
    try appendRecord(&source, allocator, "microbial_carbon_budget_fraction", 5, 0.01, " ");
    try appendRecord(&source, allocator, "residue_carbon_budget_fraction", 5, 0.25, ",");
    try appendRecord(&source, allocator, "dissolved_carbon_fraction", 5, 0.005, "|");
    try appendRecord(&source, allocator, "adsorbed_carbon_fraction", 5, 0.05, "\t");
    try appendRecord(&source, allocator, "heterotroph_population_fraction", 7, 0.1, " ");
    try appendRecord(&source, allocator, "autotroph_population_fraction", 7, 0.01, ",");
    try appendRecord(&source, allocator, "microbial_nitrogen_to_carbon", 126, 0.1, "|");
    try appendRecord(&source, allocator, "microbial_phosphorus_to_carbon", 126, 0.01, "\t");
    try appendRecord(&source, allocator, "substrate_nitrogen_to_carbon", 5, 0.1, " ");
    try appendRecord(&source, allocator, "substrate_phosphorus_to_carbon", 5, 0.01, ",");
    try appendRecord(&source, allocator, "residue_structural_fraction", 15, 0.2, "|");
    try source.appendSlice(allocator, "particulate_structural_fraction\t1\t0\t0\t0\t0\n");
    try source.appendSlice(allocator, "surface_woody_structural_fraction,0,0.045,0.660,0.295,0\n");
    try appendRecord(&source, allocator, "surface_plant_structural_fraction", 60, 0.2, "|");
    try appendRecord(&source, allocator, "surface_manure_structural_fraction", 10, 0.2, "\t");
    try appendRecord(&source, allocator, "surface_residue_nitrogen_weight", 15, 0.02, " ");
    try appendRecord(&source, allocator, "surface_residue_phosphorus_weight", 15, 0.002, ",");
    try source.appendSlice(allocator, "soil_organic_sorption|0.1|1.0\n");
    try source.appendSlice(allocator, "soil_organic_decomposition 7.5 7.5 1.5 0.5 0.0015 7.5 7.5 1.5 0.5 0.0015 7.5 7.5 1.5 0.5 0.0015 0.125 0 0 0 0.0015 0.0375 0.0075 0 0 0.0015 7.5 1.5 0.25 0.25 10 10 50 50 1200\n");
    try source.appendSlice(allocator, "soil_organic_priming,0.01,0.001\n");
    var parameters = try parse(allocator, source.items);
    defer parameters.deinit();
    try std.testing.expectEqual(@as(usize, 126), parameters.microbial_nitrogen_to_carbon.len);
    try std.testing.expectEqual(@as(usize, 105), parameters.surfaceMicrobialNitrogenToCarbon().len);
    try std.testing.expectApproxEqAbs(@as(f64, 25_000), parameters.humus_microbial_half_saturation_g_c_per_megagram, 1.0e-12);
    const depth = [_]f64{ 1, 0.5 };
    const wetland = [_]bool{ false, false };
    const mapped_parameters = parameters.mapped(&depth, &wetland);
    try std.testing.expectEqual(@as(usize, 2), mapped_parameters.depth_partition_factor_by_layer.len);
}

test "source organic parameters reproduce STARTS and NITRO data constants" {
    var parameters = try sourceParameters(std.testing.allocator);
    defer parameters.deinit();
    try std.testing.expectEqual(@as(f64, 0.25), parameters.residue_microbial_fraction);
    try std.testing.expectEqual(@as(f64, 0.010), parameters.microbial_kinetic_fraction[0]);
    try std.testing.expectEqual(@as(f64, 0.005), parameters.microbial_kinetic_fraction[2]);
    try std.testing.expectEqual(@as(f64, 0.30), parameters.heterotroph_population_fraction[2]);
    const fungal_index = (0 * organic.microbial_population_count + 2) * organic.kinetic_fraction_count;
    try std.testing.expectEqual(@as(f64, 0.111), parameters.microbial_nitrogen_to_carbon[fungal_index]);
    try std.testing.expectEqual(@as(f64, 7.5), parameters.soil_organic_decomposition.structural_rate_g_c_per_g_activity_h[0][0]);
    try std.testing.expectEqual(@as(f64, 0.1), parameters.soil_organic_sorption_rate_per_h);
    try std.testing.expectEqual(@as(f64, 0.01), parameters.soil_dissolved_priming_rate_per_h);
}

test "STARTS restricts the fungal N:C exception to heterotrophic substrates" {
    // `starts.f:234--247` gates the fungal ratios on `K.LE.4.AND.N.EQ.3`, so the
    // autotrophic substrate class K=5 takes the ordinary 0.167/0.125 ratios even
    // at the fungal population index. Production expresses this as
    // `substrate <= 4 and population == 2` (`parameters.zig:270`). Dropping the
    // substrate half of that predicate would silently give the autotrophs
    // fungal stoichiometry, which changes their N and P demand and therefore
    // the competition for mineral N.
    var parameters = try sourceParameters(std.testing.allocator);
    defer parameters.deinit();
    const fungal_population = 2;
    const heterotrophic = (4 * organic.microbial_population_count + fungal_population) * organic.kinetic_fraction_count;
    const autotrophic = (5 * organic.microbial_population_count + fungal_population) * organic.kinetic_fraction_count;
    // K=4 (humus) is the last heterotrophic class and still fungal.
    try std.testing.expectEqual(@as(f64, 0.111), parameters.microbial_nitrogen_to_carbon[heterotrophic]);
    try std.testing.expectEqual(@as(f64, 0.083), parameters.microbial_nitrogen_to_carbon[heterotrophic + 1]);
    // K=5 (autotrophic) is not, despite sharing the population index.
    try std.testing.expectEqual(@as(f64, 0.167), parameters.microbial_nitrogen_to_carbon[autotrophic]);
    try std.testing.expectEqual(@as(f64, 0.125), parameters.microbial_nitrogen_to_carbon[autotrophic + 1]);
    try std.testing.expectEqual(@as(f64, 0.0167), parameters.microbial_phosphorus_to_carbon[autotrophic]);
    // A non-fungal population inside a heterotrophic class is also unaffected,
    // so the guard cannot pass merely because the exception never fires.
    const heterotrophic_bacteria = (4 * organic.microbial_population_count + 0) * organic.kinetic_fraction_count;
    try std.testing.expectEqual(@as(f64, 0.167), parameters.microbial_nitrogen_to_carbon[heterotrophic_bacteria]);
}

test "STARTS mixes microbial ratios with the 0.55/0.45 kinetic split" {
    // `starts.f:248--249`: `CNOMC(3,N,K)=FL(1)*CNOMC(1,..)+FL(2)*CNOMC(2,..)`
    // with `FL(1)=0.55`, `FL(2)=0.45` (`starts.f:219--220`). The third slot is a
    // weighted mixture, not a mean, so a 0.5/0.5 substitution would survive any
    // test that only checked the labile and recalcitrant entries.
    var parameters = try sourceParameters(std.testing.allocator);
    defer parameters.deinit();
    const fungal = (0 * organic.microbial_population_count + 2) * organic.kinetic_fraction_count;
    const other = (0 * organic.microbial_population_count + 0) * organic.kinetic_fraction_count;
    try std.testing.expectApproxEqRel(@as(f64, 0.55 * 0.111 + 0.45 * 0.083), parameters.microbial_nitrogen_to_carbon[fungal + 2], 1e-15);
    try std.testing.expectApproxEqRel(@as(f64, 0.55 * 0.0111 + 0.45 * 0.0083), parameters.microbial_phosphorus_to_carbon[fungal + 2], 1e-15);
    try std.testing.expectApproxEqRel(@as(f64, 0.55 * 0.167 + 0.45 * 0.125), parameters.microbial_nitrogen_to_carbon[other + 2], 1e-15);
    // The weights are asymmetric, so the mixture must not equal the midpoint.
    try std.testing.expect(@abs(parameters.microbial_nitrogen_to_carbon[fungal + 2] - 0.5 * (0.111 + 0.083)) > 1e-6);
}

test "organic parameter records reject empty explicit delimiter fields" {
    inline for (.{
        "initialization_scalars,0.25,,25000,0.2,5,10,0.25,5000,0.5,1.82e-6,8e-6\n",
        "initialization_scalars|0.25| |25000|0.2|5|10|0.25|5000|0.5|1.82e-6|8e-6\n",
        "initialization_scalars\t0.25\t\t25000\t0.2\t5\t10\t0.25\t5000\t0.5\t1.82e-6\t8e-6\n",
        "initialization_scalars,0.25,25000,0.2,5,10,0.25,5000,0.5,1.82e-6, # missing final value\n",
    }) |source| try std.testing.expectError(
        error.EmptyOrganicParameterValue,
        parse(std.testing.allocator, source),
    );
}

test "organic empty-field check preserves spaces and comments" {
    try std.testing.expect(!hasEmptyExplicitField(
        "soil_organic_priming  0.01  0.001 # valid spaces",
    ));
    try std.testing.expect(!hasEmptyExplicitField(
        "soil_organic_priming, 0.01 | 0.001 # mixed delimiters",
    ));
    try std.testing.expect(!hasEmptyExplicitField("# comment only"));
}
