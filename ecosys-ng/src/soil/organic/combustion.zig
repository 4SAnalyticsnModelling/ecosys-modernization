const std = @import("std");
const SoilOrganic = @import("initialization.zig");
const FireExchange = @import("../biogeochemistry/organic_matter_fire_exchange.zig");

pub const Parameters = struct {
    minimum_combustion_temperature_k: f64 = 473.15,
    maximum_arrhenius_response: f64 = 2,
    negligible_carbon_g_c: f64 = 0,
    physical_relative_tolerance: f64 = 0,
    gas_constant_j_per_mol_k: f64 = 8.3143,
    activation_energy_j_per_mol: f64 = 60_000,
    arrhenius_intercept: f64 = 12.028,
    charcoal_activation_energy_j_per_mol: f64 = 120_000,
    charcoal_arrhenius_intercept: f64 = 20.620,
    specific_combustion_by_substrate_g_c_per_m2_h: [SoilOrganic.microbial_substrate_count]f64 = .{ 1_000, 5_000, 1_000, 1_000, 1_000, 1_000 },
    charcoal_specific_combustion_g_c_per_m2_h: f64 = 1,
    oxygen_g_per_g_combusted_carbon: f64 = 2.667,
    maximum_aerobic_charcoal_fraction: f64 = 0,
    maximum_anaerobic_charcoal_fraction: f64 = 0.5,
    oxygen_half_saturation_g_o_per_m3: f64 = 2.8,
    methane_half_saturation_g_c_per_m3: f64 = 0.005,
    aerobic_combustion_energy_megajoules_per_g_c: f64 = 0.0375,
    anaerobic_combustion_energy_megajoules_per_g_c: f64 = 0.0125,
    methane_combustion_energy_megajoules_per_g_c: f64 = 0.0743,

    pub fn validate(self: Parameters) !void {
        inline for (.{
            self.minimum_combustion_temperature_k,
            self.maximum_arrhenius_response,
            self.gas_constant_j_per_mol_k,
            self.activation_energy_j_per_mol,
            self.charcoal_activation_energy_j_per_mol,
            self.charcoal_specific_combustion_g_c_per_m2_h,
            self.oxygen_g_per_g_combusted_carbon,
            self.oxygen_half_saturation_g_o_per_m3,
            self.methane_half_saturation_g_c_per_m3,
            self.aerobic_combustion_energy_megajoules_per_g_c,
            self.anaerobic_combustion_energy_megajoules_per_g_c,
            self.methane_combustion_energy_megajoules_per_g_c,
        }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSoilCombustionParameter;
        inline for (.{ self.arrhenius_intercept, self.charcoal_arrhenius_intercept }) |value| if (!std.math.isFinite(value)) return error.InvalidSoilCombustionParameter;
        if (!std.math.isFinite(self.negligible_carbon_g_c) or self.negligible_carbon_g_c < 0 or !std.math.isFinite(self.physical_relative_tolerance) or self.physical_relative_tolerance < 0) return error.InvalidSoilCombustionParameter;
        inline for (.{ self.maximum_aerobic_charcoal_fraction, self.maximum_anaerobic_charcoal_fraction }) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSoilCombustionParameter;
        for (self.specific_combustion_by_substrate_g_c_per_m2_h) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilCombustionParameter;
    }
};

pub const OrganicPool = struct {
    carbon_g_c: f64,
    associated_carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
};

pub const LayerInputs = struct {
    fire_active: bool,
    soil_temperature_k: f64,
    combustion_temperature_threshold_k: f64,
    maximum_arrhenius_response: f64,
    total_soil_organic_carbon_g_c: f64,
    negligible_carbon_g_c: f64,
    cell_layer_area_m2: f64,
    timestep_h: f64,
};

pub const Result = struct { combustion_fraction: f64, combusted_carbon_g_c: f64, combusted_nitrogen_g_n: f64, combusted_phosphorus_g_p: f64, transfer_temperature_response: f64 };

pub const SourceSignedCombustionLoss = struct {
    carbon_change_g_c: f64,
    nitrogen_change_g_n: f64,
    phosphorus_change_g_p: f64,
};

/// NITRO.F 4344--4346 and 4389--4391 VCOXFS/VNOXFS/VPOXFS state_update.
///
/// Pool removals and the shared fire ledger use positive magnitudes. Legacy
/// output accumulators use the opposite sign, so combustion loss is negative.
/// Returning the complete C/N/P tuple keeps state_update atomic.
pub fn sourceSignedCombustionLoss(
    combusted_carbon_g_c: f64,
    combusted_nitrogen_g_n: f64,
    combusted_phosphorus_g_p: f64,
) !SourceSignedCombustionLoss {
    inline for (.{
        combusted_carbon_g_c,
        combusted_nitrogen_g_n,
        combusted_phosphorus_g_p,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidCombustionLossDiagnostic;
    const result: SourceSignedCombustionLoss = .{
        .carbon_change_g_c = -combusted_carbon_g_c,
        .nitrogen_change_g_n = -combusted_nitrogen_g_n,
        .phosphorus_change_g_p = -combusted_phosphorus_g_p,
    };
    inline for (std.meta.fields(SourceSignedCombustionLoss)) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteCombustionLossDiagnostic;
    return result;
}

pub fn regularCombustionFraction(inputs: LayerInputs, specific_combustion_g_c_per_m2_h: f64) !struct { fraction: f64, transfer_response: f64 } {
    try validateLayer(inputs);
    if (!std.math.isFinite(specific_combustion_g_c_per_m2_h) or specific_combustion_g_c_per_m2_h < 0) return error.InvalidCombustionRate;
    if (!inputs.fire_active) return .{ .fraction = 0, .transfer_response = 0 };
    const response = @min(inputs.maximum_arrhenius_response, @exp(12.028 - 60000 / (8.3143 * inputs.soil_temperature_k)));
    if (inputs.total_soil_organic_carbon_g_c <= inputs.negligible_carbon_g_c)
        return .{ .fraction = 0, .transfer_response = @min(1, response) };
    // NITRO.F 4306--4307: preserve SPCMB * TFNCO / ORGC * AREA * XNFH.
    return .{ .fraction = @min(1, specific_combustion_g_c_per_m2_h * response / inputs.total_soil_organic_carbon_g_c * inputs.cell_layer_area_m2 * inputs.timestep_h), .transfer_response = @min(1, response) };
}

pub fn charcoalCombustionFraction(inputs: LayerInputs, total_charcoal_g_c: f64, specific_charcoal_combustion_g_c_per_h: f64) !f64 {
    try validateLayer(inputs);
    if (!std.math.isFinite(total_charcoal_g_c) or total_charcoal_g_c < 0 or !std.math.isFinite(specific_charcoal_combustion_g_c_per_h) or specific_charcoal_combustion_g_c_per_h < 0) return error.InvalidCharcoalCombustionInput;
    if (!inputs.fire_active or inputs.soil_temperature_k <= inputs.combustion_temperature_threshold_k or total_charcoal_g_c == 0) return 0;
    const response = @min(inputs.maximum_arrhenius_response, @exp(20.620 - 120000 / (8.3143 * inputs.soil_temperature_k)));
    return @min(1, specific_charcoal_combustion_g_c_per_h * response * inputs.timestep_h / total_charcoal_g_c);
}

/// Applies one already-computed combustion fraction to any runtime number of
/// organic pools. `fluxes` is caller-owned scratch/output memory, supporting
/// tiled CPU execution now and device buffers in a future GPU port.
pub fn burnPools(pools: []OrganicPool, fluxes: []OrganicPool, combustion_fraction: f64) !Result {
    if (pools.len != fluxes.len) return error.CombustionFluxLengthMismatch;
    if (!std.math.isFinite(combustion_fraction) or combustion_fraction < 0 or combustion_fraction > 1) return error.InvalidCombustionFraction;
    for (pools) |pool| try validatePool(pool);
    var totals: OrganicPool = .{ .carbon_g_c = 0, .associated_carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    for (pools, fluxes) |pool, *flux| {
        if (pool.carbon_g_c > 0) {
            flux.* = .{ .carbon_g_c = combustion_fraction * pool.carbon_g_c, .associated_carbon_g_c = combustion_fraction * pool.associated_carbon_g_c, .nitrogen_g_n = combustion_fraction * pool.nitrogen_g_n, .phosphorus_g_p = combustion_fraction * pool.phosphorus_g_p };
        } else flux.* = .{ .carbon_g_c = 0, .associated_carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
        totals.carbon_g_c += flux.carbon_g_c;
        totals.associated_carbon_g_c += flux.associated_carbon_g_c;
        totals.nitrogen_g_n += flux.nitrogen_g_n;
        totals.phosphorus_g_p += flux.phosphorus_g_p;
    }
    for (pools, fluxes) |*pool, flux| {
        pool.carbon_g_c -= flux.carbon_g_c;
        pool.associated_carbon_g_c -= flux.associated_carbon_g_c;
        pool.nitrogen_g_n -= flux.nitrogen_g_n;
        pool.phosphorus_g_p -= flux.phosphorus_g_p;
    }
    return .{ .combustion_fraction = combustion_fraction, .combusted_carbon_g_c = totals.carbon_g_c, .combusted_nitrogen_g_n = totals.nitrogen_g_n, .combusted_phosphorus_g_p = totals.phosphorus_g_p, .transfer_temperature_response = 0 };
}

/// NITRO soil organic-matter fire transaction for one compact runtime layer.
/// Every pool is validated before mutation, preventing partial state_update.
pub fn burnOrganicStateLayer(state: *SoilOrganic.State, fire_exchange: *FireExchange.State, layer: usize, fire_active: bool, soil_temperature_k: f64, cell_layer_area_m2: f64, timestep_h: f64, parameters: Parameters) !Result {
    return burnOrganicState(state, fire_exchange, layer, fire_active, soil_temperature_k, cell_layer_area_m2, timestep_h, parameters, false);
}

/// NITRO `L=0` combustion. The source excludes microbial substrates K=3 and
/// K=4 at the litter surface while retaining all other litter pool families.
pub fn burnSurfaceOrganicStateCell(state: *SoilOrganic.State, fire_exchange: *FireExchange.State, cell: usize, fire_active: bool, surface_temperature_k: f64, cell_area_m2: f64, timestep_h: f64, parameters: Parameters) !Result {
    return burnOrganicState(state, fire_exchange, cell, fire_active, surface_temperature_k, cell_area_m2, timestep_h, parameters, true);
}

fn burnOrganicState(state: *SoilOrganic.State, fire_exchange: *FireExchange.State, layer: usize, fire_active: bool, soil_temperature_k: f64, cell_layer_area_m2: f64, timestep_h: f64, parameters: Parameters, surface_litter: bool) !Result {
    try parameters.validate();
    if (layer >= state.layer_count or layer >= fire_exchange.layer_count) return error.SoilCombustionLayerOutOfBounds;
    inline for (.{ soil_temperature_k, cell_layer_area_m2, timestep_h }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidCombustionLayerInput;
    if (!fire_active) return .{ .combustion_fraction = 0, .combusted_carbon_g_c = 0, .combusted_nitrogen_g_n = 0, .combusted_phosphorus_g_p = 0, .transfer_temperature_response = 0 };
    const total_carbon_g_c = try regularCombustionDenominator_g_c(state, layer);
    const carbon_presence_tolerance_g_c = parameters.negligible_carbon_g_c +
        parameters.physical_relative_tolerance * @abs(total_carbon_g_c);
    // NITRO.F 4301--4303 evaluates TFNCO and publishes capped TFNCOS before
    // the ZEROS gate used by every FRCBCO(K).
    const regular_response = @min(parameters.maximum_arrhenius_response, @exp(parameters.arrhenius_intercept - parameters.activation_energy_j_per_mol / (parameters.gas_constant_j_per_mol_k * soil_temperature_k)));
    const transfer_response = @min(1, regular_response);
    if (soil_temperature_k <= parameters.minimum_combustion_temperature_k) {
        const fraction = if (total_carbon_g_c > carbon_presence_tolerance_g_c)
            @min(1, parameters.specific_combustion_by_substrate_g_c_per_m2_h[0] * regular_response / total_carbon_g_c * cell_layer_area_m2 * timestep_h)
        else
            0;
        try fire_exchange.setCombustionTemperatureResponse(layer, transfer_response);
        return .{ .combustion_fraction = fraction, .combusted_carbon_g_c = 0, .combusted_nitrogen_g_n = 0, .combusted_phosphorus_g_p = 0, .transfer_temperature_response = transfer_response };
    }
    try validateOrganicLayer(state, layer);
    var fractions: [SoilOrganic.microbial_substrate_count]f64 = undefined;
    for (&fractions, parameters.specific_combustion_by_substrate_g_c_per_m2_h) |*fraction, rate|
        fraction.* = if (total_carbon_g_c > carbon_presence_tolerance_g_c)
            @min(1, rate * regular_response / total_carbon_g_c * cell_layer_area_m2 * timestep_h)
        else
            0;
    const charcoal_response = @min(parameters.maximum_arrhenius_response, @exp(parameters.charcoal_arrhenius_intercept - parameters.charcoal_activation_energy_j_per_mol / (parameters.gas_constant_j_per_mol_k * soil_temperature_k)));
    var total_charcoal_g_c: f64 = 0;
    for (0..SoilOrganic.substrate_count) |substrate| {
        const index = ((layer * SoilOrganic.substrate_count + substrate) * SoilOrganic.structural_fraction_count) + SoilOrganic.structural_fraction_count - 1;
        total_charcoal_g_c += state.structural[index].carbon_g_c;
    }
    const charcoal_fraction = if (total_charcoal_g_c > carbon_presence_tolerance_g_c) @min(1, parameters.charcoal_specific_combustion_g_c_per_m2_h * charcoal_response * timestep_h / total_charcoal_g_c) else 0;

    var combusted_c_by_substrate: [SoilOrganic.microbial_substrate_count]f64 = @splat(0);
    var combusted_n_by_substrate: [SoilOrganic.microbial_substrate_count]f64 = @splat(0);
    var combusted_p_by_substrate: [SoilOrganic.microbial_substrate_count]f64 = @splat(0);
    // Legacy NITRO 4313-4359 publishes microbial biomass C/N/P only after
    // deriving every flux. Preview all organic families here so a late shared
    // ledger error cannot leave authoritative pools partially combusted.
    for (0..SoilOrganic.microbial_substrate_count) |substrate| {
        if (surface_litter and (substrate == 3 or substrate == 4)) continue;
        const first = (layer * SoilOrganic.microbial_substrate_count + substrate) * SoilOrganic.microbial_population_count * SoilOrganic.kinetic_fraction_count;
        for (state.microbial[first .. first + SoilOrganic.microbial_population_count * SoilOrganic.kinetic_fraction_count]) |pool|
            accumulateElementPoolCombustion(pool, fractions[substrate], carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
    }
    for (0..SoilOrganic.substrate_count) |substrate| {
        const fraction = fractions[substrate];
        const residue_first = (layer * SoilOrganic.substrate_count + substrate) * SoilOrganic.residue_fraction_count;
        for (state.residue[residue_first .. residue_first + SoilOrganic.residue_fraction_count]) |pool|
            accumulateElementPoolCombustion(pool, fraction, carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
        const mobile = layer * SoilOrganic.substrate_count + substrate;
        try validateAssociatedCombustion(state.dissolved[mobile], state.dissolved_acetate_carbon_g_c[mobile], fraction, carbon_presence_tolerance_g_c);
        accumulateElementPoolCombustion(state.dissolved[mobile], fraction, carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
        try validateAssociatedCombustion(state.adsorbed[mobile], state.adsorbed_acetate_carbon_g_c[mobile], fraction, carbon_presence_tolerance_g_c);
        accumulateElementPoolCombustion(state.adsorbed[mobile], fraction, carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
        const structural_first = (layer * SoilOrganic.substrate_count + substrate) * SoilOrganic.structural_fraction_count;
        for (0..SoilOrganic.structural_fraction_count - 1) |structural_fraction| {
            try validateAssociatedCombustion(state.structural[structural_first + structural_fraction], state.colonized_structural_carbon_g_c[structural_first + structural_fraction], fraction, carbon_presence_tolerance_g_c);
            accumulateElementPoolCombustion(state.structural[structural_first + structural_fraction], fraction, carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
        }
        try validateAssociatedCombustion(state.structural[structural_first + SoilOrganic.structural_fraction_count - 1], state.colonized_structural_carbon_g_c[structural_first + SoilOrganic.structural_fraction_count - 1], charcoal_fraction, carbon_presence_tolerance_g_c);
        accumulateElementPoolCombustion(state.structural[structural_first + SoilOrganic.structural_fraction_count - 1], charcoal_fraction, carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
    }
    try fire_exchange.validateOrganicCombustionBySubstrate(layer, &combusted_c_by_substrate, &combusted_n_by_substrate, &combusted_p_by_substrate);
    // All fallible owner validation is complete. Publish TFNCOS only at the
    // same atomic state_update boundary as the organic removals and fire ledger.
    try fire_exchange.setCombustionTemperatureResponse(layer, transfer_response);
    combusted_c_by_substrate = @splat(0);
    combusted_n_by_substrate = @splat(0);
    combusted_p_by_substrate = @splat(0);
    for (0..SoilOrganic.microbial_substrate_count) |substrate| {
        if (surface_litter and (substrate == 3 or substrate == 4)) continue;
        const fraction = fractions[substrate];
        const first = (layer * SoilOrganic.microbial_substrate_count + substrate) * SoilOrganic.microbial_population_count * SoilOrganic.kinetic_fraction_count;
        for (state.microbial[first .. first + SoilOrganic.microbial_population_count * SoilOrganic.kinetic_fraction_count]) |*pool| burnElementPool(pool, fraction, carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
    }
    for (0..SoilOrganic.substrate_count) |substrate| {
        const fraction = fractions[substrate];
        const residue_first = (layer * SoilOrganic.substrate_count + substrate) * SoilOrganic.residue_fraction_count;
        for (state.residue[residue_first .. residue_first + SoilOrganic.residue_fraction_count]) |*pool| burnElementPool(pool, fraction, carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
        const mobile = layer * SoilOrganic.substrate_count + substrate;
        burnElementPoolWithAssociatedCarbon(&state.dissolved[mobile], &state.dissolved_acetate_carbon_g_c[mobile], fraction, carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
        burnElementPoolWithAssociatedCarbon(&state.adsorbed[mobile], &state.adsorbed_acetate_carbon_g_c[mobile], fraction, carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
        const structural_first = (layer * SoilOrganic.substrate_count + substrate) * SoilOrganic.structural_fraction_count;
        for (0..SoilOrganic.structural_fraction_count - 1) |structural_fraction| burnElementPoolWithAssociatedCarbon(&state.structural[structural_first + structural_fraction], &state.colonized_structural_carbon_g_c[structural_first + structural_fraction], fraction, carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
        burnElementPoolWithAssociatedCarbon(&state.structural[structural_first + SoilOrganic.structural_fraction_count - 1], &state.colonized_structural_carbon_g_c[structural_first + SoilOrganic.structural_fraction_count - 1], charcoal_fraction, carbon_presence_tolerance_g_c, &combusted_c_by_substrate[substrate], &combusted_n_by_substrate[substrate], &combusted_p_by_substrate[substrate]);
    }
    const no_salts = [_]f64{0} ** FireExchange.salt_species_count;
    var combusted_c: f64 = 0;
    var combusted_n: f64 = 0;
    var combusted_p: f64 = 0;
    for (0..SoilOrganic.microbial_substrate_count) |substrate| {
        try fire_exchange.addCombustedPoolsForSubstrate(layer, substrate, combusted_c_by_substrate[substrate], combusted_n_by_substrate[substrate], combusted_p_by_substrate[substrate], &no_salts);
        combusted_c += combusted_c_by_substrate[substrate];
        combusted_n += combusted_n_by_substrate[substrate];
        combusted_p += combusted_p_by_substrate[substrate];
    }
    return .{ .combustion_fraction = fractions[0], .combusted_carbon_g_c = combusted_c, .combusted_nitrogen_g_n = combusted_n, .combusted_phosphorus_g_p = combusted_p, .transfer_temperature_response = transfer_response };
}

/// Reconstructs NITRO `ORGC` for FRCBCO without `ORGCC` charcoal.
///
/// Traceability: REDIST.F 6793--6868 defines ORGC and ORGCC separately before
/// NITRO.F 4305--4307 consumes ORGC. Within represented owners, preserve its
/// order: all microbial C, then residue/mobile/structural C by substrate.
fn regularCombustionDenominator_g_c(state: *const SoilOrganic.State, layer: usize) !f64 {
    if (layer >= state.layer_count) return error.SoilCombustionLayerOutOfBounds;
    var total_g_c: f64 = 0;
    const microbial_first = layer * SoilOrganic.microbial_substrate_count *
        SoilOrganic.microbial_population_count * SoilOrganic.kinetic_fraction_count;
    const microbial_end = microbial_first + SoilOrganic.microbial_substrate_count *
        SoilOrganic.microbial_population_count * SoilOrganic.kinetic_fraction_count;
    for (state.microbial[microbial_first..microbial_end]) |pool|
        total_g_c = try addCombustionDenominator(total_g_c, pool.carbon_g_c);
    for (0..SoilOrganic.substrate_count) |substrate| {
        const residue_first = (layer * SoilOrganic.substrate_count + substrate) *
            SoilOrganic.residue_fraction_count;
        for (state.residue[residue_first .. residue_first + SoilOrganic.residue_fraction_count]) |pool|
            total_g_c = try addCombustionDenominator(total_g_c, pool.carbon_g_c);
        const mobile = layer * SoilOrganic.substrate_count + substrate;
        total_g_c = try addCombustionDenominator(total_g_c, state.dissolved[mobile].carbon_g_c);
        total_g_c = try addCombustionDenominator(total_g_c, state.adsorbed[mobile].carbon_g_c);
        total_g_c = try addCombustionDenominator(total_g_c, state.dissolved_acetate_carbon_g_c[mobile]);
        total_g_c = try addCombustionDenominator(total_g_c, state.adsorbed_acetate_carbon_g_c[mobile]);
        const structural_first = (layer * SoilOrganic.substrate_count + substrate) *
            SoilOrganic.structural_fraction_count;
        for (state.structural[structural_first .. structural_first + SoilOrganic.structural_fraction_count - 1]) |pool|
            total_g_c = try addCombustionDenominator(total_g_c, pool.carbon_g_c);
    }
    return total_g_c;
}

fn addCombustionDenominator(total_g_c: f64, carbon_g_c: f64) !f64 {
    if (!std.math.isFinite(carbon_g_c) or carbon_g_c < 0)
        return error.InvalidCombustionPool;
    const next = total_g_c + carbon_g_c;
    if (!std.math.isFinite(next)) return error.NonFiniteCombustionPool;
    return next;
}

fn validateOrganicLayer(state: *const SoilOrganic.State, layer: usize) !void {
    const microbial_first = layer * SoilOrganic.microbial_substrate_count * SoilOrganic.microbial_population_count * SoilOrganic.kinetic_fraction_count;
    for (state.microbial[microbial_first .. microbial_first + SoilOrganic.microbial_substrate_count * SoilOrganic.microbial_population_count * SoilOrganic.kinetic_fraction_count]) |pool| try validateElementPool(pool);
    const residue_first = layer * SoilOrganic.substrate_count * SoilOrganic.residue_fraction_count;
    for (state.residue[residue_first .. residue_first + SoilOrganic.substrate_count * SoilOrganic.residue_fraction_count]) |pool| try validateElementPool(pool);
    const mobile_first = layer * SoilOrganic.substrate_count;
    inline for (.{ state.dissolved[mobile_first .. mobile_first + SoilOrganic.substrate_count], state.adsorbed[mobile_first .. mobile_first + SoilOrganic.substrate_count] }) |pools| for (pools) |pool| try validateElementPool(pool);
    inline for (.{ state.dissolved_acetate_carbon_g_c[mobile_first .. mobile_first + SoilOrganic.substrate_count], state.adsorbed_acetate_carbon_g_c[mobile_first .. mobile_first + SoilOrganic.substrate_count] }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidCombustionPool;
    const structural_first = layer * SoilOrganic.substrate_count * SoilOrganic.structural_fraction_count;
    for (state.structural[structural_first .. structural_first + SoilOrganic.substrate_count * SoilOrganic.structural_fraction_count]) |pool| try validateElementPool(pool);
    for (state.colonized_structural_carbon_g_c[structural_first .. structural_first + SoilOrganic.substrate_count * SoilOrganic.structural_fraction_count]) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidCombustionPool;
}

fn validateElementPool(pool: SoilOrganic.ElementPool) !void {
    inline for (.{ pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidCombustionPool;
    if (pool.carbon_g_c == 0 and (pool.nitrogen_g_n > 0 or pool.phosphorus_g_p > 0)) return error.CombustionPoolMissingPrimaryCarbon;
}

fn burnElementPool(pool: *SoilOrganic.ElementPool, fraction: f64, negligible_carbon_g_c: f64, combusted_c: *f64, combusted_n: *f64, combusted_p: *f64) void {
    if (pool.carbon_g_c <= negligible_carbon_g_c) return;
    const carbon = pool.carbon_g_c * fraction;
    // Preserve NITRO source order: derive the carbon flux first, then obtain
    // associated elements through the pre-update pool ratios.
    const nitrogen = carbon * pool.nitrogen_g_n / pool.carbon_g_c;
    const phosphorus = carbon * pool.phosphorus_g_p / pool.carbon_g_c;
    pool.carbon_g_c -= carbon;
    pool.nitrogen_g_n -= nitrogen;
    pool.phosphorus_g_p -= phosphorus;
    combusted_c.* += carbon;
    combusted_n.* += nitrogen;
    combusted_p.* += phosphorus;
}

fn accumulateElementPoolCombustion(pool: SoilOrganic.ElementPool, fraction: f64, negligible_carbon_g_c: f64, combusted_c: *f64, combusted_n: *f64, combusted_p: *f64) void {
    if (pool.carbon_g_c <= negligible_carbon_g_c) return;
    const carbon = pool.carbon_g_c * fraction;
    combusted_c.* += carbon;
    combusted_n.* += carbon * pool.nitrogen_g_n / pool.carbon_g_c;
    combusted_p.* += carbon * pool.phosphorus_g_p / pool.carbon_g_c;
}

fn validateAssociatedCombustion(pool: SoilOrganic.ElementPool, associated_carbon_g_c: f64, fraction: f64, negligible_carbon_g_c: f64) !void {
    if (pool.carbon_g_c <= negligible_carbon_g_c) return;
    const carbon = pool.carbon_g_c * fraction;
    const combusted_associated_carbon_g_c = carbon * associated_carbon_g_c / pool.carbon_g_c;
    const remaining_associated_carbon_g_c = associated_carbon_g_c - combusted_associated_carbon_g_c;
    if (!std.math.isFinite(combusted_associated_carbon_g_c) or !std.math.isFinite(remaining_associated_carbon_g_c) or remaining_associated_carbon_g_c < 0)
        return error.NonFiniteCombustionPool;
}

fn burnElementPoolWithAssociatedCarbon(pool: *SoilOrganic.ElementPool, associated_carbon_g_c: *f64, fraction: f64, negligible_carbon_g_c: f64, combusted_c: *f64, combusted_n: *f64, combusted_p: *f64) void {
    if (pool.carbon_g_c <= negligible_carbon_g_c) return;
    const carbon = pool.carbon_g_c * fraction;
    // NITRO.F 4420--4434 and 4463--4477: derive associated acetate first,
    // then N and P from the same pre-update primary carbon. StateUpdate in source
    // order C, acetate, N, P before publishing the C/N/P magnitudes.
    const associated = carbon * associated_carbon_g_c.* / pool.carbon_g_c;
    const nitrogen = carbon * pool.nitrogen_g_n / pool.carbon_g_c;
    const phosphorus = carbon * pool.phosphorus_g_p / pool.carbon_g_c;
    pool.carbon_g_c -= carbon;
    associated_carbon_g_c.* -= associated;
    pool.nitrogen_g_n -= nitrogen;
    pool.phosphorus_g_p -= phosphorus;
    combusted_c.* += carbon;
    combusted_n.* += nitrogen;
    combusted_p.* += phosphorus;
}

fn validateLayer(inputs: LayerInputs) !void {
    inline for (@typeInfo(LayerInputs).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0)) return error.InvalidCombustionLayerInput;
    if (inputs.soil_temperature_k <= 0 or inputs.maximum_arrhenius_response <= 0 or inputs.timestep_h <= 0) return error.InvalidCombustionLayerInput;
}

fn validatePool(pool: OrganicPool) !void {
    inline for (@typeInfo(OrganicPool).@"struct".fields) |field| if (!std.math.isFinite(@field(pool, field.name)) or @field(pool, field.name) < 0) return error.InvalidCombustionPool;
    if (pool.carbon_g_c == 0 and (pool.associated_carbon_g_c > 0 or pool.nitrogen_g_n > 0 or pool.phosphorus_g_p > 0)) return error.CombustionPoolMissingPrimaryCarbon;
}

test {
    _ = @import("combustion_test.zig");
}
