const std = @import("std");
const compute = @import("../../core/compute.zig");
const grid = @import("../../state/grid.zig");
const microbial = @import("state.zig");
const metabolism = @import("metabolism.zig");
const organic = @import("../organic/initialization.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const nitrogen_parameters = @import("../nutrients/nitrogen_parameters.zig");

pub const ApplyContext = struct {
    result: *fluxes.State,
    microbial_state: *const microbial.State,
    model_grid: *const grid.GridState,
    matric_plus_osmotic_potential_megapascal: []const f64,
    thermal_adaptation_offset_k_by_cell: []const f64,
    microbial_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    microbial_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    parameters: nitrogen_parameters.Parameters,
    timestep_h: f64,
};

/// NITRO CGOMZ and CGOMS/CGONS/CGOPS for every runtime soil microbial unit.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const populations = context.microbial_state.population_count;
    const substrates = context.microbial_state.substrate_count;
    const labile_fraction = context.parameters.nitrifier_environment.labile_biomass_fraction;
    for (range.first..range.end) |layer| for (0..substrates) |substrate| for (0..populations) |population| {
        const runtime_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
        const unit = layer * context.result.process_unit_count_per_layer + substrate * populations + population;
        const ratio = (substrate * populations + population) * 3;
        // NITRO.F 593--604: WFNG uses the fungal-specific 0.05 MPa-1
        // sensitivity only for the fungal population (source N=3, this
        // codebase's population index 2) within the heterotrophic substrate
        // complexes (source K<=4); the autotrophic complex (source K=5,
        // `organic.autotrophic_substrate_index`) always uses the bacterial
        // sensitivity regardless of population index.
        const is_fungus = substrate < organic.substrate_count and population == 2;
        const water_sensitivity_per_megapascal: f64 = if (is_fungus) 0.05 else context.parameters.heterotrophic_respiration.water_potential_sensitivity_per_megapascal;
        const temperature_water_response = try metabolism.growthTemperatureResponse(context.model_grid.soil_temperature_k[layer], context.thermal_adaptation_offset_k_by_cell[layer / context.microbial_state.layer_count]) * @exp(water_sensitivity_per_megapascal * context.matric_plus_osmotic_potential_megapascal[layer]);
        const value = try metabolism.assimilateNonstructural(.{
            .nonstructural = context.microbial_state.nonstructural[runtime_index],
            .temperature_water_response = temperature_water_response,
            .nonstructural_to_structural_rate_per_h = context.parameters.nonsymbiotic_nitrogen_fixation.nonstructural_to_structural_rate_per_h,
            .timestep_h = context.timestep_h,
            .structural_partition = .{ labile_fraction, 1 - labile_fraction },
            .maximum_nitrogen_per_carbon = .{ context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio], context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio + 1] },
            .maximum_phosphorus_per_carbon = .{ context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio], context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio + 1] },
        });
        context.result.labile_assimilation_g_c[unit] = value.structural[0].carbon_g_c;
        context.result.labile_assimilation_g_n[unit] = value.structural[0].nitrogen_g_n;
        context.result.labile_assimilation_g_p[unit] = value.structural[0].phosphorus_g_p;
        context.result.resistant_assimilation_g_c[unit] = value.structural[1].carbon_g_c;
        context.result.resistant_assimilation_g_n[unit] = value.structural[1].nitrogen_g_n;
        context.result.resistant_assimilation_g_p[unit] = value.structural[1].phosphorus_g_p;
    };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.model_grid.layer_count;
    const ratio_count = try std.math.mul(usize, try std.math.mul(usize, context.microbial_state.substrate_count, context.microbial_state.population_count), 3);
    if (range.first > range.end or range.end > layers or context.microbial_state.cell_count * context.microbial_state.layer_count != layers or context.result.layer_count != layers or context.result.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count or context.matric_plus_osmotic_potential_megapascal.len != layers or context.thermal_adaptation_offset_k_by_cell.len != context.microbial_state.cell_count or context.microbial_nitrogen_to_carbon_g_n_per_g_c.len != ratio_count or context.microbial_phosphorus_to_carbon_g_p_per_g_c.len != ratio_count) return error.SoilMicrobialAssimilationDimensionMismatch;
    for (context.thermal_adaptation_offset_k_by_cell) |offset_k| if (!std.math.isFinite(offset_k)) return error.NonFiniteMicrobialThermalAdaptationOffset;
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.InvalidSoilMicrobialAssimilationInput;
}

test "runtime soil assimilation preserves component-specific C N P ratios" {
    var model_grid = try grid.GridState.init(std.testing.allocator, .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 });
    defer model_grid.deinit();
    model_grid.soil_temperature_k[0] = 293.15;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer microbial_state.deinit();
    microbial_state.nonstructural[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.05 };
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
    var context: ApplyContext = .{ .result = &result, .microbial_state = &microbial_state, .model_grid = &model_grid, .matric_plus_osmotic_potential_megapascal = &.{0}, .thermal_adaptation_offset_k_by_cell = &.{0}, .microbial_nitrogen_to_carbon_g_n_per_g_c = &.{ 0.1, 0.08, 0.2 }, .microbial_phosphorus_to_carbon_g_p_per_g_c = &.{ 0.02, 0.01, 0.05 }, .parameters = try nitrogen_parameters.parse(source), .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const expected_total_g_c = try metabolism.growthTemperatureResponse(293.15, 0) * 0.25;
    try std.testing.expectApproxEqAbs(expected_total_g_c * 0.55, result.labile_assimilation_g_c[0], 1e-15);
    try std.testing.expectApproxEqAbs(expected_total_g_c * 0.45, result.resistant_assimilation_g_c[0], 1e-15);
    try std.testing.expectApproxEqAbs(result.labile_assimilation_g_c[0] * 0.1, result.labile_assimilation_g_n[0], 1e-15);
    try std.testing.expectApproxEqAbs(result.resistant_assimilation_g_c[0] * 0.01, result.resistant_assimilation_g_p[0], 1e-15);
}
