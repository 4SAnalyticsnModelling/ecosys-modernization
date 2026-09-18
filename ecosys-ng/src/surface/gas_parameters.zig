const std = @import("std");
const delimited_input = @import("../io/input/delimited_input.zig");
const gas = @import("../soil/gas/transport.zig");
const surface_precipitation = @import("precipitation.zig");
const litter_geometry = @import("litter_geometry.zig");
const microbial_respiration = @import("microbial_respiration_step.zig");
const respiration_activity = @import("../soil/microbial/respiration_activity.zig");
const litter_water_environment = @import("litter_water_environment.zig");
const denitrification = @import("../soil/microbial/denitrification.zig");
const surface_denitrification = @import("denitrification_step.zig");
const mineral_exchange = @import("microbial_mineral_exchange_step.zig");
const microbial_turnover = @import("microbial_turnover_step.zig");
const organic_decomposition = @import("organic_decomposition_step.zig");
const organic_sorption = @import("organic_sorption_step.zig");
const litter_colonization = @import("litter_colonization_step.zig");

pub const Parameters = struct {
    atmospheric_concentration_g_per_m3: [gas.species_count]f64,
    solubility: gas.SurfaceSolubilityParameters,
    precipitation_activity_log: [gas.species_count]f64,
    exchange: surface_precipitation.GasExchangeParameters,
    oxygen_half_saturation_g_o_per_m3: f64,
    reference_aqueous_oxygen_diffusivity_m2_per_h: f64,
    microbial_radius_m: f64,
    microbial_count_per_g_c: f64,
    minimum_allocation_fraction: f64,
    negligible_oxygen_demand_g_o: f64,
    maximum_aqueous_oxygen_concentration_g_o_per_m3: f64,
    initial_litter_water_m3_per_g_c: f64,
    litter_geometry: litter_geometry.Parameters,
    litter_water_environment: litter_water_environment.Parameters,
    microbial_respiration: microbial_respiration.Parameters,
    denitrification: denitrification.Parameters,
    chemodenitrification: surface_denitrification.ChemodenitrificationParameters,
    mineral_exchange: mineral_exchange.Parameters,
    microbial_turnover: microbial_turnover.Parameters,
    organic_decomposition: organic_decomposition.Parameters,
    organic_sorption: organic_sorption.Parameters,
    litter_colonization: litter_colonization.Parameters,
};

/// Runtime surface-gas parameter file. Records and enum-like names are ASCII
/// case-insensitive; commas, tabs, spaces, pipes, and any file extension are
/// accepted by the shared input layer.
pub noinline fn parse(source: []const u8) !Parameters {
    try validateRecordArities(source);
    var tokens = delimited_input.tokens(source);
    try expectRecord(&tokens, "atmospheric_concentration_g_per_m3");
    var result: Parameters = undefined;
    // NOTE: this record is a placeholder. `ecosys_ng.zig` unconditionally
    // overwrites `atmospheric_concentration_g_per_m3` with
    // `atmosphericConcentrationsFromUmolPerMol` applied to the site file's
    // umol/mol mixing ratios, because atmospheric composition is site state
    // rather than a process coefficient. Do not read these parsed values as the
    // concentrations the model runs with, and do not "fix" the shipped row to
    // look physical: the O2 and N2 entries are deliberately unused.
    try fill(&tokens, &result.atmospheric_concentration_g_per_m3);
    try expectRecord(&tokens, "solubility_reference_water_to_air");
    try fill(&tokens, &result.solubility.reference_water_to_air);
    try expectRecord(&tokens, "solubility_log_intercept");
    try fill(&tokens, &result.solubility.log_intercept);
    try expectRecord(&tokens, "solubility_temperature_coefficient_per_c");
    try fill(&tokens, &result.solubility.temperature_coefficient_per_c);
    try expectRecord(&tokens, "precipitation_gas_activity_log");
    try fill(&tokens, &result.precipitation_activity_log);
    try expectRecord(&tokens, "air_water_exchange");
    result.exchange = .{ .reference_time_h = try nextFloat(&tokens), .wet_exponent = try nextFloat(&tokens), .dry_exponent = try nextFloat(&tokens), .transition_water_fraction = try nextFloat(&tokens), .iteration_fraction = try nextFloat(&tokens), .aqueous_tortuosity_coefficient = try nextFloat(&tokens) };
    try expectRecord(&tokens, "microbial_oxygen");
    result.oxygen_half_saturation_g_o_per_m3 = try nextFloat(&tokens);
    result.reference_aqueous_oxygen_diffusivity_m2_per_h = try nextFloat(&tokens);
    result.microbial_radius_m = try nextFloat(&tokens);
    result.microbial_count_per_g_c = try nextFloat(&tokens);
    result.minimum_allocation_fraction = try nextFloat(&tokens);
    result.negligible_oxygen_demand_g_o = try nextFloat(&tokens);
    result.maximum_aqueous_oxygen_concentration_g_o_per_m3 = try nextFloat(&tokens);
    try expectRecord(&tokens, "litter_water_retention_m3_per_g_c");
    try fillFive(&tokens, &result.litter_geometry.water_retention_m3_per_g_c);
    try expectRecord(&tokens, "litter_dry_bulk_density_megagrams_per_m3");
    try fillFive(&tokens, &result.litter_geometry.dry_bulk_density_megagrams_per_m3);
    try expectRecord(&tokens, "litter_geometry");
    result.litter_geometry.dry_mass_megagrams_per_g_c = try nextFloat(&tokens);
    result.litter_geometry.particle_density_megagrams_per_m3 = try nextFloat(&tokens);
    result.litter_geometry.field_capacity_fraction_of_porosity = try nextFloat(&tokens);
    result.litter_geometry.wilting_point_fraction_of_porosity = try nextFloat(&tokens);
    result.initial_litter_water_m3_per_g_c = try nextFloat(&tokens);
    try expectRecord(&tokens, "litter_water_potential_mpa");
    result.litter_water_environment = .{
        .saturation_water_potential_megapascal = try nextFloat(&tokens),
        .minimum_water_potential_megapascal = try nextFloat(&tokens),
        .hygroscopic_water_potential_megapascal = try nextFloat(&tokens),
        .saturation_to_field_shape = try nextFloat(&tokens),
        .below_wilting_shape = try nextFloat(&tokens),
    };
    try expectRecord(&tokens, "surface_population_metabolism");
    for (&result.microbial_respiration.populations) |*population| population.metabolism = try nextMetabolism(&tokens);
    try expectRecord(&tokens, "surface_specific_respiration_per_h");
    for (&result.microbial_respiration.populations) |*population| population.substrate_unlimited_respiration_per_h = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_target_nitrogen_per_carbon_g_n_per_g_c");
    for (&result.microbial_respiration.target_nitrogen_per_carbon_g_n_per_g_c) |*value| value.* = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_target_phosphorus_per_carbon_g_p_per_g_c");
    for (&result.microbial_respiration.target_phosphorus_per_carbon_g_p_per_g_c) |*value| value.* = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_doc_respiration_requirement_g_c_per_g_c");
    for (&result.microbial_respiration.doc_respiration_requirement_g_c_per_g_c) |*value| value.* = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_acetate_respiration_requirement_g_c_per_g_c");
    for (&result.microbial_respiration.acetate_respiration_requirement_g_c_per_g_c) |*value| value.* = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_respiration_constants");
    result.microbial_respiration.labile_biomass_fraction = try nextFloat(&tokens);
    result.microbial_respiration.doc_half_saturation_g_c_per_m3 = try nextFloat(&tokens);
    result.microbial_respiration.acetate_half_saturation_g_c_per_m3 = try nextFloat(&tokens);
    result.microbial_respiration.minimum_competition_fraction = try nextFloat(&tokens);
    result.microbial_respiration.specific_maintenance_respiration_g_c_per_g_n_per_h = try nextFloat(&tokens);
    result.microbial_respiration.decomposition_density_half_saturation_g_c_per_g_c = try nextFloat(&tokens);
    result.microbial_respiration.maintenance_density_half_saturation_g_c_per_g_c = try nextFloat(&tokens);
    result.microbial_respiration.acidity_half_response_mol_per_m3 = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_nitrogen_fixation_yield_g_n_per_g_c");
    for (&result.microbial_respiration.nitrogen_fixation_yield_g_n_per_g_c) |*value| value.* = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_nitrogen_fixation_constants");
    result.microbial_respiration.dinitrogen_half_saturation_g_n_per_m3 = try nextFloat(&tokens);
    result.microbial_respiration.nonstructural_to_structural_rate_per_h = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_denitrification_growth_respiration_requirement_g_c_per_g_c");
    result.microbial_respiration.denitrification_growth_respiration_requirement_g_c_per_g_c = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_denitrification_constants");
    result.denitrification = .{
        .minimum_competition_fraction = try nextFloat(&tokens),
        .nitrate_half_saturation_g_n_per_m3 = try nextFloat(&tokens),
        .nitrite_half_saturation_g_n_per_m3 = try nextFloat(&tokens),
        .nitrous_oxide_half_saturation_g_n_per_m3 = try nextFloat(&tokens),
        .product_inhibition_rate_g_n_per_m3_step = try nextFloat(&tokens),
        .carbon_per_nitrate_n_g_c_per_g_n = try nextFloat(&tokens),
        .carbon_per_nitrite_n_g_c_per_g_n = try nextFloat(&tokens),
        .carbon_per_nitrous_oxide_n_g_c_per_g_n = try nextFloat(&tokens),
        .nitrate_n_per_unmet_oxygen_g_n_per_g_o = try nextFloat(&tokens),
    };
    try expectRecord(&tokens, "surface_chemodenitrification");
    inline for (@typeInfo(surface_denitrification.ChemodenitrificationParameters).@"struct".fields) |field| @field(result.chemodenitrification, field.name) = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_mineral_nutrient_exchange");
    inline for (@typeInfo(mineral_exchange.Parameters).@"struct".fields) |field| @field(result.mineral_exchange, field.name) = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_microbial_turnover");
    for (&result.microbial_turnover.basal_decomposition_rate_per_h) |*value| value.* = try nextFloat(&tokens);
    result.microbial_turnover.minimum_carbon_recycling_fraction = try nextFloat(&tokens);
    result.microbial_turnover.carbon_recycling_range_fraction = try nextFloat(&tokens);
    result.microbial_turnover.maximum_nitrogen_recycling_fraction = try nextFloat(&tokens);
    result.microbial_turnover.maximum_phosphorus_recycling_fraction = try nextFloat(&tokens);
    result.microbial_turnover.dissolved_priming_rate_per_h = try nextFloat(&tokens);
    result.microbial_turnover.microbial_priming_rate_per_h = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_organic_decomposition");
    for (&result.organic_decomposition.structural_rate_g_c_per_g_activity_h) |*complex| {
        for (complex) |*value| value.* = try nextFloat(&tokens);
    }
    for (&result.organic_decomposition.microbial_residue_rate_g_c_per_g_activity_h) |*value| value.* = try nextFloat(&tokens);
    result.organic_decomposition.sorbed_organic_rate_g_c_per_g_activity_h = try nextFloat(&tokens);
    result.organic_decomposition.sorbed_acetate_rate_g_c_per_g_activity_h = try nextFloat(&tokens);
    inline for (@typeInfo(@TypeOf(result.organic_decomposition.environment)).@"struct".fields) |field| @field(result.organic_decomposition.environment, field.name) = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_organic_sorption");
    inline for (@typeInfo(organic_sorption.Parameters).@"struct".fields) |field| @field(result.organic_sorption, field.name) = try nextFloat(&tokens);
    try expectRecord(&tokens, "surface_litter_colonization");
    for (&result.litter_colonization.colonization_per_g_activity) |*value| value.* = try nextFloat(&tokens);
    if (tokens.next() != null) return error.UnexpectedSurfaceGasParameter;
    try validate(result);
    return result;
}

fn validateRecordArities(source: []const u8) !void {
    var records = delimited_input.records(source);
    while (records.next()) |record| {
        if (hasEmptyExplicitField(record))
            return error.EmptySurfaceGasParameterRecordValue;
        var tokens = delimited_input.recordTokens(record);
        const label = tokens.next() orelse continue;
        if (label[0] == '#') continue;
        const expected_count = expectedRecordValueCount(label) orelse
            return error.UnexpectedSurfaceGasParameterRecord;
        var actual_count: usize = 0;
        while (tokens.next() != null) actual_count += 1;
        if (actual_count != expected_count)
            return error.InvalidSurfaceGasParameterRecordArity;
    }
}

fn expectedRecordValueCount(label: []const u8) ?usize {
    const Entry = struct {
        name: []const u8,
        count: usize,
    };
    const entries = [_]Entry{
        .{ .name = "atmospheric_concentration_g_per_m3", .count = gas.species_count },
        .{ .name = "solubility_reference_water_to_air", .count = gas.species_count },
        .{ .name = "solubility_log_intercept", .count = gas.species_count },
        .{ .name = "solubility_temperature_coefficient_per_c", .count = gas.species_count },
        .{ .name = "precipitation_gas_activity_log", .count = gas.species_count },
        .{ .name = "air_water_exchange", .count = scalarCount(surface_precipitation.GasExchangeParameters) },
        .{ .name = "microbial_oxygen", .count = 7 },
        .{ .name = "litter_water_retention_m3_per_g_c", .count = litter_geometry.source_pool_count },
        .{ .name = "litter_dry_bulk_density_megagrams_per_m3", .count = litter_geometry.source_pool_count },
        .{ .name = "litter_geometry", .count = 5 },
        .{ .name = "litter_water_potential_mpa", .count = scalarCount(litter_water_environment.Parameters) },
        .{ .name = "surface_population_metabolism", .count = microbial_respiration.source_population_count },
        .{ .name = "surface_specific_respiration_per_h", .count = microbial_respiration.source_population_count },
        .{ .name = "surface_target_nitrogen_per_carbon_g_n_per_g_c", .count = microbial_respiration.unit_count_per_cell },
        .{ .name = "surface_target_phosphorus_per_carbon_g_p_per_g_c", .count = microbial_respiration.unit_count_per_cell },
        .{ .name = "surface_doc_respiration_requirement_g_c_per_g_c", .count = microbial_respiration.source_population_count },
        .{ .name = "surface_acetate_respiration_requirement_g_c_per_g_c", .count = microbial_respiration.source_population_count },
        .{ .name = "surface_respiration_constants", .count = 8 },
        .{ .name = "surface_nitrogen_fixation_yield_g_n_per_g_c", .count = microbial_respiration.source_population_count },
        .{ .name = "surface_nitrogen_fixation_constants", .count = 2 },
        .{ .name = "surface_denitrification_growth_respiration_requirement_g_c_per_g_c", .count = 1 },
        .{ .name = "surface_denitrification_constants", .count = scalarCount(denitrification.Parameters) },
        .{ .name = "surface_chemodenitrification", .count = scalarCount(surface_denitrification.ChemodenitrificationParameters) },
        .{ .name = "surface_mineral_nutrient_exchange", .count = scalarCount(mineral_exchange.Parameters) },
        .{ .name = "surface_microbial_turnover", .count = scalarCount(microbial_turnover.Parameters) },
        .{ .name = "surface_organic_decomposition", .count = scalarCount(organic_decomposition.Parameters) },
        .{ .name = "surface_organic_sorption", .count = scalarCount(organic_sorption.Parameters) },
        .{ .name = "surface_litter_colonization", .count = scalarCount(litter_colonization.Parameters) },
    };
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(label, entry.name)) return entry.count;
    }
    return null;
}

fn scalarCount(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .float, .int, .@"enum" => 1,
        .array => |array| array.len * scalarCount(array.child),
        .@"struct" => |structure| count: {
            var count: usize = 0;
            inline for (structure.fields) |field|
                count += scalarCount(field.type);
            break :count count;
        },
        else => @compileError("unsupported surface-gas parameter field"),
    };
}

fn validate(parameters: Parameters) !void {
    inline for (parameters.atmospheric_concentration_g_per_m3 ++ parameters.solubility.reference_water_to_air ++ parameters.solubility.log_intercept ++ parameters.solubility.temperature_coefficient_per_c ++ parameters.precipitation_activity_log) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceGasParameter;
    for (parameters.atmospheric_concentration_g_per_m3) |value| if (value < 0) return error.InvalidSurfaceGasParameter;
    for (parameters.solubility.reference_water_to_air) |value| if (value < 0) return error.InvalidSurfaceGasParameter;
    inline for (.{ parameters.exchange.reference_time_h, parameters.exchange.wet_exponent, parameters.exchange.dry_exponent, parameters.exchange.transition_water_fraction, parameters.exchange.iteration_fraction, parameters.exchange.aqueous_tortuosity_coefficient, parameters.oxygen_half_saturation_g_o_per_m3, parameters.reference_aqueous_oxygen_diffusivity_m2_per_h, parameters.microbial_radius_m, parameters.microbial_count_per_g_c, parameters.minimum_allocation_fraction, parameters.negligible_oxygen_demand_g_o, parameters.maximum_aqueous_oxygen_concentration_g_o_per_m3, parameters.initial_litter_water_m3_per_g_c }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceGasParameter;
    if (parameters.exchange.reference_time_h <= 0 or parameters.exchange.transition_water_fraction < 0 or parameters.exchange.transition_water_fraction > 1 or parameters.exchange.iteration_fraction < 0 or parameters.exchange.iteration_fraction > 1 or parameters.exchange.aqueous_tortuosity_coefficient < 0 or parameters.oxygen_half_saturation_g_o_per_m3 <= 0 or parameters.reference_aqueous_oxygen_diffusivity_m2_per_h < 0 or parameters.microbial_radius_m <= 0 or parameters.microbial_count_per_g_c < 0 or parameters.minimum_allocation_fraction < 0 or parameters.negligible_oxygen_demand_g_o < 0 or parameters.maximum_aqueous_oxygen_concentration_g_o_per_m3 <= 0 or parameters.initial_litter_water_m3_per_g_c < 0) return error.InvalidSurfaceGasParameter;
    // The deck's fifth `air_water_exchange` field is the legacy `XNPG = 1/NPG`
    // gas sub-step fraction. ecosys-ng takes exactly one time step per hour, so
    // every production caller overrides this to 1
    // (`soil/gas/transport_step.zig:179` and `:258`,
    // `surface/litter_gas_transport_step.zig:113`,
    // `surface/microbial_oxygen_driver.zig:91`). Parsing a field that can never
    // take effect is a trap: an operator who sets 0.25 to "restore the legacy
    // four gas cycles" gets a silently unchanged run, and the audit in
    // `docs/traceability/substep_residue_audit_part1.md` (1c/1e) flagged exactly
    // this shape. Reject it at the edge instead. All 27 shipped decks already
    // carry 1, so this rejects only decks that were being silently ignored.
    if (parameters.exchange.iteration_fraction != 1) return error.SurfaceGasIterationFractionMustBeWholeHour;
    _ = try litter_geometry.calculate(.{ .carbon_by_pool_g_c = .{ 0, 0, 0, 0, 0 }, .signed_charcoal_change_g_c = 0, .water_m3 = 0, .ice_m3 = 0 }, parameters.litter_geometry);
    const water_environment = parameters.litter_water_environment;
    inline for (@typeInfo(litter_water_environment.Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(water_environment, field.name))) return error.NonFiniteSurfaceGasParameter;
    if (water_environment.saturation_water_potential_megapascal >= 0 or water_environment.minimum_water_potential_megapascal >= water_environment.saturation_water_potential_megapascal or water_environment.hygroscopic_water_potential_megapascal >= 0 or water_environment.saturation_to_field_shape <= 0 or water_environment.below_wilting_shape <= 0) return error.InvalidSurfaceGasParameter;
    inline for (parameters.microbial_respiration.target_nitrogen_per_carbon_g_n_per_g_c ++ parameters.microbial_respiration.target_phosphorus_per_carbon_g_p_per_g_c ++ parameters.microbial_respiration.doc_respiration_requirement_g_c_per_g_c ++ parameters.microbial_respiration.acetate_respiration_requirement_g_c_per_g_c) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceGasParameter;
    for (parameters.microbial_respiration.target_nitrogen_per_carbon_g_n_per_g_c ++ parameters.microbial_respiration.target_phosphorus_per_carbon_g_p_per_g_c) |value| if (value <= 0) return error.InvalidSurfaceGasParameter;
    for (parameters.microbial_respiration.populations) |population| if (!std.math.isFinite(population.substrate_unlimited_respiration_per_h) or population.substrate_unlimited_respiration_per_h < 0) return error.InvalidSurfaceGasParameter;
    for (parameters.microbial_respiration.populations, 0..) |population, index| switch (population.metabolism) {
        .aerobic_heterotroph => if (parameters.microbial_respiration.doc_respiration_requirement_g_c_per_g_c[index] <= 0 or parameters.microbial_respiration.acetate_respiration_requirement_g_c_per_g_c[index] <= 0) return error.InvalidSurfaceGasParameter,
        .fermenting_heterotroph => if (parameters.microbial_respiration.doc_respiration_requirement_g_c_per_g_c[index] <= 0) return error.InvalidSurfaceGasParameter,
        .acetotrophic_methanogen => if (parameters.microbial_respiration.acetate_respiration_requirement_g_c_per_g_c[index] <= 0) return error.InvalidSurfaceGasParameter,
    };
    for (parameters.microbial_respiration.nitrogen_fixation_yield_g_n_per_g_c) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceGasParameter;
    inline for (.{ parameters.microbial_respiration.labile_biomass_fraction, parameters.microbial_respiration.doc_half_saturation_g_c_per_m3, parameters.microbial_respiration.acetate_half_saturation_g_c_per_m3, parameters.microbial_respiration.minimum_competition_fraction, parameters.microbial_respiration.specific_maintenance_respiration_g_c_per_g_n_per_h, parameters.microbial_respiration.decomposition_density_half_saturation_g_c_per_g_c, parameters.microbial_respiration.maintenance_density_half_saturation_g_c_per_g_c, parameters.microbial_respiration.acidity_half_response_mol_per_m3 }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSurfaceGasParameter;
    if (parameters.microbial_respiration.labile_biomass_fraction > 1) return error.InvalidSurfaceGasParameter;
    if (!std.math.isFinite(parameters.microbial_respiration.dinitrogen_half_saturation_g_n_per_m3) or parameters.microbial_respiration.dinitrogen_half_saturation_g_n_per_m3 <= 0 or !std.math.isFinite(parameters.microbial_respiration.nonstructural_to_structural_rate_per_h) or parameters.microbial_respiration.nonstructural_to_structural_rate_per_h <= 0 or !std.math.isFinite(parameters.microbial_respiration.denitrification_growth_respiration_requirement_g_c_per_g_c) or parameters.microbial_respiration.denitrification_growth_respiration_requirement_g_c_per_g_c <= 0) return error.InvalidSurfaceGasParameter;
    parameters.denitrification.validate() catch return error.InvalidSurfaceGasParameter;
    inline for (@typeInfo(surface_denitrification.ChemodenitrificationParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters.chemodenitrification, field.name)) or @field(parameters.chemodenitrification, field.name) < 0) return error.InvalidSurfaceGasParameter;
    if (parameters.chemodenitrification.nitrous_acid_dissociation_mol_per_m3 <= 0 or @abs(parameters.chemodenitrification.nitrous_oxide_yield_g_n_per_g_n + parameters.chemodenitrification.dissolved_organic_nitrogen_yield_g_n_per_g_n - 1) > 1e-12) return error.InvalidSurfaceGasParameter;
    inline for (@typeInfo(mineral_exchange.Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters.mineral_exchange, field.name)) or @field(parameters.mineral_exchange, field.name) <= 0) return error.InvalidSurfaceGasParameter;
    for (parameters.microbial_turnover.basal_decomposition_rate_per_h) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceGasParameter;
    inline for (.{ parameters.microbial_turnover.minimum_carbon_recycling_fraction, parameters.microbial_turnover.carbon_recycling_range_fraction, parameters.microbial_turnover.maximum_nitrogen_recycling_fraction, parameters.microbial_turnover.maximum_phosphorus_recycling_fraction }) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSurfaceGasParameter;
    inline for (.{ parameters.microbial_turnover.dissolved_priming_rate_per_h, parameters.microbial_turnover.microbial_priming_rate_per_h }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceGasParameter;
    if (parameters.microbial_turnover.minimum_carbon_recycling_fraction + parameters.microbial_turnover.carbon_recycling_range_fraction > 1) return error.InvalidSurfaceGasParameter;
    for (parameters.organic_decomposition.structural_rate_g_c_per_g_activity_h) |complex| {
        for (complex) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceGasParameter;
    }
    for (parameters.organic_decomposition.microbial_residue_rate_g_c_per_g_activity_h) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceGasParameter;
    inline for (.{ parameters.organic_decomposition.sorbed_organic_rate_g_c_per_g_activity_h, parameters.organic_decomposition.sorbed_acetate_rate_g_c_per_g_activity_h }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceGasParameter;
    inline for (@typeInfo(@TypeOf(parameters.organic_decomposition.environment)).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters.organic_decomposition.environment, field.name)) or @field(parameters.organic_decomposition.environment, field.name) <= 0) return error.InvalidSurfaceGasParameter;
    inline for (@typeInfo(organic_sorption.Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters.organic_sorption, field.name)) or @field(parameters.organic_sorption, field.name) <= 0) return error.InvalidSurfaceGasParameter;
    for (parameters.litter_colonization.colonization_per_g_activity) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceGasParameter;
}

fn hasEmptyExplicitField(line: []const u8) bool {
    const content = if (std.mem.indexOfScalar(u8, line, '#')) |comment| line[0..comment] else line;
    const trimmed = std.mem.trim(u8, content, " \r");
    if (trimmed.len == 0) return false;
    var field_start: usize = 0;
    var saw_explicit_delimiter = false;
    for (trimmed, 0..) |byte, index| {
        if (byte != ',' and byte != '|' and byte != '\t') continue;
        const field = std.mem.trim(u8, trimmed[field_start..index], " \r");
        if (field.len == 0) return true;
        field_start = index + 1;
        saw_explicit_delimiter = true;
    }
    return saw_explicit_delimiter and std.mem.trim(u8, trimmed[field_start..], " \r").len == 0;
}

fn expectRecord(tokens: anytype, expected: []const u8) !void {
    const actual = tokens.next() orelse return error.MissingSurfaceGasParameterRecord;
    if (!std.ascii.eqlIgnoreCase(actual, expected)) return error.UnexpectedSurfaceGasParameterRecord;
}

fn nextFloat(tokens: anytype) !f64 {
    const text = tokens.next() orelse return error.MissingSurfaceGasParameter;
    const value = std.fmt.parseFloat(f64, text) catch return error.InvalidSurfaceGasParameter;
    if (!std.math.isFinite(value)) return error.NonFiniteSurfaceGasParameter;
    return value;
}

fn nextMetabolism(tokens: anytype) !respiration_activity.Metabolism {
    const text = tokens.next() orelse return error.MissingSurfaceGasParameter;
    if (std.ascii.eqlIgnoreCase(text, "aerobic_heterotroph")) return .aerobic_heterotroph;
    if (std.ascii.eqlIgnoreCase(text, "fermenting_heterotroph")) return .fermenting_heterotroph;
    if (std.ascii.eqlIgnoreCase(text, "acetotrophic_methanogen")) return .acetotrophic_methanogen;
    return error.InvalidSurfaceMicrobialMetabolism;
}

fn fill(tokens: anytype, values: *[gas.species_count]f64) !void {
    for (values) |*value| value.* = try nextFloat(tokens);
}

fn fillFive(tokens: anytype, values: *[litter_geometry.source_pool_count]f64) !void {
    for (values) |*value| value.* = try nextFloat(tokens);
}

const source_parameter_text =
    "ATMOSPHERIC_CONCENTRATION_G_PER_M3,0.2,0.001,0.3,0.8,0.0001,0.00001,0.000001\n" ++
    "Solubility_Reference_Water_To_Air|0.7391|0.03156|0.02925|0.01510|0.5241|285.2|0.03156\n" ++
    "solubility_log_intercept 0.843 0.597 0.516 0.456 0.897 0.513 0.597\n" ++
    "solubility_temperature_coefficient_per_c\t0.0281\t0.0199\t0.0172\t0.0152\t0.0299\t0.0171\t0.0199\n" ++
    "precipitation_gas_activity_log 0 0 0 0 0 0 0\n" ++
    "air_water_exchange,0.5,12,12,0.5,1,0.7\n" ++
    "microbial_oxygen|0.064|8.57e-6|1e-6|2.387e11|0.001|1e-12|1.0\n" ++
    "litter_water_retention_m3_per_g_c,2e-6,5e-6,5e-6,5e-6,5e-6\n" ++
    "litter_dry_bulk_density_megagrams_per_m3|0.1|0.0125|0.025|0.025|0.025\n" ++
    "litter_geometry 1.82e-6 1.30 0.5 0.25 8e-6\n" ++
    "litter_water_potential_mpa -0.0005 -1.5e12 -1.5e4 0.5 0.5\n" ++
    "surface_population_metabolism AEROBIC_HETEROTROPH aerobic_heterotroph Aerobic_Heterotroph FERMENTING_HETEROTROPH acetotrophic_methanogen aerobic_heterotroph fermenting_heterotroph\n" ++
    "surface_specific_respiration_per_h 0.125 0.125 0.125 0.125 0.125 0.125 0.125\n" ++
    "surface_target_nitrogen_per_carbon_g_n_per_g_c 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1\n" ++
    "surface_target_phosphorus_per_carbon_g_p_per_g_c 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01\n" ++
    "surface_doc_respiration_requirement_g_c_per_g_c 0.4 0.5 0.6 0.4 0 0.4 0.4\n" ++
    "surface_acetate_respiration_requirement_g_c_per_g_c 0.3 0.3 0.3 0 0.3 0.3 0\n" ++
    "surface_respiration_constants 0.55 12 12 0.001 0.010 0.010 0.000001 1.0\n" ++
    "surface_nitrogen_fixation_yield_g_n_per_g_c 0 0 0 0 0 0.25 0.02\n" ++
    "surface_nitrogen_fixation_constants 0.14 0.25\n" ++
    "surface_denitrification_growth_respiration_requirement_g_c_per_g_c 0.7142857142857143\n" ++
    "surface_denitrification_constants 0.001 1.4 1.4 0.014 1.0 0.429 0.429 0.214 0.875\n" ++
    "surface_chemodenitrification 0.0005 0.45 0.5 0.5\n" ++
    "surface_mineral_nutrient_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 0.003 0.009 0.18 31\n" ++
    "surface_microbial_turnover 0.01 0.001 0.167 0.333 0.333 0.333 0.01 0.001\n" ++
    "surface_organic_decomposition 7.5 7.5 1.5 0.5 0.0015 7.5 7.5 1.5 0.5 0.0015 7.5 7.5 1.5 0.5 0.0015 7.5 1.5 0.25 0.25 10 10 50 50 1200\n" ++
    "surface_organic_sorption 0.1 1.0 500\n" ++
    "surface_litter_colonization 0.25 2.0 5.0";

/// Source HOUR1/NITRO surface atmosphere and litter-process coefficients,
/// materialized as runtime state and replaceable by a user parameter file.
pub fn sourceParameters() !Parameters {
    return parse(source_parameter_text);
}

/// Converts READI atmospheric mixing ratios to the tracked gas masses used by
/// TRNSFR/HOUR1 via the ideal-gas molar density `12190 / T` mol m-3.
pub fn atmosphericConcentrationsFromUmolPerMol(mixing_ratio_umol_per_mol: [gas.species_count]f64, temperature_k: f64) ![gas.species_count]f64 {
    if (!std.math.isFinite(temperature_k) or temperature_k <= 0) return error.InvalidAtmosphericGasTemperature;
    var result: [gas.species_count]f64 = undefined;
    const molar_density_mol_per_m3 = 12_190 / temperature_k;
    for (&result, mixing_ratio_umol_per_mol, gas.g_per_mol_tracked) |*concentration, mixing_ratio, molar_mass| {
        if (!std.math.isFinite(mixing_ratio) or mixing_ratio < 0) return error.InvalidAtmosphericGasMixingRatio;
        concentration.* = mixing_ratio * 1e-6 * molar_density_mol_per_m3 * molar_mass;
        if (!std.math.isFinite(concentration.*)) return error.NonFiniteAtmosphericGasConcentration;
    }
    return result;
}

/// Publishes one cell into a cell-major atmospheric carrier. Keeping this
/// indexing beside the READI conversion prevents heterogeneous site records
/// from being collapsed into a single compatibility parameter array.
pub fn writeAtmosphericConcentrationsForCell(
    destination_g_per_m3: []f64,
    cell: usize,
    mixing_ratio_umol_per_mol: [gas.species_count]f64,
    temperature_k: f64,
) !void {
    if (destination_g_per_m3.len % gas.species_count != 0 or
        cell >= destination_g_per_m3.len / gas.species_count)
        return error.AtmosphericGasCarrierDimensionMismatch;
    const concentrations = try atmosphericConcentrationsFromUmolPerMol(
        mixing_ratio_umol_per_mol,
        temperature_k,
    );
    const first = cell * gas.species_count;
    @memcpy(destination_g_per_m3[first..][0..gas.species_count], &concentrations);
}

/// Reads one species from a cell-major live atmospheric carrier.
pub fn atmosphericConcentrationForCell(
    concentrations_g_per_m3: []const f64,
    cell_count: usize,
    cell: usize,
    species: gas.Species,
) !f64 {
    if (cell_count == 0 or cell >= cell_count or
        concentrations_g_per_m3.len != cell_count * gas.species_count)
        return error.AtmosphericGasCarrierDimensionMismatch;
    return concentrations_g_per_m3[
        cell * gas.species_count + @intFromEnum(species)
    ];
}

test "surface gas runtime parameters accept flexible delimiters and casing" {
    const source = source_parameter_text;
    const parameters = try parse(source);
    try std.testing.expectEqual(@as(f64, 0.064), parameters.oxygen_half_saturation_g_o_per_m3);
    try std.testing.expectEqual(@as(f64, 285.2), parameters.solubility.reference_water_to_air[@intFromEnum(gas.Species.ammonia)]);
}

test "surface gas records accept comments with exact runtime array counts" {
    const parameters = try parse(
        "# Surface gas parameters are one strict labeled record per line.\n" ++
            source_parameter_text ++
            "\n# End of surface gas parameters.\n",
    );
    try std.testing.expectEqual(
        @as(f64, 0.064),
        parameters.oxygen_half_saturation_g_o_per_m3,
    );
}

test "surface gas preflight rejects short and long physical records" {
    try std.testing.expectError(
        error.InvalidSurfaceGasParameterRecordArity,
        parse(
            "atmospheric_concentration_g_per_m3 0.2 # six gases are missing\n",
        ),
    );
    try std.testing.expectError(
        error.InvalidSurfaceGasParameterRecordArity,
        parse(source_parameter_text ++ " 99 # extra colonization value\n"),
    );
}

test "surface gas records reject explicit empty values" {
    try std.testing.expectError(
        error.EmptySurfaceGasParameterRecordValue,
        parse("atmospheric_concentration_g_per_m3 0.2,,0.001 0.3 0.8 0.0001 0.00001 0.000001\n"),
    );
}

test "surface gas parameters reject a sub-hourly gas iteration fraction" {
    // The shipped decks all carry 1, so the source text must parse. If this
    // stops holding, the guard is wrong, not the deck.
    const whole_hour = try parse(source_parameter_text);
    try std.testing.expectEqual(@as(f64, 1), whole_hour.exchange.iteration_fraction);

    // 0.25 is the value an operator would reach for to "restore" the legacy
    // four gas cycles per hour. Production overrides it to 1 unconditionally, so
    // accepting it would mean silently ignoring an explicit request. It must be
    // a hard rejection at the deck edge, not a no-op.
    const sub_hourly = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        source_parameter_text,
        "air_water_exchange,0.5,12,12,0.5,1,0.7",
        "air_water_exchange,0.5,12,12,0.5,0.25,0.7",
    );
    defer std.testing.allocator.free(sub_hourly);
    try std.testing.expectError(
        error.SurfaceGasIterationFractionMustBeWholeHour,
        parse(sub_hourly),
    );

    // Zero is the other reachable mistake: it would mean "no gas exchange at
    // all" rather than "one whole hour", and the pre-existing range check
    // (`>= 0`) accepted it.
    const zero = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        source_parameter_text,
        "air_water_exchange,0.5,12,12,0.5,1,0.7",
        "air_water_exchange,0.5,12,12,0.5,0,0.7",
    );
    defer std.testing.allocator.free(zero);
    try std.testing.expectError(
        error.SurfaceGasIterationFractionMustBeWholeHour,
        parse(zero),
    );
}

test "READI atmospheric mixing ratios convert to tracked gas mass units" {
    const result = try atmosphericConcentrationsFromUmolPerMol(.{ 420, 1.9, 210_000, 780_000, 0.33, 0.01, 0 }, 298.15);
    try std.testing.expectApproxEqRel(@as(f64, 274.7), result[@intFromEnum(gas.Species.oxygen)], 2e-3);
    try std.testing.expect(result[@intFromEnum(gas.Species.carbon_dioxide)] > 0);
}

test "two-cell site atmosphere remains distinct through initialization and runtime lookup" {
    var carrier = [_]f64{0} ** (2 * gas.species_count);
    try writeAtmosphericConcentrationsForCell(
        &carrier,
        0,
        .{ 390, 1.7, 180_000, 780_000, 0.30, 0.01, 0.001 },
        275.15,
    );
    try writeAtmosphericConcentrationsForCell(
        &carrier,
        1,
        .{ 510, 2.4, 230_000, 760_000, 0.42, 0.08, 0.004 },
        305.15,
    );
    const oxygen_0 = try atmosphericConcentrationForCell(&carrier, 2, 0, .oxygen);
    const oxygen_1 = try atmosphericConcentrationForCell(&carrier, 2, 1, .oxygen);
    const ammonia_0 = try atmosphericConcentrationForCell(&carrier, 2, 0, .ammonia);
    const ammonia_1 = try atmosphericConcentrationForCell(&carrier, 2, 1, .ammonia);
    try std.testing.expect(oxygen_0 != oxygen_1);
    try std.testing.expect(ammonia_0 != ammonia_1);
    try std.testing.expectApproxEqRel(
        @as(f64, 0.08 / 0.01 * 275.15 / 305.15),
        ammonia_1 / ammonia_0,
        1e-12,
    );
}
