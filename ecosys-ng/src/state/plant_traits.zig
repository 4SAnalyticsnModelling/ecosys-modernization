const std = @import("std");
const delimited_input = @import("../io/input/delimited_input.zig");

pub const FunctionalType = struct {
    photosynthesis_pathway: u8,
    root_profile_type: u8,
    growth_habit: u8,
    determinacy_type: u8,
    nitrogen_fixation_type: u8,
    leaf_phenology_type: u8,
    photoperiod_type: u8,
    aboveground_turnover_type: u8,
    storage_organ_location: u8,
    mycorrhizal_type: u8,
    thermal_adaptation_zone: f64,
};

pub const Photosynthesis = struct {
    rubisco_carboxylase_umol_c_per_g_enzyme_s: f64,
    rubisco_oxygenase_umol_o_per_g_enzyme_s: f64,
    pep_carboxylase_umol_per_g_enzyme_s: f64,
    co2_half_saturation_umol_per_l: f64,
    oxygen_half_saturation_umol_per_l: f64,
    pep_co2_half_saturation_umol_per_l: f64,
    rubisco_leaf_protein_fraction: f64,
    pep_carboxylase_leaf_protein_fraction: f64,
    chlorophyll_electron_activity_umol_per_g_enzyme_s: f64,
    mesophyll_chlorophyll_leaf_protein_fraction: f64,
    c4_mesophyll_chlorophyll_leaf_protein_fraction: f64,
    intercellular_to_atmospheric_co2_ratio: f64,
};

pub const Optics = struct {
    shortwave_albedo: f64,
    par_albedo: f64,
    shortwave_transmission: f64,
    par_transmission: f64,
    shortwave_absorptivity: f64,
    par_absorptivity: f64,
};

pub const Phenology = struct {
    node_initiation_per_h: f64,
    leaf_appearance_per_h: f64,
    chilling_temperature_c: f64,
    spring_leafout_requirement_h: f64,
    autumn_leafoff_requirement_h: f64,
    leaf_length_to_width_ratio: f64,
    branching_nonstructural_carbon_fraction: f64,
    floral_initiation_node_count: f64,
    seed_initial_node_count: f64,
    critical_photoperiod_h: f64,
    floral_induction_photoperiod_difference_h: f64,
};

pub const Morphology = struct {
    specific_leaf_area_m2_per_g_c: f64,
    specific_petiole_length_m_per_g_c: f64,
    specific_internode_length_m_per_g_c: f64,
    leaf_inclination_fraction_0_to_22_5_deg: f64,
    leaf_inclination_fraction_22_5_to_45_deg: f64,
    leaf_inclination_fraction_45_to_67_5_deg: f64,
    leaf_inclination_fraction_67_5_to_90_deg: f64,
    initial_clumping_factor: f64,
    stem_angle_degrees: f64,
    petiole_angle_degrees: f64,
    maximum_seed_sites: f64,
    maximum_seeds_per_site: f64,
    maximum_seed_mass_g: f64,
    seed_mass_at_planting_g: f64,
    grain_filling_g_per_seed_h: f64,
    standing_dead_carbon_g_per_m2: f64,
};

pub const RootTraits = struct {
    primary_root_radius_m: f64,
    secondary_root_radius_m: f64,
    root_porosity_fraction: f64,
    branching_nonstructural_carbon_fraction: f64,
    radial_resistivity_mpa_h_per_m3: f64,
    axial_resistivity_mpa_h_per_m2: f64,
    shoot_root_carbon_equilibration_fraction_per_h: f64,
    secondary_root_branching_per_m: f64,
};

pub const NutrientUptake = struct {
    maximum_rate_g_per_m2_h: f64,
    half_saturation_umol_per_l: f64,
    minimum_concentration_umol_per_l: f64,
};

pub const WaterRelations = struct {
    osmotic_potential_megapascal: f64,
    stomatal_turgor_shape: f64,
    cuticular_resistance_s_per_m: f64,
};

pub const OrganValues = struct {
    leaf: f64,
    petiole: f64,
    stalk: f64,
    stalk_reserve: f64,
    husk: f64,
    ear: f64,
    grain: f64,
    root: f64,
    symbiont: f64,
};

pub const PlantTraits = struct {
    functional_type: FunctionalType,
    photosynthesis: Photosynthesis,
    optics: Optics,
    phenology: Phenology,
    morphology: Morphology,
    roots: RootTraits,
    ammonium_uptake: NutrientUptake,
    nitrate_uptake: NutrientUptake,
    phosphate_uptake: NutrientUptake,
    water_relations: WaterRelations,
    organ_growth_yield_g_c_per_g_c: OrganValues,
    organ_nitrogen_to_carbon_ratio: OrganValues,
    organ_phosphorus_to_carbon_ratio: OrganValues,
};

pub fn parse(source: []const u8) !PlantTraits {
    var records = std.mem.splitScalar(u8, source, '\n');
    var functional = delimited_input.recordTokens(try nextRecord(&records));
    var photosynthesis = delimited_input.recordTokens(try nextRecord(&records));
    var optics = delimited_input.recordTokens(try nextRecord(&records));
    var result = PlantTraits{
        .functional_type = .{
            .photosynthesis_pathway = try integer(u8, &functional),
            .root_profile_type = try integer(u8, &functional),
            .growth_habit = try integer(u8, &functional),
            .determinacy_type = try integer(u8, &functional),
            .nitrogen_fixation_type = try integer(u8, &functional),
            .leaf_phenology_type = try integer(u8, &functional),
            .photoperiod_type = try integer(u8, &functional),
            .aboveground_turnover_type = try integer(u8, &functional),
            .storage_organ_location = try integer(u8, &functional),
            .mycorrhizal_type = try integer(u8, &functional),
            .thermal_adaptation_zone = try real(&functional),
        },
        .photosynthesis = .{
            .rubisco_carboxylase_umol_c_per_g_enzyme_s = try real(&photosynthesis),
            .rubisco_oxygenase_umol_o_per_g_enzyme_s = try real(&photosynthesis),
            .pep_carboxylase_umol_per_g_enzyme_s = try real(&photosynthesis),
            .co2_half_saturation_umol_per_l = try real(&photosynthesis),
            .oxygen_half_saturation_umol_per_l = try real(&photosynthesis),
            .pep_co2_half_saturation_umol_per_l = try real(&photosynthesis),
            .rubisco_leaf_protein_fraction = try real(&photosynthesis),
            .pep_carboxylase_leaf_protein_fraction = try real(&photosynthesis),
            .chlorophyll_electron_activity_umol_per_g_enzyme_s = try real(&photosynthesis),
            .mesophyll_chlorophyll_leaf_protein_fraction = try real(&photosynthesis),
            .c4_mesophyll_chlorophyll_leaf_protein_fraction = try real(&photosynthesis),
            .intercellular_to_atmospheric_co2_ratio = try real(&photosynthesis),
        },
        .optics = undefined,
        .phenology = undefined,
        .morphology = undefined,
        .roots = undefined,
        .ammonium_uptake = undefined,
        .nitrate_uptake = undefined,
        .phosphate_uptake = undefined,
        .water_relations = undefined,
        .organ_growth_yield_g_c_per_g_c = undefined,
        .organ_nitrogen_to_carbon_ratio = undefined,
        .organ_phosphorus_to_carbon_ratio = undefined,
    };
    const shortwave_albedo = try real(&optics);
    const par_albedo = try real(&optics);
    const shortwave_transmission = try real(&optics);
    const par_transmission = try real(&optics);
    const shortwave_absorptivity = 1.0 - shortwave_albedo - shortwave_transmission;
    const par_absorptivity = 1.0 - par_albedo - par_transmission;
    result.optics = .{
        .shortwave_albedo = shortwave_albedo,
        .par_albedo = par_albedo,
        .shortwave_transmission = shortwave_transmission,
        .par_transmission = par_transmission,
        .shortwave_absorptivity = shortwave_absorptivity,
        .par_absorptivity = par_absorptivity,
    };
    if (functional.next() != null or photosynthesis.next() != null or optics.next() != null) return error.TrailingPlantTraitRecordData;
    if (result.functional_type.photosynthesis_pathway != 3 and result.functional_type.photosynthesis_pathway != 4) return error.InvalidPhotosynthesisPathway;
    if (result.functional_type.mycorrhizal_type < 1 or result.functional_type.mycorrhizal_type > 2)
        return error.InvalidMycorrhizalType;
    if (shortwave_absorptivity <= 0.0 or par_absorptivity <= 0.0) return error.InvalidLeafOptics;

    var phenology1 = delimited_input.recordTokens(try nextRecord(&records));
    var phenology2 = delimited_input.recordTokens(try nextRecord(&records));
    result.phenology = .{
        .node_initiation_per_h = try real(&phenology1),
        .leaf_appearance_per_h = try real(&phenology1),
        .chilling_temperature_c = try real(&phenology1),
        .spring_leafout_requirement_h = try real(&phenology1),
        .autumn_leafoff_requirement_h = try real(&phenology1),
        .leaf_length_to_width_ratio = try real(&phenology1),
        .branching_nonstructural_carbon_fraction = try real(&phenology1),
        .floral_initiation_node_count = try real(&phenology2),
        .seed_initial_node_count = try real(&phenology2),
        .critical_photoperiod_h = try real(&phenology2),
        .floral_induction_photoperiod_difference_h = try real(&phenology2),
    };
    try requireEnd(&phenology1);
    try requireEnd(&phenology2);

    var morphology1 = delimited_input.recordTokens(try nextRecord(&records));
    var morphology2 = delimited_input.recordTokens(try nextRecord(&records));
    var morphology3 = delimited_input.recordTokens(try nextRecord(&records));
    result.morphology = .{
        .specific_leaf_area_m2_per_g_c = try real(&morphology1),
        .specific_petiole_length_m_per_g_c = try real(&morphology1),
        .specific_internode_length_m_per_g_c = try real(&morphology1),
        .leaf_inclination_fraction_0_to_22_5_deg = try real(&morphology2),
        .leaf_inclination_fraction_22_5_to_45_deg = try real(&morphology2),
        .leaf_inclination_fraction_45_to_67_5_deg = try real(&morphology2),
        .leaf_inclination_fraction_67_5_to_90_deg = try real(&morphology2),
        .initial_clumping_factor = try real(&morphology2),
        .stem_angle_degrees = try real(&morphology2),
        .petiole_angle_degrees = try real(&morphology2),
        .maximum_seed_sites = try real(&morphology3),
        .maximum_seeds_per_site = try real(&morphology3),
        .maximum_seed_mass_g = try real(&morphology3),
        .seed_mass_at_planting_g = try real(&morphology3),
        .grain_filling_g_per_seed_h = try real(&morphology3),
        .standing_dead_carbon_g_per_m2 = try real(&morphology3),
    };
    try requireEnd(&morphology1);
    try requireEnd(&morphology2);
    try requireEnd(&morphology3);

    var roots = delimited_input.recordTokens(try nextRecord(&records));
    result.roots = .{
        .primary_root_radius_m = try real(&roots),
        .secondary_root_radius_m = try real(&roots),
        .root_porosity_fraction = try real(&roots),
        .branching_nonstructural_carbon_fraction = try real(&roots),
        .radial_resistivity_mpa_h_per_m3 = try real(&roots),
        .axial_resistivity_mpa_h_per_m2 = try real(&roots),
        .shoot_root_carbon_equilibration_fraction_per_h = try real(&roots),
        .secondary_root_branching_per_m = try real(&roots),
    };
    try discardFiniteExtras(&roots);
    result.ammonium_uptake = try parseUptake(&records);
    result.nitrate_uptake = try parseUptake(&records);
    result.phosphate_uptake = try parseUptake(&records);
    var water = delimited_input.recordTokens(try nextRecord(&records));
    result.water_relations = .{
        .osmotic_potential_megapascal = try real(&water),
        .stomatal_turgor_shape = try real(&water),
        .cuticular_resistance_s_per_m = try real(&water),
    };
    try requireEnd(&water);
    result.organ_growth_yield_g_c_per_g_c = try parseOrganValues(&records);
    result.organ_nitrogen_to_carbon_ratio = try parseOrganValues(&records);
    result.organ_phosphorus_to_carbon_ratio = try parseOrganValues(&records);
    if (try nextRecordOrNull(&records) != null) return error.TrailingPlantTraitRecords;
    return result;
}

fn parseUptake(records: anytype) !NutrientUptake {
    var values = delimited_input.recordTokens(try nextRecord(records));
    const result = NutrientUptake{
        .maximum_rate_g_per_m2_h = try real(&values),
        .half_saturation_umol_per_l = try real(&values),
        .minimum_concentration_umol_per_l = try real(&values),
    };
    try requireEnd(&values);
    return result;
}

fn parseOrganValues(records: anytype) !OrganValues {
    var values = delimited_input.recordTokens(try nextRecord(records));
    const result = OrganValues{
        .leaf = try real(&values),
        .petiole = try real(&values),
        .stalk = try real(&values),
        .stalk_reserve = try real(&values),
        .husk = try real(&values),
        .ear = try real(&values),
        .grain = try real(&values),
        .root = try real(&values),
        .symbiont = try real(&values),
    };
    try requireEnd(&values);
    return result;
}

fn requireEnd(tokens: anytype) !void {
    if (tokens.next() != null) return error.TrailingPlantTraitRecordData;
}

fn discardFiniteExtras(tokens: anytype) !void {
    while (tokens.next()) |text| {
        const value = std.fmt.parseFloat(f64, text) catch return error.InvalidPlantTraitValue;
        if (!std.math.isFinite(value)) return error.NonFinitePlantTraitValue;
    }
}

fn nextRecord(records: anytype) ![]const u8 {
    return try nextRecordOrNull(records) orelse error.UnexpectedEndOfPlantTraits;
}

fn nextRecordOrNull(records: anytype) !?[]const u8 {
    while (records.next()) |record| {
        if (hasEmptyExplicitField(record)) return error.EmptyPlantTraitRecordValue;
        var tokens = delimited_input.recordTokens(record);
        if (tokens.next() != null) return record;
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

fn integer(comptime T: type, tokens: anytype) !T {
    return std.fmt.parseUnsigned(T, tokens.next() orelse return error.IncompletePlantTraitRecord, 10);
}

fn real(tokens: anytype) !f64 {
    const result = try std.fmt.parseFloat(f64, tokens.next() orelse return error.IncompletePlantTraitRecord);
    if (!std.math.isFinite(result)) return error.NonFinitePlantTraitValue;
    return result;
}

test "parse self-contained functional and photosynthetic traits" {
    const source = @import("../core/test_fixtures.zig").plant_traits_source;
    const traits = try parse(source);
    try std.testing.expectEqual(@as(u8, 4), traits.functional_type.photosynthesis_pathway);
    try std.testing.expectApproxEqAbs(@as(f64, 75.0), traits.photosynthesis.rubisco_carboxylase_umol_c_per_g_enzyme_s, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.60), traits.optics.shortwave_absorptivity, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), traits.optics.par_absorptivity, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.020), traits.morphology.specific_leaf_area_m2_per_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.75e-4), traits.roots.primary_root_radius_m, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.014), traits.ammonium_uptake.maximum_rate_g_per_m2_h, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.72), traits.organ_growth_yield_g_c_per_g_c.leaf, 1.0e-12);
}

test "plant trait comments do not displace compulsory scientific records" {
    const source =
        "# Functional type record follows.\n" ++
        @import("../core/test_fixtures.zig").plant_traits_source ++
        "# End of trait file.\n";
    const traits = try parse(source);
    try std.testing.expectEqual(
        @as(u8, 4),
        traits.functional_type.photosynthesis_pathway,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 3.75e-4),
        traits.roots.primary_root_radius_m,
        1.0e-12,
    );
}

test "plant trait comments cannot satisfy a missing compulsory record" {
    try std.testing.expectError(
        error.UnexpectedEndOfPlantTraits,
        parse(
            \\4 2 0 0 0 0 2 0 0 2 2.0
            \\# Photosynthesis is compulsory and cannot be replaced by this.
        ),
    );
}

test "plant trait records reject explicit empty values" {
    try std.testing.expectError(
        error.EmptyPlantTraitRecordValue,
        parse(
            \\4 2 0 0 0 0 2 0 0,,0 2 2.0
        ),
    );
}
