const std = @import("std");
const delimited_input = @import("../../io/input/delimited_input.zig");
const chemistry = @import("../solute/chemistry_state.zig");
const aqueous_rates = @import("../solute/aqueous_reaction_rates.zig");
const phosphate_rates = @import("../solute/phosphate_reaction_rates.zig");
const phosphate_exchange = @import("../solute/phosphate_exchange.zig");
const cation_exchange = @import("../solute/cation_exchange.zig");
const carboxyl_exchange = @import("../solute/carboxyl_exchange.zig");
const geochemistry_rates = @import("../solute/geochemistry_reaction_rates.zig");
const activity_coefficients = @import("../solute/activity_coefficients.zig");
const surface_litter_rates = @import("../../surface/litter_reaction_rates.zig");
const surface_fertilizer = @import("../../surface/litter_fertilizer.zig");

pub const SurfaceLitterParameters = struct {
    carboxyl_dissociation_constant: f64,
    carboxyl_sites_mol_per_megagram_c: f64,
};

pub const SurfaceFertilizerParameters = struct {
    ammonium_dissolution_fraction_per_h: f64,
    ammonia_dissolution_fraction_per_h: f64,
    nitrate_dissolution_fraction_per_h: f64,
    minimum_urea_half_saturation_mol_n_per_megagram: f64,
    microbial_activity_inhibition_g_c_per_m3_per_h: f64,
    specific_urea_hydrolysis_mol_n_per_g_c_per_h: f64,
    fast_release_inhibition_decline_fraction_per_h: f64,
    normal_release_inhibition_decline_fraction_per_h: f64,
    slow_release_inhibition_decline_fraction_per_h: f64,

    pub fn forFormulation(self: SurfaceFertilizerParameters, formulation: u8, timestep_h: f64) !surface_fertilizer.Parameters {
        if (!std.math.isFinite(timestep_h) or timestep_h <= 0) return error.InvalidSurfaceFertilizerTimestep;
        // HOUR1 maps fertilizer codes 1 and 3 to the normal-release urea
        // formulation, and codes 2 and 4 to slow release. Codes 3 and 4 also
        // select nitrification inhibitors in the nitrogen transformation
        // kernel; they must not be rejected here.
        const decline = switch (formulation) {
            0 => self.fast_release_inhibition_decline_fraction_per_h,
            1, 3 => self.normal_release_inhibition_decline_fraction_per_h,
            2, 4 => self.slow_release_inhibition_decline_fraction_per_h,
            else => return error.InvalidSurfaceUreaFormulation,
        };
        return .{
            .ammonium_dissolution_fraction_per_step = @min(1, self.ammonium_dissolution_fraction_per_h * timestep_h),
            .ammonia_dissolution_fraction_per_step = @min(1, self.ammonia_dissolution_fraction_per_h * timestep_h),
            .nitrate_dissolution_fraction_per_step = @min(1, self.nitrate_dissolution_fraction_per_h * timestep_h),
            .minimum_urea_half_saturation_mol_n_per_megagram = self.minimum_urea_half_saturation_mol_n_per_megagram,
            .microbial_activity_inhibition_g_c_per_m3_per_h = self.microbial_activity_inhibition_g_c_per_m3_per_h,
            .specific_urea_hydrolysis_mol_n_per_g_c = self.specific_urea_hydrolysis_mol_n_per_g_c_per_h * timestep_h,
            .urease_inhibition_decline_fraction_per_step = @min(1, decline * timestep_h),
        };
    }
};

/// Coefficients shared by every runtime soil layer. Layer geometry, zone
/// fractions, exchange capacity, and soil/water ratios are supplied separately.
pub const Parameters = struct {
    aqueous_constants: aqueous_rates.EquilibriumConstants,
    aqueous_kinetics: aqueous_rates.Kinetics,
    phosphate_constants: phosphate_rates.EquilibriumConstants,
    phosphate_surface: phosphate_exchange.Parameters,
    phosphate_minerals: phosphate_rates.MineralParameters,
    phosphate_kinetics: phosphate_rates.Kinetics,
    cation_substrate_limit_fraction: f64,
    cation_maximum_adsorption_mol_charge_per_m3_step: f64,
    geochemistry_products: geochemistry_rates.SolubilityProducts,
    geochemistry_kinetics: geochemistry_rates.Kinetics,
    water_activity_product_mol2_per_m6: f64,
    negligible_water_ion_concentration_mol_per_m3: f64,
    water_concentration_mol_per_m3: f64,
    surface_litter: SurfaceLitterParameters,
    surface_fertilizer: SurfaceFertilizerParameters,

    pub fn forLayer(
        self: Parameters,
        fractions: @import("../solute/charge_classification.zig").ZoneFractions,
        non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3: f64,
        band_phosphate_soil_mass_per_water_volume_megagrams_per_m3: f64,
        cation_exchange_capacity_mol_charge_per_megagram: f64,
        total_carboxyl_sites_mol_per_megagram: f64,
        cation_exchange_water_ratios: chemistry.CationExchangeWaterRatios,
        cation_selectivity: cation_exchange.Selectivity,
    ) chemistry.ReactionParameters {
        return .{
            .fractions = fractions,
            .non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
            .band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
            .cation_exchange_capacity_mol_charge_per_megagram = cation_exchange_capacity_mol_charge_per_megagram,
            .cation_exchange_water_ratios = cation_exchange_water_ratios,
            .total_carboxyl_sites_mol_per_megagram = total_carboxyl_sites_mol_per_megagram,
            .carboxyl_exchange_parameters = carboxyl_exchange.Parameters{
                .dissociation_constant_mol_per_m3 = self.surface_litter.carboxyl_dissociation_constant,
                .maximum_exchange_mol_per_m3_per_iteration = self.cation_maximum_adsorption_mol_charge_per_m3_step,
                .substrate_limit_fraction_per_iteration = self.cation_substrate_limit_fraction,
            },
            .aqueous_constants = self.aqueous_constants,
            .aqueous_kinetics = self.aqueous_kinetics,
            .phosphate_constants = self.phosphate_constants,
            .phosphate_surface = self.phosphate_surface,
            .phosphate_minerals = self.phosphate_minerals,
            .phosphate_kinetics = self.phosphate_kinetics,
            .cation_exchange_parameters = .{ .selectivity = cation_selectivity, .substrate_limit_fraction = self.cation_substrate_limit_fraction, .maximum_adsorption_mol_charge_per_m3_step = self.cation_maximum_adsorption_mol_charge_per_m3_step },
            .geochemistry_products = self.geochemistry_products,
            .geochemistry_kinetics = self.geochemistry_kinetics,
            .water_activity_product_mol2_per_m6 = self.water_activity_product_mol2_per_m6,
            .negligible_water_ion_concentration_mol_per_m3 = self.negligible_water_ion_concentration_mol_per_m3,
        };
    }

    /// Constructs the surface-litter subset of SOLUTE.F without duplicating
    /// source constants or silently selecting a soil-layer parameterization.
    pub fn forSurfaceLitter(
        self: Parameters,
        activity: activity_coefficients.Result,
        cation_selectivity: cation_exchange.Selectivity,
        cation_exchange_capacity_mol_charge_per_megagram_litter: f64,
        litter_mass_per_water_volume_megagrams_per_m3: f64,
        dynamic_salts: bool,
    ) surface_litter_rates.Context {
        const phosphate = self.phosphate_constants;
        const minerals = self.phosphate_minerals;
        const geochemistry = self.geochemistry_products;
        return .{
            .litter_mass_per_water_volume_megagrams_per_m3 = litter_mass_per_water_volume_megagrams_per_m3,
            .dynamic_salts = dynamic_salts,
            .parameters = .{
                .activity = activity,
                .dissociation = .{
                    .ammonium = self.aqueous_constants.ammonium,
                    .carbon_dioxide = self.aqueous_constants.carbon_dioxide,
                    .bicarbonate = self.aqueous_constants.bicarbonate,
                    .h2po4 = phosphate.h2po4,
                    .hpo4 = phosphate.hpo4,
                    .carboxyl = self.surface_litter.carboxyl_dissociation_constant,
                },
                .minerals = .{
                    .aluminum_phosphate = minerals.aluminum_phosphate_solubility_product,
                    .iron_phosphate = minerals.iron_phosphate_solubility_product,
                    .dicalcium_phosphate = minerals.dicalcium_phosphate_solubility_product,
                    .hydroxyapatite = minerals.hydroxyapatite_solubility_product,
                    .monocalcium_phosphate = minerals.monocalcium_phosphate_solubility_product,
                    .gibbsite = geochemistry.gibbsite,
                    .iron_hydroxide = geochemistry.iron_hydroxide,
                    .calcite = geochemistry.calcite,
                    .gypsum = geochemistry.gypsum,
                    .fixed_ph_aluminum_h2po4 = minerals.aluminum_phosphate_solubility_product / (phosphate.hpo4 * phosphate.h2po4),
                    .fixed_ph_iron_h2po4 = minerals.iron_phosphate_solubility_product / (phosphate.hpo4 * phosphate.h2po4),
                    .fixed_ph_hydroxyapatite_h2po4 = minerals.hydroxyapatite_solubility_product / (self.water_activity_product_mol2_per_m6 * std.math.pow(f64, phosphate.hpo4, 3) * std.math.pow(f64, phosphate.h2po4, 3)),
                },
                .kinetics = .{
                    .ammonium_substrate_limit_fraction = self.aqueous_kinetics.ammonium_substrate_limit_fraction,
                    .general_substrate_limit_fraction = self.aqueous_kinetics.general_substrate_limit_fraction,
                    .maximum_ammonium_association_mol_per_m3_step = self.aqueous_kinetics.maximum_fast_association_mol_per_m3_step,
                    .maximum_association_mol_per_m3_step = self.aqueous_kinetics.maximum_slow_association_mol_per_m3_step,
                    .maximum_phosphate_precipitation_mol_per_m3_step = minerals.maximum_phosphate_precipitation_mol_per_m3_step,
                    // SOLUTE assigns TPA = TRW for the restricted surface
                    // branch; retain that shared runtime control rather than
                    // the independent full-network apatite ceiling.
                    .maximum_apatite_precipitation_mol_per_m3_step = minerals.maximum_mineral_dissolution_mol_per_m3_step,
                    .maximum_monocalcium_dissolution_mol_per_m3_step = minerals.maximum_mineral_dissolution_mol_per_m3_step,
                    .maximum_cation_adsorption_mol_charge_per_m3_step = self.cation_maximum_adsorption_mol_charge_per_m3_step,
                    .calcite_hydroxide_inhibition_constant_mol_per_m3 = self.geochemistry_kinetics.calcite_hydroxide_inhibition_constant_mol_per_m3,
                },
                .cation_exchange_capacity_mol_charge_per_megagram = cation_exchange_capacity_mol_charge_per_megagram_litter,
                .cation_selectivity = cation_selectivity,
                .water_activity_product_mol2_per_m6 = self.water_activity_product_mol2_per_m6,
                .negligible_water_ion_concentration_mol_per_m3 = self.negligible_water_ion_concentration_mol_per_m3,
                .phosphate_surface = self.phosphate_surface,
            },
        };
    }
};

const Record = enum {
    aqueous_constants,
    aqueous_kinetics,
    phosphate_constants,
    phosphate_surface,
    phosphate_minerals,
    phosphate_kinetics,
    cation_kinetics,
    geochemistry_products,
    geochemistry_kinetics,
    water_equilibrium,
    surface_litter,
    surface_fertilizer,
};

pub noinline fn parse(source: []const u8) !Parameters {
    var result: Parameters = undefined;
    var seen = [_]bool{false} ** @typeInfo(Record).@"enum".fields.len;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (hasEmptyExplicitField(line))
            return error.EmptyChemistryParameterValue;
        var tokens = delimited_input.recordTokens(line);
        const label = tokens.next() orelse continue;
        if (label[0] == '#') continue;
        const record = recordFromLabel(label) orelse return error.UnknownChemistryParameterRecord;
        const index: usize = @intFromEnum(record);
        if (seen[index]) return error.DuplicateChemistryParameterRecord;
        seen[index] = true;
        switch (record) {
            .aqueous_constants => result.aqueous_constants = try parseStruct(aqueous_rates.EquilibriumConstants, &tokens),
            .aqueous_kinetics => result.aqueous_kinetics = try parseStruct(aqueous_rates.Kinetics, &tokens),
            .phosphate_constants => result.phosphate_constants = try parseStruct(phosphate_rates.EquilibriumConstants, &tokens),
            .phosphate_surface => result.phosphate_surface = try parseStruct(phosphate_exchange.Parameters, &tokens),
            .phosphate_minerals => result.phosphate_minerals = try parseStruct(phosphate_rates.MineralParameters, &tokens),
            .phosphate_kinetics => result.phosphate_kinetics = try parseStruct(phosphate_rates.Kinetics, &tokens),
            .cation_kinetics => {
                result.cation_substrate_limit_fraction = try nextFinite(&tokens);
                result.cation_maximum_adsorption_mol_charge_per_m3_step = try nextFinite(&tokens);
                if (tokens.next() != null) return error.TooManyChemistryParameterValues;
            },
            .geochemistry_products => result.geochemistry_products = try parseStruct(geochemistry_rates.SolubilityProducts, &tokens),
            .geochemistry_kinetics => result.geochemistry_kinetics = try parseStruct(geochemistry_rates.Kinetics, &tokens),
            .water_equilibrium => {
                result.water_activity_product_mol2_per_m6 = try nextFinite(&tokens);
                result.negligible_water_ion_concentration_mol_per_m3 = try nextFinite(&tokens);
                result.water_concentration_mol_per_m3 = try nextFinite(&tokens);
                if (tokens.next() != null) return error.TooManyChemistryParameterValues;
            },
            .surface_litter => result.surface_litter = try parseStruct(SurfaceLitterParameters, &tokens),
            .surface_fertilizer => result.surface_fertilizer = try parseStruct(SurfaceFertilizerParameters, &tokens),
        }
    }
    for (seen) |present| if (!present) return error.MissingChemistryParameterRecord;
    try validate(result);
    return result;
}

fn hasEmptyExplicitField(line: []const u8) bool {
    const content = if (std.mem.indexOfScalar(u8, line, '#')) |comment|
        line[0..comment]
    else
        line;
    const trimmed = std.mem.trim(u8, content, " \r");
    if (trimmed.len == 0) return false;
    var previous_explicit_end: usize = 0;
    var saw_explicit = false;
    for (trimmed, 0..) |byte, index| {
        if (byte != ',' and byte != '|' and byte != '\t') continue;
        const field = std.mem.trim(
            u8,
            trimmed[previous_explicit_end..index],
            " \r",
        );
        if (field.len == 0) return true;
        previous_explicit_end = index + 1;
        saw_explicit = true;
    }
    return saw_explicit and
        std.mem.trim(u8, trimmed[previous_explicit_end..], " \r").len == 0;
}

fn parseStruct(comptime T: type, tokens: anytype) !T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| @field(result, field.name) = try nextFinite(tokens);
    if (tokens.next() != null) return error.TooManyChemistryParameterValues;
    return result;
}

fn nextFinite(tokens: anytype) !f64 {
    const token = tokens.next() orelse return error.MissingChemistryParameterValue;
    const value = std.fmt.parseFloat(f64, token) catch return error.InvalidChemistryParameterValue;
    if (!std.math.isFinite(value)) return error.NonFiniteChemistryParameterValue;
    return value;
}

fn recordFromLabel(label: []const u8) ?Record {
    inline for (@typeInfo(Record).@"enum".fields) |field| if (std.ascii.eqlIgnoreCase(label, field.name)) return @enumFromInt(field.value);
    return null;
}

fn validate(parameters: Parameters) !void {
    inline for (@typeInfo(Parameters).@"struct".fields) |field| {
        const value = @field(parameters, field.name);
        switch (@typeInfo(field.type)) {
            .float => if (!std.math.isFinite(value) or value < 0) return error.InvalidChemistryParameter,
            .@"struct" => inline for (@typeInfo(field.type).@"struct".fields) |nested| if (!std.math.isFinite(@field(value, nested.name)) or @field(value, nested.name) < 0) return error.InvalidChemistryParameter,
            else => @compileError("unsupported chemistry parameter field"),
        }
    }
    if (parameters.water_activity_product_mol2_per_m6 <= 0 or parameters.negligible_water_ion_concentration_mol_per_m3 <= 0 or parameters.water_concentration_mol_per_m3 <= 0) return error.InvalidChemistryParameter;
    if (parameters.aqueous_kinetics.ammonium_substrate_limit_fraction > 1 or parameters.aqueous_kinetics.general_substrate_limit_fraction > 1 or parameters.phosphate_kinetics.substrate_limit_fraction > 1 or parameters.phosphate_surface.substrate_limit_fraction > 1 or parameters.cation_substrate_limit_fraction > 1 or parameters.geochemistry_kinetics.general_substrate_limit_fraction > 1 or parameters.geochemistry_kinetics.hydrogen_coupled_substrate_limit_fraction > 1) return error.InvalidChemistryParameter;
    const fertilizer = parameters.surface_fertilizer;
    if (fertilizer.ammonium_dissolution_fraction_per_h > 1 or fertilizer.ammonia_dissolution_fraction_per_h > 1 or fertilizer.nitrate_dissolution_fraction_per_h > 1 or fertilizer.minimum_urea_half_saturation_mol_n_per_megagram <= 0 or fertilizer.microbial_activity_inhibition_g_c_per_m3_per_h <= 0 or fertilizer.fast_release_inhibition_decline_fraction_per_h > 1 or fertilizer.normal_release_inhibition_decline_fraction_per_h > 1 or fertilizer.slow_release_inhibition_decline_fraction_per_h > 1) return error.InvalidChemistryParameter;
}

test "chemistry parameters accept flexible delimiters and case-insensitive labels" {
    const source =
        "AQUEOUS_CONSTANTS 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1\n" ++
        "aqueous_kinetics|0.2|0.2|0.1|0.1\n" ++
        "Phosphate_Constants\t1\t1\t1\t1\t1\t1\t1\t1\n" ++
        "phosphate_surface,1,1,1,1,1e-8,1e-4,0.1,0.2\n" ++
        "phosphate_minerals 1 1 1 1 1 1 1 1 1\n" ++
        "phosphate_kinetics 0.2 0.1\n" ++
        "cation_kinetics 0.2 0.1\n" ++
        "geochemistry_products 1 1 1 1 1 1 1 1 1 1\n" ++
        "geochemistry_kinetics 0.2 0.2 0.1 0.1 1 0.01 0.01\n" ++
        "water_equilibrium 1e-8 1e-20 55555.555555555555\n" ++
        "surface_litter 1e-2 2.5e2\n" ++
        "surface_fertilizer 1 1 1 0.05 50 0.03 0.05 0.01 0.005\n";
    const parameters = try parse(source);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0e-8), parameters.water_activity_product_mol2_per_m6, 1.0e-20);
}

test "surface fertilizer formulation maps inhibitor decline rate by code" {
    const parameters: SurfaceFertilizerParameters = .{
        .ammonium_dissolution_fraction_per_h = 0.1,
        .ammonia_dissolution_fraction_per_h = 0.2,
        .nitrate_dissolution_fraction_per_h = 0.3,
        .minimum_urea_half_saturation_mol_n_per_megagram = 0.05,
        .microbial_activity_inhibition_g_c_per_m3_per_h = 50,
        .specific_urea_hydrolysis_mol_n_per_g_c_per_h = 0.03,
        .fast_release_inhibition_decline_fraction_per_h = 0.05,
        .normal_release_inhibition_decline_fraction_per_h = 0.01,
        .slow_release_inhibition_decline_fraction_per_h = 0.005,
    };
    const timestep_h = 2.0;
    const normal = try parameters.forFormulation(1, timestep_h);
    const fast = try parameters.forFormulation(0, timestep_h);
    const slow = try parameters.forFormulation(2, timestep_h);
    const normal_from_3 = try parameters.forFormulation(3, timestep_h);
    const slow_from_4 = try parameters.forFormulation(4, timestep_h);
    try std.testing.expectApproxEqAbs(0.05 * timestep_h, fast.urease_inhibition_decline_fraction_per_step, 1e-15);
    try std.testing.expectApproxEqAbs(0.01 * timestep_h, normal.urease_inhibition_decline_fraction_per_step, 1e-15);
    try std.testing.expectApproxEqAbs(0.005 * timestep_h, slow.urease_inhibition_decline_fraction_per_step, 1e-15);
    try std.testing.expectApproxEqAbs(normal.urease_inhibition_decline_fraction_per_step, normal_from_3.urease_inhibition_decline_fraction_per_step, 1e-15);
    try std.testing.expectApproxEqAbs(slow.urease_inhibition_decline_fraction_per_step, slow_from_4.urease_inhibition_decline_fraction_per_step, 1e-15);
    try std.testing.expectError(error.InvalidSurfaceUreaFormulation, parameters.forFormulation(7, timestep_h));
}

test "chemistry records reject empty comma pipe and tab fields" {
    inline for (.{
        "aqueous_kinetics,0.2,,0.2,0.1,0.1\n",
        "aqueous_kinetics|0.2| |0.2|0.1|0.1\n",
        "aqueous_kinetics\t0.2\t\t0.2\t0.1\t0.1\n",
        "aqueous_kinetics,0.2,0.2,0.1, # missing final value\n",
    }) |source| try std.testing.expectError(
        error.EmptyChemistryParameterValue,
        parse(source),
    );
}

test "chemistry empty-field check preserves spaces and trailing comments" {
    try std.testing.expect(!hasEmptyExplicitField(
        "aqueous_kinetics  0.2  0.2  0.1  0.1 # valid spaces",
    ));
    try std.testing.expect(!hasEmptyExplicitField(
        "aqueous_kinetics, 0.2 | 0.2\t0.1, 0.1 # mixed delimiters",
    ));
    try std.testing.expect(!hasEmptyExplicitField("   # comment only"));
}

test "surface litter coefficients are derived from runtime SOLUTE parameters" {
    const source =
        "aqueous_constants 5.5e-7 5.6e-8 4.2e-4 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1\n" ++
        "aqueous_kinetics 0.2 0.25 0.1 0.01\n" ++
        "phosphate_constants 4.8e-10 6.2e-5 7.5 1 1 1 1 1\n" ++
        "phosphate_surface 1 1 1 1 1e-8 6.2e-5 0.01 0.2\n" ++
        "phosphate_minerals 9.8e-15 2.5e-19 0.13 4e-31 7e7 1e-8 0.001 0.002 0.003\n" ++
        "phosphate_kinetics 0.2 0.1\n" ++
        "cation_kinetics 0.2 0.01\n" ++
        "geochemistry_products 1.9e-21 6.3e-26 0.0033 14 1 1 1 1 1 1\n" ++
        "geochemistry_kinetics 0.2 0.2 0.001 0.001 1e-5 0 0\n" ++
        "water_equilibrium 1e-8 1e-48 55555.555555555555\n" ++
        "surface_litter 0.01 250\n" ++
        "surface_fertilizer 1 1 1 0.05 50 0.03 0.05 0.01 0.005\n";
    const parameters = try parse(source);
    const activity = try activity_coefficients.calculate(.{ .trivalent_cations_mol = 0, .trivalent_anions_mol = 0, .divalent_cations_mol = 0, .divalent_anions_mol = 0, .monovalent_cations_mol = 0, .monovalent_anions_mol = 0, .neutral_solutes_mol = 0 }, 1);
    const context = parameters.forSurfaceLitter(activity, .{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 }, 3, 2, true);
    try std.testing.expectEqual(@as(f64, 3), context.parameters.cation_exchange_capacity_mol_charge_per_megagram);
    try std.testing.expectEqual(@as(f64, 0.01), context.parameters.dissociation.carboxyl);
    try std.testing.expectEqual(@as(f64, 250), parameters.surface_litter.carboxyl_sites_mol_per_megagram_c);
    try std.testing.expectApproxEqAbs(9.8e-15 / (4.8e-10 * 6.2e-5), context.parameters.minerals.fixed_ph_aluminum_h2po4, 1e-15);
    try std.testing.expectEqual(@as(f64, 2), context.litter_mass_per_water_volume_megagrams_per_m3);
    try std.testing.expect(context.dynamic_salts);
    try std.testing.expectEqual(
        parameters.aqueous_kinetics.maximum_slow_association_mol_per_m3_step,
        context.parameters.kinetics.maximum_association_mol_per_m3_step,
    );
    try std.testing.expectEqual(
        parameters.phosphate_minerals.maximum_mineral_dissolution_mol_per_m3_step,
        context.parameters.kinetics.maximum_apatite_precipitation_mol_per_m3_step,
    );
    const slow = try parameters.surface_fertilizer.forFormulation(2, 1);
    try std.testing.expectEqual(@as(f64, 0.005), slow.urease_inhibition_decline_fraction_per_step);
    const normal_with_nitrification_inhibitor = try parameters.surface_fertilizer.forFormulation(3, 1);
    try std.testing.expectEqual(@as(f64, 0.01), normal_with_nitrification_inhibitor.urease_inhibition_decline_fraction_per_step);
    const slow_with_nitrification_inhibitor = try parameters.surface_fertilizer.forFormulation(4, 1);
    try std.testing.expectEqual(@as(f64, 0.005), slow_with_nitrification_inhibitor.urease_inhibition_decline_fraction_per_step);
}
