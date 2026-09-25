//! `root_processes` declarations: uptake.
//!
//! Split out of `root_processes.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ecosys = @import("ecosys_ng");
// TEMP_DIAGNOSTIC (`issue-108`): cation probe only.
const diagnostics = @import("diagnostics.zig");

pub fn applyRootNutrientUptake(context: anytype) !void {
    if (context.plant_roots.* == null or context.plant_water_workspace.* == null or context.plant_root_nutrient_workspace.* == null or context.plant_root_exudation_workspace.* == null) return;
    if (context.salinity_enabled_by_cell.len != context.grid.cell_count)
        return error.RootSaltSalinityDimensionMismatch;
    var any_salinity_enabled = false;
    for (context.salinity_enabled_by_cell) |enabled|
        any_salinity_enabled = any_salinity_enabled or enabled;
    if (any_salinity_enabled and context.plant_root_salt_workspace.* == null)
        return error.MissingRootSaltWorkspace;
    const roots = &context.plant_roots.*.?;
    const water = &context.plant_water_workspace.*.?;
    const grid_workspace = &context.plant_root_nutrient_workspace.*.?;
    try context.plant_available_nutrients.refreshMineralPools(context.soil_chemistry, context.grid.matrix_liquid_water_m3, context.fertilizer_band);
    for (0..context.grid.cell_count) |cell| {
        const dynamic_salts = context.salinity_enabled_by_cell[cell];
        var workspace = &grid_workspace.per_cell[cell];
        const salt_workspace = if (dynamic_salts) &context.plant_root_salt_workspace.*.?.per_cell[cell] else null;
        const transaction_salt = if (dynamic_salts) try context.plant_root_salt_workspace.*.?.transactionSaltBuffer(cell) else null;
        const transaction_salt_selected = if (dynamic_salts) try context.plant_root_salt_workspace.*.?.transactionSaltSelection(cell) else null;
        var exudation_workspace = &context.plant_root_exudation_workspace.*.?.per_cell[cell];
        const transaction_organic = try context.plant_root_exudation_workspace.*.?.transactionOrganicBuffer(cell);
        const transaction_organic_selected = try context.plant_root_exudation_workspace.*.?.transactionOrganicSelection(cell);
        const plant_first = cell * context.config.plant_populations;
        const active_layer_count = context.grid.active_soil_layer_count[cell];
        const first_soil = try context.grid.layerIndex(cell, 0);
        const layer_thickness_m = context.soil_solver_properties.layer_thickness_m[first_soil..][0..active_layer_count];
        const admission_buffer = try grid_workspace.admissionBuffer(cell);
        var admitted_count: usize = 0;
        for (0..context.config.plant_populations) |species| {
            const plant = plant_first + species;
            var iterator = try ecosys.rooted_layer_eligibility.Iterator.init(.{
                .plant = plant,
                .active_biological_domain_count = context.root_metabolism_plant_parameters[plant].biologicalDomainCount(),
                .first_active_soil_layer = 0,
                .deepest_rooted_soil_layer = roots.current_deepest_rooted_layer_by_plant[plant],
                .layer_thickness_m = layer_thickness_m,
                .minimum_active_layer_thickness_m = context.runscript.soil_geometry_parameters.minimum_layer_thickness_m,
            });
            while (iterator.next()) |coordinate| {
                if (admitted_count == admission_buffer.len) return error.RootNutrientAdmissionCapacityExceeded;
                admission_buffer[admitted_count] = coordinate;
                admitted_count += 1;
            }
        }
        const admitted = admission_buffer[0..admitted_count];
        if (transaction_salt_selected) |selected| @memset(selected[0..admitted_count], false);
        @memset(transaction_organic_selected[0..admitted_count], false);
        const transaction_nutrient = try grid_workspace.transactionNutrientBuffer(cell);
        const transaction_nutrient_selected = try grid_workspace.transactionNutrientSelection(cell);
        @memset(transaction_nutrient_selected[0..admitted_count], false);
        for (0..context.grid.active_soil_layer_count[cell]) |layer| {
            const soil = try context.grid.layerIndex(cell, layer);
            const fractions = try context.fertilizer_band.scienceZoneFractions(cell, layer);
            const zone_fraction_by_pool = [ecosys.plant_root_nutrient_uptake.nutrient_pool_count]f64{
                fractions.ammonium_non_band,
                fractions.ammonium_band,
                fractions.nitrate_non_band,
                fractions.nitrate_band,
                fractions.phosphate_non_band,
                fractions.phosphate_band,
                fractions.phosphate_non_band,
                fractions.phosphate_band,
            };
            const soil_pools = try context.plant_available_nutrients.mineralPools(soil);
            // HOUR1 freezes the single REDIST/EXTRACT R*X accumulator into
            // R*Y before either NITRO or UPTAKE reads it. Every contributor
            // therefore uses this immutable accepted-hour denominator.
            const total_previous = [ecosys.plant_root_nutrient_uptake.nutrient_pool_count]f64{
                context.soil_nutrient_competition_history.soil_previous_total[@intFromEnum(ecosys.soil_nutrient_competition_history.SoilPool.ammonium_non_band)][soil],
                context.soil_nutrient_competition_history.soil_previous_total[@intFromEnum(ecosys.soil_nutrient_competition_history.SoilPool.ammonium_band)][soil],
                context.soil_nutrient_competition_history.soil_previous_total[@intFromEnum(ecosys.soil_nutrient_competition_history.SoilPool.nitrate_non_band)][soil],
                context.soil_nutrient_competition_history.soil_previous_total[@intFromEnum(ecosys.soil_nutrient_competition_history.SoilPool.nitrate_band)][soil],
                context.soil_nutrient_competition_history.soil_previous_total[@intFromEnum(ecosys.soil_nutrient_competition_history.SoilPool.h2po4_non_band)][soil],
                context.soil_nutrient_competition_history.soil_previous_total[@intFromEnum(ecosys.soil_nutrient_competition_history.SoilPool.h2po4_band)][soil],
                context.soil_nutrient_competition_history.soil_previous_total[@intFromEnum(ecosys.soil_nutrient_competition_history.SoilPool.hpo4_non_band)][soil],
                context.soil_nutrient_competition_history.soil_previous_total[@intFromEnum(ecosys.soil_nutrient_competition_history.SoilPool.hpo4_band)][soil],
            };

            var competitor_count: usize = 0;
            var exudation_competitor_count: usize = 0;
            for (admitted, 0..) |coordinate, admission_index| {
                if (coordinate.soil_layer != layer) continue;
                const plant = coordinate.plant;
                const domain = coordinate.biological_domain;
                if (!context.plant_phenology.*.?.active[plant]) continue;
                const root = try roots.layerIndex(plant, domain, layer);
                if (roots.root_surface_area_m2_per_plant[root] <= context.config.physical_tolerance.area(roots.root_surface_area_m2_per_plant[root])) continue;
                if (roots.aqueous_volume_m3[root] > context.config.physical_tolerance.waterVolume(roots.aqueous_volume_m3[root])) {
                    exudation_workspace.competitors[exudation_competitor_count] = .{ .plant = plant, .domain = domain, .layer = layer };
                    exudation_workspace.admission_index_by_competitor[exudation_competitor_count] = admission_index;
                    exudation_competitor_count += 1;
                }
                const activity = try ecosys.plant_root_nutrient_uptake.activityFractions(
                    roots.protein_carbon_g[root],
                    roots.total_carbon_g[root],
                    roots.maximum_protein_carbon_g_per_g_c[root],
                    roots.mobile_carbon_g[root],
                    roots.respiration_unlimited_by_carbon_g_c_per_h[root],
                    roots.mobile_carbon_concentration_g_per_g[root],
                    roots.mobile_nitrogen_concentration_g_per_g[root],
                    roots.mobile_phosphorus_concentration_g_per_g[root],
                    context.root_nutrient_feedback_enabled[plant],
                    context.runscript.root_nutrient_parameters,
                );
                if (activity.protein <= 0 or activity.carbon <= 0) continue;
                var competition: [ecosys.plant_root_nutrient_uptake.nutrient_pool_count]f64 = undefined;
                for (0..ecosys.plant_root_nutrient_uptake.nutrient_pool_count) |pool_index| {
                    const pool: ecosys.plant_root_nutrient_uptake.NutrientPool = @enumFromInt(pool_index);
                    const biome = water.root_biome_fraction[root];
                    competition[pool_index] = if (total_previous[pool_index] > nutrientDemandPresenceLimit(context.config.physical_tolerance, pool, total_previous[pool_index]))
                        @max(context.runscript.root_nutrient_parameters.minimum_population_uptake_fraction_multiplier * biome, previousRootNutrientDemand(roots, pool, root) / total_previous[pool_index])
                    else
                        biome;
                }
                const temperature_response = try ecosys.plant_root_nutrient_uptake.rootGrowthTemperatureResponse(context.grid.soil_temperature_k[soil], context.detailed_canopy.*.?.plant_thermal_adaptation_offset_c[plant], context.runscript.canopy_stress_parameters.growth_temperature);
                const water_filled_fraction = if (context.soil_solver_properties.matrix_bulk_volume_m3[soil] > 0)
                    std.math.clamp(context.grid.matrix_liquid_water_m3[soil] / context.soil_solver_properties.matrix_bulk_volume_m3[soil], 0, 1)
                else
                    0;
                const diffusivity = [3]f64{
                    try context.runscript.root_nutrient_parameters.diffusivityM2PerH(0, context.grid.soil_temperature_k[soil]),
                    try context.runscript.root_nutrient_parameters.diffusivityM2PerH(1, context.grid.soil_temperature_k[soil]),
                    try context.runscript.root_nutrient_parameters.diffusivityM2PerH(2, context.grid.soil_temperature_k[soil]),
                };
                const inputs = try workspace.inputs(competitor_count);
                try ecosys.plant_root_nutrient_uptake.buildLayerInputs(.{
                    .traits_by_element = context.root_nutrient_traits[plant],
                    .soil_pool_g_element = soil_pools,
                    .total_soil_water_volume_m3 = context.grid.matrix_liquid_water_m3[soil],
                    .zone_fraction_by_pool = zone_fraction_by_pool,
                    .aqueous_diffusivity_m2_per_h_by_element = diffusivity,
                    .liquid_tortuosity = context.runscript.root_nutrient_parameters.liquid_tortuosity_coefficient * water_filled_fraction * water_filled_fraction,
                    .timestep_h = 1,
                    .soil_path_length_m = water.soil_path_length_m[root],
                    .root_cylinder_radius_m = water.root_cylinder_radius_m[root],
                    .root_surface_area_per_radius_m = water.root_surface_area_per_radius_m[root],
                    .root_surface_area_m2_per_plant = roots.root_surface_area_m2_per_plant[root],
                    .root_activity_fraction = std.math.clamp(activity.protein * temperature_response, 0, 1),
                    .nutrient_activity_fraction_by_element = .{ activity.nitrogen, activity.nitrogen, activity.phosphorus },
                    .oxygen_limitation_fraction = std.math.clamp(roots.oxygen_process_constraint_fraction[root], 0, 1),
                    .root_water_uptake_m3_per_plant_step = @max(0, -roots.water_uptake_m3_per_h[root]) / water.plant_population_count[plant],
                    .plant_population_count = water.plant_population_count[plant],
                    .population_competition_fraction_by_pool = competition,
                    .carbon_uptake_limitation_fraction = activity.carbon,
                }, inputs);
                workspace.competitors[competitor_count] = .{ .plant = plant, .domain = domain, .layer = layer, .input_by_pool = inputs };
                workspace.admission_index_by_competitor[competitor_count] = admission_index;
                competitor_count += 1;
            }
            if (exudation_competitor_count > 0) {
                var substrate_fractions: [ecosys.plant_root_exudation.substrate_count]f64 = undefined;
                try ecosys.soil_heterotrophic_respiration_step.substrateComplexFractions(
                    context.soil_organic,
                    soil,
                    &substrate_fractions,
                    context.config.physical_tolerance.carbon_g,
                );
                try exudation_workspace.stageLayer(
                    roots,
                    context.soil_organic,
                    soil,
                    context.soil_nitrogen_flux_workspace.layer_biologically_active_water_m3[soil],
                    &substrate_fractions,
                    context.runscript.root_exudation_parameters,
                    context.config.physical_tolerance.waterVolume(context.soil_nitrogen_flux_workspace.layer_biologically_active_water_m3[soil]),
                    context.config.physical_tolerance.carbon(context.soil_nitrogen_flux_workspace.layer_biologically_active_water_m3[soil] * context.runscript.root_exudation_parameters.maximum_root_carbon_concentration_g_c_per_m3),
                    exudation_competitor_count,
                );
                for (0..exudation_competitor_count) |competitor_index| {
                    const result_base = competitor_index * ecosys.plant_root_exudation.substrate_count;
                    const admission_index = exudation_workspace.admission_index_by_competitor[competitor_index];
                    transaction_organic[admission_index] = try ecosys.plant_root_exudation.mapTransactionResult(exudation_workspace.staged_results[result_base..][0..ecosys.plant_root_exudation.substrate_count]);
                    transaction_organic_selected[admission_index] = true;
                }
            }
            var salt_competitor_count: usize = 0;
            if (exudation_competitor_count > 0 and salt_workspace != null and context.grid.matrix_liquid_water_m3[soil] > context.config.physical_tolerance.waterVolume(context.grid.matrix_liquid_water_m3[soil])) {
                const salt_water_filled_fraction = if (context.soil_solver_properties.matrix_bulk_volume_m3[soil] > 0)
                    std.math.clamp(context.grid.matrix_liquid_water_m3[soil] / context.soil_solver_properties.matrix_bulk_volume_m3[soil], 0, 1)
                else
                    0;
                try diagnostics.traceIssue108Cation(context, "before_root_salt", soil, context.executed_weather_hours.* + 1);
                var soil_salt_content_mol = [ecosys.plant_root_salt_exchange.species_count]f64{
                    context.soil_chemistry.aqueous[soil].aluminum * context.grid.matrix_liquid_water_m3[soil],
                    context.soil_chemistry.aqueous[soil].iron * context.grid.matrix_liquid_water_m3[soil],
                    context.soil_chemistry.aqueous[soil].calcium * context.grid.matrix_liquid_water_m3[soil],
                    context.soil_chemistry.aqueous[soil].magnesium * context.grid.matrix_liquid_water_m3[soil],
                    context.soil_chemistry.aqueous[soil].sodium * context.grid.matrix_liquid_water_m3[soil],
                    context.soil_chemistry.aqueous[soil].potassium * context.grid.matrix_liquid_water_m3[soil],
                    context.soil_chemistry.aqueous[soil].sulfate * context.grid.matrix_liquid_water_m3[soil],
                    context.soil_chemistry.aqueous[soil].chloride * context.grid.matrix_liquid_water_m3[soil],
                };
                for (0..exudation_competitor_count) |competitor_index| {
                    const competitor = exudation_workspace.competitors[competitor_index];
                    const root = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
                    if (roots.aqueous_volume_m3[root] <= context.config.physical_tolerance.waterVolume(roots.aqueous_volume_m3[root])) continue;
                    const radial_log = @log((water.soil_path_length_m[root] + water.root_cylinder_radius_m[root]) / water.root_cylinder_radius_m[root]);
                    if (!std.math.isFinite(radial_log) or radial_log <= 0) return error.InvalidRootSaltDiffusionGeometry;
                    salt_workspace.?.competitors[salt_competitor_count] = .{
                        .plant = competitor.plant,
                        .domain = competitor.domain,
                        .layer = competitor.layer,
                        .soil_inventory_fraction = water.root_biome_fraction[root],
                        .root_water_volume_m3 = roots.aqueous_volume_m3[root],
                        .water_advection_m3_per_step = @max(0, -roots.water_uptake_m3_per_h[root]) / water.plant_population_count[competitor.plant],
                        .diffusive_geometry_m = salt_water_filled_fraction * water.root_surface_area_per_radius_m[root] / radial_log,
                        .plant_population_count = water.plant_population_count[competitor.plant],
                    };
                    var salt_admission_index: ?usize = null;
                    for (admitted, 0..) |coordinate, admission_index| {
                        if (coordinate.plant == competitor.plant and coordinate.biological_domain == competitor.domain and coordinate.soil_layer == competitor.layer) {
                            salt_admission_index = admission_index;
                            break;
                        }
                    }
                    salt_workspace.?.admission_index_by_competitor[salt_competitor_count] = salt_admission_index orelse return error.MissingRootSaltAdmissionCoordinate;
                    salt_competitor_count += 1;
                }
                if (salt_competitor_count > 0) {
                    _ = try salt_workspace.?.stage(
                        roots,
                        &soil_salt_content_mol,
                        context.grid.matrix_liquid_water_m3[soil],
                        context.grid.soil_temperature_k[soil],
                        context.runscript.root_salt_parameters,
                        salt_competitor_count,
                        .{
                            .absolute_tolerance_mol = context.config.nonlinear_tolerance.amount_mol,
                            .relative_tolerance = context.config.nonlinear_tolerance.relative,
                            .picard_relaxation = context.config.picard_relaxation,
                            .max_iterations = context.iteration_limits.water_heat_solute_max_iterations,
                        },
                    );
                    for (0..salt_competitor_count) |competitor_index| {
                        const result_base = competitor_index * ecosys.plant_root_salt_exchange.species_count;
                        const admission_index = salt_workspace.?.admission_index_by_competitor[competitor_index];
                        transaction_salt.?[admission_index] = try ecosys.plant_root_salt_exchange.mapTransactionResult(salt_workspace.?.staged_exchange_mol[result_base..][0..ecosys.plant_root_salt_exchange.species_count]);
                        transaction_salt_selected.?[admission_index] = true;
                    }
                    try salt_workspace.?.state_updateStaged(roots, &soil_salt_content_mol, salt_competitor_count);
                }
                const inverse_water = 1 / context.grid.matrix_liquid_water_m3[soil];
                context.soil_chemistry.aqueous[soil].aluminum = soil_salt_content_mol[0] * inverse_water;
                context.soil_chemistry.aqueous[soil].iron = soil_salt_content_mol[1] * inverse_water;
                context.soil_chemistry.aqueous[soil].calcium = soil_salt_content_mol[2] * inverse_water;
                context.soil_chemistry.aqueous[soil].magnesium = soil_salt_content_mol[3] * inverse_water;
                context.soil_chemistry.aqueous[soil].sodium = soil_salt_content_mol[4] * inverse_water;
                context.soil_chemistry.aqueous[soil].potassium = soil_salt_content_mol[5] * inverse_water;
                context.soil_chemistry.aqueous[soil].sulfate = soil_salt_content_mol[6] * inverse_water;
                context.soil_chemistry.aqueous[soil].chloride = soil_salt_content_mol[7] * inverse_water;
                try diagnostics.traceIssue108Cation(context, "after_root_salt_writeback", soil, context.executed_weather_hours.* + 1);
            }
            if (competitor_count > 0) {
                try workspace.stage(roots, soil_pools, competitor_count);
                for (0..competitor_count) |competitor_index| {
                    const result_base = competitor_index * ecosys.plant_root_nutrient_uptake.nutrient_pool_count;
                    const admission_index = workspace.admission_index_by_competitor[competitor_index];
                    transaction_nutrient[admission_index] = try ecosys.plant_root_nutrient_uptake.mapTransactionResult(
                        workspace.staged_results[result_base..][0..ecosys.plant_root_nutrient_uptake.nutrient_pool_count],
                        context.runscript.root_metabolism_parameters.nutrient_uptake_respiration_g_c_per_g_element,
                    );
                    transaction_nutrient_selected[admission_index] = true;
                }
                try workspace.state_updateStagedAssimilating(
                    roots,
                    soil_pools,
                    competitor_count,
                    context.runscript.root_metabolism_parameters.nutrient_uptake_respiration_g_c_per_g_element,
                );
            }
            for (admitted) |coordinate| {
                if (coordinate.soil_layer != layer) continue;
                const root = try roots.layerIndex(coordinate.plant, coordinate.biological_domain, layer);
                var next_root_demand: [ecosys.plant_root_nutrient_uptake.nutrient_pool_count]f64 = undefined;
                for (0..ecosys.plant_root_nutrient_uptake.nutrient_pool_count) |pool_index| {
                    const pool: ecosys.plant_root_nutrient_uptake.NutrientPool = @enumFromInt(pool_index);
                    next_root_demand[pool_index] = currentRootNutrientDemand(roots, pool, root);
                }
                try context.soil_nutrient_competition_attempt.addSoil(soil, next_root_demand);
            }
            if (exudation_competitor_count > 0) {
                for (0..ecosys.plant_root_exudation.substrate_count) |substrate| {
                    var total: ecosys.plant_root_exudation.Result = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
                    for (0..exudation_competitor_count) |competitor_index| {
                        const result = exudation_workspace.staged_results[competitor_index * ecosys.plant_root_exudation.substrate_count + substrate];
                        total.carbon_g_c += result.carbon_g_c;
                        total.nitrogen_g_n += result.nitrogen_g_n;
                        total.phosphorus_g_p += result.phosphorus_g_p;
                    }
                    const available_index = try context.plant_available_nutrients.organicIndex(soil, substrate);
                    inline for (.{
                        context.plant_available_nutrients.organic_carbon_change_g_c_per_h[available_index] - total.carbon_g_c,
                        context.plant_available_nutrients.organic_nitrogen_change_g_n_per_h[available_index] - total.nitrogen_g_n,
                        context.plant_available_nutrients.organic_phosphorus_change_g_p_per_h[available_index] - total.phosphorus_g_p,
                    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootExudationMirrorStateUpdate;
                }
                try exudation_workspace.state_updateLayer(
                    roots,
                    context.soil_organic,
                    soil,
                    exudation_competitor_count,
                );
                for (0..ecosys.plant_root_exudation.substrate_count) |substrate| {
                    var total: ecosys.plant_root_exudation.Result = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
                    for (0..exudation_competitor_count) |competitor_index| {
                        const result = exudation_workspace.staged_results[competitor_index * ecosys.plant_root_exudation.substrate_count + substrate];
                        total.carbon_g_c += result.carbon_g_c;
                        total.nitrogen_g_n += result.nitrogen_g_n;
                        total.phosphorus_g_p += result.phosphorus_g_p;
                    }
                    const available_index = try context.plant_available_nutrients.organicIndex(soil, substrate);
                    const authoritative = context.soil_organic.dissolved[soil * ecosys.plant_root_exudation.substrate_count + substrate];
                    context.plant_available_nutrients.organic_carbon_g_c[available_index] = authoritative.carbon_g_c;
                    context.plant_available_nutrients.organic_nitrogen_g_n[available_index] = authoritative.nitrogen_g_n;
                    context.plant_available_nutrients.organic_phosphorus_g_p[available_index] = authoritative.phosphorus_g_p;
                    context.plant_available_nutrients.organic_carbon_change_g_c_per_h[available_index] -= total.carbon_g_c;
                    context.plant_available_nutrients.organic_nitrogen_change_g_n_per_h[available_index] -= total.nitrogen_g_n;
                    context.plant_available_nutrients.organic_phosphorus_change_g_p_per_h[available_index] -= total.phosphorus_g_p;
                }
            }
            if ((competitor_count > 0 or salt_competitor_count > 0) and dynamic_salts) {
                var hydrogen_charge_mol: f64 = 0;
                for (0..competitor_count) |competitor_index| {
                    const result_base = competitor_index * ecosys.plant_root_nutrient_uptake.nutrient_pool_count;
                    hydrogen_charge_mol += try ecosys.plant_root_ion_balance.hydrogenChargeMol(
                        workspace.staged_results[result_base..][0..ecosys.plant_root_nutrient_uptake.nutrient_pool_count],
                        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                        .{},
                    );
                }
                const zero_nutrient_results = [_]ecosys.plant_root_nutrient_uptake.Result{.{
                    .demand_g_element = 0,
                    .uptake_g_element = 0,
                    .oxygen_unlimited_uptake_g_element = 0,
                    .carbon_unlimited_uptake_g_element = 0,
                    .available_g_element = 0,
                }} ** ecosys.plant_root_nutrient_uptake.nutrient_pool_count;
                for (0..salt_competitor_count) |competitor_index| {
                    const competitor = salt_workspace.?.competitors[competitor_index];
                    var salts: ecosys.plant_root_ion_balance.SaltUptakeMol = .{};
                    inline for (@typeInfo(ecosys.plant_root_system.SaltSpecies).@"enum".fields) |field| {
                        const species: ecosys.plant_root_system.SaltSpecies = @enumFromInt(field.value);
                        @field(salts, field.name) = roots.salt_uptake_mol_per_h[try roots.saltIndex(competitor.plant, competitor.domain, competitor.layer, species)];
                    }
                    hydrogen_charge_mol += try ecosys.plant_root_ion_balance.hydrogenChargeMol(
                        &zero_nutrient_results,
                        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                        salts,
                    );
                }
                _ = try ecosys.plant_root_ion_balance.state_updateHydrogenCharge(
                    &context.soil_chemistry.aqueous[soil].hydrogen,
                    context.grid.matrix_liquid_water_m3[soil],
                    hydrogen_charge_mol,
                    1,
                );
            }
        }
    }
    try context.plant_available_nutrients.publishMineralPools(context.soil_chemistry, context.grid.matrix_liquid_water_m3, context.fertilizer_band);
}

fn previousRootNutrientDemand(roots: anytype, pool: ecosys.plant_root_nutrient_uptake.NutrientPool, root: usize) f64 {
    return switch (pool) {
        .ammonium_nonband => roots.previous_ammonium_demand_nonband_g_n_per_h[root],
        .ammonium_band => roots.previous_ammonium_demand_band_g_n_per_h[root],
        .nitrate_nonband => roots.previous_nitrate_demand_nonband_g_n_per_h[root],
        .nitrate_band => roots.previous_nitrate_demand_band_g_n_per_h[root],
        .phosphate_h2_nonband => roots.previous_phosphate_h2_demand_nonband_g_p_per_h[root],
        .phosphate_h2_band => roots.previous_phosphate_h2_demand_band_g_p_per_h[root],
        .phosphate_h_nonband => roots.previous_phosphate_h_demand_nonband_g_p_per_h[root],
        .phosphate_h_band => roots.previous_phosphate_h_demand_band_g_p_per_h[root],
    };
}

fn currentRootNutrientDemand(roots: anytype, pool: ecosys.plant_root_nutrient_uptake.NutrientPool, root: usize) f64 {
    return switch (pool) {
        .ammonium_nonband => roots.ammonium_demand_nonband_g_n_per_h[root],
        .ammonium_band => roots.ammonium_demand_band_g_n_per_h[root],
        .nitrate_nonband => roots.nitrate_demand_nonband_g_n_per_h[root],
        .nitrate_band => roots.nitrate_demand_band_g_n_per_h[root],
        .phosphate_h2_nonband => roots.phosphate_h2_demand_nonband_g_p_per_h[root],
        .phosphate_h2_band => roots.phosphate_h2_demand_band_g_p_per_h[root],
        .phosphate_h_nonband => roots.phosphate_h_demand_nonband_g_p_per_h[root],
        .phosphate_h_band => roots.phosphate_h_demand_band_g_p_per_h[root],
    };
}

fn nutrientDemandPresenceLimit(physical_tolerance: anytype, pool: ecosys.plant_root_nutrient_uptake.NutrientPool, scale_g: f64) f64 {
    return switch (pool) {
        .ammonium_nonband, .ammonium_band, .nitrate_nonband, .nitrate_band => physical_tolerance.nitrogen(scale_g),
        .phosphate_h2_nonband, .phosphate_h2_band, .phosphate_h_nonband, .phosphate_h_band => physical_tolerance.phosphorus(scale_g),
    };
}
