const std = @import("std");
const compute = @import("../../core/compute.zig");
const grid = @import("../../state/grid.zig");
const chemistry = @import("../solute/chemistry_state.zig");
const zones = @import("../solute/charge_classification.zig");
const reaction = @import("denitrification.zig");
const reactive = @import("../nutrients/reactive_nitrogen_state.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const oxygen = @import("../gas/oxygen_allocation.zig");
const nitrifier_environment = @import("nitrifier_environment_step.zig");
const nitrogen_parameters = @import("../nutrients/nitrogen_parameters.zig");
const retention = @import("../water/retention.zig");
const competition_history = @import("../nutrients/competition_history.zig");

pub const ApplyContext = struct {
    result: *fluxes.State,
    reactive_nitrogen: *const reactive.State,
    nutrient_competition: ?*const competition_history.State = null,
    chemistry_state: *const chemistry.State,
    model_grid: *const grid.GridState,
    oxygen_state: *const oxygen.State,
    environment: *const nitrifier_environment.State,
    retention_curve: []const retention.ResolvedCurve,
    matrix_bulk_volume_m3: []const f64,
    zone_fractions: zones.ZoneFractions,
    zone_fractions_by_layer: []const zones.ZoneFractions = &.{},
    parameters: nitrogen_parameters.Parameters,
    nitrogen_molar_mass_g_per_mol: f64,
    timestep_h: f64,
    negligible_water_volume_m3: f64,
    negligible_nitrogen_g_n: f64,
};

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const units_per_layer = context.result.process_unit_count_per_layer;
    for (range.first..range.end) |layer| {
        const water_m3 = context.model_grid.matrix_liquid_water_m3[layer];
        if (water_m3 <= context.negligible_water_volume_m3) continue;
        // NITRO `THETY` uses HOUR1's unshaped FC-to-WP extrapolation even
        // though PSISM applies a separate below-wilting shape coefficient.
        const inactive_water_fraction = try context.retention_curve[layer].legacyDryEndWaterFractionAtPotentialMpa(context.parameters.oxygen_uptake.hygroscopic_water_potential_megapascal);
        const current_water_fraction = water_m3 / context.matrix_bulk_volume_m3[layer];
        const active_water_fraction = @max(0, @min(@max(0.75 * context.retention_curve[layer].porosity_fraction, context.retention_curve[layer].curve.field_capacity_fraction), current_water_fraction) - inactive_water_fraction);
        const biologically_active_water_m3 = active_water_fraction / (1 + active_water_fraction) * context.matrix_bulk_volume_m3[layer];
        const first = layer * units_per_layer;
        for (first..first + units_per_layer) |unit| {
            if (context.environment.roles[unit] != .ammonia_oxidizer) continue;
            const oxygen_demand = context.result.aerobic_oxygen_demand_g_o[unit];
            const potential = try reaction.calculateAutotrophicPotential(.{
                .non_band = makeZone(context.*, layer, unit, water_m3, false),
                .band = makeZone(context.*, layer, unit, water_m3, true),
                .oxygen_demand_g_o = oxygen_demand,
                .oxygen_reduction_g_o = context.oxygen_state.oxygen_uptake_g_o[unit],
                .aqueous_co2_activity = context.environment.aqueous_co2_activity[unit],
                .biologically_active_water_m3 = biologically_active_water_m3,
                .timestep_h = context.timestep_h,
                .negligible_water_volume_m3 = context.negligible_water_volume_m3,
                .nitrite_oxidizer_carbon_efficiency_g_c_per_g_n = context.parameters.nitrification.nitrite_oxidizer_carbon_efficiency_g_c_per_g_n,
                .anaerobic_growth_respiration_fraction = context.parameters.autotrophic_denitrification.anaerobic_growth_respiration_fraction,
                .additional_ammonium_oxidation_per_nitrite_reduction = context.parameters.autotrophic_denitrification.additional_ammonium_oxidation_per_nitrite_reduction,
            }, context.parameters.denitrification);
            context.result.non_band_autotrophic_nitrite_reduction_potential_g_n[unit] = potential.non_band_nitrite_reduction_g_n;
            context.result.band_autotrophic_nitrite_reduction_potential_g_n[unit] = potential.band_nitrite_reduction_g_n;
            context.result.non_band_autotrophic_ammonium_oxidation_potential_g_n[unit] = potential.non_band_additional_ammonium_oxidation_g_n;
            context.result.band_autotrophic_ammonium_oxidation_potential_g_n[unit] = potential.band_additional_ammonium_oxidation_g_n;
            context.result.non_band_nitrite_reduction_capacity_g_n[unit] += potential.non_band_capacity_g_n;
            context.result.band_nitrite_reduction_capacity_g_n[unit] += potential.band_capacity_g_n;
            context.result.denitrification_respiration_g_c[unit] += potential.growth_respiration_g_c;
        }
    }
}

fn makeZone(context: ApplyContext, layer: usize, unit: usize, water_m3: f64, band: bool) reaction.AutotrophicZone {
    const fractions = if (context.zone_fractions_by_layer.len == 0) context.zone_fractions else context.zone_fractions_by_layer[layer];
    const ammonium_fraction = if (band) fractions.ammonium_band else fractions.ammonium_non_band;
    const nitrite_fraction = if (band) fractions.nitrate_band else fractions.nitrate_non_band;
    const aqueous = context.chemistry_state.aqueous[layer];
    const ammonium_concentration = if (band) aqueous.ammonium_band else aqueous.ammonium_non_band;
    const ammonium_amount = ammonium_concentration * water_m3 * ammonium_fraction * context.nitrogen_molar_mass_g_per_mol;
    const nitrite_amount = if (band) context.reactive_nitrogen.band_nitrite_g_n[layer] else context.reactive_nitrogen.non_band_nitrite_g_n[layer];
    const nitrite_volume = water_m3 * nitrite_fraction;
    const previous_nitrite_capacity = if (band) context.reactive_nitrogen.previous_band_nitrite_reduction_capacity_g_n[unit] else context.reactive_nitrogen.previous_non_band_nitrite_reduction_capacity_g_n[unit];
    const previous_nitrite_total = if (band) context.reactive_nitrogen.previous_total_band_nitrite_demand_g_n[layer] else context.reactive_nitrogen.previous_total_non_band_nitrite_demand_g_n[layer];
    const previous_ammonia_capacity = if (band) context.reactive_nitrogen.previous_band_ammonia_oxidation_capacity_g_n[unit] else context.reactive_nitrogen.previous_non_band_ammonia_oxidation_capacity_g_n[unit];
    const previous_ammonia_total = if (context.nutrient_competition) |history| history.soil_previous_total[@intFromEnum(if (band) competition_history.SoilPool.ammonium_band else competition_history.SoilPool.ammonium_non_band)][layer] else if (band) context.reactive_nitrogen.previous_total_band_ammonium_demand_g_n[layer] else context.reactive_nitrogen.previous_total_non_band_ammonium_demand_g_n[layer];
    const active_fraction = context.environment.microbial_active_fraction[unit];
    return .{
        .nitrite_fraction = nitrite_fraction,
        .nitrite_concentration_g_n_per_m3 = if (nitrite_volume > 0) nitrite_amount / nitrite_volume else 0,
        .nitrite_amount_g_n = nitrite_amount,
        .ammonium_amount_g_n = ammonium_amount,
        .nitrite_competition_fraction = competition(previous_nitrite_total, previous_nitrite_capacity, active_fraction * nitrite_fraction, context.negligible_nitrogen_g_n, context.parameters.denitrification.minimum_competition_fraction),
        .ammonium_competition_fraction = competition(previous_ammonia_total, previous_ammonia_capacity, active_fraction * ammonium_fraction, context.negligible_nitrogen_g_n, context.parameters.nitrification.minimum_competition_fraction),
        .preceding_ammonia_oxidation_g_n = (if (band) context.result.band_ammonia_oxidation_potential_g_n[unit] else context.result.non_band_ammonia_oxidation_potential_g_n[unit]) * context.oxygen_state.demand_satisfaction_fraction[unit],
    };
}

fn competition(previous_total: f64, previous_capacity: f64, fallback: f64, negligible: f64, minimum: f64) f64 {
    return @max(minimum, if (previous_total > negligible) previous_capacity / previous_total else fallback);
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.model_grid.layer_count;
    const units = try std.math.mul(usize, layers, context.result.process_unit_count_per_layer);
    if (range.first > range.end or range.end > layers or context.reactive_nitrogen.layer_count != layers or context.chemistry_state.cell_count != layers or context.oxygen_state.demand_satisfaction_fraction.len != units or context.environment.roles.len != units or context.retention_curve.len != layers or context.matrix_bulk_volume_m3.len != layers or (context.zone_fractions_by_layer.len != 0 and context.zone_fractions_by_layer.len != layers)) return error.SoilAutotrophicDenitrificationDimensionMismatch;
    if (!std.math.isFinite(context.nitrogen_molar_mass_g_per_mol) or context.nitrogen_molar_mass_g_per_mol <= 0 or !std.math.isFinite(context.timestep_h) or context.timestep_h <= 0 or !std.math.isFinite(context.negligible_water_volume_m3) or context.negligible_water_volume_m3 < 0 or !std.math.isFinite(context.negligible_nitrogen_g_n) or context.negligible_nitrogen_g_n < 0) return error.InvalidSoilAutotrophicDenitrificationInput;
}

test "runtime ammonia oxidizer performs oxygen-deficit autotrophic denitrification" {
    const config = @import("../../core/config.zig").SimulationConfig{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 };
    var model_grid = try grid.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    model_grid.matrix_liquid_water_m3[0] = 0.3;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.aqueous[0].ammonium_non_band = 1;
    chemistry_state.aqueous[0].ammonium_band = 1;
    var reactive_state = try reactive.State.init(std.testing.allocator, 1, 1);
    defer reactive_state.deinit();
    reactive_state.non_band_nitrite_g_n[0] = 1;
    reactive_state.band_nitrite_g_n[0] = 1;
    var result = try fluxes.State.init(std.testing.allocator, 1, 1);
    defer result.deinit();
    result.aerobic_oxygen_demand_g_o[0] = 1;
    result.non_band_ammonia_oxidation_potential_g_n[0] = 0.1;
    result.band_ammonia_oxidation_potential_g_n[0] = 0.1;
    var oxygen_state = try oxygen.State.init(std.testing.allocator, 1, 1, 1);
    defer oxygen_state.deinit();
    oxygen_state.oxygen_uptake_g_o[0] = 0.1;
    oxygen_state.demand_satisfaction_fraction[0] = 0.1;
    var environment = try nitrifier_environment.State.init(std.testing.allocator, 1, 1);
    defer environment.deinit();
    environment.roles[0] = .ammonia_oxidizer;
    environment.aqueous_co2_activity[0] = 1;
    environment.microbial_active_fraction[0] = 1;
    const curve = retention.ResolvedCurve{ .porosity_fraction = 0.5, .curve = .{ .field_capacity_fraction = 0.25, .wilting_point_fraction = 0.1, .saturation_water_potential_megapascal = -0.0005, .field_capacity_water_potential_megapascal = -0.033, .wilting_point_water_potential_megapascal = -1.5, .minimum_water_potential_megapascal = -1.5e12, .saturation_to_field_shape = 0.5, .below_wilting_shape = 0.5 } };
    const parameters: nitrogen_parameters.Parameters = .{
        .nitrification = .{ .minimum_competition_fraction = 0.001, .inhibition_decay_per_h = 0, .inhibition_decay_ammonium_constant_g_n_per_m3 = 1, .ammonia_product_inhibition_g_n_per_m3 = 1, .ammonium_half_saturation_g_n_per_m3 = 1, .nitrite_half_saturation_g_n_per_m3 = 1, .ammonia_oxidation_rate_g_n_per_g_c_h = 1, .nitrite_oxidation_rate_g_n_per_g_c_h = 1, .ammonia_oxidizer_carbon_efficiency_g_c_per_g_n = 0.3, .nitrite_oxidizer_carbon_efficiency_g_c_per_g_n = 0.1, .growth_respiration_fraction = 0.5, .oxygen_per_respired_carbon_g_o_per_g_c = 2.667, .oxygen_per_ammonium_n_g_o_per_g_n = 3.429, .oxygen_per_nitrite_n_g_o_per_g_n = 1.143 },
        .denitrification = .{ .minimum_competition_fraction = 0.001, .nitrate_half_saturation_g_n_per_m3 = 1.4, .nitrite_half_saturation_g_n_per_m3 = 1.4, .nitrous_oxide_half_saturation_g_n_per_m3 = 0.014, .product_inhibition_rate_g_n_per_m3_step = 1, .carbon_per_nitrate_n_g_c_per_g_n = 0.429, .carbon_per_nitrite_n_g_c_per_g_n = 0.429, .carbon_per_nitrous_oxide_n_g_c_per_g_n = 0.214, .nitrate_n_per_unmet_oxygen_g_n_per_g_o = 0.875 },
        .autotrophic_denitrification = .{ .anaerobic_growth_respiration_fraction = 0.5, .additional_ammonium_oxidation_per_nitrite_reduction = 0.333 },
        .chemodenitrification = .{ .reaction_rate_per_h = 0, .minimum_competition_fraction = 0.001, .negligible_demand_g_n = 1e-12, .nitrous_oxide_product_fraction = 0.5, .dinitrogen_product_fraction = 0, .dissolved_organic_nitrogen_product_fraction = 0.5 },
        .nitrous_acid_dissociation_mol_per_m3 = 0.45,
        .microbial_thermal_adaptation_offset_k = 0,
        .nitrifier_indices = .{ .autotrophic_substrate_index = 0, .ammonia_oxidizer_population_index = 0, .nitrite_oxidizer_population_index = 1, .heterotrophic_denitrifier_population_index = 1 },
        .nitrifier_environment = .{ .labile_biomass_fraction = 0.5, .ammonia_oxidizer_target_nitrogen_per_carbon_g_n_per_g_c = 0.1, .nitrite_oxidizer_target_nitrogen_per_carbon_g_n_per_g_c = 0.1, .ammonia_oxidizer_target_phosphorus_per_carbon_g_p_per_g_c = 0.01, .nitrite_oxidizer_target_phosphorus_per_carbon_g_p_per_g_c = 0.01, .aqueous_co2_half_saturation_g_c_per_m3 = 1, .water_potential_sensitivity_per_megapascal = 0.1 },
        .oxygen_uptake = .{ .microbial_radius_m = 1e-6, .microbial_count_per_g_c = 1, .oxygen_half_saturation_g_o_per_m3 = 0.064, .hygroscopic_water_potential_megapascal = -1.5e4, .air_water_exchange_reference_time_h = 0.5, .wet_exchange_exponent = 12, .dry_exchange_exponent = 12, .minimum_transition_water_fraction = 0.5, .aqueous_tortuosity_coefficient = 0.7, .minimum_allocation_fraction = 0.001, .negligible_oxygen_demand_g_o = 1e-12 },
        .heterotrophic_respiration = .{ .substrate_unlimited_respiration_per_h = 0.125, .target_nitrogen_per_carbon_g_n_per_g_c = 0.1, .target_phosphorus_per_carbon_g_p_per_g_c = 0.01, .doc_half_saturation_g_c_per_m3 = 12, .acetate_half_saturation_g_c_per_m3 = 12, .doc_respiration_requirement_g_c_per_g_c = 0.5, .acetate_respiration_requirement_g_c_per_g_c = 0.42016806722689076, .water_potential_sensitivity_per_megapascal = 0.1, .oxygen_per_respired_carbon_g_o_per_g_c = 2.667, .specific_maintenance_respiration_g_c_per_g_n_per_h = 0.01, .decomposition_density_half_saturation_g_c_per_g_c = 0.01, .maintenance_density_half_saturation_g_c_per_g_c = 1e-6, .acidity_half_response_mol_per_m3 = 1, .denitrification_growth_respiration_fraction_g_c_per_g_c = 0.7142857142857143 },
        .microbial_mineral_exchange = .{ .ammonium_maximum_uptake_g_n_per_m2_h = 0.014, .ammonium_minimum_concentration_g_n_per_m3 = 0.0125, .ammonium_half_saturation_g_n_per_m3 = 0.40, .nitrate_maximum_uptake_g_n_per_m2_h = 0.014, .nitrate_minimum_concentration_g_n_per_m3 = 0.03, .nitrate_half_saturation_g_n_per_m3 = 0.35, .phosphate_maximum_uptake_g_p_per_m2_h = 0.003, .phosphate_minimum_concentration_g_p_per_m3 = 0.009, .phosphate_half_saturation_g_p_per_m3 = 0.18, .phosphorus_molar_mass_g_per_mol = 31 },
        .nonsymbiotic_nitrogen_fixation = .{ .aerobic_diazotroph_population_index = 5, .anaerobic_diazotroph_population_index = 6, .aerobic_yield_g_n_per_g_c = 0.25, .anaerobic_yield_g_n_per_g_c = 0.02, .dinitrogen_half_saturation_g_n_per_m3 = 0.14, .nonstructural_to_structural_rate_per_h = 0.25 },
        .microbial_turnover = .{ .labile_basal_decomposition_rate_per_h = 0.01, .resistant_basal_decomposition_rate_per_h = 0.001, .minimum_carbon_recycling_fraction = 0.167, .carbon_recycling_range_fraction = 0.333, .maximum_nitrogen_recycling_fraction = 0.333, .maximum_phosphorus_recycling_fraction = 0.333, .humification_intercept = 0.150, .humification_clay_coefficient = 0.300, .humification_maximum_clay_fraction = 0.333, .woody_colonization_per_g_respired_carbon = 0.25, .fine_litter_colonization_per_g_respired_carbon = 2, .manure_colonization_per_g_respired_carbon = 5, .particulate_colonization_per_g_respired_carbon = 1, .humus_colonization_per_g_respired_carbon = 0.5, .humification_organic_carbon_coefficient_per_g_per_megagram = 0.182e-6 },
    };
    var context: ApplyContext = .{ .result = &result, .reactive_nitrogen = &reactive_state, .chemistry_state = &chemistry_state, .model_grid = &model_grid, .oxygen_state = &oxygen_state, .environment = &environment, .retention_curve = &.{curve}, .matrix_bulk_volume_m3 = &.{1}, .zone_fractions = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 }, .parameters = parameters, .nitrogen_molar_mass_g_per_mol = 14, .timestep_h = 1, .negligible_water_volume_m3 = 1e-12, .negligible_nitrogen_g_n = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(result.non_band_autotrophic_nitrite_reduction_potential_g_n[0] > 0);
    try std.testing.expectApproxEqRel(result.non_band_autotrophic_nitrite_reduction_potential_g_n[0] * 0.333, result.non_band_autotrophic_ammonium_oxidation_potential_g_n[0], 1e-12);
    try std.testing.expect(result.denitrification_respiration_g_c[0] > 0);
}
