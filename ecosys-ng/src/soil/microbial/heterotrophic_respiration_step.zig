const std = @import("std");
const compute = @import("../../core/compute.zig");
const gas = @import("../gas/transport.zig");
const grid = @import("../../state/grid.zig");
const organic = @import("../organic/initialization.zig");
const microbial = @import("state.zig");
const metabolism = @import("metabolism.zig");
const respiration = @import("respiration_activity.zig");
const reactive = @import("../nutrients/reactive_nitrogen_state.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const nitrogen_parameters = @import("../nutrients/nitrogen_parameters.zig");
const anaerobic = @import("anaerobic_growth_respiration.zig");
const retention = @import("../water/retention.zig");

pub const ApplyContext = struct {
    result: *fluxes.State,
    reactive_nitrogen: *const reactive.State,
    organic_state: *const organic.State,
    microbial_state: *const microbial.State,
    model_grid: *const grid.GridState,
    retention_curve: []const retention.ResolvedCurve,
    matrix_bulk_volume_m3: []const f64,
    matric_plus_osmotic_potential_megapascal: []const f64,
    thermal_adaptation_offset_k_by_cell: []const f64,
    /// Authoritative aqueous gas owner for source `CH2GS`, the
    /// aqueous hydrogen concentration that drives the `NITRO.F` 918 fermenter
    /// energy feedback. Read-only; this step never publishes a gas field.
    /// Source ECHZ is mandatory runtime science, so this owner is mandatory.
    gas_state: *const gas.State,
    /// Authoritative liquid water owner used as the aqueous concentration
    /// basis, matching `soil_methane_step`'s `water_volume_m3`. When absent,
    /// `model_grid.matrix_liquid_water_m3` is used, which is the same field
    /// production passes.
    aqueous_water_volume_m3: ?[]const f64 = null,
    parameters: nitrogen_parameters.Parameters,
    timestep_h: f64,
    negligible_carbon_g_c: f64,
};

/// Source `NITRO.F` 924--928 and 1003--1004 growth respiration requirements
/// for the two anaerobic branches this step owns.
///
/// `soil_heterotrophic_respiration_step` remains the sole writer of the
/// anaerobic publish set. This only replaces the two scalar requirements that
/// multiply the supply limit, per
/// `docs/traceability/bind_nitro_001_double_mutation_analysis.md`.
const AnaerobicRequirements = struct {
    fermenter_g_c_per_g_c: f64,
    anaerobic_diazotroph_g_c_per_g_c: f64,
    acetotrophic_methanogen_g_c_per_g_c: f64,
};

/// Exact source order: `GH2X` at `NITRO.F` 556--557 is computed once per layer,
/// before the substrate and population loops that consume it at 918 and 1317.
fn layerHydrogenFeedback_kilojoule_per_mol(
    context: ApplyContext,
    layer: usize,
) !f64 {
    const water_m3 = if (context.aqueous_water_volume_m3) |volumes|
        volumes[layer]
    else
        context.model_grid.matrix_liquid_water_m3[layer];
    const concentration_g_h_per_m3 = blk: {
        if (!(water_m3 > 0)) break :blk 0;
        const index = try gas.massIndex(layer, .hydrogen, context.gas_state.cell_count);
        break :blk context.gas_state.dissolved_mass_g[index] / water_m3;
    };
    return try anaerobic.hydrogenFeedbackEnergy_kilojoule_per_mol(
        context.model_grid.soil_temperature_k[layer],
        concentration_g_h_per_m3,
        anaerobic.source_feedback_environment,
    );
}

/// Source `NITRO.F` 325, `OXYI`: layer-level O2 inhibition of fermentation,
/// computed once per layer exactly like `GH2X` above, before the substrate
/// and population loops that consume it at source line 960. `gas_state` is
/// the authoritative aqueous O2 owner; production always supplies it (see
/// `stages/biogeochemistry_batches.zig`). Isolated tests that omit it fall
/// back to no suppression (`OXYI` acts as if aqueous O2 were absent from the
/// model, i.e. unsuppressed), which reproduces this step's pre-existing
/// behaviour rather than manufacturing an unowned anoxic assumption.
fn layerFermentationOxygenInhibition(context: ApplyContext, layer: usize) !f64 {
    const water_m3 = if (context.aqueous_water_volume_m3) |volumes|
        volumes[layer]
    else
        context.model_grid.matrix_liquid_water_m3[layer];
    if (!(water_m3 > 0)) return 1;
    const index = try gas.massIndex(layer, .oxygen, context.gas_state.cell_count);
    const concentration_g_o_per_m3 = context.gas_state.dissolved_mass_g[index] / water_m3;
    return try metabolism.fermentationOxygenInhibition(concentration_g_o_per_m3);
}

fn anaerobicRequirements(
    context: ApplyContext,
    layer: usize,
    hydrogen_feedback_kilojoule_per_mol: f64,
    aqueous_acetate_concentration_g_c_per_m3: f64,
) !AnaerobicRequirements {
    const energy = context.parameters.anaerobic_growth_energy;
    const temperature_k = context.model_grid.soil_temperature_k[layer];
    const feedback = try anaerobic.fermenterFeedback(
        temperature_k,
        aqueous_acetate_concentration_g_c_per_m3,
        hydrogen_feedback_kilojoule_per_mol,
        anaerobic.source_feedback_environment,
        anaerobic.source_carbon_basis,
    );
    return .{
        .fermenter_g_c_per_g_c = try anaerobic.fermenterRequirement_g_c_per_g_c(
            energy,
            feedback,
            .fermenter,
        ),
        .anaerobic_diazotroph_g_c_per_g_c = try anaerobic.fermenterRequirement_g_c_per_g_c(
            energy,
            feedback,
            .anaerobic_diazotroph,
        ),
        .acetotrophic_methanogen_g_c_per_g_c = try anaerobic.acetotrophicRequirement_g_c_per_g_c(
            energy,
            try anaerobic.acetotrophicFeedback_kilojoule_per_g_c(
                temperature_k,
                aqueous_acetate_concentration_g_c_per_m3,
                anaerobic.source_feedback_environment,
                anaerobic.source_carbon_basis,
            ),
        ),
    };
}

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const population_count = context.microbial_state.population_count;
    const substrate_count = @min(context.microbial_state.substrate_count, organic.substrate_count);
    const units_per_layer = context.result.process_unit_count_per_layer;
    for (range.first..range.end) |layer| {
        const active_water_m3 = try biologicallyActiveWaterM3(context.*, layer);
        context.result.layer_biologically_active_water_m3[layer] = active_water_m3;
        // Source NITRO.F 556--557, once per layer before the K and N loops.
        const layer_hydrogen_feedback_kilojoule_per_mol = try layerHydrogenFeedback_kilojoule_per_mol(context.*, layer);
        // Source NITRO.F 325 (OXYI), once per layer before the K and N loops.
        const layer_oxygen_inhibition = try layerFermentationOxygenInhibition(context.*, layer);
        var total_colonized_g_c: f64 = 0;
        for (0..substrate_count) |substrate| total_colonized_g_c += colonizedAndSorbedCarbon(context.organic_state, layer, substrate);
        for (0..substrate_count) |substrate| {
            if (substrate == context.parameters.nitrifier_indices.autotrophic_substrate_index) continue;
            var total_active_g_c: f64 = 0;
            var total_previous_doc_g_c: f64 = 0;
            var total_previous_acetate_g_c: f64 = 0;
            for (0..population_count) |population| {
                const unit = layer * units_per_layer + substrate * population_count + population;
                const runtime_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
                total_active_g_c += context.microbial_state.structural[runtime_index * 2].carbon_g_c / context.parameters.nitrifier_environment.labile_biomass_fraction;
                total_previous_doc_g_c += context.reactive_nitrogen.previous_doc_respiration_demand_g_c[unit];
                total_previous_acetate_g_c += context.reactive_nitrogen.previous_acetate_respiration_demand_g_c[unit];
            }
            var total_doc_share: f64 = 0;
            var total_acetate_share: f64 = 0;
            for (0..population_count) |population| {
                const unit = layer * units_per_layer + substrate * population_count + population;
                const runtime_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
                const active_biomass_g_c = context.microbial_state.structural[runtime_index * 2].carbon_g_c / context.parameters.nitrifier_environment.labile_biomass_fraction;
                const active_fraction = if (total_active_g_c > context.negligible_carbon_g_c) active_biomass_g_c / total_active_g_c else 0;
                total_doc_share += competition(context.reactive_nitrogen.previous_doc_respiration_demand_g_c[unit], total_previous_doc_g_c, active_fraction, context.parameters.denitrification.minimum_competition_fraction, context.negligible_carbon_g_c);
                total_acetate_share += competition(context.reactive_nitrogen.previous_acetate_respiration_demand_g_c[unit], total_previous_acetate_g_c, active_fraction, context.parameters.denitrification.minimum_competition_fraction, context.negligible_carbon_g_c);
            }
            for (0..population_count) |population| {
                const unit = layer * units_per_layer + substrate * population_count + population;
                const runtime_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
                const labile = context.microbial_state.structural[runtime_index * 2];
                const active_biomass_g_c = labile.carbon_g_c / context.parameters.nitrifier_environment.labile_biomass_fraction;
                const active_fraction = if (total_active_g_c > context.negligible_carbon_g_c) active_biomass_g_c / total_active_g_c else 0;
                const doc_share = normalizedCompetition(competition(context.reactive_nitrogen.previous_doc_respiration_demand_g_c[unit], total_previous_doc_g_c, active_fraction, context.parameters.denitrification.minimum_competition_fraction, context.negligible_carbon_g_c), total_doc_share);
                const acetate_share = normalizedCompetition(competition(context.reactive_nitrogen.previous_acetate_respiration_demand_g_c[unit], total_previous_acetate_g_c, active_fraction, context.parameters.denitrification.minimum_competition_fraction, context.negligible_carbon_g_c), total_acetate_share);
                const parameters = context.parameters.heterotrophic_respiration;
                const actual_n = if (labile.carbon_g_c > 0) labile.nitrogen_g_n / labile.carbon_g_c else parameters.target_nitrogen_per_carbon_g_n_per_g_c;
                const actual_p = if (labile.carbon_g_c > 0) labile.phosphorus_g_p / labile.carbon_g_c else parameters.target_phosphorus_per_carbon_g_p_per_g_c;
                const nutrient = @min(@min(1, @max(0.1, std.math.pow(f64, actual_n / parameters.target_nitrogen_per_carbon_g_n_per_g_c, 0.25))), @min(1, @max(0.1, std.math.pow(f64, actual_p / parameters.target_phosphorus_per_carbon_g_p_per_g_c, 0.25))));
                // NITRO.F 593--604: WFNG uses the fungal-specific 0.05 MPa-1
                // sensitivity only for the fungal population (source N=3,
                // this codebase's population index 2) within the
                // heterotrophic substrate complexes (source K<=4). The
                // autotrophic complex (K=5) is excluded from this loop above,
                // so substrate is always a heterotrophic complex here.
                const is_fungus = population == 2;
                const water_sensitivity_per_megapascal: f64 = if (is_fungus) 0.05 else parameters.water_potential_sensitivity_per_megapascal;
                const water = @exp(water_sensitivity_per_megapascal * context.matric_plus_osmotic_potential_megapascal[layer]);
                const unlimited = parameters.substrate_unlimited_respiration_per_h * nutrient * water * active_biomass_g_c * context.timestep_h;
                const substrate_carbon_g_c = colonizedAndSorbedCarbon(context.organic_state, layer, substrate);
                const substrate_fraction = if (total_colonized_g_c > context.negligible_carbon_g_c) substrate_carbon_g_c / total_colonized_g_c else 1;
                const mobile = layer * organic.substrate_count + substrate;
                const population_metabolism = respiration.sourceMetabolism(population);
                const temperature_response = try metabolism.growthTemperatureResponse(context.model_grid.soil_temperature_k[layer], context.thermal_adaptation_offset_k_by_cell[layer / context.microbial_state.layer_count]);
                const effective_water_m3 = active_water_m3 * substrate_fraction;
                const concentration_water_m3 = if (effective_water_m3 > 0) effective_water_m3 else active_water_m3;
                if (population_metabolism == .fermenting_heterotroph) {
                    const doc_concentration_g_c_per_m3 = if (concentration_water_m3 > 0) context.organic_state.dissolved[mobile].carbon_g_c / concentration_water_m3 else 0;
                    const acetate_concentration_g_c_per_m3 = if (concentration_water_m3 > 0) context.organic_state.dissolved_acetate_carbon_g_c[mobile] / concentration_water_m3 else 0;
                    // Source NITRO.F 960: `FSBST=COQC/(COQC+OQKM)*OXYI`. OXYI
                    // suppresses fermentation (and the anaerobic diazotroph
                    // branch, source N=7) toward 0 as the layer's aqueous O2
                    // rises, so a well-aerated layer shuts this pathway down.
                    const doc_demand_g_c = unlimited * doc_concentration_g_c_per_m3 / (doc_concentration_g_c_per_m3 + parameters.doc_half_saturation_g_c_per_m3) * layer_oxygen_inhibition * temperature_response;
                    // Source NITRO.F 924--928: ECHZ is a function of the H2
                    // plus acetate product energy, and the N=7 anaerobic
                    // diazotroph has a different floor and energy requirement
                    // from the N=4 fermenter.
                    const requirements = try anaerobicRequirements(context.*, layer, layer_hydrogen_feedback_kilojoule_per_mol, acetate_concentration_g_c_per_m3);
                    const is_anaerobic_diazotroph = population == context.parameters.nonsymbiotic_nitrogen_fixation.anaerobic_diazotroph_population_index;
                    const respiration_requirement = if (is_anaerobic_diazotroph)
                        requirements.anaerobic_diazotroph_g_c_per_g_c
                    else
                        requirements.fermenter_g_c_per_g_c;
                    const doc_supply_g_c = context.organic_state.dissolved[mobile].carbon_g_c * doc_share * respiration_requirement * context.timestep_h;
                    const doc_respiration_g_c = @min(doc_supply_g_c, doc_demand_g_c);
                    context.result.substrate_unlimited_respiration_g_c[unit] = unlimited;
                    context.result.doc_respiration_demand_g_c[unit] = doc_respiration_g_c;
                    context.result.acetate_respiration_demand_g_c[unit] = 0;
                    context.result.substrate_limited_respiration_g_c[unit] = doc_respiration_g_c;
                    context.result.aerobic_oxygen_demand_g_o[unit] = 0;
                    context.result.aerobic_active_biomass_g_c[unit] = active_biomass_g_c;
                    context.result.aerobic_fallback_active_fraction[unit] = active_fraction;
                    context.result.doc_competition_fraction[unit] = doc_share;
                    context.result.substrate_complex_fraction[unit] = substrate_fraction;
                    continue;
                }
                if (population_metabolism == .acetotrophic_methanogen) {
                    const acetate_concentration_g_c_per_m3 = if (concentration_water_m3 > 0) context.organic_state.dissolved_acetate_carbon_g_c[mobile] / concentration_water_m3 else 0;
                    const acetate_demand_g_c = unlimited * acetate_concentration_g_c_per_m3 / (acetate_concentration_g_c_per_m3 + parameters.acetate_half_saturation_g_c_per_m3) * temperature_response;
                    // Source NITRO.F 1003--1004. The acetate feedback ADDS to
                    // GC4X here where the fermenter branch subtracts it.
                    const requirements = try anaerobicRequirements(context.*, layer, layer_hydrogen_feedback_kilojoule_per_mol, acetate_concentration_g_c_per_m3);
                    const acetate_supply_g_c = context.organic_state.dissolved_acetate_carbon_g_c[mobile] * acetate_share * requirements.acetotrophic_methanogen_g_c_per_g_c * context.timestep_h;
                    const acetate_respiration_g_c = @min(acetate_supply_g_c, acetate_demand_g_c);
                    context.result.substrate_unlimited_respiration_g_c[unit] = 0;
                    context.result.doc_respiration_demand_g_c[unit] = 0;
                    context.result.acetate_respiration_demand_g_c[unit] = acetate_respiration_g_c;
                    context.result.substrate_limited_respiration_g_c[unit] = acetate_respiration_g_c;
                    context.result.aerobic_oxygen_demand_g_o[unit] = 0;
                    context.result.aerobic_active_biomass_g_c[unit] = active_biomass_g_c;
                    context.result.aerobic_fallback_active_fraction[unit] = active_fraction;
                    context.result.doc_competition_fraction[unit] = doc_share;
                    context.result.substrate_complex_fraction[unit] = substrate_fraction;
                    continue;
                }
                const aerobic_inputs: respiration.AerobicSubstrateInputs = .{
                    .unlimited_respiration_g_c = unlimited,
                    .dissolved_organic_carbon_g_c = context.organic_state.dissolved[mobile].carbon_g_c,
                    .dissolved_acetate_carbon_g_c = context.organic_state.dissolved_acetate_carbon_g_c[mobile],
                    .biologically_active_water_m3 = active_water_m3,
                    .substrate_complex_fraction = substrate_fraction,
                    .doc_half_saturation_g_c_per_m3 = parameters.doc_half_saturation_g_c_per_m3,
                    .acetate_half_saturation_g_c_per_m3 = parameters.acetate_half_saturation_g_c_per_m3,
                    .doc_biological_demand_fraction = doc_share,
                    .acetate_biological_demand_fraction = acetate_share,
                    .doc_respiration_requirement_g_c_per_g_c = parameters.doc_respiration_requirement_g_c_per_g_c,
                    .acetate_respiration_requirement_g_c_per_g_c = parameters.acetate_respiration_requirement_g_c_per_g_c,
                    .temperature_response = temperature_response,
                    .timestep_h = context.timestep_h,
                };
                const limited = respiration.aerobicSubstrateLimitedRespiration(aerobic_inputs) catch |err| {
                    std.log.err(
                        "invalid soil aerobic substrate inputs: layer={d} substrate={d} population={d} unlimited_g_c={e} doc_g_c={e} acetate_g_c={e} active_water_m3={e} substrate_fraction={e} doc_share={e} acetate_share={e} temperature_response={e}",
                        .{ layer, substrate, population, aerobic_inputs.unlimited_respiration_g_c, aerobic_inputs.dissolved_organic_carbon_g_c, aerobic_inputs.dissolved_acetate_carbon_g_c, aerobic_inputs.biologically_active_water_m3, aerobic_inputs.substrate_complex_fraction, aerobic_inputs.doc_biological_demand_fraction, aerobic_inputs.acetate_biological_demand_fraction, aerobic_inputs.temperature_response },
                    );
                    return err;
                };
                context.result.substrate_unlimited_respiration_g_c[unit] = unlimited;
                context.result.doc_respiration_demand_g_c[unit] = limited.doc_respiration_g_c;
                context.result.acetate_respiration_demand_g_c[unit] = limited.acetate_respiration_g_c;
                context.result.substrate_limited_respiration_g_c[unit] = limited.substrate_limited_respiration_g_c;
                context.result.aerobic_oxygen_demand_g_o[unit] = parameters.oxygen_per_respired_carbon_g_o_per_g_c * limited.substrate_limited_respiration_g_c;
                context.result.aerobic_active_biomass_g_c[unit] = active_biomass_g_c;
                context.result.aerobic_fallback_active_fraction[unit] = active_fraction;
                context.result.doc_competition_fraction[unit] = doc_share;
                context.result.substrate_complex_fraction[unit] = substrate_fraction;
            }
        }
    }
}

fn colonizedAndSorbedCarbon(state: *const organic.State, layer: usize, substrate: usize) f64 {
    var total = state.adsorbed[layer * organic.substrate_count + substrate].carbon_g_c + state.adsorbed_acetate_carbon_g_c[layer * organic.substrate_count + substrate];
    for (0..organic.structural_fraction_count) |fraction| total += state.colonized_structural_carbon_g_c[(layer * organic.substrate_count + substrate) * organic.structural_fraction_count + fraction];
    for (0..organic.residue_fraction_count) |fraction| total += state.residue[(layer * organic.substrate_count + substrate) * organic.residue_fraction_count + fraction].carbon_g_c;
    return total;
}

pub fn substrateComplexFractions(state: *const organic.State, layer: usize, output: []f64, negligible_carbon_g_c: f64) !void {
    if (layer >= state.layer_count or output.len != organic.substrate_count or !std.math.isFinite(negligible_carbon_g_c) or negligible_carbon_g_c < 0) return error.InvalidSubstrateComplexFractionRequest;
    var total: f64 = 0;
    for (0..organic.substrate_count) |substrate| {
        output[substrate] = colonizedAndSorbedCarbon(state, layer, substrate);
        if (!std.math.isFinite(output[substrate]) or output[substrate] < 0) return error.InvalidSubstrateComplexCarbon;
        total += output[substrate];
    }
    if (!std.math.isFinite(total)) return error.InvalidSubstrateComplexCarbon;
    for (output) |*fraction| fraction.* = if (total > negligible_carbon_g_c) fraction.* / total else 1;
}

fn biologicallyActiveWaterM3(context: ApplyContext, layer: usize) !f64 {
    // NITRO `THETY` is the HOUR1 field-capacity-to-wilting extrapolation,
    // not the inverse of PSISM's shaped below-wilting branch.
    const inactive = try context.retention_curve[layer].legacyDryEndWaterFractionAtPotentialMpa(context.parameters.oxygen_uptake.hygroscopic_water_potential_megapascal);
    const water_fraction = context.model_grid.matrix_liquid_water_m3[layer] / context.matrix_bulk_volume_m3[layer];
    const active_fraction = @max(0, @min(@max(0.75 * context.retention_curve[layer].porosity_fraction, context.retention_curve[layer].curve.field_capacity_fraction), water_fraction) - inactive);
    return active_fraction / (1 + active_fraction) * context.matrix_bulk_volume_m3[layer];
}

fn competition(previous: f64, total: f64, fallback: f64, minimum: f64, negligible: f64) f64 {
    return @max(minimum, if (total > negligible) previous / total else fallback);
}

fn normalizedCompetition(raw_share: f64, total_raw_share: f64) f64 {
    return raw_share / @max(1, total_raw_share);
}

test "minimum competition floors remain a conservative shared allocation" {
    const raw = [_]f64{ 1, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001 };
    var total_raw: f64 = 0;
    for (raw) |share| total_raw += share;
    var normalized_total: f64 = 0;
    for (raw) |share| normalized_total += normalizedCompetition(share, total_raw);
    try std.testing.expectApproxEqAbs(@as(f64, 1), normalized_total, 1e-15);
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.model_grid.layer_count;
    const units = try std.math.mul(usize, layers, context.result.process_unit_count_per_layer);
    if (range.first > range.end or range.end > layers or context.organic_state.layer_count != layers or context.reactive_nitrogen.layer_count != layers or context.retention_curve.len != layers or context.matrix_bulk_volume_m3.len != layers or context.matric_plus_osmotic_potential_megapascal.len != layers or context.thermal_adaptation_offset_k_by_cell.len != context.microbial_state.cell_count or context.result.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count or context.reactive_nitrogen.previous_doc_respiration_demand_g_c.len != units) return error.SoilHeterotrophicRespirationDimensionMismatch;
    for (context.thermal_adaptation_offset_k_by_cell) |offset_k| if (!std.math.isFinite(offset_k)) return error.NonFiniteMicrobialThermalAdaptationOffset;
    if (context.parameters.nitrifier_indices.heterotrophic_denitrifier_population_index >= context.microbial_state.population_count or !std.math.isFinite(context.timestep_h) or context.timestep_h <= 0 or !std.math.isFinite(context.negligible_carbon_g_c) or context.negligible_carbon_g_c < 0) return error.InvalidSoilHeterotrophicRespirationInput;
    // The source ECHZ feedback needs the authoritative aqueous hydrogen owner.
    if (context.gas_state.cell_count != layers) return error.SoilHeterotrophicRespirationDimensionMismatch;
    if (context.aqueous_water_volume_m3) |volumes| if (volumes.len != layers) return error.SoilHeterotrophicRespirationDimensionMismatch;
}

test "runtime aerobic respiration evaluates every heterotrophic population" {
    const config = @import("../../core/config.zig").SimulationConfig{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 };
    var model_grid = try grid.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    model_grid.matrix_liquid_water_m3[0] = 0.3;
    model_grid.soil_temperature_k[0] = 293.15;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 2, 6);
    defer microbial_state.deinit();
    for (0..microbial_state.substrate_count * microbial_state.population_count) |population_index| {
        microbial_state.structural[population_index * 2] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    }
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.dissolved[0].carbon_g_c = 10;
    organic_state.dissolved_acetate_carbon_g_c[0] = 2;
    organic_state.adsorbed[0].carbon_g_c = 5;
    var reactive_state = try reactive.State.init(std.testing.allocator, 1, 12);
    defer reactive_state.deinit();
    var result = try fluxes.State.init(std.testing.allocator, 1, 12);
    defer result.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    const source =
        "soil_nitrification 0.001 0.0002 7000 14 1.4 1.4 0.125 0.125 0.3 0.1 0.5 2.667 3.429 1.143\n" ++
        "soil_denitrification 0.001 1.4 1.4 0.014 1 0.429 0.429 0.214 0.875\n" ++
        "soil_autotrophic_denitrification 0.5 0.333\nsoil_chemodenitrification 0.0005 0.001 1e-12 0.5 0 0.5\n" ++
        "nitrous_acid_dissociation_mol_per_m3 0.45\nsoil_microbial_thermal_adaptation_offset_k 0\n" ++
        "soil_nitrifier_indices 5 0 1 1\nsoil_nitrifier_environment 0.55 0.1 0.1 0.01 0.01 12 0.1\n" ++
        "soil_oxygen_uptake 1e-6 2.3866348449e11 0.064 -1.5e4 0.5 12 12 0.5 0.7 0.001 1e-12\n" ++
        "soil_heterotrophic_respiration 0.125 0.1 0.01 12 12 0.5 0.42016806722689076 0.1 2.667 0.01 0.01 1e-6 1 0.7142857142857143\n" ++
        "soil_microbial_mineral_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 0.003 0.009 0.18 31\n" ++
        "soil_nonsymbiotic_nitrogen_fixation 5 6 0.25 0.02 0.14 0.25\n" ++
        "soil_microbial_turnover 0.01 0.001 0.167 0.333 0.333 0.333 0.150 0.300 0.333 0.25 2.0 5.0 1.0 0.5 0.182e-6";
    const parsed = try nitrogen_parameters.parse(source);
    const curve = retention.ResolvedCurve{ .porosity_fraction = 0.5, .curve = .{ .field_capacity_fraction = 0.25, .wilting_point_fraction = 0.1, .saturation_water_potential_megapascal = -0.0005, .field_capacity_water_potential_megapascal = -0.033, .wilting_point_water_potential_megapascal = -1.5, .minimum_water_potential_megapascal = -1.5e12, .saturation_to_field_shape = 0.5, .below_wilting_shape = 0.5 } };
    var context: ApplyContext = .{ .result = &result, .reactive_nitrogen = &reactive_state, .organic_state = &organic_state, .microbial_state = &microbial_state, .model_grid = &model_grid, .retention_curve = &.{curve}, .matrix_bulk_volume_m3 = &.{1}, .matric_plus_osmotic_potential_megapascal = &.{0}, .thermal_adaptation_offset_k_by_cell = &.{0}, .gas_state = &gas_state, .parameters = parsed, .timestep_h = 1, .negligible_carbon_g_c = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(result.substrate_limited_respiration_g_c[0] > 0);
    try std.testing.expect(result.substrate_limited_respiration_g_c[1] > 0);
    try std.testing.expectApproxEqAbs(result.substrate_limited_respiration_g_c[0], result.substrate_limited_respiration_g_c[1], 1e-14);
    for (0..microbial_state.substrate_count) |substrate| {
        const first_unit = substrate * microbial_state.population_count;
        try std.testing.expectEqual(@as(f64, 0), result.acetate_respiration_demand_g_c[first_unit + 3]);
        try std.testing.expectEqual(@as(f64, 0), result.doc_respiration_demand_g_c[first_unit + 4]);
    }
}

/// Shared fixture for the anaerobic `ECHZ` tests. Owns every allocation and is
/// deinitialized by the caller through `deinit`.
const AnaerobicFixture = struct {
    model_grid: grid.GridState,
    microbial_state: microbial.State,
    organic_state: organic.State,
    reactive_state: reactive.State,
    result: fluxes.State,
    gas_state: gas.State,
    curve: retention.ResolvedCurve,

    const layer_count = 1;
    const substrate_count = 2;
    const population_count = 7;
    const units_per_layer = substrate_count * population_count;

    fn init(allocator: std.mem.Allocator) !AnaerobicFixture {
        const config = @import("../../core/config.zig").SimulationConfig{ .lon_count = 1, .lat_count = 1, .soil_layers = layer_count, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 };
        var model_grid = try grid.GridState.init(allocator, config);
        errdefer model_grid.deinit();
        model_grid.matrix_liquid_water_m3[0] = 0.3;
        model_grid.soil_temperature_k[0] = 293.15;
        var microbial_state = try microbial.State.init(allocator, 1, layer_count, substrate_count, population_count);
        errdefer microbial_state.deinit();
        for (0..substrate_count * population_count) |index|
            // Large active biomass so the source supply limit `RGOFX`/`RGOGX`,
            // which is what `ECHZ` scales, is the binding constraint rather
            // than the kinetic demand. C:N:P ratios stay at the parameter
            // targets so the nutrient factor is exactly one.
            microbial_state.structural[index * 2] = .{ .carbon_g_c = 100, .nitrogen_g_n = 10, .phosphorus_g_p = 1 };
        var organic_state = try organic.State.init(allocator, layer_count);
        errdefer organic_state.deinit();
        organic_state.dissolved[0].carbon_g_c = 10;
        organic_state.dissolved_acetate_carbon_g_c[0] = 2;
        organic_state.adsorbed[0].carbon_g_c = 5;
        var reactive_state = try reactive.State.init(allocator, layer_count, units_per_layer);
        errdefer reactive_state.deinit();
        var result = try fluxes.State.init(allocator, layer_count, units_per_layer);
        errdefer result.deinit();
        var gas_state = try gas.State.init(allocator, layer_count);
        errdefer gas_state.deinit();
        gas_state.dissolved_mass_g[try gas.massIndex(0, .hydrogen, layer_count)] = 0.03;
        return .{
            .model_grid = model_grid,
            .microbial_state = microbial_state,
            .organic_state = organic_state,
            .reactive_state = reactive_state,
            .result = result,
            .gas_state = gas_state,
            .curve = .{ .porosity_fraction = 0.5, .curve = .{ .field_capacity_fraction = 0.25, .wilting_point_fraction = 0.1, .saturation_water_potential_megapascal = -0.0005, .field_capacity_water_potential_megapascal = -0.033, .wilting_point_water_potential_megapascal = -1.5, .minimum_water_potential_megapascal = -1.5e12, .saturation_to_field_shape = 0.5, .below_wilting_shape = 0.5 } },
        };
    }

    fn deinit(self: *AnaerobicFixture) void {
        self.gas_state.deinit();
        self.result.deinit();
        self.reactive_state.deinit();
        self.organic_state.deinit();
        self.microbial_state.deinit();
        self.model_grid.deinit();
    }

    fn context(self: *AnaerobicFixture, parameters: nitrogen_parameters.Parameters) ApplyContext {
        return .{
            .result = &self.result,
            .reactive_nitrogen = &self.reactive_state,
            .organic_state = &self.organic_state,
            .microbial_state = &self.microbial_state,
            .model_grid = &self.model_grid,
            .retention_curve = self.retentionSlice(),
            .matrix_bulk_volume_m3 = &.{1},
            .matric_plus_osmotic_potential_megapascal = &.{0},
            .thermal_adaptation_offset_k_by_cell = &.{0},
            .gas_state = &self.gas_state,
            .aqueous_water_volume_m3 = self.model_grid.matrix_liquid_water_m3,
            .parameters = parameters,
            .timestep_h = 1,
            .negligible_carbon_g_c = 1e-12,
        };
    }

    fn retentionSlice(self: *AnaerobicFixture) []const retention.ResolvedCurve {
        return @as(*const [1]retention.ResolvedCurve, &self.curve)[0..];
    }

    /// Zero-based population index of the fermenter and the acetotrophic
    /// methanogen, matching `soil_microbial_respiration_activity`.
    const fermenter_population = 3;
    const acetotrophic_population = 4;
    const anaerobic_diazotroph_population = 6;
};

fn anaerobicTestParameters(with_energy_record: bool) !nitrogen_parameters.Parameters {
    const base =
        "soil_nitrification 0.001 0.0002 7000 14 1.4 1.4 0.125 0.125 0.3 0.1 0.5 2.667 3.429 1.143\n" ++
        "soil_denitrification 0.001 1.4 1.4 0.014 1 0.429 0.429 0.214 0.875\n" ++
        "soil_autotrophic_denitrification 0.5 0.333\nsoil_chemodenitrification 0.0005 0.001 1e-12 0.5 0 0.5\n" ++
        "nitrous_acid_dissociation_mol_per_m3 0.45\nsoil_microbial_thermal_adaptation_offset_k 0\n" ++
        "soil_nitrifier_indices 5 0 1 1\nsoil_nitrifier_environment 0.55 0.1 0.1 0.01 0.01 12 0.1\n" ++
        "soil_oxygen_uptake 1e-6 2.3866348449e11 0.064 -1.5e4 0.5 12 12 0.5 0.7 0.001 1e-12\n" ++
        "soil_heterotrophic_respiration 0.125 0.1 0.01 12 12 0.5 0.42016806722689076 0.1 2.667 0.01 0.01 1e-6 1 0.7142857142857143\n" ++
        "soil_microbial_mineral_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 0.003 0.009 0.18 31\n" ++
        "soil_nonsymbiotic_nitrogen_fixation 5 6 0.25 0.02 0.14 0.25\n" ++
        "soil_microbial_turnover 0.01 0.001 0.167 0.333 0.333 0.333 0.150 0.300 0.333 0.25 2.0 5.0 1.0 0.5 0.182e-6";
    if (!with_energy_record) return nitrogen_parameters.parse(base);
    // NITRO.F 179--187 source values.
    return nitrogen_parameters.parse(base ++ "\nsoil_anaerobic_growth_energy 3.0 1.5 37.5 37.5 37.5 0.4 0.5");
}

test "absent anaerobic energy record binds source ECHZ instead of fixed constants" {
    var fixture = try AnaerobicFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const parameters = try anaerobicTestParameters(false);
    try std.testing.expectEqualDeep(
        nitrogen_parameters.source_anaerobic_growth_energy_parameters,
        parameters.anaerobic_growth_energy,
    );
    var context = fixture.context(parameters);
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const fermenter_unit = AnaerobicFixture.fermenter_population;
    const acetotrophic_unit = AnaerobicFixture.acetotrophic_population;
    try std.testing.expect(fixture.result.substrate_limited_respiration_g_c[fermenter_unit] > 0);
    try std.testing.expect(fixture.result.doc_respiration_demand_g_c[fermenter_unit] > 0);
    try std.testing.expect(fixture.result.acetate_respiration_demand_g_c[acetotrophic_unit] > 0);
}

test "NITRO 325 OXYI suppresses fermentation toward zero as aqueous O2 rises" {
    // Regression pin for a fresh-domain audit finding: OXYI
    // (`metabolism.fermentationOxygenInhibition`) was computed but never
    // multiplied into the fermenter/anaerobic-diazotroph kinetic rate, so
    // fermentation ran unsuppressed regardless of aeration. The default
    // fixture is supply-limited (see "absent anaerobic energy record
    // reproduces the legacy constants bit for bit" above), so proving the
    // fix needs enough aqueous O2 to push the kinetic demand below the
    // supply cap and make demand the binding constraint -- exactly the
    // physical case OXYI exists to create.
    var anoxic_fixture = try AnaerobicFixture.init(std.testing.allocator);
    defer anoxic_fixture.deinit();
    var anoxic_context = anoxic_fixture.context(try anaerobicTestParameters(false));
    try applyTile(&anoxic_context, .{ .first = 0, .end = 1 });

    var aerated_fixture = try AnaerobicFixture.init(std.testing.allocator);
    defer aerated_fixture.deinit();
    // 15 g O across the fixture's 0.3 m3 water = 50 g O m-3, far past OXYI's
    // half-inhibition point at 2.5 g O m-3, so OXYI collapses toward 0.
    aerated_fixture.gas_state.dissolved_mass_g[try gas.massIndex(0, .oxygen, 1)] = 15;
    var aerated_context = aerated_fixture.context(try anaerobicTestParameters(false));
    try applyTile(&aerated_context, .{ .first = 0, .end = 1 });

    const fermenter_unit = AnaerobicFixture.fermenter_population;
    const anoxic_demand = anoxic_fixture.result.doc_respiration_demand_g_c[fermenter_unit];
    const aerated_demand = aerated_fixture.result.doc_respiration_demand_g_c[fermenter_unit];
    // Before the fix, aeration had zero effect: every fixture published the
    // same supply-limited value regardless of aqueous O2. After the fix, the
    // well-aerated layer's kinetic demand collapses far below the supply
    // cap and becomes the binding constraint instead.
    try std.testing.expect(anoxic_demand > 0.5);
    try std.testing.expect(aerated_demand < anoxic_demand * 1e-6);
    try std.testing.expect(aerated_demand >= 0);
}

test "omitted and explicit source anaerobic energy records are bit-identical" {
    var omitted_fixture = try AnaerobicFixture.init(std.testing.allocator);
    defer omitted_fixture.deinit();
    var omitted_context = omitted_fixture.context(try anaerobicTestParameters(false));
    try applyTile(&omitted_context, .{ .first = 0, .end = 1 });

    var source_fixture = try AnaerobicFixture.init(std.testing.allocator);
    defer source_fixture.deinit();
    const source_parameters = try anaerobicTestParameters(true);
    var source_context = source_fixture.context(source_parameters);
    try applyTile(&source_context, .{ .first = 0, .end = 1 });

    const fermenter = AnaerobicFixture.fermenter_population;
    const acetotroph = AnaerobicFixture.acetotrophic_population;
    try std.testing.expectEqual(
        omitted_fixture.result.doc_respiration_demand_g_c[fermenter],
        source_fixture.result.doc_respiration_demand_g_c[fermenter],
    );
    try std.testing.expectEqual(
        omitted_fixture.result.acetate_respiration_demand_g_c[acetotroph],
        source_fixture.result.acetate_respiration_demand_g_c[acetotroph],
    );
}

test "fermenter and diazotroph branches are distinguished only by floor and requirement" {
    var fixture = try AnaerobicFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.organic_state.dissolved_acetate_carbon_g_c[0] = 1.0e-12;
    fixture.gas_state.dissolved_mass_g[try gas.massIndex(0, .hydrogen, 1)] = 0;
    var context = fixture.context(try anaerobicTestParameters(true));
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const feedback = try anaerobic.fermenterFeedback(
        fixture.model_grid.soil_temperature_k[0],
        fixture.organic_state.dissolved_acetate_carbon_g_c[0] /
            fixture.result.layer_biologically_active_water_m3[0],
        try anaerobic.hydrogenFeedbackEnergy_kilojoule_per_mol(
            fixture.model_grid.soil_temperature_k[0],
            0,
            anaerobic.source_feedback_environment,
        ),
        anaerobic.source_feedback_environment,
        anaerobic.source_carbon_basis,
    );
    // Both feedback terms are negative when products sit below their
    // inhibition references, and the source subtracts GHAX from GCHX.
    try std.testing.expect(feedback.hydrogen_kilojoule_per_g_c < 0);
    try std.testing.expect(feedback.acetate_kilojoule_per_g_c < 0);
    const energy = context.parameters.anaerobic_growth_energy;
    const fermenter_requirement =
        try anaerobic.fermenterRequirement_g_c_per_g_c(energy, feedback, .fermenter);
    const diazotroph_requirement =
        try anaerobic.fermenterRequirement_g_c_per_g_c(energy, feedback, .anaerobic_diazotroph);
    // Measured finding, recorded in
    // docs/traceability/nitro_anaerobic_growth_respiration.md: at the source
    // defaults EOMF and EOMY are both 37.5, so the two branches differ ONLY by
    // their floors EO2X=0.4 and ENFY=0.5. The fermenter floor needs
    // GCHX-GHAX >= 56.25 kilojoule per gram carbon, which at 293.15 K needs an
    // aqueous acetate ratio COQA/OAKI below exp(-772), and the diazotroph floor
    // needs below exp(-496). Both are unrepresentable in f64 at any physical
    // acetate concentration, so neither floor can bind and the two branches
    // agree exactly. This is source behaviour, not an approximation.
    try std.testing.expectEqual(fermenter_requirement, diazotroph_requirement);
    try std.testing.expect(fermenter_requirement > 0.5);
    try std.testing.expect(fermenter_requirement < 1);

    // The floor logic itself is still real and must select per branch. Prove it
    // with an energy requirement small enough to make each floor bind, which
    // isolates the floor selection from its physical reachability.
    const steep: nitrogen_parameters.AnaerobicGrowthEnergyParameters = .{
        .fermentation_energy_yield_kilojoule_per_g_c = 3.0,
        .acetotrophic_methanogenesis_energy_yield_kilojoule_per_g_c = 1.5,
        .fermenter_growth_energy_requirement_kilojoule_per_g_c = 0.1,
        .anaerobic_diazotroph_growth_energy_requirement_kilojoule_per_g_c = 0.1,
        .acetotrophic_methanogen_growth_energy_requirement_kilojoule_per_g_c = 0.1,
        .minimum_growth_respiration_requirement_g_c_per_g_c = 0.4,
        .anaerobic_diazotroph_minimum_growth_respiration_requirement_g_c_per_g_c = 0.5,
    };
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.4),
        try anaerobic.fermenterRequirement_g_c_per_g_c(steep, feedback, .fermenter),
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.5),
        try anaerobic.fermenterRequirement_g_c_per_g_c(steep, feedback, .anaerobic_diazotroph),
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.4),
        try anaerobic.acetotrophicRequirement_g_c_per_g_c(steep, 1e6),
        1e-15,
    );

    // Source asymmetry, and the reason the two branches cannot share a
    // constant. For the fermenter, acetate is a PRODUCT: source 925 subtracts
    // GHAX from GCHX, so accumulation shrinks the net energy, drives ECHZ to 1,
    // and by source line 171 collapses growth yield 1-ECHZ to zero. That is the
    // thermodynamic brake on fermentation. For the acetotrophic methanogen,
    // acetate is the SUBSTRATE: source 1004 adds GOMM to GC4X, so accumulation
    // raises the available energy and drives ECHZ down toward EO2X instead,
    // raising growth yield. Applying one constant to both, as production did,
    // erases both directions.
    const accumulated_products: anaerobic.FermenterFeedback = .{
        .hydrogen_kilojoule_per_g_c = 10,
        .acetate_kilojoule_per_mol = 720,
        .acetate_kilojoule_per_g_c = 10,
        .combined_kilojoule_per_g_c = 20,
    };
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        try anaerobic.fermenterRequirement_g_c_per_g_c(energy, accumulated_products, .fermenter),
        1e-15,
    );
    // GC4X=1.5, EOMH=37.5, GOMM=10: 1/(1+11.5/37.5).
    try std.testing.expectApproxEqRel(
        1.0 / (1.0 + (1.5 + 10.0) / 37.5),
        try anaerobic.acetotrophicRequirement_g_c_per_g_c(energy, 10),
        1e-15,
    );
    // Depleted acetate reverses the acetotroph: GC4X+GOMM below zero is floored
    // at zero by source 1004, so ECHZ saturates at complete dissipation.
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        try anaerobic.acetotrophicRequirement_g_c_per_g_c(energy, -2),
        1e-15,
    );
}

test "source ECHZ rejects a mismatched hydrogen owner atomically" {
    var fixture = try AnaerobicFixture.init(std.testing.allocator);
    defer fixture.deinit();
    var wrong_gas_state = try gas.State.init(std.testing.allocator, 2);
    defer wrong_gas_state.deinit();
    fixture.result.doc_respiration_demand_g_c[AnaerobicFixture.fermenter_population] = 7;
    var context = fixture.context(try anaerobicTestParameters(true));
    context.gas_state = &wrong_gas_state;
    try std.testing.expectError(
        error.SoilHeterotrophicRespirationDimensionMismatch,
        applyTile(&context, .{ .first = 0, .end = 1 }),
    );
    try std.testing.expectEqual(
        @as(f64, 7),
        fixture.result.doc_respiration_demand_g_c[AnaerobicFixture.fermenter_population],
    );
}

test "ECHZ correction keeps the anaerobic carbon draw inside its donor pools" {
    // Tier 3, conservation closure. ECHZ scales a supply CEILING, so the one
    // conservation statement that must survive the correction is that the
    // published anaerobic respiration never withdraws more carbon than the
    // donor pool it is drawn from, summed over every competing population in
    // the layer. The competition shares are normalized to at most one, so this
    // is the real closure test, not a per-population one.
    var fixture = try AnaerobicFixture.init(std.testing.allocator);
    defer fixture.deinit();
    var context = fixture.context(try anaerobicTestParameters(true));
    try applyTile(&context, .{ .first = 0, .end = 1 });
    for (0..AnaerobicFixture.substrate_count) |substrate| {
        var doc_drawn_g_c: f64 = 0;
        var acetate_drawn_g_c: f64 = 0;
        for (0..AnaerobicFixture.population_count) |population| {
            const unit = substrate * AnaerobicFixture.population_count + population;
            doc_drawn_g_c += fixture.result.doc_respiration_demand_g_c[unit];
            acetate_drawn_g_c += fixture.result.acetate_respiration_demand_g_c[unit];
            // Every published value stays finite and nonnegative: a supply
            // ceiling can never produce a negative withdrawal.
            try std.testing.expect(fixture.result.doc_respiration_demand_g_c[unit] >= 0);
            try std.testing.expect(fixture.result.acetate_respiration_demand_g_c[unit] >= 0);
            // The published limited respiration is exactly the sum of its two
            // substrate components, so no carbon is created at state_update.
            try std.testing.expectApproxEqAbs(
                fixture.result.doc_respiration_demand_g_c[unit] +
                    fixture.result.acetate_respiration_demand_g_c[unit],
                fixture.result.substrate_limited_respiration_g_c[unit],
                1e-15,
            );
        }
        try std.testing.expect(doc_drawn_g_c <= fixture.organic_state.dissolved[substrate].carbon_g_c);
        try std.testing.expect(acetate_drawn_g_c <= fixture.organic_state.dissolved_acetate_carbon_g_c[substrate]);
    }
}

test "the ECHZ correction raises the anaerobic supply ceiling and never lowers it" {
    // docs/model_changes.md "NITRO anaerobic ECHZ product-energy feedback".
    // This is the tier-2 magnitude claim, pinned so the recorded sign and
    // bounds cannot drift silently. Reproduce independently of Zig with
    // `pwsh tools/a3_echz_magnitude.ps1`.
    //
    // ECHZ multiplies the anaerobic supply cap RGOFX/RGOGX. Production used
    // fixed 0.5 (= ENFY, the anaerobic diazotroph FLOOR) for the fermenter and
    // 0.42016806722689076 (= EO2A, the AEROBIC acetate requirement) for the
    // acetotroph. Both sit at or below the floor of their source range, so the
    // corrected value is strictly larger at every physical product energy and
    // the change is one-signed: POSITIVE.
    const energy = (try anaerobicTestParameters(true)).anaerobic_growth_energy;
    const legacy_fermenter: f64 = 0.5;
    const legacy_acetotroph: f64 = 0.42016806722689076;
    var minimum_fermenter_ratio: f64 = std.math.inf(f64);
    var maximum_fermenter_ratio: f64 = 0;
    var minimum_acetotroph_ratio: f64 = std.math.inf(f64);
    var maximum_acetotroph_ratio: f64 = 0;
    // Physical soil temperatures and a five-decade acetate range spanning the
    // OAKI = 12 g C m-3 inhibition reference, crossed with a four-decade
    // aqueous hydrogen range spanning the H2KI = 1 g H m-3 reference.
    for ([_]f64{ 275.15, 293.15, 308.15 }) |temperature_k| {
        for ([_]f64{ 1e-6, 1e-3, 0.1, 1, 12, 120, 1200 }) |acetate_g_c_per_m3| {
            for ([_]f64{ 0, 1e-3, 1e-2, 0.1, 1, 10 }) |hydrogen_g_h_per_m3| {
                const hydrogen_feedback = try anaerobic.hydrogenFeedbackEnergy_kilojoule_per_mol(
                    temperature_k,
                    hydrogen_g_h_per_m3,
                    anaerobic.source_feedback_environment,
                );
                const feedback = try anaerobic.fermenterFeedback(
                    temperature_k,
                    acetate_g_c_per_m3,
                    hydrogen_feedback,
                    anaerobic.source_feedback_environment,
                    anaerobic.source_carbon_basis,
                );
                const fermenter = try anaerobic.fermenterRequirement_g_c_per_g_c(energy, feedback, .fermenter);
                const diazotroph = try anaerobic.fermenterRequirement_g_c_per_g_c(energy, feedback, .anaerobic_diazotroph);
                const acetotroph = try anaerobic.acetotrophicRequirement_g_c_per_g_c(
                    energy,
                    try anaerobic.acetotrophicFeedback_kilojoule_per_g_c(
                        temperature_k,
                        acetate_g_c_per_m3,
                        anaerobic.source_feedback_environment,
                        anaerobic.source_carbon_basis,
                    ),
                );
                // Tier 1: ECHZ is gram carbon per gram carbon, so it is
                // dimensionless and the source AMAX1/AMIN1 pair confines it to
                // [floor, 1]. A value outside that is not a physical yield.
                for ([_]f64{ fermenter, diazotroph, acetotroph }) |value| {
                    try std.testing.expect(std.math.isFinite(value));
                    try std.testing.expect(value >= energy.minimum_growth_respiration_requirement_g_c_per_g_c);
                    try std.testing.expect(value <= 1);
                }
                // Tier 2: one-signed change. Never below the legacy constant.
                try std.testing.expect(fermenter >= legacy_fermenter);
                try std.testing.expect(diazotroph >= legacy_fermenter);
                try std.testing.expect(acetotroph >= legacy_acetotroph);
                minimum_fermenter_ratio = @min(minimum_fermenter_ratio, fermenter / legacy_fermenter);
                maximum_fermenter_ratio = @max(maximum_fermenter_ratio, fermenter / legacy_fermenter);
                minimum_acetotroph_ratio = @min(minimum_acetotroph_ratio, acetotroph / legacy_acetotroph);
                maximum_acetotroph_ratio = @max(maximum_acetotroph_ratio, acetotroph / legacy_acetotroph);
            }
        }
    }
    // Recorded magnitude. The fermenter cap grows by roughly 1.8x and the
    // acetotroph cap by roughly 2.3x, and neither exceeds the arithmetic
    // ceilings 1/0.5 = 2 and 1/0.42016806722689076 = 2.38 that ECHZ <= 1 imposes.
    try std.testing.expect(minimum_fermenter_ratio > 1.7);
    try std.testing.expect(maximum_fermenter_ratio <= 1.0 / legacy_fermenter);
    try std.testing.expect(minimum_acetotroph_ratio > 2.2);
    try std.testing.expect(maximum_acetotroph_ratio <= 1.0 / legacy_acetotroph);
}

test "anaerobic requirement is monotone in acetate for the fermenter branch" {
    var previous: f64 = 0;
    for ([_]f64{ 0.02, 0.2, 2, 20, 200 }) |acetate_g_c| {
        var fixture = try AnaerobicFixture.init(std.testing.allocator);
        defer fixture.deinit();
        fixture.organic_state.dissolved_acetate_carbon_g_c[0] = acetate_g_c;
        var context = fixture.context(try anaerobicTestParameters(true));
        try applyTile(&context, .{ .first = 0, .end = 1 });
        const respiration_g_c =
            fixture.result.doc_respiration_demand_g_c[AnaerobicFixture.fermenter_population];
        // Rising acetate raises GOAF, shrinks GCHX-GHAX, raises ECHZ, and so
        // relaxes the fermenter's DOC supply cap RGOFX, until the kinetic
        // demand RGOFZ binds instead. Growth yield 1-ECHZ falls at the same
        // time, which is where the thermodynamic limitation actually acts.
        try std.testing.expect(respiration_g_c >= previous - 1e-15);
        previous = respiration_g_c;
    }
}
