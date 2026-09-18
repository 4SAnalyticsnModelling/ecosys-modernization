const std = @import("std");
const delimited_input = @import("../../io/input/delimited_input.zig");
const nitrification = @import("../microbial/nitrification.zig");
const denitrification = @import("../microbial/denitrification.zig");
const chemodenitrification = @import("../microbial/chemodenitrification.zig");

pub const AutotrophicDenitrificationParameters = struct {
    anaerobic_growth_respiration_fraction: f64,
    additional_ammonium_oxidation_per_nitrite_reduction: f64,
};

pub const NitrifierIndices = struct {
    autotrophic_substrate_index: usize,
    ammonia_oxidizer_population_index: usize,
    nitrite_oxidizer_population_index: usize,
    heterotrophic_denitrifier_population_index: usize,
};

pub const NitrifierEnvironmentParameters = struct {
    labile_biomass_fraction: f64,
    ammonia_oxidizer_target_nitrogen_per_carbon_g_n_per_g_c: f64,
    nitrite_oxidizer_target_nitrogen_per_carbon_g_n_per_g_c: f64,
    ammonia_oxidizer_target_phosphorus_per_carbon_g_p_per_g_c: f64,
    nitrite_oxidizer_target_phosphorus_per_carbon_g_p_per_g_c: f64,
    aqueous_co2_half_saturation_g_c_per_m3: f64,
    water_potential_sensitivity_per_megapascal: f64,
};

pub const OxygenUptakeParameters = struct {
    microbial_radius_m: f64,
    microbial_count_per_g_c: f64,
    oxygen_half_saturation_g_o_per_m3: f64,
    hygroscopic_water_potential_megapascal: f64,
    air_water_exchange_reference_time_h: f64,
    wet_exchange_exponent: f64,
    dry_exchange_exponent: f64,
    minimum_transition_water_fraction: f64,
    aqueous_tortuosity_coefficient: f64,
    minimum_allocation_fraction: f64,
    negligible_oxygen_demand_g_o: f64,
};

pub const HeterotrophicRespirationParameters = struct {
    substrate_unlimited_respiration_per_h: f64,
    target_nitrogen_per_carbon_g_n_per_g_c: f64,
    target_phosphorus_per_carbon_g_p_per_g_c: f64,
    doc_half_saturation_g_c_per_m3: f64,
    acetate_half_saturation_g_c_per_m3: f64,
    doc_respiration_requirement_g_c_per_g_c: f64,
    acetate_respiration_requirement_g_c_per_g_c: f64,
    water_potential_sensitivity_per_megapascal: f64,
    oxygen_per_respired_carbon_g_o_per_g_c: f64,
    specific_maintenance_respiration_g_c_per_g_n_per_h: f64,
    decomposition_density_half_saturation_g_c_per_g_c: f64,
    maintenance_density_half_saturation_g_c_per_g_c: f64,
    acidity_half_response_mol_per_m3: f64,
    denitrification_growth_respiration_fraction_g_c_per_g_c: f64,
};

pub const MicrobialMineralExchangeParameters = struct {
    ammonium_maximum_uptake_g_n_per_m2_h: f64,
    ammonium_minimum_concentration_g_n_per_m3: f64,
    ammonium_half_saturation_g_n_per_m3: f64,
    nitrate_maximum_uptake_g_n_per_m2_h: f64,
    nitrate_minimum_concentration_g_n_per_m3: f64,
    nitrate_half_saturation_g_n_per_m3: f64,
    phosphate_maximum_uptake_g_p_per_m2_h: f64,
    phosphate_minimum_concentration_g_p_per_m3: f64,
    phosphate_half_saturation_g_p_per_m3: f64,
    phosphorus_molar_mass_g_per_mol: f64,
};

pub const NonsymbioticNitrogenFixationParameters = struct {
    aerobic_diazotroph_population_index: usize,
    anaerobic_diazotroph_population_index: usize,
    aerobic_yield_g_n_per_g_c: f64,
    anaerobic_yield_g_n_per_g_c: f64,
    dinitrogen_half_saturation_g_n_per_m3: f64,
    nonstructural_to_structural_rate_per_h: f64,
};

pub const FermenterRespirationParameters = struct {
    fermenter_population_index: usize,
    anaerobic_diazotroph_population_index: usize,
    specific_oxidation_rate_g_c_per_g_c_h: f64,
    dissolved_organic_carbon_half_saturation_g_c_per_m3: f64,
    acetate_product_inhibition_g_c_per_m3: f64,
    reference_energy_yield_kj_per_g_c: f64,
    growth_energy_requirement_kj_per_g_c: f64,
    diazotroph_growth_energy_requirement_kj_per_g_c: f64,
    minimum_respiration_requirement_g_c_per_g_c: f64,
    diazotroph_minimum_respiration_requirement_g_c_per_g_c: f64,
    gas_constant_kj_per_mol_k: f64,
    acetate_feedback_stoichiometric_exponent: f64,
    feedback_carbon_conversion_g_c_per_mol: f64,
};

pub const AcetotrophicMethanogenesisParameters = struct {
    population_index: usize,
    acetate_product_inhibition_g_c_per_m3: f64,
    acetate_half_saturation_g_c_per_m3: f64,
    specific_respiration_rate_g_c_per_g_c_h: f64,
    reference_energy_yield_kj_per_g_c: f64,
    growth_energy_requirement_kj_per_g_c: f64,
    minimum_growth_respiration_fraction: f64,
    gas_constant_kj_per_mol_k: f64,
    feedback_carbon_conversion_g_c_per_mol: f64,
    methane_carbon_yield_g_c_per_g_c_oxidized: f64,
};

pub const AnaerobicEnergyParameters = struct {
    fermenter: FermenterRespirationParameters,
    acetotrophic_methanogenesis: AcetotrophicMethanogenesisParameters,
};

/// Source NITRO.F 179--187 anaerobic growth-respiration energetics, as runtime
/// state reachable from the production heterotrophic respiration owner.
///
/// These are the inputs to the source `ECHZ` growth respiration requirement for
/// the three anaerobic populations. `ECHZ` is a *function of product energy
/// feedback* in the source:
///
///   fermenter (N=4)   ECHZ = max(EO2X, min(1, 1/(1 + max(0, GCHX-GHAX)/EOMF)))
///   diazotroph (N=7)  ECHZ = max(ENFY, min(1, 1/(1 + max(0, GCHX-GHAX)/EOMY)))
///   acetotroph (N=5)  ECHZ = max(EO2X, min(1, 1/(1 + max(0, GC4X+GOMM)/EOMH)))
///
/// where `GHAX` combines the aqueous H2 and acetate feedback and `GOMM` is the
/// acetate feedback, both varying hourly with concentration and temperature.
///
/// The production path in `soil_heterotrophic_respiration_step` currently
/// applies fixed constants instead (`0.5` for fermenters,
/// `0.42016806722689076` for acetotrophic methanogens), which loses that
/// thermodynamic feedback. `0.42016806722689076` is in fact exactly source
/// `EO2A = 1/(1+(GO2X-GCHX)/EOMC)`, the *aerobic acetate* requirement, so an
/// aerobic constant is being applied to an anaerobic population. See
/// `docs/traceability/bind_nitro_001_double_mutation_analysis.md`.
///
/// This record exists so the owning NITRO lane can correct that inside the
/// single existing owner. Adding it does NOT introduce a second writer of the
/// anaerobic respiration publish set, and no kernel is bound to it here.
pub const AnaerobicGrowthEnergyParameters = struct {
    /// `GCHX`, energy yield of fermentation (kilojoule per gram carbon).
    fermentation_energy_yield_kilojoule_per_g_c: f64,
    /// `GC4X`, energy yield of acetotrophic methanogenesis.
    acetotrophic_methanogenesis_energy_yield_kilojoule_per_g_c: f64,
    /// `EOMF`, fermenter growth energy requirement.
    fermenter_growth_energy_requirement_kilojoule_per_g_c: f64,
    /// `EOMY`, anaerobic diazotroph growth energy requirement.
    anaerobic_diazotroph_growth_energy_requirement_kilojoule_per_g_c: f64,
    /// `EOMH`, acetotrophic methanogen growth energy requirement.
    acetotrophic_methanogen_growth_energy_requirement_kilojoule_per_g_c: f64,
    /// `EO2X`, minimum growth respiration requirement for the fermenter and
    /// acetotrophic methanogen branches (dimensionless g C per g C).
    minimum_growth_respiration_requirement_g_c_per_g_c: f64,
    /// `ENFY`, minimum growth respiration requirement for the anaerobic
    /// diazotroph branch.
    anaerobic_diazotroph_minimum_growth_respiration_requirement_g_c_per_g_c: f64,

    /// Source `ECHZ` for a fermenter or anaerobic diazotroph, given the
    /// combined H2 and acetate feedback `GHAX` in kilojoule per gram carbon.
    /// Retains source operation order: subtract, floor at zero, divide, add
    /// one, reciprocate, cap at one, then floor at the population minimum.
    pub fn fermenterGrowthRespirationRequirement(
        self: AnaerobicGrowthEnergyParameters,
        combined_product_feedback_kilojoule_per_g_c: f64,
        is_anaerobic_diazotroph: bool,
    ) !f64 {
        const requirement = if (is_anaerobic_diazotroph)
            self.anaerobic_diazotroph_growth_energy_requirement_kilojoule_per_g_c
        else
            self.fermenter_growth_energy_requirement_kilojoule_per_g_c;
        const minimum = if (is_anaerobic_diazotroph)
            self.anaerobic_diazotroph_minimum_growth_respiration_requirement_g_c_per_g_c
        else
            self.minimum_growth_respiration_requirement_g_c_per_g_c;
        return growthRespirationRequirement(
            self.fermentation_energy_yield_kilojoule_per_g_c -
                combined_product_feedback_kilojoule_per_g_c,
            requirement,
            minimum,
        );
    }

    /// Source `ECHZ` for an acetotrophic methanogen, given the acetate
    /// feedback `GOMM` in kilojoule per gram carbon. Note the source ADDS the
    /// acetate feedback here where the fermenter branch subtracts it.
    pub fn acetotrophicGrowthRespirationRequirement(
        self: AnaerobicGrowthEnergyParameters,
        acetate_feedback_kilojoule_per_g_c: f64,
    ) !f64 {
        return growthRespirationRequirement(
            self.acetotrophic_methanogenesis_energy_yield_kilojoule_per_g_c +
                acetate_feedback_kilojoule_per_g_c,
            self.acetotrophic_methanogen_growth_energy_requirement_kilojoule_per_g_c,
            self.minimum_growth_respiration_requirement_g_c_per_g_c,
        );
    }
};

/// Mandatory source ECHZ controls used when an older parameter file omits
/// the explicit record. This preserves file compatibility without restoring
/// the scientifically altered fixed-requirement production path.
pub const source_anaerobic_growth_energy_parameters: AnaerobicGrowthEnergyParameters = .{
    .fermentation_energy_yield_kilojoule_per_g_c = 3.0,
    .acetotrophic_methanogenesis_energy_yield_kilojoule_per_g_c = 1.5,
    .fermenter_growth_energy_requirement_kilojoule_per_g_c = 37.5,
    .anaerobic_diazotroph_growth_energy_requirement_kilojoule_per_g_c = 37.5,
    .acetotrophic_methanogen_growth_energy_requirement_kilojoule_per_g_c = 37.5,
    .minimum_growth_respiration_requirement_g_c_per_g_c = 0.4,
    .anaerobic_diazotroph_minimum_growth_respiration_requirement_g_c_per_g_c = 0.5,
};

fn growthRespirationRequirement(
    net_energy_kilojoule_per_g_c: f64,
    growth_energy_requirement_kilojoule_per_g_c: f64,
    minimum_g_c_per_g_c: f64,
) !f64 {
    if (!std.math.isFinite(net_energy_kilojoule_per_g_c) or
        !std.math.isFinite(growth_energy_requirement_kilojoule_per_g_c) or
        growth_energy_requirement_kilojoule_per_g_c <= 0 or
        !std.math.isFinite(minimum_g_c_per_g_c) or
        minimum_g_c_per_g_c < 0 or minimum_g_c_per_g_c > 1)
        return error.InvalidAnaerobicGrowthEnergy;
    const yield_ratio = @max(0, net_energy_kilojoule_per_g_c) /
        growth_energy_requirement_kilojoule_per_g_c;
    const result = @max(minimum_g_c_per_g_c, @min(1, 1 / (1 + yield_ratio)));
    if (!std.math.isFinite(result) or result < 0 or result > 1)
        return error.NonFiniteAnaerobicGrowthEnergy;
    return result;
}

pub const MicrobialTurnoverParameters = struct {
    labile_basal_decomposition_rate_per_h: f64,
    resistant_basal_decomposition_rate_per_h: f64,
    minimum_carbon_recycling_fraction: f64,
    carbon_recycling_range_fraction: f64,
    maximum_nitrogen_recycling_fraction: f64,
    maximum_phosphorus_recycling_fraction: f64,
    humification_intercept: f64,
    humification_clay_coefficient: f64,
    humification_maximum_clay_fraction: f64,
    woody_colonization_per_g_respired_carbon: f64,
    fine_litter_colonization_per_g_respired_carbon: f64,
    manure_colonization_per_g_respired_carbon: f64,
    particulate_colonization_per_g_respired_carbon: f64,
    humus_colonization_per_g_respired_carbon: f64,
    /// SOIL-EHUM-001 / `hour1.f:3739,2911` third EHUM term, `0.182E-06`.
    humification_organic_carbon_coefficient_per_g_per_megagram: f64,
};

pub const MethaneParameters = struct {
    hydrogenotroph_population_index: usize,
    methanotroph_population_index: usize,
    hydrogen_product_inhibition_g_h_per_m3: f64,
    hydrogen_half_saturation_g_h_per_m3: f64,
    hydrogenotrophic_specific_co2_reduction_g_c_per_g_c_h: f64,
    hydrogenotrophic_reference_energy_yield_kj_per_g_c: f64,
    methanogen_growth_energy_requirement_kj_per_g_c: f64,
    minimum_growth_respiration_fraction: f64,
    hydrogen_supply_conversion_g_c_per_g_h: f64,
    fermentation_hydrogen_to_pool_fraction: f64,
    methane_half_saturation_g_c_per_m3: f64,
    methane_solubility_water_to_air: f64,
    gas_exchange_rate_per_step: f64,
    methanotroph_biomass_conversion_efficiency_g_c_per_g_c: f64,
    methanotroph_growth_respiration_g_c_per_g_c: f64,
    methanotroph_specific_oxidation_per_h: f64,
};

pub const Parameters = struct {
    nitrification: nitrification.Parameters,
    denitrification: denitrification.Parameters,
    autotrophic_denitrification: AutotrophicDenitrificationParameters,
    chemodenitrification: chemodenitrification.Parameters,
    nitrous_acid_dissociation_mol_per_m3: f64,
    microbial_thermal_adaptation_offset_k: f64,
    nitrifier_indices: NitrifierIndices,
    nitrifier_environment: NitrifierEnvironmentParameters,
    oxygen_uptake: OxygenUptakeParameters,
    heterotrophic_respiration: HeterotrophicRespirationParameters,
    microbial_mineral_exchange: MicrobialMineralExchangeParameters,
    nonsymbiotic_nitrogen_fixation: NonsymbioticNitrogenFixationParameters,
    microbial_turnover: MicrobialTurnoverParameters,
    microbial_layer_mixing_rate_per_h: f64 = 0.001,
    methane: ?MethaneParameters = null,
    /// Source NITRO.F 179--187 anaerobic `ECHZ` energetics. This is mandatory
    /// runtime science. Older parameter files that omit the extension record
    /// receive the exact source controls during parsing; no active caller can
    /// select the altered fixed-requirement fallback by constructing `null`.
    anaerobic_growth_energy: AnaerobicGrowthEnergyParameters = source_anaerobic_growth_energy_parameters,
};

/// Runtime compatibility defaults transcribed from the source NITRO parameter
/// set. They are returned as ordinary runtime state and remain fully
/// replaceable by a user-supplied parameter file.
pub fn sourceParameters() !Parameters {
    return parse(source_parameter_text);
}

/// Runtime compatibility defaults for NITRO.F 900--1048. This isolated
/// parser is intentionally not production-bound until the two kernels have
/// authoritative state-array owners.
pub fn sourceAnaerobicEnergyParameters() !AnaerobicEnergyParameters {
    return parseAnaerobicEnergyParameters(source_anaerobic_energy_parameter_text);
}

const source_anaerobic_energy_parameter_text =
    "soil_fermenter_respiration,3,6,0.125,12,12,3,37.5,37.5,0.4,0.5,0.0083143,2,72\n" ++
    "soil_acetotrophic_methanogenesis,4,12,12,0.125,1.5,37.5,0.4,0.0083143,24,0.5";

const source_parameter_text_without_anaerobic_growth_energy =
    "soil_nitrification,0.001,0.0002,7000,14,1.4,1.4,0.125,0.125,0.3,0.1,0.5,2.667,3.429,1.143\n" ++
    "soil_denitrification,0.001,1.4,1.4,0.014,1,0.429,0.429,0.214,0.875\n" ++
    "soil_autotrophic_denitrification,0.5,0.333\n" ++
    "soil_chemodenitrification,0.0005,0.001,1e-12,0.5,0,0.5\n" ++
    "nitrous_acid_dissociation_mol_per_m3,0.45\n" ++
    "soil_microbial_thermal_adaptation_offset_k,0\n" ++
    "soil_nitrifier_indices,5,0,1,1\n" ++
    "soil_nitrifier_environment,0.55,0.1,0.1,0.01,0.01,12,0.1\n" ++
    "soil_oxygen_uptake,1e-6,2.3866348449e11,0.064,-1.5e4,0.5,12,12,0.5,0.7,0.001,1e-12\n" ++
    "soil_heterotrophic_respiration,0.125,0.1,0.01,12,12,0.5,0.42016806722689076,0.1,2.667,0.01,0.01,1e-6,1,0.7142857142857143\n" ++
    "soil_microbial_mineral_exchange,0.014,0.0125,0.40,0.014,0.03,0.35,0.003,0.009,0.18,31\n" ++
    "soil_nonsymbiotic_nitrogen_fixation,5,6,0.25,0.02,0.14,0.25\n" ++
    "soil_microbial_turnover,0.01,0.001,0.167,0.333,0.333,0.333,0.150,0.300,0.333,0.25,2.0,5.0,1.0,0.5,0.182e-6\n" ++
    "soil_microbial_layer_mixing,0.001\n" ++
    // NITRO.F 95, 150--158, 179--187: H2KI,H2KM,VMXC,GCOX,EOMH,
    // EO2X,CCK4,ECHO,EH4X,VMX4. The remaining exchange/stoichiometry
    // controls retain their runtime source bindings.
    "soil_methane,4,2,1,0.01,0.125,11,37.5,0.4,1.5,0.111,0.0012,0.03,0.5,0.75,0.27322404371584696,0.375";

const source_parameter_text =
    source_parameter_text_without_anaerobic_growth_energy ++
    // NITRO.F 179--187: GCHX=3.0, GC4X=1.5, EOMF=EOMY=EOMH=37.5,
    // EO2X=1/(1+GO2X/EOMC)=1/(1+37.5/25)=0.4, ENFY=1/(1+37.5/37.5)=0.5.
    "\nsoil_anaerobic_growth_energy,3.0,1.5,37.5,37.5,37.5,0.4,0.5";

/// Runtime soil NITRO parameters. Record names are ASCII case-insensitive and
/// values accept comma, tab, space, or pipe delimiters with any file extension.
pub noinline fn parse(source: []const u8) !Parameters {
    try validateRecordArities(source);
    var tokens = delimited_input.tokens(source);
    var result: Parameters = undefined;
    try expectRecord(&tokens, "soil_nitrification");
    try fillStruct(nitrification.Parameters, &result.nitrification, &tokens);
    try expectRecord(&tokens, "soil_denitrification");
    try fillStruct(denitrification.Parameters, &result.denitrification, &tokens);
    try expectRecord(&tokens, "soil_autotrophic_denitrification");
    try fillStruct(AutotrophicDenitrificationParameters, &result.autotrophic_denitrification, &tokens);
    try expectRecord(&tokens, "soil_chemodenitrification");
    try fillStruct(chemodenitrification.Parameters, &result.chemodenitrification, &tokens);
    try expectRecord(&tokens, "nitrous_acid_dissociation_mol_per_m3");
    result.nitrous_acid_dissociation_mol_per_m3 = try nextFloat(&tokens);
    try expectRecord(&tokens, "soil_microbial_thermal_adaptation_offset_k");
    result.microbial_thermal_adaptation_offset_k = try nextFloat(&tokens);
    try expectRecord(&tokens, "soil_nitrifier_indices");
    result.nitrifier_indices = .{ .autotrophic_substrate_index = try nextUnsigned(&tokens), .ammonia_oxidizer_population_index = try nextUnsigned(&tokens), .nitrite_oxidizer_population_index = try nextUnsigned(&tokens), .heterotrophic_denitrifier_population_index = try nextUnsigned(&tokens) };
    try expectRecord(&tokens, "soil_nitrifier_environment");
    try fillStruct(NitrifierEnvironmentParameters, &result.nitrifier_environment, &tokens);
    try expectRecord(&tokens, "soil_oxygen_uptake");
    try fillStruct(OxygenUptakeParameters, &result.oxygen_uptake, &tokens);
    try expectRecord(&tokens, "soil_heterotrophic_respiration");
    try fillStruct(HeterotrophicRespirationParameters, &result.heterotrophic_respiration, &tokens);
    try expectRecord(&tokens, "soil_microbial_mineral_exchange");
    try fillStruct(MicrobialMineralExchangeParameters, &result.microbial_mineral_exchange, &tokens);
    try expectRecord(&tokens, "soil_nonsymbiotic_nitrogen_fixation");
    result.nonsymbiotic_nitrogen_fixation = .{
        .aerobic_diazotroph_population_index = try nextUnsigned(&tokens),
        .anaerobic_diazotroph_population_index = try nextUnsigned(&tokens),
        .aerobic_yield_g_n_per_g_c = try nextFloat(&tokens),
        .anaerobic_yield_g_n_per_g_c = try nextFloat(&tokens),
        .dinitrogen_half_saturation_g_n_per_m3 = try nextFloat(&tokens),
        .nonstructural_to_structural_rate_per_h = try nextFloat(&tokens),
    };
    try expectRecord(&tokens, "soil_microbial_turnover");
    try fillStruct(MicrobialTurnoverParameters, &result.microbial_turnover, &tokens);
    result.microbial_layer_mixing_rate_per_h = 0.001;
    result.methane = null;
    result.anaerobic_growth_energy = source_anaerobic_growth_energy_parameters;
    var has_mixing = false;
    var has_anaerobic_growth_energy = false;
    while (tokens.next()) |record| {
        if (std.ascii.eqlIgnoreCase(record, "soil_microbial_layer_mixing")) {
            if (has_mixing) return error.DuplicateSoilNitrogenParameter;
            result.microbial_layer_mixing_rate_per_h = try nextFloat(&tokens);
            has_mixing = true;
        } else if (std.ascii.eqlIgnoreCase(record, "soil_methane")) {
            if (result.methane != null) return error.DuplicateSoilNitrogenParameter;
            var methane: MethaneParameters = undefined;
            methane.hydrogenotroph_population_index = try nextUnsigned(&tokens);
            methane.methanotroph_population_index = try nextUnsigned(&tokens);
            inline for (@typeInfo(MethaneParameters).@"struct".fields[2..]) |field| @field(methane, field.name) = try nextFloat(&tokens);
            result.methane = methane;
        } else if (std.ascii.eqlIgnoreCase(record, "soil_anaerobic_growth_energy")) {
            if (has_anaerobic_growth_energy) return error.DuplicateSoilNitrogenParameter;
            var energy: AnaerobicGrowthEnergyParameters = undefined;
            inline for (@typeInfo(AnaerobicGrowthEnergyParameters).@"struct".fields) |field|
                @field(energy, field.name) = try nextFloat(&tokens);
            result.anaerobic_growth_energy = energy;
            has_anaerobic_growth_energy = true;
        } else return error.UnexpectedSoilNitrogenParameter;
    }
    try validate(result);
    return result;
}

/// Parses the two compulsory anaerobic-energy records with exact physical
/// line arity. Record names are ASCII case-insensitive.
pub fn parseAnaerobicEnergyParameters(source: []const u8) !AnaerobicEnergyParameters {
    try validateAnaerobicEnergyRecordArities(source);
    var tokens = delimited_input.tokens(source);
    try expectRecord(&tokens, "soil_fermenter_respiration");
    const fermenter = FermenterRespirationParameters{
        .fermenter_population_index = try nextUnsigned(&tokens),
        .anaerobic_diazotroph_population_index = try nextUnsigned(&tokens),
        .specific_oxidation_rate_g_c_per_g_c_h = try nextFloat(&tokens),
        .dissolved_organic_carbon_half_saturation_g_c_per_m3 = try nextFloat(&tokens),
        .acetate_product_inhibition_g_c_per_m3 = try nextFloat(&tokens),
        .reference_energy_yield_kj_per_g_c = try nextFloat(&tokens),
        .growth_energy_requirement_kj_per_g_c = try nextFloat(&tokens),
        .diazotroph_growth_energy_requirement_kj_per_g_c = try nextFloat(&tokens),
        .minimum_respiration_requirement_g_c_per_g_c = try nextFloat(&tokens),
        .diazotroph_minimum_respiration_requirement_g_c_per_g_c = try nextFloat(&tokens),
        .gas_constant_kj_per_mol_k = try nextFloat(&tokens),
        .acetate_feedback_stoichiometric_exponent = try nextFloat(&tokens),
        .feedback_carbon_conversion_g_c_per_mol = try nextFloat(&tokens),
    };
    try expectRecord(&tokens, "soil_acetotrophic_methanogenesis");
    const acetotrophic = AcetotrophicMethanogenesisParameters{
        .population_index = try nextUnsigned(&tokens),
        .acetate_product_inhibition_g_c_per_m3 = try nextFloat(&tokens),
        .acetate_half_saturation_g_c_per_m3 = try nextFloat(&tokens),
        .specific_respiration_rate_g_c_per_g_c_h = try nextFloat(&tokens),
        .reference_energy_yield_kj_per_g_c = try nextFloat(&tokens),
        .growth_energy_requirement_kj_per_g_c = try nextFloat(&tokens),
        .minimum_growth_respiration_fraction = try nextFloat(&tokens),
        .gas_constant_kj_per_mol_k = try nextFloat(&tokens),
        .feedback_carbon_conversion_g_c_per_mol = try nextFloat(&tokens),
        .methane_carbon_yield_g_c_per_g_c_oxidized = try nextFloat(&tokens),
    };
    if (tokens.next() != null) return error.UnexpectedSoilNitrogenParameter;
    const result = AnaerobicEnergyParameters{
        .fermenter = fermenter,
        .acetotrophic_methanogenesis = acetotrophic,
    };
    try validateAnaerobicEnergyParameters(result);
    return result;
}

fn validateAnaerobicEnergyRecordArities(source: []const u8) !void {
    var records = delimited_input.records(source);
    var record_index: usize = 0;
    const names = [_][]const u8{
        "soil_fermenter_respiration",
        "soil_acetotrophic_methanogenesis",
    };
    const counts = [_]usize{
        structFieldCount(FermenterRespirationParameters),
        structFieldCount(AcetotrophicMethanogenesisParameters),
    };
    while (records.next()) |record| : (record_index += 1) {
        if (record_index >= names.len) return error.UnexpectedSoilNitrogenParameterRecord;
        if (hasEmptyExplicitField(record)) return error.EmptySoilNitrogenParameterValue;
        var tokens = delimited_input.recordTokens(record);
        const label = tokens.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(label, names[record_index]))
            return error.UnexpectedSoilNitrogenParameterRecord;
        var actual_count: usize = 0;
        while (tokens.next() != null) actual_count += 1;
        if (actual_count != counts[record_index])
            return error.InvalidSoilNitrogenParameterRecordArity;
    }
    if (record_index != names.len) return error.MissingSoilNitrogenParameterRecord;
}

fn validateAnaerobicEnergyParameters(parameters: AnaerobicEnergyParameters) !void {
    const fermenter = parameters.fermenter;
    if (fermenter.fermenter_population_index == fermenter.anaerobic_diazotroph_population_index)
        return error.InvalidSoilNitrogenParameter;
    inline for (@typeInfo(FermenterRespirationParameters).@"struct".fields[2..]) |field| {
        const value = @field(fermenter, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidSoilNitrogenParameter;
    }
    if (fermenter.minimum_respiration_requirement_g_c_per_g_c > 1 or
        fermenter.diazotroph_minimum_respiration_requirement_g_c_per_g_c > 1)
        return error.InvalidSoilNitrogenParameter;
    const acetotrophic = parameters.acetotrophic_methanogenesis;
    inline for (@typeInfo(AcetotrophicMethanogenesisParameters).@"struct".fields[1..]) |field| {
        const value = @field(acetotrophic, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidSoilNitrogenParameter;
    }
    if (acetotrophic.minimum_growth_respiration_fraction > 1 or
        acetotrophic.methane_carbon_yield_g_c_per_g_c_oxidized > 1)
        return error.InvalidSoilNitrogenParameter;
}

fn validateRecordArities(source: []const u8) !void {
    var records = delimited_input.records(source);
    while (records.next()) |record| {
        if (hasEmptyExplicitField(record))
            return error.EmptySoilNitrogenParameterValue;
        var tokens = delimited_input.recordTokens(record);
        const label = tokens.next() orelse continue;
        if (label[0] == '#') continue;
        const expected_count = expectedRecordValueCount(label) orelse
            return error.UnexpectedSoilNitrogenParameterRecord;
        var actual_count: usize = 0;
        while (tokens.next() != null) actual_count += 1;
        if (actual_count != expected_count)
            return error.InvalidSoilNitrogenParameterRecordArity;
    }
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

fn expectedRecordValueCount(label: []const u8) ?usize {
    const Entry = struct {
        name: []const u8,
        count: usize,
    };
    const entries = [_]Entry{
        .{ .name = "soil_nitrification", .count = structFieldCount(nitrification.Parameters) },
        .{ .name = "soil_denitrification", .count = structFieldCount(denitrification.Parameters) },
        .{ .name = "soil_autotrophic_denitrification", .count = structFieldCount(AutotrophicDenitrificationParameters) },
        .{ .name = "soil_chemodenitrification", .count = structFieldCount(chemodenitrification.Parameters) },
        .{ .name = "nitrous_acid_dissociation_mol_per_m3", .count = 1 },
        .{ .name = "soil_microbial_thermal_adaptation_offset_k", .count = 1 },
        .{ .name = "soil_nitrifier_indices", .count = structFieldCount(NitrifierIndices) },
        .{ .name = "soil_nitrifier_environment", .count = structFieldCount(NitrifierEnvironmentParameters) },
        .{ .name = "soil_oxygen_uptake", .count = structFieldCount(OxygenUptakeParameters) },
        .{ .name = "soil_heterotrophic_respiration", .count = structFieldCount(HeterotrophicRespirationParameters) },
        .{ .name = "soil_microbial_mineral_exchange", .count = structFieldCount(MicrobialMineralExchangeParameters) },
        .{ .name = "soil_nonsymbiotic_nitrogen_fixation", .count = structFieldCount(NonsymbioticNitrogenFixationParameters) },
        .{ .name = "soil_microbial_turnover", .count = structFieldCount(MicrobialTurnoverParameters) },
        .{ .name = "soil_microbial_layer_mixing", .count = 1 },
        .{ .name = "soil_methane", .count = structFieldCount(MethaneParameters) },
        .{ .name = "soil_anaerobic_growth_energy", .count = structFieldCount(AnaerobicGrowthEnergyParameters) },
    };
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(label, entry.name)) return entry.count;
    }
    return null;
}

fn structFieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".fields.len;
}

pub fn validate(parameters: Parameters) !void {
    try parameters.nitrification.validate();
    try parameters.denitrification.validate();
    const autotrophic = parameters.autotrophic_denitrification;
    if (!std.math.isFinite(autotrophic.anaerobic_growth_respiration_fraction) or autotrophic.anaerobic_growth_respiration_fraction < 0 or autotrophic.anaerobic_growth_respiration_fraction > 1 or !std.math.isFinite(autotrophic.additional_ammonium_oxidation_per_nitrite_reduction) or autotrophic.additional_ammonium_oxidation_per_nitrite_reduction <= 0 or autotrophic.additional_ammonium_oxidation_per_nitrite_reduction >= 1) return error.InvalidSoilNitrogenParameter;
    const chemo = parameters.chemodenitrification;
    inline for (@typeInfo(chemodenitrification.Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(chemo, field.name)) or @field(chemo, field.name) < 0) return error.InvalidSoilNitrogenParameter;
    if (chemo.negligible_demand_g_n <= 0 or @abs(chemo.nitrous_oxide_product_fraction + chemo.dinitrogen_product_fraction + chemo.dissolved_organic_nitrogen_product_fraction - 1) > 1e-12) return error.InvalidSoilNitrogenParameter;
    if (!std.math.isFinite(parameters.nitrous_acid_dissociation_mol_per_m3) or parameters.nitrous_acid_dissociation_mol_per_m3 <= 0) return error.InvalidSoilNitrogenParameter;
    if (!std.math.isFinite(parameters.microbial_thermal_adaptation_offset_k)) return error.InvalidSoilNitrogenParameter;
    if (parameters.nitrifier_indices.ammonia_oxidizer_population_index == parameters.nitrifier_indices.nitrite_oxidizer_population_index) return error.InvalidSoilNitrogenParameter;
    inline for (@typeInfo(NitrifierEnvironmentParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters.nitrifier_environment, field.name)) or @field(parameters.nitrifier_environment, field.name) <= 0) return error.InvalidSoilNitrogenParameter;
    if (parameters.nitrifier_environment.labile_biomass_fraction > 1) return error.InvalidSoilNitrogenParameter;
    inline for (@typeInfo(OxygenUptakeParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters.oxygen_uptake, field.name))) return error.InvalidSoilNitrogenParameter;
    const oxygen = parameters.oxygen_uptake;
    if (oxygen.microbial_radius_m <= 0 or oxygen.microbial_count_per_g_c < 0 or oxygen.oxygen_half_saturation_g_o_per_m3 <= 0 or oxygen.hygroscopic_water_potential_megapascal >= 0 or oxygen.air_water_exchange_reference_time_h <= 0 or oxygen.minimum_transition_water_fraction < 0 or oxygen.minimum_transition_water_fraction > 1 or oxygen.aqueous_tortuosity_coefficient < 0 or oxygen.minimum_allocation_fraction < 0 or oxygen.negligible_oxygen_demand_g_o < 0) return error.InvalidSoilNitrogenParameter;
    inline for (@typeInfo(HeterotrophicRespirationParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters.heterotrophic_respiration, field.name)) or @field(parameters.heterotrophic_respiration, field.name) <= 0) return error.InvalidSoilNitrogenParameter;
    inline for (@typeInfo(MicrobialMineralExchangeParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters.microbial_mineral_exchange, field.name)) or @field(parameters.microbial_mineral_exchange, field.name) <= 0) return error.InvalidSoilNitrogenParameter;
    const fixation = parameters.nonsymbiotic_nitrogen_fixation;
    if (fixation.aerobic_diazotroph_population_index == fixation.anaerobic_diazotroph_population_index) return error.InvalidSoilNitrogenParameter;
    inline for (.{ fixation.aerobic_yield_g_n_per_g_c, fixation.anaerobic_yield_g_n_per_g_c, fixation.dinitrogen_half_saturation_g_n_per_m3, fixation.nonstructural_to_structural_rate_per_h }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSoilNitrogenParameter;
    const turnover = parameters.microbial_turnover;
    inline for (@typeInfo(MicrobialTurnoverParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(turnover, field.name)) or @field(turnover, field.name) < 0) return error.InvalidSoilNitrogenParameter;
    if (!std.math.isFinite(parameters.microbial_layer_mixing_rate_per_h) or parameters.microbial_layer_mixing_rate_per_h < 0) return error.InvalidSoilNitrogenParameter;
    if (parameters.methane) |methane| {
        if (methane.hydrogenotroph_population_index == methane.methanotroph_population_index) return error.InvalidSoilNitrogenParameter;
        inline for (@typeInfo(MethaneParameters).@"struct".fields[2..]) |field| if (!std.math.isFinite(@field(methane, field.name)) or @field(methane, field.name) < 0) return error.InvalidSoilNitrogenParameter;
        if (methane.hydrogen_half_saturation_g_h_per_m3 <= 0 or methane.methanogen_growth_energy_requirement_kj_per_g_c <= 0 or methane.hydrogen_supply_conversion_g_c_per_g_h <= 0 or methane.methane_half_saturation_g_c_per_m3 <= 0 or methane.minimum_growth_respiration_fraction > 1) return error.InvalidSoilNitrogenParameter;
    }
    const energy = parameters.anaerobic_growth_energy;
    inline for (@typeInfo(AnaerobicGrowthEnergyParameters).@"struct".fields) |field| {
        const value = @field(energy, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidSoilNitrogenParameter;
    }
    // The two ECHZ floors are dimensionless growth respiration fractions.
    if (energy.minimum_growth_respiration_requirement_g_c_per_g_c > 1 or
        energy.anaerobic_diazotroph_minimum_growth_respiration_requirement_g_c_per_g_c > 1)
        return error.InvalidSoilNitrogenParameter;
    // Both ECHZ branches must be evaluable at zero product feedback, which
    // is the most favourable case, and at the strongest feedback that still
    // leaves a nonnegative numerator. Failing here beats failing per layer.
    _ = try energy.fermenterGrowthRespirationRequirement(0, false);
    _ = try energy.fermenterGrowthRespirationRequirement(0, true);
    _ = try energy.acetotrophicGrowthRespirationRequirement(0);
    if (turnover.minimum_carbon_recycling_fraction + turnover.carbon_recycling_range_fraction > 1 or turnover.maximum_nitrogen_recycling_fraction > 1 or turnover.maximum_phosphorus_recycling_fraction > 1 or turnover.humification_maximum_clay_fraction > 1) return error.InvalidSoilNitrogenParameter;
}

fn fillStruct(comptime T: type, value: *T, tokens: anytype) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| @field(value, field.name) = try nextFloat(tokens);
}

fn expectRecord(tokens: anytype, expected: []const u8) !void {
    const actual = tokens.next() orelse return error.MissingSoilNitrogenParameterRecord;
    if (!std.ascii.eqlIgnoreCase(actual, expected)) return error.UnexpectedSoilNitrogenParameterRecord;
}

fn nextFloat(tokens: anytype) !f64 {
    const text = tokens.next() orelse return error.MissingSoilNitrogenParameter;
    const value = std.fmt.parseFloat(f64, text) catch return error.InvalidSoilNitrogenParameter;
    if (!std.math.isFinite(value)) return error.NonFiniteSoilNitrogenParameter;
    return value;
}

fn nextUnsigned(tokens: anytype) !usize {
    const text = tokens.next() orelse return error.MissingSoilNitrogenParameter;
    return std.fmt.parseUnsigned(usize, text, 10) catch return error.InvalidSoilNitrogenParameter;
}

test "soil nitrogen parameters are self-contained flexible and case-insensitive" {
    const source =
        "SOIL_NITRIFICATION,0.001,0.0002,7000,14,1.4,1.4,0.125,0.125,0.3,0.1,0.5,2.667,3.429,1.143\n" ++
        "Soil_Denitrification|0.001|1.4|1.4|0.014|1|0.429|0.429|0.214|0.875\n" ++
        "soil_autotrophic_denitrification 0.5 0.333\n" ++
        "soil_chemodenitrification\t0.0005\t0.001\t1e-12\t0.5\t0\t0.5\n" ++
        "nitrous_acid_dissociation_mol_per_m3 0.45\n" ++
        "soil_microbial_thermal_adaptation_offset_k 0\n" ++
        "soil_nitrifier_indices 5 0 1 1\n" ++
        "soil_nitrifier_environment 0.55 0.1 0.1 0.01 0.01 12 0.1\n" ++
        "soil_oxygen_uptake 1e-6 2.3866348449e11 0.064 -1.5e4 0.5 12 12 0.5 0.7 0.001 1e-12\n" ++
        "soil_heterotrophic_respiration 0.125 0.1 0.01 12 12 0.5 0.42016806722689076 0.1 2.667 0.01 0.01 1e-6 1 0.7142857142857143\n" ++
        "soil_microbial_mineral_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 0.003 0.009 0.18 31\n" ++
        "soil_nonsymbiotic_nitrogen_fixation 5 6 0.25 0.02 0.14 0.25\n" ++
        "soil_microbial_turnover 0.01 0.001 0.167 0.333 0.333 0.333 0.150 0.300 0.333 0.25 2.0 5.0 1.0 0.5 0.182e-6\n" ++
        "Soil_Microbial_Layer_Mixing|0.0025\n" ++
        "Soil_Methane|4|2|0.001|0.01|0.1|1|10|0.05|1.5|0.111|0.2|0.03|0.5|0.4|0.5|0.125";
    const parameters = try parse(source);
    try std.testing.expectEqual(@as(f64, 0.125), parameters.nitrification.ammonia_oxidation_rate_g_n_per_g_c_h);
    try std.testing.expectEqual(@as(f64, 0.45), parameters.nitrous_acid_dissociation_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.064), parameters.oxygen_uptake.oxygen_half_saturation_g_o_per_m3);
    try std.testing.expectEqual(@as(f64, 0.0025), parameters.microbial_layer_mixing_rate_per_h);
    try std.testing.expectEqual(@as(usize, 4), parameters.methane.?.hydrogenotroph_population_index);
    try std.testing.expectEqual(@as(f64, 0.125), parameters.methane.?.methanotroph_specific_oxidation_per_h);
}

test "source NITRO defaults are runtime validated and keep methane active" {
    const parameters = try sourceParameters();
    try validate(parameters);
    try std.testing.expect(parameters.methane != null);
    try std.testing.expectEqual(@as(f64, 0.125), parameters.nitrification.ammonia_oxidation_rate_g_n_per_g_c_h);
    try std.testing.expectEqual(@as(f64, 31), parameters.microbial_mineral_exchange.phosphorus_molar_mass_g_per_mol);
    try std.testing.expectEqual(@as(f64, 0.001), parameters.microbial_layer_mixing_rate_per_h);
}

test "source NITRO derived geometry phosphate and EN2F defaults reach runtime owners" {
    const parameters = try sourceParameters();
    const radius_m = parameters.oxygen_uptake.microbial_radius_m;
    const source_count_per_g_c = 1.0e-6 / (4.19 * radius_m * radius_m * radius_m);
    try std.testing.expectApproxEqRel(
        source_count_per_g_c,
        parameters.oxygen_uptake.microbial_count_per_g_c,
        2e-11,
    );
    const source_surface_area_m2_per_g_c =
        source_count_per_g_c * 12.57 * radius_m * radius_m;
    const kernel_surface_area_m2_per_g_c =
        parameters.oxygen_uptake.microbial_count_per_g_c *
        4 * std.math.pi * radius_m * radius_m;
    // The kernel uses exact 4*pi while Fortran used rounded 12.57.
    try std.testing.expectApproxEqRel(
        source_surface_area_m2_per_g_c,
        kernel_surface_area_m2_per_g_c,
        3e-4,
    );

    const phosphate = parameters.microbial_mineral_exchange;
    try std.testing.expectEqual(
        @as(f64, 0.25 * 0.003),
        0.25 * phosphate.phosphate_maximum_uptake_g_p_per_m2_h,
    );
    try std.testing.expectEqual(
        @as(f64, 0.25 * 0.009),
        0.25 * phosphate.phosphate_minimum_concentration_g_p_per_m3,
    );

    var fixation_yield_by_population: [7]f64 = @splat(0);
    const fixation = parameters.nonsymbiotic_nitrogen_fixation;
    fixation_yield_by_population[fixation.aerobic_diazotroph_population_index] =
        fixation.aerobic_yield_g_n_per_g_c;
    fixation_yield_by_population[fixation.anaerobic_diazotroph_population_index] =
        fixation.anaerobic_yield_g_n_per_g_c;
    try std.testing.expectEqual(
        [7]f64{ 0, 0, 0, 0, 0, 0.25, 0.02 },
        fixation_yield_by_population,
    );
    try std.testing.expectEqual(@as(f64, 37.5) / 150.0, fixation.aerobic_yield_g_n_per_g_c);
    try std.testing.expectEqual(@as(f64, 3.0) / 150.0, fixation.anaerobic_yield_g_n_per_g_c);
}

test "anaerobic energy owners remain outside production parameter aggregate" {
    // The two isolated vector kernels are still NOT production-bound, and must
    // not be: `soil_heterotrophic_respiration_step` already owns the anaerobic
    // respiration publish set for the same populations, so binding them would
    // be a double mutation. See
    // `docs/traceability/bind_nitro_001_double_mutation_analysis.md`.
    try std.testing.expect(!@hasField(Parameters, "fermenter_respiration"));
    try std.testing.expect(!@hasField(Parameters, "acetotrophic_methanogenesis"));

    const methane = (try sourceParameters()).methane.?;
    // These fields belong to the hydrogenotrophic path: source GCOX=11 and
    // EOMH=37.5.  The acetotrophic path independently owns GC4X=1.5 below.
    try std.testing.expectEqual(@as(f64, 11), methane.hydrogenotrophic_reference_energy_yield_kj_per_g_c);
    try std.testing.expectEqual(@as(f64, 37.5), methane.methanogen_growth_energy_requirement_kj_per_g_c);

    // The `ECHZ` energetics DO now have a runtime home, because the owning
    // NITRO lane needs one to correct the constants inside the single existing
    // owner. Carrying the values is not the same as binding a second writer.
    const energy = (try sourceParameters()).anaerobic_growth_energy;
    try std.testing.expectEqual(@as(f64, 1.5), energy.acetotrophic_methanogenesis_energy_yield_kilojoule_per_g_c);
    try std.testing.expectEqual(@as(f64, 37.5), energy.acetotrophic_methanogen_growth_energy_requirement_kilojoule_per_g_c);
}

test "NITRO 179-187 anaerobic ECHZ energetics reach a runtime owner" {
    const energy = (try sourceParameters()).anaerobic_growth_energy;
    // GCHX=3.00, GC4X=1.50, EOMF=EOMY=EOMH=37.5 at nitro.f 179--182.
    try std.testing.expectEqual(@as(f64, 3.0), energy.fermentation_energy_yield_kilojoule_per_g_c);
    try std.testing.expectEqual(@as(f64, 1.5), energy.acetotrophic_methanogenesis_energy_yield_kilojoule_per_g_c);
    try std.testing.expectEqual(@as(f64, 37.5), energy.fermenter_growth_energy_requirement_kilojoule_per_g_c);
    try std.testing.expectEqual(@as(f64, 37.5), energy.anaerobic_diazotroph_growth_energy_requirement_kilojoule_per_g_c);
    try std.testing.expectEqual(@as(f64, 37.5), energy.acetotrophic_methanogen_growth_energy_requirement_kilojoule_per_g_c);
    // EO2X=1/(1+GO2X/EOMC)=1/(1+37.5/25); ENFY=1/(1+GO2X/EOMY)=1/(1+37.5/37.5).
    try std.testing.expectEqual(
        1.0 / (1.0 + 37.5 / 25.0),
        energy.minimum_growth_respiration_requirement_g_c_per_g_c,
    );
    try std.testing.expectEqual(
        1.0 / (1.0 + 37.5 / 37.5),
        energy.anaerobic_diazotroph_minimum_growth_respiration_requirement_g_c_per_g_c,
    );
}

test "NITRO 924-928 and 1003-1004 ECHZ reproduce source operation order" {
    const energy = (try sourceParameters()).anaerobic_growth_energy;

    // Read the source form carefully. ECHZ is the growth RESPIRATION
    // requirement, so growth yield is 1-ECHZ:
    //   ECHZ = max(floor, min(1, 1/(1 + max(0, net)/EOM)))
    // A LARGER net available energy makes the denominator larger and ECHZ
    // SMALLER, i.e. more of the carbon becomes biomass. When net energy falls
    // to zero the ratio is zero and ECHZ saturates at exactly 1: every gram
    // respired, no growth. That is the correct self-limiting direction.

    // Zero product feedback. fermenter N=4: 1/(1+max(0,3.0-0)/37.5).
    try std.testing.expectApproxEqAbs(
        1.0 / (1.0 + 3.0 / 37.5),
        try energy.fermenterGrowthRespirationRequirement(0, false),
        1e-15,
    );
    // acetotroph N=5: 1/(1+max(0,1.5+0)/37.5). Note the source ADDS the
    // acetate feedback for this branch where the fermenter subtracts it.
    try std.testing.expectApproxEqAbs(
        1.0 / (1.0 + 1.5 / 37.5),
        try energy.acetotrophicGrowthRespirationRequirement(0),
        1e-15,
    );

    // Strong H2/acetate feedback cancels the fermentation energy yield, so the
    // numerator clamps at zero and ECHZ saturates at 1. This is the mechanism
    // that makes fermentation self-limiting as products accumulate.
    try std.testing.expectEqual(
        @as(f64, 1),
        try energy.fermenterGrowthRespirationRequirement(3.0, false),
    );
    try std.testing.expectEqual(
        @as(f64, 1),
        try energy.fermenterGrowthRespirationRequirement(100, false),
    );
    // Symmetrically, a strongly NEGATIVE acetate feedback drives the
    // acetotroph numerator to zero, so it too saturates at 1, not at the floor.
    try std.testing.expectEqual(
        @as(f64, 1),
        try energy.acetotrophicGrowthRespirationRequirement(-1000),
    );

    // The EO2X/ENFY floors bind only when net energy is LARGE. For the
    // acetotroph, 1/(1+net/37.5) < EO2X=0.4 needs net > 37.5*1.5 = 56.25, so
    // an acetate feedback above 54.75 reaches the floor.
    try std.testing.expectEqual(
        energy.minimum_growth_respiration_requirement_g_c_per_g_c,
        try energy.acetotrophicGrowthRespirationRequirement(100),
    );
    // The diazotroph floor ENFY=0.5 binds sooner than the fermenter floor
    // EO2X=0.4: it needs only net > 37.5, i.e. a feedback below 3.0-37.5.
    try std.testing.expectEqual(
        energy.anaerobic_diazotroph_minimum_growth_respiration_requirement_g_c_per_g_c,
        try energy.fermenterGrowthRespirationRequirement(-100, true),
    );
    try std.testing.expectEqual(
        energy.minimum_growth_respiration_requirement_g_c_per_g_c,
        try energy.fermenterGrowthRespirationRequirement(-100, false),
    );

    // ECHZ is monotonically NON-DECREASING in the fermenter product feedback:
    // more accumulated product means more respiration and less growth.
    var previous: f64 = 0;
    for ([_]f64{ -100, -50, -10, -1, 0, 1, 2, 3, 50 }) |feedback| {
        const value = try energy.fermenterGrowthRespirationRequirement(feedback, false);
        try std.testing.expect(value >= previous);
        previous = value;
    }

    // Every result is a valid growth respiration fraction within its floor.
    for ([_]f64{ -1000, -50, -1, 0, 1, 3, 50, 1000 }) |feedback| {
        const fermenter = try energy.fermenterGrowthRespirationRequirement(feedback, false);
        const diazotroph = try energy.fermenterGrowthRespirationRequirement(feedback, true);
        const acetotroph = try energy.acetotrophicGrowthRespirationRequirement(feedback);
        for ([_]f64{ fermenter, diazotroph, acetotroph }) |value| {
            try std.testing.expect(value >= 0 and value <= 1);
        }
        try std.testing.expect(diazotroph >= energy.anaerobic_diazotroph_minimum_growth_respiration_requirement_g_c_per_g_c);
        try std.testing.expect(fermenter >= energy.minimum_growth_respiration_requirement_g_c_per_g_c);
        try std.testing.expect(acetotroph >= energy.minimum_growth_respiration_requirement_g_c_per_g_c);
    }
}

test "aerobic compatibility constants remain distinct from mandatory source ECHZ" {
    // BIND-NITRO-001 found that these aerobic compatibility constants had
    // incorrectly driven anaerobic branches. Pin their distinct origins while
    // the active anaerobic path uses the mandatory dynamic ECHZ controls.
    const energy = (try sourceParameters()).anaerobic_growth_energy;
    const heterotrophic = (try sourceParameters()).heterotrophic_respiration;

    // 0.42016806722689076 is EO2A = 1/(1+(GO2X-GCHX)/EOMC), the AEROBIC acetate
    // requirement, not the acetotrophic methanogen's ECHZ. Exact to the last
    // bit, so this is certainly its origin.
    const aerobic_acetate_requirement = 1.0 / (1.0 + (37.5 - 3.0) / 25.0);
    try std.testing.expectApproxEqAbs(
        aerobic_acetate_requirement,
        heterotrophic.acetate_respiration_requirement_g_c_per_g_c,
        1e-15,
    );
    // The acetotroph's own source floor is EO2X, and at zero product feedback
    // its ECHZ is far higher than this aerobic constant.
    try std.testing.expect(
        heterotrophic.acetate_respiration_requirement_g_c_per_g_c <
            try energy.acetotrophicGrowthRespirationRequirement(0),
    );
    // The fermenter constant 0.5 equals the DIAZOTROPH floor ENFY, applied to
    // both N=4 and N=7, where the N=4 floor should be EO2X=0.4.
    try std.testing.expectEqual(
        energy.anaerobic_diazotroph_minimum_growth_respiration_requirement_g_c_per_g_c,
        heterotrophic.doc_respiration_requirement_g_c_per_g_c,
    );
    try std.testing.expect(
        heterotrophic.doc_respiration_requirement_g_c_per_g_c <
            try energy.fermenterGrowthRespirationRequirement(0, false),
    );
}

test "omitted anaerobic growth energy record receives exact source controls" {
    // Older files remain readable, but omission cannot enter the altered
    // fixed-requirement science path.
    const without = try parse(source_parameter_text_without_anaerobic_growth_energy);
    try std.testing.expectEqualDeep(
        source_anaerobic_growth_energy_parameters,
        without.anaerobic_growth_energy,
    );
    try std.testing.expect(without.methane != null);

    // Case-insensitive label and any supported delimiter.
    const with = try parse(
        source_parameter_text_without_anaerobic_growth_energy ++
            "\nSOIL_ANAEROBIC_GROWTH_ENERGY|4.0|2.0|38|39|40|0.41|0.51",
    );
    try std.testing.expectEqual(
        @as(f64, 4),
        with.anaerobic_growth_energy.fermentation_energy_yield_kilojoule_per_g_c,
    );
    try std.testing.expectEqual(
        @as(f64, 0.51),
        with.anaerobic_growth_energy.anaerobic_diazotroph_minimum_growth_respiration_requirement_g_c_per_g_c,
    );

    // Short record, and a floor above one, are both rejected.
    try std.testing.expectError(
        error.InvalidSoilNitrogenParameterRecordArity,
        parse(source_parameter_text_without_anaerobic_growth_energy ++
            "\nsoil_anaerobic_growth_energy 3.0 1.5 37.5"),
    );
    try std.testing.expectError(
        error.InvalidSoilNitrogenParameter,
        parse(source_parameter_text_without_anaerobic_growth_energy ++
            "\nsoil_anaerobic_growth_energy 3.0 1.5 37.5 37.5 37.5 1.5 0.5"),
    );
    // A zero growth energy requirement would divide by zero inside ECHZ.
    try std.testing.expectError(
        error.InvalidSoilNitrogenParameter,
        parse(source_parameter_text_without_anaerobic_growth_energy ++
            "\nsoil_anaerobic_growth_energy 3.0 1.5 0 37.5 37.5 0.4 0.5"),
    );
    // A duplicate record is a configuration error, not a last-wins override.
    try std.testing.expectError(
        error.DuplicateSoilNitrogenParameter,
        parse(source_parameter_text ++
            "\nsoil_anaerobic_growth_energy 3.0 1.5 37.5 37.5 37.5 0.4 0.5"),
    );
}

test "NITRO anaerobic energy defaults have isolated runtime owners" {
    const parameters = try sourceAnaerobicEnergyParameters();
    const fermenter = parameters.fermenter;
    try std.testing.expectEqual(@as(usize, 3), fermenter.fermenter_population_index);
    try std.testing.expectEqual(@as(usize, 6), fermenter.anaerobic_diazotroph_population_index);
    try std.testing.expectEqual(@as(f64, 3), fermenter.reference_energy_yield_kj_per_g_c);
    try std.testing.expectEqual(@as(f64, 37.5), fermenter.growth_energy_requirement_kj_per_g_c);
    try std.testing.expectEqual(
        1.0 / (1.0 + 37.5 / 25.0),
        fermenter.minimum_respiration_requirement_g_c_per_g_c,
    );
    try std.testing.expectEqual(
        1.0 / (1.0 + 37.5 / 37.5),
        fermenter.diazotroph_minimum_respiration_requirement_g_c_per_g_c,
    );

    const acetotrophic = parameters.acetotrophic_methanogenesis;
    try std.testing.expectEqual(@as(usize, 4), acetotrophic.population_index);
    try std.testing.expectEqual(@as(f64, 1.5), acetotrophic.reference_energy_yield_kj_per_g_c);
    try std.testing.expectEqual(@as(f64, 37.5), acetotrophic.growth_energy_requirement_kj_per_g_c);
    try std.testing.expectEqual(
        1.0 / (1.0 + 37.5 / 25.0),
        acetotrophic.minimum_growth_respiration_fraction,
    );
    try std.testing.expectEqual(@as(f64, 0.5), acetotrophic.methane_carbon_yield_g_c_per_g_c_oxidized);
}

test "anaerobic energy records are strict flexible and case-insensitive" {
    const parameters = try parseAnaerobicEnergyParameters(
        "Soil_Fermenter_Respiration|8|9|0.2|13|14|4|38|39|0.41|0.51|0.008|2.1|73 # runtime roles\n" ++
            "SOIL_ACETOTROPHIC_METHANOGENESIS,10,15,16,0.3,1.6,40,0.42,0.009,25,0.6",
    );
    try std.testing.expectEqual(@as(usize, 8), parameters.fermenter.fermenter_population_index);
    try std.testing.expectEqual(@as(f64, 4), parameters.fermenter.reference_energy_yield_kj_per_g_c);
    try std.testing.expectEqual(@as(usize, 10), parameters.acetotrophic_methanogenesis.population_index);
    try std.testing.expectEqual(@as(f64, 40), parameters.acetotrophic_methanogenesis.growth_energy_requirement_kj_per_g_c);
    try std.testing.expectError(
        error.InvalidSoilNitrogenParameterRecordArity,
        parseAnaerobicEnergyParameters(
            "soil_fermenter_respiration 3 6 0.125\n" ++
                "soil_acetotrophic_methanogenesis 4 12 12 0.125 1.5 37.5 0.4 0.0083143 24 0.5",
        ),
    );
}

test "soil nitrogen records accept comments and retain case-insensitive labels" {
    const parameters = try parse(
        "# Every parameter record has exact physical-line arity.\n" ++
            source_parameter_text ++
            "\n# End of soil nitrogen parameters.\n",
    );
    try std.testing.expect(parameters.methane != null);
    try std.testing.expectEqual(
        @as(f64, 0.001),
        parameters.microbial_layer_mixing_rate_per_h,
    );
}

test "soil nitrogen preflight rejects short and long physical records" {
    try std.testing.expectError(
        error.InvalidSoilNitrogenParameterRecordArity,
        parse("soil_nitrification 0.001 # remaining values cannot come from another line\n"),
    );
    try std.testing.expectError(
        error.InvalidSoilNitrogenParameterRecordArity,
        parse(source_parameter_text ++ " 99 # extra methane value\n"),
    );
}

test "soil nitrogen records reject explicit empty values" {
    try std.testing.expectError(
        error.EmptySoilNitrogenParameterValue,
        parse("soil_nitrification 0.001,,0.0002 7000 14 1.4 1.4 0.125 0.125 0.3 0.1 0.5 2.667 3.429\n"),
    );
}
