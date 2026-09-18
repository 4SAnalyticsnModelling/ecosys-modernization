//! Daily plant carbon/nutrient pool accounting, mortality and litterfall.
//!
//! Extracted verbatim from `ecosys_ng.zig` so the entry point holds only
//! `main`. Declaration bodies are unchanged.

const std = @import("std");
const ecosys = @import("ecosys_ng");
pub fn applyPlantStorageRemobilization(
    context: anytype,
    calendar: ecosys.plant_development.Calendar,
    internal_activity: *ecosys.plant_internal_root_shoot_activity.State,
) !void {
    if (context.plant_roots.* == null or context.detailed_canopy.* == null or context.plant_growth_stages.* == null or context.branch_development.* == null or context.plant_phenology.* == null or context.plant_dormancy.* == null or context.plant_storage_remobilization_workspace.* == null) return;
    const roots = &context.plant_roots.*.?;
    const canopy = &context.detailed_canopy.*.?;
    const stages = &context.plant_growth_stages.*.?;
    const development = &context.branch_development.*.?;
    const dormancy = &context.plant_dormancy.*.?;
    const phenology = &context.plant_phenology.*.?;
    const workspace = &context.plant_storage_remobilization_workspace.*.?;
    const water_workspace = if (context.plant_water_workspace.*) |*value|
        value
    else
        return error.MissingPlantWaterWorkspaceForStorageRemobilization;
    if (workspace.plant_count != stages.plant_count or water_workspace.plant_count != stages.plant_count)
        return error.StorageRemobilizationDimensionMismatch;
    for (0..stages.plant_count) |plant| {
        const range = try stages.branchRange(plant);
        if (range.first == range.end or !context.plant_phenology.*.?.active[plant] or roots.roots_dead[plant]) continue;
        const root_traits = context.root_metabolism_plant_parameters[plant];
        // GROSUB 774--809 derives the current-hour IFLGZ/IFLGZR state before
        // any of the 4609+ storage/root transfers. This used to run only
        // later, inside root metabolism, so every transfer saw stale flags.
        for (range.first..range.end) |branch| {
            if (stages.branches[branch].dead) continue;
            try ecosys.plant_dormancy.advanceRemobilization(
                &dormancy.branches[branch],
                .{
                    .timestep_h = 1,
                    .canopy_temperature_c = context.plants.canopy_temperature_k[plant] - 273.15,
                    .canopy_total_water_potential_megapascal = context.plants.canopy_water_potential_megapascal[plant],
                },
                context.development_dormancy_parameters[plant],
                ecosys.plant_growth_stages.growthHabitFromReadq(root_traits.growth_habit),
                try ecosys.plant_growth_stages.phenologyTypeFromReadq(root_traits.leaf_phenology_type),
                stages.branches[branch].seed_number_set_end_day != 0,
            );
        }
        // GROSUB NB1 is the fixed HFUNC main-stalk identity. It is not
        // reassigned when that branch dies; living laterals still reference
        // its VRNS/CPOOL values, while the NB1-only DATRP block is skipped.
        const main_branch = (try stages.mainStalkBranch(plant)) orelse continue;
        const plant_parameters = context.shoot_growth_plant_parameters[plant];
        const dormancy_parameters = context.development_dormancy_parameters[plant];
        const leafoff_start_fraction = if (plant_parameters.leaf_phenology_type == 0)
            dormancy_parameters.evergreen_leafoff_remobilization_start_fraction
        else
            dormancy_parameters.deciduous_leafoff_remobilization_start_fraction;
        const water = try ecosys.canopy_photosynthesis.canopyWaterGrowthResponse(
            plant_parameters.root_profile_type == 0,
            canopy.plant_canopy_turgor_potential_megapascal[plant],
            context.runscript.phenology_parameters.minimum_turgor_potential_megapascal,
            context.plants.canopy_water_potential_megapascal[plant],
            plant_parameters.stomatal_turgor_shape_per_megapascal,
        );
        const temperature_factor = canopy.plant_uptake_growth_temperature_response[plant];
        const remobilization_increment_h = try ecosys.plant_storage_remobilization.remobilizationTimeIncrementH(
            temperature_factor,
            water.growth_fraction,
            1,
        );
        const growth_habit: u8 = if (context.plant_topology_controls.growth_habit_code[plant] == 0) 0 else 1;
        const remobilization_duration_h = context.runscript.storage_remobilization_parameters.remobilization_duration_h[growth_habit];
        const cell = plant / canopy.species_count;
        const active_layer_count = context.grid.active_soil_layer_count[cell];
        if (active_layer_count > roots.soil_layer_count)
            return error.StorageRemobilizationDimensionMismatch;

        // GROSUB carries these plant aggregates into the NB transaction. They
        // must be captured before CH2OH changes root mobile carbon below.
        var total_leaf_sheath_carbon_g_c: f64 = 0;
        var total_stalk_carbon_g_c: f64 = 0;
        var total_sapwood_carbon_g_c: f64 = 0;
        for (range.first..range.end) |branch| {
            total_leaf_sheath_carbon_g_c += canopy.branch_leaf_carbon_g[branch] + canopy.branch_sheath_carbon_g[branch];
            total_stalk_carbon_g_c += canopy.branch_stalk_carbon_g[branch];
            total_sapwood_carbon_g_c += canopy.branch_sapwood_carbon_g[branch];
        }
        // Durable GROSUB-entry snapshots. WTLS/WTSTK/WVSTK and the derived
        // FWODR are carried through all later branch/root blocks this hour.
        canopy.plant_leaf_sheath_carbon_g[plant] = total_leaf_sheath_carbon_g_c;
        canopy.plant_stalk_carbon_g[plant] = total_stalk_carbon_g_c;
        canopy.plant_sapwood_carbon_g[plant] = total_sapwood_carbon_g_c;
        var carried_total_root_carbon_g_c: f64 = 0;
        for (0..root_traits.biologicalDomainCount()) |domain| for (0..active_layer_count) |layer| {
            const root = try roots.layerIndex(plant, domain, layer);
            carried_total_root_carbon_g_c += roots.mobile_carbon_g[root];
            for (0..roots.active_root_axis_count[plant]) |axis| {
                const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
                carried_total_root_carbon_g_c += roots.axis_primary_carbon_g[axis_layer] +
                    roots.axis_secondary_carbon_g[axis_layer];
            }
        };
        workspace.carried_total_root_carbon_g_c[plant] = carried_total_root_carbon_g_c;
        const root_nonwoody_fraction = water_workspace.woody_root_fraction[plant];
        if (!std.math.isFinite(root_nonwoody_fraction) or root_nonwoody_fraction < 0 or root_nonwoody_fraction > 1)
            return error.InvalidStorageRemobilizationRootWoodFraction;
        const plant_presence_threshold_g_c =
            context.runscript.plant_pool_parameters.plant_root_structural_presence_g_per_plant *
            canopy.plant_population_count[plant];

        // GROSUB 4572--5109 is one source-ordered DO NB=1,NBR transaction.
        // NB1 alone owns DATRP, but it must not be moved ahead of lower array
        // indices: every living branch consumes storage/root state exactly in
        // source index order. The old plant-level call omitted lateral storage
        // transfers entirely (GROSUB-015).
        for (range.first..range.end) |branch| {
            if (stages.branches[branch].dead) continue;
            const branch_dormancy = dormancy.branches[branch];
            const admitted = try ecosys.plant_storage_remobilization.activationEnabled(.{
                .annual_growth_habit = plant_parameters.growth_habit == 0,
                .lifecycle_initialized = phenology.lifecycle_initialized[plant],
                .current_day_of_year = calendar.day_of_year,
                .current_year = calendar.current_year,
                .planting_day_of_year = context.development_planting_day_of_year[plant],
                .planting_year = context.development_planting_year[plant],
                .accumulated_leafout_h = dormancy.branches[main_branch].accumulated_leafout_h,
                .required_leafout_h = dormancy_parameters.required_leafout_h,
                .accumulated_leafoff_h = branch_dormancy.accumulated_leafoff_h,
                .required_leafoff_h = dormancy_parameters.required_leafoff_h,
                .leafoff_remobilization_start_fraction = leafoff_start_fraction,
            });
            if (admitted) {
                if (!development.leafout_initialization_enabled[branch]) {
                    development.remobilization_progress_h[branch] = 0;
                    development.leafout_initialization_enabled[branch] = true;
                }
                // Only NB1 evaluates DATRP/advances ATRP before CH2OH.
                if (branch == main_branch)
                    development.remobilization_progress_h[branch] += remobilization_increment_h;

                var root_mobile_carbon_g_c: f64 = 0;
                var root_mobile_nitrogen_g_n: f64 = 0;
                var root_mobile_phosphorus_g_p: f64 = 0;
                var root_structural_carbon_g_c: f64 = 0;
                for (0..active_layer_count) |layer| {
                    const root = try roots.layerIndex(plant, 0, layer);
                    root_mobile_carbon_g_c += roots.mobile_carbon_g[root];
                    root_mobile_nitrogen_g_n += roots.mobile_nitrogen_g[root];
                    root_mobile_phosphorus_g_p += roots.mobile_phosphorus_g[root];
                    for (0..roots.active_root_axis_count[plant]) |axis| {
                        const axis_layer = try roots.layerAxisIndex(plant, 0, layer, axis);
                        root_structural_carbon_g_c += roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer];
                    }
                }
                const slices = try workspace.refreshPlant(roots, plant);
                const planting_layer = roots.planting_layer_by_plant[plant];
                if (planting_layer >= active_layer_count)
                    return error.StorageRemobilizationPlantingLayerInactive;
                if (root_structural_carbon_g_c > plant_presence_threshold_g_c and
                    root_mobile_carbon_g_c > plant_presence_threshold_g_c)
                {
                    for (0..active_layer_count) |layer| {
                        var layer_structural_carbon_g_c: f64 = 0;
                        for (0..roots.active_root_axis_count[plant]) |axis| {
                            const axis_layer = try roots.layerAxisIndex(plant, 0, layer, axis);
                            layer_structural_carbon_g_c += roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer];
                        }
                        slices.structural_carbon_fractions[layer] = layer_structural_carbon_g_c / root_structural_carbon_g_c;
                    }
                } else {
                    for (0..roots.soil_layer_count) |layer|
                        slices.structural_carbon_fractions[layer] = @floatFromInt(@intFromBool(layer == planting_layer));
                }
                for (active_layer_count..roots.soil_layer_count) |layer|
                    slices.structural_carbon_fractions[layer] = 0;
                const transfers = try ecosys.plant_storage_remobilization.calculate(context.runscript.storage_remobilization_parameters, .{
                    .growth_habit = growth_habit,
                    .aboveground_turnover_type = context.canopy_layer_controls.biomass_turnover_type[plant],
                    .accumulated_remobilization_h = development.remobilization_progress_h[branch],
                    .remobilization_time_increment_h = remobilization_increment_h,
                    .biological_timestep_h = 1,
                    .storage_carbon_g_c = canopy.plant_seed_storage_carbon_g[plant],
                    .storage_nitrogen_g_n = canopy.plant_seed_storage_nitrogen_g[plant],
                    .storage_phosphorus_g_p = canopy.plant_seed_storage_phosphorus_g[plant],
                    .shoot_mobile_carbon_g_c = canopy.branch_mobile_carbon_g[branch],
                    .shoot_mobile_nitrogen_g_n = canopy.branch_mobile_nitrogen_g[branch],
                    .shoot_mobile_phosphorus_g_p = canopy.branch_mobile_phosphorus_g[branch],
                    .root_mobile_carbon_g_c = root_mobile_carbon_g_c,
                    .root_mobile_nitrogen_g_n = root_mobile_nitrogen_g_n,
                    .root_mobile_phosphorus_g_p = root_mobile_phosphorus_g_p,
                    .continue_annual_remobilization_after_duration = plant_parameters.leaf_phenology_type < 2,
                    .presence_threshold_g_c = plant_presence_threshold_g_c,
                });

                // GROSUB 4799--4857 allocates root N/P from CPOOLR after the
                // carbon publication. Reconstruct those post-carbon weights
                // before the atomic state update; inactive layers remain zero.
                var post_root_mobile_total_g_c: f64 = 0;
                for (0..active_layer_count) |layer| {
                    const root = slices.root_layer_indices[layer];
                    const post_carbon = roots.mobile_carbon_g[root] +
                        transfers.root_carbon_g_c * slices.structural_carbon_fractions[layer];
                    slices.mobile_carbon_fractions[layer] = post_carbon;
                    post_root_mobile_total_g_c += post_carbon;
                }
                for (active_layer_count..roots.soil_layer_count) |layer|
                    slices.mobile_carbon_fractions[layer] = 0;
                if (root_structural_carbon_g_c > plant_presence_threshold_g_c and
                    post_root_mobile_total_g_c > plant_presence_threshold_g_c)
                {
                    for (0..active_layer_count) |layer|
                        slices.mobile_carbon_fractions[layer] /= post_root_mobile_total_g_c;
                } else {
                    for (0..roots.soil_layer_count) |layer|
                        slices.mobile_carbon_fractions[layer] = @floatFromInt(@intFromBool(layer == planting_layer));
                }
                try ecosys.plant_storage_remobilization.state_update(canopy, roots, plant, branch, slices.root_layer_indices, slices.structural_carbon_fractions, slices.mobile_carbon_fractions, transfers);
                for (0..active_layer_count) |layer| try internal_activity.recordCanopyToRoot(cell, layer, .{
                    .carbon_g_c = transfers.root_carbon_g_c * slices.structural_carbon_fractions[layer],
                    .nitrogen_g_n = transfers.root_nitrogen_g_n * slices.mobile_carbon_fractions[layer],
                    .phosphorus_g_p = transfers.root_phosphorus_g_p * slices.mobile_carbon_fractions[layer],
                });
            }

            if (branch != main_branch and development.remobilization_progress_h[branch] <= remobilization_duration_h) {
                development.remobilization_progress_h[branch] += remobilization_increment_h;
                try ecosys.shoot_growth_runtime.redistributeMainBranchMobileDuringRemobilization(
                    canopy,
                    main_branch,
                    branch,
                    temperature_factor,
                    context.runscript.branch_mobile_exchange_parameters,
                    1,
                );
            }

            // GROSUB 4902--4964: the exact isolated owner existed but had no
            // production call. This is canopy-internal, so it intentionally
            // does not enter the cross-scope sidecar.
            const seasonal_result = try ecosys.plant_storage_remobilization.remobilizeBranchPoolsToSeasonalStorage(
                context.runscript.storage_remobilization_parameters,
                .{
                    .shoot_remobilization_enabled = branch_dormancy.shoot_remobilization_enabled,
                    .growth_habit = if (growth_habit == 0) .annual else .perennial,
                    .branch_reserve = .{
                        .carbon_g_c = canopy.branch_reserve_carbon_g[branch],
                        .nitrogen_g_n = canopy.branch_reserve_nitrogen_g[branch],
                        .phosphorus_g_p = canopy.branch_reserve_phosphorus_g[branch],
                    },
                    .branch_mobile = .{
                        .carbon_g_c = canopy.branch_mobile_carbon_g[branch],
                        .nitrogen_g_n = canopy.branch_mobile_nitrogen_g[branch],
                        .phosphorus_g_p = canopy.branch_mobile_phosphorus_g[branch],
                    },
                    .seasonal_storage = .{
                        .carbon_g_c = canopy.plant_seed_storage_carbon_g[plant],
                        .nitrogen_g_n = canopy.plant_seed_storage_nitrogen_g[plant],
                        .phosphorus_g_p = canopy.plant_seed_storage_phosphorus_g[plant],
                    },
                    .exchange_fraction_per_h = context.runscript.storage_remobilization_parameters.perennial_nutrient_equilibration_fraction_per_h[context.canopy_layer_controls.biomass_turnover_type[plant]],
                    .biological_timestep_h = 1,
                },
            );
            canopy.branch_reserve_carbon_g[branch] = seasonal_result.next_branch_reserve.carbon_g_c;
            canopy.branch_reserve_nitrogen_g[branch] = seasonal_result.next_branch_reserve.nitrogen_g_n;
            canopy.branch_reserve_phosphorus_g[branch] = seasonal_result.next_branch_reserve.phosphorus_g_p;
            canopy.branch_mobile_carbon_g[branch] = seasonal_result.next_branch_mobile.carbon_g_c;
            canopy.branch_mobile_nitrogen_g[branch] = seasonal_result.next_branch_mobile.nitrogen_g_n;
            canopy.branch_mobile_phosphorus_g[branch] = seasonal_result.next_branch_mobile.phosphorus_g_p;
            canopy.plant_seed_storage_carbon_g[plant] = seasonal_result.next_seasonal_storage.carbon_g_c;
            canopy.plant_seed_storage_nitrogen_g[plant] = seasonal_result.next_seasonal_storage.nitrogen_g_n;
            canopy.plant_seed_storage_phosphorus_g[plant] = seasonal_result.next_seasonal_storage.phosphorus_g_p;

            // GROSUB 4966--5020 follows seasonal-storage remobilization in
            // the same NB transaction. This exact kernel was previously
            // reachable only from tests.
            const branch_exchange = try ecosys.plant_storage_remobilization.equilibrateBranchMobileAndReserve(.{
                .growth_habit = if (growth_habit == 0) .annual else .perennial,
                .annual_final_seed_number_is_set = stages.branches[branch].seed_number_set_end_day != 0,
                .perennial_stem_elongation_started = stages.branches[branch].stem_elongation_start_day != 0,
                .branch_leaf_and_petiole_carbon_g_c = canopy.branch_leaf_carbon_g[branch] + canopy.branch_sheath_carbon_g[branch],
                .branch_sapwood_carbon_g_c = canopy.branch_sapwood_carbon_g[branch],
                .branch_mobile = .{
                    .carbon_g_c = canopy.branch_mobile_carbon_g[branch],
                    .nitrogen_g_n = canopy.branch_mobile_nitrogen_g[branch],
                    .phosphorus_g_p = canopy.branch_mobile_phosphorus_g[branch],
                },
                .branch_reserve = .{
                    .carbon_g_c = canopy.branch_reserve_carbon_g[branch],
                    .nitrogen_g_n = canopy.branch_reserve_nitrogen_g[branch],
                    .phosphorus_g_p = canopy.branch_reserve_phosphorus_g[branch],
                },
                .maximum_mobile_nitrogen_per_carbon_g_n_per_g_c = context.runscript.storage_remobilization_parameters.maximum_mobile_nitrogen_per_carbon_g_n_per_g_c,
                .maximum_mobile_phosphorus_per_carbon_g_p_per_g_c = context.runscript.storage_remobilization_parameters.maximum_mobile_phosphorus_per_carbon_g_p_per_g_c,
                .carbon_exchange_fraction_per_h = context.runscript.shoot_node_growth_parameters.branch_reserve_carbon_exchange_fraction_per_h,
                .nutrient_exchange_fraction_per_h = context.runscript.shoot_node_growth_parameters.branch_reserve_nutrient_exchange_fraction_per_h,
                .biological_timestep_h = 1,
                .presence_threshold_g_c = plant_presence_threshold_g_c,
            });
            canopy.branch_mobile_carbon_g[branch] = branch_exchange.next_branch_mobile.carbon_g_c;
            canopy.branch_mobile_nitrogen_g[branch] = branch_exchange.next_branch_mobile.nitrogen_g_n;
            canopy.branch_mobile_phosphorus_g[branch] = branch_exchange.next_branch_mobile.phosphorus_g_p;
            canopy.branch_reserve_carbon_g[branch] = branch_exchange.next_branch_reserve.carbon_g_c;
            canopy.branch_reserve_nitrogen_g[branch] = branch_exchange.next_branch_reserve.nitrogen_g_n;
            canopy.branch_reserve_phosphorus_g[branch] = branch_exchange.next_branch_reserve.phosphorus_g_p;

            // GROSUB 5021--5047 immediately follows for this branch. This is
            // canopy-internal and intentionally absent from the layer sidecar.
            const low_reserve = try ecosys.plant_storage_remobilization.replenishLowBranchReserve(.{
                .branch_sapwood_carbon_g_c = canopy.branch_sapwood_carbon_g[branch],
                .plant_total_sapwood_carbon_g_c = total_sapwood_carbon_g_c,
                .plant_total_root_carbon_g_c = carried_total_root_carbon_g_c,
                .branch_reserve_carbon_g_c = canopy.branch_reserve_carbon_g[branch],
                .seasonal_storage_carbon_g_c = canopy.plant_seed_storage_carbon_g[plant],
                .low_reserve_threshold_g_c_per_g_sapwood_c = 0.10,
                .exchange_fraction_per_h = 0.01,
                .biological_timestep_h = 1,
                .presence_threshold_g_c = plant_presence_threshold_g_c,
            });
            canopy.branch_reserve_carbon_g[branch] = low_reserve.next_branch_reserve_carbon_g_c;
            canopy.plant_seed_storage_carbon_g[plant] = low_reserve.next_seasonal_storage_carbon_g_c;

            // GROSUB 5050--5109 is the final root/canopy transfer in this NB
            // block. Validate the whole layer sweep before committing roots.
            if (growth_habit == 0 and stages.branches[branch].seed_number_set_end_day != 0) {
                var validated_reserve: ecosys.plant_storage_remobilization.ElementTransfer = .{
                    .carbon_g_c = canopy.branch_reserve_carbon_g[branch],
                    .nitrogen_g_n = canopy.branch_reserve_nitrogen_g[branch],
                    .phosphorus_g_p = canopy.branch_reserve_phosphorus_g[branch],
                };
                for (0..active_layer_count) |layer| {
                    const soil = try context.grid.layerIndex(cell, layer);
                    var active_root_carbon_g_c: f64 = 0;
                    for (0..roots.active_root_axis_count[plant]) |axis| {
                        const axis_layer = try roots.layerAxisIndex(plant, 0, layer, axis);
                        active_root_carbon_g_c += roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer];
                    }
                    const root = try roots.layerIndex(plant, 0, layer);
                    const checked = try ecosys.plant_storage_remobilization.transferAnnualRootMobileToBranchReserve(.{
                        .growth_habit = .annual,
                        .final_seed_number_is_set = true,
                        .layer_is_soil = context.soil_solver_properties.layer_thickness_m[soil] > context.runscript.soil_geometry_parameters.minimum_layer_thickness_m,
                        .active_root_carbon_g_c = active_root_carbon_g_c,
                        .root_nonwoody_carbon_fraction = root_nonwoody_fraction,
                        .branch_sapwood_carbon_g_c = canopy.branch_sapwood_carbon_g[branch],
                        .root_mobile = .{
                            .carbon_g_c = roots.mobile_carbon_g[root],
                            .nitrogen_g_n = roots.mobile_nitrogen_g[root],
                            .phosphorus_g_p = roots.mobile_phosphorus_g[root],
                        },
                        .branch_reserve = validated_reserve,
                        .carbon_exchange_fraction_per_h = context.runscript.shoot_node_growth_parameters.branch_reserve_carbon_exchange_fraction_per_h,
                        .nutrient_exchange_fraction_per_h = context.runscript.shoot_node_growth_parameters.branch_reserve_nutrient_exchange_fraction_per_h,
                        .biological_timestep_h = 1,
                        .presence_threshold_g_c = plant_presence_threshold_g_c,
                    });
                    validated_reserve = checked.next_branch_reserve;
                }
                var branch_reserve: ecosys.plant_storage_remobilization.ElementTransfer = .{
                    .carbon_g_c = canopy.branch_reserve_carbon_g[branch],
                    .nitrogen_g_n = canopy.branch_reserve_nitrogen_g[branch],
                    .phosphorus_g_p = canopy.branch_reserve_phosphorus_g[branch],
                };
                for (0..active_layer_count) |layer| {
                    const soil = try context.grid.layerIndex(cell, layer);
                    var active_root_carbon_g_c: f64 = 0;
                    for (0..roots.active_root_axis_count[plant]) |axis| {
                        const axis_layer = try roots.layerAxisIndex(plant, 0, layer, axis);
                        active_root_carbon_g_c += roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer];
                    }
                    const root = try roots.layerIndex(plant, 0, layer);
                    const accepted = try ecosys.plant_storage_remobilization.transferAnnualRootMobileToBranchReserve(.{
                        .growth_habit = .annual,
                        .final_seed_number_is_set = true,
                        .layer_is_soil = context.soil_solver_properties.layer_thickness_m[soil] > context.runscript.soil_geometry_parameters.minimum_layer_thickness_m,
                        .active_root_carbon_g_c = active_root_carbon_g_c,
                        .root_nonwoody_carbon_fraction = root_nonwoody_fraction,
                        .branch_sapwood_carbon_g_c = canopy.branch_sapwood_carbon_g[branch],
                        .root_mobile = .{
                            .carbon_g_c = roots.mobile_carbon_g[root],
                            .nitrogen_g_n = roots.mobile_nitrogen_g[root],
                            .phosphorus_g_p = roots.mobile_phosphorus_g[root],
                        },
                        .branch_reserve = branch_reserve,
                        .carbon_exchange_fraction_per_h = context.runscript.shoot_node_growth_parameters.branch_reserve_carbon_exchange_fraction_per_h,
                        .nutrient_exchange_fraction_per_h = context.runscript.shoot_node_growth_parameters.branch_reserve_nutrient_exchange_fraction_per_h,
                        .biological_timestep_h = 1,
                        .presence_threshold_g_c = plant_presence_threshold_g_c,
                    });
                    try internal_activity.recordRootToCanopy(cell, layer, .{
                        .carbon_g_c = accepted.root_to_reserve.carbon_g_c,
                        .nitrogen_g_n = accepted.root_to_reserve.nitrogen_g_n,
                        .phosphorus_g_p = accepted.root_to_reserve.phosphorus_g_p,
                    });
                    roots.mobile_carbon_g[root] = accepted.next_root_mobile.carbon_g_c;
                    roots.mobile_nitrogen_g[root] = accepted.next_root_mobile.nitrogen_g_n;
                    roots.mobile_phosphorus_g[root] = accepted.next_root_mobile.phosphorus_g_p;
                    branch_reserve = accepted.next_branch_reserve;
                }
                canopy.branch_reserve_carbon_g[branch] = branch_reserve.carbon_g_c;
                canopy.branch_reserve_nitrogen_g[branch] = branch_reserve.nitrogen_g_n;
                canopy.branch_reserve_phosphorus_g[branch] = branch_reserve.phosphorus_g_p;
            }
        }
    }
}

/// GROSUB 8159--8199, after root/mycorrhizal exchange and before the
/// shoot-root equilibration sweep. The exact kernel was previously test-only.
pub fn applyPerennialRootSeasonalStorage(
    context: anytype,
    internal_activity: *ecosys.plant_internal_root_shoot_activity.State,
) !void {
    if (context.plant_roots.* == null or context.detailed_canopy.* == null or
        context.plant_growth_stages.* == null or context.plant_dormancy.* == null or
        context.plant_storage_remobilization_workspace.* == null)
        return;
    const roots = &context.plant_roots.*.?;
    const canopy = &context.detailed_canopy.*.?;
    const stages = &context.plant_growth_stages.*.?;
    const dormancy = &context.plant_dormancy.*.?;
    const workspace = &context.plant_storage_remobilization_workspace.*.?;
    for (0..stages.plant_count) |plant| {
        if (!context.plant_phenology.*.?.active[plant]) continue;
        // GROSUB 807 assigns IFLGZR on every living NB; the scalar retained
        // after DO 105 is therefore the last living branch in source order,
        // not NB1. The old main-branch read changed the seasonal root sink.
        const range = try stages.branchRange(plant);
        var root_flag_branch: ?usize = null;
        for (range.first..range.end) |branch| {
            if (!stages.branches[branch].dead) root_flag_branch = branch;
        }
        const retained_branch = root_flag_branch orelse continue;
        const growth_habit: ecosys.plant_storage_remobilization.GrowthHabit =
            if (context.plant_topology_controls.growth_habit_code[plant] == 0) .annual else .perennial;
        if (!ecosys.plant_storage_remobilization.sourceOrderRootStorageTransferIsEnabled(
            dormancy.branches[retained_branch].shoot_remobilization_enabled,
            growth_habit,
        )) continue;
        const cell = plant / canopy.species_count;
        const active_layer_count = context.grid.active_soil_layer_count[cell];
        if (active_layer_count == 0 or active_layer_count > roots.soil_layer_count)
            return error.RootSeasonalStorageDimensionMismatch;
        const slices = try workspace.refreshPlant(roots, plant);
        @memset(slices.seasonal_storage_transfers, .{});
        const exchange_fraction_per_h = context.runscript.storage_remobilization_parameters
            .perennial_nutrient_equilibration_fraction_per_h[context.canopy_layer_controls.biomass_turnover_type[plant]];
        for (0..active_layer_count) |layer| {
            const root = slices.root_layer_indices[layer];
            slices.seasonal_storage_transfers[layer] = try ecosys.plant_storage_remobilization.rootToSeasonalStorage(
                context.runscript.storage_remobilization_parameters,
                roots.mobile_carbon_g[root],
                roots.mobile_nitrogen_g[root],
                roots.mobile_phosphorus_g[root],
                exchange_fraction_per_h,
                1,
            );
        }
        try ecosys.plant_storage_remobilization.state_updateRootToSeasonalStorage(
            canopy,
            roots,
            plant,
            slices.root_layer_indices[0..active_layer_count],
            slices.seasonal_storage_transfers[0..active_layer_count],
        );
        for (slices.seasonal_storage_transfers[0..active_layer_count], 0..) |transfer, layer|
            try internal_activity.recordRootToCanopy(cell, layer, .{
                .carbon_g_c = transfer.carbon_g_c,
                .nitrogen_g_n = transfer.nitrogen_g_n,
                .phosphorus_g_p = transfer.phosphorus_g_p,
            });
    }
}

pub fn applyStorageExhaustionMortality(context: anytype, calendar: ecosys.plant_development.Calendar) !void {
    if (context.plant_roots.* == null or context.detailed_canopy.* == null or context.plant_growth_stages.* == null or context.branch_development.* == null or context.plant_phenology.* == null or context.canopy_precipitation_retention.* == null) return;
    const canopy = &context.detailed_canopy.*.?;
    const phenology = &context.plant_phenology.*.?;
    for (0..phenology.active.len) |plant| {
        if (!phenology.active[plant]) continue;
        const cell = plant / context.config.plant_populations;
        const perennial = context.plant_topology_controls.growth_habit_code[plant] != 0;
        const storage_exhausted = try ecosys.plant_mortality.sourceOrderStorageExhausted(
            canopy.plant_seed_storage_carbon_g[plant],
            canopy.plant_seed_storage_nitrogen_g[plant],
            canopy.plant_seed_storage_phosphorus_g[plant],
            perennial,
            context.runscript.plant_pool_parameters.plant_root_structural_presence_g_per_plant,
            canopy.plant_population_count[plant],
        );
        const harvest = if (perennial and storage_exhausted)
            context.plant_harvest orelse return error.StorageExhaustionRequiresRootLitterContext
        else
            context.plant_harvest;
        const died = try ecosys.plant_mortality.applyStorageExhaustion(
            canopy,
            &context.plant_growth_stages.*.?,
            &context.branch_development.*.?,
            phenology,
            &context.plant_roots.*.?,
            &context.canopy_precipitation_retention.*.?,
            context.plants,
            plant,
            perennial,
            context.canopy_cell_area_m2[cell],
            context.runscript.plant_pool_parameters.plant_root_structural_presence_g_per_plant,
        );
        if (died) {
            try ecosys.plant_harvest_runtime.applyWholePlantMortalityResidue(harvest.?, plant);
            try ecosys.plant_harvest_runtime.releaseDeadRootsToLitter(harvest.?, plant);
            const exported = try ecosys.plant_harvest_runtime.publishPlantProducts(harvest.?, plant);
            if (exported.carbon_g != 0 or exported.nitrogen_g != 0 or exported.phosphorus_g != 0)
                return error.UnexpectedPlantMortalityExport;
            if (calendar.current_year < 0 or calendar.current_year > std.math.maxInt(u16))
                return error.PerennialReplantYearOutOfRange;
            const current_year: u16 = @intCast(calendar.current_year);
            try ecosys.plant_mortality.scheduleNextDayReplant(
                phenology,
                plant,
                calendar.day_of_year,
                current_year,
                ecosys.climate_change.daysInYear(current_year),
            );
        }
        if (died) std.log.info(
            "perennial storage exhausted: plant={d} cell={d} storage_C_g={e} storage_N_g={e} storage_P_g={e}",
            .{ plant, cell, canopy.plant_seed_storage_carbon_g[plant], canopy.plant_seed_storage_nitrogen_g[plant], canopy.plant_seed_storage_phosphorus_g[plant] },
        );
    }
}

pub fn applyNaturalBranchMortality(context: anytype, calendar: ecosys.plant_development.Calendar) !void {
    if (context.detailed_canopy.* == null or context.plant_growth_stages.* == null or context.branch_development.* == null or
        context.plant_phenology.* == null or context.plant_roots.* == null or context.canopy_precipitation_retention.* == null)
        return;
    const harvest = context.plant_harvest orelse return error.NaturalBranchDeathRequiresLitterContext;
    const canopy = &context.detailed_canopy.*.?;
    const growth = &context.plant_growth_stages.*.?;
    const development = &context.branch_development.*.?;
    const phenology = &context.plant_phenology.*.?;
    for (0..phenology.active.len) |plant| {
        if (!phenology.active[plant]) continue;
        const parameters = context.shoot_growth_plant_parameters[plant];
        const branches = try growth.branchRange(plant);
        var dead_count: usize = 0;
        var encountered_dead = false;
        for (branches.first..branches.end) |branch| {
            const dead = growth.branches[branch].dead or development.dead[branch];
            if (!dead) continue;
            dead_count += 1;
            encountered_dead = true;
            try ecosys.plant_harvest_runtime.applyNaturalDeadBranchResidue(
                harvest,
                plant,
                branch,
                parameters.growth_habit == 0 and parameters.leaf_phenology_type != 0,
            );
            try ecosys.shoot_growth_runtime.resetNaturalDeadBranch(growth, development, &context.plant_dormancy.*.?, branch);
        }
        if (dead_count == branches.end - branches.first) {
            const winter_annual = parameters.growth_habit == 0 and parameters.leaf_phenology_type != 0;
            if (!winter_annual)
                try ecosys.plant_harvest_runtime.applyWholePlantMortalityResidue(harvest, plant);
            const cell = plant / context.config.plant_populations;
            try ecosys.plant_mortality.applyAllBranchesDead(
                canopy,
                phenology,
                &context.plant_roots.*.?,
                &context.canopy_precipitation_retention.*.?,
                context.plants,
                plant,
                winter_annual,
                context.canopy_cell_area_m2[cell],
            );
            try ecosys.plant_harvest_runtime.releaseDeadRootsToLitter(harvest, plant);
            if (parameters.growth_habit != 0) {
                if (calendar.current_year < 0 or calendar.current_year > std.math.maxInt(u16))
                    return error.PerennialReplantYearOutOfRange;
                const year: u16 = @intCast(calendar.current_year);
                try ecosys.plant_mortality.scheduleNextDayReplant(phenology, plant, calendar.day_of_year, year, ecosys.climate_change.daysInYear(year));
            }
        }
        if (encountered_dead) {
            const exported = try ecosys.plant_harvest_runtime.publishPlantProducts(harvest, plant);
            if (exported.carbon_g != 0 or exported.nitrogen_g != 0 or exported.phosphorus_g != 0)
                return error.UnexpectedNaturalBranchDeathExport;
        }
    }
}

/// GROSUB lines 12598–12626. Exponential decay of standing dead C/N/P into
/// surface litter at each hourly step. The woody/fine-residue partition is
/// derived from per-plant branch sapwood/total-stalk ratios (FWOOD in
/// Fortran). All three elemental partitions use the same fraction
/// (FWOODN=FWOODP=FWOOD). Output is routed into the surface organic pools via
/// the existing shoot-litter bridge (position-0=woody, position-1=fine residue).
/// grosub.f:422-431 (FWOOD): herbaceous aboveground turnover type (IBTYP==0)
/// or shallow/no root profile (IGTYP<=1) forces all standing-dead litterfall
/// to the fine/non-woody position, regardless of the branch sapwood-to-stalk
/// ratio. Only woody, deep-rooted plant types use the true sapwood ratio.
/// Returns the fine/non-woody (position 1) fraction; woody (position 0) is
/// `1 - result`.
pub fn nonWoodyLitterfallFraction(biomass_turnover_type: u8, root_profile_type: u8, total_stalk_carbon_g: f64, total_sapwood_carbon_g: f64) f64 {
    const is_herbaceous = biomass_turnover_type == 0 or root_profile_type <= 1;
    if (is_herbaceous) return 1.0;
    if (total_stalk_carbon_g > 0) return std.math.clamp(total_sapwood_carbon_g / total_stalk_carbon_g, 0, 1);
    return 1.0;
}

pub fn applyStandingDeadLitterfall(context: anytype) !void {
    if (context.detailed_canopy.* == null) return;
    const canopy = &context.detailed_canopy.*.?;
    const plant_count = canopy.cell_count * canopy.species_count;
    if (plant_count == 0) return;

    const fraction_count = ecosys.standing_dead_litterfall.kinetic_fraction_count;
    const position_count = ecosys.standing_dead_litterfall.litter_position_count;

    var lf_state = try ecosys.standing_dead_litterfall.State.init(context.allocator, plant_count);
    defer lf_state.deinit();

    const partition_count = plant_count * position_count;
    const partitions = try context.allocator.alloc(f64, partition_count);
    defer context.allocator.free(partitions);
    for (0..plant_count) |plant| {
        const b_first = canopy.plant_branch_offsets[plant];
        const b_end = canopy.plant_branch_offsets[plant + 1];
        var total_stalk: f64 = 0;
        var total_sapwood: f64 = 0;
        for (b_first..b_end) |branch| {
            total_stalk += canopy.branch_stalk_carbon_g[branch];
            total_sapwood += canopy.branch_sapwood_carbon_g[branch];
        }
        const sapwood_frac = nonWoodyLitterfallFraction(
            context.canopy_layer_controls.biomass_turnover_type[plant],
            context.canopy_layer_controls.root_profile_type[plant],
            total_stalk,
            total_sapwood,
        );
        partitions[plant * position_count + 0] = 1.0 - sapwood_frac;
        partitions[plant * position_count + 1] = sapwood_frac;
    }

    try ecosys.standing_dead_litterfall.apply(
        &lf_state,
        .{
            .biomass_turnover_type_by_plant = context.canopy_layer_controls.biomass_turnover_type,
            .root_profile_type_by_plant = context.canopy_layer_controls.root_profile_type,
            .canopy_growth_temperature_response_by_plant = canopy.plant_uptake_growth_temperature_response,
            .timestep_h = 1,
            .carbon_partition_by_plant_and_position = partitions,
            .nitrogen_partition_by_plant_and_position = partitions,
            .phosphorus_partition_by_plant_and_position = partitions,
        },
        canopy.plant_standing_dead_carbon_by_kinetic_g,
        canopy.plant_standing_dead_nitrogen_by_kinetic_g,
        canopy.plant_standing_dead_phosphorus_by_kinetic_g,
    );

    // Keep per-plant totals in sync with the updated per-fraction pools.
    for (0..plant_count) |plant| {
        var c: f64 = 0;
        var n: f64 = 0;
        var p: f64 = 0;
        const first = plant * fraction_count;
        for (first..first + fraction_count) |i| {
            c += canopy.plant_standing_dead_carbon_by_kinetic_g[i];
            n += canopy.plant_standing_dead_nitrogen_by_kinetic_g[i];
            p += canopy.plant_standing_dead_phosphorus_by_kinetic_g[i];
        }
        canopy.plant_standing_dead_carbon_g[plant] = c;
        canopy.plant_standing_dead_nitrogen_g[plant] = n;
        canopy.plant_standing_dead_phosphorus_g[plant] = p;
    }

    // StateUpdate litter to surface organic (position-0 → woody, position-1 →
    // fine residue) and retain the same plant-resolved CSNC/ZSNC/PSNC
    // producer. GROSUB 12598--12617 adds standing-dead litter to the ordinary
    // litter arrays before 12636--12653 forms HCSNC/HZSNC/HPSNC; dropping it
    // from `shoot_senescence_products_by_plant` made the surface recipient
    // change without the paired plant litterfall publication.
    for (0..canopy.cell_count) |cell| {
        var cell_products: ecosys.canopy_photosynthesis.SenescenceProducts = .{};
        for (0..canopy.species_count) |species| {
            const plant = cell * canopy.species_count + species;
            const plant_products = try ecosys.standing_dead_litterfall.productsForPlant(&lf_state, plant);
            ecosys.canopy_photosynthesis.addSenescenceProducts(
                &context.shoot_senescence_products_by_plant[plant],
                plant_products,
            );
            ecosys.canopy_photosynthesis.addSenescenceProducts(&cell_products, plant_products);
        }
        try ecosys.shoot_litter_bridge.state_updateCell(context.surface_organic, cell, cell_products);
    }
}

pub const DailyPlantElement = enum { nitrogen, phosphorus };

pub fn calculateDailyPlantElementPools(
    canopy: *const ecosys.canopy_photosynthesis.State,
    roots: *const ecosys.plant_root_system.State,
    plant: usize,
    branches: ecosys.canopy_photosynthesis.Range,
    element: DailyPlantElement,
    biological_domain_count: usize,
    root_workspace_g_by_layer: []f64,
) !ecosys.plant_daily_pool_aggregation.ElementPools {
    if (root_workspace_g_by_layer.len != roots.soil_layer_count or biological_domain_count < 1 or biological_domain_count > ecosys.plant_root_system.biological_domain_count)
        return error.DailyPlantElementRootDimensionMismatch;
    @memset(root_workspace_g_by_layer, 0);
    var root_symbiont_g: f64 = 0;
    for (0..roots.soil_layer_count) |layer| for (0..biological_domain_count) |domain| {
        const root = try roots.layerIndex(plant, domain, layer);
        root_workspace_g_by_layer[layer] += switch (element) {
            .nitrogen => roots.mobile_nitrogen_g[root],
            .phosphorus => roots.mobile_phosphorus_g[root],
        };
        root_symbiont_g += switch (element) {
            .nitrogen => roots.symbiont_structural_nitrogen_g_n[root] + roots.symbiont_mobile_nitrogen_g_n[root],
            .phosphorus => roots.symbiont_structural_phosphorus_g_p[root] + roots.symbiont_mobile_phosphorus_g_p[root],
        };
        for (0..roots.active_root_axis_count[plant]) |axis| {
            const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
            root_workspace_g_by_layer[layer] += switch (element) {
                .nitrogen => roots.axis_primary_nitrogen_g[axis_layer] + roots.axis_secondary_nitrogen_g[axis_layer],
                .phosphorus => roots.axis_primary_phosphorus_g[axis_layer] + roots.axis_secondary_phosphorus_g[axis_layer],
            };
        }
    };
    var canopy_symbiont_g: f64 = 0;
    for (branches.first..branches.end) |branch| {
        canopy_symbiont_g += switch (element) {
            .nitrogen => canopy.branch_symbiont_structural_nitrogen_g[branch] + canopy.branch_symbiont_mobile_nitrogen_g[branch],
            .phosphorus => canopy.branch_symbiont_structural_phosphorus_g[branch] + canopy.branch_symbiont_mobile_phosphorus_g[branch],
        };
    }
    return ecosys.plant_daily_pool_aggregation.calculateElement(.{
        .branch_leaf_g = switch (element) {
            .nitrogen => canopy.branch_leaf_nitrogen_g[branches.first..branches.end],
            .phosphorus => canopy.branch_leaf_phosphorus_g[branches.first..branches.end],
        },
        .branch_sheath_g = switch (element) {
            .nitrogen => canopy.branch_sheath_nitrogen_g[branches.first..branches.end],
            .phosphorus => canopy.branch_sheath_phosphorus_g[branches.first..branches.end],
        },
        .branch_stalk_g = switch (element) {
            .nitrogen => canopy.branch_stalk_nitrogen_g[branches.first..branches.end],
            .phosphorus => canopy.branch_stalk_phosphorus_g[branches.first..branches.end],
        },
        .branch_reserve_g = switch (element) {
            .nitrogen => canopy.branch_reserve_nitrogen_g[branches.first..branches.end],
            .phosphorus => canopy.branch_reserve_phosphorus_g[branches.first..branches.end],
        },
        .branch_husk_g = switch (element) {
            .nitrogen => canopy.branch_husk_nitrogen_g[branches.first..branches.end],
            .phosphorus => canopy.branch_husk_phosphorus_g[branches.first..branches.end],
        },
        .branch_ear_g = switch (element) {
            .nitrogen => canopy.branch_ear_nitrogen_g[branches.first..branches.end],
            .phosphorus => canopy.branch_ear_phosphorus_g[branches.first..branches.end],
        },
        .branch_grain_g = switch (element) {
            .nitrogen => canopy.branch_grain_nitrogen_g[branches.first..branches.end],
            .phosphorus => canopy.branch_grain_phosphorus_g[branches.first..branches.end],
        },
        .branch_mobile_g = switch (element) {
            .nitrogen => canopy.branch_mobile_nitrogen_g[branches.first..branches.end],
            .phosphorus => canopy.branch_mobile_phosphorus_g[branches.first..branches.end],
        },
        .root_g_by_layer = root_workspace_g_by_layer,
        .canopy_symbiont_g = canopy_symbiont_g,
        .root_symbiont_g = root_symbiont_g,
        .standing_dead_g = switch (element) {
            .nitrogen => canopy.plant_standing_dead_nitrogen_g[plant],
            .phosphorus => canopy.plant_standing_dead_phosphorus_g[plant],
        },
        .seed_storage_g = switch (element) {
            .nitrogen => canopy.plant_seed_storage_nitrogen_g[plant],
            .phosphorus => canopy.plant_seed_storage_phosphorus_g[plant],
        },
    });
}

fn calculateDailyPlantCarbonPools(
    canopy: *const ecosys.canopy_photosynthesis.State,
    roots: *const ecosys.plant_root_system.State,
    plant: usize,
    branches: ecosys.canopy_photosynthesis.Range,
    biological_domain_count: usize,
    root_carbon_g_by_layer: []f64,
    root_length_density_m_per_m3_by_layer: []f64,
) !ecosys.plant_daily_pool_aggregation.CarbonPools {
    if (root_carbon_g_by_layer.len != roots.soil_layer_count or
        root_length_density_m_per_m3_by_layer.len != roots.soil_layer_count)
    {
        return error.DailyPlantElementRootDimensionMismatch;
    }
    if (biological_domain_count < 1 or biological_domain_count > ecosys.plant_root_system.biological_domain_count)
        return error.DailyPlantElementRootDimensionMismatch;
    @memset(root_carbon_g_by_layer, 0);
    @memset(root_length_density_m_per_m3_by_layer, 0);
    for (0..roots.soil_layer_count) |layer| {
        for (0..biological_domain_count) |domain| {
            const root = try roots.layerIndex(plant, domain, layer);
            root_carbon_g_by_layer[layer] += roots.mobile_carbon_g[root];
            for (0..roots.active_root_axis_count[plant]) |axis| {
                const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
                root_carbon_g_by_layer[layer] +=
                    roots.axis_primary_carbon_g[axis_layer] +
                    roots.axis_secondary_carbon_g[axis_layer];
            }
        }
    }

    // Preserve source-order aggregation semantics used by plant_daily_output and
    // avoid reusing historical transformed outputs as inputs.
    const primary_root_first = try roots.layerIndex(plant, 0, 0);
    for (0..roots.soil_layer_count) |local_layer| {
        root_length_density_m_per_m3_by_layer[local_layer] =
            roots.root_length_density_m_per_m3[primary_root_first + local_layer];
    }

    var canopy_symbiont_carbon_g: f64 = 0;
    for (branches.first..branches.end) |branch| {
        canopy_symbiont_carbon_g +=
            canopy.branch_symbiont_structural_carbon_g[branch] +
            canopy.branch_symbiont_mobile_carbon_g[branch];
    }
    var root_symbiont_carbon_g: f64 = 0;
    for (0..roots.soil_layer_count) |layer| {
        for (0..biological_domain_count) |domain| {
            const root = try roots.layerIndex(plant, domain, layer);
            root_symbiont_carbon_g +=
                roots.symbiont_structural_carbon_g_c[root] +
                roots.symbiont_mobile_carbon_g_c[root];
        }
    }

    var leaf_intermediate_carbon_g: f64 = 0;
    for (branches.first..branches.end) |branch| {
        const nodes = try canopy.nodeRange(branch);
        for (nodes.first..nodes.end) |node| {
            leaf_intermediate_carbon_g +=
                canopy.node_c3_nonstructural_carbon_g[node] +
                canopy.node_c4_mesophyll_nonstructural_carbon_g[node] +
                canopy.node_bundle_sheath_co2_carbon_g[node] +
                canopy.node_bundle_sheath_bicarbonate_carbon_g[node];
        }
    }

    var projected_leaf_area_m2: f64 = 0;
    for (branches.first..branches.end) |branch| projected_leaf_area_m2 += canopy.branch_leaf_area_m2[branch];

    return ecosys.plant_daily_pool_aggregation.calculateCarbonInto(.{
        .branch_leaf_carbon_g = canopy.branch_leaf_carbon_g[branches.first..branches.end],
        .branch_sheath_carbon_g = canopy.branch_sheath_carbon_g[branches.first..branches.end],
        .branch_stalk_carbon_g = canopy.branch_stalk_carbon_g[branches.first..branches.end],
        .branch_reserve_carbon_g = canopy.branch_reserve_carbon_g[branches.first..branches.end],
        .branch_husk_carbon_g = canopy.branch_husk_carbon_g[branches.first..branches.end],
        .branch_ear_carbon_g = canopy.branch_ear_carbon_g[branches.first..branches.end],
        .branch_grain_carbon_g = canopy.branch_grain_carbon_g[branches.first..branches.end],
        .branch_mobile_carbon_g = canopy.branch_mobile_carbon_g[branches.first..branches.end],
        .branch_seed_count = canopy.branch_seed_count[branches.first..branches.end],
        .c4_intermediate_carbon_g = leaf_intermediate_carbon_g,
        .canopy_symbiont_carbon_g = canopy_symbiont_carbon_g,
        .root_carbon_g_by_layer = root_carbon_g_by_layer,
        .primary_root_length_density_m_per_m3_by_layer = root_length_density_m_per_m3_by_layer,
        .root_symbiont_carbon_g = root_symbiont_carbon_g,
        .standing_dead_carbon_g = canopy.plant_standing_dead_carbon_g[plant],
        .seed_storage_carbon_g = canopy.plant_seed_storage_carbon_g[plant],
        .projected_leaf_area_m2 = projected_leaf_area_m2,
        .plant_population_count = canopy.plant_population_count[plant],
    }, root_carbon_g_by_layer);
}

pub fn assemblePlantBalanceInputs(
    canopy: *const ecosys.canopy_photosynthesis.State,
    roots: *const ecosys.plant_root_system.State,
    root_metabolism_plant_parameters: []const ecosys.plant_root_metabolism.RuntimePlantParameters,
    plant_daily_flux_ledger: *const ecosys.plant_daily_flux_ledger.State,
    active_by_plant: []const bool,
    carbon_inputs: []ecosys.plant_daily_output.CarbonBalanceInputs,
    nitrogen_inputs: []ecosys.plant_daily_output.NutrientBalanceInputs,
    phosphorus_inputs: []ecosys.plant_daily_output.NutrientBalanceInputs,
    carbon_root_by_layer: []f64,
    carbon_root_length_density_by_layer: []f64,
    nutrient_root_by_layer: []f64,
) !void {
    if (carbon_inputs.len != active_by_plant.len or
        nitrogen_inputs.len != active_by_plant.len or
        phosphorus_inputs.len != active_by_plant.len)
        return error.InvalidPlantBalanceStateUpdateDimensions;

    @memset(std.mem.sliceAsBytes(carbon_inputs), 0);
    @memset(std.mem.sliceAsBytes(nitrogen_inputs), 0);
    @memset(std.mem.sliceAsBytes(phosphorus_inputs), 0);

    for (0..active_by_plant.len) |plant| {
        if (!active_by_plant[plant]) continue;
        const branches = try canopy.branchRange(plant);
        const carbon_pools = try calculateDailyPlantCarbonPools(
            canopy,
            roots,
            plant,
            branches,
            root_metabolism_plant_parameters[plant].biologicalDomainCount(),
            carbon_root_by_layer,
            carbon_root_length_density_by_layer,
        );
        const net_primary_productivity_g =
            plant_daily_flux_ledger.net_carbon_change_g[plant] +
            plant_daily_flux_ledger.signed_total_respiration_carbon_g[plant];
        const carbon_balance_inputs: ecosys.plant_daily_output.CarbonBalanceInputs = .{
            .shoot_carbon_g = carbon_pools.shoot_carbon_g,
            .root_carbon_g = carbon_pools.root_carbon_g,
            .nodule_carbon_g = carbon_pools.nodule_carbon_g,
            .storage_carbon_g = carbon_pools.storage_carbon_g,
            .standing_dead_carbon_g = carbon_pools.vegetative_residue_carbon_g,
            .cumulative_carbon_sink_g = plant_daily_flux_ledger.carbon_sink_g[plant],
            .cumulative_root_soil_carbon_exchange_g = plant_daily_flux_ledger.root_soil_carbon_exchange_g[plant],
            .cumulative_carbon_balance_g = plant_daily_flux_ledger.cumulative_carbon_balance_g[plant],
            .cumulative_harvested_carbon_g = plant_daily_flux_ledger.cumulative_harvested_carbon_g[plant],
            .harvested_carbon_g = plant_daily_flux_ledger.harvested_carbon_g[plant],
            .carbon_oxidation_g = plant_daily_flux_ledger.carbon_oxidation_g[plant],
            .cumulative_net_primary_productivity_g = net_primary_productivity_g,
        };
        carbon_inputs[plant] = carbon_balance_inputs;

        const element_domains = root_metabolism_plant_parameters[plant].biologicalDomainCount();
        const nitrogen_pools = try calculateDailyPlantElementPools(
            canopy,
            roots,
            plant,
            branches,
            .nitrogen,
            element_domains,
            nutrient_root_by_layer,
        );
        const phosphorus_pools = try calculateDailyPlantElementPools(
            canopy,
            roots,
            plant,
            branches,
            .phosphorus,
            element_domains,
            nutrient_root_by_layer,
        );

        nitrogen_inputs[plant] = .{
            .shoot_g = nitrogen_pools.shoot_g,
            .root_g = nitrogen_pools.root_g,
            .nodule_g = nitrogen_pools.nodule_g,
            .storage_g = nitrogen_pools.storage_g,
            .standing_dead_g = nitrogen_pools.vegetative_residue_g,
            .cumulative_sink_g = plant_daily_flux_ledger.nitrogen_sink_g[plant],
            .cumulative_root_soil_exchange_g = plant_daily_flux_ledger.root_soil_nitrogen_exchange_g[plant],
            .cumulative_balance_g = plant_daily_flux_ledger.cumulative_nitrogen_balance_g[plant],
            .cumulative_harvested_g = plant_daily_flux_ledger.cumulative_harvested_nitrogen_g[plant],
            .harvested_g = plant_daily_flux_ledger.harvested_nitrogen_g[plant],
            .oxidation_g = plant_daily_flux_ledger.nitrogen_oxidation_g[plant],
            .atmospheric_exchange_g = plant_daily_flux_ledger.ammonia_exchange_g_n[plant],
            .biological_fixation_g = plant_daily_flux_ledger.symbiotic_nitrogen_fixation_g[plant],
        };
        phosphorus_inputs[plant] = .{
            .shoot_g = phosphorus_pools.shoot_g,
            .root_g = phosphorus_pools.root_g,
            .nodule_g = phosphorus_pools.nodule_g,
            .storage_g = phosphorus_pools.storage_g,
            .standing_dead_g = phosphorus_pools.vegetative_residue_g,
            .cumulative_sink_g = plant_daily_flux_ledger.phosphorus_sink_g[plant],
            .cumulative_root_soil_exchange_g = plant_daily_flux_ledger.root_soil_phosphorus_exchange_g[plant],
            .cumulative_balance_g = plant_daily_flux_ledger.cumulative_phosphorus_balance_g[plant],
            .cumulative_harvested_g = plant_daily_flux_ledger.cumulative_harvested_phosphorus_g[plant],
            .harvested_g = plant_daily_flux_ledger.harvested_phosphorus_g[plant],
            .oxidation_g = plant_daily_flux_ledger.phosphorus_oxidation_g[plant],
        };
    }
}

test "nonWoodyLitterfallFraction: herbaceous turnover type (IBTYP==0) forces 100% fine-residue regardless of sapwood ratio" {
    // A herbaceous annual (e.g. Ottawa's maize/soybean) with a large sapwood
    // fraction would, without the FWOOD gate, route most litterfall to the
    // woody position. grosub.f:422-431 forces FWOOD(1)=1.0 for IBTYP==0.
    try std.testing.expectEqual(@as(f64, 1.0), nonWoodyLitterfallFraction(0, 3, 100.0, 90.0));
}

test "nonWoodyLitterfallFraction: shallow root profile (IGTYP<=1) forces 100% fine-residue regardless of turnover type" {
    try std.testing.expectEqual(@as(f64, 1.0), nonWoodyLitterfallFraction(2, 1, 100.0, 90.0));
    try std.testing.expectEqual(@as(f64, 1.0), nonWoodyLitterfallFraction(2, 0, 100.0, 90.0));
}

test "nonWoodyLitterfallFraction: woody, deep-rooted plant uses the true sapwood ratio" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), nonWoodyLitterfallFraction(2, 3, 100.0, 90.0), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), nonWoodyLitterfallFraction(1, 2, 40.0, 10.0), 1e-12);
}

test "nonWoodyLitterfallFraction: woody plant with zero stalk carbon still defaults to 100% fine-residue" {
    try std.testing.expectEqual(@as(f64, 1.0), nonWoodyLitterfallFraction(2, 3, 0.0, 0.0));
}

test "nonWoodyLitterfallFraction: sapwood ratio is clamped to [0, 1] even if inputs are inconsistent" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), nonWoodyLitterfallFraction(2, 3, 10.0, 50.0), 1e-12);
}
