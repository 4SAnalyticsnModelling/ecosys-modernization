//! `root_processes` declarations: metabolism.
//!
//! Split out of `root_processes.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ecosys = @import("ecosys_ng");

pub fn applyRootMetabolism(
    context: anytype,
    internal_activity: *ecosys.plant_internal_root_shoot_activity.State,
) !void {
    if (context.plant_roots.* == null or context.detailed_canopy.* == null or context.plant_growth_stages.* == null or context.branch_development.* == null or context.plant_dormancy.* == null or context.plant_root_metabolism_workspace.* == null or context.plant_storage_remobilization_workspace.* == null or context.plant_water_workspace.* == null or context.plant_litter_partition.* == null) return;
    const roots = &context.plant_roots.*.?;
    try context.root_litter_carbon_ledger.validateDimensions(
        roots.plant_count,
        ecosys.plant_root_system.biological_domain_count,
        roots.soil_layer_count,
    );
    @memset(context.root_litter_products_by_plant, std.mem.zeroes(ecosys.plant_root_metabolism.RootLitter));
    context.root_litter_carbon_ledger.resetHourly();
    const canopy = &context.detailed_canopy.*.?;
    const growth_stages = &context.plant_growth_stages.*.?;
    const branch_development = &context.branch_development.*.?;
    const parameters = context.runscript.root_metabolism_parameters;
    for (0..roots.plant_count) |plant| {
        if (!context.plant_phenology.*.?.active[plant]) continue;
        var oxygen_uptake_g_o: f64 = 0;
        var oxygen_demand_g_o: f64 = 0;
        for (0..context.root_metabolism_plant_parameters[plant].biologicalDomainCount()) |domain| for (0..roots.soil_layer_count) |layer| {
            const root = try roots.layerIndex(plant, domain, layer);
            oxygen_uptake_g_o += roots.oxygen_uptake_g_o_per_h[root];
            oxygen_demand_g_o += roots.oxygen_demand_g_o_per_h[root];
        };
        const oxygen_satisfaction = try ecosys.plant_root_porosity.sourceOxygenSatisfaction(
            oxygen_uptake_g_o,
            oxygen_demand_g_o,
            context.config.physical_tolerance.oxygen(@max(oxygen_uptake_g_o, oxygen_demand_g_o)),
        );
        const first_domain = try roots.domainIndex(plant, 0);
        const domain_count = context.root_metabolism_plant_parameters[plant].biologicalDomainCount();
        const domain_offsets = [2]usize{ 0, domain_count };
        const oxygen_satisfaction_by_plant = [1]f64{oxygen_satisfaction};
        try ecosys.plant_root_porosity_sweep.apply(
            .{ .current_porosity_fraction_by_domain = roots.current_porosity_fraction_by_domain[first_domain..][0..domain_count] },
            .{
                .plant_count = 1,
                .biological_domain_offsets_by_plant = &domain_offsets,
                .initial_porosity_fraction_by_domain = roots.initial_porosity_fraction_by_domain[first_domain..][0..domain_count],
                .oxygen_satisfaction_fraction_by_plant = &oxygen_satisfaction_by_plant,
                .biological_timestep_h = 1,
                .parameters = context.runscript.root_porosity_parameters,
            },
        );
        context.plant_water_workspace.*.?.root_porosity_fraction[plant] =
            roots.current_porosity_fraction_by_domain[first_domain];
    }
    for (0..context.grid.cell_count) |cell| {
        var workspace = &context.plant_root_metabolism_workspace.*.?.per_cell[cell];
        for (0..context.config.plant_populations) |species| {
            const plant = cell * context.config.plant_populations + species;
            if (!context.plant_phenology.*.?.active[plant] or roots.roots_dead[plant]) continue;
            try roots.resetGrosubAxisCountAggregates(plant);
            const traits = context.root_metabolism_plant_parameters[plant];
            try workspace.beginPlantHour(roots.active_root_axis_count[plant]);
            const branch_range = try growth_stages.branchRange(plant);
            if (branch_range.first == branch_range.end) continue;
            const main_branch = (try growth_stages.mainLivingBranch(plant)) orelse continue;
            // GROSUB 807--809 overwrites IFLGYR/IFLGZR/FLGZR for every
            // living NB, so root senescence retains the last living branch's
            // current-hour values rather than NB1's.
            var retained_root_remobilization_branch = main_branch;
            for (branch_range.first..branch_range.end) |branch| {
                if (!growth_stages.branches[branch].dead) {
                    retained_root_remobilization_branch = branch;
                }
            }
            const root_respiration_active = ecosys.plant_root_metabolism.rootRespirationActive(
                traits.growth_habit != 0,
                branch_development.stage_day[main_branch * 10 + 9] != 0,
            );
            var stalk_carbon_g_c: f64 = 0;
            var sapwood_carbon_g_c: f64 = 0;
            for (branch_range.first..branch_range.end) |branch| {
                stalk_carbon_g_c += canopy.branch_stalk_carbon_g[branch];
                sapwood_carbon_g_c += canopy.branch_sapwood_carbon_g[branch];
            }
            const wood = try ecosys.plant_root_metabolism.rootWoodComposition(
                context.canopy_layer_controls.biomass_turnover_type[plant] != 0,
                traits.root_profile_type > 1,
                stalk_carbon_g_c,
                sapwood_carbon_g_c,
                traits.stalk_nitrogen_to_carbon_g_n_per_g_c,
                traits.root_nitrogen_to_carbon_g_n_per_g_c,
                traits.stalk_phosphorus_to_carbon_g_p_per_g_c,
                traits.root_phosphorus_to_carbon_g_p_per_g_c,
                context.runscript.plant_pool_parameters.plant_root_structural_presence_g_per_plant,
                parameters.nonwoody_root_fraction_exponent,
            );
            const termination_feedback = try ecosys.plant_root_metabolism.annualTerminationFeedback(
                traits.growth_habit,
                branch_development.hours_without_grain_fill[main_branch],
                parameters.annual_termination_hours_without_grain_fill,
            );
            const coarse_litter = try context.plant_litter_partition.*.?.get(plant, .coarse_wood);
            const fine_litter = try context.plant_litter_partition.*.?.get(plant, .fine_root);
            const litter_kinetics: ecosys.plant_root_metabolism.RootLitterFractions = .{
                .woody_carbon = coarse_litter.carbon,
                .woody_nitrogen = coarse_litter.nitrogen,
                .woody_phosphorus = coarse_litter.phosphorus,
                .nonwoody_carbon = fine_litter.carbon,
                .nonwoody_nitrogen = fine_litter.nitrogen,
                .nonwoody_phosphorus = fine_litter.phosphorus,
            };
            var layer_bottom_for_withdrawal_m: f64 = 0;
            const active_soil_layer_count = context.grid.active_soil_layer_count[cell];
            for (0..active_soil_layer_count) |layer| {
                const soil = try context.grid.layerIndex(cell, layer);
                const thickness_m =
                    context.soil_solver_properties.layer_thickness_m[soil];
                layer_bottom_for_withdrawal_m += thickness_m;
                workspace.withdrawal_layer_thickness_m[layer] = thickness_m;
                workspace.withdrawal_layer_bottom_m[layer] =
                    layer_bottom_for_withdrawal_m;
            }
            // BIND-GROSUB-506, source `grosub.f` 506--512, from
            // `docs/binding_requests/A2_grosub_batch1.md` item A2-B1-03.
            //
            //     IF(PP.GT.ZERO)THEN
            //       WTRTA = AMAX1(0.999992087*WTRTA*XNFH, WTRT/PP)
            //     ELSE
            //       WTRTA = 0.0
            //     ENDIF
            //     XRTN1 = AMAX1(1.0, WTRTA**0.667)*PP
            //
            // THIS FIXES A LIVE SILENT DEFECT IN BOUND CODE, it does not merely
            // bind an idle kernel. `XRTN1` and `RTN1` are DIFFERENT quantities
            // in the source: `XRTN1` is the per-plant axis-count multiplier,
            // while `RTN1` is a per-layer-per-axis accumulator that GROSUB
            // BUILDS FROM `XRTN1` at 6445 and decrements by it at 7243. The
            // consumers of `XRTN1` are 5892, 5927 and 6424. Production was
            // passing `@max(1, roots.axis_primary_count[axis_layer])`, i.e.
            // `RTN1`, into the `XRTN1` slot of
            // `sourceOrderRootAxisSinkStrength`.
            //
            // Worse, `roots.axis_primary_count` has NO PRODUCTION WRITER. A1
            // re-grepped all of `src/`: every assignment
            // (`disturbance_management_dispatch.zig:707`/`:801`,
            // `plant_root_disturbance.zig:1100`, `plant_root_system.zig:1009`,
            // `water_balance.zig:849`) is inside a `test` block, and
            // `reconstructPlant` memsets it to zero. So `@max(1, 0)` pinned the
            // multiplier to the constant `1` for every plant, layer and axis
            // for the whole run, and primary root sink strength lost its entire
            // dependence on root mass per plant and on population. The failure
            // was SILENT because `1` is finite and positive, so no boundary
            // validation could fire.
            //
            // Publish set: `roots.retained_root_carbon_g_c_per_plant[plant]`
            // (`WTRTA`) and the hourly local `primary_axis_count_multiplier`.
            // The `WTRTA` field is NEW in this change and has exactly one
            // writer, this line, so no owner is replaced and nothing is double
            // mutated. It is registered in `plant_root_checkpoint` version 7
            // in the same change, because `WTRTA` is a recurrence on its own
            // previous value and an unserialized recurrence would make a
            // resumed run diverge from a continuous one, which is the Wave 2
            // `RESTART-EQUIVALENCE` obligation A8's `INIT-004` warns about.
            //
            // Ordering, and the one honest caveat. In the source, `WTRT` is
            // accumulated at 13004 (mobile `CPOOLR` plus primary `WTRT1` plus
            // secondary `WTRT2`), i.e. at the END of the plant pass, so line
            // 507 reads the PREVIOUS hour's total. Production has no persisted
            // `WTRT`, so this reassembles it here from the same three pools
            // before this hour's layer loop below mutates any of them. That is
            // the closest faithful analogue available without adding a second
            // persisted total, and A1 states the residual difference rather
            // than hiding it: any earlier step in this hour that moved root
            // carbon is already reflected here, where the source would still be
            // carrying the prior hour's sum.
            // Hoisted out of the `blk` below (rather than kept local to it)
            // because GROSUB 5021-5047's `WTRT(NZ,NY,NX).GT.ZEROP` gate and
            // `WTRTTX=WTRT(NZ,NY,NX)*FWTBR` allocation, applied per branch
            // near the end of this plant's pass, read the exact same
            // previous-hour-carried `WTRT` total this `blk` already
            // reconstructs for the `XRTN1` gate at `grosub.f` 507.
            var total_root_carbon_g_c: f64 = 0;
            const primary_axis_count_multiplier = blk: {
                const population = context.plant_water_workspace.*.?.plant_population_count[plant];
                for (0..traits.biologicalDomainCount()) |domain| {
                    for (0..context.grid.active_soil_layer_count[cell]) |layer| {
                        const domain_root = try roots.layerIndex(plant, domain, layer);
                        total_root_carbon_g_c += roots.mobile_carbon_g[domain_root];
                        for (0..roots.active_root_axis_count[plant]) |axis| {
                            const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
                            total_root_carbon_g_c += roots.axis_primary_carbon_g[axis_layer] +
                                roots.axis_secondary_carbon_g[axis_layer];
                        }
                    }
                }
                var scaling_state: ecosys.primary_root_axis_scaling.State = .{
                    .retained_root_carbon_g_c_per_plant = roots.retained_root_carbon_g_c_per_plant[plant],
                };
                const scaled = try ecosys.primary_root_axis_scaling.advance(&scaling_state, .{
                    .total_root_carbon_g_c = total_root_carbon_g_c,
                    .plant_population = population,
                    .biological_timestep_h = 1,
                    // `grosub.f` 500--501 names `0.999992087` as the rate of
                    // decline in primary root number, and 512 fixes the
                    // exponent at `0.667`. Both are source literals passed
                    // explicitly rather than promoted to runtime controls, so
                    // this stays a direct translation and no example parameter
                    // file changes.
                    .hourly_retention_fraction = 0.999992087,
                    .axis_scaling_exponent = 0.667,
                });
                // `advance` validates and only then writes its own state, so a
                // failure above leaves `WTRTA` at its previous value and this
                // state_update never runs.
                roots.retained_root_carbon_g_c_per_plant[plant] =
                    scaling_state.retained_root_carbon_g_c_per_plant;
                break :blk scaled.primary_root_axis_count_multiplier;
            };
            for (0..traits.biologicalDomainCount()) |domain| {
                const planting_layer = roots.planting_layer_by_plant[plant];
                const deepest_rooted_layer = roots.current_deepest_rooted_layer_by_plant[plant];
                if (planting_layer >= active_soil_layer_count or
                    deepest_rooted_layer < planting_layer or
                    deepest_rooted_layer >= active_soil_layer_count)
                    return error.InvalidRootMetabolismLayerSelector;
                var layer_top_m: f64 = if (planting_layer == 0)
                    0
                else
                    workspace.withdrawal_layer_bottom_m[planting_layer - 1];
                for (planting_layer..deepest_rooted_layer + 1) |layer| {
                    const soil = try context.grid.layerIndex(cell, layer);
                    const layer_bottom_m = layer_top_m + context.soil_solver_properties.layer_thickness_m[soil];
                    const root = try roots.layerIndex(plant, domain, layer);
                    const active_axis_count = roots.active_root_axis_count[plant];
                    const minimum_active_layer_thickness_m = context.runscript.soil_geometry_parameters.minimum_layer_thickness_m;
                    // grosub.f 5746/5981: no root metabolism is evaluated in
                    // a DLYR<=DLYRM intermediate layer. Its thickness still
                    // contributes to the absolute depth coordinate.
                    if (active_axis_count == 0 or
                        context.soil_solver_properties.layer_thickness_m[soil] <= minimum_active_layer_thickness_m)
                    {
                        layer_top_m = layer_bottom_m;
                        continue;
                    }
                    const next_lower_layer: ?usize = if (layer + 1 < active_soil_layer_count)
                        try ecosys.plant_root_metabolism.nextLowerRootLayer(
                            workspace.withdrawal_layer_thickness_m[0..active_soil_layer_count],
                            layer,
                            minimum_active_layer_thickness_m,
                        )
                    else
                        null;
                    try workspace.resetAxes(active_axis_count);
                    var litterfall: ecosys.plant_root_litterfall.LayerInput = .{};
                    var root_carbon_g_c: f64 = 0;
                    var sink_scale_m: f64 = 0;
                    for (0..active_axis_count) |axis| {
                        const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
                        root_carbon_g_c += roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer];
                    }
                    var upper_host_active_root_carbon_g_c: f64 = 0;
                    if (domain == 0 and layer > 0) for (0..active_axis_count) |axis| {
                        const upper_axis_layer = try roots.layerAxisIndex(plant, 0, layer - 1, axis);
                        upper_host_active_root_carbon_g_c +=
                            roots.axis_primary_carbon_g[upper_axis_layer] +
                            roots.axis_secondary_carbon_g[upper_axis_layer];
                    };
                    const mobile_c = roots.mobile_carbon_g[root];
                    const mobile_n = roots.mobile_nitrogen_g[root];
                    const mobile_p = roots.mobile_phosphorus_g[root];
                    const recycling = try ecosys.plant_root_metabolism.secondaryRootRecyclingFractions(
                        context.plant_phenology.*.?.emerged[plant],
                        if (root_carbon_g_c > 0) mobile_c / root_carbon_g_c else 1,
                        if (root_carbon_g_c > 0) mobile_n / root_carbon_g_c else 1,
                        if (root_carbon_g_c > 0) mobile_p / root_carbon_g_c else 1,
                        parameters,
                    );
                    const hydrogen_mol_per_m3 = context.soil_chemistry.aqueous[soil].hydrogen;
                    const soil_ph = if (hydrogen_mol_per_m3 > 0) -@log10(hydrogen_mol_per_m3 / 1.0e3) else 7;
                    const growth_temperature = try ecosys.plant_root_nutrient_uptake.rootGrowthTemperatureResponse(context.grid.soil_temperature_k[soil], canopy.plant_thermal_adaptation_offset_c[plant], context.runscript.canopy_stress_parameters.growth_temperature);
                    const primary_environment = try ecosys.plant_root_metabolism.rootEnvironmentResponses(
                        parameters,
                        context.grid.soil_temperature_k[soil],
                        canopy.plant_thermal_adaptation_offset_c[plant],
                        soil_ph,
                        roots.total_water_potential_megapascal[root],
                        roots.turgor_water_potential_megapascal[root],
                        context.runscript.phenology_parameters.minimum_turgor_potential_megapascal,
                        0,
                        traits.primary_root_radius_m,
                        traits.root_profile_type == 0,
                    );
                    const secondary_environment = try ecosys.plant_root_metabolism.rootEnvironmentResponses(
                        parameters,
                        context.grid.soil_temperature_k[soil],
                        canopy.plant_thermal_adaptation_offset_c[plant],
                        soil_ph,
                        roots.total_water_potential_megapascal[root],
                        roots.turgor_water_potential_megapascal[root],
                        context.runscript.phenology_parameters.minimum_turgor_potential_megapascal,
                        0,
                        traits.secondary_root_radius_m,
                        traits.root_profile_type == 0,
                    );
                    for (0..active_axis_count) |axis| {
                        const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
                        const axis_index = try roots.axisIndex(plant, domain, axis);
                        const primary_depth_m = roots.axis_depth_m[axis_index];
                        workspace.pre_update_primary_depth_m[axis] = primary_depth_m;
                        const tip_in_layer = primary_depth_m > layer_top_m and (primary_depth_m <= layer_bottom_m or layer + 1 == context.grid.active_soil_layer_count[cell]);
                        workspace.primary_active[axis] = domain == 0 and tip_in_layer and !try workspace.primaryWasProcessed(domain, axis);
                        const deepest_axis_layer =
                            roots.deepest_rooted_layer_by_axis[
                                try roots.rootAxisIndex(plant, axis)
                            ];
                        workspace.secondary_active[axis] =
                            ecosys.plant_root_metabolism.secondaryRootAxisActive(
                                layer,
                                deepest_axis_layer,
                                try workspace.secondaryWasProcessed(domain, axis),
                            );
                        workspace.sink_strengths[axis] = try ecosys.plant_root_metabolism.sourceOrderRootAxisSinkStrength(parameters, .{
                            .root_profile_type = traits.root_profile_type,
                            // BIND-GROSUB-506: the source's `XRTN1`, computed
                            // once per plant above. This slot previously read
                            // `roots.axis_primary_count`, which is the source's
                            // per-layer `RTN1` and has no production writer, so
                            // it was identically `1`.
                            .primary_axis_count_multiplier = primary_axis_count_multiplier,
                            .primary_root_radius_m = traits.primary_root_radius_m,
                            .primary_root_depth_from_surface_m = primary_depth_m,
                            .layer_top_depth_m = layer_top_m,
                            .layer_thickness_m = context.soil_solver_properties.layer_thickness_m[soil],
                            .secondary_root_origin_offset_m = 0,
                            .seeding_depth_m = context.plant_water_workspace.*.?.seeding_depth_m[plant],
                            .hypocotyledon_height_m = canopy.plant_hypocotyledon_height_m[plant],
                            .canopy_height_m = context.development_canopy_height_m[plant],
                            .secondary_axis_count = roots.axis_secondary_count[axis_layer],
                            .secondary_root_radius_m = traits.secondary_root_radius_m,
                            .average_secondary_root_length_m = roots.average_secondary_length_m[root],
                            .negligible_sink_m = context.config.physical_tolerance.length(@max(roots.average_secondary_length_m[root], context.soil_solver_properties.layer_thickness_m[soil])),
                            .primary_biological_domain = domain == 0,
                        });
                        sink_scale_m = @max(
                            sink_scale_m,
                            @max(
                                @abs(workspace.sink_strengths[axis].primary_m),
                                @abs(workspace.sink_strengths[axis].secondary_m),
                            ),
                        );
                    }
                    roots.sink_strength_m[root] = try ecosys.plant_root_metabolism.normalizeRootAxisSinkFractions(
                        workspace.sink_strengths[0..active_axis_count],
                        workspace.primary_sink_fractions[0..active_axis_count],
                        workspace.secondary_sink_fractions[0..active_axis_count],
                        context.config.physical_tolerance.length(sink_scale_m),
                    );
                    if (domain == 0) for (0..active_axis_count) |axis| {
                        workspace.withdrawal_sink_fractions[
                            try workspace.withdrawalSinkIndex(layer, axis)
                        ] = std.math.clamp(
                            workspace.primary_sink_fractions[axis] +
                                workspace.secondary_sink_fractions[axis],
                            0,
                            1,
                        );
                    };
                    for (0..active_axis_count) |axis| {
                        const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
                        inline for (.{ true, false }) |primary| {
                            const active = if (primary) workspace.primary_active[axis] else workspace.secondary_active[axis];
                            if (active) {
                                const axis_c = if (primary) roots.axis_primary_carbon_g[axis_layer] else roots.axis_secondary_carbon_g[axis_layer];
                                const axis_n = if (primary) roots.axis_primary_nitrogen_g[axis_layer] else roots.axis_secondary_nitrogen_g[axis_layer];
                                const axis_p = if (primary) roots.axis_primary_phosphorus_g[axis_layer] else roots.axis_secondary_phosphorus_g[axis_layer];
                                const environment = if (primary) primary_environment else secondary_environment;
                                const water_responses = try ecosys.plant_root_metabolism.sourceRootRespirationWaterResponses(
                                    traits.root_profile_type,
                                    traits.leaf_phenology_type,
                                    environment.growth_water,
                                    environment.maintenance_water,
                                );
                                const shared: ecosys.plant_root_metabolism.SecondaryRootInputs = .{
                                    .mobile_carbon_g_c = mobile_c,
                                    .nonstructural_nitrogen_g_n = mobile_n,
                                    .nonstructural_phosphorus_g_p = mobile_p,
                                    .root_carbon_g_c = root_carbon_g_c,
                                    .root_nitrogen_g_n = axis_n,
                                    .root_nitrogen_to_carbon_ratio_g_n_per_g_c = wood.growth_nitrogen_to_carbon_g_n_per_g_c,
                                    .root_phosphorus_to_carbon_ratio_g_p_per_g_c = wood.growth_phosphorus_to_carbon_g_p_per_g_c,
                                    .root_growth_yield_g_c_per_g_c = traits.root_growth_yield_g_c_per_g_c,
                                    .active_root_fraction = if (primary) workspace.primary_sink_fractions[axis] else workspace.secondary_sink_fractions[axis],
                                    .biological_timestep_h = 1,
                                    .substrate_temperature_response = if (root_respiration_active) growth_temperature else 0,
                                    .maintenance_temperature_response = if (root_respiration_active) environment.maintenance_temperature else 0,
                                    .acidity_response = environment.acidity,
                                    .substrate_feedback = termination_feedback,
                                    .oxygen_limitation = std.math.clamp(roots.oxygen_process_constraint_fraction[root], 0, 1),
                                    .substrate_water_response = water_responses.substrate,
                                    .maintenance_water_response = water_responses.maintenance,
                                };
                                const metabolism = if (primary)
                                    try ecosys.plant_root_metabolism.primaryRootMetabolism(parameters, .{ .shared = shared, .primary_tip_at_or_below_profile_bottom = layer + 1 == context.grid.active_soil_layer_count[cell] })
                                else
                                    try ecosys.plant_root_metabolism.secondaryRootMetabolism(parameters, shared);
                                const senescence_inputs: ecosys.plant_root_metabolism.SecondaryRootSenescenceInputs = .{
                                    .oxygen_unlimited_substrate_minus_maintenance_g_c_per_h = metabolism.substrate_respiration_oxygen_unlimited_g_c_per_h - metabolism.maintenance_respiration_g_c_per_h,
                                    .actual_substrate_minus_maintenance_g_c_per_h = metabolism.substrate_respiration_actual_g_c_per_h - metabolism.maintenance_respiration_g_c_per_h,
                                    .root_carbon_g_c = axis_c,
                                    .root_nitrogen_g_n = axis_n,
                                    .root_phosphorus_g_p = axis_p,
                                    .oxygen_limitation = shared.oxygen_limitation,
                                    .phenological_remobilization_enabled = context.plant_dormancy.*.?.branches[retained_root_remobilization_branch].phenological_remobilization_enabled,
                                    .root_remobilization_enabled = context.plant_dormancy.*.?.branches[retained_root_remobilization_branch].shoot_remobilization_enabled,
                                    .storage_exchange_fraction_per_h = parameters.storage_exchange_fraction_per_h,
                                    .remobilization_elapsed_h = context.plant_dormancy.*.?.branches[retained_root_remobilization_branch].remobilization_elapsed_h,
                                    .full_senescence_h = parameters.full_senescence_duration_h,
                                    .biological_timestep_h = 1,
                                    .structural_presence_threshold_g_c = context.runscript.plant_pool_parameters.plant_root_structural_presence_g_per_plant,
                                };
                                const senescence = if (primary)
                                    try ecosys.plant_root_metabolism.primaryRootSenescence(senescence_inputs, recycling)
                                else
                                    try ecosys.plant_root_metabolism.secondaryRootSenescence(senescence_inputs, recycling);
                                try litterfall.add(try ecosys.plant_root_metabolism.secondaryRootLitter(
                                    senescence,
                                    axis_c,
                                    axis_n,
                                    axis_p,
                                    wood.carbon_fraction,
                                    wood.nitrogen_fraction,
                                    wood.phosphorus_fraction,
                                    litter_kinetics,
                                ));
                                if (primary) {
                                    workspace.primary_metabolism[axis] = metabolism;
                                    workspace.primary_senescence[axis] = senescence;
                                } else {
                                    workspace.secondary_metabolism[axis] = metabolism;
                                    workspace.secondary_senescence[axis] = senescence;
                                }
                            }
                        }
                    }
                    try ecosys.plant_root_litterfall.validateStateUpdate(context.soil_organic, soil, litterfall);
                    try ecosys.plant_root_metabolism.state_updateStagedLayerAxes(roots, plant, domain, layer, workspace, active_axis_count, .{
                        .primary_specific_length_m_per_g_c = traits.primary_specific_length_m_per_g_c,
                        .secondary_specific_length_m_per_g_c = traits.secondary_specific_length_m_per_g_c,
                        .plant_population_count = context.plant_water_workspace.*.?.plant_population_count[plant],
                        .seeding_depth_m = context.plant_water_workspace.*.?.seeding_depth_m[plant],
                        .current_layer_bottom_depth_m = layer_bottom_m,
                        .next_lower_layer = next_lower_layer,
                        .next_layer_thickness_m = if (next_lower_layer) |next_layer|
                            context.soil_solver_properties.layer_thickness_m[try context.grid.layerIndex(cell, next_layer)]
                        else
                            0,
                        .extension_presence_threshold_m = context.runscript.plant_pool_parameters.plant_root_structural_presence_g_per_plant *
                            context.plant_water_workspace.*.?.plant_population_count[plant],
                        .root_extension_water_response = @min(primary_environment.extension_water, secondary_environment.extension_water),
                        .nonwoody_carbon_fraction = wood.carbon_fraction[1],
                        .nonwoody_nitrogen_fraction = wood.nitrogen_fraction[1],
                        .nonwoody_phosphorus_fraction = wood.phosphorus_fraction[1],
                        .protein_carbon_per_nitrogen_g_c_per_g_n = parameters.root_protein_carbon_per_nitrogen_g_c_per_g_n,
                        .protein_carbon_per_phosphorus_g_c_per_g_p = parameters.root_protein_carbon_per_phosphorus_g_c_per_g_p,
                        .primary_axis_count_multiplier = primary_axis_count_multiplier,
                        .secondary_root_branching_per_m = traits.secondary_root_branching_per_m,
                        .current_layer_thickness_m = context.soil_solver_properties.layer_thickness_m[soil],
                    });
                    const domain_litterfall = litterfall.litter;
                    var current_mycorrhizal_litterfall = std.mem.zeroes(ecosys.plant_root_metabolism.RootLitter);
                    var upper_mycorrhizal_litterfall: ecosys.plant_root_litterfall.LayerInput = .{};
                    if (domain == 0) {
                        const concurrent_loss = try ecosys.plant_root_metabolism.state_updateMycorrhizalLossWithSecondaryRoots(
                            roots,
                            plant,
                            layer,
                            workspace.*,
                            active_axis_count,
                            // GROSUB FSNCP uses WTRTL(1): total active host
                            // primary plus secondary root C, not WTRT2 alone.
                            .{ root_carbon_g_c, upper_host_active_root_carbon_g_c },
                            context.runscript.plant_pool_parameters.plant_root_structural_presence_g_per_plant,
                            .{ wood.carbon_fraction, wood.nitrogen_fraction, wood.phosphorus_fraction },
                            litter_kinetics,
                        );
                        current_mycorrhizal_litterfall = concurrent_loss.current;
                        try litterfall.add(concurrent_loss.current);
                        try upper_mycorrhizal_litterfall.add(concurrent_loss.upper);
                        try ecosys.plant_root_litterfall.validateStateUpdate(context.soil_organic, soil, litterfall);
                        if (layer > 0)
                            try ecosys.plant_root_litterfall.validateStateUpdate(context.soil_organic, try context.grid.layerIndex(cell, layer - 1), upper_mycorrhizal_litterfall);
                    }
                    var plant_litterfall: ecosys.plant_root_litterfall.LayerInput = .{ .litter = context.root_litter_products_by_plant[plant] };
                    try plant_litterfall.add(litterfall.litter);
                    try plant_litterfall.add(upper_mycorrhizal_litterfall.litter);
                    for (0..active_axis_count) |axis| if (workspace.primary_active[axis]) try workspace.markPrimaryProcessed(domain, axis);
                    for (0..active_axis_count) |axis| {
                        if (!workspace.secondary_active[axis]) continue;
                        const deepest_axis_layer =
                            roots.deepest_rooted_layer_by_axis[
                                try roots.rootAxisIndex(plant, axis)
                            ];
                        if (layer == deepest_axis_layer)
                            try workspace.markSecondaryProcessed(domain, axis);
                    }
                    ecosys.plant_root_litterfall.publishValidated(context.soil_organic, soil, litterfall);
                    if (domain == 0 and layer > 0)
                        ecosys.plant_root_litterfall.publishValidated(context.soil_organic, try context.grid.layerIndex(cell, layer - 1), upper_mycorrhizal_litterfall);
                    context.root_litter_carbon_ledger.addValidated(plant, domain, layer, domain_litterfall);
                    if (domain == 0) {
                        // Concurrent loss is mycorrhizal (legacy N=2), even
                        // though its host trigger is evaluated in domain zero.
                        context.root_litter_carbon_ledger.addValidated(plant, 1, layer, current_mycorrhizal_litterfall);
                        if (layer > 0)
                            context.root_litter_carbon_ledger.addValidated(plant, 1, layer - 1, upper_mycorrhizal_litterfall.litter);
                    }
                    context.root_litter_products_by_plant[plant] = plant_litterfall.litter;
                    if (domain == 0 and layer > roots.planting_layer_by_plant[plant]) {
                        for (0..active_axis_count) |axis| {
                            const root_axis = try roots.rootAxisIndex(plant, axis);
                            const withdrawn_count =
                                try ecosys.plant_root_disturbance.selectSourceOrderWithdrawnLayers(
                                    layer,
                                    roots.deepest_rooted_layer_by_axis[root_axis],
                                    roots.planting_layer_by_plant[plant],
                                    workspace.pre_update_primary_depth_m[axis],
                                    context.plant_water_workspace.*.?.seeding_depth_m[plant],
                                    context.runscript.soil_geometry_parameters.minimum_layer_thickness_m,
                                    workspace.withdrawal_layer_thickness_m[0..active_soil_layer_count],
                                    workspace.withdrawal_layer_bottom_m[0..active_soil_layer_count],
                                    workspace.withdrawn_layers[0..active_soil_layer_count],
                                );
                            for (workspace.withdrawn_layers[0..withdrawn_count], 0..) |source_layer, withdrawn_index|
                                workspace.withdrawn_fractions[withdrawn_index] =
                                    workspace.withdrawal_sink_fractions[
                                        try workspace.withdrawalSinkIndex(source_layer, axis)
                                    ];
                            try ecosys.plant_root_disturbance.withdrawRootAxisLayersSourceOrder(
                                roots,
                                plant,
                                axis,
                                traits.biologicalDomainCount(),
                                workspace.withdrawn_layers[0..withdrawn_count],
                                workspace.withdrawn_fractions[0..withdrawn_count],
                                context.plant_water_workspace.*.?.seeding_depth_m[plant],
                                workspace.withdrawal_layer_thickness_m[0..active_soil_layer_count],
                                workspace.withdrawal_layer_bottom_m[0..active_soil_layer_count],
                            );
                        }
                    }
                    const shoot_traits = context.shoot_growth_plant_parameters[plant];
                    if (domain == 0 and
                        shoot_traits.nitrogen_fixation_type >= 1 and
                        shoot_traits.nitrogen_fixation_type <= 3)
                    {
                        var host_structural_carbon_g_c: f64 = 0;
                        for (0..roots.active_root_axis_count[plant]) |axis| {
                            const axis_layer = try roots.layerAxisIndex(plant, 0, layer, axis);
                            host_structural_carbon_g_c += roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer];
                        }
                        const host_presence_threshold_g_c =
                            context.runscript.plant_pool_parameters.plant_root_structural_presence_g_per_plant *
                            canopy.plant_population_count[plant];
                        if (host_structural_carbon_g_c > host_presence_threshold_g_c) {
                            const fine_root_litter = try context.plant_litter_partition.*.?.get(plant, .fine_root);
                            const physiological_maturity_reached = branch_development.stage_day[main_branch * 10 + 9] != 0;
                            const symbiosis = try ecosys.plant_root_symbiotic_fixation.calculate(.{
                                .fixation_type = shoot_traits.nitrogen_fixation_type,
                                .first_subhour = true,
                                .fire_active_this_hour = context.fire_active_this_hour[cell],
                                .structural = .{
                                    .carbon_g_c = roots.symbiont_structural_carbon_g_c[root],
                                    .nitrogen_g_n = roots.symbiont_structural_nitrogen_g_n[root],
                                    .phosphorus_g_p = roots.symbiont_structural_phosphorus_g_p[root],
                                },
                                .mobile = .{
                                    .carbon_g_c = roots.symbiont_mobile_carbon_g_c[root],
                                    .nitrogen_g_n = roots.symbiont_mobile_nitrogen_g_n[root],
                                    .phosphorus_g_p = roots.symbiont_mobile_phosphorus_g_p[root],
                                },
                                .host_mobile = .{
                                    .carbon_g_c = roots.mobile_carbon_g[root],
                                    .nitrogen_g_n = roots.mobile_nitrogen_g[root],
                                    .phosphorus_g_p = roots.mobile_phosphorus_g[root],
                                },
                                .host_structural_carbon_g_c = host_structural_carbon_g_c,
                                .host_presence_threshold_g_c = host_presence_threshold_g_c,
                                .cell_area_m2 = context.canopy_cell_area_m2[cell],
                                .temperature_response = try ecosys.plant_root_nutrient_uptake.rootGrowthTemperatureResponse(context.grid.soil_temperature_k[soil], canopy.plant_thermal_adaptation_offset_c[plant], context.runscript.canopy_stress_parameters.growth_temperature),
                                .growth_water_response = primary_environment.growth_water,
                                .maintenance_temperature_response = primary_environment.maintenance_temperature * primary_environment.acidity,
                                .maintenance_water_response = primary_environment.maintenance_water,
                                .oxygen_constraint_fraction = roots.oxygen_process_constraint_fraction[root],
                                .host_exchange_enabled = roots.mobile_carbon_g[root] >
                                    context.runscript.plant_pool_parameters.branch_structural_presence_g_per_plant *
                                        canopy.plant_population_count[plant] and
                                    (shoot_traits.growth_habit != 0 or !physiological_maturity_reached),
                                .timestep_h = 1,
                            }, context.runscript.symbiotic_fixation_parameters, shoot_traits.symbiont_nitrogen_to_carbon_g_n_per_g_c, shoot_traits.symbiont_phosphorus_to_carbon_g_p_per_g_c, shoot_traits.symbiont_growth_yield_g_c_per_g_c, fine_root_litter);
                            var symbiotic_litterfall: ecosys.plant_root_litterfall.LayerInput = .{};
                            try symbiotic_litterfall.add(symbiosis.litterfall);
                            try ecosys.plant_root_litterfall.validateStateUpdate(context.soil_organic, soil, symbiotic_litterfall);
                            plant_litterfall = .{ .litter = context.root_litter_products_by_plant[plant] };
                            try plant_litterfall.add(symbiotic_litterfall.litter);
                            inline for (.{
                                roots.actual_respiration_g_c_per_h[root] + symbiosis.respiration_actual_g_c,
                                roots.respiration_unlimited_by_oxygen_g_c_per_h[root] + symbiosis.respiration_oxygen_unlimited_g_c,
                                roots.fixation_uptake_g_n_per_h[plant] + symbiosis.fixed_nitrogen_g_n,
                                roots.fixation_uptake_g_n_per_h_by_layer[root] + symbiosis.fixed_nitrogen_g_n,
                            }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteRootSymbioticStateUpdate;
                            try ecosys.plant_symbiotic_fixation.accumulateExternalInput(
                                &context.symbiotic_inoculum_input_by_cell[cell],
                                symbiosis.external_inoculum_input,
                            );
                            roots.symbiont_structural_carbon_g_c[root] = symbiosis.structural.carbon_g_c;
                            roots.symbiont_structural_nitrogen_g_n[root] = symbiosis.structural.nitrogen_g_n;
                            roots.symbiont_structural_phosphorus_g_p[root] = symbiosis.structural.phosphorus_g_p;
                            roots.symbiont_mobile_carbon_g_c[root] = symbiosis.mobile.carbon_g_c;
                            roots.symbiont_mobile_nitrogen_g_n[root] = symbiosis.mobile.nitrogen_g_n;
                            roots.symbiont_mobile_phosphorus_g_p[root] = symbiosis.mobile.phosphorus_g_p;
                            roots.mobile_carbon_g[root] = symbiosis.host_mobile.carbon_g_c;
                            roots.mobile_nitrogen_g[root] = symbiosis.host_mobile.nitrogen_g_n;
                            roots.mobile_phosphorus_g[root] = symbiosis.host_mobile.phosphorus_g_p;
                            roots.symbiotic_respiration_actual_g_c_per_h[root] += symbiosis.respiration_actual_g_c;
                            roots.symbiotic_respiration_oxygen_unlimited_g_c_per_h[root] += symbiosis.respiration_oxygen_unlimited_g_c;
                            roots.actual_respiration_g_c_per_h[root] += symbiosis.respiration_actual_g_c;
                            roots.respiration_unlimited_by_oxygen_g_c_per_h[root] += symbiosis.respiration_oxygen_unlimited_g_c;
                            roots.fixation_uptake_g_n_per_h[plant] += symbiosis.fixed_nitrogen_g_n;
                            roots.fixation_uptake_g_n_per_h_by_layer[root] += symbiosis.fixed_nitrogen_g_n;
                            ecosys.plant_root_litterfall.publishValidated(context.soil_organic, soil, symbiotic_litterfall);
                            // GROSUB 9947: nodules are always root-type/domain
                            // zero (Fortran `WTRTD(1,...)`), outside the
                            // mycorrhizal `DO N=1,MY` loop, matching the state
                            // owner read above (`roots.layerIndex(plant, 0,
                            // layer)`). Publishing to domain one silently
                            // dropped this litter from `carbonByPlantLayer`'s
                            // `0..active_domain_count` sum for any
                            // non-mycorrhizal N-fixing plant (GROSUB-072's
                            // harvest-path analog).
                            context.root_litter_carbon_ledger.addValidated(plant, 0, layer, symbiotic_litterfall.litter);
                            context.root_litter_products_by_plant[plant] = plant_litterfall.litter;
                        }
                    }
                    layer_top_m = layer_bottom_m;
                }
            }
            try roots.rebuildNextDeepestRootedLayerFromAxes(plant);
            const root_reserve_presence_threshold_g_c =
                context.runscript.plant_pool_parameters.plant_root_structural_presence_g_per_plant *
                context.plant_water_workspace.*.?.plant_population_count[plant];
            // GROSUB 7365--7399 remains here after the root metabolism sweep.
            // Earlier 4902--5109 NB transactions are source-ordered in
            // plant_daily before this stage.
            if (traits.growth_habit != 0) {
                const domain_count = context.root_metabolism_plant_parameters[plant].biologicalDomainCount();
                const active_layer_count = context.grid.active_soil_layer_count[cell];
                const presence_threshold_g_c = root_reserve_presence_threshold_g_c;

                // First pass proves that the complete source-ordered sequence
                // is admissible. The second pass state_updates the same deterministic
                // sequence, so a late failure cannot leave partial transfers.
                var validated_storage_g_c = canopy.plant_seed_storage_carbon_g[plant];
                for (0..domain_count) |domain| for (0..active_layer_count) |layer| {
                    var layer_active_root_carbon_g_c: f64 = 0;
                    for (0..roots.active_root_axis_count[plant]) |axis| {
                        const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
                        layer_active_root_carbon_g_c += roots.axis_primary_carbon_g[axis_layer] +
                            roots.axis_secondary_carbon_g[axis_layer];
                    }
                    const root = try roots.layerIndex(plant, domain, layer);
                    const result = try ecosys.plant_storage_remobilization.replenishDepletedSeasonalStorage(.{
                        .growth_habit = .perennial,
                        .layer_is_rooted = true,
                        .layer_active_root_carbon_g_c = layer_active_root_carbon_g_c,
                        // Source WTRT is the carried whole-root total, including
                        // mobile C, not a post-metabolism structural-only sum.
                        .plant_total_root_carbon_g_c = total_root_carbon_g_c,
                        .layer_mobile_carbon_g_c = roots.mobile_carbon_g[root],
                        .seasonal_storage_carbon_g_c = validated_storage_g_c,
                        .storage_deficit_threshold_g_c_per_g_root_c = context.runscript.storage_remobilization_parameters.depleted_storage_threshold_g_c_per_g_root_c,
                        .exchange_fraction_per_h = parameters.storage_exchange_fraction_per_h,
                        .biological_timestep_h = 1,
                        .presence_threshold_g_c = presence_threshold_g_c,
                    });
                    validated_storage_g_c = result.next_seasonal_storage_carbon_g_c;
                };
                for (0..domain_count) |domain| for (0..active_layer_count) |layer| {
                    var layer_active_root_carbon_g_c: f64 = 0;
                    for (0..roots.active_root_axis_count[plant]) |axis| {
                        const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
                        layer_active_root_carbon_g_c += roots.axis_primary_carbon_g[axis_layer] +
                            roots.axis_secondary_carbon_g[axis_layer];
                    }
                    const root = try roots.layerIndex(plant, domain, layer);
                    const result = try ecosys.plant_storage_remobilization.replenishDepletedSeasonalStorage(.{
                        .growth_habit = .perennial,
                        .layer_is_rooted = true,
                        .layer_active_root_carbon_g_c = layer_active_root_carbon_g_c,
                        .plant_total_root_carbon_g_c = total_root_carbon_g_c,
                        .layer_mobile_carbon_g_c = roots.mobile_carbon_g[root],
                        .seasonal_storage_carbon_g_c = canopy.plant_seed_storage_carbon_g[plant],
                        .storage_deficit_threshold_g_c_per_g_root_c = context.runscript.storage_remobilization_parameters.depleted_storage_threshold_g_c_per_g_root_c,
                        .exchange_fraction_per_h = parameters.storage_exchange_fraction_per_h,
                        .biological_timestep_h = 1,
                        .presence_threshold_g_c = presence_threshold_g_c,
                    });
                    try internal_activity.recordRootToCanopy(cell, layer, .{
                        .carbon_g_c = result.root_to_storage_carbon_g_c,
                    });
                    roots.mobile_carbon_g[root] = result.next_layer_mobile_carbon_g_c;
                    canopy.plant_seed_storage_carbon_g[plant] = result.next_seasonal_storage_carbon_g_c;
                };
            }
        }
    }
    // grosub.f:5710 (`NIX=NG` reset) / hfunc.f:140 (`NI(NZ,NY,NX)=NIX(NZ,NY,NX)`):
    // publish this hour's accumulated rooted-layer boundary once, after every
    // plant's axis growth has committed, so the next hour's UPTAKE-stage
    // callers (root nutrient admission, root oxygen competition) see the
    // deepened root front instead of a boundary pinned at planting.
    try roots.advanceRootedLayerBoundary(0, roots.plant_count);
}
