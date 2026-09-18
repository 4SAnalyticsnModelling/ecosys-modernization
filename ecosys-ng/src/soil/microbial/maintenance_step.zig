const std = @import("std");
const compute = @import("../../core/compute.zig");
const grid = @import("../../state/grid.zig");
const organic = @import("../organic/initialization.zig");
const microbial = @import("state.zig");
const metabolism = @import("metabolism.zig");
const chemistry = @import("../solute/chemistry_state.zig");
const oxygen = @import("../gas/oxygen_allocation.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const nitrogen_parameters = @import("../nutrients/nitrogen_parameters.zig");
const respiration = @import("respiration_activity.zig");

pub const ApplyContext = struct {
    result: *fluxes.State,
    microbial_state: *const microbial.State,
    organic_state: *const organic.State,
    chemistry_state: *const chemistry.State,
    model_grid: *const grid.GridState,
    oxygen_state: *const oxygen.State,
    matric_plus_osmotic_potential_megapascal: []const f64,
    thermal_adaptation_offset_k_by_cell: []const f64,
    parameters: nitrogen_parameters.Parameters,
    timestep_h: f64,
};

/// Ports NITRO RMOMX/RMOMC/RMOMT/RGOMT/RXOMT after oxygen allocation.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const population_count = context.microbial_state.population_count;
    const substrate_count = context.microbial_state.substrate_count;
    const p = context.parameters.heterotrophic_respiration;
    for (range.first..range.end) |layer| {
        const hydrogen_mol_per_m3 = context.chemistry_state.aqueous[layer].hydrogen;
        if (!std.math.isFinite(hydrogen_mol_per_m3) or hydrogen_mol_per_m3 <= 0) return error.InvalidSoilHydrogenActivity;
        const ph_response = try metabolism.maintenancePhResponse(-@log10(hydrogen_mol_per_m3 / 1e3), p.acidity_half_response_mol_per_m3);
        for (0..substrate_count) |substrate| {
            const colonized_g_c = if (substrate < organic.substrate_count) colonizedAndSorbedCarbon(context.organic_state, layer, substrate) else 0;
            for (0..population_count) |population| {
                const runtime_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
                const unit = layer * context.result.process_unit_count_per_layer + substrate * population_count + population;
                const labile = context.microbial_state.structural[runtime_index * 2];
                const resistant = context.microbial_state.structural[runtime_index * 2 + 1];
                const active_biomass_g_c = labile.carbon_g_c / context.parameters.nitrifier_environment.labile_biomass_fraction;
                const active_resistant_carbon_g_c = @max(0, @min(active_biomass_g_c * (1 - context.parameters.nitrifier_environment.labile_biomass_fraction), resistant.carbon_g_c));
                const active_resistant_nitrogen_g_n = if (resistant.carbon_g_c > 0) resistant.nitrogen_g_n * active_resistant_carbon_g_c / resistant.carbon_g_c else 0;
                const environment = try metabolism.environmentalResponse(.{
                    .soil_temperature_k = context.model_grid.soil_temperature_k[layer],
                    .thermal_adaptation_offset_k = context.thermal_adaptation_offset_k_by_cell[layer / context.microbial_state.layer_count],
                    .matric_plus_osmotic_potential_megapascal = context.matric_plus_osmotic_potential_megapascal[layer],
                    .aqueous_oxygen_concentration_g_o_per_m3 = 0,
                    .is_fungus = false,
                    .active_biomass_g_c = active_biomass_g_c,
                    .colonized_substrate_g_c = colonized_g_c,
                    .decomposition_density_half_saturation = p.decomposition_density_half_saturation_g_c_per_g_c,
                    .maintenance_density_half_saturation = p.maintenance_density_half_saturation_g_c_per_g_c,
                });
                // NITRO constrains only aerobic populations by FOXYX.
                // Fermenters and acetotrophic methanogens retain their
                // substrate-limited respiration without an O2 allocation.
                const oxygen_fraction: f64 = if (respiration.sourceMetabolism(population) == .aerobic_heterotroph) context.oxygen_state.demand_satisfaction_fraction[unit] else 1;
                const actual_aerobic_respiration_g_c = context.result.substrate_limited_respiration_g_c[unit] * oxygen_fraction;
                const value = try metabolism.maintenance(.{
                    .labile_nitrogen_g_n = labile.nitrogen_g_n,
                    .resistant_nitrogen_g_n = active_resistant_nitrogen_g_n,
                    .specific_maintenance_g_c_per_g_n_h = p.specific_maintenance_respiration_g_c_per_g_n_per_h,
                    .temperature_response = environment.maintenance_temperature_response,
                    .ph_response = ph_response,
                    .low_carbon_response = environment.maintenance_density_response,
                    .timestep_h = context.timestep_h,
                    .oxygen_limited_respiration_g_c = actual_aerobic_respiration_g_c,
                });
                context.result.labile_maintenance_respiration_g_c[unit] = value.labile_respiration_g_c;
                context.result.resistant_maintenance_respiration_g_c[unit] = value.resistant_respiration_g_c;
                context.result.total_maintenance_respiration_g_c[unit] = value.total_maintenance_g_c;
                context.result.growth_respiration_g_c[unit] = value.growth_respiration_g_c;
                context.result.senescence_respiration_deficit_g_c[unit] = value.senescence_respiration_deficit_g_c;
            }
        }
    }
}

fn colonizedAndSorbedCarbon(state: *const organic.State, layer: usize, substrate: usize) f64 {
    const mobile = layer * organic.substrate_count + substrate;
    var total = state.adsorbed[mobile].carbon_g_c + state.adsorbed_acetate_carbon_g_c[mobile];
    for (0..organic.structural_fraction_count) |fraction| total += state.colonized_structural_carbon_g_c[mobile * organic.structural_fraction_count + fraction];
    for (0..organic.residue_fraction_count) |fraction| total += state.residue[mobile * organic.residue_fraction_count + fraction].carbon_g_c;
    return total;
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.model_grid.layer_count;
    const units = try std.math.mul(usize, layers, context.result.process_unit_count_per_layer);
    if (range.first > range.end or range.end > layers or context.organic_state.layer_count != layers or context.chemistry_state.cell_count != layers or context.microbial_state.cell_count * context.microbial_state.layer_count != layers or context.result.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count or context.oxygen_state.demand_satisfaction_fraction.len != units or context.matric_plus_osmotic_potential_megapascal.len != layers or context.thermal_adaptation_offset_k_by_cell.len != context.microbial_state.cell_count) return error.SoilMicrobialMaintenanceDimensionMismatch;
    for (context.thermal_adaptation_offset_k_by_cell) |offset_k| if (!std.math.isFinite(offset_k)) return error.NonFiniteMicrobialThermalAdaptationOffset;
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.InvalidSoilMicrobialMaintenanceTimestep;
}

test "runtime soil maintenance separates microbial growth and deficit" {
    const config = @import("../../core/config.zig").SimulationConfig{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 };
    var model_grid = try grid.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    model_grid.soil_temperature_k[0] = 293.15;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 6, 7);
    defer microbial_state.deinit();
    microbial_state.structural[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 1, .phosphorus_g_p = 0.01 };
    microbial_state.structural[1] = .{ .carbon_g_c = 1, .nitrogen_g_n = 1, .phosphorus_g_p = 0.01 };
    microbial_state.structural[6] = .{ .carbon_g_c = 1, .nitrogen_g_n = 1, .phosphorus_g_p = 0.01 };
    microbial_state.structural[7] = .{ .carbon_g_c = 1, .nitrogen_g_n = 1, .phosphorus_g_p = 0.01 };
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.adsorbed[0].carbon_g_c = 10;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.aqueous[0].hydrogen = 1e-3;
    var oxygen_state = try oxygen.State.init(std.testing.allocator, 1, 42, 1);
    defer oxygen_state.deinit();
    oxygen_state.demand_satisfaction_fraction[0] = 1;
    var result = try fluxes.State.init(std.testing.allocator, 1, 42);
    defer result.deinit();
    result.substrate_limited_respiration_g_c[0] = 1;
    result.substrate_limited_respiration_g_c[3] = 1;
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
    var context: ApplyContext = .{ .result = &result, .microbial_state = &microbial_state, .organic_state = &organic_state, .chemistry_state = &chemistry_state, .model_grid = &model_grid, .oxygen_state = &oxygen_state, .matric_plus_osmotic_potential_megapascal = &.{0}, .thermal_adaptation_offset_k_by_cell = &.{0}, .parameters = parsed, .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(result.labile_maintenance_respiration_g_c[0] > 0);
    try std.testing.expect(result.resistant_maintenance_respiration_g_c[0] > 0);
    try std.testing.expect(result.growth_respiration_g_c[0] > 0);
    try std.testing.expectEqual(@as(f64, 0), result.senescence_respiration_deficit_g_c[0]);
    try std.testing.expect(result.growth_respiration_g_c[3] > 0);
    try std.testing.expectEqual(@as(f64, 0), result.senescence_respiration_deficit_g_c[3]);
}
