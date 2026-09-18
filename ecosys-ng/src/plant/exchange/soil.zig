const std = @import("std");

/// Runtime layout for the opening aggregation block in extract.f. Species is
/// always the outer dimension; biochemical fractions, material phases, and
/// canopy/root layers are selected by the run rather than PARAMETERS.H.
pub const Layout = struct {
    species_count: usize,
    biochemical_fraction_count: usize,
    material_phase_count: usize,
    exchange_layer_count: usize,

    pub fn litterValueCount(self: Layout) !usize {
        if (self.species_count == 0 or self.biochemical_fraction_count == 0 or self.material_phase_count == 0 or self.exchange_layer_count == 0) return error.EmptyPlantSoilExchangeLayout;
        return std.math.mul(usize, self.species_count, try std.math.mul(usize, self.biochemical_fraction_count, try std.math.mul(usize, self.material_phase_count, self.exchange_layer_count)));
    }
};

pub const Inputs = struct {
    litter_carbon_g: []const f64,
    litter_nitrogen_g: []const f64,
    litter_phosphorus_g: []const f64,
    canopy_litter_carbon_g: []const f64,
    canopy_litter_nitrogen_g: []const f64,
    canopy_litter_phosphorus_g: []const f64,
    standing_dead_carbon_g: []const f64,
    /// Species-major, then exchange layer, then the eight named salt species.
    litter_salt_mol: []const f64,
    /// Species-major, then manure biochemical fraction.
    manure_carbon_g_per_h: []const f64,
    manure_nitrogen_g_per_h: []const f64,
    manure_phosphorus_g_per_h: []const f64,
    manure_inorganic_nitrogen_g_per_h: []const f64,
    manure_inorganic_phosphorus_g_per_h: []const f64,
};

pub const Totals = struct {
    litter_carbon_g: []f64,
    litter_nitrogen_g: []f64,
    litter_phosphorus_g: []f64,
    canopy_litter_carbon_g: f64,
    canopy_litter_nitrogen_g: f64,
    canopy_litter_phosphorus_g: f64,
    standing_dead_carbon_g: f64,
    /// Exchange-layer-major: Al, Fe, Ca, Mg, Na, K, SO4, Cl.
    litter_salt_mol: []f64,
    manure_carbon_g_per_h: []f64,
    manure_nitrogen_g_per_h: []f64,
    manure_phosphorus_g_per_h: []f64,
    manure_inorganic_nitrogen_g_per_h: f64,
    manure_inorganic_phosphorus_g_per_h: f64,
};

pub const CanopyFireParameters = struct {
    gas_constant_j_per_mol_k: f64 = 8.3143,
    combustion_activation_energy_j_per_mol: f64 = 60_000,
    combustion_temperature_intercept: f64 = 12.028,
    oxygen_g_per_g_carbon: f64 = 2.667,
    maximum_aerobic_charcoal_fraction: f64 = 0,
    maximum_anaerobic_charcoal_fraction: f64 = 0.5,
    oxygen_half_saturation_umol_per_mol: f64,
    methane_half_saturation_umol_per_mol: f64,
    aerobic_combustion_energy_megajoules_per_g_carbon: f64,
    anaerobic_combustion_energy_megajoules_per_g_carbon: f64,
    methane_combustion_energy_megajoules_per_g_carbon: f64,
};

pub const CanopyFireResult = struct {
    oxygen_consumed_g: f64,
    /// Source `ROGOX2` (`trnsfr.f` 1111, 1292): the aerobic, oxygen-limited
    /// combustion uptake alone, before the methane-oxidation demand is added.
    /// `redist.f` 4499 and 4837 need this term separately from
    /// `methane_combustion_g_carbon`, and neither is recoverable from
    /// `oxygen_consumed_g` once they are summed.
    oxygen_limited_uptake_g: f64,
    /// Source `RC4OX2` (`trnsfr.f` 1114--1116, 1295--1297): methane oxidised by
    /// the residual oxygen, in g C. Its oxygen demand is
    /// `methane_combustion_g_carbon * oxygen_g_per_g_carbon`.
    methane_combustion_g_carbon: f64,
    carbon_dioxide_emitted_g_carbon: f64,
    methane_emitted_g_carbon: f64,
    charcoal_produced_g_carbon: f64,
    charcoal_fraction_of_combusted_carbon: f64,
    heat_released_megajoules: f64,
    aerobic_fraction_of_noncharcoal: f64,
    anaerobic_fraction_of_noncharcoal: f64,
    combustion_temperature_response: f64,
};

pub const SubsurfaceFireParameters = struct {
    oxygen_g_per_g_carbon: f64 = 2.667,
    maximum_aerobic_charcoal_fraction: f64 = 0,
    maximum_anaerobic_charcoal_fraction: f64 = 0.5,
    oxygen_half_saturation_g_o_per_m3: f64,
    methane_half_saturation_g_c_per_m3: f64,
    aerobic_combustion_energy_megajoules_per_g_carbon: f64,
    anaerobic_combustion_energy_megajoules_per_g_carbon: f64,
    methane_combustion_energy_megajoules_per_g_carbon: f64,
};

pub const CombustedPoolResult = struct {
    carbon_dioxide_g_carbon: f64 = 0,
    methane_g_carbon: f64 = 0,
    charcoal_g_carbon: f64 = 0,
    gaseous_nitrogen_g: f64 = 0,
    gaseous_phosphorus_g: f64 = 0,
    ammonium_nitrogen_g: f64 = 0,
    phosphate_phosphorus_g: f64 = 0,
    released_salt_mol: [8]f64 = @splat(0),
};

pub const PlantCombustionFractions = struct {
    charcoal: f64,
    aerobic_noncharcoal: f64,
    anaerobic_noncharcoal: f64,
};

pub const root_gas_count = 6;
pub const RootGas = enum(usize) { carbon_dioxide, oxygen, methane, nitrous_oxide, ammonia, hydrogen };

pub const CanopyAmmoniaExchangeParameters = struct {
    minimum_canopy_dry_matter_fraction: f64,
    water_potential_dry_matter_increment: f64,
    water_potential_denominator_per_megapascal: f64,
    water_potential_denominator_offset: f64,
    canopy_air_volume_ratio_m3_per_g_c: f64,
    maximum_mobile_nitrogen_transfer_fraction_per_step: f64,
    solubility_log_intercept: f64,
    solubility_temperature_coefficient_per_c: f64,

    pub fn validate(self: CanopyAmmoniaExchangeParameters) !void {
        inline for (@typeInfo(CanopyAmmoniaExchangeParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.NonFiniteCanopyAmmoniaExchangeParameter;
        if (self.minimum_canopy_dry_matter_fraction <= 0 or self.water_potential_dry_matter_increment < 0 or self.water_potential_denominator_per_megapascal < 0 or self.water_potential_denominator_offset <= 0 or self.canopy_air_volume_ratio_m3_per_g_c < 0 or self.maximum_mobile_nitrogen_transfer_fraction_per_step < 0 or self.maximum_mobile_nitrogen_transfer_fraction_per_step > 1 or self.solubility_temperature_coefficient_per_c < 0) return error.InvalidCanopyAmmoniaExchangeParameter;
    }
};

pub fn compatibilityCanopyAmmoniaExchangeParameters() CanopyAmmoniaExchangeParameters {
    return .{
        .minimum_canopy_dry_matter_fraction = 0.16,
        .water_potential_dry_matter_increment = 0.10,
        .water_potential_denominator_per_megapascal = 0.05,
        .water_potential_denominator_offset = 2.0,
        .canopy_air_volume_ratio_m3_per_g_c = 1.0e-4,
        .maximum_mobile_nitrogen_transfer_fraction_per_step = 0.1,
        .solubility_log_intercept = 0.513,
        .solubility_temperature_coefficient_per_c = 0.0171,
    };
}

pub fn canopyDryMatterFraction(total_water_potential_megapascal: f64, parameters: CanopyAmmoniaExchangeParameters) !f64 {
    try parameters.validate();
    if (!std.math.isFinite(total_water_potential_megapascal)) return error.NonFiniteCanopyAmmoniaExchangeInput;
    const absolute_potential_megapascal = @max(0, -total_water_potential_megapascal);
    const denominator = parameters.water_potential_denominator_per_megapascal * absolute_potential_megapascal + parameters.water_potential_denominator_offset;
    const fraction = parameters.minimum_canopy_dry_matter_fraction +
        parameters.water_potential_dry_matter_increment * absolute_potential_megapascal / denominator;
    if (!std.math.isFinite(fraction) or fraction <= 0) return error.NonFiniteCanopyAmmoniaExchange;
    return fraction;
}

pub const CanopyAmmoniaExchangeInputs = struct {
    parameters: CanopyAmmoniaExchangeParameters,
    atmospheric_ammonia_g_n_per_m3: f64,
    canopy_temperature_c: f64,
    ammonia_solubility_at_25_c: f64,
    canopy_dry_matter_fraction: f64,
    branch_mobile_nitrogen_concentration_g_n_per_g_c: f64,
    branch_mobile_nitrogen_g_n: f64,
    branch_live_structural_carbon_g_c: f64,
    branch_leaf_area_m2: f64,
    plant_leaf_area_m2: f64,
    total_aerodynamic_resistance_h_per_m: f64,
    stomatal_resistance_h_per_m: f64,
    plant_radiation_fraction: f64,
    cell_area_m2: f64,
    timestep_h: f64,
    negligible_carbon_g_c: f64,
};

/// UPTAKE RNH3B: signed atmospheric NH3-N transfer for one shoot branch.
/// Positive flux enters the plant mobile-N pool; negative flux is emission.
pub fn canopyAmmoniaExchangeGNPerStep(inputs: CanopyAmmoniaExchangeInputs) !f64 {
    inline for (@typeInfo(CanopyAmmoniaExchangeInputs).@"struct".fields) |field| {
        if (field.type != f64) continue;
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteCanopyAmmoniaExchangeInput;
    }
    try inputs.parameters.validate();
    if (inputs.atmospheric_ammonia_g_n_per_m3 < 0 or
        inputs.ammonia_solubility_at_25_c <= 0 or
        inputs.canopy_dry_matter_fraction < 0 or
        inputs.branch_mobile_nitrogen_concentration_g_n_per_g_c < 0 or
        inputs.branch_mobile_nitrogen_g_n < 0 or
        inputs.branch_live_structural_carbon_g_c < 0 or
        inputs.branch_leaf_area_m2 < 0 or
        inputs.plant_leaf_area_m2 < 0 or
        inputs.total_aerodynamic_resistance_h_per_m < 0 or
        inputs.stomatal_resistance_h_per_m < 0 or
        inputs.plant_radiation_fraction < 0 or
        inputs.cell_area_m2 <= 0 or
        inputs.timestep_h <= 0 or
        inputs.negligible_carbon_g_c < 0) return error.InvalidCanopyAmmoniaExchangeInput;
    if (inputs.branch_live_structural_carbon_g_c <= inputs.negligible_carbon_g_c or
        inputs.branch_leaf_area_m2 <= inputs.negligible_carbon_g_c or
        inputs.plant_leaf_area_m2 <= inputs.negligible_carbon_g_c) return 0;
    const total_resistance_h_per_m = inputs.total_aerodynamic_resistance_h_per_m + inputs.stomatal_resistance_h_per_m;
    if (total_resistance_h_per_m <= 0) return error.InvalidCanopyAmmoniaExchangeInput;
    const temperature_adjusted_solubility = inputs.ammonia_solubility_at_25_c *
        @exp(inputs.parameters.solubility_log_intercept - inputs.parameters.solubility_temperature_coefficient_per_c * inputs.canopy_temperature_c);
    if (!std.math.isFinite(temperature_adjusted_solubility) or temperature_adjusted_solubility <= 0) return error.NonFiniteCanopyAmmoniaExchange;
    const canopy_ammonia_g_n_per_m3 = @max(
        0,
        inputs.parameters.canopy_air_volume_ratio_m3_per_g_c * inputs.canopy_dry_matter_fraction *
            inputs.branch_mobile_nitrogen_concentration_g_n_per_g_c /
            temperature_adjusted_solubility,
    );
    const mobile_nitrogen_g_n = @max(0, inputs.branch_mobile_nitrogen_g_n);
    const unconstrained_flux_g_n =
        (inputs.atmospheric_ammonia_g_n_per_m3 - canopy_ammonia_g_n_per_m3) /
        total_resistance_h_per_m *
        inputs.plant_radiation_fraction *
        inputs.cell_area_m2 *
        inputs.timestep_h *
        inputs.branch_leaf_area_m2 /
        inputs.plant_leaf_area_m2;
    const transfer_limit_g_n = inputs.parameters.maximum_mobile_nitrogen_transfer_fraction_per_step * mobile_nitrogen_g_n;
    const flux_g_n = std.math.clamp(unconstrained_flux_g_n, -transfer_limit_g_n, transfer_limit_g_n);
    if (!std.math.isFinite(flux_g_n)) return error.NonFiniteCanopyAmmoniaExchange;
    return flux_g_n;
}

pub const RootBoundaryFlux = enum(usize) {
    atmospheric_carbon_dioxide_g_per_h,
    atmospheric_oxygen_g_per_h,
    atmospheric_methane_g_per_h,
    atmospheric_nitrous_oxide_g_per_h,
    atmospheric_ammonia_g_per_h,
    atmospheric_hydrogen_g_per_h,
    aqueous_carbon_dioxide_production_g_per_h,
    aqueous_oxygen_uptake_g_per_h,
    soil_carbon_dioxide_production_g_per_h,
    soil_oxygen_uptake_g_per_h,
    soil_methane_uptake_g_per_h,
    soil_nitrous_oxide_uptake_g_per_h,
    soil_ammonia_uptake_g_per_h,
    band_ammonia_uptake_g_per_h,
    soil_hydrogen_uptake_g_per_h,
    soil_ammonium_uptake_g_nitrogen_per_h,
    soil_nitrate_uptake_g_nitrogen_per_h,
    soil_dihydrogen_phosphate_uptake_g_phosphorus_per_h,
    soil_hydrogen_phosphate_uptake_g_phosphorus_per_h,
    band_ammonium_uptake_g_nitrogen_per_h,
    band_nitrate_uptake_g_nitrogen_per_h,
    band_dihydrogen_phosphate_uptake_g_phosphorus_per_h,
    band_hydrogen_phosphate_uptake_g_phosphorus_per_h,
};
pub const root_boundary_flux_count = @typeInfo(RootBoundaryFlux).@"enum".fields.len;

/// Aggregates the named root boundary fluxes across runtime root axes. EXTRACT
/// stores root aqueous CO2 production with the opposite sign; all other named
/// totals retain the source sign.
pub fn aggregateRootBoundaryFluxes(root_axis_count: usize, soil_layer_count: usize, species_fluxes: [root_boundary_flux_count][]const f64, totals_by_layer: [root_boundary_flux_count][]f64) !void {
    if (root_axis_count == 0 or soil_layer_count == 0) return error.InvalidRootBoundaryFluxLayout;
    const value_count = try std.math.mul(usize, root_axis_count, soil_layer_count);
    for (0..root_boundary_flux_count) |flux| {
        if (species_fluxes[flux].len != value_count or totals_by_layer[flux].len != soil_layer_count) return error.RootBoundaryFluxDimensionMismatch;
        for (species_fluxes[flux]) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootBoundaryFlux;
        for (0..root_axis_count) |axis| for (0..soil_layer_count) |layer| {
            const sign: f64 = if (flux == @intFromEnum(RootBoundaryFlux.aqueous_carbon_dioxide_production_g_per_h)) -1 else 1;
            totals_by_layer[flux][layer] += sign * species_fluxes[flux][axis * soil_layer_count + layer];
            if (!std.math.isFinite(totals_by_layer[flux][layer])) return error.NonFiniteRootBoundaryFlux;
        };
    }
}

/// Dynamic-salt counterpart of TUPZAL..TUPZCL, using the model's eight named
/// salt species and arbitrary runtime root-axis/layer counts.
pub fn aggregateRootSaltUptake(root_axis_count: usize, soil_layer_count: usize, dynamic_salts: bool, uptake_mol_per_h: []const f64, totals_mol_per_h: []f64) !void {
    const axis_layer_count = try std.math.mul(usize, root_axis_count, soil_layer_count);
    if (root_axis_count == 0 or soil_layer_count == 0 or uptake_mol_per_h.len != try std.math.mul(usize, axis_layer_count, 8) or totals_mol_per_h.len != try std.math.mul(usize, soil_layer_count, 8)) return error.RootSaltUptakeDimensionMismatch;
    for (uptake_mol_per_h) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootSaltUptake;
    if (!dynamic_salts) return;
    for (0..root_axis_count) |axis| for (0..soil_layer_count) |layer| for (0..8) |salt| {
        totals_mol_per_h[layer * 8 + salt] += uptake_mol_per_h[(axis * soil_layer_count + layer) * 8 + salt];
        if (!std.math.isFinite(totals_mol_per_h[layer * 8 + salt])) return error.NonFiniteRootSaltUptake;
    };
}

/// Root nonstructural C/N/P exchange is subtracted into the five REDIST DOM
/// fractions in EXTRACT. Fraction count remains runtime for future extensions.
pub fn aggregateRootExudation(root_axis_count: usize, soil_layer_count: usize, fraction_count: usize, carbon_g_per_h: []const f64, nitrogen_g_per_h: []const f64, phosphorus_g_per_h: []const f64, total_carbon_g_per_h: []f64, total_nitrogen_g_per_h: []f64, total_phosphorus_g_per_h: []f64) !void {
    const layer_fraction_count = try std.math.mul(usize, soil_layer_count, fraction_count);
    const input_count = try std.math.mul(usize, root_axis_count, layer_fraction_count);
    if (root_axis_count == 0 or soil_layer_count == 0 or fraction_count == 0 or carbon_g_per_h.len != input_count or nitrogen_g_per_h.len != input_count or phosphorus_g_per_h.len != input_count or total_carbon_g_per_h.len != layer_fraction_count or total_nitrogen_g_per_h.len != layer_fraction_count or total_phosphorus_g_per_h.len != layer_fraction_count) return error.RootExudationDimensionMismatch;
    inline for (.{ carbon_g_per_h, nitrogen_g_per_h, phosphorus_g_per_h }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootExudation;
    for (0..root_axis_count) |axis| for (0..soil_layer_count) |layer| for (0..fraction_count) |fraction| {
        const source = (axis * soil_layer_count + layer) * fraction_count + fraction;
        const destination = layer * fraction_count + fraction;
        total_carbon_g_per_h[destination] -= carbon_g_per_h[source];
        total_nitrogen_g_per_h[destination] -= nitrogen_g_per_h[source];
        total_phosphorus_g_per_h[destination] -= phosphorus_g_per_h[source];
    };
}

pub const CompetitionDemand = enum(usize) {
    oxygen_g_per_h,
    soil_ammonium_g_nitrogen_per_h,
    soil_nitrate_g_nitrogen_per_h,
    soil_dihydrogen_phosphate_g_phosphorus_per_h,
    soil_hydrogen_phosphate_g_phosphorus_per_h,
    band_ammonium_g_nitrogen_per_h,
    band_nitrate_g_nitrogen_per_h,
    band_dihydrogen_phosphate_g_phosphorus_per_h,
    band_hydrogen_phosphate_g_phosphorus_per_h,
};
pub const competition_demand_count = @typeInfo(CompetitionDemand).@"enum".fields.len;

/// Adds root/mycorrhizal potential demand into the shared competition arrays
/// used alongside microbial demand in NITRO and SOLUTE.
pub fn aggregateCompetitionDemand(root_axis_count: usize, soil_layer_count: usize, species_demand: [competition_demand_count][]const f64, shared_demand_by_layer: [competition_demand_count][]f64) !void {
    if (root_axis_count == 0 or soil_layer_count == 0) return error.InvalidCompetitionDemandLayout;
    const value_count = try std.math.mul(usize, root_axis_count, soil_layer_count);
    for (0..competition_demand_count) |demand| {
        if (species_demand[demand].len != value_count or shared_demand_by_layer[demand].len != soil_layer_count) return error.CompetitionDemandDimensionMismatch;
        for (0..root_axis_count) |axis| for (0..soil_layer_count) |layer| {
            const value = species_demand[demand][axis * soil_layer_count + layer];
            if (!std.math.isFinite(value)) return error.NonFiniteCompetitionDemand;
            shared_demand_by_layer[demand][layer] += value;
            if (!std.math.isFinite(shared_demand_by_layer[demand][layer])) return error.NonFiniteCompetitionDemand;
        };
    }
}

pub const SpeciesBalanceInputs = struct {
    hourly_canopy_carbon_fixation_g_per_h: []const f64,
    canopy_carbon_exchange_g_per_h: []const f64,
    leaf_area_m2: []const f64,
    stalk_area_m2: []const f64,
    root_soil_carbon_exchange_g_per_h: []const f64,
    root_soil_nitrogen_exchange_g_per_h: []const f64,
    root_soil_phosphorus_exchange_g_per_h: []const f64,
    carbon_balance_g: []const f64,
    nitrogen_balance_g: []const f64,
    phosphorus_balance_g: []const f64,
    root_gas_loss_g_per_h: [root_gas_count][]const f64,
    /// Species-major branch NH3 exchange.
    branch_ammonia_exchange_g_nitrogen_per_h: []const f64,
    branch_count_by_species: []const usize,
};

pub const SpeciesBalanceTotals = struct {
    hourly_canopy_carbon_fixation_g_per_h: f64,
    canopy_carbon_exchange_g_per_h: f64,
    canopy_oxygen_exchange_g_per_h: f64,
    leaf_area_m2: f64,
    stalk_area_m2: f64,
    root_soil_carbon_exchange_g_per_h: f64,
    root_soil_nitrogen_exchange_g_per_h: f64,
    root_soil_phosphorus_exchange_g_per_h: f64,
    carbon_balance_g: f64,
    nitrogen_balance_g: f64,
    phosphorus_balance_g: f64,
    root_gas_loss_g_per_h: [root_gas_count]f64,
    canopy_ammonia_exchange_g_nitrogen_per_h: f64,
};

/// Final EXTRACT all-species balance aggregation. Hourly canopy fixation is
/// only state_updateted on the final Newton/Picard iteration, matching NFZ == NFH.
pub fn aggregateSpeciesBalances(species_count: usize, final_iteration: bool, oxygen_g_per_g_carbon: f64, inputs: SpeciesBalanceInputs, species_canopy_ammonia_g_nitrogen_per_h: []f64, totals: *SpeciesBalanceTotals) !void {
    if (species_count == 0 or !std.math.isFinite(oxygen_g_per_g_carbon) or oxygen_g_per_g_carbon <= 0 or species_canopy_ammonia_g_nitrogen_per_h.len != species_count or inputs.branch_count_by_species.len != species_count) return error.InvalidSpeciesBalanceLayout;
    inline for (.{ inputs.hourly_canopy_carbon_fixation_g_per_h, inputs.canopy_carbon_exchange_g_per_h, inputs.leaf_area_m2, inputs.stalk_area_m2, inputs.root_soil_carbon_exchange_g_per_h, inputs.root_soil_nitrogen_exchange_g_per_h, inputs.root_soil_phosphorus_exchange_g_per_h, inputs.carbon_balance_g, inputs.nitrogen_balance_g, inputs.phosphorus_balance_g }) |values| if (values.len != species_count) return error.SpeciesBalanceDimensionMismatch;
    for (0..root_gas_count) |gas| if (inputs.root_gas_loss_g_per_h[gas].len != species_count) return error.SpeciesBalanceDimensionMismatch;
    var required_branch_values: usize = 0;
    for (inputs.branch_count_by_species) |count| required_branch_values = try std.math.add(usize, required_branch_values, count);
    if (inputs.branch_ammonia_exchange_g_nitrogen_per_h.len != required_branch_values) return error.SpeciesBalanceDimensionMismatch;
    var branch_offset: usize = 0;
    for (0..species_count) |species| {
        if (final_iteration) totals.hourly_canopy_carbon_fixation_g_per_h += inputs.hourly_canopy_carbon_fixation_g_per_h[species];
        const canopy_carbon = inputs.canopy_carbon_exchange_g_per_h[species];
        totals.canopy_carbon_exchange_g_per_h += canopy_carbon;
        totals.canopy_oxygen_exchange_g_per_h -= canopy_carbon * oxygen_g_per_g_carbon;
        totals.leaf_area_m2 += inputs.leaf_area_m2[species];
        totals.stalk_area_m2 += inputs.stalk_area_m2[species];
        totals.root_soil_carbon_exchange_g_per_h -= inputs.root_soil_carbon_exchange_g_per_h[species];
        totals.root_soil_nitrogen_exchange_g_per_h -= inputs.root_soil_nitrogen_exchange_g_per_h[species];
        totals.root_soil_phosphorus_exchange_g_per_h -= inputs.root_soil_phosphorus_exchange_g_per_h[species];
        totals.carbon_balance_g += inputs.carbon_balance_g[species];
        totals.nitrogen_balance_g += inputs.nitrogen_balance_g[species];
        totals.phosphorus_balance_g += inputs.phosphorus_balance_g[species];
        for (0..root_gas_count) |gas| totals.root_gas_loss_g_per_h[gas] += inputs.root_gas_loss_g_per_h[gas][species];
        var species_ammonia: f64 = 0;
        for (inputs.branch_ammonia_exchange_g_nitrogen_per_h[branch_offset .. branch_offset + inputs.branch_count_by_species[species]]) |value| species_ammonia += value;
        branch_offset += inputs.branch_count_by_species[species];
        species_canopy_ammonia_g_nitrogen_per_h[species] = species_ammonia;
        totals.canopy_ammonia_exchange_g_nitrogen_per_h += species_ammonia;
    }
    try validateSpeciesBalanceFinite(inputs, species_canopy_ammonia_g_nitrogen_per_h, totals.*);
}

fn validateSpeciesBalanceFinite(inputs: SpeciesBalanceInputs, species_ammonia: []const f64, totals: SpeciesBalanceTotals) !void {
    inline for (.{ inputs.hourly_canopy_carbon_fixation_g_per_h, inputs.canopy_carbon_exchange_g_per_h, inputs.leaf_area_m2, inputs.stalk_area_m2, inputs.root_soil_carbon_exchange_g_per_h, inputs.root_soil_nitrogen_exchange_g_per_h, inputs.root_soil_phosphorus_exchange_g_per_h, inputs.carbon_balance_g, inputs.nitrogen_balance_g, inputs.phosphorus_balance_g, inputs.branch_ammonia_exchange_g_nitrogen_per_h, species_ammonia }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteSpeciesBalance;
    for (0..root_gas_count) |gas| for (inputs.root_gas_loss_g_per_h[gas]) |value| if (!std.math.isFinite(value)) return error.NonFiniteSpeciesBalance;
    inline for (@typeInfo(SpeciesBalanceTotals).@"struct".fields) |field| {
        if (field.type == f64) {
            if (!std.math.isFinite(@field(totals, field.name))) return error.NonFiniteSpeciesBalance;
        } else for (@field(totals, field.name)) |value| if (!std.math.isFinite(value)) return error.NonFiniteSpeciesBalance;
    }
}

pub fn aggregateRootNitrogenFixation(species_count: usize, soil_layer_count: usize, fixation_g_nitrogen_per_h: []const f64, totals_by_layer_g_nitrogen_per_h: []f64) !void {
    if (species_count == 0 or soil_layer_count == 0 or fixation_g_nitrogen_per_h.len != try std.math.mul(usize, species_count, soil_layer_count) or totals_by_layer_g_nitrogen_per_h.len != soil_layer_count) return error.RootNitrogenFixationDimensionMismatch;
    for (0..species_count) |species| for (0..soil_layer_count) |layer| {
        const value = fixation_g_nitrogen_per_h[species * soil_layer_count + layer];
        if (!std.math.isFinite(value)) return error.NonFiniteRootNitrogenFixation;
        totals_by_layer_g_nitrogen_per_h[layer] += value;
    };
}

pub const RootExchangeInputs = struct {
    root_length_density_per_plant_m_per_m3: []const f64,
    water_uptake_m3_per_h: []const f64,
    /// Gas-major arrays of root-axis × soil-layer rates.
    gaseous_atmosphere_exchange_g_per_h: [root_gas_count][]const f64,
    aqueous_to_gaseous_exchange_g_per_h: [root_gas_count][]const f64,
    /// Signed biological change: production positive, uptake negative.
    aqueous_biological_change_g_per_h: [root_gas_count][]const f64,
};

pub const RootExchangeState = struct {
    gaseous_content_g: [root_gas_count][]f64,
    aqueous_content_g: [root_gas_count][]f64,
    total_content_by_layer_g: [root_gas_count][]f64,
    total_root_length_density_m_per_m3: []f64,
    total_water_uptake_m3_per_h: []f64,
    convective_water_heat_megajoules_per_h: []f64,
};

/// Exact EXTRACT root gas bookkeeping (`*A`, `*P`, and `TL*P`) and water/heat
/// uptake aggregation for one runtime plant species.
pub fn aggregateRootExchange(root_axis_count: usize, soil_layer_count: usize, plant_population: f64, horizontal_layer_area_m2: []const f64, soil_temperature_k: []const f64, inputs: RootExchangeInputs, state: *RootExchangeState) !void {
    if (root_axis_count == 0 or soil_layer_count == 0 or !std.math.isFinite(plant_population) or plant_population < 0 or horizontal_layer_area_m2.len != soil_layer_count or soil_temperature_k.len != soil_layer_count) return error.InvalidRootExchangeLayout;
    const value_count = try std.math.mul(usize, root_axis_count, soil_layer_count);
    if (inputs.root_length_density_per_plant_m_per_m3.len != value_count or inputs.water_uptake_m3_per_h.len != value_count or state.total_root_length_density_m_per_m3.len != soil_layer_count or state.total_water_uptake_m3_per_h.len != soil_layer_count or state.convective_water_heat_megajoules_per_h.len != soil_layer_count) return error.RootExchangeDimensionMismatch;
    for (0..root_gas_count) |gas| if (inputs.gaseous_atmosphere_exchange_g_per_h[gas].len != value_count or inputs.aqueous_to_gaseous_exchange_g_per_h[gas].len != value_count or inputs.aqueous_biological_change_g_per_h[gas].len != value_count or state.gaseous_content_g[gas].len != value_count or state.aqueous_content_g[gas].len != value_count or state.total_content_by_layer_g[gas].len != soil_layer_count) return error.RootExchangeDimensionMismatch;
    inline for (.{ horizontal_layer_area_m2, soil_temperature_k, inputs.root_length_density_per_plant_m_per_m3, inputs.water_uptake_m3_per_h }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootExchange;
    for (horizontal_layer_area_m2, soil_temperature_k) |area, temperature| if (area <= 0 or temperature <= 0) return error.InvalidRootExchangeGeometry;
    for (0..root_gas_count) |gas| inline for (.{ inputs.gaseous_atmosphere_exchange_g_per_h[gas], inputs.aqueous_to_gaseous_exchange_g_per_h[gas], inputs.aqueous_biological_change_g_per_h[gas], state.gaseous_content_g[gas], state.aqueous_content_g[gas], state.total_content_by_layer_g[gas] }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootExchange;

    for (0..root_axis_count) |axis| for (0..soil_layer_count) |layer| {
        const index = axis * soil_layer_count + layer;
        if (axis == 0) state.total_root_length_density_m_per_m3[layer] += inputs.root_length_density_per_plant_m_per_m3[index] * plant_population / horizontal_layer_area_m2[layer];
        state.total_water_uptake_m3_per_h[layer] += inputs.water_uptake_m3_per_h[index];
        state.convective_water_heat_megajoules_per_h[layer] += inputs.water_uptake_m3_per_h[index] * 4.19 * soil_temperature_k[layer];
        for (0..root_gas_count) |gas| {
            state.gaseous_content_g[gas][index] += inputs.gaseous_atmosphere_exchange_g_per_h[gas][index] - inputs.aqueous_to_gaseous_exchange_g_per_h[gas][index];
            state.aqueous_content_g[gas][index] += inputs.aqueous_to_gaseous_exchange_g_per_h[gas][index] + inputs.aqueous_biological_change_g_per_h[gas][index];
            state.total_content_by_layer_g[gas][layer] += state.gaseous_content_g[gas][index] + state.aqueous_content_g[gas][index];
        }
    };
    for (0..root_gas_count) |gas| inline for (.{ state.gaseous_content_g[gas], state.aqueous_content_g[gas], state.total_content_by_layer_g[gas] }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootExchange;
}

pub fn canopyPlantCombustionFractions(result: CanopyFireResult) PlantCombustionFractions {
    return .{ .charcoal = result.charcoal_fraction_of_combusted_carbon, .aerobic_noncharcoal = result.aerobic_fraction_of_noncharcoal, .anaerobic_noncharcoal = result.anaerobic_fraction_of_noncharcoal };
}

/// Exact layer-specific root partition from RCGSK, RCGOX, and RCHOX.
pub fn rootPlantCombustionFractions(unlimited_combustion_g_carbon: f64, aerobic_combustion_g_carbon: f64, anaerobic_combustion_g_carbon: f64, negligible_carbon_g: f64) !?PlantCombustionFractions {
    inline for (.{ unlimited_combustion_g_carbon, aerobic_combustion_g_carbon, anaerobic_combustion_g_carbon, negligible_carbon_g }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootCombustionInput;
    const gaseous = aerobic_combustion_g_carbon + anaerobic_combustion_g_carbon;
    if (unlimited_combustion_g_carbon <= negligible_carbon_g or gaseous <= negligible_carbon_g) return null;
    if (gaseous > unlimited_combustion_g_carbon) return error.RootCombustionExceedsUnlimitedRate;
    return .{ .charcoal = (unlimited_combustion_g_carbon - gaseous) / unlimited_combustion_g_carbon, .aerobic_noncharcoal = aerobic_combustion_g_carbon / gaseous, .anaerobic_noncharcoal = anaerobic_combustion_g_carbon / gaseous };
}

pub const CanopyTransferInputs = struct {
    active: []const bool,
    standing_dead_area_m2: []const f64,
    leaf_area_m2: []const f64,
    leaf_carbon_g: []const f64,
    stalk_area_m2: []const f64,
    standing_dead_ground_area_m2: []const f64,
    net_radiation_megajoules_per_h: []const f64,
    latent_heat_flux_megajoules_per_h: []const f64,
    sensible_heat_flux_megajoules_per_h: []const f64,
    storage_heat_flux_megajoules_per_h: []const f64,
    convective_heat_flux_megajoules_per_h: []const f64,
    transpiration_m3_per_h: []const f64,
    evaporation_m3_per_h: []const f64,
    internal_water_m3: []const f64,
    surface_water_m3: []const f64,
    standing_dead_surface_water_m3: []const f64,
    retained_foliar_water_m3_per_h: []const f64,
    retained_standing_dead_water_m3_per_h: []const f64,
    canopy_temperature_k: []const f64,
};

pub const CanopyTransferTotals = struct {
    standing_dead_area_m2: []f64,
    leaf_area_m2: []f64,
    leaf_carbon_g: []f64,
    stalk_area_m2: []f64,
    standing_dead_ground_area_m2: f64,
    net_radiation_megajoules_per_h: f64,
    latent_heat_flux_megajoules_per_h: f64,
    sensible_heat_flux_megajoules_per_h: f64,
    storage_heat_flux_megajoules_per_h: f64,
    transpiration_and_evaporation_m3_per_h: f64,
    internal_water_m3: f64,
    surface_water_m3: f64,
    evaporation_m3_per_h: f64,
    water_energy_megajoules: f64,
    water_energy_change_megajoules_per_h: f64,
};

/// Aggregates the EXTRACT canopy/standing-dead transfer block for any runtime
/// species and canopy-layer counts. `previous_water_energy_megajoules` is updated in
/// place exactly like ENGYX after the hourly storage-flux calculation.
pub fn aggregateHourlyCanopyTransfers(species_count: usize, canopy_layer_count: usize, air_temperature_k: f64, inputs: CanopyTransferInputs, previous_water_energy_megajoules: []f64, totals: *CanopyTransferTotals) !void {
    if (species_count == 0 or canopy_layer_count == 0 or !std.math.isFinite(air_temperature_k) or air_temperature_k <= 0) return error.InvalidCanopyTransferLayout;
    const layered_count = try std.math.mul(usize, species_count, canopy_layer_count);
    inline for (.{ inputs.standing_dead_area_m2, inputs.leaf_area_m2, inputs.leaf_carbon_g, inputs.stalk_area_m2 }) |values| if (values.len != layered_count) return error.CanopyTransferDimensionMismatch;
    inline for (.{ inputs.active, inputs.standing_dead_ground_area_m2, inputs.net_radiation_megajoules_per_h, inputs.latent_heat_flux_megajoules_per_h, inputs.sensible_heat_flux_megajoules_per_h, inputs.storage_heat_flux_megajoules_per_h, inputs.convective_heat_flux_megajoules_per_h, inputs.transpiration_m3_per_h, inputs.evaporation_m3_per_h, inputs.internal_water_m3, inputs.surface_water_m3, inputs.standing_dead_surface_water_m3, inputs.retained_foliar_water_m3_per_h, inputs.retained_standing_dead_water_m3_per_h, inputs.canopy_temperature_k, previous_water_energy_megajoules }) |values| if (values.len != species_count) return error.CanopyTransferDimensionMismatch;
    inline for (.{ totals.standing_dead_area_m2, totals.leaf_area_m2, totals.leaf_carbon_g, totals.stalk_area_m2 }) |values| if (values.len != canopy_layer_count) return error.CanopyTransferDimensionMismatch;
    inline for (.{ inputs.standing_dead_area_m2, inputs.leaf_area_m2, inputs.leaf_carbon_g, inputs.stalk_area_m2, inputs.standing_dead_ground_area_m2, inputs.net_radiation_megajoules_per_h, inputs.latent_heat_flux_megajoules_per_h, inputs.sensible_heat_flux_megajoules_per_h, inputs.storage_heat_flux_megajoules_per_h, inputs.convective_heat_flux_megajoules_per_h, inputs.transpiration_m3_per_h, inputs.evaporation_m3_per_h, inputs.internal_water_m3, inputs.surface_water_m3, inputs.standing_dead_surface_water_m3, inputs.retained_foliar_water_m3_per_h, inputs.retained_standing_dead_water_m3_per_h, inputs.canopy_temperature_k, previous_water_energy_megajoules }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopyTransfer;
    for (0..species_count) |species| {
        for (0..canopy_layer_count) |layer| {
            const index = species * canopy_layer_count + layer;
            totals.standing_dead_area_m2[layer] += inputs.standing_dead_area_m2[index];
            if (inputs.active[species]) {
                totals.leaf_area_m2[layer] += inputs.leaf_area_m2[index];
                totals.leaf_carbon_g[layer] += inputs.leaf_carbon_g[index];
                totals.stalk_area_m2[layer] += inputs.stalk_area_m2[index];
            }
        }
        totals.standing_dead_ground_area_m2 += inputs.standing_dead_ground_area_m2[species];
        totals.net_radiation_megajoules_per_h += inputs.net_radiation_megajoules_per_h[species];
        totals.latent_heat_flux_megajoules_per_h += inputs.latent_heat_flux_megajoules_per_h[species];
        totals.sensible_heat_flux_megajoules_per_h += inputs.sensible_heat_flux_megajoules_per_h[species];
        totals.storage_heat_flux_megajoules_per_h -= inputs.storage_heat_flux_megajoules_per_h[species] - inputs.convective_heat_flux_megajoules_per_h[species];
        const transpiration_and_evaporation = inputs.transpiration_m3_per_h[species] + inputs.evaporation_m3_per_h[species];
        totals.transpiration_and_evaporation_m3_per_h += transpiration_and_evaporation;
        totals.internal_water_m3 += inputs.internal_water_m3[species];
        totals.surface_water_m3 += inputs.surface_water_m3[species] + inputs.standing_dead_surface_water_m3[species];
        totals.evaporation_m3_per_h += inputs.evaporation_m3_per_h[species];
        const water_energy_megajoules = 4.19 * (inputs.surface_water_m3[species] + inputs.standing_dead_surface_water_m3[species] + inputs.retained_foliar_water_m3_per_h[species] + inputs.retained_standing_dead_water_m3_per_h[species] + inputs.evaporation_m3_per_h[species]) * inputs.canopy_temperature_k[species];
        totals.water_energy_megajoules += water_energy_megajoules;
        // The source XNFH term represented one member of its repeated
        // sub-hour cycle. ecosys-ng state_updates the full hourly carrier once.
        totals.water_energy_change_megajoules_per_h += water_energy_megajoules - previous_water_energy_megajoules[species] - (inputs.retained_foliar_water_m3_per_h[species] + inputs.retained_standing_dead_water_m3_per_h[species]) * 4.19 * air_temperature_k;
        previous_water_energy_megajoules[species] = water_energy_megajoules;
    }
    try validateCanopyTransferTotals(totals.*);
}

fn validateCanopyTransferTotals(totals: CanopyTransferTotals) !void {
    inline for (.{ totals.standing_dead_area_m2, totals.leaf_area_m2, totals.leaf_carbon_g, totals.stalk_area_m2 }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopyTransfer;
    inline for (.{ totals.standing_dead_ground_area_m2, totals.net_radiation_megajoules_per_h, totals.latent_heat_flux_megajoules_per_h, totals.sensible_heat_flux_megajoules_per_h, totals.storage_heat_flux_megajoules_per_h, totals.transpiration_and_evaporation_m3_per_h, totals.internal_water_m3, totals.surface_water_m3, totals.evaporation_m3_per_h, totals.water_energy_megajoules, totals.water_energy_change_megajoules_per_h }) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopyTransfer;
}

/// Live EXTRACT ENGYC/ENGYX/THFLXC state_update after canopy surface-water
/// retention and evaporation have state_updateted. Since `surface_water_m3` is the
/// accepted endpoint inventory, retention and evaporation are not added to it
/// again. Only the retained precipitation carrier enters with atmospheric
/// enthalpy, exactly once for the whole hour.
pub fn refreshHourlyCanopyWaterEnergy(
    species_count: usize,
    air_temperature_k_by_cell: []const f64,
    canopy_temperature_k_by_plant: []const f64,
    surface_water_m3_by_plant: []const f64,
    standing_dead_surface_water_m3_by_plant: []const f64,
    retained_foliar_water_m3_per_h_by_plant: []const f64,
    retained_standing_dead_water_m3_per_h_by_plant: []const f64,
    previous_water_energy_megajoules_by_plant: []f64,
    total_water_energy_megajoules_by_cell: []f64,
    water_energy_change_megajoules_per_h_by_cell: []f64,
) !void {
    if (species_count == 0 or air_temperature_k_by_cell.len == 0 or
        total_water_energy_megajoules_by_cell.len != air_temperature_k_by_cell.len or
        water_energy_change_megajoules_per_h_by_cell.len != air_temperature_k_by_cell.len)
        return error.CanopyWaterEnergyDimensionMismatch;
    const plant_count = try std.math.mul(usize, air_temperature_k_by_cell.len, species_count);
    inline for (.{
        canopy_temperature_k_by_plant,
        surface_water_m3_by_plant,
        standing_dead_surface_water_m3_by_plant,
        retained_foliar_water_m3_per_h_by_plant,
        retained_standing_dead_water_m3_per_h_by_plant,
        previous_water_energy_megajoules_by_plant,
    }) |values| if (values.len != plant_count) return error.CanopyWaterEnergyDimensionMismatch;
    for (air_temperature_k_by_cell) |temperature_k|
        if (!std.math.isFinite(temperature_k) or temperature_k <= 0) return error.InvalidCanopyWaterEnergyInput;
    for (0..plant_count) |plant| {
        inline for (.{
            canopy_temperature_k_by_plant[plant],
            surface_water_m3_by_plant[plant],
            standing_dead_surface_water_m3_by_plant[plant],
            retained_foliar_water_m3_per_h_by_plant[plant],
            retained_standing_dead_water_m3_per_h_by_plant[plant],
            previous_water_energy_megajoules_by_plant[plant],
        }) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopyWaterEnergyInput;
        if (canopy_temperature_k_by_plant[plant] <= 0 or
            surface_water_m3_by_plant[plant] < 0 or
            standing_dead_surface_water_m3_by_plant[plant] < 0 or
            previous_water_energy_megajoules_by_plant[plant] < 0)
            return error.InvalidCanopyWaterEnergyInput;
        const cell = plant / species_count;
        const current = 4.19 *
            (surface_water_m3_by_plant[plant] + standing_dead_surface_water_m3_by_plant[plant]) *
            canopy_temperature_k_by_plant[plant];
        const incoming = 4.19 *
            (retained_foliar_water_m3_per_h_by_plant[plant] + retained_standing_dead_water_m3_per_h_by_plant[plant]) *
            air_temperature_k_by_cell[cell];
        const change = current - previous_water_energy_megajoules_by_plant[plant] - incoming;
        if (!std.math.isFinite(current) or current < 0 or !std.math.isFinite(change))
            return error.NonFiniteCanopyWaterEnergy;
    }
    @memset(total_water_energy_megajoules_by_cell, 0);
    @memset(water_energy_change_megajoules_per_h_by_cell, 0);
    for (0..plant_count) |plant| {
        const cell = plant / species_count;
        const current = 4.19 *
            (surface_water_m3_by_plant[plant] + standing_dead_surface_water_m3_by_plant[plant]) *
            canopy_temperature_k_by_plant[plant];
        const incoming = 4.19 *
            (retained_foliar_water_m3_per_h_by_plant[plant] + retained_standing_dead_water_m3_per_h_by_plant[plant]) *
            air_temperature_k_by_cell[cell];
        total_water_energy_megajoules_by_cell[cell] += current;
        water_energy_change_megajoules_per_h_by_cell[cell] += current - previous_water_energy_megajoules_by_plant[plant] - incoming;
        previous_water_energy_megajoules_by_plant[plant] = current;
    }
}

/// EXTRACT shoot/standing-dead pool partition. Pool count is entirely runtime;
/// salts are pool-major in the named Al..Cl order used by the model science.
pub fn combustPlantPools(carbon_g: []const f64, nitrogen_g: []const f64, phosphorus_g: []const f64, salt_mol: []const f64, dynamic_salts: bool, tissue_combustion_temperature_response: f64, fractions: PlantCombustionFractions) !CombustedPoolResult {
    if (carbon_g.len != nitrogen_g.len or carbon_g.len != phosphorus_g.len or salt_mol.len != try std.math.mul(usize, carbon_g.len, 8)) return error.PlantCombustionDimensionMismatch;
    if (!std.math.isFinite(tissue_combustion_temperature_response) or tissue_combustion_temperature_response < 0 or tissue_combustion_temperature_response > 1) return error.InvalidPlantCombustionTemperatureResponse;
    inline for (.{ fractions.charcoal, fractions.aerobic_noncharcoal, fractions.anaerobic_noncharcoal }) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidPlantCombustionFractions;
    if (@abs(fractions.aerobic_noncharcoal + fractions.anaerobic_noncharcoal - 1.0) > 1e-12) return error.InvalidPlantCombustionFractions;
    inline for (.{ carbon_g, nitrogen_g, phosphorus_g, salt_mol }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantCombustionPool;
    const nitrogen_to_ammonium_fraction = 0.1 + (0.5 - 0.1) * (1.0 - tissue_combustion_temperature_response);
    const phosphorus_to_phosphate_fraction = 0.7 + (0.9 - 0.7) * (1.0 - tissue_combustion_temperature_response);
    var result: CombustedPoolResult = .{};
    for (carbon_g, nitrogen_g, phosphorus_g, 0..) |carbon, nitrogen, phosphorus, pool| {
        result.charcoal_g_carbon += carbon * fractions.charcoal;
        result.carbon_dioxide_g_carbon += carbon * (1.0 - fractions.charcoal) * fractions.aerobic_noncharcoal;
        result.methane_g_carbon += carbon * (1.0 - fractions.charcoal) * fractions.anaerobic_noncharcoal;
        result.ammonium_nitrogen_g += nitrogen * nitrogen_to_ammonium_fraction;
        result.gaseous_nitrogen_g += nitrogen * (1.0 - nitrogen_to_ammonium_fraction);
        result.phosphate_phosphorus_g += phosphorus * phosphorus_to_phosphate_fraction;
        result.gaseous_phosphorus_g += phosphorus * (1.0 - phosphorus_to_phosphate_fraction);
        if (dynamic_salts) {
            for (0..8) |salt| result.released_salt_mol[salt] += salt_mol[pool * 8 + salt];
        }
    }
    inline for (@typeInfo(CombustedPoolResult).@"struct".fields) |field| {
        if (field.type == f64) {
            if (!std.math.isFinite(@field(result, field.name))) return error.NonFinitePlantCombustionResult;
        } else for (@field(result, field.name)) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantCombustionResult;
    }
    return result;
}

/// Guards the exported parts against drifting from the aggregate they were
/// split out of. `oxygen_consumed_g` is the only term downstream gas ledgers
/// debit, while `redist.f` 4499/4837 consume the two parts separately, so an
/// inconsistency here would double count or silently lose oxygen. Both parts
/// are also required non-negative: a negative `ROGOX` or `RC4OX` has no
/// physical reading and would flip the sign of the REDIST debit.
fn validateOxygenPartition(result: CanopyFireResult, oxygen_g_per_g_carbon: f64) !void {
    if (result.oxygen_limited_uptake_g < 0 or result.methane_combustion_g_carbon < 0) return error.NegativeFireOxygenPartition;
    const recombined = result.oxygen_limited_uptake_g + result.methane_combustion_g_carbon * oxygen_g_per_g_carbon;
    const scale = @max(1.0, @abs(result.oxygen_consumed_g));
    if (@abs(recombined - result.oxygen_consumed_g) > 1e-12 * scale) return error.FireOxygenPartitionMismatch;
}

/// Exact EXTRACT total-canopy combustion partition. Positive gas values are
/// emissions/consumption; callers apply their own atmospheric ledger signs.
pub fn canopyFireCombustion(total_combusted_carbon_g: f64, negligible_carbon_g: f64, canopy_temperature_k: f64, oxygen_concentration_umol_per_mol: f64, oxygen_content_g: f64, methane_concentration_umol_per_mol: f64, parameters: CanopyFireParameters) !CanopyFireResult {
    inline for (.{ total_combusted_carbon_g, negligible_carbon_g, canopy_temperature_k, oxygen_concentration_umol_per_mol, oxygen_content_g, methane_concentration_umol_per_mol, parameters.gas_constant_j_per_mol_k, parameters.combustion_activation_energy_j_per_mol, parameters.combustion_temperature_intercept, parameters.oxygen_g_per_g_carbon, parameters.maximum_aerobic_charcoal_fraction, parameters.maximum_anaerobic_charcoal_fraction, parameters.oxygen_half_saturation_umol_per_mol, parameters.methane_half_saturation_umol_per_mol, parameters.aerobic_combustion_energy_megajoules_per_g_carbon, parameters.anaerobic_combustion_energy_megajoules_per_g_carbon, parameters.methane_combustion_energy_megajoules_per_g_carbon }) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopyFireInput;
    if (total_combusted_carbon_g < 0 or negligible_carbon_g < 0 or canopy_temperature_k <= 0 or oxygen_concentration_umol_per_mol < 0 or oxygen_content_g < 0 or methane_concentration_umol_per_mol < 0 or parameters.gas_constant_j_per_mol_k <= 0 or parameters.combustion_activation_energy_j_per_mol < 0 or parameters.oxygen_g_per_g_carbon <= 0 or parameters.maximum_aerobic_charcoal_fraction < 0 or parameters.maximum_aerobic_charcoal_fraction > 1 or parameters.maximum_anaerobic_charcoal_fraction < 0 or parameters.maximum_anaerobic_charcoal_fraction > 1 or parameters.oxygen_half_saturation_umol_per_mol < 0 or parameters.methane_half_saturation_umol_per_mol < 0) return error.InvalidCanopyFireInput;
    if (total_combusted_carbon_g <= negligible_carbon_g) return .{ .oxygen_consumed_g = 0, .oxygen_limited_uptake_g = 0, .methane_combustion_g_carbon = 0, .carbon_dioxide_emitted_g_carbon = 0, .methane_emitted_g_carbon = 0, .charcoal_produced_g_carbon = 0, .charcoal_fraction_of_combusted_carbon = 0, .heat_released_megajoules = 0, .aerobic_fraction_of_noncharcoal = 0, .anaerobic_fraction_of_noncharcoal = 0, .combustion_temperature_response = 0 };
    const oxygen_denominator = oxygen_concentration_umol_per_mol + parameters.oxygen_half_saturation_umol_per_mol;
    const methane_denominator = methane_concentration_umol_per_mol + parameters.methane_half_saturation_umol_per_mol;
    if (oxygen_denominator <= 0 or methane_denominator <= 0) return error.ZeroCanopyFireHalfSaturationDenominator;

    const temperature_response = @min(1.0, @exp(parameters.combustion_temperature_intercept - parameters.combustion_activation_energy_j_per_mol / (parameters.gas_constant_j_per_mol_k * canopy_temperature_k)));
    const aerobic_gas_fraction = 1.0 - parameters.maximum_aerobic_charcoal_fraction * (1.0 - temperature_response);
    const anaerobic_gas_fraction = 1.0 - parameters.maximum_anaerobic_charcoal_fraction * (1.0 - temperature_response);
    const unlimited_oxygen_g = total_combusted_carbon_g * parameters.oxygen_g_per_g_carbon;
    const aerobic_oxygen_g = @min(unlimited_oxygen_g * oxygen_concentration_umol_per_mol / oxygen_denominator, oxygen_content_g) * aerobic_gas_fraction;
    const aerobic_carbon_g = aerobic_oxygen_g / parameters.oxygen_g_per_g_carbon;
    const methane_produced_g_carbon = @max(0.0, (total_combusted_carbon_g * aerobic_gas_fraction - aerobic_carbon_g) * anaerobic_gas_fraction);
    const oxygen_remaining_g = @max(0.0, oxygen_content_g - aerobic_oxygen_g);
    const methane_oxidized_g_carbon = @min(
        methane_produced_g_carbon * methane_concentration_umol_per_mol / methane_denominator * oxygen_concentration_umol_per_mol / oxygen_denominator,
        oxygen_remaining_g / parameters.oxygen_g_per_g_carbon,
    );
    const charcoal_g = total_combusted_carbon_g - aerobic_carbon_g - methane_produced_g_carbon;
    const noncharcoal_g = aerobic_carbon_g + methane_produced_g_carbon;
    if (noncharcoal_g <= 0) return error.NoGaseousCanopyFireProduct;
    const result: CanopyFireResult = .{
        .oxygen_consumed_g = aerobic_oxygen_g + methane_oxidized_g_carbon * parameters.oxygen_g_per_g_carbon,
        .oxygen_limited_uptake_g = aerobic_oxygen_g,
        .methane_combustion_g_carbon = methane_oxidized_g_carbon,
        .carbon_dioxide_emitted_g_carbon = aerobic_carbon_g + methane_oxidized_g_carbon,
        .methane_emitted_g_carbon = methane_produced_g_carbon - methane_oxidized_g_carbon,
        .charcoal_produced_g_carbon = charcoal_g,
        .charcoal_fraction_of_combusted_carbon = charcoal_g / total_combusted_carbon_g,
        .heat_released_megajoules = aerobic_carbon_g * parameters.aerobic_combustion_energy_megajoules_per_g_carbon + methane_produced_g_carbon * parameters.anaerobic_combustion_energy_megajoules_per_g_carbon + methane_oxidized_g_carbon * parameters.methane_combustion_energy_megajoules_per_g_carbon,
        .aerobic_fraction_of_noncharcoal = aerobic_carbon_g / noncharcoal_g,
        .anaerobic_fraction_of_noncharcoal = methane_produced_g_carbon / noncharcoal_g,
        .combustion_temperature_response = temperature_response,
    };
    inline for (@typeInfo(CanopyFireResult).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteCanopyFireResult;
    try validateOxygenPartition(result, parameters.oxygen_g_per_g_carbon);
    return result;
}

/// TRNSFR/REDIST gas partition shared by litter, soil organic matter, and
/// roots. The caller supplies the already evaluated TFNCOS response.
pub fn subsurfaceOrganicMatterFire(total_combusted_carbon_g: f64, negligible_carbon_g: f64, combustion_temperature_response: f64, oxygen_concentration_g_o_per_m3: f64, oxygen_content_g_o: f64, methane_concentration_g_c_per_m3: f64, methane_content_g_c: f64, parameters: SubsurfaceFireParameters) !CanopyFireResult {
    inline for (.{
        total_combusted_carbon_g,
        negligible_carbon_g,
        combustion_temperature_response,
        oxygen_concentration_g_o_per_m3,
        oxygen_content_g_o,
        methane_concentration_g_c_per_m3,
        methane_content_g_c,
        parameters.oxygen_g_per_g_carbon,
        parameters.maximum_aerobic_charcoal_fraction,
        parameters.maximum_anaerobic_charcoal_fraction,
        parameters.oxygen_half_saturation_g_o_per_m3,
        parameters.methane_half_saturation_g_c_per_m3,
        parameters.aerobic_combustion_energy_megajoules_per_g_carbon,
        parameters.anaerobic_combustion_energy_megajoules_per_g_carbon,
        parameters.methane_combustion_energy_megajoules_per_g_carbon,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSubsurfaceFireInput;
    if (total_combusted_carbon_g < 0 or negligible_carbon_g < 0 or combustion_temperature_response < 0 or combustion_temperature_response > 1 or oxygen_concentration_g_o_per_m3 < 0 or oxygen_content_g_o < 0 or methane_concentration_g_c_per_m3 < 0 or methane_content_g_c < 0 or parameters.oxygen_g_per_g_carbon <= 0 or parameters.maximum_aerobic_charcoal_fraction < 0 or parameters.maximum_aerobic_charcoal_fraction > 1 or parameters.maximum_anaerobic_charcoal_fraction < 0 or parameters.maximum_anaerobic_charcoal_fraction > 1 or parameters.oxygen_half_saturation_g_o_per_m3 < 0 or parameters.methane_half_saturation_g_c_per_m3 < 0) return error.InvalidSubsurfaceFireInput;
    if (total_combusted_carbon_g <= negligible_carbon_g) return .{ .oxygen_consumed_g = 0, .oxygen_limited_uptake_g = 0, .methane_combustion_g_carbon = 0, .carbon_dioxide_emitted_g_carbon = 0, .methane_emitted_g_carbon = 0, .charcoal_produced_g_carbon = 0, .charcoal_fraction_of_combusted_carbon = 0, .heat_released_megajoules = 0, .aerobic_fraction_of_noncharcoal = 0, .anaerobic_fraction_of_noncharcoal = 0, .combustion_temperature_response = combustion_temperature_response };
    const oxygen_denominator = oxygen_concentration_g_o_per_m3 + parameters.oxygen_half_saturation_g_o_per_m3;
    const methane_denominator = methane_concentration_g_c_per_m3 + parameters.methane_half_saturation_g_c_per_m3;
    if (oxygen_denominator <= 0 or methane_denominator <= 0) return error.ZeroSubsurfaceFireHalfSaturationDenominator;
    const aerobic_gas_fraction = 1.0 - parameters.maximum_aerobic_charcoal_fraction * (1.0 - combustion_temperature_response);
    const anaerobic_gas_fraction = 1.0 - parameters.maximum_anaerobic_charcoal_fraction * (1.0 - combustion_temperature_response);
    const unlimited_oxygen_g = total_combusted_carbon_g * parameters.oxygen_g_per_g_carbon;
    const aerobic_oxygen_g = @min(unlimited_oxygen_g * oxygen_concentration_g_o_per_m3 / oxygen_denominator, oxygen_content_g_o) * aerobic_gas_fraction;
    const aerobic_carbon_g = aerobic_oxygen_g / parameters.oxygen_g_per_g_carbon;
    const methane_produced_g_carbon = @max(0.0, (total_combusted_carbon_g * aerobic_gas_fraction - aerobic_carbon_g) * anaerobic_gas_fraction);
    const oxygen_remaining_g = @max(0.0, oxygen_content_g_o - aerobic_oxygen_g);
    const methane_oxidized_g_carbon = @min(
        methane_produced_g_carbon * methane_concentration_g_c_per_m3 / methane_denominator * oxygen_concentration_g_o_per_m3 / oxygen_denominator,
        methane_content_g_c,
        oxygen_remaining_g / parameters.oxygen_g_per_g_carbon,
    );
    const charcoal_g = total_combusted_carbon_g - aerobic_carbon_g - methane_produced_g_carbon;
    const noncharcoal_g = aerobic_carbon_g + methane_produced_g_carbon;
    const result: CanopyFireResult = .{
        .oxygen_consumed_g = aerobic_oxygen_g + methane_oxidized_g_carbon * parameters.oxygen_g_per_g_carbon,
        .oxygen_limited_uptake_g = aerobic_oxygen_g,
        .methane_combustion_g_carbon = methane_oxidized_g_carbon,
        .carbon_dioxide_emitted_g_carbon = aerobic_carbon_g + methane_oxidized_g_carbon,
        .methane_emitted_g_carbon = methane_produced_g_carbon - methane_oxidized_g_carbon,
        .charcoal_produced_g_carbon = charcoal_g,
        .charcoal_fraction_of_combusted_carbon = charcoal_g / total_combusted_carbon_g,
        .heat_released_megajoules = aerobic_carbon_g * parameters.aerobic_combustion_energy_megajoules_per_g_carbon + methane_produced_g_carbon * parameters.anaerobic_combustion_energy_megajoules_per_g_carbon + methane_oxidized_g_carbon * parameters.methane_combustion_energy_megajoules_per_g_carbon,
        .aerobic_fraction_of_noncharcoal = if (noncharcoal_g > 0) aerobic_carbon_g / noncharcoal_g else 0,
        .anaerobic_fraction_of_noncharcoal = if (noncharcoal_g > 0) methane_produced_g_carbon / noncharcoal_g else 0,
        .combustion_temperature_response = combustion_temperature_response,
    };
    inline for (@typeInfo(CanopyFireResult).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteSubsurfaceFireResult;
    try validateOxygenPartition(result, parameters.oxygen_g_per_g_carbon);
    return result;
}

/// Adds all user-selected plant species into one cell's REDIST-facing totals.
/// Existing totals are retained, matching the additive EXTRACT transaction.
pub fn aggregate(layout: Layout, dynamic_salts: bool, first_subhour: bool, inputs: Inputs, totals: *Totals) !void {
    const litter_stride = try std.math.mul(usize, layout.biochemical_fraction_count, try std.math.mul(usize, layout.material_phase_count, layout.exchange_layer_count));
    const litter_count = try layout.litterValueCount();
    const total_litter_count = litter_stride;
    const salt_count = try std.math.mul(usize, layout.exchange_layer_count, 8);
    const manure_fraction_count = if (layout.biochemical_fraction_count < 4) layout.biochemical_fraction_count else 4;
    const manure_input_count = try std.math.mul(usize, layout.species_count, manure_fraction_count);
    if (inputs.litter_carbon_g.len != litter_count or inputs.litter_nitrogen_g.len != litter_count or inputs.litter_phosphorus_g.len != litter_count or totals.litter_carbon_g.len != total_litter_count or totals.litter_nitrogen_g.len != total_litter_count or totals.litter_phosphorus_g.len != total_litter_count or inputs.canopy_litter_carbon_g.len != layout.species_count or inputs.canopy_litter_nitrogen_g.len != layout.species_count or inputs.canopy_litter_phosphorus_g.len != layout.species_count or inputs.standing_dead_carbon_g.len != layout.species_count or inputs.litter_salt_mol.len != try std.math.mul(usize, layout.species_count, salt_count) or totals.litter_salt_mol.len != salt_count or inputs.manure_carbon_g_per_h.len != manure_input_count or inputs.manure_nitrogen_g_per_h.len != manure_input_count or inputs.manure_phosphorus_g_per_h.len != manure_input_count or totals.manure_carbon_g_per_h.len != manure_fraction_count or totals.manure_nitrogen_g_per_h.len != manure_fraction_count or totals.manure_phosphorus_g_per_h.len != manure_fraction_count or inputs.manure_inorganic_nitrogen_g_per_h.len != layout.species_count or inputs.manure_inorganic_phosphorus_g_per_h.len != layout.species_count) return error.PlantSoilExchangeDimensionMismatch;

    try validateFinite(inputs);
    for (0..layout.species_count) |species| {
        totals.canopy_litter_carbon_g += inputs.canopy_litter_carbon_g[species];
        totals.canopy_litter_nitrogen_g += inputs.canopy_litter_nitrogen_g[species];
        totals.canopy_litter_phosphorus_g += inputs.canopy_litter_phosphorus_g[species];
        totals.standing_dead_carbon_g += inputs.standing_dead_carbon_g[species];
        const litter_base = species * litter_stride;
        for (0..litter_stride) |index| {
            totals.litter_carbon_g[index] += inputs.litter_carbon_g[litter_base + index];
            totals.litter_nitrogen_g[index] += inputs.litter_nitrogen_g[litter_base + index];
            totals.litter_phosphorus_g[index] += inputs.litter_phosphorus_g[litter_base + index];
        }
        if (dynamic_salts) {
            for (0..salt_count) |index| totals.litter_salt_mol[index] += inputs.litter_salt_mol[species * salt_count + index];
        }
        if (first_subhour) {
            for (0..manure_fraction_count) |fraction| {
                const index = species * manure_fraction_count + fraction;
                totals.manure_carbon_g_per_h[fraction] += inputs.manure_carbon_g_per_h[index];
                totals.manure_nitrogen_g_per_h[fraction] += inputs.manure_nitrogen_g_per_h[index];
                totals.manure_phosphorus_g_per_h[fraction] += inputs.manure_phosphorus_g_per_h[index];
            }
            totals.manure_inorganic_nitrogen_g_per_h += inputs.manure_inorganic_nitrogen_g_per_h[species];
            totals.manure_inorganic_phosphorus_g_per_h += inputs.manure_inorganic_phosphorus_g_per_h[species];
        }
    }
    try validateTotals(totals.*);
}

fn validateFinite(inputs: Inputs) !void {
    inline for (.{ inputs.litter_carbon_g, inputs.litter_nitrogen_g, inputs.litter_phosphorus_g, inputs.canopy_litter_carbon_g, inputs.canopy_litter_nitrogen_g, inputs.canopy_litter_phosphorus_g, inputs.standing_dead_carbon_g, inputs.litter_salt_mol, inputs.manure_carbon_g_per_h, inputs.manure_nitrogen_g_per_h, inputs.manure_phosphorus_g_per_h, inputs.manure_inorganic_nitrogen_g_per_h, inputs.manure_inorganic_phosphorus_g_per_h }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantSoilExchange;
}

fn validateTotals(totals: Totals) !void {
    inline for (.{ totals.litter_carbon_g, totals.litter_nitrogen_g, totals.litter_phosphorus_g, totals.litter_salt_mol, totals.manure_carbon_g_per_h, totals.manure_nitrogen_g_per_h, totals.manure_phosphorus_g_per_h }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantSoilExchange;
    inline for (.{ totals.canopy_litter_carbon_g, totals.canopy_litter_nitrogen_g, totals.canopy_litter_phosphorus_g, totals.standing_dead_carbon_g, totals.manure_inorganic_nitrogen_g_per_h, totals.manure_inorganic_phosphorus_g_per_h }) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantSoilExchange;
}

test "extract aggregation accepts more than five plant species" {
    const layout: Layout = .{ .species_count = 7, .biochemical_fraction_count = 1, .material_phase_count = 1, .exchange_layer_count = 1 };
    const sevens = [_]f64{1} ** 7;
    const salts = [_]f64{1} ** 56;
    var litter_c = [_]f64{0};
    var litter_n = [_]f64{0};
    var litter_p = [_]f64{0};
    var total_salts = [_]f64{0} ** 8;
    var manure_c = [_]f64{0};
    var manure_n = [_]f64{0};
    var manure_p = [_]f64{0};
    var totals: Totals = .{ .litter_carbon_g = &litter_c, .litter_nitrogen_g = &litter_n, .litter_phosphorus_g = &litter_p, .canopy_litter_carbon_g = 0, .canopy_litter_nitrogen_g = 0, .canopy_litter_phosphorus_g = 0, .standing_dead_carbon_g = 0, .litter_salt_mol = &total_salts, .manure_carbon_g_per_h = &manure_c, .manure_nitrogen_g_per_h = &manure_n, .manure_phosphorus_g_per_h = &manure_p, .manure_inorganic_nitrogen_g_per_h = 0, .manure_inorganic_phosphorus_g_per_h = 0 };
    try aggregate(layout, true, true, .{ .litter_carbon_g = &sevens, .litter_nitrogen_g = &sevens, .litter_phosphorus_g = &sevens, .canopy_litter_carbon_g = &sevens, .canopy_litter_nitrogen_g = &sevens, .canopy_litter_phosphorus_g = &sevens, .standing_dead_carbon_g = &sevens, .litter_salt_mol = &salts, .manure_carbon_g_per_h = &sevens, .manure_nitrogen_g_per_h = &sevens, .manure_phosphorus_g_per_h = &sevens, .manure_inorganic_nitrogen_g_per_h = &sevens, .manure_inorganic_phosphorus_g_per_h = &sevens }, &totals);
    try std.testing.expectEqual(@as(f64, 7), totals.litter_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 7), totals.litter_salt_mol[7]);
    try std.testing.expectEqual(@as(f64, 7), totals.manure_inorganic_nitrogen_g_per_h);
}

test "extract canopy fire conserves carbon and oxygen bounds" {
    const result = try canopyFireCombustion(10, 1e-12, 600, 100_000, 12, 2, .{ .oxygen_half_saturation_umol_per_mol = 10_000, .methane_half_saturation_umol_per_mol = 1, .aerobic_combustion_energy_megajoules_per_g_carbon = 0.03, .anaerobic_combustion_energy_megajoules_per_g_carbon = 0.01, .methane_combustion_energy_megajoules_per_g_carbon = 0.05 });
    try std.testing.expectApproxEqAbs(@as(f64, 10), result.carbon_dioxide_emitted_g_carbon + result.methane_emitted_g_carbon + result.charcoal_produced_g_carbon, 1e-12);
    try std.testing.expect(result.oxygen_consumed_g <= 12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.aerobic_fraction_of_noncharcoal + result.anaerobic_fraction_of_noncharcoal, 1e-12);
    try std.testing.expect(result.heat_released_megajoules > 0);
}

test "EXTRACT canopy fire oxidizes newly produced methane without an ambient inventory cap" {
    const parameters: CanopyFireParameters = .{
        .oxygen_half_saturation_umol_per_mol = 1,
        .methane_half_saturation_umol_per_mol = 1,
        .aerobic_combustion_energy_megajoules_per_g_carbon = 0.03,
        .anaerobic_combustion_energy_megajoules_per_g_carbon = 0.01,
        .methane_combustion_energy_megajoules_per_g_carbon = 0.05,
    };
    const result = try canopyFireCombustion(10, 0, 600, 1_000_000, 100, 1_000_000, parameters);
    try std.testing.expect(result.carbon_dioxide_emitted_g_carbon > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 10), result.carbon_dioxide_emitted_g_carbon + result.methane_emitted_g_carbon + result.charcoal_produced_g_carbon, 1e-12);
}

test "TRNSFR subsurface fire conserves layer carbon oxygen methane and heat" {
    const result = try subsurfaceOrganicMatterFire(10, 1e-12, 0.25, 3, 8, 0.4, 0.2, .{
        .oxygen_half_saturation_g_o_per_m3 = 0.5,
        .methane_half_saturation_g_c_per_m3 = 0.1,
        .aerobic_combustion_energy_megajoules_per_g_carbon = 0.0375,
        .anaerobic_combustion_energy_megajoules_per_g_carbon = 0.0125,
        .methane_combustion_energy_megajoules_per_g_carbon = 0.0743,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 10), result.carbon_dioxide_emitted_g_carbon + result.methane_emitted_g_carbon + result.charcoal_produced_g_carbon, 1e-12);
    try std.testing.expect(result.oxygen_consumed_g <= 8);
    try std.testing.expect(result.carbon_dioxide_emitted_g_carbon >= 0);
    try std.testing.expect(result.methane_emitted_g_carbon >= 0);
    try std.testing.expect(result.charcoal_produced_g_carbon >= 0);
    try std.testing.expect(result.heat_released_megajoules > 0);
}

test "TRNSFR subsurface fire exports ROGOX and RC4OX consistently with the aggregate" {
    const parameters: SubsurfaceFireParameters = .{
        .oxygen_half_saturation_g_o_per_m3 = 0.5,
        .methane_half_saturation_g_c_per_m3 = 0.1,
        .aerobic_combustion_energy_megajoules_per_g_carbon = 0.0375,
        .anaerobic_combustion_energy_megajoules_per_g_carbon = 0.0125,
        .methane_combustion_energy_megajoules_per_g_carbon = 0.0743,
    };
    // Swept over regimes that select each arm of the source RC4OX three-way
    // AMIN1: methane-content limited, residual-oxygen limited, and kinetic.
    const cases = [_][4]f64{
        .{ 3, 8, 0.4, 0.2 },
        .{ 40, 1.0, 5.0, 0.001 },
        .{ 0.01, 0.05, 20.0, 50.0 },
        .{ 100, 500, 0.0, 0.0 },
    };
    for (cases) |c| {
        const result = try subsurfaceOrganicMatterFire(10, 1e-12, 0.25, c[0], c[1], c[2], c[3], parameters);
        // Tier 2: the exported parts reconstruct the only aggregate any gas
        // ledger debits. Nothing downstream may see a different total.
        try std.testing.expectApproxEqAbs(result.oxygen_consumed_g, result.oxygen_limited_uptake_g + result.methane_combustion_g_carbon * parameters.oxygen_g_per_g_carbon, 1e-12 * @max(1.0, result.oxygen_consumed_g));
        // Tier 1: both parts sit in a valid physical domain.
        try std.testing.expect(result.oxygen_limited_uptake_g >= 0);
        try std.testing.expect(result.methane_combustion_g_carbon >= 0);
        // Tier 2: neither part may exceed the inventory that supplies it. ROGOX
        // is capped by the oxygen present, RC4OX by the methane present and by
        // the oxygen the aerobic branch left behind.
        try std.testing.expect(result.oxygen_limited_uptake_g <= c[1] + 1e-12);
        try std.testing.expect(result.methane_combustion_g_carbon <= c[3] + 1e-12);
        try std.testing.expect(result.oxygen_consumed_g <= c[1] + 1e-12);
        // The aggregate identity the parts were split out of still holds.
        try std.testing.expectApproxEqAbs(result.carbon_dioxide_emitted_g_carbon, result.oxygen_limited_uptake_g / parameters.oxygen_g_per_g_carbon + result.methane_combustion_g_carbon, 1e-12);
        try std.testing.expectApproxEqAbs(@as(f64, 10), result.carbon_dioxide_emitted_g_carbon + result.methane_emitted_g_carbon + result.charcoal_produced_g_carbon, 1e-12);
    }
}

test "fire oxygen partition rejects parts that do not reconstruct the aggregate" {
    // The guard is the reason the export cannot silently drift; assert it fires.
    try std.testing.expectError(error.FireOxygenPartitionMismatch, validateOxygenPartition(.{ .oxygen_consumed_g = 10, .oxygen_limited_uptake_g = 1, .methane_combustion_g_carbon = 0, .carbon_dioxide_emitted_g_carbon = 0, .methane_emitted_g_carbon = 0, .charcoal_produced_g_carbon = 0, .charcoal_fraction_of_combusted_carbon = 0, .heat_released_megajoules = 0, .aerobic_fraction_of_noncharcoal = 0, .anaerobic_fraction_of_noncharcoal = 0, .combustion_temperature_response = 0 }, 2.667));
    try std.testing.expectError(error.NegativeFireOxygenPartition, validateOxygenPartition(.{ .oxygen_consumed_g = 0, .oxygen_limited_uptake_g = -1, .methane_combustion_g_carbon = 1.0 / 2.667, .carbon_dioxide_emitted_g_carbon = 0, .methane_emitted_g_carbon = 0, .charcoal_produced_g_carbon = 0, .charcoal_fraction_of_combusted_carbon = 0, .heat_released_megajoules = 0, .aerobic_fraction_of_noncharcoal = 0, .anaerobic_fraction_of_noncharcoal = 0, .combustion_temperature_response = 0 }, 2.667));
}

test "subsurface fire below the negligible carbon threshold exports zero parts" {
    const result = try subsurfaceOrganicMatterFire(0, 1e-12, 0.25, 3, 8, 0.4, 0.2, .{
        .oxygen_half_saturation_g_o_per_m3 = 0.5,
        .methane_half_saturation_g_c_per_m3 = 0.1,
        .aerobic_combustion_energy_megajoules_per_g_carbon = 0.0375,
        .anaerobic_combustion_energy_megajoules_per_g_carbon = 0.0125,
        .methane_combustion_energy_megajoules_per_g_carbon = 0.0743,
    });
    try std.testing.expectEqual(@as(f64, 0), result.oxygen_limited_uptake_g);
    try std.testing.expectEqual(@as(f64, 0), result.methane_combustion_g_carbon);
    try std.testing.expectEqual(@as(f64, 0), result.oxygen_consumed_g);
}

test "extract plant pool combustion conserves carbon nitrogen and phosphorus" {
    const canopy = try canopyFireCombustion(10, 0, 600, 100_000, 12, 2, .{ .oxygen_half_saturation_umol_per_mol = 10_000, .methane_half_saturation_umol_per_mol = 1, .aerobic_combustion_energy_megajoules_per_g_carbon = 0.03, .anaerobic_combustion_energy_megajoules_per_g_carbon = 0.01, .methane_combustion_energy_megajoules_per_g_carbon = 0.05 });
    const salts = [_]f64{1} ** 16;
    const result = try combustPlantPools(&.{ 3, 7 }, &.{ 0.2, 0.3 }, &.{ 0.04, 0.06 }, &salts, true, 0.25, canopyPlantCombustionFractions(canopy));
    try std.testing.expectApproxEqAbs(@as(f64, 10), result.carbon_dioxide_g_carbon + result.methane_g_carbon + result.charcoal_g_carbon, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.gaseous_nitrogen_g + result.ammonium_nitrogen_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result.gaseous_phosphorus_g + result.phosphate_phosphorus_g, 1e-12);
    try std.testing.expectEqual(@as(f64, 2), result.released_salt_mol[0]);
}

test "extract root combustion uses layer aerobic and anaerobic limits" {
    const fractions = (try rootPlantCombustionFractions(10, 6, 2, 1e-12)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), fractions.charcoal, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), fractions.aerobic_noncharcoal, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), fractions.anaerobic_noncharcoal, 1e-12);
    const salts = [_]f64{0} ** 8;
    const result = try combustPlantPools(&.{10}, &.{1}, &.{0.2}, &salts, false, 0.5, fractions);
    try std.testing.expectApproxEqAbs(@as(f64, 10), result.carbon_dioxide_g_carbon + result.methane_g_carbon + result.charcoal_g_carbon, 1e-12);
}

test "extract root exchange cancels internal gas phase transfer" {
    const atmosphere = [_]f64{ 3, 4 };
    const dissolved = [_]f64{ 1, 2 };
    const biological = [_]f64{ 0.5, -0.5 };
    var gaseous_backing: [root_gas_count][2]f64 = @splat(@splat(0));
    var aqueous_backing: [root_gas_count][2]f64 = @splat(@splat(0));
    var totals_backing: [root_gas_count][1]f64 = @splat(@splat(0));
    var gaseous: [root_gas_count][]f64 = undefined;
    var aqueous: [root_gas_count][]f64 = undefined;
    var gas_totals: [root_gas_count][]f64 = undefined;
    var atmosphere_inputs: [root_gas_count][]const f64 = undefined;
    var dissolved_inputs: [root_gas_count][]const f64 = undefined;
    var biological_inputs: [root_gas_count][]const f64 = undefined;
    for (0..root_gas_count) |gas| {
        gaseous[gas] = &gaseous_backing[gas];
        aqueous[gas] = &aqueous_backing[gas];
        gas_totals[gas] = &totals_backing[gas];
        atmosphere_inputs[gas] = &atmosphere;
        dissolved_inputs[gas] = &dissolved;
        biological_inputs[gas] = &biological;
    }
    var density = [_]f64{0};
    var water = [_]f64{0};
    var heat = [_]f64{0};
    var state: RootExchangeState = .{ .gaseous_content_g = gaseous, .aqueous_content_g = aqueous, .total_content_by_layer_g = gas_totals, .total_root_length_density_m_per_m3 = &density, .total_water_uptake_m3_per_h = &water, .convective_water_heat_megajoules_per_h = &heat };
    try aggregateRootExchange(2, 1, 10, &.{2}, &.{280}, .{ .root_length_density_per_plant_m_per_m3 = &.{ 4, 9 }, .water_uptake_m3_per_h = &.{ 0.1, 0.2 }, .gaseous_atmosphere_exchange_g_per_h = atmosphere_inputs, .aqueous_to_gaseous_exchange_g_per_h = dissolved_inputs, .aqueous_biological_change_g_per_h = biological_inputs }, &state);
    try std.testing.expectApproxEqAbs(@as(f64, 7), state.total_content_by_layer_g[@intFromEnum(RootGas.carbon_dioxide)][0], 1e-12);
    try std.testing.expectEqual(@as(f64, 20), density[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), water[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3 * 4.19 * 280), heat[0], 1e-12);
}

test "extract root boundary solute salt and exudate totals preserve signs" {
    var flux_backing: [root_boundary_flux_count][2]f64 = @splat(.{ 1, 2 });
    var total_backing: [root_boundary_flux_count][1]f64 = @splat(@splat(0));
    var fluxes: [root_boundary_flux_count][]const f64 = undefined;
    var totals: [root_boundary_flux_count][]f64 = undefined;
    for (0..root_boundary_flux_count) |flux| {
        fluxes[flux] = &flux_backing[flux];
        totals[flux] = &total_backing[flux];
    }
    try aggregateRootBoundaryFluxes(2, 1, fluxes, totals);
    try std.testing.expectEqual(@as(f64, 3), totals[@intFromEnum(RootBoundaryFlux.atmospheric_oxygen_g_per_h)][0]);
    try std.testing.expectEqual(@as(f64, -3), totals[@intFromEnum(RootBoundaryFlux.aqueous_carbon_dioxide_production_g_per_h)][0]);

    const salt_uptake = [_]f64{1} ** 16;
    var salt_totals = [_]f64{0} ** 8;
    try aggregateRootSaltUptake(2, 1, true, &salt_uptake, &salt_totals);
    try std.testing.expectEqual(@as(f64, 2), salt_totals[7]);

    const exudates = [_]f64{ 1, 2, 3, 4 };
    var carbon = [_]f64{ 10, 10 };
    var nitrogen = [_]f64{ 10, 10 };
    var phosphorus = [_]f64{ 10, 10 };
    try aggregateRootExudation(2, 1, 2, &exudates, &exudates, &exudates, &carbon, &nitrogen, &phosphorus);
    try std.testing.expectEqualSlices(f64, &.{ 6, 4 }, &carbon);
    try std.testing.expectEqualSlices(f64, &carbon, &nitrogen);
    try std.testing.expectEqualSlices(f64, &carbon, &phosphorus);
}

test "extract competition fixation and final species balances aggregate dynamically" {
    var demand_backing: [competition_demand_count][2]f64 = @splat(.{ 1, 2 });
    var shared_backing: [competition_demand_count][1]f64 = @splat(@splat(0));
    var demand: [competition_demand_count][]const f64 = undefined;
    var shared: [competition_demand_count][]f64 = undefined;
    for (0..competition_demand_count) |index| {
        demand[index] = &demand_backing[index];
        shared[index] = &shared_backing[index];
    }
    try aggregateCompetitionDemand(2, 1, demand, shared);
    try std.testing.expectEqual(@as(f64, 3), shared[@intFromEnum(CompetitionDemand.band_nitrate_g_nitrogen_per_h)][0]);
    var fixation = [_]f64{ 0, 0 };
    try aggregateRootNitrogenFixation(3, 2, &.{ 1, 2, 3, 4, 5, 6 }, &fixation);
    try std.testing.expectEqualSlices(f64, &.{ 9, 12 }, &fixation);

    const values = [_]f64{ 2, 3 };
    const gas_losses: [root_gas_count][]const f64 = @splat(&values);
    var species_ammonia = [_]f64{ 0, 0 };
    var balance_totals: SpeciesBalanceTotals = std.mem.zeroes(SpeciesBalanceTotals);
    const inputs: SpeciesBalanceInputs = .{ .hourly_canopy_carbon_fixation_g_per_h = &values, .canopy_carbon_exchange_g_per_h = &values, .leaf_area_m2 = &values, .stalk_area_m2 = &values, .root_soil_carbon_exchange_g_per_h = &values, .root_soil_nitrogen_exchange_g_per_h = &values, .root_soil_phosphorus_exchange_g_per_h = &values, .carbon_balance_g = &values, .nitrogen_balance_g = &values, .phosphorus_balance_g = &values, .root_gas_loss_g_per_h = gas_losses, .branch_ammonia_exchange_g_nitrogen_per_h = &.{ 1, 2, 3 }, .branch_count_by_species = &.{ 1, 2 } };
    try aggregateSpeciesBalances(2, true, 2.667, inputs, &species_ammonia, &balance_totals);
    try std.testing.expectEqual(@as(f64, 5), balance_totals.hourly_canopy_carbon_fixation_g_per_h);
    try std.testing.expectApproxEqAbs(@as(f64, -13.335), balance_totals.canopy_oxygen_exchange_g_per_h, 1e-12);
    try std.testing.expectEqualSlices(f64, &.{ 1, 5 }, &species_ammonia);
    try std.testing.expectEqual(@as(f64, -5), balance_totals.root_soil_nitrogen_exchange_g_per_h);
}

test "extract canopy transfers aggregate runtime species and active leaf areas" {
    var dead_area = [_]f64{ 0, 0 };
    var leaf_area = [_]f64{ 0, 0 };
    var leaf_carbon = [_]f64{ 0, 0 };
    var stalk_area = [_]f64{ 0, 0 };
    var previous_energy = [_]f64{ 1, 2, 3 };
    var totals: CanopyTransferTotals = .{ .standing_dead_area_m2 = &dead_area, .leaf_area_m2 = &leaf_area, .leaf_carbon_g = &leaf_carbon, .stalk_area_m2 = &stalk_area, .standing_dead_ground_area_m2 = 0, .net_radiation_megajoules_per_h = 0, .latent_heat_flux_megajoules_per_h = 0, .sensible_heat_flux_megajoules_per_h = 0, .storage_heat_flux_megajoules_per_h = 0, .transpiration_and_evaporation_m3_per_h = 0, .internal_water_m3 = 0, .surface_water_m3 = 0, .evaporation_m3_per_h = 0, .water_energy_megajoules = 0, .water_energy_change_megajoules_per_h = 0 };
    const layered = [_]f64{ 1, 2, 3, 4, 5, 6 };
    const species_values = [_]f64{ 1, 2, 3 };
    const zero_species = [_]f64{ 0, 0, 0 };
    try aggregateHourlyCanopyTransfers(3, 2, 280, .{ .active = &.{ true, false, true }, .standing_dead_area_m2 = &layered, .leaf_area_m2 = &layered, .leaf_carbon_g = &layered, .stalk_area_m2 = &layered, .standing_dead_ground_area_m2 = &species_values, .net_radiation_megajoules_per_h = &species_values, .latent_heat_flux_megajoules_per_h = &species_values, .sensible_heat_flux_megajoules_per_h = &species_values, .storage_heat_flux_megajoules_per_h = &species_values, .convective_heat_flux_megajoules_per_h = &zero_species, .transpiration_m3_per_h = &zero_species, .evaporation_m3_per_h = &zero_species, .internal_water_m3 = &species_values, .surface_water_m3 = &zero_species, .standing_dead_surface_water_m3 = &zero_species, .retained_foliar_water_m3_per_h = &.{ 1, 0, 0 }, .retained_standing_dead_water_m3_per_h = &zero_species, .canopy_temperature_k = &.{ 280, 281, 282 } }, &previous_energy, &totals);
    try std.testing.expectEqual(@as(f64, 9), totals.standing_dead_area_m2[0]);
    try std.testing.expectEqual(@as(f64, 6), totals.leaf_area_m2[0]);
    try std.testing.expectEqual(@as(f64, 6), totals.net_radiation_megajoules_per_h);
    try std.testing.expectEqual(@as(f64, -6), totals.storage_heat_flux_megajoules_per_h);
    try std.testing.expectApproxEqAbs(@as(f64, 4.19 * 280), totals.water_energy_megajoules, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -6), totals.water_energy_change_megajoules_per_h, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), previous_energy[2]);
}

test "EXTRACT hourly canopy water energy publishes post-state_update runtime species and persists ENGYX" {
    var previous = [_]f64{ 100, 200, 300, 400, 500, 600, 700 };
    var total = [_]f64{0};
    var change = [_]f64{0};
    try refreshHourlyCanopyWaterEnergy(
        7,
        &.{280},
        &.{ 281, 282, 283, 284, 285, 286, 287 },
        &.{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7 },
        &.{ 0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07 },
        &.{ 0.001, 0.002, 0.003, 0.004, 0.005, 0.006, 0.007 },
        &.{ 0.0001, 0.0002, 0.0003, 0.0004, 0.0005, 0.0006, 0.0007 },
        &previous,
        &total,
        &change,
    );
    var expected_total: f64 = 0;
    var expected_change: f64 = 0;
    for (0..7) |plant| {
        const current = 4.19 * (0.11 * @as(f64, @floatFromInt(plant + 1))) * @as(f64, @floatFromInt(281 + plant));
        const incoming = 4.19 * (0.0011 * @as(f64, @floatFromInt(plant + 1))) * 280;
        expected_total += current;
        expected_change += current - 100 * @as(f64, @floatFromInt(plant + 1)) - incoming;
        try std.testing.expectApproxEqAbs(current, previous[plant], 1e-12);
    }
    try std.testing.expectApproxEqAbs(expected_total, total[0], 1e-12);
    try std.testing.expectApproxEqAbs(expected_change, change[0], 1e-12);
}

test "UPTAKE canopy ammonia exchange preserves gradient and mobile pool bounds" {
    const common: CanopyAmmoniaExchangeInputs = .{
        .parameters = compatibilityCanopyAmmoniaExchangeParameters(),
        .atmospheric_ammonia_g_n_per_m3 = 2.0e-4,
        .canopy_temperature_c = 25,
        .ammonia_solubility_at_25_c = 0.8,
        .canopy_dry_matter_fraction = 0.4,
        .branch_mobile_nitrogen_concentration_g_n_per_g_c = 0.02,
        .branch_mobile_nitrogen_g_n = 1,
        .branch_live_structural_carbon_g_c = 2,
        .branch_leaf_area_m2 = 3,
        .plant_leaf_area_m2 = 6,
        .total_aerodynamic_resistance_h_per_m = 0.01,
        .stomatal_resistance_h_per_m = 0.02,
        .plant_radiation_fraction = 0.5,
        .cell_area_m2 = 1,
        .timestep_h = 1,
        .negligible_carbon_g_c = 1.0e-12,
    };
    try std.testing.expect(try canopyAmmoniaExchangeGNPerStep(common) > 0);
    var emitting = common;
    emitting.atmospheric_ammonia_g_n_per_m3 = 0;
    try std.testing.expect(try canopyAmmoniaExchangeGNPerStep(emitting) < 0);
    var bounded = common;
    bounded.atmospheric_ammonia_g_n_per_m3 = 1;
    bounded.branch_mobile_nitrogen_g_n = 0.01;
    try std.testing.expectApproxEqAbs(@as(f64, 0.001), try canopyAmmoniaExchangeGNPerStep(bounded), 1.0e-15);
    var leafless = common;
    leafless.branch_leaf_area_m2 = 0;
    try std.testing.expectEqual(@as(f64, 0), try canopyAmmoniaExchangeGNPerStep(leafless));
    try std.testing.expectApproxEqAbs(@as(f64, 0.16), try canopyDryMatterFraction(0, common.parameters), 1.0e-15);
    try std.testing.expect(try canopyDryMatterFraction(-2, common.parameters) > 0.16);
}
