const std = @import("std");
const compute = @import("../../core/compute.zig");
const grid = @import("../../state/grid.zig");
const chemistry = @import("../solute/chemistry_state.zig");
const zones = @import("../solute/charge_classification.zig");
const reaction = @import("nitrification.zig");
const reactive = @import("../nutrients/reactive_nitrogen_state.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const competition_history = @import("../nutrients/competition_history.zig");

pub const Role = enum { inactive, ammonia_oxidizer, nitrite_oxidizer };

pub const ApplyContext = struct {
    result: *fluxes.State,
    reactive_nitrogen: *const reactive.State,
    nutrient_competition: ?*const competition_history.State = null,
    chemistry_state: *const chemistry.State,
    model_grid: *const grid.GridState,
    zone_fractions: zones.ZoneFractions,
    zone_fractions_by_layer: []const zones.ZoneFractions = &.{},
    roles: []const Role,
    temperature_water_activity: []const f64,
    nitrogen_phosphorus_activity: []const f64,
    aqueous_co2_activity: []const f64,
    active_biomass_g_c: []const f64,
    microbial_active_fraction: []const f64,
    parameters: reaction.Parameters,
    nitrogen_molar_mass_g_per_mol: f64,
    timestep_h: f64,
    negligible_demand_g_n: f64,
};

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const units_per_layer = context.result.process_unit_count_per_layer;
    for (range.first..range.end) |layer| {
        const water_m3 = context.model_grid.matrix_liquid_water_m3[layer];
        const first = layer * units_per_layer;
        for (first..first + units_per_layer) |unit| {
            if (context.roles[unit] == .inactive) continue;
            const potential = try reaction.calculatePotential(.{
                .non_band = makeZone(context.*, layer, unit, water_m3, false),
                .band = makeZone(context.*, layer, unit, water_m3, true),
                .temperature_water_activity = context.temperature_water_activity[unit],
                .nitrogen_phosphorus_activity = context.nitrogen_phosphorus_activity[unit],
                .aqueous_co2_activity = context.aqueous_co2_activity[unit],
                .active_oxidizer_biomass_g_c = context.active_biomass_g_c[unit],
                .microbial_active_fraction = context.microbial_active_fraction[unit],
                .timestep_h = context.timestep_h,
                .initial_inhibition_activity = context.reactive_nitrogen.initial_nitrification_inhibition_activity[layer],
                .current_inhibition_activity = context.reactive_nitrogen.current_nitrification_inhibition_activity[layer],
                .negligible_demand_g_n = context.negligible_demand_g_n,
            }, context.parameters);
            context.result.layer_nitrification_inhibition_activity[layer] = potential.updated_inhibition_activity;
            context.result.aerobic_active_biomass_g_c[unit] = context.active_biomass_g_c[unit];
            context.result.aerobic_fallback_active_fraction[unit] = context.microbial_active_fraction[unit];
            switch (context.roles[unit]) {
                .ammonia_oxidizer => {
                    context.result.non_band_ammonia_oxidation_potential_g_n[unit] = potential.non_band_ammonia_oxidation_g_n;
                    context.result.band_ammonia_oxidation_potential_g_n[unit] = potential.band_ammonia_oxidation_g_n;
                    context.result.non_band_ammonia_oxidation_capacity_g_n[unit] = potential.non_band_ammonia_oxidation_capacity_g_n;
                    context.result.band_ammonia_oxidation_capacity_g_n[unit] = potential.band_ammonia_oxidation_capacity_g_n;
                    context.result.aerobic_oxygen_demand_g_o[unit] = potential.ammonia_oxidation_oxygen_demand_g_o;
                },
                .nitrite_oxidizer => {
                    context.result.non_band_nitrite_oxidation_potential_g_n[unit] = potential.non_band_nitrite_oxidation_g_n;
                    context.result.band_nitrite_oxidation_potential_g_n[unit] = potential.band_nitrite_oxidation_g_n;
                    context.result.non_band_nitrite_oxidation_capacity_g_n[unit] = potential.non_band_nitrite_oxidation_capacity_g_n;
                    context.result.band_nitrite_oxidation_capacity_g_n[unit] = potential.band_nitrite_oxidation_capacity_g_n;
                    context.result.aerobic_oxygen_demand_g_o[unit] = potential.nitrite_oxidation_oxygen_demand_g_o;
                },
                .inactive => unreachable,
            }
        }
    }
}

fn makeZone(context: ApplyContext, layer: usize, unit: usize, water_m3: f64, band: bool) reaction.Zone {
    const fractions = if (context.zone_fractions_by_layer.len == 0) context.zone_fractions else context.zone_fractions_by_layer[layer];
    const ammonium_fraction = if (band) fractions.ammonium_band else fractions.ammonium_non_band;
    const nitrite_fraction = if (band) fractions.nitrate_band else fractions.nitrate_non_band;
    const aqueous = context.chemistry_state.aqueous[layer];
    const ammonium_concentration = if (band) aqueous.ammonium_band else aqueous.ammonium_non_band;
    const ammonia_concentration = if (band) aqueous.ammonia_band else aqueous.ammonia_non_band;
    const nitrite_amount = if (band) context.reactive_nitrogen.band_nitrite_g_n[layer] else context.reactive_nitrogen.non_band_nitrite_g_n[layer];
    const nitrite_volume = water_m3 * nitrite_fraction;
    return .{
        .substrate_access_fraction = ammonium_fraction,
        .fallback_available_fraction = nitrite_fraction,
        .ammonium_concentration_g_n_per_m3 = ammonium_concentration * context.nitrogen_molar_mass_g_per_mol,
        .ammonia_concentration_g_n_per_m3 = ammonia_concentration * context.nitrogen_molar_mass_g_per_mol,
        .nitrite_concentration_g_n_per_m3 = if (nitrite_volume > 0) nitrite_amount / nitrite_volume else 0,
        .ammonium_amount_g_n = ammonium_concentration * water_m3 * ammonium_fraction * context.nitrogen_molar_mass_g_per_mol,
        .nitrite_amount_g_n = nitrite_amount,
        .previous_total_ammonium_demand_g_n = if (context.nutrient_competition) |history| history.soil_previous_total[@intFromEnum(if (band) competition_history.SoilPool.ammonium_band else competition_history.SoilPool.ammonium_non_band)][layer] else if (band) context.reactive_nitrogen.previous_total_band_ammonium_demand_g_n[layer] else context.reactive_nitrogen.previous_total_non_band_ammonium_demand_g_n[layer],
        .previous_ammonia_oxidation_capacity_g_n = if (band) context.reactive_nitrogen.previous_band_ammonia_oxidation_capacity_g_n[unit] else context.reactive_nitrogen.previous_non_band_ammonia_oxidation_capacity_g_n[unit],
        .previous_total_nitrite_demand_g_n = if (band) context.reactive_nitrogen.previous_total_band_nitrite_demand_g_n[layer] else context.reactive_nitrogen.previous_total_non_band_nitrite_demand_g_n[layer],
        .previous_nitrite_oxidation_capacity_g_n = if (band) context.reactive_nitrogen.previous_band_nitrite_oxidation_capacity_g_n[unit] else context.reactive_nitrogen.previous_non_band_nitrite_oxidation_capacity_g_n[unit],
    };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.model_grid.layer_count;
    const units = try std.math.mul(usize, layers, context.result.process_unit_count_per_layer);
    if (range.first > range.end or range.end > layers or context.result.layer_count != layers or context.reactive_nitrogen.layer_count != layers or context.chemistry_state.cell_count != layers or (context.zone_fractions_by_layer.len != 0 and context.zone_fractions_by_layer.len != layers)) return error.SoilNitrificationDimensionMismatch;
    inline for (.{ context.roles, context.temperature_water_activity, context.nitrogen_phosphorus_activity, context.aqueous_co2_activity, context.active_biomass_g_c, context.microbial_active_fraction }) |values| if (values.len != units) return error.SoilNitrificationDimensionMismatch;
    if (!std.math.isFinite(context.nitrogen_molar_mass_g_per_mol) or context.nitrogen_molar_mass_g_per_mol <= 0 or !std.math.isFinite(context.timestep_h) or context.timestep_h <= 0 or !std.math.isFinite(context.negligible_demand_g_n) or context.negligible_demand_g_n < 0) return error.InvalidSoilNitrificationRuntimeInput;
    for (context.temperature_water_activity, context.nitrogen_phosphorus_activity, context.aqueous_co2_activity, context.active_biomass_g_c, context.microbial_active_fraction) |temperature, nutrient, co2, biomass, active| inline for (.{ temperature, nutrient, co2, biomass, active }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilNitrificationRuntimeInput;
}

test "separate runtime nitrifier roles write distinct zone potentials" {
    var model_grid = try grid.GridState.init(std.testing.allocator, .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 });
    defer model_grid.deinit();
    model_grid.matrix_liquid_water_m3[0] = 1;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.aqueous[0].ammonium_non_band = 1;
    chemistry_state.aqueous[0].ammonium_band = 1;
    var reactive_state = try reactive.State.init(std.testing.allocator, 1, 2);
    defer reactive_state.deinit();
    reactive_state.non_band_nitrite_g_n[0] = 1;
    reactive_state.band_nitrite_g_n[0] = 1;
    var result = try fluxes.State.init(std.testing.allocator, 1, 2);
    defer result.deinit();
    const nitrification_parameters: reaction.Parameters = .{ .minimum_competition_fraction = 0.001, .inhibition_decay_per_h = 0.0002, .inhibition_decay_ammonium_constant_g_n_per_m3 = 7000, .ammonia_product_inhibition_g_n_per_m3 = 14, .ammonium_half_saturation_g_n_per_m3 = 1.4, .nitrite_half_saturation_g_n_per_m3 = 1.4, .ammonia_oxidation_rate_g_n_per_g_c_h = 0.125, .nitrite_oxidation_rate_g_n_per_g_c_h = 0.125, .ammonia_oxidizer_carbon_efficiency_g_c_per_g_n = 0.3, .nitrite_oxidizer_carbon_efficiency_g_c_per_g_n = 0.1, .growth_respiration_fraction = 0.5, .oxygen_per_respired_carbon_g_o_per_g_c = 2.667, .oxygen_per_ammonium_n_g_o_per_g_n = 3.429, .oxygen_per_nitrite_n_g_o_per_g_n = 1.143 };
    var context: ApplyContext = .{ .result = &result, .reactive_nitrogen = &reactive_state, .chemistry_state = &chemistry_state, .model_grid = &model_grid, .zone_fractions = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 }, .roles = &.{ .ammonia_oxidizer, .nitrite_oxidizer }, .temperature_water_activity = &.{ 1, 1 }, .nitrogen_phosphorus_activity = &.{ 1, 1 }, .aqueous_co2_activity = &.{ 1, 1 }, .active_biomass_g_c = &.{ 1, 1 }, .microbial_active_fraction = &.{ 1, 1 }, .parameters = nitrification_parameters, .nitrogen_molar_mass_g_per_mol = 14, .timestep_h = 1, .negligible_demand_g_n = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(result.non_band_ammonia_oxidation_potential_g_n[0] > 0);
    try std.testing.expectEqual(@as(f64, 0), result.non_band_nitrite_oxidation_potential_g_n[0]);
    try std.testing.expect(result.non_band_nitrite_oxidation_potential_g_n[1] > 0);
}
