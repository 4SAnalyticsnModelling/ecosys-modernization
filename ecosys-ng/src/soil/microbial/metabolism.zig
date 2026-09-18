const std = @import("std");

pub const ElementalPool = struct { carbon_g_c: f64, nitrogen_g_n: f64, phosphorus_g_p: f64 };

pub const EnvironmentalInputs = struct {
    soil_temperature_k: f64,
    thermal_adaptation_offset_k: f64,
    matric_plus_osmotic_potential_megapascal: f64,
    aqueous_oxygen_concentration_g_o_per_m3: f64,
    is_fungus: bool,
    active_biomass_g_c: f64,
    colonized_substrate_g_c: f64,
    decomposition_density_half_saturation: f64,
    maintenance_density_half_saturation: f64,
};

pub const EnvironmentalResult = struct {
    growth_temperature_response: f64,
    maintenance_temperature_response: f64,
    water_potential_response: f64,
    growth_temperature_water_response: f64,
    fermentation_oxygen_inhibition: f64,
    decomposition_density_response: f64,
    maintenance_density_response: f64,
};

pub fn environmentalResponse(inputs: EnvironmentalInputs) !EnvironmentalResult {
    inline for (@typeInfo(EnvironmentalInputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteMicrobialEnvironmentalInput;
    const adapted_temperature_k = inputs.soil_temperature_k + inputs.thermal_adaptation_offset_k;
    if (inputs.soil_temperature_k <= 0 or adapted_temperature_k <= 0 or inputs.active_biomass_g_c < 0 or inputs.colonized_substrate_g_c < 0 or inputs.decomposition_density_half_saturation <= 0 or inputs.maintenance_density_half_saturation <= 0) return error.InvalidMicrobialEnvironmentalInput;
    const rt_kj_per_mol = 8.3143 * adapted_temperature_k;
    const entropy_temperature_j_per_mol = 710 * adapted_temperature_k;
    const growth_inactivation = 1 + @exp((197500 - entropy_temperature_j_per_mol) / rt_kj_per_mol) + @exp((entropy_temperature_j_per_mol - 222500) / rt_kj_per_mol);
    const growth_temperature = @exp(25.229 - 62500 / rt_kj_per_mol) / growth_inactivation;
    const maintenance_inactivation = 1 + @exp((197500 - entropy_temperature_j_per_mol) / rt_kj_per_mol);
    const maintenance_temperature = @min(1e3, @exp(25.216 - 62500 / rt_kj_per_mol) / maintenance_inactivation);
    const water_sensitivity_per_megapascal: f64 = if (inputs.is_fungus) 0.05 else 0.10;
    const water = @exp(water_sensitivity_per_megapascal * inputs.matric_plus_osmotic_potential_megapascal);
    const oxygen_inhibition = try fermentationOxygenInhibition(inputs.aqueous_oxygen_concentration_g_o_per_m3);
    var decomposition_density: f64 = 1;
    var maintenance_density: f64 = 1;
    if (inputs.colonized_substrate_g_c > 0) {
        const concentration = inputs.active_biomass_g_c / inputs.colonized_substrate_g_c;
        decomposition_density = concentration / (concentration + inputs.decomposition_density_half_saturation);
        maintenance_density = concentration / (concentration + inputs.maintenance_density_half_saturation);
    }
    return .{ .growth_temperature_response = growth_temperature, .maintenance_temperature_response = maintenance_temperature, .water_potential_response = water, .growth_temperature_water_response = growth_temperature * water, .fermentation_oxygen_inhibition = oxygen_inhibition, .decomposition_density_response = decomposition_density, .maintenance_density_response = maintenance_density };
}

/// NITRO.F 325: `OXYI=1.0-1.0/(1.0+EXP(1.0*(-COXYS(L,NY,NX)+2.5)))`. Layer-level
/// O2 inhibition of fermentation and the anaerobic N2-fixer branch (source
/// N=4, N=7), on `[0, 1)`. A well-aerated layer (high aqueous O2) drives this
/// toward 0, shutting fermentation down; a waterlogged/anoxic layer drives it
/// toward 1, permitting it. This is the single production definition: callers
/// must not duplicate the formula inline.
pub fn fermentationOxygenInhibition(aqueous_oxygen_concentration_g_o_per_m3: f64) !f64 {
    if (!std.math.isFinite(aqueous_oxygen_concentration_g_o_per_m3)) return error.NonFiniteMicrobialEnvironmentalInput;
    return 1 - 1 / (1 + @exp(-aqueous_oxygen_concentration_g_o_per_m3 + 2.5));
}

pub fn growthTemperatureResponse(soil_temperature_k: f64, thermal_adaptation_offset_k: f64) !f64 {
    if (!std.math.isFinite(soil_temperature_k) or !std.math.isFinite(thermal_adaptation_offset_k)) return error.NonFiniteMicrobialEnvironmentalInput;
    const adapted_temperature_k = soil_temperature_k + thermal_adaptation_offset_k;
    if (soil_temperature_k <= 0 or adapted_temperature_k <= 0) return error.InvalidMicrobialEnvironmentalInput;
    const rt_kj_per_mol = 8.3143 * adapted_temperature_k;
    const entropy_temperature_j_per_mol = 710 * adapted_temperature_k;
    const inactivation = 1 + @exp((197500 - entropy_temperature_j_per_mol) / rt_kj_per_mol) + @exp((entropy_temperature_j_per_mol - 222500) / rt_kj_per_mol);
    const result = @exp(25.229 - 62500 / rt_kj_per_mol) / inactivation;
    if (!std.math.isFinite(result) or result < 0) return error.NonFiniteMicrobialEnvironmentalResult;
    return result;
}

pub const MaintenanceInputs = struct {
    labile_nitrogen_g_n: f64,
    resistant_nitrogen_g_n: f64,
    specific_maintenance_g_c_per_g_n_h: f64,
    temperature_response: f64,
    ph_response: f64,
    low_carbon_response: f64,
    timestep_h: f64,
    oxygen_limited_respiration_g_c: f64,
};

pub const MaintenanceResult = struct { labile_respiration_g_c: f64, resistant_respiration_g_c: f64, total_maintenance_g_c: f64, growth_respiration_g_c: f64, senescence_respiration_deficit_g_c: f64 };

/// HOUR1 AHY/PHKI maintenance multiplier. pH follows the mol L-1 convention;
/// AHY is converted to mol m-3 exactly as in the source.
pub fn maintenancePhResponse(ph: f64, acidity_half_response_mol_per_m3: f64) !f64 {
    if (!std.math.isFinite(ph) or !std.math.isFinite(acidity_half_response_mol_per_m3)) return error.NonFiniteMicrobialPhResponseInput;
    if (acidity_half_response_mol_per_m3 <= 0) return error.InvalidMicrobialPhResponseInput;
    const hydrogen_activity_mol_per_m3 = 1e3 * std.math.pow(f64, 10, -ph);
    const result = 1 + @min(4, hydrogen_activity_mol_per_m3 / acidity_half_response_mol_per_m3);
    if (!std.math.isFinite(result)) return error.NonFiniteMicrobialPhResponse;
    return result;
}

pub fn maintenance(inputs: MaintenanceInputs) !MaintenanceResult {
    try validateNonnegativeStruct(inputs, error.InvalidMicrobialMaintenanceInput);
    if (inputs.timestep_h <= 0) return error.InvalidMicrobialMaintenanceInput;
    const specific = inputs.specific_maintenance_g_c_per_g_n_h * inputs.temperature_response * inputs.ph_response * inputs.timestep_h * inputs.low_carbon_response;
    const labile = inputs.labile_nitrogen_g_n * specific;
    const resistant = inputs.resistant_nitrogen_g_n * specific;
    const total = labile + resistant;
    return .{ .labile_respiration_g_c = labile, .resistant_respiration_g_c = resistant, .total_maintenance_g_c = total, .growth_respiration_g_c = @max(0, inputs.oxygen_limited_respiration_g_c - total), .senescence_respiration_deficit_g_c = @max(0, total - inputs.oxygen_limited_respiration_g_c) };
}

pub const FixationInputs = struct {
    is_diazotroph: bool,
    nonstructural_carbon_g_c: f64,
    nonstructural_nitrogen_g_n: f64,
    maximum_nitrogen_per_carbon_g_n_per_g_c: f64,
    nitrogen_fixation_yield_g_n_per_g_c: f64,
    growth_respiration_g_c: f64,
    aqueous_dinitrogen_concentration_g_n_per_m3: f64,
    dinitrogen_half_saturation_g_n_per_m3: f64,
    nonstructural_to_structural_rate_per_h: f64,
    timestep_h: f64,
    /// Dissolved N2 mass this diazotroph may still draw on within the step,
    /// in the same layer and the same units as `fixed_nitrogen_g_n`. The
    /// source expresses N2 supply only as the Monod ratio on
    /// `CZ2GS = Z2GS/VOLW`, which is an intensive concentration and therefore
    /// cannot bound an extensive draw. Where liquid water is ample the ratio
    /// saturates while the pool is still large, so the two agree; where the
    /// aqueous phase nearly vanishes the ratio still saturates (`VOLW` divides
    /// out) while the pool is empty, and fixation then manufactures nitrogen.
    /// `null` restores the unbounded source behaviour for isolated tests.
    available_dissolved_dinitrogen_g_n: ?f64 = null,
};

pub const FixationResult = struct { fixation_respiration_g_c: f64, fixed_nitrogen_g_n: f64, respiration_required_g_c: f64 };

pub fn nonsymbioticNitrogenFixation(inputs: FixationInputs) !FixationResult {
    inline for (@typeInfo(FixationInputs).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0)) return error.InvalidNitrogenFixationInput;
    if (inputs.available_dissolved_dinitrogen_g_n) |available|
        if (!std.math.isFinite(available) or available < 0) return error.InvalidNitrogenFixationInput;
    if (!inputs.is_diazotroph) return .{ .fixation_respiration_g_c = 0, .fixed_nitrogen_g_n = 0, .respiration_required_g_c = 0 };
    if (inputs.nitrogen_fixation_yield_g_n_per_g_c <= 0 or inputs.dinitrogen_half_saturation_g_n_per_m3 <= 0 or inputs.timestep_h <= 0) return error.InvalidNitrogenFixationInput;
    const respiration_required = @max(0, inputs.nonstructural_carbon_g_c * inputs.maximum_nitrogen_per_carbon_g_n_per_g_c - inputs.nonstructural_nitrogen_g_n) / inputs.nitrogen_fixation_yield_g_n_per_g_c;
    if (inputs.growth_respiration_g_c == 0 or respiration_required == 0) return .{ .fixation_respiration_g_c = 0, .fixed_nitrogen_g_n = 0, .respiration_required_g_c = respiration_required };
    const coupled_respiration = inputs.growth_respiration_g_c * respiration_required / (inputs.growth_respiration_g_c + respiration_required);
    const dinitrogen_limitation = inputs.aqueous_dinitrogen_concentration_g_n_per_m3 / (inputs.aqueous_dinitrogen_concentration_g_n_per_m3 + inputs.dinitrogen_half_saturation_g_n_per_m3);
    const carbon_transfer_limit = inputs.nonstructural_to_structural_rate_per_h * inputs.nonstructural_carbon_g_c * inputs.timestep_h;
    var respiration = @min(coupled_respiration * dinitrogen_limitation, carbon_transfer_limit);
    // Substrate mass bound. N2 fixation is a reduction of dissolved N2, so it
    // cannot exceed the dissolved N2 actually present. This is a conservation
    // bound, not a tolerance: it is inactive whenever the aqueous pool can
    // supply the demand, which is every unfrozen layer.
    if (inputs.available_dissolved_dinitrogen_g_n) |available| {
        const respiration_supply_limit = available / inputs.nitrogen_fixation_yield_g_n_per_g_c;
        respiration = @min(respiration, respiration_supply_limit);
    }
    return .{ .fixation_respiration_g_c = respiration, .fixed_nitrogen_g_n = respiration * inputs.nitrogen_fixation_yield_g_n_per_g_c, .respiration_required_g_c = respiration_required };
}

pub const SubstrateUptakeInputs = struct {
    is_heterotroph: bool,
    maintenance_respiration_g_c: f64,
    aerobic_respiration_g_c: f64,
    growth_respiration_g_c: f64,
    fixation_respiration_g_c: f64,
    aerobic_growth_respiration_fraction_g_c_per_g_c: f64,
    denitrification_respiration_g_c: f64,
    denitrification_growth_respiration_fraction_g_c_per_g_c: f64,
    doc_fraction_of_aerobic_carbon: f64,
    acetate_fraction_of_aerobic_carbon: f64,
    dissolved_organic_nitrogen_g_n: f64,
    dissolved_organic_phosphorus_g_p: f64,
    population_biomass_fraction: f64,
    dissolved_nitrogen_per_doc_g_n_per_g_c: f64,
    dissolved_phosphorus_per_doc_g_p_per_g_c: f64,
    nitrogen_limitation_fraction: f64,
    phosphorus_limitation_fraction: f64,
};

pub const SubstrateUptakeResult = struct { total_carbon_g_c: f64, doc_g_c: f64, acetate_g_c: f64, dissolved_organic_nitrogen_g_n: f64, dissolved_organic_phosphorus_g_p: f64 };

pub fn respirationDrivenSubstrateUptake(inputs: SubstrateUptakeInputs) !SubstrateUptakeResult {
    try validateNonnegativeStruct(inputs, error.InvalidMicrobialSubstrateUptakeInput);
    if (inputs.aerobic_growth_respiration_fraction_g_c_per_g_c <= 0 or inputs.denitrification_growth_respiration_fraction_g_c_per_g_c <= 0 or inputs.nitrogen_limitation_fraction <= 0 or inputs.phosphorus_limitation_fraction <= 0 or inputs.fixation_respiration_g_c > inputs.growth_respiration_g_c) return error.InvalidMicrobialSubstrateUptakeInput;
    const aerobic_carbon = @min(inputs.maintenance_respiration_g_c, inputs.aerobic_respiration_g_c) + inputs.fixation_respiration_g_c + (inputs.growth_respiration_g_c - inputs.fixation_respiration_g_c) / inputs.aerobic_growth_respiration_fraction_g_c_per_g_c;
    const denitrification_carbon = inputs.denitrification_respiration_g_c / inputs.denitrification_growth_respiration_fraction_g_c_per_g_c;
    const total = aerobic_carbon + denitrification_carbon;
    if (!inputs.is_heterotroph) return .{ .total_carbon_g_c = total, .doc_g_c = total, .acetate_g_c = 0, .dissolved_organic_nitrogen_g_n = 0, .dissolved_organic_phosphorus_g_p = 0 };
    const doc = aerobic_carbon * inputs.doc_fraction_of_aerobic_carbon + denitrification_carbon;
    const acetate = aerobic_carbon * inputs.acetate_fraction_of_aerobic_carbon;
    const organic_carbon = doc + acetate;
    return .{
        .total_carbon_g_c = total,
        .doc_g_c = doc,
        .acetate_g_c = acetate,
        .dissolved_organic_nitrogen_g_n = @max(0, @min(inputs.dissolved_organic_nitrogen_g_n * inputs.population_biomass_fraction, organic_carbon * inputs.dissolved_nitrogen_per_doc_g_n_per_g_c / inputs.nitrogen_limitation_fraction)),
        .dissolved_organic_phosphorus_g_p = @max(0, @min(inputs.dissolved_organic_phosphorus_g_p * inputs.population_biomass_fraction, organic_carbon * inputs.dissolved_phosphorus_per_doc_g_p_per_g_c / inputs.phosphorus_limitation_fraction)),
    };
}

pub const RecyclingParameters = struct { minimum_carbon_fraction: f64, carbon_range_fraction: f64, maximum_nitrogen_fraction: f64, maximum_phosphorus_fraction: f64 };
pub const RecyclingFractions = struct { carbon: f64, nitrogen: f64, phosphorus: f64 };

pub const AssimilationInputs = struct {
    nonstructural: ElementalPool,
    temperature_water_response: f64,
    nonstructural_to_structural_rate_per_h: f64,
    timestep_h: f64,
    structural_partition: [2]f64,
    maximum_nitrogen_per_carbon: [2]f64,
    maximum_phosphorus_per_carbon: [2]f64,
};

pub const AssimilationResult = struct { structural: [2]ElementalPool };

/// The two entries are biochemical labile and resistant components, not a
/// population-size limit; populations remain a caller-owned runtime dimension.
pub fn assimilateNonstructural(inputs: AssimilationInputs) !AssimilationResult {
    try validatePool(inputs.nonstructural);
    inline for (.{ inputs.temperature_water_response, inputs.nonstructural_to_structural_rate_per_h, inputs.timestep_h }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidMicrobialAssimilationInput;
    inline for (inputs.structural_partition) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidMicrobialAssimilationPartition;
    inline for (inputs.maximum_nitrogen_per_carbon) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidMicrobialAssimilationRatio;
    inline for (inputs.maximum_phosphorus_per_carbon) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidMicrobialAssimilationRatio;
    if (inputs.timestep_h <= 0 or @abs(inputs.structural_partition[0] + inputs.structural_partition[1] - 1) > 1e-12) return error.InvalidMicrobialAssimilationInput;
    const total_carbon = inputs.temperature_water_response * inputs.nonstructural_to_structural_rate_per_h * inputs.nonstructural.carbon_g_c * inputs.timestep_h;
    if (total_carbon > inputs.nonstructural.carbon_g_c) return error.MicrobialAssimilationExceedsNonstructuralCarbon;
    var result: AssimilationResult = .{ .structural = undefined };
    for (0..2) |index| {
        const carbon = inputs.structural_partition[index] * total_carbon;
        if (inputs.nonstructural.carbon_g_c > 0) {
            result.structural[index] = .{
                .carbon_g_c = carbon,
                .nitrogen_g_n = @min(inputs.structural_partition[index] * inputs.nonstructural.nitrogen_g_n, carbon * @min(inputs.maximum_nitrogen_per_carbon[index], inputs.nonstructural.nitrogen_g_n / inputs.nonstructural.carbon_g_c)),
                .phosphorus_g_p = @min(inputs.structural_partition[index] * inputs.nonstructural.phosphorus_g_p, carbon * @min(inputs.maximum_phosphorus_per_carbon[index], inputs.nonstructural.phosphorus_g_p / inputs.nonstructural.carbon_g_c)),
            };
        } else result.structural[index] = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    }
    return result;
}

pub const AssimilationState = struct { nonstructural: ElementalPool, structural: [2]ElementalPool };

pub fn state_updateAssimilation(state: *AssimilationState, result: AssimilationResult) !void {
    try validatePool(state.nonstructural);
    for (state.structural) |pool| try validatePool(pool);
    var total: ElementalPool = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    for (result.structural) |pool| {
        try validatePool(pool);
        total.carbon_g_c += pool.carbon_g_c;
        total.nitrogen_g_n += pool.nitrogen_g_n;
        total.phosphorus_g_p += pool.phosphorus_g_p;
    }
    if (total.carbon_g_c > state.nonstructural.carbon_g_c or total.nitrogen_g_n > state.nonstructural.nitrogen_g_n or total.phosphorus_g_p > state.nonstructural.phosphorus_g_p) return error.InsufficientNonstructuralMicrobialPool;
    state.nonstructural = subtract(state.nonstructural, total);
    for (0..2) |index| {
        state.structural[index].carbon_g_c += result.structural[index].carbon_g_c;
        state.structural[index].nitrogen_g_n += result.structural[index].nitrogen_g_n;
        state.structural[index].phosphorus_g_p += result.structural[index].phosphorus_g_p;
    }
}

pub fn recyclingFractions(nonstructural: ElementalPool, labile_nitrogen_per_carbon: f64, labile_phosphorus_per_carbon: f64, parameters: RecyclingParameters) !RecyclingFractions {
    try validatePool(nonstructural);
    try validateNonnegativeStruct(parameters, error.InvalidMicrobialRecyclingParameter);
    if (labile_nitrogen_per_carbon <= 0 or labile_phosphorus_per_carbon <= 0 or !std.math.isFinite(labile_nitrogen_per_carbon) or !std.math.isFinite(labile_phosphorus_per_carbon)) return error.InvalidMicrobialRecyclingRatio;
    var carbon_balance: f64 = 1;
    var nitrogen_balance: f64 = 0;
    var phosphorus_balance: f64 = 0;
    if (nonstructural.carbon_g_c > 0) {
        carbon_balance = std.math.clamp(@min(nonstructural.nitrogen_g_n / (nonstructural.nitrogen_g_n + nonstructural.carbon_g_c * labile_nitrogen_per_carbon), nonstructural.phosphorus_g_p / (nonstructural.phosphorus_g_p + nonstructural.carbon_g_c * labile_phosphorus_per_carbon)), 0, 1);
        nitrogen_balance = std.math.clamp(nonstructural.carbon_g_c / (nonstructural.carbon_g_c + nonstructural.nitrogen_g_n / labile_nitrogen_per_carbon), 0, 1);
        phosphorus_balance = std.math.clamp(nonstructural.carbon_g_c / (nonstructural.carbon_g_c + nonstructural.phosphorus_g_p / labile_phosphorus_per_carbon), 0, 1);
    }
    return .{ .carbon = parameters.minimum_carbon_fraction + carbon_balance * parameters.carbon_range_fraction, .nitrogen = nitrogen_balance * parameters.maximum_nitrogen_fraction, .phosphorus = phosphorus_balance * parameters.maximum_phosphorus_fraction };
}

pub const DecompositionInputs = struct {
    pool: ElementalPool,
    temperature_response: f64,
    water_response: f64,
    basal_decomposition_rate_per_h: f64,
    microbial_carbon_response: f64,
    timestep_h: f64,
    recycling: RecyclingFractions,
    humification_fraction: f64,
    humus_nitrogen_per_carbon_g_n_per_g_c: f64,
    humus_phosphorus_per_carbon_g_p_per_g_c: f64,
};

pub const DecompositionResult = struct { decomposed: ElementalPool, recycled: ElementalPool, humified: ElementalPool, microbial_residue: ElementalPool };

pub const SenescenceInputs = struct {
    structural: [2]ElementalPool,
    component_maintenance_respiration_g_c: [2]f64,
    total_maintenance_respiration_g_c: f64,
    senescence_respiration_deficit_g_c: f64,
    recycling: RecyclingFractions,
    active_nitrogen_per_carbon_g_n_per_g_c: f64,
    active_phosphorus_per_carbon_g_p_per_g_c: f64,
    humification_fraction: f64,
    humus_nitrogen_per_carbon_g_n_per_g_c: f64,
    humus_phosphorus_per_carbon_g_p_per_g_c: f64,
    negligible_g_c: f64,
};

pub const SenescenceResult = struct { component: [2]DecompositionResult };

pub fn acceleratedSenescence(inputs: SenescenceInputs) !SenescenceResult {
    for (inputs.structural) |pool| try validatePool(pool);
    inline for (@typeInfo(SenescenceInputs).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0)) return error.InvalidMicrobialSenescenceInput;
    inline for (inputs.component_maintenance_respiration_g_c) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidMicrobialSenescenceInput;
    inline for (@typeInfo(RecyclingFractions).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs.recycling, field.name)) or @field(inputs.recycling, field.name) < 0 or @field(inputs.recycling, field.name) > 1) return error.InvalidMicrobialRecyclingFraction;
    if (inputs.humification_fraction > 1) return error.InvalidMicrobialSenescenceInput;
    var result: SenescenceResult = .{ .component = undefined };
    const enabled = inputs.senescence_respiration_deficit_g_c > inputs.negligible_g_c and inputs.total_maintenance_respiration_g_c > inputs.negligible_g_c and inputs.recycling.carbon > 0;
    const deficit_fraction = if (enabled) inputs.senescence_respiration_deficit_g_c / inputs.total_maintenance_respiration_g_c else 0;
    for (0..2) |index| {
        const decomposed_carbon = if (enabled) @min(inputs.structural[index].carbon_g_c, @max(0, deficit_fraction * inputs.component_maintenance_respiration_g_c[index] / inputs.recycling.carbon)) else 0;
        const decomposed: ElementalPool = .{ .carbon_g_c = decomposed_carbon, .nitrogen_g_n = @min(inputs.structural[index].nitrogen_g_n, @max(0, decomposed_carbon * inputs.active_nitrogen_per_carbon_g_n_per_g_c)), .phosphorus_g_p = @min(inputs.structural[index].phosphorus_g_p, @max(0, decomposed_carbon * inputs.active_phosphorus_per_carbon_g_p_per_g_c)) };
        const recycled: ElementalPool = .{ .carbon_g_c = decomposed.carbon_g_c * inputs.recycling.carbon, .nitrogen_g_n = decomposed.nitrogen_g_n * (inputs.recycling.nitrogen + (1 - inputs.recycling.nitrogen) * inputs.recycling.carbon), .phosphorus_g_p = decomposed.phosphorus_g_p * (inputs.recycling.phosphorus + (1 - inputs.recycling.phosphorus) * inputs.recycling.carbon) };
        const litterfall = subtract(decomposed, recycled);
        const humified_carbon = @max(0, litterfall.carbon_g_c * inputs.humification_fraction);
        const humified: ElementalPool = .{ .carbon_g_c = humified_carbon, .nitrogen_g_n = @max(0, @min(litterfall.nitrogen_g_n * inputs.humification_fraction, litterfall.carbon_g_c * inputs.humus_nitrogen_per_carbon_g_n_per_g_c)), .phosphorus_g_p = @max(0, @min(litterfall.phosphorus_g_p * inputs.humification_fraction, litterfall.carbon_g_c * inputs.humus_phosphorus_per_carbon_g_p_per_g_c)) };
        result.component[index] = .{ .decomposed = decomposed, .recycled = recycled, .humified = humified, .microbial_residue = subtract(litterfall, humified) };
    }
    return result;
}

pub fn decompose(inputs: DecompositionInputs) !DecompositionResult {
    try validatePool(inputs.pool);
    inline for (@typeInfo(DecompositionInputs).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0)) return error.InvalidMicrobialDecompositionInput;
    inline for (@typeInfo(RecyclingFractions).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs.recycling, field.name)) or @field(inputs.recycling, field.name) < 0 or @field(inputs.recycling, field.name) > 1) return error.InvalidMicrobialRecyclingFraction;
    if (inputs.timestep_h <= 0 or inputs.humification_fraction > 1) return error.InvalidMicrobialDecompositionInput;
    const rate = @sqrt(inputs.temperature_response) * inputs.water_response * inputs.basal_decomposition_rate_per_h * inputs.microbial_carbon_response * inputs.timestep_h;
    if (rate > 1) return error.MicrobialDecompositionExceedsPool;
    const decomposed = scale(inputs.pool, rate);
    const recycled: ElementalPool = .{
        .carbon_g_c = decomposed.carbon_g_c * inputs.recycling.carbon,
        .nitrogen_g_n = decomposed.nitrogen_g_n * (inputs.recycling.nitrogen + (1 - inputs.recycling.nitrogen) * inputs.recycling.carbon),
        .phosphorus_g_p = decomposed.phosphorus_g_p * (inputs.recycling.phosphorus + (1 - inputs.recycling.phosphorus) * inputs.recycling.carbon),
    };
    const litterfall = subtract(decomposed, recycled);
    const humified_carbon = @max(0, litterfall.carbon_g_c * inputs.humification_fraction);
    const humified: ElementalPool = .{ .carbon_g_c = humified_carbon, .nitrogen_g_n = @max(0, @min(litterfall.nitrogen_g_n * inputs.humification_fraction, humified_carbon * inputs.humus_nitrogen_per_carbon_g_n_per_g_c)), .phosphorus_g_p = @max(0, @min(litterfall.phosphorus_g_p * inputs.humification_fraction, humified_carbon * inputs.humus_phosphorus_per_carbon_g_p_per_g_c)) };
    return .{ .decomposed = decomposed, .recycled = recycled, .humified = humified, .microbial_residue = subtract(litterfall, humified) };
}

fn scale(pool: ElementalPool, factor: f64) ElementalPool {
    return .{ .carbon_g_c = pool.carbon_g_c * factor, .nitrogen_g_n = pool.nitrogen_g_n * factor, .phosphorus_g_p = pool.phosphorus_g_p * factor };
}

fn subtract(a: ElementalPool, b: ElementalPool) ElementalPool {
    return .{ .carbon_g_c = a.carbon_g_c - b.carbon_g_c, .nitrogen_g_n = a.nitrogen_g_n - b.nitrogen_g_n, .phosphorus_g_p = a.phosphorus_g_p - b.phosphorus_g_p };
}

fn validatePool(pool: ElementalPool) !void {
    try validateNonnegativeStruct(pool, error.InvalidMicrobialElementalPool);
}

fn validateNonnegativeStruct(value: anytype, comptime failure: anyerror) !void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(value, field.name)) or @field(value, field.name) < 0)) return failure;
}

test "maintenance separates growth and senescence deficit" {
    const result = try maintenance(.{ .labile_nitrogen_g_n = 1, .resistant_nitrogen_g_n = 1, .specific_maintenance_g_c_per_g_n_h = 0.1, .temperature_response = 1, .ph_response = 1, .low_carbon_response = 1, .timestep_h = 1, .oxygen_limited_respiration_g_c = 0.15 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), result.senescence_respiration_deficit_g_c, 1e-15);
    try std.testing.expectEqual(@as(f64, 0), result.growth_respiration_g_c);
}

test "maintenance pH response reproduces HOUR1 FPH" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.001), try maintenancePhResponse(6, 1), 1e-15);
    try std.testing.expectEqual(@as(f64, 5), try maintenancePhResponse(0, 1));
}

test "thermally adapted microbial environment remains finite and bounded" {
    const result = try environmentalResponse(.{ .soil_temperature_k = 293.15, .thermal_adaptation_offset_k = 2, .matric_plus_osmotic_potential_megapascal = -1, .aqueous_oxygen_concentration_g_o_per_m3 = 2, .is_fungus = true, .active_biomass_g_c = 1, .colonized_substrate_g_c = 10, .decomposition_density_half_saturation = 0.1, .maintenance_density_half_saturation = 0.2 });
    try std.testing.expect(std.math.isFinite(result.growth_temperature_response));
    try std.testing.expect(result.water_potential_response > 0 and result.water_potential_response <= 1);
    try std.testing.expect(result.fermentation_oxygen_inhibition >= 0 and result.fermentation_oxygen_inhibition <= 1);
    try std.testing.expect(result.decomposition_density_response >= 0 and result.decomposition_density_response <= 1);
}

test "nonsymbiotic fixation obeys respiration carbon and N2 limits" {
    const result = try nonsymbioticNitrogenFixation(.{ .is_diazotroph = true, .nonstructural_carbon_g_c = 2, .nonstructural_nitrogen_g_n = 0, .maximum_nitrogen_per_carbon_g_n_per_g_c = 0.1, .nitrogen_fixation_yield_g_n_per_g_c = 0.05, .growth_respiration_g_c = 1, .aqueous_dinitrogen_concentration_g_n_per_m3 = 1, .dinitrogen_half_saturation_g_n_per_m3 = 1, .nonstructural_to_structural_rate_per_h = 1, .timestep_h = 1 });
    try std.testing.expect(result.fixed_nitrogen_g_n > 0);
    try std.testing.expect(result.fixation_respiration_g_c <= 1);
}

test "respiration drives bounded dissolved organic nutrient uptake" {
    const result = try respirationDrivenSubstrateUptake(.{ .is_heterotroph = true, .maintenance_respiration_g_c = 0.2, .aerobic_respiration_g_c = 0.5, .growth_respiration_g_c = 0.3, .fixation_respiration_g_c = 0.05, .aerobic_growth_respiration_fraction_g_c_per_g_c = 0.5, .denitrification_respiration_g_c = 0.1, .denitrification_growth_respiration_fraction_g_c_per_g_c = 0.5, .doc_fraction_of_aerobic_carbon = 0.75, .acetate_fraction_of_aerobic_carbon = 0.25, .dissolved_organic_nitrogen_g_n = 1, .dissolved_organic_phosphorus_g_p = 1, .population_biomass_fraction = 0.2, .dissolved_nitrogen_per_doc_g_n_per_g_c = 0.1, .dissolved_phosphorus_per_doc_g_p_per_g_c = 0.01, .nitrogen_limitation_fraction = 0.5, .phosphorus_limitation_fraction = 0.5 });
    try std.testing.expectApproxEqAbs(result.total_carbon_g_c, result.doc_g_c + result.acetate_g_c, 1e-14);
    try std.testing.expect(result.dissolved_organic_nitrogen_g_n <= 0.2);
    try std.testing.expect(result.dissolved_organic_phosphorus_g_p <= 0.2);
}

test "microbial assimilation conserves nonstructural and structural elements" {
    var state: AssimilationState = .{ .nonstructural = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 }, .structural = .{ .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.04 }, .{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.06 } } };
    const before = .{ state.nonstructural.carbon_g_c + state.structural[0].carbon_g_c + state.structural[1].carbon_g_c, state.nonstructural.nitrogen_g_n + state.structural[0].nitrogen_g_n + state.structural[1].nitrogen_g_n, state.nonstructural.phosphorus_g_p + state.structural[0].phosphorus_g_p + state.structural[1].phosphorus_g_p };
    const result = try assimilateNonstructural(.{ .nonstructural = state.nonstructural, .temperature_water_response = 1, .nonstructural_to_structural_rate_per_h = 0.1, .timestep_h = 1, .structural_partition = .{ 0.7, 0.3 }, .maximum_nitrogen_per_carbon = .{ 0.2, 0.1 }, .maximum_phosphorus_per_carbon = .{ 0.03, 0.02 } });
    try state_updateAssimilation(&state, result);
    const after = .{ state.nonstructural.carbon_g_c + state.structural[0].carbon_g_c + state.structural[1].carbon_g_c, state.nonstructural.nitrogen_g_n + state.structural[0].nitrogen_g_n + state.structural[1].nitrogen_g_n, state.nonstructural.phosphorus_g_p + state.structural[0].phosphorus_g_p + state.structural[1].phosphorus_g_p };
    inline for (before, after) |expected, actual| try std.testing.expectApproxEqAbs(expected, actual, 1e-14);
}

test "decomposition partitions every element conservatively" {
    const result = try decompose(.{ .pool = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 }, .temperature_response = 1, .water_response = 1, .basal_decomposition_rate_per_h = 0.1, .microbial_carbon_response = 1, .timestep_h = 1, .recycling = .{ .carbon = 0.3, .nitrogen = 0.4, .phosphorus = 0.5 }, .humification_fraction = 0.2, .humus_nitrogen_per_carbon_g_n_per_g_c = 0.1, .humus_phosphorus_per_carbon_g_p_per_g_c = 0.02 });
    inline for (@typeInfo(ElementalPool).@"struct".fields) |field| try std.testing.expectApproxEqAbs(@field(result.decomposed, field.name), @field(result.recycled, field.name) + @field(result.humified, field.name) + @field(result.microbial_residue, field.name), 1e-14);
}

test "maintenance-deficit senescence conserves every structural element" {
    const result = try acceleratedSenescence(.{ .structural = .{ .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 }, .{ .carbon_g_c = 5, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.1 } }, .component_maintenance_respiration_g_c = .{ 0.6, 0.4 }, .total_maintenance_respiration_g_c = 1, .senescence_respiration_deficit_g_c = 0.2, .recycling = .{ .carbon = 0.4, .nitrogen = 0.5, .phosphorus = 0.6 }, .active_nitrogen_per_carbon_g_n_per_g_c = 0.1, .active_phosphorus_per_carbon_g_p_per_g_c = 0.02, .humification_fraction = 0.2, .humus_nitrogen_per_carbon_g_n_per_g_c = 0.1, .humus_phosphorus_per_carbon_g_p_per_g_c = 0.02, .negligible_g_c = 1e-12 });
    for (result.component) |component| inline for (@typeInfo(ElementalPool).@"struct".fields) |field| try std.testing.expectApproxEqAbs(@field(component.decomposed, field.name), @field(component.recycled, field.name) + @field(component.humified, field.name) + @field(component.microbial_residue, field.name), 1e-14);
}
