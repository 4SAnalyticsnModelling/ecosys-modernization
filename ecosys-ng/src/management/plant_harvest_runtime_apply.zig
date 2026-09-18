//! `plant_harvest_runtime` declarations: apply.
//!
//! Split out of `plant_harvest_runtime.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const management = @import("plant_management.zig");
const canopy = @import("../canopy/photosynthesis/photosynthesis.zig");
const phenology = @import("../plant/lifecycle/phenology.zig");
const growth_stages = @import("../plant/lifecycle/growth_stages.zig");
const root_system = @import("../plant/root/plant_root_system.zig");
const root_disturbance = @import("../plant/root/plant_root_disturbance.zig");
const symbiotic_fixation = @import("../canopy/symbiosis/plant_symbiotic_fixation.zig");
const root_litterfall = @import("../plant/root/plant_root_litterfall.zig");
const root_litter_ledger = @import("../plant/root/plant_root_litter_budget.zig");
const litter_partition = @import("../plant/partition/litter.zig");
const soil_organic = @import("../soil/organic/initialization.zig");
const grid_module = @import("../state/grid.zig");
const carbon_exchange = @import("../canopy/photosynthesis/carbon_exchange.zig");
const shoot_litter_bridge = @import("../plant/growth/shoot_litter_bridge.zig");
const canopy_structure = @import("../canopy/morphology/structure.zig");
const canopy_layers = @import("../canopy/radiation/layer_distribution.zig");
const canopy_biochemistry = @import("../canopy/photosynthesis/biochemistry.zig");
const dormancy = @import("../plant/lifecycle/dormancy.zig");
const grazing_manure = @import("grazing_manure.zig");
const surface_nutrients = @import("../soil/biogeochemistry/organic_matter_fire_exchange.zig");
const spring_reproductive_litterfall = @import("../plant/growth/spring_reproductive_litterfall.zig");
const storage_remobilization = @import("../plant/growth/storage_remobilization.zig");
const pool_aggregation = @import("../plant/accounting/pool_aggregation.zig");
const group_harvest = @import("plant_harvest_runtime_harvest.zig");
const group_misc = @import("plant_harvest_runtime_misc.zig");
const group_mortality = @import("plant_harvest_runtime_mortality.zig");
const group_types = @import("plant_harvest_runtime_types.zig");
const group_validation = @import("plant_harvest_runtime_validation.zig");

/// Rebuild the cell aggregate from its authoritative per-plant owners after a
/// management change.  Subtract-and-zero publication can hide a stale local
/// aggregate and manufacture or delete area at the exact point where water and
/// radiation coupling consume it.
fn standingDeadAreaForCellLayer(
    layers: *const canopy_layers.State,
    cell: usize,
    species_count: usize,
    layer: usize,
) !f64 {
    if (species_count == 0 or species_count != layers.species_count or cell >= layers.cell_count or layer >= layers.layer_count) return error.InvalidStandingDeadAreaTopology;
    const first_plant = try std.math.mul(usize, cell, species_count);
    const end_plant = try std.math.add(usize, first_plant, species_count);
    if (end_plant > layers.cell_count * layers.species_count) return error.InvalidStandingDeadAreaTopology;
    var total_m2: f64 = 0;
    for (first_plant..end_plant) |plant_index| {
        const value = layers.plant_standing_dead_area_m2[plant_index * layers.layer_count + layer];
        if (!std.math.isFinite(value) or value < 0) return error.InvalidStandingDeadAreaState;
        total_m2 += value;
        if (!std.math.isFinite(total_m2)) return error.InvalidStandingDeadAreaState;
    }
    return total_m2;
}

pub fn applyForestSelfThinning(context: *group_misc.Context, plant: usize) !f64 {
    if (plant >= context.canopy_state.plant_population_per_m2.len or plant >= context.canopy_state.plant_stem_diameter_m.len)
        return error.PlantHarvestIndexOutOfBounds;
    const fraction = try group_mortality.forestSelfThinningFraction(
        context.canopy_state.plant_stem_diameter_m[plant],
        context.canopy_state.plant_population_per_m2[plant],
    );
    if (fraction == 0) return 0;
    try applyEvent(context, plant, .{
        .date = .{ .day = 1, .month = 1, .year = 9999 },
        .kind = .none,
        .termination = .retain,
        .cutting_height_m_or_lai_fraction = 1000,
        .thinning_fraction_or_consumption_rate = fraction,
        .harvested_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 0 },
        .ecosystem_export_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0 },
    });
    return fraction;
}

/// Management-dispatch callback for deterministic cutting, thinning, pruning,
/// and grain harvest. Grazing is rejected here and routed to its demand-driven
/// hourly kernel instead of being approximated as a fractional cut.
pub fn applyEvent(context: *group_misc.Context, plant: usize, source_event: management.HarvestEvent) !void {
    return applyEventInternal(context, plant, source_event, true, true);
}

const PreparedPostHarvest = struct {
    allocation: []f64,
    current_node_count_by_branch: []f64,
    branch_leaf_sheath_carbon_g_c: []f64,
    main_branch: usize,
    canopy_height_m: f64,
};

fn postCutRequest(
    context: *const group_misc.Context,
    prepared: PreparedPostHarvest,
    plant: usize,
    selected_branch: usize,
    cutting_height_m: f64,
) phenology.PostCutResetRequest {
    const binding = context.post_harvest.?;
    const dormancy_parameters = binding.dormancy_parameters_by_plant[plant];
    const winter_phenology_type = binding.winter_phenology_type_by_plant[plant];
    return .{
        .selected_branch = selected_branch,
        .main_branch = prepared.main_branch,
        .plant_branch_first = context.canopy_state.plant_branch_offsets[plant],
        .plant_branch_end = context.canopy_state.plant_branch_offsets[plant + 1],
        .biomass_turnover_type = binding.biomass_turnover_type_by_plant[plant],
        .root_profile_type = binding.root_profile_type_by_plant[plant],
        .grazing = false,
        .canopy_height_m = prepared.canopy_height_m,
        .cutting_height_m = cutting_height_m,
        .winter_phenology_type = winter_phenology_type,
        // GROSUB VRNF/VRNX are the live branch leafoff counter and its
        // plant requirement. FVRN is the same runtime remobilization-start
        // fraction used by dormancy (DATA 0.75 for evergreen, 0.5 otherwise).
        .accumulated_vernalization_h = binding.dormancy_state.branches[selected_branch].accumulated_leafoff_h,
        .required_vernalization_h = dormancy_parameters.required_leafoff_h,
        .vernalization_reset_fraction = if (winter_phenology_type == 0)
            dormancy_parameters.evergreen_leafoff_remobilization_start_fraction
        else
            dormancy_parameters.deciduous_leafoff_remobilization_start_fraction,
        .initial_maturity_group = binding.initial_maturity_group_by_plant[plant],
        // GROSUB PSTG is the initiated-node count. It is not the normalized
        // reproductive-stage accumulator.
        .current_reproductive_stage_by_branch = prepared.current_node_count_by_branch,
        .current_day = context.current_day_of_year,
    };
}

fn preparePostHarvest(
    context: *group_misc.Context,
    plant: usize,
    cutting_height_m: f64,
) !?PreparedPostHarvest {
    const binding = context.post_harvest orelse return null;
    const state = context.canopy_state;
    const growth = context.growth_stages orelse return error.IncompletePostHarvestContext;
    const layers = context.canopy_layer_state orelse return error.IncompletePostHarvestContext;
    const plant_count = state.plant_branch_offsets.len - 1;
    if (plant >= plant_count or growth.plant_count != plant_count or
        binding.dormancy_parameters_by_plant.len != plant_count or
        binding.biomass_turnover_type_by_plant.len != plant_count or
        binding.root_profile_type_by_plant.len != plant_count or
        binding.winter_phenology_type_by_plant.len != plant_count or
        binding.initial_maturity_group_by_plant.len != plant_count or
        binding.dormancy_state.branches.len != growth.branches.len or
        context.branch_development.branch_count != growth.branches.len or
        state.branch_node_offsets.len - 1 != growth.branches.len or
        layers.branch_count != growth.branches.len or
        context.current_day_of_year == 0 or context.current_day_of_year > 366)
    {
        if (!builtin.is_test) std.log.err("post-harvest context mismatch: plant={d} plants={d} growth_plants={d} parameter_lengths={d}/{d}/{d}/{d}/{d} branch_lengths={d}/{d}/{d}/{d}/{d} day={d}", .{
            plant,                                      plant_count,                                 growth.plant_count,
            binding.dormancy_parameters_by_plant.len,   binding.biomass_turnover_type_by_plant.len,  binding.root_profile_type_by_plant.len,
            binding.winter_phenology_type_by_plant.len, binding.initial_maturity_group_by_plant.len, binding.dormancy_state.branches.len,
            growth.branches.len,                        context.branch_development.branch_count,     state.branch_node_offsets.len - 1,
            layers.branch_count,                        context.current_day_of_year,
        });
        return error.PostHarvestDimensionMismatch;
    }
    const branches = try state.branchRange(plant);
    const growth_branches = try growth.branchRange(plant);
    if (branches.first != growth_branches.first or branches.end != growth_branches.end or
        branches.first == branches.end or plant >= layers.canopy_height_m_by_plant.len)
    {
        if (!builtin.is_test) std.log.err("post-harvest plant topology mismatch: plant={d} canopy_branches={d}..{d} growth_branches={d}..{d} height_count={d} day={d}", .{
            plant,                               branches.first,              branches.end, growth_branches.first, growth_branches.end,
            layers.canopy_height_m_by_plant.len, context.current_day_of_year,
        });
        return error.PostHarvestDimensionMismatch;
    }
    const main_branch = (try growth.mainStalkBranch(plant)) orelse return error.PostHarvestMissingMainBranch;
    const binding_parameters = binding.dormancy_parameters_by_plant[plant];
    try binding_parameters.validate();
    if (binding.winter_phenology_type_by_plant[plant] > 5 or
        !std.math.isFinite(binding.initial_maturity_group_by_plant[plant]) or
        binding.initial_maturity_group_by_plant[plant] < 0 or
        !std.math.isFinite(layers.canopy_height_m_by_plant[plant]) or
        layers.canopy_height_m_by_plant[plant] < 0 or
        !std.math.isFinite(cutting_height_m) or cutting_height_m < 0)
        return error.InvalidPostHarvestBinding;
    const local_branch_count = branches.end - branches.first;
    const allocation_count = try std.math.add(usize, growth.branches.len, local_branch_count);
    const allocation = try state.allocator.alloc(f64, allocation_count);
    errdefer state.allocator.free(allocation);
    const current_node_count = allocation[0..growth.branches.len];
    const leaf_sheath = allocation[growth.branches.len..];
    for (growth.branches, current_node_count) |branch, *value| {
        if (!std.math.isFinite(branch.initiated_node_count) or branch.initiated_node_count < 0)
            return error.InvalidPostHarvestBinding;
        value.* = branch.initiated_node_count;
    }
    const prepared: PreparedPostHarvest = .{
        .allocation = allocation,
        .current_node_count_by_branch = current_node_count,
        .branch_leaf_sheath_carbon_g_c = leaf_sheath,
        .main_branch = main_branch,
        .canopy_height_m = layers.canopy_height_m_by_plant[plant],
    };
    // Validate every late reset request before the first harvest mutation.
    // After this point resetDevelopmentAfterCut has no remaining failure mode
    // unless an owner is corrupted concurrently, which tile ownership forbids.
    for (branches.first..branches.end) |branch|
        try phenology.validatePostCutResetRequest(
            context.branch_development,
            postCutRequest(context, prepared, plant, branch, cutting_height_m),
        );
    return prepared;
}

fn synchronizeGrowthStagesAfterCut(
    growth: *growth_stages.State,
    first: usize,
    end: usize,
    day_of_year: u16,
) void {
    for (growth.branches[first..end]) |*branch| {
        // PSTG itself remains the current initiated-node count. The reset
        // moves that value into PSTGI and clears the later stage baselines and
        // accumulators, so the next HFUNC advance consumes the new origin.
        branch.nodes_at_floral_initiation = branch.initiated_node_count;
        branch.nodes_at_anthesis = 0;
        branch.maximum_active_leaf_node = 0;
        branch.vegetative_stage_normalized = 0;
        branch.reproductive_stage_normalized = 0;
        branch.vegetative_stage_increment = 0;
        branch.reproductive_stage_increment = 0;
        branch.accumulated_vegetative_stage = 0;
        branch.accumulated_reproductive_stage = 0;
        branch.emergence_day = day_of_year;
        branch.floral_initiation_day = 0;
        branch.stem_elongation_start_day = 0;
        branch.stem_elongation_midpoint_day = 0;
        branch.stem_elongation_end_day = 0;
        branch.anthesis_day = 0;
        branch.grain_fill_start_day = 0;
        branch.seed_number_set_end_day = 0;
        branch.seed_size_set_end_day = 0;
    }
}

fn applyPostCutReset(
    context: *group_misc.Context,
    prepared: PreparedPostHarvest,
    plant: usize,
    selected_branch: usize,
    cutting_height_m: f64,
) !void {
    if (!try phenology.resetDevelopmentAfterCut(
        context.branch_development,
        postCutRequest(context, prepared, plant, selected_branch, cutting_height_m),
    )) return;
    const branches = try context.canopy_state.branchRange(plant);
    const first = if (selected_branch == prepared.main_branch) branches.first else selected_branch;
    const end = if (selected_branch == prepared.main_branch) branches.end else selected_branch + 1;
    synchronizeGrowthStagesAfterCut(context.growth_stages.?, first, end, context.current_day_of_year);
}

fn publishPostHarvestPlantTotals(
    context: *group_misc.Context,
    prepared: *PreparedPostHarvest,
    plant: usize,
) !void {
    const state = context.canopy_state;
    const layers = context.canopy_layer_state.?;
    const branches = try state.branchRange(plant);
    for (branches.first..branches.end, 0..) |branch, local| {
        const leaf_sheath = state.branch_leaf_carbon_g[branch] + state.branch_sheath_carbon_g[branch];
        if (!std.math.isFinite(leaf_sheath) or leaf_sheath < 0)
            return error.InvalidPostHarvestPlantTotalInput;
        prepared.branch_leaf_sheath_carbon_g_c[local] = leaf_sheath;
    }
    const totals = try pool_aggregation.sourceOrderPostHarvestPlantTotals(
        prepared.branch_leaf_sheath_carbon_g_c,
        state.branch_stalk_carbon_g[branches.first..branches.end],
        state.branch_sapwood_carbon_g[branches.first..branches.end],
        layers.branch_stalk_area_m2[branches.first * layers.layer_count .. branches.end * layers.layer_count],
        layers.layer_count,
    );
    state.plant_leaf_sheath_carbon_g[plant] = totals.leaf_sheath_carbon_g_c;
    state.plant_stalk_carbon_g[plant] = totals.stalk_carbon_g_c;
    state.plant_sapwood_carbon_g[plant] = totals.sapwood_carbon_g_c;
    state.plant_stalk_surface_area_m2[plant] = totals.stalk_surface_area_m2;

    // Keep the existing whole-shoot downstream owner coherent with the same
    // remaining branch pools. This prevents the next hourly aggregation from
    // reporting harvest removal as biological shoot growth.
    var total_shoot_carbon_g_c: f64 = 0;
    for (branches.first..branches.end) |branch| {
        total_shoot_carbon_g_c += state.branch_leaf_carbon_g[branch] +
            state.branch_sheath_carbon_g[branch] +
            state.branch_stalk_carbon_g[branch] +
            state.branch_reserve_carbon_g[branch] +
            state.branch_husk_carbon_g[branch] +
            state.branch_ear_carbon_g[branch] +
            state.branch_grain_carbon_g[branch] +
            state.branch_mobile_carbon_g[branch];
        const nodes = try state.nodeRange(branch);
        for (nodes.first..nodes.end) |node|
            total_shoot_carbon_g_c += state.node_c3_nonstructural_carbon_g[node] +
                state.node_c4_mesophyll_nonstructural_carbon_g[node] +
                state.node_bundle_sheath_co2_carbon_g[node] +
                state.node_bundle_sheath_bicarbonate_carbon_g[node];
    }
    if (!std.math.isFinite(total_shoot_carbon_g_c) or total_shoot_carbon_g_c < 0)
        return error.InvalidPostHarvestPlantTotalInput;
    state.plant_total_shoot_carbon_g[plant] = total_shoot_carbon_g_c;
    state.plant_previous_total_shoot_carbon_g[plant] = total_shoot_carbon_g_c;
    state.plant_shoot_growth_g_c_per_step[plant] = 0;
}

/// Automatic GROSUB winter-annual harvest generated when the main branch
/// enters end-of-season reproductive turnover.
pub fn applyAutomaticSelfSeedingHarvests(
    context: *group_misc.Context,
    seasonal_turnover_event_by_plant: []const bool,
    growth_habit_by_plant: []const u8,
    leaf_phenology_type_by_plant: []const u8,
    current_date: management.PackedDate,
) !usize {
    const plant_state = context.plant_phenology orelse return error.IncompleteAutomaticSelfSeedingContext;
    const plant_count = context.canopy_state.plant_branch_offsets.len - 1;
    if (growth_habit_by_plant.len != plant_count or leaf_phenology_type_by_plant.len != plant_count or
        plant_state.active.len != plant_count or plant_state.reseed_pending.len != plant_count or
        seasonal_turnover_event_by_plant.len != plant_count or
        (context.automatic_harvest_date_by_plant != null and context.automatic_harvest_date_by_plant.?.len != plant_count))
        return error.AutomaticSelfSeedingDimensionMismatch;
    _ = try current_date.dayOfYear(current_date.year);
    var applied: usize = 0;
    for (0..plant_count) |plant| {
        if (!plant_state.active[plant] or plant_state.reseed_pending[plant] or
            growth_habit_by_plant[plant] != 0 or leaf_phenology_type_by_plant[plant] == 0)
            continue;
        if (!seasonal_turnover_event_by_plant[plant]) continue;
        try applyEvent(context, plant, .{
            .date = current_date,
            .kind = .grain,
            .termination = .terminate_and_reseed,
            .cutting_height_m_or_lai_fraction = 0,
            .thinning_fraction_or_consumption_rate = 0,
            .harvested_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 1 },
            .ecosystem_export_fraction = .{ .leaf = 0, .nonfoliar = 1, .woody = 0, .standing_dead = 0 },
        });
        if (context.automatic_harvest_date_by_plant) |dates| dates[plant] = current_date;
        applied += 1;
    }
    return applied;
}

/// GROSUB spring perennial transition immediately before shoot topology is
/// reconstructed. Old deciduous foliage and all reproductive organs become
/// litter; herbaceous/shrub stalk enters standing dead and stalk reserve is
/// retained in seasonal storage.
pub fn applyStartOfSeasonResidue(
    context: *group_misc.Context,
    plant: usize,
    biomass_turnover_type: u8,
    root_profile_type: u8,
) !void {
    // This transition is rare (once per admitted leafout), so stage the full
    // canopy owner to guarantee that a late topology/arithmetic failure cannot
    // publish a partial C/N/P cleanup.
    var staged_canopy = try context.canopy_state.clone();
    defer staged_canopy.deinit();
    const staged_products = try context.canopy_state.allocator.dupe(group_types.ProductLedger, context.products_by_plant);
    defer context.canopy_state.allocator.free(staged_products);
    var staged_context = context.*;
    staged_context.canopy_state = &staged_canopy;
    staged_context.products_by_plant = staged_products;
    try applyStartOfSeasonResidueStaged(&staged_context, plant, biomass_turnover_type, root_profile_type);
    inline for (@typeInfo(canopy.State).@"struct".fields) |field| {
        if (field.type == []f64) @memcpy(@field(context.canopy_state, field.name), @field(staged_canopy, field.name));
    }
    @memcpy(context.products_by_plant, staged_products);
}

fn applyStartOfSeasonResidueStaged(
    context: *group_misc.Context,
    plant: usize,
    biomass_turnover_type: u8,
    root_profile_type: u8,
) !void {
    const state = context.canopy_state;
    if (plant >= context.science_by_plant.len or plant >= context.products_by_plant.len)
        return error.PlantHarvestIndexOutOfBounds;
    const science = context.science_by_plant[plant];
    try group_validation.validateScience(science);
    const partitions = context.root_litter_partition orelse return error.IncompleteStartOfSeasonResidueContext;
    if (plant >= partitions.plant_count) return error.PlantHarvestIndexOutOfBounds;
    const stalk_kinetics = try partitions.get(plant, .stalk);
    const reproductive_kinetics = try partitions.get(plant, .non_foliar);
    const branches = try state.branchRange(plant);
    for (branches.first..branches.end) |branch| {
        if (biomass_turnover_type == 0) {
            const nodes = try state.nodeRange(branch);
            for (nodes.first..nodes.end) |node| {
                const node_within_branch = node - nodes.first;
                const samples = try state.sampleRange(node);
                for (samples.first..samples.end) |sample| {
                    const products = try canopy.harvestLeafLayerSample(
                        state,
                        branch,
                        node_within_branch,
                        sample - samples.first,
                        .{ .remaining_fraction = 0, .unexported_fraction = 1, .height_below_cut_fraction = 0 },
                        science.carbon_woody_fraction,
                        science.leaf_nitrogen_woody_fraction,
                        science.leaf_phosphorus_woody_fraction,
                        node_within_branch == 1,
                    );
                    group_misc.addProducts(&context.products_by_plant[plant].foliar, products.foliar);
                    group_misc.addProducts(&context.products_by_plant[plant].woody, products.woody);
                }
                const sheath = try canopy.harvestNodeSheath(
                    state,
                    branch,
                    node_within_branch,
                    0,
                    1,
                    science.carbon_woody_fraction,
                    science.sheath_nitrogen_woody_fraction,
                    science.sheath_phosphorus_woody_fraction,
                    false,
                    0,
                );
                group_misc.addProducts(&context.products_by_plant[plant].nonfoliar, sheath.nonwoody);
                group_misc.addProducts(&context.products_by_plant[plant].woody, sheath.woody);
            }
        }
        var husk: spring_reproductive_litterfall.Elements = .{ .carbon = state.branch_husk_carbon_g[branch], .nitrogen = state.branch_husk_nitrogen_g[branch], .phosphorus = state.branch_husk_phosphorus_g[branch] };
        var ear: spring_reproductive_litterfall.Elements = .{ .carbon = state.branch_ear_carbon_g[branch], .nitrogen = state.branch_ear_nitrogen_g[branch], .phosphorus = state.branch_ear_phosphorus_g[branch] };
        var grain: spring_reproductive_litterfall.Elements = .{ .carbon = state.branch_grain_carbon_g[branch], .nitrogen = state.branch_grain_nitrogen_g[branch], .phosphorus = state.branch_grain_phosphorus_g[branch] };
        _ = try spring_reproductive_litterfall.apply(.{
            .husk = &husk,
            .ear = &ear,
            .grain = &grain,
            .potential_seed_site_count = &state.branch_potential_seed_site_count[branch],
            .grain_count = &state.branch_seed_count[branch],
            .individual_grain_carbon_g_c = &state.branch_individual_seed_carbon_g[branch],
            .litter_carbon_g_c = &context.products_by_plant[plant].direct_litter.nonwoody_carbon_g,
            .litter_nitrogen_g_n = &context.products_by_plant[plant].direct_litter.nonwoody_nitrogen_g,
            .litter_phosphorus_g_p = &context.products_by_plant[plant].direct_litter.nonwoody_phosphorus_g,
        }, .{
            .leafout_status = .enabled,
            .perennial = true,
            .accumulated_leafout_h = 1,
            .required_leafout_h = 1,
            .reproductive_litter_kinetics = .{ .carbon = &reproductive_kinetics.carbon, .nitrogen = &reproductive_kinetics.nitrogen, .phosphorus = &reproductive_kinetics.phosphorus },
        });
        state.branch_husk_carbon_g[branch] = husk.carbon;
        state.branch_husk_nitrogen_g[branch] = husk.nitrogen;
        state.branch_husk_phosphorus_g[branch] = husk.phosphorus;
        state.branch_ear_carbon_g[branch] = ear.carbon;
        state.branch_ear_nitrogen_g[branch] = ear.nitrogen;
        state.branch_ear_phosphorus_g[branch] = ear.phosphorus;
        state.branch_grain_carbon_g[branch] = grain.carbon;
        state.branch_grain_nitrogen_g[branch] = grain.nitrogen;
        state.branch_grain_phosphorus_g[branch] = grain.phosphorus;

        if (biomass_turnover_type == 0 or root_profile_type == 1) {
            const stalk: canopy.ElementalMass = .{
                .carbon_g = state.branch_stalk_carbon_g[branch],
                .nitrogen_g = state.branch_stalk_nitrogen_g[branch],
                .phosphorus_g = state.branch_stalk_phosphorus_g[branch],
            };
            state.plant_standing_dead_carbon_g[plant] += stalk.carbon_g;
            state.plant_standing_dead_nitrogen_g[plant] += stalk.nitrogen_g;
            state.plant_standing_dead_phosphorus_g[plant] += stalk.phosphorus_g;
            for (0..4) |kinetic| {
                const index = plant * 4 + kinetic;
                state.plant_standing_dead_carbon_by_kinetic_g[index] += stalk.carbon_g * stalk_kinetics.carbon[kinetic];
                state.plant_standing_dead_nitrogen_by_kinetic_g[index] += stalk.nitrogen_g * stalk_kinetics.nitrogen[kinetic];
                state.plant_standing_dead_phosphorus_by_kinetic_g[index] += stalk.phosphorus_g * stalk_kinetics.phosphorus[kinetic];
            }
            state.plant_seed_storage_carbon_g[plant] += state.branch_reserve_carbon_g[branch];
            state.plant_seed_storage_nitrogen_g[plant] += state.branch_reserve_nitrogen_g[branch];
            state.plant_seed_storage_phosphorus_g[plant] += state.branch_reserve_phosphorus_g[branch];
            state.branch_stalk_carbon_g[branch] = 0;
            state.branch_stalk_nitrogen_g[branch] = 0;
            state.branch_stalk_phosphorus_g[branch] = 0;
            state.branch_senescing_stalk_carbon_g[branch] = 0;
            state.branch_senescing_stalk_nitrogen_g[branch] = 0;
            state.branch_senescing_stalk_phosphorus_g[branch] = 0;
            state.branch_reserve_carbon_g[branch] = 0;
            state.branch_reserve_nitrogen_g[branch] = 0;
            state.branch_reserve_phosphorus_g[branch] = 0;
            const nodes = try state.nodeRange(branch);
            for (nodes.first..nodes.end) |node| {
                state.node_internode_carbon_g[node] = 0;
                state.node_internode_nitrogen_g[node] = 0;
                state.node_internode_phosphorus_g[node] = 0;
                state.node_internode_length_m[node] = 0;
            }
        }
    }
    try state.validateFinite();
}

/// GROSUB whole-plant death transaction. All living shoot inventories are
/// removed before the dead perennial is scheduled for next-day reconstruction:
/// foliage and reproductive material enter surface litter, stalk plus reserve
/// enter standing dead, and seasonal storage enters nonstructural/woody litter.
pub fn applyWholePlantMortalityResidue(context: *group_misc.Context, plant: usize) !void {
    const state = context.canopy_state;
    if (plant >= context.science_by_plant.len or plant >= context.products_by_plant.len)
        return error.PlantHarvestIndexOutOfBounds;
    const partitions = context.root_litter_partition orelse return error.IncompletePlantMortalityResidueContext;
    if (plant >= partitions.plant_count) return error.PlantHarvestIndexOutOfBounds;
    _ = try partitions.get(plant, .stalk);
    const science = context.science_by_plant[plant];
    try group_validation.validateScience(science);

    const storage: canopy.ElementalMass = .{
        .carbon_g = state.plant_seed_storage_carbon_g[plant],
        .nitrogen_g = state.plant_seed_storage_nitrogen_g[plant],
        .phosphorus_g = state.plant_seed_storage_phosphorus_g[plant],
    };
    state.plant_seed_storage_carbon_g[plant] = 0;
    state.plant_seed_storage_nitrogen_g[plant] = 0;
    state.plant_seed_storage_phosphorus_g[plant] = 0;
    const woody_storage: canopy.ElementalMass = .{
        .carbon_g = storage.carbon_g * science.carbon_woody_fraction[0],
        .nitrogen_g = storage.nitrogen_g * science.leaf_nitrogen_woody_fraction[0],
        .phosphorus_g = storage.phosphorus_g * science.leaf_phosphorus_woody_fraction[0],
    };
    const nonwoody_storage: canopy.ElementalMass = .{
        .carbon_g = storage.carbon_g * science.carbon_woody_fraction[1],
        .nitrogen_g = storage.nitrogen_g * science.leaf_nitrogen_woody_fraction[1],
        .phosphorus_g = storage.phosphorus_g * science.leaf_phosphorus_woody_fraction[1],
    };
    const storage_kinetics = try partitions.get(plant, .nonstructural);
    try group_harvest.addHarvestLitterKinetics(&context.products_by_plant[plant].direct_litter, woody_storage, storage_kinetics, true);
    try group_harvest.addHarvestLitterKinetics(&context.products_by_plant[plant].direct_litter, nonwoody_storage, storage_kinetics, false);

    const branches = try state.branchRange(plant);
    for (branches.first..branches.end) |branch| {
        const reserve: canopy.ElementalMass = .{
            .carbon_g = state.branch_reserve_carbon_g[branch],
            .nitrogen_g = state.branch_reserve_nitrogen_g[branch],
            .phosphorus_g = state.branch_reserve_phosphorus_g[branch],
        };
        state.branch_reserve_carbon_g[branch] = 0;
        state.branch_reserve_nitrogen_g[branch] = 0;
        state.branch_reserve_phosphorus_g[branch] = 0;
        state.branch_stalk_carbon_g[branch] += reserve.carbon_g;
        state.branch_stalk_nitrogen_g[branch] += reserve.nitrogen_g;
        state.branch_stalk_phosphorus_g[branch] += reserve.phosphorus_g;

        const mobile = try canopy.harvestBranchMobilePools(state, branch, 0);
        group_misc.addMass(&context.products_by_plant[plant].nonstructural.litter, mobile);
        const symbiont_mobile: canopy.ElementalMass = .{
            .carbon_g = state.branch_symbiont_mobile_carbon_g[branch],
            .nitrogen_g = state.branch_symbiont_mobile_nitrogen_g[branch],
            .phosphorus_g = state.branch_symbiont_mobile_phosphorus_g[branch],
        };
        const symbiont_structural: canopy.ElementalMass = .{
            .carbon_g = state.branch_symbiont_structural_carbon_g[branch],
            .nitrogen_g = state.branch_symbiont_structural_nitrogen_g[branch],
            .phosphorus_g = state.branch_symbiont_structural_phosphorus_g[branch],
        };
        group_misc.addMass(&context.products_by_plant[plant].nonstructural.litter, symbiont_mobile);
        group_misc.addMass(&context.products_by_plant[plant].foliar.litter, symbiont_structural);
        state.branch_symbiont_mobile_carbon_g[branch] = 0;
        state.branch_symbiont_mobile_nitrogen_g[branch] = 0;
        state.branch_symbiont_mobile_phosphorus_g[branch] = 0;
        state.branch_symbiont_structural_carbon_g[branch] = 0;
        state.branch_symbiont_structural_nitrogen_g[branch] = 0;
        state.branch_symbiont_structural_phosphorus_g[branch] = 0;
    }

    // Whole-plant death publishes reproductive organs through the nonfoliar
    // harvest ledger.  The spring-transition owner below deliberately routes
    // those organs directly to litter, so consume them here before sharing its
    // foliage and stalk cleanup.
    for (branches.first..branches.end) |branch| {
        const reproductive = try canopy.harvestReproductiveOrgans(state, branch, .{
            .husk_remaining = 0,
            .husk_unexported = 1,
            .ear_remaining = 0,
            .ear_unexported = 1,
            .grain_remaining = 0,
            .grain_unexported = 1,
        });
        group_misc.addProducts(&context.products_by_plant[plant].nonfoliar, reproductive.products);
    }

    // Death removes foliage for every turnover type and routes every stalk.
    try applyStartOfSeasonResidue(context, plant, 0, 1);
    for (branches.first..branches.end) |branch| {
        state.branch_sapwood_carbon_g[branch] = 0;
        state.branch_fixed_carbon_g_c_per_h[branch] = 0;
        state.branch_shoot_carbohydrate_g_c_per_h[branch] = 0;
        state.branch_carboxylation_umol_per_s[branch] = 0;
        state.branch_potential_seed_site_count[branch] = 0;
        state.branch_seed_count[branch] = 0;
        const nodes = try state.nodeRange(branch);
        for (nodes.first..nodes.end) |node| {
            state.node_height_m[node] = 0;
            state.node_sheath_height_m[node] = 0;
            const samples = try state.sampleRange(node);
            @memset(state.sample_stalk_area_m2[samples.first..samples.end], 0);
        }
    }
    state.plant_carboxylation_umol_per_s[plant] = 0;
    state.plant_maximum_turgor_carboxylation_umol_per_s[plant] = 0;
    state.plant_gross_primary_productivity_g_c_per_h[plant] = 0;
    state.plant_mobile_carbon_g[plant] = 0;
    state.plant_mobile_nitrogen_g[plant] = 0;
    state.plant_mobile_phosphorus_g[plant] = 0;
    state.plant_symbiont_mobile_carbon_g[plant] = 0;
    state.plant_symbiont_mobile_nitrogen_g[plant] = 0;
    state.plant_symbiont_mobile_phosphorus_g[plant] = 0;
    state.plant_total_shoot_carbon_g[plant] = 0;
    state.plant_shoot_growth_g_c_per_step[plant] = 0;
    try state.validateFinite();
}

/// GROSUB dead-branch transaction preceding whole-PFT death. Host mobile C/N/P,
/// C3/C4 intermediates, and stalk reserve return to seasonal storage; remaining
/// foliage and reproductive organs enter litter, stalk enters standing dead,
/// and canopy symbionts enter their source litter classes.
pub fn applyNaturalDeadBranchResidue(
    context: *group_misc.Context,
    plant: usize,
    branch: usize,
    winter_annual: bool,
) !void {
    const state = context.canopy_state;
    if (plant >= context.science_by_plant.len or plant >= context.products_by_plant.len)
        return error.PlantHarvestIndexOutOfBounds;
    const branches = try state.branchRange(plant);
    if (branch < branches.first or branch >= branches.end) return error.CanopyBranchIndexOutOfBounds;
    const partitions = context.root_litter_partition orelse return error.IncompleteDeadBranchResidueContext;
    const stalk_kinetics = try partitions.get(plant, .stalk);
    const science = context.science_by_plant[plant];
    try group_validation.validateScience(science);
    if (context.canopy_layer_state) |layers| try layers.clearDeadBranch(state, plant, branch);

    const recovered_mobile = try canopy.harvestBranchMobilePools(state, branch, 0);
    state.plant_seed_storage_carbon_g[plant] += recovered_mobile.carbon_g + state.branch_reserve_carbon_g[branch];
    state.plant_seed_storage_nitrogen_g[plant] += recovered_mobile.nitrogen_g + state.branch_reserve_nitrogen_g[branch];
    state.plant_seed_storage_phosphorus_g[plant] += recovered_mobile.phosphorus_g + state.branch_reserve_phosphorus_g[branch];
    state.branch_reserve_carbon_g[branch] = 0;
    state.branch_reserve_nitrogen_g[branch] = 0;
    state.branch_reserve_phosphorus_g[branch] = 0;

    const symbiont_mobile: canopy.ElementalMass = .{
        .carbon_g = state.branch_symbiont_mobile_carbon_g[branch],
        .nitrogen_g = state.branch_symbiont_mobile_nitrogen_g[branch],
        .phosphorus_g = state.branch_symbiont_mobile_phosphorus_g[branch],
    };
    const symbiont_structural: canopy.ElementalMass = .{
        .carbon_g = state.branch_symbiont_structural_carbon_g[branch],
        .nitrogen_g = state.branch_symbiont_structural_nitrogen_g[branch],
        .phosphorus_g = state.branch_symbiont_structural_phosphorus_g[branch],
    };
    group_misc.addMass(&context.products_by_plant[plant].nonstructural.litter, symbiont_mobile);
    group_misc.addMass(&context.products_by_plant[plant].foliar.litter, symbiont_structural);
    state.branch_symbiont_mobile_carbon_g[branch] = 0;
    state.branch_symbiont_mobile_nitrogen_g[branch] = 0;
    state.branch_symbiont_mobile_phosphorus_g[branch] = 0;
    state.branch_symbiont_structural_carbon_g[branch] = 0;
    state.branch_symbiont_structural_nitrogen_g[branch] = 0;
    state.branch_symbiont_structural_phosphorus_g[branch] = 0;

    const nodes = try state.nodeRange(branch);
    for (nodes.first..nodes.end) |node| {
        const node_within_branch = node - nodes.first;
        const samples = try state.sampleRange(node);
        for (samples.first..samples.end) |sample| {
            const leaf = try canopy.harvestLeafLayerSample(
                state,
                branch,
                node_within_branch,
                sample - samples.first,
                .{ .remaining_fraction = 0, .unexported_fraction = 1, .height_below_cut_fraction = 0 },
                science.carbon_woody_fraction,
                science.leaf_nitrogen_woody_fraction,
                science.leaf_phosphorus_woody_fraction,
                node_within_branch == 1,
            );
            group_misc.addProducts(&context.products_by_plant[plant].foliar, leaf.foliar);
            group_misc.addProducts(&context.products_by_plant[plant].woody, leaf.woody);
        }
        const sheath = try canopy.harvestNodeSheath(state, branch, node_within_branch, 0, 1, science.carbon_woody_fraction, science.sheath_nitrogen_woody_fraction, science.sheath_phosphorus_woody_fraction, false, 0);
        group_misc.addProducts(&context.products_by_plant[plant].nonfoliar, sheath.nonwoody);
        group_misc.addProducts(&context.products_by_plant[plant].woody, sheath.woody);
    }

    const grain: canopy.ElementalMass = .{
        .carbon_g = state.branch_grain_carbon_g[branch],
        .nitrogen_g = state.branch_grain_nitrogen_g[branch],
        .phosphorus_g = state.branch_grain_phosphorus_g[branch],
    };
    const reproductive = try canopy.harvestReproductiveOrgans(state, branch, .{
        .husk_remaining = 0,
        .husk_unexported = 1,
        .ear_remaining = 0,
        .ear_unexported = 1,
        .grain_remaining = 0,
        .grain_unexported = 1,
    });
    group_misc.addProducts(&context.products_by_plant[plant].nonfoliar, reproductive.products);
    if (winter_annual) {
        try group_misc.subtractMass(&context.products_by_plant[plant].nonfoliar.litter, grain);
        group_misc.addMassToStorage(state, plant, grain);
    }

    const stalk: canopy.ElementalMass = .{
        .carbon_g = state.branch_stalk_carbon_g[branch],
        .nitrogen_g = state.branch_stalk_nitrogen_g[branch],
        .phosphorus_g = state.branch_stalk_phosphorus_g[branch],
    };
    group_misc.addMassToStandingDead(state, plant, stalk, stalk_kinetics);
    state.branch_stalk_carbon_g[branch] = 0;
    state.branch_stalk_nitrogen_g[branch] = 0;
    state.branch_stalk_phosphorus_g[branch] = 0;
    state.branch_sapwood_carbon_g[branch] = 0;
    state.branch_senescing_stalk_carbon_g[branch] = 0;
    state.branch_senescing_stalk_nitrogen_g[branch] = 0;
    state.branch_senescing_stalk_phosphorus_g[branch] = 0;
    state.branch_leaf_area_m2[branch] = 0;
    state.branch_potential_seed_site_count[branch] = 0;
    state.branch_seed_count[branch] = 0;
    state.branch_individual_seed_carbon_g[branch] = 0;
    state.branch_c3_feedback_fraction[branch] = 1;
    state.branch_c4_feedback_fraction[branch] = 1;
    try state.validateFinite();
}

/// Late-GROSUB tillage of an eligible herbaceous canopy. The common canopy
/// transaction is reused, but roots are excluded because the disturbance
/// dispatcher state_updates their layer-resolved transaction separately.
pub fn applyAbovegroundTillage(context: *group_misc.Context, plant: usize, remaining_fraction: f64, winter_annual: bool) !void {
    if (!std.math.isFinite(remaining_fraction) or remaining_fraction < 0 or remaining_fraction > 1)
        return error.InvalidPlantTillageRetention;
    const state = context.canopy_state;
    if (plant >= state.plant_population_count.len or plant >= context.products_by_plant.len)
        return error.PlantHarvestIndexOutOfBounds;
    const root_fractions = context.root_woody_fraction_by_plant orelse return error.IncompletePlantTillageRootComposition;
    if (plant >= root_fractions.len) return error.PlantHarvestIndexOutOfBounds;
    const root_nonwoody = root_fractions[plant];
    if (!std.math.isFinite(root_nonwoody) or root_nonwoody < 0 or root_nonwoody > 1)
        return error.InvalidPlantTillageRootComposition;
    const standing: canopy.ElementalMass = .{
        .carbon_g = state.plant_standing_dead_carbon_g[plant],
        .nitrogen_g = state.plant_standing_dead_nitrogen_g[plant],
        .phosphorus_g = state.plant_standing_dead_phosphorus_g[plant],
    };
    inline for (.{ standing.carbon_g, standing.nitrogen_g, standing.phosphorus_g }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantTillageStandingDead;
    const branches = try state.branchRange(plant);
    var grain_before: canopy.ElementalMass = .{};
    for (branches.first..branches.end) |branch| {
        grain_before.carbon_g += state.branch_grain_carbon_g[branch];
        grain_before.nitrogen_g += state.branch_grain_nitrogen_g[branch];
        grain_before.phosphorus_g += state.branch_grain_phosphorus_g[branch];
    }
    const storage_before: canopy.ElementalMass = .{
        .carbon_g = state.plant_seed_storage_carbon_g[plant],
        .nitrogen_g = state.plant_seed_storage_nitrogen_g[plant],
        .phosphorus_g = state.plant_seed_storage_phosphorus_g[plant],
    };
    inline for (.{
        grain_before.carbon_g,
        grain_before.nitrogen_g,
        grain_before.phosphorus_g,
        storage_before.carbon_g,
        storage_before.nitrogen_g,
        storage_before.phosphorus_g,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantTillageStorage;
    for (branches.first..branches.end) |branch| inline for (.{
        "branch_symbiont_mobile_carbon_g",
        "branch_symbiont_mobile_nitrogen_g",
        "branch_symbiont_mobile_phosphorus_g",
        "branch_symbiont_structural_carbon_g",
        "branch_symbiont_structural_nitrogen_g",
        "branch_symbiont_structural_phosphorus_g",
    }) |field_name| {
        const value = @field(state, field_name)[branch];
        if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantTillageSymbiont;
    };
    const layers = context.canopy_layer_state;
    if (layers == null and (standing.carbon_g > 0 or standing.nitrogen_g > 0 or standing.phosphorus_g > 0))
        return error.IncompletePlantTillageStandingDeadContext;
    try applyEventInternal(context, plant, .{
        .date = .{ .day = 1, .month = 1, .year = 9999 },
        .kind = .none,
        .termination = if (remaining_fraction == 0) .terminate else .retain,
        .cutting_height_m_or_lai_fraction = 0,
        .thinning_fraction_or_consumption_rate = 1 - remaining_fraction,
        .harvested_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 1 },
        .ecosystem_export_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0 },
    }, false, false);

    const removed_fraction = 1 - remaining_fraction;
    const grain_to_storage: canopy.ElementalMass = if (winter_annual) .{
        .carbon_g = grain_before.carbon_g * removed_fraction,
        .nitrogen_g = grain_before.nitrogen_g * removed_fraction,
        .phosphorus_g = grain_before.phosphorus_g * removed_fraction,
    } else .{};
    if (winter_annual) {
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
            const next = @field(context.products_by_plant[plant].nonfoliar.litter, field.name) - @field(grain_to_storage, field.name);
            if (!std.math.isFinite(next) or next < 0) return error.InvalidPlantTillageStorage;
            @field(context.products_by_plant[plant].nonfoliar.litter, field.name) = next;
        }
    }
    const combined_storage: canopy.ElementalMass = .{
        .carbon_g = storage_before.carbon_g + grain_to_storage.carbon_g,
        .nitrogen_g = storage_before.nitrogen_g + grain_to_storage.nitrogen_g,
        .phosphorus_g = storage_before.phosphorus_g + grain_to_storage.phosphorus_g,
    };
    const removed_storage: canopy.ElementalMass = .{
        .carbon_g = combined_storage.carbon_g * removed_fraction,
        .nitrogen_g = combined_storage.nitrogen_g * removed_fraction,
        .phosphorus_g = combined_storage.phosphorus_g * removed_fraction,
    };
    group_misc.addScaledMass(&context.products_by_plant[plant].woody.litter, removed_storage, 1 - root_nonwoody);
    group_misc.addScaledMass(&context.products_by_plant[plant].nonstructural.litter, removed_storage, root_nonwoody);
    state.plant_seed_storage_carbon_g[plant] = combined_storage.carbon_g * remaining_fraction;
    state.plant_seed_storage_nitrogen_g[plant] = combined_storage.nitrogen_g * remaining_fraction;
    state.plant_seed_storage_phosphorus_g[plant] = combined_storage.phosphorus_g * remaining_fraction;
    for (branches.first..branches.end) |branch| {
        const mobile_symbiont: canopy.ElementalMass = .{
            .carbon_g = state.branch_symbiont_mobile_carbon_g[branch] * removed_fraction,
            .nitrogen_g = state.branch_symbiont_mobile_nitrogen_g[branch] * removed_fraction,
            .phosphorus_g = state.branch_symbiont_mobile_phosphorus_g[branch] * removed_fraction,
        };
        const structural_symbiont: canopy.ElementalMass = .{
            .carbon_g = state.branch_symbiont_structural_carbon_g[branch] * removed_fraction,
            .nitrogen_g = state.branch_symbiont_structural_nitrogen_g[branch] * removed_fraction,
            .phosphorus_g = state.branch_symbiont_structural_phosphorus_g[branch] * removed_fraction,
        };
        group_misc.addMass(&context.products_by_plant[plant].nonstructural.litter, mobile_symbiont);
        group_misc.addMass(&context.products_by_plant[plant].foliar.litter, structural_symbiont);
        inline for (.{
            "branch_symbiont_mobile_carbon_g",
            "branch_symbiont_mobile_nitrogen_g",
            "branch_symbiont_mobile_phosphorus_g",
            "branch_symbiont_structural_carbon_g",
            "branch_symbiont_structural_nitrogen_g",
            "branch_symbiont_structural_phosphorus_g",
        }) |field_name| @field(state, field_name)[branch] *= remaining_fraction;
    }
    const removed_standing: canopy.ElementalMass = .{
        .carbon_g = standing.carbon_g * removed_fraction,
        .nitrogen_g = standing.nitrogen_g * removed_fraction,
        .phosphorus_g = standing.phosphorus_g * removed_fraction,
    };
    group_misc.addScaledMass(&context.products_by_plant[plant].woody.litter, removed_standing, 1 - root_nonwoody);
    group_misc.addScaledMass(&context.products_by_plant[plant].nonfoliar.litter, removed_standing, root_nonwoody);
    inline for (.{
        "plant_standing_dead_carbon_g",
        "plant_standing_dead_nitrogen_g",
        "plant_standing_dead_phosphorus_g",
    }) |field_name| @field(state, field_name)[plant] *= remaining_fraction;
    const kinetic_first = plant * 4;
    inline for (.{
        "plant_standing_dead_carbon_by_kinetic_g",
        "plant_standing_dead_nitrogen_by_kinetic_g",
        "plant_standing_dead_phosphorus_by_kinetic_g",
    }) |field_name| {
        for (@field(state, field_name)[kinetic_first..][0..4]) |*value|
            value.* *= remaining_fraction;
    }
    if (layers) |layer_state| {
        const cell = plant / state.species_count;
        for (0..layer_state.layer_count) |layer| {
            const plant_layer = plant * layer_state.layer_count + layer;
            layer_state.plant_standing_dead_area_m2[plant_layer] *= remaining_fraction;
            layer_state.cell_standing_dead_area_m2[cell * layer_state.layer_count + layer] =
                try standingDeadAreaForCellLayer(layer_state, cell, state.species_count, layer);
            const projected_first = plant_layer * layer_state.inclination_count;
            for (layer_state.plant_standing_dead_projected_surface_m2[projected_first..][0..layer_state.inclination_count]) |*area_m2|
                area_m2.* *= remaining_fraction;
        }
    }
}

pub fn applyEventInternal(context: *group_misc.Context, plant: usize, source_event: management.HarvestEvent, include_roots: bool, include_standing_dead: bool) !void {
    var event = source_event;
    if (event.kind == .animal_grazing or event.kind == .insect_grazing) return error.GrazingRequiresDemandDrivenKernel;
    const state = context.canopy_state;
    if (plant >= context.science_by_plant.len or plant >= context.products_by_plant.len) return error.PlantHarvestIndexOutOfBounds;
    if (@intFromEnum(event.kind) <= @intFromEnum(management.HarvestKind.above_ground) and event.cutting_height_m_or_lai_fraction < 0) {
        const layers = context.canopy_layer_state orelse return error.IncompleteLeafAreaHarvestContext;
        const cell = plant / state.species_count;
        if (cell >= layers.cell_count or layers.species_count != state.species_count) return error.PlantHarvestIndexOutOfBounds;
        const first = cell * layers.layer_count;
        event.cutting_height_m_or_lai_fraction = try group_harvest.cuttingHeightFromLeafAreaRemoval(
            @abs(event.cutting_height_m_or_lai_fraction),
            try layers.cellBoundaries(cell),
            layers.cell_leaf_area_m2[first..][0..layers.layer_count],
            context.leaf_area_presence_tolerance_m2,
        );
    }
    const branches = try state.branchRange(plant);
    if (context.branch_development.branch_count != state.branch_stalk_carbon_g.len) return error.BranchDevelopmentDimensionMismatch;
    var prepared_post_harvest = try preparePostHarvest(
        context,
        plant,
        event.cutting_height_m_or_lai_fraction,
    );
    defer if (prepared_post_harvest) |prepared|
        state.allocator.free(prepared.allocation);
    const science = context.science_by_plant[plant];
    try group_validation.validateScience(science);
    const thinning_retention = 1.0 - event.thinning_fraction_or_consumption_rate;
    if (!std.math.isFinite(thinning_retention) or thinning_retention < 0 or thinning_retention > 1)
        return error.InvalidPlantHarvestThinningFraction;
    const pruning = event.kind == .pruning;
    const grain_only = event.kind == .grain;
    const reseed = event.termination == .terminate_and_reseed;
    const reseed_population_per_m2: f64 = if (reseed) blk: {
        const targets = context.reseed_population_per_m2_by_plant orelse return error.IncompletePlantReseedContext;
        const areas = context.cell_area_m2_by_cell orelse return error.IncompletePlantReseedContext;
        const plant_state = context.plant_phenology orelse return error.IncompletePlantReseedContext;
        const cell = plant / state.species_count;
        if (plant >= targets.len or plant >= plant_state.reseed_pending.len or cell >= areas.len) return error.PlantHarvestIndexOutOfBounds;
        if (!std.math.isFinite(targets[plant]) or targets[plant] < 0 or
            !std.math.isFinite(areas[cell]) or areas[cell] <= 0)
            return error.InvalidPlantReseedPopulation;
        break :blk targets[plant];
    } else 0;
    const PruningStateUpdate = struct { structure: *canopy_structure.State, initial: f64, effective: f64 };
    const pruning_state_update: ?PruningStateUpdate = if (pruning) blk: {
        const structure = context.canopy_structure_state orelse return error.IncompletePruningContext;
        if (plant >= structure.initial_clumping_factor.len or plant >= structure.effective_clumping_factor.len)
            return error.PlantHarvestIndexOutOfBounds;
        if (!std.math.isFinite(event.cutting_height_m_or_lai_fraction) or event.cutting_height_m_or_lai_fraction < 0)
            return error.InvalidPruningClumpingFraction;
        break :blk .{
            .structure = structure,
            .initial = try group_harvest.prunedClumpingFactor(structure.initial_clumping_factor[plant], event.cutting_height_m_or_lai_fraction),
            .effective = try group_harvest.prunedClumpingFactor(structure.effective_clumping_factor[plant], event.cutting_height_m_or_lai_fraction),
        };
    } else null;
    var maximum_internode_height_m: f64 = 0;
    for (branches.first..branches.end) |branch| {
        const nodes = try state.nodeRange(branch);
        for (state.node_height_m[nodes.first..nodes.end]) |height_m|
            maximum_internode_height_m = @max(maximum_internode_height_m, height_m);
    }
    const reproductive_organs_reached_by_cut =
        event.cutting_height_m_or_lai_fraction < maximum_internode_height_m;
    for (branches.first..branches.end) |branch| {
        // grosub.f's leaf/sheath/stalk cutting-height transaction runs for
        // every IHVST reaching this point (IHVST.GE.0 .AND. IHVST.NE.4 .AND.
        // IHVST.NE.6 -- grazing kinds 4/6 are already excluded above at the
        // GrazingRequiresDemandDrivenKernel check), including IHVST=1
        // (grain): grosub.f:8566-8568, :8872-8873, :10604-10619. Grain
        // harvest is not exempt from vegetative cutting in the reference.
        try group_harvest.harvestVegetativeBranch(context, plant, branch, event, science, pruning);
        var retention = try canopy.reproductiveRetention(false, reproductive_organs_reached_by_cut, grain_only or pruning, event.thinning_fraction_or_consumption_rate, event.harvested_fraction.nonfoliar, state.branch_husk_carbon_g[branch], state.branch_ear_carbon_g[branch], state.branch_grain_carbon_g[branch], 0, 0, 0);
        retention.husk_unexported = group_misc.unexportedFraction(retention.husk_remaining, event.ecosystem_export_fraction.nonfoliar);
        retention.ear_unexported = group_misc.unexportedFraction(retention.ear_remaining, event.ecosystem_export_fraction.nonfoliar);
        retention.grain_unexported = group_misc.unexportedFraction(retention.grain_remaining, event.ecosystem_export_fraction.nonfoliar);
        const reproductive = try canopy.harvestReproductiveOrgans(state, branch, retention);
        group_misc.addProducts(&context.products_by_plant[plant].nonfoliar, reproductive.products);
        group_misc.addMass(&context.products_by_plant[plant].harvested_grain, reproductive.harvested_grain);
        if (prepared_post_harvest) |prepared|
            try applyPostCutReset(
                context,
                prepared,
                plant,
                branch,
                event.cutting_height_m_or_lai_fraction,
            );
    }
    if (prepared_post_harvest) |*prepared|
        try publishPostHarvestPlantTotals(context, prepared, plant);
    if (include_standing_dead) try applyScheduledStandingDeadHarvest(context, plant, event);
    if (include_roots) try applyRootSymbiontHarvest(
        context,
        plant,
        if (event.termination == .retain) thinning_retention else 0,
    );
    if (!reseed) {
        state.plant_population_per_m2[plant] *= thinning_retention;
        state.plant_population_count[plant] *= thinning_retention;
        state.plant_population_change_count[plant] *= thinning_retention;
        state.plant_standing_dead_population_count[plant] *= thinning_retention;
    } else {
        const cell = plant / state.species_count;
        const population_count = reseed_population_per_m2 * context.cell_area_m2_by_cell.?[cell];
        state.plant_population_per_m2[plant] = reseed_population_per_m2;
        state.plant_population_count[plant] = population_count;
        state.plant_population_change_count[plant] = population_count;
        state.plant_standing_dead_population_count[plant] = population_count;
        try group_misc.retainReseedProductsInSeedStorage(context, plant);
    }
    if (pruning) {
        const state_update = pruning_state_update.?;
        state_update.structure.initial_clumping_factor[plant] = state_update.initial;
        state_update.structure.effective_clumping_factor[plant] = state_update.effective;
    }
    if (event.termination != .retain) {
        if (context.root_state) |roots| {
            if (plant >= roots.roots_dead.len) return error.PlantHarvestIndexOutOfBounds;
            roots.roots_dead[plant] = true;
        }
        try phenology.terminatePlantBranches(context.branch_development, branches.first, branches.end, true);
        if (context.plant_phenology) |plant_state| {
            if (plant >= plant_state.active.len) return error.PlantHarvestIndexOutOfBounds;
            if (!reseed) plant_state.active[plant] = false;
        }
        if (context.emerged_by_plant) |emerged| {
            if (plant >= emerged.len) return error.PlantHarvestIndexOutOfBounds;
            emerged[plant] = false;
        }
        if (context.growth_stages) |growth| {
            const growth_branches = try growth.branchRange(plant);
            for (growth.branches[growth_branches.first..growth_branches.end]) |*branch| branch.dead = true;
        }
        if (reseed) {
            context.plant_phenology.?.reseed_pending[plant] = true;
        }
    }
    try state.validateFinite();
    try context.branch_development.validateFinite();
}

pub fn applyScheduledStandingDeadHarvest(context: *group_misc.Context, plant: usize, event: management.HarvestEvent) !void {
    const state = context.canopy_state;
    const total_removed_fraction = if (event.thinning_fraction_or_consumption_rate == 0)
        event.harvested_fraction.standing_dead
    else
        event.thinning_fraction_or_consumption_rate;
    const harvested_fraction = if (event.thinning_fraction_or_consumption_rate == 0)
        event.harvested_fraction.standing_dead
    else if (event.kind == .none)
        event.harvested_fraction.standing_dead * event.thinning_fraction_or_consumption_rate
    else
        event.thinning_fraction_or_consumption_rate;
    inline for (.{ total_removed_fraction, harvested_fraction, event.ecosystem_export_fraction.standing_dead }) |value|
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidStandingDeadHarvestFraction;
    if (total_removed_fraction == 0) return;
    const root_fractions = context.root_woody_fraction_by_plant orelse return error.IncompleteStandingDeadHarvestContext;
    const layers = context.canopy_layer_state orelse return error.IncompleteStandingDeadHarvestContext;
    if (plant >= root_fractions.len) return error.PlantHarvestIndexOutOfBounds;
    const nonwoody = root_fractions[plant];
    if (!std.math.isFinite(nonwoody) or nonwoody < 0 or nonwoody > 1) return error.InvalidStandingDeadHarvestFraction;
    const initial: canopy.ElementalMass = .{
        .carbon_g = state.plant_standing_dead_carbon_g[plant],
        .nitrogen_g = state.plant_standing_dead_nitrogen_g[plant],
        .phosphorus_g = state.plant_standing_dead_phosphorus_g[plant],
    };
    const initial_charcoal: canopy.ElementalMass = .{
        .carbon_g = state.plant_charcoal_carbon_g[plant],
        .nitrogen_g = state.plant_charcoal_nitrogen_g[plant],
        .phosphorus_g = state.plant_charcoal_phosphorus_g[plant],
    };
    inline for (.{ initial.carbon_g, initial.nitrogen_g, initial.phosphorus_g }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidStandingDeadHarvestState;
    inline for (.{ initial_charcoal.carbon_g, initial_charcoal.nitrogen_g, initial_charcoal.phosphorus_g }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidStandingDeadHarvestState;
    // GROSUB IHVST=1 exports only grain; any simultaneous standing-dead
    // removal is returned completely to litter.
    const export_fraction = if (event.kind == .grain)
        0
    else
        harvested_fraction * event.ecosystem_export_fraction.standing_dead;
    const litter_fraction = total_removed_fraction - export_fraction;
    const exported: canopy.ElementalMass = .{
        .carbon_g = initial.carbon_g * export_fraction,
        .nitrogen_g = initial.nitrogen_g * export_fraction,
        .phosphorus_g = initial.phosphorus_g * export_fraction,
    };
    const litter: canopy.ElementalMass = .{
        .carbon_g = initial.carbon_g * litter_fraction,
        .nitrogen_g = initial.nitrogen_g * litter_fraction,
        .phosphorus_g = initial.phosphorus_g * litter_fraction,
    };
    const exported_charcoal: canopy.ElementalMass = .{
        .carbon_g = initial_charcoal.carbon_g * export_fraction,
        .nitrogen_g = initial_charcoal.nitrogen_g * export_fraction,
        .phosphorus_g = initial_charcoal.phosphorus_g * export_fraction,
    };
    const litter_charcoal: canopy.ElementalMass = .{
        .carbon_g = initial_charcoal.carbon_g * litter_fraction,
        .nitrogen_g = initial_charcoal.nitrogen_g * litter_fraction,
        .phosphorus_g = initial_charcoal.phosphorus_g * litter_fraction,
    };
    group_misc.addMass(&context.products_by_plant[plant].standing_dead_export, exported);
    group_misc.addMass(&context.products_by_plant[plant].standing_dead_export, exported_charcoal);
    group_misc.addMass(&context.products_by_plant[plant].standing_dead_charcoal_litter, litter_charcoal);
    group_misc.addScaledMass(&context.products_by_plant[plant].woody.litter, litter, 1 - nonwoody);
    group_misc.addScaledMass(&context.products_by_plant[plant].nonfoliar.litter, litter, nonwoody);
    const retained = 1 - total_removed_fraction;
    inline for (.{
        "plant_standing_dead_carbon_g",
        "plant_standing_dead_nitrogen_g",
        "plant_standing_dead_phosphorus_g",
    }) |field_name| @field(state, field_name)[plant] *= retained;
    inline for (.{
        "plant_charcoal_carbon_g",
        "plant_charcoal_nitrogen_g",
        "plant_charcoal_phosphorus_g",
    }) |field_name| @field(state, field_name)[plant] *= retained;
    const kinetic_first = plant * 4;
    inline for (.{
        "plant_standing_dead_carbon_by_kinetic_g",
        "plant_standing_dead_nitrogen_by_kinetic_g",
        "plant_standing_dead_phosphorus_by_kinetic_g",
    }) |field_name| {
        for (@field(state, field_name)[kinetic_first..][0..4]) |*value| value.* *= retained;
    }
    const cell = plant / state.species_count;
    for (0..layers.layer_count) |layer| {
        const plant_layer = plant * layers.layer_count + layer;
        layers.plant_standing_dead_area_m2[plant_layer] *= retained;
        layers.cell_standing_dead_area_m2[cell * layers.layer_count + layer] =
            try standingDeadAreaForCellLayer(layers, cell, state.species_count, layer);
        const projected_first = plant_layer * layers.inclination_count;
        for (layers.plant_standing_dead_projected_surface_m2[projected_first..][0..layers.inclination_count]) |*area_m2|
            area_m2.* *= retained;
    }
}

/// Live GROSUB animal/insect grazing transaction for one plant and hour.
pub fn applyGrazingEvent(
    context: *group_misc.Context,
    plant: usize,
    event: management.HarvestEvent,
    landscape_average_shoot_carbon_g_c: f64,
    horizontal_cell_area_m2: f64,
) !f64 {
    if (event.kind != .animal_grazing and event.kind != .insect_grazing) return error.NotGrazingEvent;
    const state = context.canopy_state;
    if (plant >= state.plant_total_shoot_carbon_g.len or plant >= context.products_by_plant.len or
        !std.math.isFinite(landscape_average_shoot_carbon_g_c) or landscape_average_shoot_carbon_g_c < 0)
        return error.InvalidGrazingRuntimeInput;
    const layers = context.canopy_layer_state orelse return error.IncompleteGrazingContext;
    const branches = try state.branchRange(plant);
    const science = context.science_by_plant[plant];
    try group_validation.validateScience(science);
    try group_misc.preflightGrazing(context, plant, event, layers);
    const initial_product_carbon_g_c = group_misc.productLedgerCarbonG(context.products_by_plant[plant]);
    var stalk_area_m2: f64 = 0;
    for (branches.first..branches.end) |branch| {
        const first = branch * layers.layer_count;
        for (layers.branch_stalk_area_m2[first..][0..layers.layer_count]) |area| stalk_area_m2 += area;
    }
    const leaf_area_m2 = try layers.plantLeafAreaM2(state, plant);
    const demand_g_c = try canopy.sourceOrderGrazingCarbonDemandGPerH(
        event.kind == .animal_grazing,
        event.cutting_height_m_or_lai_fraction,
        event.thinning_fraction_or_consumption_rate,
        horizontal_cell_area_m2,
        leaf_area_m2 + stalk_area_m2,
        state.plant_uptake_growth_temperature_response[plant],
        state.plant_total_shoot_carbon_g[plant],
        landscape_average_shoot_carbon_g_c,
        context.plant_structural_presence_threshold_g_per_plant *
            state.plant_population_count[plant],
    );
    const pools: canopy.GrazingPools = .{
        .leaf_carbon_g = group_misc.totalBranchPool(state, branches, "branch_leaf_carbon_g"),
        .sheath_carbon_g = group_misc.totalBranchPool(state, branches, "branch_sheath_carbon_g"),
        .husk_carbon_g = group_misc.totalBranchPool(state, branches, "branch_husk_carbon_g"),
        .ear_carbon_g = group_misc.totalBranchPool(state, branches, "branch_ear_carbon_g"),
        .grain_carbon_g = group_misc.totalBranchPool(state, branches, "branch_grain_carbon_g"),
        .stalk_carbon_g = group_misc.totalBranchPool(state, branches, "branch_stalk_carbon_g"),
        .reserve_carbon_g = group_misc.totalBranchPool(state, branches, "branch_reserve_carbon_g"),
    };
    const allocation = try canopy.allocateGrazingDemand(
        demand_g_c,
        event.harvested_fraction.leaf,
        event.harvested_fraction.nonfoliar,
        event.harvested_fraction.woody,
        state.plant_mobile_carbon_concentration_g_per_g[plant],
        state.plant_symbiont_mobile_carbon_concentration_g_per_g[plant],
        pools,
    );

    // GROSUB 9865/9855/9845: canopy layers top-to-bottom, branches in
    // source order, and nodes newest-to-oldest. Each branch-layer receives
    // its share of the plant leaf demand from its pre-removal carbon.
    const angular_count = try std.math.mul(usize, layers.inclination_count, layers.azimuth_count);
    var layer_cursor = layers.layer_count;
    while (layer_cursor > 0) {
        layer_cursor -= 1;
        const layer = layer_cursor;
        for (branches.first..branches.end) |branch| {
            const nodes = try state.nodeRange(branch);
            var branch_layer_carbon_g_c: f64 = 0;
            for (nodes.first..nodes.end) |node|
                branch_layer_carbon_g_c += layers.node_leaf_carbon_g[node * layers.layer_count + layer];
            var branch_layer_demand_g_c = try canopy.sourceOrderBranchLayerLeafDemand(
                pools.leaf_carbon_g,
                allocation.structural_leaf_carbon_g,
                branch_layer_carbon_g_c,
                context.plant_structural_presence_threshold_g_per_plant *
                    state.plant_population_count[plant],
            );
            var node_cursor = nodes.end;
            while (node_cursor > nodes.first and branch_layer_demand_g_c > 0) {
                node_cursor -= 1;
                const node = node_cursor;
                const node_layer_carbon_g_c = layers.node_leaf_carbon_g[node * layers.layer_count + layer];
                if (node_layer_carbon_g_c <= 0) continue;
                const removed_carbon_g_c = @min(branch_layer_demand_g_c, node_layer_carbon_g_c);
                const leaf_remaining = std.math.clamp(1 - removed_carbon_g_c / node_layer_carbon_g_c, 0, 1);
                for (0..angular_count) |angular| {
                    const sample = layer * angular_count + angular;
                    const retention: canopy.LayerHarvestRetention = .{
                        .remaining_fraction = leaf_remaining,
                        .unexported_fraction = leaf_remaining + (1 - leaf_remaining) * (1 - event.ecosystem_export_fraction.leaf),
                        .height_below_cut_fraction = leaf_remaining,
                    };
                    const removed = try canopy.harvestLeafLayerSample(
                        state,
                        branch,
                        node - nodes.first,
                        sample,
                        retention,
                        science.carbon_woody_fraction,
                        science.leaf_nitrogen_woody_fraction,
                        science.leaf_phosphorus_woody_fraction,
                        node - nodes.first == 1,
                    );
                    group_misc.addProducts(&context.products_by_plant[plant].foliar, removed.foliar);
                    group_misc.addProducts(&context.products_by_plant[plant].woody, removed.woody);
                }
                branch_layer_demand_g_c = @max(0, branch_layer_demand_g_c - removed_carbon_g_c);
            }
        }
    }

    for (branches.first..branches.end) |branch| {
        const nodes = try state.nodeRange(branch);
        var initial_branch_leaf_carbon_g_c: f64 = 0;
        for (nodes.first..nodes.end) |node| {
            const first = node * layers.layer_count;
            for (layers.node_leaf_carbon_g[first..][0..layers.layer_count]) |carbon_g_c|
                initial_branch_leaf_carbon_g_c += carbon_g_c;
        }
        const initial_branch_sheath_carbon_g_c = state.branch_sheath_carbon_g[branch];
        var branch_sheath_demand_g_c = if (pools.sheath_carbon_g > 0)
            allocation.structural_sheath_carbon_g * initial_branch_sheath_carbon_g_c / pools.sheath_carbon_g
        else
            0;
        var node_cursor = nodes.end;
        while (node_cursor > nodes.first and branch_sheath_demand_g_c > 0) {
            node_cursor -= 1;
            const node = node_cursor;
            const initial_sheath_carbon_g_c = state.node_sheath_carbon_g[node];
            if (initial_sheath_carbon_g_c <= 0) continue;
            const removed_carbon_g_c = @min(branch_sheath_demand_g_c, initial_sheath_carbon_g_c);
            const sheath_remaining = std.math.clamp(1 - removed_carbon_g_c / initial_sheath_carbon_g_c, 0, 1);
            const removed = try canopy.harvestNodeSheath(
                state,
                branch,
                node - nodes.first,
                sheath_remaining,
                sheath_remaining + (1 - sheath_remaining) * (1 - event.ecosystem_export_fraction.nonfoliar),
                science.carbon_woody_fraction,
                science.sheath_nitrogen_woody_fraction,
                science.sheath_phosphorus_woody_fraction,
                false,
                0,
            );
            group_misc.addProducts(&context.products_by_plant[plant].nonfoliar, removed.nonwoody);
            group_misc.addProducts(&context.products_by_plant[plant].woody, removed.woody);
            branch_sheath_demand_g_c = @max(0, branch_sheath_demand_g_c - removed_carbon_g_c);
        }

        const total_leaf_sheath_carbon_g_c = pools.leaf_carbon_g + pools.sheath_carbon_g;
        const branch_share = if (total_leaf_sheath_carbon_g_c >
            context.plant_tissue_presence_threshold_g_per_plant *
                state.plant_population_count[plant])
            @max(0, initial_branch_leaf_carbon_g_c + initial_branch_sheath_carbon_g_c) / total_leaf_sheath_carbon_g_c
        else
            0;
        const branch_mobile_target_g_c = allocation.mobile_carbon_g * branch_share;
        const branch_mobile_carbon_g_c = state.branch_mobile_carbon_g[branch];
        const host_mobile = try canopy.sourceOrderProportionalMobileRemoval(
            .{
                .carbon_g = branch_mobile_carbon_g_c,
                .nitrogen_g = state.branch_mobile_nitrogen_g[branch],
                .phosphorus_g = state.branch_mobile_phosphorus_g[branch],
            },
            branch_mobile_target_g_c,
            context.plant_structural_presence_threshold_g_per_plant *
                state.plant_population_count[plant],
        );
        const mobile_remaining = if (branch_mobile_carbon_g_c > 0)
            host_mobile.remaining.carbon_g / branch_mobile_carbon_g_c
        else
            0;
        const is_c4 = if (context.canopy_biochemistry_parameters_by_plant) |parameters|
            parameters[plant].pathway == .c4
        else
            true;
        const intermediate_remaining = try canopy.sourceOrderC4IntermediateRetention(
            is_c4,
            branch_mobile_carbon_g_c,
            host_mobile.remaining.carbon_g,
            context.plant_structural_presence_threshold_g_per_plant *
                state.plant_population_count[plant],
        );
        const mobile_removed = try canopy.harvestBranchMobilePoolsWithIntermediateRetention(
            state,
            branch,
            mobile_remaining,
            intermediate_remaining,
        );
        group_misc.routeGrazedMass(&context.products_by_plant[plant].nonfoliar, mobile_removed, event.ecosystem_export_fraction.nonfoliar);

        const branch_symbiont_target_g_c = allocation.symbiont_mobile_carbon_g * branch_share;
        const branch_symbiont_mobile_carbon_g_c = state.branch_symbiont_mobile_carbon_g[branch];
        const symbiont_mobile = try canopy.sourceOrderProportionalMobileRemoval(
            .{
                .carbon_g = branch_symbiont_mobile_carbon_g_c,
                .nitrogen_g = state.branch_symbiont_mobile_nitrogen_g[branch],
                .phosphorus_g = state.branch_symbiont_mobile_phosphorus_g[branch],
            },
            branch_symbiont_target_g_c,
            context.plant_structural_presence_threshold_g_per_plant *
                state.plant_population_count[plant],
        );
        const symbiont_remaining = if (branch_symbiont_mobile_carbon_g_c > 0)
            std.math.clamp(
                symbiont_mobile.remaining.carbon_g / branch_symbiont_mobile_carbon_g_c,
                0,
                1,
            )
        else
            0;
        var symbiont_removed: canopy.ElementalMass = .{};
        inline for (
            .{
                "branch_symbiont_mobile_carbon_g",     "branch_symbiont_mobile_nitrogen_g",     "branch_symbiont_mobile_phosphorus_g",
                "branch_symbiont_structural_carbon_g", "branch_symbiont_structural_nitrogen_g", "branch_symbiont_structural_phosphorus_g",
            },
            .{ "carbon_g", "nitrogen_g", "phosphorus_g", "carbon_g", "nitrogen_g", "phosphorus_g" },
        ) |state_field, mass_field| {
            const initial = @field(state, state_field)[branch];
            @field(symbiont_removed, mass_field) += initial * (1 - symbiont_remaining);
            @field(state, state_field)[branch] = initial * symbiont_remaining;
        }
        group_misc.routeGrazedMass(&context.products_by_plant[plant].nonstructural, symbiont_removed, event.ecosystem_export_fraction.nonfoliar);
    }

    const reproductive_retention = try canopy.sourceOrderReproductiveRetention(.{
        .grazing = true,
        .reproductive_organs_reached_by_cut = false,
        .grain_or_pruning = false,
        .thinning_fraction = 0,
        .harvested_nonfoliar_fraction = 0,
        .total_husk_carbon_g_c = pools.husk_carbon_g,
        .total_ear_carbon_g_c = pools.ear_carbon_g,
        .total_grain_carbon_g_c = pools.grain_carbon_g,
        .grazed_husk_carbon_g_c = allocation.husk_carbon_g,
        .grazed_ear_carbon_g_c = allocation.ear_carbon_g,
        .grazed_grain_carbon_g_c = allocation.grain_carbon_g,
        .plant_presence_threshold_g_c = context.plant_structural_presence_threshold_g_per_plant *
            state.plant_population_count[plant],
    });
    for (branches.first..branches.end) |branch| {
        const reproductive = try canopy.harvestReproductiveOrgans(
            state,
            branch,
            reproductive_retention,
        );
        // products already contains husk, ear, and grain removal;
        // harvested_grain is a diagnostic subset and must not be added twice.
        group_misc.routeGrazedMass(&context.products_by_plant[plant].nonfoliar, reproductive.products.ecosystem_export, event.ecosystem_export_fraction.nonfoliar);
    }

    const plant_presence_threshold_g_c =
        context.plant_tissue_presence_threshold_g_per_plant *
        state.plant_population_count[plant];
    const stalk_remaining = if (pools.stalk_carbon_g > plant_presence_threshold_g_c)
        1 - group_misc.removalFraction(allocation.stalk_carbon_g, pools.stalk_carbon_g)
    else
        1;
    for (branches.first..branches.end) |branch| {
        const nodes = try state.nodeRange(branch);
        for (nodes.first..nodes.end) |node|
            try canopy.state_updateInternodeHarvest(state, branch, node - nodes.first, stalk_remaining, false, 0);
        // GROSUB applies WHVRVH independently to each branch reserve rather
        // than distributing it by the plant-total reserve pool.
        const branch_reserve_carbon_g_c = state.branch_reserve_carbon_g[branch];
        const reserve_retention = try canopy.sourceOrderStalkReserveRetention(
            true,
            state.branch_stalk_carbon_g[branch] * stalk_remaining,
            .{
                .remaining_fraction = stalk_remaining,
                .unexported_fraction = stalk_remaining,
                .height_below_cut_fraction = 0,
            },
            branch_reserve_carbon_g_c,
            allocation.reserve_carbon_g,
            context.plant_structural_presence_threshold_g_per_plant *
                state.plant_population_count[plant],
        );
        const reserve_remaining = reserve_retention.remaining_fraction;
        const removed = try canopy.harvestBranchStalkAndReserve(
            state,
            branch,
            stalk_remaining,
            stalk_remaining + (1 - stalk_remaining) * (1 - event.ecosystem_export_fraction.woody),
            reserve_remaining,
            reserve_remaining + (1 - reserve_remaining) * (1 - event.ecosystem_export_fraction.woody),
        );
        group_misc.addProducts(&context.products_by_plant[plant].woody, removed);
    }

    var returned_mass: canopy.ElementalMass = .{};
    inline for (.{ "foliar", "nonfoliar", "woody" }) |field_name| {
        group_misc.addMass(&returned_mass, @field(context.products_by_plant[plant], field_name).litter);
        @field(context.products_by_plant[plant], field_name).litter = .{};
    }

    var standing_dead_area_m2: f64 = 0;
    const standing_area_first = plant * layers.layer_count;
    for (layers.plant_standing_dead_area_m2[standing_area_first..][0..layers.layer_count]) |area_m2|
        standing_dead_area_m2 += area_m2;
    const standing_dead_demand_g_c = try grazing_manure.standingDeadDemandGPerH(
        event.kind,
        event.cutting_height_m_or_lai_fraction,
        event.thinning_fraction_or_consumption_rate,
        horizontal_cell_area_m2,
        standing_dead_area_m2,
        event.harvested_fraction.standing_dead,
    );
    const standing_dead_carbon_g_c =
        state.plant_standing_dead_carbon_g[plant] +
        state.plant_charcoal_carbon_g[plant];
    const standing_dead_remaining = if (standing_dead_carbon_g_c > 0)
        std.math.clamp(1 - standing_dead_demand_g_c / standing_dead_carbon_g_c, 0, 1)
    else
        1;
    const removed_standing_dead: canopy.ElementalMass = .{
        .carbon_g = state.plant_standing_dead_carbon_g[plant] * (1 - standing_dead_remaining),
        .nitrogen_g = state.plant_standing_dead_nitrogen_g[plant] * (1 - standing_dead_remaining),
        .phosphorus_g = state.plant_standing_dead_phosphorus_g[plant] * (1 - standing_dead_remaining),
    };
    const removed_standing_dead_charcoal: canopy.ElementalMass = .{
        .carbon_g = state.plant_charcoal_carbon_g[plant] * (1 - standing_dead_remaining),
        .nitrogen_g = state.plant_charcoal_nitrogen_g[plant] * (1 - standing_dead_remaining),
        .phosphorus_g = state.plant_charcoal_phosphorus_g[plant] * (1 - standing_dead_remaining),
    };
    inline for (.{
        "plant_standing_dead_carbon_g",
        "plant_standing_dead_nitrogen_g",
        "plant_standing_dead_phosphorus_g",
    }) |field_name| @field(state, field_name)[plant] *= standing_dead_remaining;
    inline for (.{
        "plant_charcoal_carbon_g",
        "plant_charcoal_nitrogen_g",
        "plant_charcoal_phosphorus_g",
    }) |field_name| @field(state, field_name)[plant] *= standing_dead_remaining;
    const kinetic_first = plant * 4;
    inline for (.{
        "plant_standing_dead_carbon_by_kinetic_g",
        "plant_standing_dead_nitrogen_by_kinetic_g",
        "plant_standing_dead_phosphorus_by_kinetic_g",
    }) |field_name| {
        for (@field(state, field_name)[kinetic_first..][0..4]) |*value| value.* *= standing_dead_remaining;
    }
    const cell = plant / state.species_count;
    for (0..layers.layer_count) |layer| {
        const plant_layer = standing_area_first + layer;
        layers.plant_standing_dead_area_m2[plant_layer] *= standing_dead_remaining;
        layers.cell_standing_dead_area_m2[cell * layers.layer_count + layer] =
            try standingDeadAreaForCellLayer(layers, cell, state.species_count, layer);
        const projected_first = plant_layer * layers.inclination_count;
        for (layers.plant_standing_dead_projected_surface_m2[projected_first..][0..layers.inclination_count]) |*area_m2|
            area_m2.* *= standing_dead_remaining;
    }
    group_misc.addScaledMass(&context.products_by_plant[plant].standing_dead_export, removed_standing_dead, event.ecosystem_export_fraction.standing_dead);
    group_misc.addScaledMass(&context.products_by_plant[plant].standing_dead_export, removed_standing_dead_charcoal, event.ecosystem_export_fraction.standing_dead);
    group_misc.addScaledMass(&returned_mass, removed_standing_dead, 1 - event.ecosystem_export_fraction.standing_dead);
    group_misc.addScaledMass(&returned_mass, removed_standing_dead_charcoal, 1 - event.ecosystem_export_fraction.standing_dead);
    if (returned_mass.carbon_g > 0 or returned_mass.nitrogen_g > 0 or returned_mass.phosphorus_g > 0)
        try grazing_manure.add(&context.products_by_plant[plant].manure, try grazing_manure.partition(event.kind, returned_mass));

    try state.validateFinite();
    const removed_product_carbon_g_c = group_misc.productLedgerCarbonG(context.products_by_plant[plant]) - initial_product_carbon_g_c;
    if (!std.math.isFinite(removed_product_carbon_g_c) or removed_product_carbon_g_c < 0)
        return error.InvalidGrazingProductBalance;
    return removed_product_carbon_g_c;
}

pub fn applyRootSymbiontHarvest(context: *group_misc.Context, plant: usize, remaining_fraction: f64) !void {
    if (remaining_fraction == 1) return;
    const roots = context.root_state orelse return;
    const partitions = context.root_litter_partition orelse return error.IncompleteRootHarvestContext;
    const organic = context.soil_organic_state orelse return error.IncompleteRootHarvestContext;
    const grid = context.grid orelse return error.IncompleteRootHarvestContext;
    if (plant >= roots.plant_count or plant >= partitions.plant_count or plant >= context.science_by_plant.len) return error.PlantHarvestIndexOutOfBounds;
    if (!std.math.isFinite(remaining_fraction) or remaining_fraction < 0 or remaining_fraction > 1) return error.InvalidRootHarvestRetention;
    const cell = plant / context.canopy_state.species_count;
    if (cell >= grid.cell_count) return error.PlantHarvestIndexOutOfBounds;
    const fine = try partitions.get(plant, .fine_root);
    const coarse = try partitions.get(plant, .coarse_wood);
    const mobile = try partitions.get(plant, .nonstructural);
    const nitrogen_fixation_type = context.science_by_plant[plant].nitrogen_fixation_type;
    const compositions = context.belowground_harvest_composition_by_plant orelse
        return error.IncompleteBelowgroundHarvestComposition;
    if (plant >= compositions.len) return error.PlantHarvestIndexOutOfBounds;
    const composition = compositions[plant];
    try composition.validate();
    const retention = root_disturbance.ElementRetention.uniform(remaining_fraction);
    const woody_fraction: root_disturbance.ElementRetention = .{
        .carbon = composition.root_woody_nonwoody.carbon[0],
        .nitrogen = composition.root_woody_nonwoody.nitrogen[0],
        .phosphorus = composition.root_woody_nonwoody.phosphorus[0],
    };
    const planting_layer = roots.planting_layer_by_plant[plant];
    if (planting_layer >= grid.active_soil_layer_count[cell]) return error.PlantRootLayerOutOfBounds;
    const storage_result = try storage_remobilization.sourceOrderPerennialStorageHarvest(
        composition.perennial,
        .{
            .carbon_g_c = context.canopy_state.plant_seed_storage_carbon_g[plant],
            .nitrogen_g_n = context.canopy_state.plant_seed_storage_nitrogen_g[plant],
            .phosphorus_g_p = context.canopy_state.plant_seed_storage_phosphorus_g[plant],
        },
        .{ .carbon = remaining_fraction, .nitrogen = remaining_fraction, .phosphorus = remaining_fraction },
        .{
            .carbon_woody_nonwoody = composition.storage_woody_nonwoody.carbon,
            .nitrogen_woody_nonwoody = composition.storage_woody_nonwoody.nitrogen,
            .phosphorus_woody_nonwoody = composition.storage_woody_nonwoody.phosphorus,
        },
        mobile,
    );
    var removed_host_carbon_g_c: f64 = 0;

    // Validate every soil state_update before changing any root or soil pool.
    for (0..grid.active_soil_layer_count[cell]) |layer| {
        const root = try roots.layerIndex(plant, 0, layer);
        const result = try group_harvest.noduleHarvestResult(
            nitrogen_fixation_type,
            .{
                .carbon_g_c = roots.symbiont_structural_carbon_g_c[root],
                .nitrogen_g_n = roots.symbiont_structural_nitrogen_g_n[root],
                .phosphorus_g_p = roots.symbiont_structural_phosphorus_g_p[root],
            },
            .{
                .carbon_g_c = roots.symbiont_mobile_carbon_g_c[root],
                .nitrogen_g_n = roots.symbiont_mobile_nitrogen_g_n[root],
                .phosphorus_g_p = roots.symbiont_mobile_phosphorus_g_p[root],
            },
            remaining_fraction,
            fine,
            mobile,
        );
        var state_update: root_litterfall.LayerInput = .{};
        try state_update.add(result.litterfall);
        const host = try group_harvest.hostLayerHarvest(roots, plant, layer, retention, woody_fraction, fine, coarse, mobile);
        try state_update.add(host.litterfall);
        if (layer == planting_layer) try state_update.add(storage_result.litterfall);
        removed_host_carbon_g_c += host.removed.carbon_g_c;
        if (context.root_litter_carbon_ledger) |ledger| {
            const host_domain_zero = try group_harvest.hostLayerHarvestDomain(roots, plant, 0, layer, retention, woody_fraction, fine, coarse, mobile);
            const host_domain_one = try group_harvest.hostLayerHarvestDomain(roots, plant, 1, layer, retention, woody_fraction, fine, coarse, mobile);
            try ledger.validateCarbonAdd(
                plant,
                0,
                layer,
                try root_litter_ledger.totalCarbon(host_domain_zero.litterfall) +
                    try root_litter_ledger.totalCarbon(result.litterfall) +
                    if (layer == planting_layer) try root_litter_ledger.totalCarbon(storage_result.litterfall) else 0,
            );
            try ledger.validateCarbonAdd(
                plant,
                1,
                layer,
                try root_litter_ledger.totalCarbon(host_domain_one.litterfall),
            );
        }
        try group_harvest.validateHostLayerHarvestState(roots, plant, layer, retention);
        try root_disturbance.validateRootGasRelease(roots, plant, layer, 1 - remaining_fraction);
        try root_litterfall.validateStateUpdate(organic, try grid.layerIndex(cell, layer), state_update);
    }
    if (!std.math.isFinite(removed_host_carbon_g_c)) return error.NonFiniteRootHarvest;
    if (context.carbon_exchange_state) |exchange| {
        const branches = try context.canopy_state.branchRange(plant);
        if (branches.first >= branches.end or exchange.branchCount() != context.canopy_state.branch_node_offsets.len - 1) return error.CanopyCarbonExchangeDimensionMismatch;
        const next = exchange.disturbance_carbon_g_c_per_h[branches.first] + removed_host_carbon_g_c;
        if (!std.math.isFinite(next)) return error.NonFiniteRootHarvest;
    }
    context.canopy_state.plant_seed_storage_carbon_g[plant] = storage_result.remaining.carbon_g_c;
    context.canopy_state.plant_seed_storage_nitrogen_g[plant] = storage_result.remaining.nitrogen_g_n;
    context.canopy_state.plant_seed_storage_phosphorus_g[plant] = storage_result.remaining.phosphorus_g_p;
    for (0..grid.active_soil_layer_count[cell]) |layer| {
        const root = roots.layerIndex(plant, 0, layer) catch unreachable;
        const soil = grid.layerIndex(cell, layer) catch unreachable;
        const result = group_harvest.noduleHarvestResult(
            nitrogen_fixation_type,
            .{
                .carbon_g_c = roots.symbiont_structural_carbon_g_c[root],
                .nitrogen_g_n = roots.symbiont_structural_nitrogen_g_n[root],
                .phosphorus_g_p = roots.symbiont_structural_phosphorus_g_p[root],
            },
            .{
                .carbon_g_c = roots.symbiont_mobile_carbon_g_c[root],
                .nitrogen_g_n = roots.symbiont_mobile_nitrogen_g_n[root],
                .phosphorus_g_p = roots.symbiont_mobile_phosphorus_g_p[root],
            },
            remaining_fraction,
            fine,
            mobile,
        ) catch unreachable;
        var host_litter_by_domain = [_]@import("../plant/root/plant_root_metabolism.zig").RootLitter{
            std.mem.zeroes(@import("../plant/root/plant_root_metabolism.zig").RootLitter),
            std.mem.zeroes(@import("../plant/root/plant_root_metabolism.zig").RootLitter),
        };
        for (0..root_system.biological_domain_count) |domain|
            host_litter_by_domain[domain] = (group_harvest.hostLayerHarvestDomain(
                roots,
                plant,
                domain,
                layer,
                retention,
                woody_fraction,
                fine,
                coarse,
                mobile,
            ) catch unreachable).litterfall;
        roots.symbiont_structural_carbon_g_c[root] = result.structural.carbon_g_c;
        roots.symbiont_structural_nitrogen_g_n[root] = result.structural.nitrogen_g_n;
        roots.symbiont_structural_phosphorus_g_p[root] = result.structural.phosphorus_g_p;
        roots.symbiont_mobile_carbon_g_c[root] = result.mobile.carbon_g_c;
        roots.symbiont_mobile_nitrogen_g_n[root] = result.mobile.nitrogen_g_n;
        roots.symbiont_mobile_phosphorus_g_p[root] = result.mobile.phosphorus_g_p;
        var state_update: root_litterfall.LayerInput = .{};
        state_update.add(result.litterfall) catch unreachable;
        const host = group_harvest.hostLayerHarvest(roots, plant, layer, retention, woody_fraction, fine, coarse, mobile) catch unreachable;
        state_update.add(host.litterfall) catch unreachable;
        if (layer == planting_layer) state_update.add(storage_result.litterfall) catch unreachable;
        group_harvest.state_updateHostLayerHarvest(roots, plant, layer, retention);
        root_disturbance.releaseRootGasFraction(roots, plant, layer, 1 - remaining_fraction) catch unreachable;
        root_litterfall.publishValidated(organic, soil, state_update);
        if (context.root_litter_carbon_ledger) |ledger| {
            for (0..root_system.biological_domain_count) |domain|
                ledger.addValidated(plant, domain, layer, host_litter_by_domain[domain]);
            ledger.addValidated(plant, 0, layer, result.litterfall);
            if (layer == planting_layer) ledger.addValidated(plant, 0, layer, storage_result.litterfall);
        }
    }
    if (context.carbon_exchange_state) |exchange| {
        const branches = context.canopy_state.branchRange(plant) catch unreachable;
        exchange.disturbance_carbon_g_c_per_h[branches.first] += removed_host_carbon_g_c;
    }
}
