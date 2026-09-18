const std = @import("std");
const compute = @import("../../core/compute.zig");
const grid = @import("../../state/grid.zig");
const gas = @import("../gas/transport.zig");
const organic = @import("../organic/initialization.zig");
const microbial = @import("state.zig");
const chemistry = @import("../solute/chemistry_state.zig");
const zones = @import("../solute/charge_classification.zig");
const reaction = @import("denitrification.zig");
const reactive = @import("../nutrients/reactive_nitrogen_state.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const oxygen = @import("../gas/oxygen_allocation.zig");
const parameters = @import("../nutrients/nitrogen_parameters.zig");
const competition_history = @import("../nutrients/competition_history.zig");

/// Builds the K=0..4,N=2 NITRO denitrification potentials after the shared
/// oxygen solve. Inventory commit happens in production via
/// `nitrogen_state_update.zig`'s `applyZone`, not via
/// `denitrification.state_update` (NITRIFICATION-DENITRIFICATION-STATE-UPDATE-DEAD-001:
/// that function is a zero-caller reference implementation).
pub const ApplyContext = struct {
    result: *fluxes.State,
    reactive_nitrogen: *const reactive.State,
    nutrient_competition: ?*const competition_history.State = null,
    chemistry_state: *const chemistry.State,
    organic_state: *const organic.State,
    microbial_state: *const microbial.State,
    gas_state: *const gas.State,
    model_grid: *const grid.GridState,
    oxygen_state: *const oxygen.State,
    zone_fractions: zones.ZoneFractions,
    zone_fractions_by_layer: []const zones.ZoneFractions = &.{},
    nitrogen_parameters: parameters.Parameters,
    nitrogen_molar_mass_g_per_mol: f64,
    timestep_h: f64,
    negligible_water_volume_m3: f64,
    negligible_nitrogen_g_n: f64,
};

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const actual_population_count = context.microbial_state.population_count;
    const denitrifier = context.nitrogen_parameters.nitrifier_indices.heterotrophic_denitrifier_population_index;
    for (range.first..range.end) |layer| {
        const water_m3 = context.model_grid.matrix_liquid_water_m3[layer];
        if (water_m3 <= context.negligible_water_volume_m3) continue;
        const n2o_index = try gas.massIndex(layer, .nitrous_oxide, context.gas_state.cell_count);
        const n2o_g_n = context.gas_state.dissolved_mass_g[n2o_index];
        const active_water_m3 = context.result.layer_biologically_active_water_m3[layer];
        var total_raw_nitrous_oxide_competition: f64 = 0;
        for (0..@min(context.microbial_state.substrate_count, organic.substrate_count)) |substrate| {
            if (substrate == context.nitrogen_parameters.nitrifier_indices.autotrophic_substrate_index) continue;
            const unit = layer * context.result.process_unit_count_per_layer + substrate * actual_population_count + denitrifier;
            total_raw_nitrous_oxide_competition += reaction.competitionFraction(
                context.reactive_nitrogen.previous_total_nitrous_oxide_demand_g_n[layer],
                context.reactive_nitrogen.previous_nitrous_oxide_reduction_capacity_g_n[unit],
                context.result.aerobic_fallback_active_fraction[unit],
                context.negligible_nitrogen_g_n,
                context.nitrogen_parameters.denitrification.minimum_competition_fraction,
            );
        }
        for (0..@min(context.microbial_state.substrate_count, organic.substrate_count)) |substrate| {
            if (substrate == context.nitrogen_parameters.nitrifier_indices.autotrophic_substrate_index) continue;
            const unit = layer * context.result.process_unit_count_per_layer + substrate * actual_population_count + denitrifier;
            const mobile = layer * organic.substrate_count + substrate;
            const oxygen_satisfaction = context.oxygen_state.demand_satisfaction_fraction[unit];
            const residual_doc_after_aerobic_g_c = @max(0, context.organic_state.dissolved[mobile].carbon_g_c * context.result.doc_competition_fraction[unit] - context.result.doc_respiration_demand_g_c[unit] * oxygen_satisfaction);
            // CGOMD later divides denitrification respiration by ENOX to
            // include growth carbon. Budget the redox respiration by ENOX
            // here so the implicit whole-hour replacement cannot consume
            // more DOC than OQCZ3 after aerobic respiration.
            const available_doc_g_c = residual_doc_after_aerobic_g_c * context.nitrogen_parameters.heterotrophic_respiration.denitrification_growth_respiration_fraction_g_c_per_g_c;
            const raw_nitrous_oxide_competition = reaction.competitionFraction(
                context.reactive_nitrogen.previous_total_nitrous_oxide_demand_g_n[layer],
                context.reactive_nitrogen.previous_nitrous_oxide_reduction_capacity_g_n[unit],
                context.result.aerobic_fallback_active_fraction[unit],
                context.negligible_nitrogen_g_n,
                context.nitrogen_parameters.denitrification.minimum_competition_fraction,
            );
            const potential = try reaction.calculateHeterotrophicPotential(.{
                .non_band = makeZone(context.*, layer, unit, water_m3, false),
                .band = makeZone(context.*, layer, unit, water_m3, true),
                .oxygen_demand_g_o = context.result.aerobic_oxygen_demand_g_o[unit],
                .oxygen_reduction_g_o = context.oxygen_state.oxygen_uptake_g_o[unit],
                .biologically_active_water_m3 = active_water_m3,
                .substrate_complex_fraction = context.result.substrate_complex_fraction[unit],
                .available_doc_g_c = available_doc_g_c,
                .microbial_active_fraction = context.result.aerobic_fallback_active_fraction[unit],
                .nitrous_oxide_concentration_g_n_per_m3 = if (active_water_m3 > context.negligible_water_volume_m3) n2o_g_n / active_water_m3 else 0,
                .nitrous_oxide_amount_g_n = n2o_g_n,
                .previous_total_nitrous_oxide_demand_g_n = context.reactive_nitrogen.previous_total_nitrous_oxide_demand_g_n[layer],
                .previous_nitrous_oxide_reduction_capacity_g_n = context.reactive_nitrogen.previous_nitrous_oxide_reduction_capacity_g_n[unit],
                .nitrous_oxide_competition_fraction = raw_nitrous_oxide_competition / @max(1, total_raw_nitrous_oxide_competition),
                .timestep_h = context.timestep_h,
                .negligible_water_volume_m3 = context.negligible_water_volume_m3,
                .negligible_nitrogen_g_n = context.negligible_nitrogen_g_n,
            }, context.nitrogen_parameters.denitrification);
            context.result.non_band_nitrate_reduction_potential_g_n[unit] = potential.non_band_nitrate_reduction_g_n;
            context.result.band_nitrate_reduction_potential_g_n[unit] = potential.band_nitrate_reduction_g_n;
            context.result.non_band_heterotrophic_nitrite_reduction_potential_g_n[unit] = potential.non_band_nitrite_reduction_g_n;
            context.result.band_heterotrophic_nitrite_reduction_potential_g_n[unit] = potential.band_nitrite_reduction_g_n;
            context.result.nitrous_oxide_reduction_potential_g_n[unit] = potential.nitrous_oxide_reduction_g_n;
            context.result.non_band_nitrate_reduction_capacity_g_n[unit] = potential.non_band_nitrate_capacity_g_n;
            context.result.band_nitrate_reduction_capacity_g_n[unit] = potential.band_nitrate_capacity_g_n;
            context.result.non_band_nitrite_reduction_capacity_g_n[unit] += potential.non_band_nitrite_capacity_g_n;
            context.result.band_nitrite_reduction_capacity_g_n[unit] += potential.band_nitrite_capacity_g_n;
            context.result.nitrous_oxide_reduction_capacity_g_n[unit] = potential.nitrous_oxide_capacity_g_n;
            context.result.denitrification_respiration_g_c[unit] += potential.nitrate_reduction_respiration_g_c + potential.nitrite_reduction_respiration_g_c + potential.nitrous_oxide_reduction_respiration_g_c;
        }
    }
}

test "nitrous oxide minimum competition remains a conservative shared allocation" {
    const raw = [_]f64{ 0.8, 0.05, 0.05, 0.05, 0.05, 0.05 };
    var total_raw: f64 = 0;
    for (raw) |fraction| total_raw += fraction;
    var normalized_total: f64 = 0;
    for (raw) |fraction| normalized_total += fraction / @max(1, total_raw);
    try std.testing.expectApproxEqAbs(@as(f64, 1), normalized_total, 1e-15);
}

fn makeZone(context: ApplyContext, layer: usize, unit: usize, water_m3: f64, band: bool) reaction.Zone {
    const fractions = if (context.zone_fractions_by_layer.len == 0) context.zone_fractions else context.zone_fractions_by_layer[layer];
    const fraction = if (band) fractions.nitrate_band else fractions.nitrate_non_band;
    const aqueous = context.chemistry_state.aqueous[layer];
    const nitrate_concentration = (if (band) aqueous.nitrate_band else aqueous.nitrate_non_band) * context.nitrogen_molar_mass_g_per_mol;
    const nitrate_amount = nitrate_concentration * water_m3 * fraction;
    const nitrite_amount = if (band) context.reactive_nitrogen.band_nitrite_g_n[layer] else context.reactive_nitrogen.non_band_nitrite_g_n[layer];
    const zone_water = water_m3 * fraction;
    return .{
        .nitrate_fraction = fraction,
        .nitrite_fraction = fraction,
        .nitrate_concentration_g_n_per_m3 = nitrate_concentration,
        .nitrite_concentration_g_n_per_m3 = if (zone_water > context.negligible_water_volume_m3) nitrite_amount / zone_water else 0,
        .nitrate_amount_g_n = nitrate_amount,
        .nitrite_amount_g_n = nitrite_amount,
        .previous_total_nitrate_demand_g_n = if (context.nutrient_competition) |history| history.soil_previous_total[@intFromEnum(if (band) competition_history.SoilPool.nitrate_band else competition_history.SoilPool.nitrate_non_band)][layer] else if (band) context.reactive_nitrogen.previous_total_band_nitrate_demand_g_n[layer] else context.reactive_nitrogen.previous_total_non_band_nitrate_demand_g_n[layer],
        .previous_nitrate_reduction_capacity_g_n = if (band) context.reactive_nitrogen.previous_band_nitrate_reduction_capacity_g_n[unit] else context.reactive_nitrogen.previous_non_band_nitrate_reduction_capacity_g_n[unit],
        .previous_total_nitrite_demand_g_n = if (band) context.reactive_nitrogen.previous_total_band_nitrite_demand_g_n[layer] else context.reactive_nitrogen.previous_total_non_band_nitrite_demand_g_n[layer],
        .previous_nitrite_reduction_capacity_g_n = if (band) context.reactive_nitrogen.previous_band_nitrite_reduction_capacity_g_n[unit] else context.reactive_nitrogen.previous_non_band_nitrite_reduction_capacity_g_n[unit],
        .fallback_available_fraction = fraction,
    };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.model_grid.layer_count;
    const units = try std.math.mul(usize, layers, context.result.process_unit_count_per_layer);
    if (range.first > range.end or range.end > layers or context.reactive_nitrogen.layer_count != layers or context.chemistry_state.cell_count != layers or context.organic_state.layer_count != layers or context.gas_state.cell_count != layers or context.oxygen_state.oxygen_uptake_g_o.len != units or context.microbial_state.layer_count * context.microbial_state.cell_count != layers or context.result.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count or (context.zone_fractions_by_layer.len != 0 and context.zone_fractions_by_layer.len != layers)) return error.SoilHeterotrophicDenitrificationDimensionMismatch;
    const population_count = context.microbial_state.population_count;
    if (context.nitrogen_parameters.nitrifier_indices.heterotrophic_denitrifier_population_index >= population_count or !std.math.isFinite(context.nitrogen_molar_mass_g_per_mol) or context.nitrogen_molar_mass_g_per_mol <= 0 or !std.math.isFinite(context.timestep_h) or context.timestep_h <= 0 or !std.math.isFinite(context.negligible_water_volume_m3) or context.negligible_water_volume_m3 < 0 or !std.math.isFinite(context.negligible_nitrogen_g_n) or context.negligible_nitrogen_g_n < 0) return error.InvalidSoilHeterotrophicDenitrificationInput;
}

test "runtime soil denitrifier builds sequential nitrogen reduction potentials" {
    const config = @import("../../core/config.zig").SimulationConfig{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 };
    var model_grid = try grid.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    model_grid.matrix_liquid_water_m3[0] = 0.3;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 6, 2);
    defer microbial_state.deinit();
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.dissolved[1].carbon_g_c = 10;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.aqueous[0].nitrate_non_band = 1;
    chemistry_state.aqueous[0].nitrate_band = 1;
    var reactive_state = try reactive.State.init(std.testing.allocator, 1, 12);
    defer reactive_state.deinit();
    reactive_state.non_band_nitrite_g_n[0] = 1;
    reactive_state.band_nitrite_g_n[0] = 1;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[try gas.massIndex(0, .nitrous_oxide, 1)] = 1;
    var result = try fluxes.State.init(std.testing.allocator, 1, 12);
    defer result.deinit();
    const unit: usize = 3;
    result.aerobic_oxygen_demand_g_o[unit] = 4;
    result.doc_respiration_demand_g_c[unit] = 0.1;
    result.doc_competition_fraction[unit] = 1;
    result.substrate_complex_fraction[unit] = 0.5;
    result.aerobic_fallback_active_fraction[unit] = 1;
    result.layer_biologically_active_water_m3[0] = 0.2;
    var oxygen_state = try oxygen.State.init(std.testing.allocator, 1, 12, 1);
    defer oxygen_state.deinit();
    oxygen_state.oxygen_uptake_g_o[unit] = 0.1;
    oxygen_state.demand_satisfaction_fraction[unit] = 0.025;
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
    const nitrogen_parameters = try parameters.parse(source);
    var context: ApplyContext = .{ .result = &result, .reactive_nitrogen = &reactive_state, .chemistry_state = &chemistry_state, .organic_state = &organic_state, .microbial_state = &microbial_state, .gas_state = &gas_state, .model_grid = &model_grid, .oxygen_state = &oxygen_state, .zone_fractions = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 }, .nitrogen_parameters = nitrogen_parameters, .nitrogen_molar_mass_g_per_mol = 14, .timestep_h = 1, .negligible_water_volume_m3 = 1e-12, .negligible_nitrogen_g_n = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(result.non_band_nitrate_reduction_potential_g_n[unit] > 0);
    try std.testing.expect(result.non_band_heterotrophic_nitrite_reduction_potential_g_n[unit] > 0);
    try std.testing.expect(result.nitrous_oxide_reduction_potential_g_n[unit] > 0);
    try std.testing.expect(result.denitrification_respiration_g_c[unit] > 0);
    const residual_doc_after_aerobic_g_c = organic_state.dissolved[1].carbon_g_c * result.doc_competition_fraction[unit] - result.doc_respiration_demand_g_c[unit] * oxygen_state.demand_satisfaction_fraction[unit];
    try std.testing.expect(result.denitrification_respiration_g_c[unit] / nitrogen_parameters.heterotrophic_respiration.denitrification_growth_respiration_fraction_g_c_per_g_c <= residual_doc_after_aerobic_g_c + 1e-12);
    try std.testing.expectEqual(@as(f64, 0), result.non_band_nitrate_reduction_potential_g_n[unit - 1]);
}
