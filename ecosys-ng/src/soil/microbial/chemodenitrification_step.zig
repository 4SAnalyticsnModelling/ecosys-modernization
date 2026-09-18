const std = @import("std");
const compute = @import("../../core/compute.zig");
const grid = @import("../../state/grid.zig");
const chemistry = @import("../solute/chemistry_state.zig");
const zones = @import("../solute/charge_classification.zig");
const metabolism = @import("metabolism.zig");
const reaction = @import("chemodenitrification.zig");
const parameters = @import("../nutrients/nitrogen_parameters.zig");
const reactive = @import("../nutrients/reactive_nitrogen_state.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");

pub const ApplyContext = struct {
    result: *fluxes.State,
    reactive_nitrogen: *const reactive.State,
    chemistry_state: *const chemistry.State,
    model_grid: *const grid.GridState,
    thermal_adaptation_offset_k_by_cell: []const f64,
    zone_fractions: zones.ZoneFractions,
    zone_fractions_by_layer: []const zones.ZoneFractions = &.{},
    parameters: parameters.Parameters,
    timestep_h: f64,
};

/// Exact NITRO.F 553--555 dissociation order:
/// `D = CHY1 / HNO2K`, then `CHNO2 = CNO2S * D / (D + 1)`.
pub fn nitrousAcidFraction(
    hydrogen_mol_per_m3: f64,
    dissociation_mol_per_m3: f64,
) !f64 {
    if (!std.math.isFinite(hydrogen_mol_per_m3) or
        hydrogen_mol_per_m3 < 0 or
        !std.math.isFinite(dissociation_mol_per_m3) or
        dissociation_mol_per_m3 <= 0)
        return error.InvalidNitrousAcidEnvironment;
    const dissociation_ratio =
        hydrogen_mol_per_m3 / dissociation_mol_per_m3;
    const fraction = dissociation_ratio / (dissociation_ratio + 1);
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
        return error.NonFiniteNitrousAcidEnvironment;
    return fraction;
}

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |layer| {
        const zone_fractions = if (context.zone_fractions_by_layer.len == 0) context.zone_fractions else context.zone_fractions_by_layer[layer];
        const water_m3 = context.model_grid.matrix_liquid_water_m3[layer];
        const hydrogen_mol_per_m3 =
            context.chemistry_state.aqueous[layer].hydrogen;
        const acid_fraction = try nitrousAcidFraction(
            hydrogen_mol_per_m3,
            context.parameters.nitrous_acid_dissociation_mol_per_m3,
        );
        const non_band_volume = water_m3 * zone_fractions.nitrate_non_band;
        const band_volume = water_m3 * zone_fractions.nitrate_band;
        const non_band_nitrite = context.reactive_nitrogen.non_band_nitrite_g_n[layer];
        const band_nitrite = context.reactive_nitrogen.band_nitrite_g_n[layer];
        const temperature = try metabolism.growthTemperatureResponse(context.model_grid.soil_temperature_k[layer], context.thermal_adaptation_offset_k_by_cell[layer / context.model_grid.soil_layer_capacity]);
        const result = try reaction.calculate(.{
            .non_band = zone(non_band_nitrite, non_band_volume, acid_fraction, zone_fractions.nitrate_non_band, context.reactive_nitrogen.previous_total_non_band_nitrite_demand_g_n[layer], context.reactive_nitrogen.previous_non_band_chemodenitrification_capacity_g_n[layer]),
            .band = zone(band_nitrite, band_volume, acid_fraction, zone_fractions.nitrate_band, context.reactive_nitrogen.previous_total_band_nitrite_demand_g_n[layer], context.reactive_nitrogen.previous_band_chemodenitrification_capacity_g_n[layer]),
            .water_volume_m3 = water_m3,
            .temperature_response = temperature,
            .timestep_h = context.timestep_h,
        }, context.parameters.chemodenitrification);
        context.result.chemodenitrification_non_band_nitrite_reduction_g_n[layer] = result.non_band_nitrite_reduction_g_n;
        context.result.chemodenitrification_band_nitrite_reduction_g_n[layer] = result.band_nitrite_reduction_g_n;
        context.result.chemodenitrification_non_band_unlimited_reduction_g_n[layer] = result.non_band_unlimited_reduction_g_n;
        context.result.chemodenitrification_band_unlimited_reduction_g_n[layer] = result.band_unlimited_reduction_g_n;
        context.result.chemodenitrification_nitrous_oxide_production_g_n[layer] = result.nitrous_oxide_production_g_n;
        context.result.chemodenitrification_dinitrogen_production_g_n[layer] = result.dinitrogen_production_g_n;
        context.result.chemodenitrification_dissolved_organic_nitrogen_production_g_n[layer] = result.dissolved_organic_nitrogen_production_g_n;
    }
}

fn zone(nitrite_g_n: f64, zone_water_m3: f64, acid_fraction: f64, reaction_volume_fraction: f64, previous_total: f64, previous_capacity: f64) reaction.Zone {
    return .{ .nitrous_acid_concentration_g_n_per_m3 = if (zone_water_m3 > 0) nitrite_g_n / zone_water_m3 * acid_fraction else 0, .nitrite_g_n = nitrite_g_n, .dissolved_fraction = reaction_volume_fraction, .reaction_volume_fraction = reaction_volume_fraction, .previous_total_nitrite_demand_g_n = previous_total, .previous_unlimited_reduction_g_n = previous_capacity };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.model_grid.layer_count;
    if (range.first > range.end or range.end > layers or context.result.layer_count != layers or context.reactive_nitrogen.layer_count != layers or context.chemistry_state.cell_count != layers or context.thermal_adaptation_offset_k_by_cell.len != context.model_grid.cell_count or (context.zone_fractions_by_layer.len != 0 and context.zone_fractions_by_layer.len != layers)) return error.SoilChemodenitrificationDimensionMismatch;
    for (context.thermal_adaptation_offset_k_by_cell) |offset_k| if (!std.math.isFinite(offset_k)) return error.NonFiniteMicrobialThermalAdaptationOffset;
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.InvalidSoilChemodenitrificationTimestep;
    try parameters.validate(context.parameters);
}

test "NITRO 553-555 nitrous acid fraction preserves dissociation operation order" {
    try std.testing.expectEqual(
        @as(f64, 0.5),
        try nitrousAcidFraction(0.45, 0.45),
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        try nitrousAcidFraction(0, 0.45),
    );
    try std.testing.expectError(
        error.InvalidNitrousAcidEnvironment,
        nitrousAcidFraction(1, 0),
    );
}

test "layer chemodenitrification derives both zone fluxes without mutation" {
    var model_grid = try grid.GridState.init(std.testing.allocator, .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 });
    defer model_grid.deinit();
    model_grid.matrix_liquid_water_m3[0] = 1;
    model_grid.soil_temperature_k[0] = 298.15;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.aqueous[0].hydrogen = 0.45;
    var reactive_state = try reactive.State.init(std.testing.allocator, 1, 1);
    defer reactive_state.deinit();
    reactive_state.non_band_nitrite_g_n[0] = 1;
    reactive_state.band_nitrite_g_n[0] = 1;
    var result = try fluxes.State.init(std.testing.allocator, 1, 1);
    defer result.deinit();
    const source = "soil_nitrification 0.001 0.0002 7000 14 1.4 1.4 0.125 0.125 0.3 0.1 0.5 2.667 3.429 1.143\nsoil_denitrification 0.001 1.4 1.4 0.014 1 0.429 0.429 0.214 0.875\nsoil_autotrophic_denitrification 0.5 0.333\nsoil_chemodenitrification 0.0005 0.001 1e-12 0.5 0 0.5\nnitrous_acid_dissociation_mol_per_m3 0.45\nsoil_microbial_thermal_adaptation_offset_k 0\nsoil_nitrifier_indices 5 0 1 1\nsoil_nitrifier_environment 0.55 0.1 0.1 0.01 0.01 12 0.1\nsoil_oxygen_uptake 1e-6 2.3866348449e11 0.064 -1.5e4 0.5 12 12 0.5 0.7 0.001 1e-12\nsoil_heterotrophic_respiration 0.125 0.1 0.01 12 12 0.5 0.42016806722689076 0.1 2.667 0.01 0.01 1e-6 1 0.7142857142857143\nsoil_microbial_mineral_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 0.003 0.009 0.18 31\nsoil_nonsymbiotic_nitrogen_fixation 5 6 0.25 0.02 0.14 0.25\nsoil_microbial_turnover 0.01 0.001 0.167 0.333 0.333 0.333 0.150 0.300 0.333";
    var context: ApplyContext = .{ .result = &result, .reactive_nitrogen = &reactive_state, .chemistry_state = &chemistry_state, .model_grid = &model_grid, .thermal_adaptation_offset_k_by_cell = &.{0}, .zone_fractions = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 }, .parameters = try parameters.parse(source ++ " 0.25 2.0 5.0 1.0 0.5 0.182e-6"), .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(result.chemodenitrification_non_band_nitrite_reduction_g_n[0] > 0);
    try std.testing.expect(result.chemodenitrification_band_nitrite_reduction_g_n[0] > 0);
    try std.testing.expectEqual(@as(f64, 1), reactive_state.non_band_nitrite_g_n[0]);
}
