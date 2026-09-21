const std = @import("std");
const compute = @import("../../core/compute.zig");
const grid = @import("../../state/grid.zig");
const microbial = @import("state.zig");
const metabolism = @import("metabolism.zig");
const organic = @import("../organic/initialization.zig");
const chemistry = @import("../solute/chemistry_state.zig");
const zones = @import("../solute/charge_classification.zig");
const history = @import("phosphorus_state.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const nitrogen_parameters = @import("../nutrients/nitrogen_parameters.zig");
const competition_history = @import("../nutrients/competition_history.zig");

pub const ApplyContext = struct {
    result: *fluxes.State,
    phosphorus_history: *const history.State,
    nutrient_competition: ?*const competition_history.State = null,
    microbial_state: *const microbial.State,
    chemistry_state: *const chemistry.State,
    model_grid: *const grid.GridState,
    matric_plus_osmotic_potential_megapascal: []const f64,
    thermal_adaptation_offset_k_by_cell: []const f64,
    zone_fractions: zones.ZoneFractions,
    zone_fractions_by_layer: []const zones.ZoneFractions = &.{},
    parameters: nitrogen_parameters.Parameters,
    timestep_h: f64,
    negligible_carbon_g_c: f64,
    negligible_phosphorus_g_p: f64,
    /// `solute.f:610`-style `ZEROS2` floor (issue-073 Finding B): this file
    /// previously had no floor at all on `water_m3` for `exchangePair`'s
    /// concentration->mass conversion; widened via a per-layer skip,
    /// mirroring `autotrophic_denitrification_step.zig`'s/
    /// `heterotrophic_denitrification_step.zig`'s own established pattern.
    negligible_water_volume_m3: f64,
};

/// Ports NITRO RIPOP/RIPOO/RIPBO/RIPO4/RIPOB followed by
/// RIP1P/RIPO1/RIPB1/RIP14/RIP1B. Positive flux immobilizes P.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const populations = context.microbial_state.population_count;
    const substrates = context.microbial_state.substrate_count;
    const p = context.parameters.microbial_mineral_exchange;
    const surface_area_m2_per_g_c = context.parameters.oxygen_uptake.microbial_count_per_g_c * 4 * std.math.pi * std.math.pow(f64, context.parameters.oxygen_uptake.microbial_radius_m, 2);
    for (range.first..range.end) |layer| {
        const zone_fractions = if (context.zone_fractions_by_layer.len == 0) context.zone_fractions else context.zone_fractions_by_layer[layer];
        const water_m3 = context.model_grid.matrix_liquid_water_m3[layer];
        if (water_m3 <= context.negligible_water_volume_m3) continue;
        const fractions = [2]f64{ zone_fractions.phosphate_non_band, zone_fractions.phosphate_band };
        const h2_concentration = [2]f64{ context.chemistry_state.non_band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 * p.phosphorus_molar_mass_g_per_mol, context.chemistry_state.band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 * p.phosphorus_molar_mass_g_per_mol };
        const hp_concentration = [2]f64{ context.chemistry_state.non_band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 * p.phosphorus_molar_mass_g_per_mol, context.chemistry_state.band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 * p.phosphorus_molar_mass_g_per_mol };
        var total_active_g_c: f64 = 0;
        const first = layer * context.result.process_unit_count_per_layer;
        for (0..substrates) |substrate| for (0..populations) |population| {
            const index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
            total_active_g_c += context.microbial_state.structural[index * 2].carbon_g_c / context.parameters.nitrifier_environment.labile_biomass_fraction;
        };
        for (0..substrates) |substrate| for (0..populations) |population| {
            const index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
            const unit = first + substrate * populations + population;
            const active_g_c = context.microbial_state.structural[index * 2].carbon_g_c / context.parameters.nitrifier_environment.labile_biomass_fraction;
            const active_fraction = if (total_active_g_c > context.negligible_carbon_g_c) active_g_c / total_active_g_c else 0;
            // NITRO.F 593--604: WFNG uses the fungal-specific 0.05 MPa-1
            // sensitivity only for the fungal population (source N=3, this
            // codebase's population index 2) within the heterotrophic
            // substrate complexes (source K<=4); the autotrophic complex
            // (source K=5, `organic.autotrophic_substrate_index`) always
            // uses the bacterial sensitivity regardless of population index.
            const is_fungus = substrate < organic.substrate_count and population == 2;
            const water_sensitivity_per_megapascal: f64 = if (is_fungus) 0.05 else context.parameters.heterotrophic_respiration.water_potential_sensitivity_per_megapascal;
            const activity = try metabolism.growthTemperatureResponse(context.model_grid.soil_temperature_k[layer], context.thermal_adaptation_offset_k_by_cell[layer / context.microbial_state.layer_count]) * @exp(water_sensitivity_per_megapascal * context.matric_plus_osmotic_potential_megapascal[layer]);
            const area_activity = surface_area_m2_per_g_c * active_g_c * activity * context.timestep_h;
            const nonstructural = context.microbial_state.nonstructural[index];
            const phosphorus_demand = nonstructural.carbon_g_c * context.parameters.heterotrophic_respiration.target_phosphorus_per_carbon_g_p_per_g_c - nonstructural.phosphorus_g_p;
            const h2 = exchangePair(context.*, layer, unit, phosphorus_demand, h2_concentration, fractions, p.phosphate_minimum_concentration_g_p_per_m3, p.phosphate_half_saturation_g_p_per_m3, p.phosphate_maximum_uptake_g_p_per_m2_h * area_activity, active_fraction, water_m3, true);
            const hp_demand = @max(0, phosphorus_demand - h2.flux[0] - h2.flux[1]);
            const hp = if (hp_demand > 0) exchangePair(context.*, layer, unit, hp_demand, hp_concentration, fractions, 0.25 * p.phosphate_minimum_concentration_g_p_per_m3, p.phosphate_half_saturation_g_p_per_m3, 0.25 * p.phosphate_maximum_uptake_g_p_per_m2_h * area_activity, active_fraction, water_m3, false) else PairResult{};
            context.result.non_band_microbial_h2po4_exchange_g_p[unit] = h2.flux[0];
            context.result.band_microbial_h2po4_exchange_g_p[unit] = h2.flux[1];
            context.result.non_band_microbial_hpo4_exchange_g_p[unit] = hp.flux[0];
            context.result.band_microbial_hpo4_exchange_g_p[unit] = hp.flux[1];
            context.result.non_band_microbial_h2po4_capacity_g_p[unit] = h2.capacity[0];
            context.result.band_microbial_h2po4_capacity_g_p[unit] = h2.capacity[1];
            context.result.non_band_microbial_hpo4_capacity_g_p[unit] = hp.capacity[0];
            context.result.band_microbial_hpo4_capacity_g_p[unit] = hp.capacity[1];
        };
    }
}

const PairResult = struct { flux: [2]f64 = .{ 0, 0 }, capacity: [2]f64 = .{ 0, 0 } };

fn exchangePair(context: ApplyContext, layer: usize, unit: usize, demand: f64, concentration: [2]f64, fractions: [2]f64, minimum: f64, half_saturation: f64, uptake_capacity: f64, active_fraction: f64, water_m3: f64, h2po4: bool) PairResult {
    if (demand <= 0) return .{ .flux = .{ demand * fractions[0], demand * fractions[1] } };
    var result = PairResult{};
    const limited = @min(demand, uptake_capacity);
    inline for (0..2) |zone| {
        const available_concentration = @max(0, concentration[zone] - minimum);
        result.capacity[zone] = fractions[zone] * limited * available_concentration / (available_concentration + half_saturation);
        const total_previous = if (context.nutrient_competition) |accepted| accepted.soil_previous_total[@intFromEnum(if (h2po4) (if (zone == 0) competition_history.SoilPool.h2po4_non_band else competition_history.SoilPool.h2po4_band) else (if (zone == 0) competition_history.SoilPool.hpo4_non_band else competition_history.SoilPool.hpo4_band))][layer] else if (h2po4) (if (zone == 0) context.phosphorus_history.previous_total_non_band_h2po4_demand_g_p[layer] else context.phosphorus_history.previous_total_band_h2po4_demand_g_p[layer]) else (if (zone == 0) context.phosphorus_history.previous_total_non_band_hpo4_demand_g_p[layer] else context.phosphorus_history.previous_total_band_hpo4_demand_g_p[layer]);
        const previous = if (h2po4) (if (zone == 0) context.phosphorus_history.previous_non_band_h2po4_capacity_g_p[unit] else context.phosphorus_history.previous_band_h2po4_capacity_g_p[unit]) else (if (zone == 0) context.phosphorus_history.previous_non_band_hpo4_capacity_g_p[unit] else context.phosphorus_history.previous_band_hpo4_capacity_g_p[unit]);
        const share = @max(context.parameters.nitrification.minimum_competition_fraction, if (total_previous > context.negligible_phosphorus_g_p) previous / total_previous else active_fraction * fractions[zone]);
        result.flux[zone] = @min(result.capacity[zone], share * @max(0, (concentration[zone] - minimum) * water_m3 * fractions[zone]) * context.timestep_h);
    }
    return result;
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.model_grid.layer_count;
    if (range.first > range.end or range.end > layers or context.phosphorus_history.layer_count != layers or context.chemistry_state.cell_count != layers or context.microbial_state.cell_count * context.microbial_state.layer_count != layers or context.result.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count or context.phosphorus_history.process_unit_count_per_layer != context.result.process_unit_count_per_layer or context.matric_plus_osmotic_potential_megapascal.len != layers or context.thermal_adaptation_offset_k_by_cell.len != context.microbial_state.cell_count or (context.zone_fractions_by_layer.len != 0 and context.zone_fractions_by_layer.len != layers)) return error.SoilMicrobialPhosphorusExchangeDimensionMismatch;
    for (context.thermal_adaptation_offset_k_by_cell) |offset_k| if (!std.math.isFinite(offset_k)) return error.NonFiniteMicrobialThermalAdaptationOffset;
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h <= 0 or !std.math.isFinite(context.negligible_carbon_g_c) or context.negligible_carbon_g_c < 0 or !std.math.isFinite(context.negligible_phosphorus_g_p) or context.negligible_phosphorus_g_p < 0) return error.InvalidSoilMicrobialPhosphorusExchangeInput;
    if (!std.math.isFinite(context.negligible_water_volume_m3) or context.negligible_water_volume_m3 < 0) return error.InvalidSoilMicrobialPhosphorusExchangeInput;
}

test "runtime microbial phosphate exchange immobilizes deficits and mineralizes surplus" {
    const config = @import("../../core/config.zig").SimulationConfig{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 };
    var model_grid = try grid.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    model_grid.matrix_liquid_water_m3[0] = 1;
    model_grid.soil_temperature_k[0] = 293.15;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer microbial_state.deinit();
    microbial_state.structural[0] = .{ .carbon_g_c = 0.55, .nitrogen_g_n = 0.055, .phosphorus_g_p = 0.0055 };
    microbial_state.nonstructural[0].carbon_g_c = 1;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 1;
    var phosphorus_history = try history.State.init(std.testing.allocator, 1, 1);
    defer phosphorus_history.deinit();
    var result = try fluxes.State.init(std.testing.allocator, 1, 1);
    defer result.deinit();
    const source =
        "soil_nitrification 0.001 0.0002 7000 14 1.4 1.4 0.125 0.125 0.3 0.1 0.5 2.667 3.429 1.143\n" ++
        "soil_denitrification 0.001 1.4 1.4 0.014 1 0.429 0.429 0.214 0.875\nsoil_autotrophic_denitrification 0.5 0.333\n" ++
        "soil_chemodenitrification 0.0005 0.001 1e-12 0.5 0 0.5\nnitrous_acid_dissociation_mol_per_m3 0.45\nsoil_microbial_thermal_adaptation_offset_k 0\n" ++
        "soil_nitrifier_indices 5 0 1 1\nsoil_nitrifier_environment 0.55 0.1 0.1 0.01 0.01 12 0.1\n" ++
        "soil_oxygen_uptake 1e-6 2.3866348449e11 0.064 -1.5e4 0.5 12 12 0.5 0.7 0.001 1e-12\n" ++
        "soil_heterotrophic_respiration 0.125 0.1 0.01 12 12 0.5 0.42016806722689076 0.1 2.667 0.01 0.01 1e-6 1 0.7142857142857143\n" ++
        "soil_microbial_mineral_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 0.003 0.009 0.18 31\n" ++
        "soil_nonsymbiotic_nitrogen_fixation 5 6 0.25 0.02 0.14 0.25\n" ++
        "soil_microbial_turnover 0.01 0.001 0.167 0.333 0.333 0.333 0.150 0.300 0.333 0.25 2.0 5.0 1.0 0.5 0.182e-6";
    var context: ApplyContext = .{ .result = &result, .phosphorus_history = &phosphorus_history, .microbial_state = &microbial_state, .chemistry_state = &chemistry_state, .model_grid = &model_grid, .matric_plus_osmotic_potential_megapascal = &.{0}, .thermal_adaptation_offset_k_by_cell = &.{0}, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .parameters = try nitrogen_parameters.parse(source), .timestep_h = 1, .negligible_carbon_g_c = 1e-12, .negligible_phosphorus_g_p = 1e-12, .negligible_water_volume_m3 = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(result.non_band_microbial_h2po4_exchange_g_p[0] > 0);
    try std.testing.expect(result.non_band_microbial_h2po4_capacity_g_p[0] > 0);
    microbial_state.nonstructural[0].phosphorus_g_p = 1;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(result.non_band_microbial_h2po4_exchange_g_p[0] < 0);
    try std.testing.expectEqual(@as(f64, 0), result.non_band_microbial_hpo4_exchange_g_p[0]);
}

test "issue-073 Finding B: a near-zero-but-nonzero layer water_m3 is skipped instead of feeding an unfloored exchangePair" {
    // OLD: no guard at all on water_m3 for exchangePair's concentration->mass
    // conversion. NEW: a per-layer skip (mirroring the two already-fixed
    // siblings in this same directory) leaves the reset (zero)
    // exchange/capacity in place instead of proceeding on a
    // tiny-but-nonzero carrier.
    const config = @import("../../core/config.zig").SimulationConfig{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 };
    var model_grid = try grid.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    const negligible_water_volume_m3: f64 = 1e-6;
    model_grid.matrix_liquid_water_m3[0] = negligible_water_volume_m3 / 2; // tiny-but-nonzero, below the floor
    model_grid.soil_temperature_k[0] = 293.15;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer microbial_state.deinit();
    microbial_state.structural[0] = .{ .carbon_g_c = 0.55, .nitrogen_g_n = 0.055, .phosphorus_g_p = 0.0055 };
    microbial_state.nonstructural[0].carbon_g_c = 1;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 1;
    var phosphorus_history = try history.State.init(std.testing.allocator, 1, 1);
    defer phosphorus_history.deinit();
    var result = try fluxes.State.init(std.testing.allocator, 1, 1);
    defer result.deinit();
    const source =
        "soil_nitrification 0.001 0.0002 7000 14 1.4 1.4 0.125 0.125 0.3 0.1 0.5 2.667 3.429 1.143\n" ++
        "soil_denitrification 0.001 1.4 1.4 0.014 1 0.429 0.429 0.214 0.875\nsoil_autotrophic_denitrification 0.5 0.333\n" ++
        "soil_chemodenitrification 0.0005 0.001 1e-12 0.5 0 0.5\nnitrous_acid_dissociation_mol_per_m3 0.45\nsoil_microbial_thermal_adaptation_offset_k 0\n" ++
        "soil_nitrifier_indices 5 0 1 1\nsoil_nitrifier_environment 0.55 0.1 0.1 0.01 0.01 12 0.1\n" ++
        "soil_oxygen_uptake 1e-6 2.3866348449e11 0.064 -1.5e4 0.5 12 12 0.5 0.7 0.001 1e-12\n" ++
        "soil_heterotrophic_respiration 0.125 0.1 0.01 12 12 0.5 0.42016806722689076 0.1 2.667 0.01 0.01 1e-6 1 0.7142857142857143\n" ++
        "soil_microbial_mineral_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 0.003 0.009 0.18 31\n" ++
        "soil_nonsymbiotic_nitrogen_fixation 5 6 0.25 0.02 0.14 0.25\n" ++
        "soil_microbial_turnover 0.01 0.001 0.167 0.333 0.333 0.333 0.150 0.300 0.333 0.25 2.0 5.0 1.0 0.5 0.182e-6";
    var context: ApplyContext = .{ .result = &result, .phosphorus_history = &phosphorus_history, .microbial_state = &microbial_state, .chemistry_state = &chemistry_state, .model_grid = &model_grid, .matric_plus_osmotic_potential_megapascal = &.{0}, .thermal_adaptation_offset_k_by_cell = &.{0}, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .parameters = try nitrogen_parameters.parse(source), .timestep_h = 1, .negligible_carbon_g_c = 1e-12, .negligible_phosphorus_g_p = 1e-12, .negligible_water_volume_m3 = negligible_water_volume_m3 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 0), result.non_band_microbial_h2po4_exchange_g_p[0]);
}
