//! `photosynthesis` declarations: reproductive.
//!
//! Split out of `photosynthesis.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const c4_mesophyll_bundle_exchange = @import("c4_mesophyll_bundle_exchange.zig");
const branch_organ_growth_state_update = @import("../../plant/growth/branch_organ_growth_state_update.zig");
const leaf_node_growth_state_update = @import("../leaf/node_growth_state_update.zig");
const shoot_recycling_fraction = @import("../../plant/growth/shoot_recycling_fraction.zig");
const reserve_maintenance_respiration = @import("../../plant/growth/reserve_maintenance_respiration.zig");
const shoot_total_senescence_setup = @import("../../plant/growth/shoot_total_senescence_setup.zig");
const node_senescence_remobilization_request = @import("../../plant/growth/node_senescence_remobilization_request.zig");
const c4_leaf_nonstructural_carbon_senescence = @import("../leaf/c4_nonstructural_carbon_senescence.zig");
const node_senescence_cascade_progress = @import("../../plant/growth/node_senescence_cascade_progress.zig");
const perennial_stalk_senescence_setup = @import("../../plant/growth/perennial_stalk_senescence_setup.zig");
const internode_senescence_state_update = @import("../sheath/internode_senescence_state_update.zig");
const residual_stalk_senescence_request = @import("../../plant/growth/residual_stalk_senescence_request.zig");
const residual_stalk_senescence_state_update = @import("../../plant/growth/residual_stalk_senescence_state_update.zig");
const group_node_layer = @import("photosynthesis_node_layer.zig");
const group_organ_growth = @import("photosynthesis_organ_growth.zig");
const group_state = @import("photosynthesis_state.zig");

pub const PersistentReseedInventories = struct {
    seed_storage: group_state.ElementalMass,
    standing_dead: group_state.ElementalMass,
    charcoal: group_state.ElementalMass,
    standing_dead_height_m: f64,
    standing_dead_carbon_by_kinetic_g: [4]f64,
    standing_dead_nitrogen_by_kinetic_g: [4]f64,
    standing_dead_phosphorus_by_kinetic_g: [4]f64,
    standing_dead_aerodynamic_temperature_k: f64,
    standing_dead_aerodynamic_vapor_pressure_kpa: f64,
    standing_dead_surface_temperature_k: f64,
    thermal_adaptation_offset_c: f64,
    leafout_threshold_c: f64,
    leafoff_threshold_c: f64,
    seed_set_high_temperature_c: f64,
};

pub fn capturePersistentReseedInventories(state: *const group_state.State, plant: usize) !PersistentReseedInventories {
    if (plant >= state.plant_seed_storage_carbon_g.len) return error.CanopyPlantIndexOutOfBounds;
    const first = plant * 4;
    var result: PersistentReseedInventories = .{
        .seed_storage = .{ .carbon_g = state.plant_seed_storage_carbon_g[plant], .nitrogen_g = state.plant_seed_storage_nitrogen_g[plant], .phosphorus_g = state.plant_seed_storage_phosphorus_g[plant] },
        .standing_dead = .{ .carbon_g = state.plant_standing_dead_carbon_g[plant], .nitrogen_g = state.plant_standing_dead_nitrogen_g[plant], .phosphorus_g = state.plant_standing_dead_phosphorus_g[plant] },
        .charcoal = .{ .carbon_g = state.plant_charcoal_carbon_g[plant], .nitrogen_g = state.plant_charcoal_nitrogen_g[plant], .phosphorus_g = state.plant_charcoal_phosphorus_g[plant] },
        .standing_dead_height_m = state.plant_standing_dead_height_m[plant],
        .standing_dead_carbon_by_kinetic_g = undefined,
        .standing_dead_nitrogen_by_kinetic_g = undefined,
        .standing_dead_phosphorus_by_kinetic_g = undefined,
        .standing_dead_aerodynamic_temperature_k = state.plant_standing_dead_aerodynamic_temperature_k[plant],
        .standing_dead_aerodynamic_vapor_pressure_kpa = state.plant_standing_dead_aerodynamic_vapor_pressure_kpa[plant],
        .standing_dead_surface_temperature_k = state.plant_standing_dead_surface_temperature_k[plant],
        .thermal_adaptation_offset_c = state.plant_thermal_adaptation_offset_c[plant],
        .leafout_threshold_c = state.plant_leafout_threshold_c[plant],
        .leafoff_threshold_c = state.plant_leafoff_threshold_c[plant],
        .seed_set_high_temperature_c = state.plant_seed_set_high_temperature_c[plant],
    };
    @memcpy(&result.standing_dead_carbon_by_kinetic_g, state.plant_standing_dead_carbon_by_kinetic_g[first..][0..4]);
    @memcpy(&result.standing_dead_nitrogen_by_kinetic_g, state.plant_standing_dead_nitrogen_by_kinetic_g[first..][0..4]);
    @memcpy(&result.standing_dead_phosphorus_by_kinetic_g, state.plant_standing_dead_phosphorus_by_kinetic_g[first..][0..4]);
    inline for (@typeInfo(PersistentReseedInventories).@"struct".fields) |field| switch (field.type) {
        f64 => if (!std.math.isFinite(@field(result, field.name))) return error.NonFinitePersistentReseedInventory,
        [4]f64 => for (@field(result, field.name)) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPersistentReseedInventory,
        group_state.ElementalMass => inline for (@typeInfo(group_state.ElementalMass).@"struct".fields) |mass_field| if (!std.math.isFinite(@field(@field(result, field.name), mass_field.name)) or @field(@field(result, field.name), mass_field.name) < 0) return error.InvalidPersistentReseedInventory,
        else => unreachable,
    };
    return result;
}

pub fn restorePersistentReseedInventories(state: *group_state.State, plant: usize, inventories: PersistentReseedInventories) !void {
    if (plant >= state.plant_seed_storage_carbon_g.len) return error.CanopyPlantIndexOutOfBounds;
    state.plant_seed_storage_carbon_g[plant] = inventories.seed_storage.carbon_g;
    state.plant_seed_storage_nitrogen_g[plant] = inventories.seed_storage.nitrogen_g;
    state.plant_seed_storage_phosphorus_g[plant] = inventories.seed_storage.phosphorus_g;
    state.plant_standing_dead_carbon_g[plant] = inventories.standing_dead.carbon_g;
    state.plant_standing_dead_nitrogen_g[plant] = inventories.standing_dead.nitrogen_g;
    state.plant_standing_dead_phosphorus_g[plant] = inventories.standing_dead.phosphorus_g;
    state.plant_charcoal_carbon_g[plant] = inventories.charcoal.carbon_g;
    state.plant_charcoal_nitrogen_g[plant] = inventories.charcoal.nitrogen_g;
    state.plant_charcoal_phosphorus_g[plant] = inventories.charcoal.phosphorus_g;
    state.plant_standing_dead_height_m[plant] = inventories.standing_dead_height_m;
    const first = plant * 4;
    @memcpy(state.plant_standing_dead_carbon_by_kinetic_g[first..][0..4], &inventories.standing_dead_carbon_by_kinetic_g);
    @memcpy(state.plant_standing_dead_nitrogen_by_kinetic_g[first..][0..4], &inventories.standing_dead_nitrogen_by_kinetic_g);
    @memcpy(state.plant_standing_dead_phosphorus_by_kinetic_g[first..][0..4], &inventories.standing_dead_phosphorus_by_kinetic_g);
    state.plant_standing_dead_aerodynamic_temperature_k[plant] = inventories.standing_dead_aerodynamic_temperature_k;
    state.plant_standing_dead_aerodynamic_vapor_pressure_kpa[plant] = inventories.standing_dead_aerodynamic_vapor_pressure_kpa;
    state.plant_standing_dead_surface_temperature_k[plant] = inventories.standing_dead_surface_temperature_k;
    state.plant_thermal_adaptation_offset_c[plant] = inventories.thermal_adaptation_offset_c;
    state.plant_leafout_threshold_c[plant] = inventories.leafout_threshold_c;
    state.plant_leafoff_threshold_c[plant] = inventories.leafoff_threshold_c;
    state.plant_seed_set_high_temperature_c[plant] = inventories.seed_set_high_temperature_c;
}

pub const StalkGrowthResult = struct { stem_diameter_m: f64 };

pub fn accumulatePotentialSeedSites(current_site_count: f64, stem_elongation_started: bool, anthesis_started: bool, branch_shoot_carbon_g: f64, canopy_shoot_carbon_g: f64, canopy_shoot_growth_g_c_per_step: f64, potential_sites_per_g_growth: f64, structural_presence_threshold_g: f64) !f64 {
    inline for (.{ current_site_count, branch_shoot_carbon_g, canopy_shoot_carbon_g, canopy_shoot_growth_g_c_per_step, potential_sites_per_g_growth, structural_presence_threshold_g }) |value| if (!std.math.isFinite(value)) return error.NonFinitePotentialSeedSiteInput;
    if (current_site_count < 0 or branch_shoot_carbon_g < 0 or canopy_shoot_carbon_g < 0 or canopy_shoot_growth_g_c_per_step < 0 or potential_sites_per_g_growth < 0 or structural_presence_threshold_g < 0) return error.InvalidPotentialSeedSiteInput;
    if (!stem_elongation_started or anthesis_started or canopy_shoot_carbon_g <= structural_presence_threshold_g or canopy_shoot_growth_g_c_per_step <= structural_presence_threshold_g) return current_site_count;
    const branch_growth_g_c = canopy_shoot_growth_g_c_per_step * branch_shoot_carbon_g / canopy_shoot_carbon_g;
    return current_site_count + potential_sites_per_g_growth * branch_growth_g_c;
}

pub const SeedSetInputs = struct {
    anthesis_started: bool,
    grain_fill_started: bool,
    final_seed_number_set: bool,
    maximum_seed_size_set: bool,
    mobile_carbon_concentration_g_per_g: f64,
    mobile_nitrogen_concentration_g_per_g: f64,
    mobile_phosphorus_concentration_g_per_g: f64,
    carbon_half_saturation_g_per_g: f64,
    nitrogen_half_saturation_g_per_g: f64,
    phosphorus_half_saturation_g_per_g: f64,
    canopy_temperature_c: f64,
    chilling_temperature_c: f64,
    high_temperature_c: f64,
    seed_loss_fraction_per_c_h: f64,
    timestep_h: f64,
    water_growth_fraction: f64,
    reproductive_stage_increment: f64,
    maximum_seeds_per_site: f64,
    potential_site_count: f64,
    current_seed_count: f64,
    maximum_individual_seed_carbon_g: f64,
    current_individual_seed_carbon_g: f64,
};

pub const SeedSetParameters = struct {
    carbon_half_saturation_g_per_g: f64,
    nitrogen_half_saturation_g_per_g: f64,
    phosphorus_half_saturation_g_per_g: f64,

    pub fn validate(self: SeedSetParameters) !void {
        inline for (@typeInfo(SeedSetParameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value <= 0) return error.InvalidSeedSetParameter;
        }
    }
};

pub fn compatibilitySeedSetParameters() SeedSetParameters {
    return .{ .carbon_half_saturation_g_per_g = 2.5e-2, .nitrogen_half_saturation_g_per_g = 0.5e-2, .phosphorus_half_saturation_g_per_g = 0.1e-2 };
}

pub const SeedSetResult = struct {
    nutrient_set_fraction: f64,
    thermal_loss_fraction: f64,
    seed_count: f64,
    individual_seed_carbon_g: f64,
};

/// GROSUB SET/FGRNX/GRNOB/GRWTB update following anthesis.
pub fn updateSeedNumberAndSize(input: SeedSetInputs) !SeedSetResult {
    inline for (@typeInfo(SeedSetInputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(input, field.name))) return error.NonFiniteSeedSetInput;
    inline for (.{ input.mobile_carbon_concentration_g_per_g, input.mobile_nitrogen_concentration_g_per_g, input.mobile_phosphorus_concentration_g_per_g, input.carbon_half_saturation_g_per_g, input.nitrogen_half_saturation_g_per_g, input.phosphorus_half_saturation_g_per_g, input.seed_loss_fraction_per_c_h, input.timestep_h, input.water_growth_fraction, input.reproductive_stage_increment, input.maximum_seeds_per_site, input.potential_site_count, input.current_seed_count, input.maximum_individual_seed_carbon_g, input.current_individual_seed_carbon_g }) |value| if (value < 0) return error.InvalidSeedSetInput;
    if (input.timestep_h <= 0 or input.water_growth_fraction > 1) return error.InvalidSeedSetInput;
    if (!input.anthesis_started or input.maximum_seed_size_set) return .{
        .nutrient_set_fraction = 0,
        .thermal_loss_fraction = 0,
        .seed_count = input.current_seed_count,
        .individual_seed_carbon_g = input.current_individual_seed_carbon_g,
    };
    if (input.carbon_half_saturation_g_per_g + input.mobile_carbon_concentration_g_per_g <= 0 or input.nitrogen_half_saturation_g_per_g + input.mobile_nitrogen_concentration_g_per_g <= 0 or input.phosphorus_half_saturation_g_per_g + input.mobile_phosphorus_concentration_g_per_g <= 0) return error.InvalidSeedSetInput;
    const nutrient_set_fraction = @min(input.mobile_carbon_concentration_g_per_g / (input.mobile_carbon_concentration_g_per_g + input.carbon_half_saturation_g_per_g), @min(input.mobile_nitrogen_concentration_g_per_g / (input.mobile_nitrogen_concentration_g_per_g + input.nitrogen_half_saturation_g_per_g), input.mobile_phosphorus_concentration_g_per_g / (input.mobile_phosphorus_concentration_g_per_g + input.phosphorus_half_saturation_g_per_g)));
    var thermal_loss_fraction: f64 = 0;
    if (!input.grain_fill_started or !input.final_seed_number_set) {
        if (input.canopy_temperature_c < input.chilling_temperature_c)
            thermal_loss_fraction = input.seed_loss_fraction_per_c_h * (input.chilling_temperature_c - input.canopy_temperature_c) * input.timestep_h
        else if (input.canopy_temperature_c > input.high_temperature_c)
            thermal_loss_fraction = input.seed_loss_fraction_per_c_h * (input.canopy_temperature_c - input.high_temperature_c) * input.timestep_h;
    }
    var seed_count = input.current_seed_count;
    if (input.anthesis_started and !input.final_seed_number_set) {
        const nutrient_water_set = nutrient_set_fraction * std.math.pow(f64, input.water_growth_fraction, 0.25);
        const maximum_seed_count = input.maximum_seeds_per_site * input.potential_site_count;
        const candidate_seed_count = @min(maximum_seed_count, seed_count + maximum_seed_count * nutrient_water_set * input.reproductive_stage_increment - thermal_loss_fraction * seed_count);
        if (candidate_seed_count < 0) return error.NegativeSeedCount;
        seed_count = candidate_seed_count;
    }
    var individual_seed_carbon_g = input.current_individual_seed_carbon_g;
    if (input.grain_fill_started and !input.maximum_seed_size_set) {
        const nutrient_water_set = std.math.pow(f64, nutrient_set_fraction * input.water_growth_fraction, 0.25);
        individual_seed_carbon_g = @min(input.maximum_individual_seed_carbon_g, individual_seed_carbon_g + input.maximum_individual_seed_carbon_g * @max(0.5, nutrient_water_set) * input.reproductive_stage_increment);
    }
    return .{ .nutrient_set_fraction = nutrient_set_fraction, .thermal_loss_fraction = thermal_loss_fraction, .seed_count = seed_count, .individual_seed_carbon_g = individual_seed_carbon_g };
}

pub fn distributeStalkGrowth(state: *group_state.State, branch: usize, first_growing_node_within_branch: usize, last_growing_node_within_branch: usize, growth: group_organ_growth.LeafGrowth, etoliation_factor: f64, base_specific_internode_length_m_per_g_c: f64, minimum_stalk_carbon_per_cell_g: f64, plant_density_per_m2: f64, length_exponent: f64, turgor_expansion_fraction: f64, vertical_projection_fraction: f64, stalk_volume_m3_per_g_c: f64) !StalkGrowthResult {
    inline for (.{ growth.carbon_g, growth.nitrogen_g, growth.phosphorus_g, etoliation_factor, base_specific_internode_length_m_per_g_c, minimum_stalk_carbon_per_cell_g, plant_density_per_m2, length_exponent, turgor_expansion_fraction, vertical_projection_fraction, stalk_volume_m3_per_g_c }) |value| if (!std.math.isFinite(value)) return error.NonFiniteStalkGrowthInput;
    if (growth.carbon_g < 0 or growth.nitrogen_g < 0 or growth.phosphorus_g < 0 or etoliation_factor < 0 or base_specific_internode_length_m_per_g_c < 0 or minimum_stalk_carbon_per_cell_g < 0 or plant_density_per_m2 <= 0 or turgor_expansion_fraction < 0 or vertical_projection_fraction < 0 or stalk_volume_m3_per_g_c < 0) return error.InvalidStalkGrowthInput;
    const nodes = try state.nodeRange(branch);
    if (last_growing_node_within_branch >= nodes.end - nodes.first or first_growing_node_within_branch > last_growing_node_within_branch) return error.CanopyNodeIndexOutOfBounds;
    const first = first_growing_node_within_branch;
    const count = last_growing_node_within_branch - first + 1;
    const allocation = 1.0 / @as(f64, @floatFromInt(count));
    for (first..last_growing_node_within_branch + 1) |local_node| {
        const node = nodes.first + local_node;
        const carbon = allocation * growth.carbon_g;
        state.node_internode_carbon_g[node] += carbon;
        state.node_internode_nitrogen_g[node] += allocation * growth.nitrogen_g;
        state.node_internode_phosphorus_g[node] += allocation * growth.phosphorus_g;
        const specific_length = @sqrt(etoliation_factor) * base_specific_internode_length_m_per_g_c * std.math.pow(f64, @max(minimum_stalk_carbon_per_cell_g, state.node_internode_carbon_g[node]) / plant_density_per_m2, length_exponent) * turgor_expansion_fraction;
        state.node_internode_length_m[node] += carbon / plant_density_per_m2 * specific_length * vertical_projection_fraction;
        state.node_height_m[node] = state.node_internode_length_m[node] + if (local_node > 0) state.node_height_m[node - 1] else 0;
    }
    const diagnostic_node = nodes.first + first;
    const previous_height = if (first > 0) state.node_height_m[diagnostic_node - 1] else 0;
    const height_difference = state.node_height_m[diagnostic_node] - previous_height;
    var diameter: f64 = 0;
    if (height_difference > 0 and state.node_internode_carbon_g[diagnostic_node] > 0) {
        const radius = @sqrt(stalk_volume_m3_per_g_c * (state.node_internode_carbon_g[diagnostic_node] / plant_density_per_m2) / (3.1416 * height_difference));
        diameter = 2.0 * radius;
        // grosub.f:2443-2444,2469-2471: the exponent term uses K1=MOD(KK,25)
        // (wrapped into [1,25], with the MOD-zero case folded to 25), not the
        // raw unbounded node index KK itself. WGNODE/HTNODE are a fixed
        // 25-slot circular buffer in the Fortran reference (blk1cp.h:8); this
        // Zig translation uses a true dynamic per-branch node array, so the
        // wrap must be reproduced explicitly here for the exponent argument
        // even though it is no longer needed for storage indexing.
        if (first > 0) {
            const wrapped_raw = first % 25;
            const wrapped: usize = if (wrapped_raw == 0) 25 else wrapped_raw;
            if (wrapped > 1) diameter *= std.math.pow(f64, @as(f64, @floatFromInt(wrapped)), 0.167);
        }
    }
    return .{ .stem_diameter_m = diameter };
}

pub const GrainFillResult = struct {
    carbon_translocated_g: f64,
    nitrogen_translocated_g: f64,
    phosphorus_translocated_g: f64,
    maximum_carbon_translocation_g: f64,
};

pub const ReproductiveRetention = struct { husk_remaining: f64, husk_unexported: f64, ear_remaining: f64, ear_unexported: f64, grain_remaining: f64, grain_unexported: f64 };

/// Operands for the exact GROSUB 9532-9573 reproductive-organ selector.
pub const SourceOrderReproductiveRetentionInput = struct {
    grazing: bool,
    reproductive_organs_reached_by_cut: bool,
    grain_or_pruning: bool,
    thinning_fraction: f64,
    harvested_nonfoliar_fraction: f64,
    total_husk_carbon_g_c: f64,
    total_ear_carbon_g_c: f64,
    total_grain_carbon_g_c: f64,
    grazed_husk_carbon_g_c: f64,
    grazed_ear_carbon_g_c: f64,
    grazed_grain_carbon_g_c: f64,
    plant_presence_threshold_g_c: f64,
};

/// Preserves GROSUB's strict plant-level `ZEROP` gates and branch order.
pub fn sourceOrderReproductiveRetention(input: SourceOrderReproductiveRetentionInput) !ReproductiveRetention {
    inline for (.{
        input.thinning_fraction,
        input.harvested_nonfoliar_fraction,
        input.total_husk_carbon_g_c,
        input.total_ear_carbon_g_c,
        input.total_grain_carbon_g_c,
        input.grazed_husk_carbon_g_c,
        input.grazed_ear_carbon_g_c,
        input.grazed_grain_carbon_g_c,
        input.plant_presence_threshold_g_c,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteReproductiveHarvestInput;
    if (input.thinning_fraction < 0 or input.thinning_fraction > 1 or
        input.harvested_nonfoliar_fraction < 0 or input.harvested_nonfoliar_fraction > 1 or
        input.total_husk_carbon_g_c < 0 or input.total_ear_carbon_g_c < 0 or
        input.total_grain_carbon_g_c < 0 or input.grazed_husk_carbon_g_c < 0 or
        input.grazed_ear_carbon_g_c < 0 or input.grazed_grain_carbon_g_c < 0 or
        input.plant_presence_threshold_g_c < 0)
        return error.InvalidReproductiveHarvestInput;

    if (!input.grazing) {
        const reached = input.reproductive_organs_reached_by_cut or input.grain_or_pruning;
        const remaining = if (reached)
            if (input.thinning_fraction == 0)
                1 - input.harvested_nonfoliar_fraction
            else
                1 - input.thinning_fraction
        else
            1 - input.thinning_fraction;
        const unexported = if (reached and input.thinning_fraction != 0)
            1 - input.harvested_nonfoliar_fraction * input.thinning_fraction
        else
            remaining;
        return .{
            .husk_remaining = remaining,
            .husk_unexported = unexported,
            .ear_remaining = remaining,
            .ear_unexported = unexported,
            .grain_remaining = remaining,
            .grain_unexported = unexported,
        };
    }

    const husk_remaining = if (input.total_husk_carbon_g_c > input.plant_presence_threshold_g_c)
        std.math.clamp(1 - input.grazed_husk_carbon_g_c / input.total_husk_carbon_g_c, 0, 1)
    else
        1;
    const ear_remaining = if (input.total_ear_carbon_g_c > input.plant_presence_threshold_g_c)
        std.math.clamp(1 - input.grazed_ear_carbon_g_c / input.total_ear_carbon_g_c, 0, 1)
    else
        1;
    const grain_remaining = if (input.total_grain_carbon_g_c > input.plant_presence_threshold_g_c)
        std.math.clamp(1 - input.grazed_grain_carbon_g_c / input.total_grain_carbon_g_c, 0, 1)
    else
        1;
    return .{
        .husk_remaining = husk_remaining,
        .husk_unexported = husk_remaining,
        .ear_remaining = ear_remaining,
        .ear_unexported = ear_remaining,
        .grain_remaining = grain_remaining,
        .grain_unexported = grain_remaining,
    };
}

pub fn reproductiveRetention(grazing: bool, reproductive_organs_reached_by_cut: bool, grain_or_pruning: bool, thinning_fraction: f64, harvested_nonfoliar_fraction: f64, total_husk_carbon_g: f64, total_ear_carbon_g: f64, total_grain_carbon_g: f64, grazed_husk_carbon_g: f64, grazed_ear_carbon_g: f64, grazed_grain_carbon_g: f64) !ReproductiveRetention {
    inline for (.{ thinning_fraction, harvested_nonfoliar_fraction, total_husk_carbon_g, total_ear_carbon_g, total_grain_carbon_g, grazed_husk_carbon_g, grazed_ear_carbon_g, grazed_grain_carbon_g }) |value| if (!std.math.isFinite(value)) return error.NonFiniteReproductiveHarvestInput;
    if (thinning_fraction < 0 or thinning_fraction > 1 or harvested_nonfoliar_fraction < 0 or harvested_nonfoliar_fraction > 1 or total_husk_carbon_g < 0 or total_ear_carbon_g < 0 or total_grain_carbon_g < 0 or grazed_husk_carbon_g < 0 or grazed_ear_carbon_g < 0 or grazed_grain_carbon_g < 0) return error.InvalidReproductiveHarvestInput;
    if (grazing) return .{
        .husk_remaining = if (total_husk_carbon_g > 0) std.math.clamp(1.0 - grazed_husk_carbon_g / total_husk_carbon_g, 0, 1) else 1,
        .husk_unexported = if (total_husk_carbon_g > 0) std.math.clamp(1.0 - grazed_husk_carbon_g / total_husk_carbon_g, 0, 1) else 1,
        .ear_remaining = if (total_ear_carbon_g > 0) std.math.clamp(1.0 - grazed_ear_carbon_g / total_ear_carbon_g, 0, 1) else 1,
        .ear_unexported = if (total_ear_carbon_g > 0) std.math.clamp(1.0 - grazed_ear_carbon_g / total_ear_carbon_g, 0, 1) else 1,
        .grain_remaining = if (total_grain_carbon_g > 0) std.math.clamp(1.0 - grazed_grain_carbon_g / total_grain_carbon_g, 0, 1) else 1,
        .grain_unexported = if (total_grain_carbon_g > 0) std.math.clamp(1.0 - grazed_grain_carbon_g / total_grain_carbon_g, 0, 1) else 1,
    };
    const reached = reproductive_organs_reached_by_cut or grain_or_pruning;
    const remaining = if (reached) (if (thinning_fraction == 0) 1.0 - harvested_nonfoliar_fraction else 1.0 - thinning_fraction) else 1.0 - thinning_fraction;
    const unexported = if (reached and thinning_fraction != 0) 1.0 - harvested_nonfoliar_fraction * thinning_fraction else remaining;
    return .{ .husk_remaining = remaining, .husk_unexported = unexported, .ear_remaining = remaining, .ear_unexported = unexported, .grain_remaining = remaining, .grain_unexported = unexported };
}

/// Exact GROSUB 9339-9369 branch stalk retained-plant/ecosystem fractions.
pub fn sourceOrderBranchStalkRetention(
    grazing: bool,
    no_harvest_kind: bool,
    pruning: bool,
    maximum_internode_height_m: f64,
    cutting_height_m: f64,
    thinning_fraction: f64,
    woody_harvest_fraction: f64,
    total_stalk_carbon_g_c: f64,
    allocated_woody_demand_g_c: f64,
    removed_stalk_carbon_g_c: f64,
    plant_presence_threshold_g_c: f64,
) !group_node_layer.LayerHarvestRetention {
    inline for (.{
        maximum_internode_height_m,
        cutting_height_m,
        thinning_fraction,
        woody_harvest_fraction,
        total_stalk_carbon_g_c,
        allocated_woody_demand_g_c,
        removed_stalk_carbon_g_c,
        plant_presence_threshold_g_c,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidInternodeHarvestInput;
    if (thinning_fraction > 1 or woody_harvest_fraction > 1) return error.InvalidInternodeHarvestInput;
    if (grazing) {
        const retention = if (total_stalk_carbon_g_c > plant_presence_threshold_g_c)
            @max(0, @min(1, 1 - (removed_stalk_carbon_g_c + allocated_woody_demand_g_c) / total_stalk_carbon_g_c))
        else
            1;
        return .{ .remaining_fraction = retention, .unexported_fraction = retention, .height_below_cut_fraction = 0 };
    }
    if (maximum_internode_height_m == 0)
        return .{ .remaining_fraction = 1, .unexported_fraction = 1, .height_below_cut_fraction = 1 };
    const height_fraction = if (pruning) 0 else @max(0, @min(1, cutting_height_m / maximum_internode_height_m));
    if (thinning_fraction == 0) {
        const retention = @max(0, 1 - (1 - height_fraction) * woody_harvest_fraction);
        return .{ .remaining_fraction = retention, .unexported_fraction = retention, .height_below_cut_fraction = height_fraction };
    }
    const remaining = @max(0, 1 - thinning_fraction);
    const unexported = if (no_harvest_kind)
        1 - (1 - height_fraction) * woody_harvest_fraction * thinning_fraction
    else
        remaining;
    return .{ .remaining_fraction = remaining, .unexported_fraction = unexported, .height_below_cut_fraction = height_fraction };
}

/// Exact GROSUB 9474-9490 reserve retention after branch stalk state_update.
pub fn sourceOrderStalkReserveRetention(
    grazing: bool,
    remaining_stalk_carbon_g_c: f64,
    stalk_retention: group_node_layer.LayerHarvestRetention,
    reserve_carbon_g_c: f64,
    removed_reserve_carbon_g_c: f64,
    plant_presence_threshold_g_c: f64,
) !group_node_layer.LayerHarvestRetention {
    inline for (.{ remaining_stalk_carbon_g_c, reserve_carbon_g_c, removed_reserve_carbon_g_c, plant_presence_threshold_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidHarvestMass;
    if (!grazing) {
        if (remaining_stalk_carbon_g_c > plant_presence_threshold_g_c) return stalk_retention;
        return .{ .remaining_fraction = 0, .unexported_fraction = 0, .height_below_cut_fraction = 0 };
    }
    const retention = if (reserve_carbon_g_c > plant_presence_threshold_g_c)
        @max(0, @min(1, 1 - removed_reserve_carbon_g_c / reserve_carbon_g_c))
    else
        0;
    return .{ .remaining_fraction = retention, .unexported_fraction = retention, .height_below_cut_fraction = 0 };
}

pub fn fillGrainFromReserve(state: *group_state.State, branch: usize, grain_fill_started: bool, final_seed_count: f64, maximum_seed_carbon_g: f64, grain_fill_g_c_per_seed_h_25c: f64, growth_temperature_factor: f64, timestep_h: f64, minimum_grain_nutrient_fraction: f64, maximum_grain_nitrogen_to_carbon_g_per_g: f64, maximum_grain_phosphorus_to_carbon_g_per_g: f64, reserve_nitrogen_half_saturation_g_per_g_c: f64, reserve_phosphorus_half_saturation_g_per_g_c: f64, grain_precursor_growth: group_organ_growth.LeafGrowth) !GrainFillResult {
    inline for (.{ final_seed_count, maximum_seed_carbon_g, grain_fill_g_c_per_seed_h_25c, growth_temperature_factor, timestep_h, minimum_grain_nutrient_fraction, maximum_grain_nitrogen_to_carbon_g_per_g, maximum_grain_phosphorus_to_carbon_g_per_g, reserve_nitrogen_half_saturation_g_per_g_c, reserve_phosphorus_half_saturation_g_per_g_c, grain_precursor_growth.carbon_g, grain_precursor_growth.nitrogen_g, grain_precursor_growth.phosphorus_g }) |value| if (!std.math.isFinite(value)) return error.NonFiniteGrainFillInput;
    if (branch >= state.branch_grain_carbon_g.len) return error.CanopyBranchIndexOutOfBounds;
    if (final_seed_count < 0 or maximum_seed_carbon_g < 0 or grain_fill_g_c_per_seed_h_25c < 0 or growth_temperature_factor < 0 or timestep_h <= 0 or minimum_grain_nutrient_fraction < 0 or minimum_grain_nutrient_fraction > 1 or maximum_grain_nitrogen_to_carbon_g_per_g <= 0 or maximum_grain_phosphorus_to_carbon_g_per_g <= 0 or reserve_nitrogen_half_saturation_g_per_g_c < 0 or reserve_phosphorus_half_saturation_g_per_g_c < 0 or grain_precursor_growth.carbon_g < 0 or grain_precursor_growth.nitrogen_g < 0 or grain_precursor_growth.phosphorus_g < 0) return error.InvalidGrainFillInput;
    if (!grain_fill_started) return .{ .carbon_translocated_g = 0, .nitrogen_translocated_g = 0, .phosphorus_translocated_g = 0, .maximum_carbon_translocation_g = 0 };
    const grain_c = state.branch_grain_carbon_g[branch];
    const grain_n = state.branch_grain_nitrogen_g[branch];
    const grain_p = state.branch_grain_phosphorus_g[branch];
    const reserve_c = state.branch_reserve_carbon_g[branch];
    const reserve_n = state.branch_reserve_nitrogen_g[branch];
    const reserve_p = state.branch_reserve_phosphorus_g[branch];
    inline for (.{ grain_c, grain_n, grain_p, reserve_c, reserve_n, reserve_p }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidGrainFillState;
    const sink_capacity = maximum_seed_carbon_g * final_seed_count;
    const maximum_fill = if (grain_c >= sink_capacity) 0 else @max(0.0, grain_fill_g_c_per_seed_h_25c * final_seed_count * @sqrt(growth_temperature_factor) * timestep_h);
    const nutrient_deficient = grain_n < minimum_grain_nutrient_fraction * maximum_grain_nitrogen_to_carbon_g_per_g * grain_c or grain_p < minimum_grain_nutrient_fraction * maximum_grain_phosphorus_to_carbon_g_per_g * grain_c;
    const actual_fill_ceiling = if (nutrient_deficient) 0 else maximum_fill;
    const maximum_carbon_translocation = @min(maximum_fill, reserve_c);
    const carbon_translocated = @min(actual_fill_ceiling, reserve_c);
    const responsive_fraction = 1.0 - minimum_grain_nutrient_fraction;
    var nitrogen_translocated: f64 = 0;
    if (reserve_n > 0) {
        const reserve_constraint = reserve_n / (reserve_n + reserve_nitrogen_half_saturation_g_per_g_c * reserve_c);
        const grain_ratio = minimum_grain_nutrient_fraction + responsive_fraction * std.math.clamp(reserve_constraint, 0, 1);
        // GROSUB 5181--5183 is a three-argument AMIN1.  The reserve term is
        // bounded below independently; the grain deficit is deliberately not.
        nitrogen_translocated = @min(maximum_carbon_translocation * maximum_grain_nitrogen_to_carbon_g_per_g, @min(@max(0.0, reserve_n * grain_ratio), (grain_c + carbon_translocated) * maximum_grain_nitrogen_to_carbon_g_per_g - grain_n));
    }
    var phosphorus_translocated: f64 = 0;
    if (reserve_p > 0) {
        const reserve_constraint = reserve_p / (reserve_p + reserve_phosphorus_half_saturation_g_per_g_c * reserve_c);
        const grain_ratio = minimum_grain_nutrient_fraction + responsive_fraction * std.math.clamp(reserve_constraint, 0, 1);
        // GROSUB 5191--5193 has the same source-ordered three-way minimum.
        phosphorus_translocated = @min(maximum_carbon_translocation * maximum_grain_phosphorus_to_carbon_g_per_g, @min(@max(0.0, reserve_p * grain_ratio), (grain_c + carbon_translocated) * maximum_grain_phosphorus_to_carbon_g_per_g - grain_p));
    }
    nitrogen_translocated = @min(nitrogen_translocated, phosphorus_translocated * maximum_grain_nitrogen_to_carbon_g_per_g / maximum_grain_phosphorus_to_carbon_g_per_g);
    phosphorus_translocated = @min(phosphorus_translocated, nitrogen_translocated * maximum_grain_phosphorus_to_carbon_g_per_g / maximum_grain_nitrogen_to_carbon_g_per_g);
    const next_reserve_c = reserve_c + grain_precursor_growth.carbon_g - carbon_translocated;
    const next_reserve_n = reserve_n + grain_precursor_growth.nitrogen_g - nitrogen_translocated;
    const next_reserve_p = reserve_p + grain_precursor_growth.phosphorus_g - phosphorus_translocated;
    const next_grain_c = grain_c + carbon_translocated;
    const next_grain_n = grain_n + nitrogen_translocated;
    const next_grain_p = grain_p + phosphorus_translocated;
    inline for (.{ next_reserve_c, next_reserve_n, next_reserve_p, next_grain_c, next_grain_n, next_grain_p }) |next|
        if (!std.math.isFinite(next)) return error.NonFiniteGrainFillResult;
    if (next_reserve_c < 0 or next_reserve_n < 0 or next_reserve_p < 0 or next_grain_c < 0 or next_grain_n < 0 or next_grain_p < 0) {
        std.log.err("grain fill exhausted reserve: branch={d} reserve_c_g={e} reserve_n_g={e} reserve_p_g={e}", .{ branch, next_reserve_c, next_reserve_n, next_reserve_p });
        return error.GrainFillExhaustedReserve;
    }
    state.branch_reserve_carbon_g[branch] = next_reserve_c;
    state.branch_reserve_nitrogen_g[branch] = next_reserve_n;
    state.branch_reserve_phosphorus_g[branch] = next_reserve_p;
    state.branch_grain_carbon_g[branch] = next_grain_c;
    state.branch_grain_nitrogen_g[branch] = next_grain_n;
    state.branch_grain_phosphorus_g[branch] = next_grain_p;
    return .{ .carbon_translocated_g = carbon_translocated, .nitrogen_translocated_g = nitrogen_translocated, .phosphorus_translocated_g = phosphorus_translocated, .maximum_carbon_translocation_g = maximum_carbon_translocation };
}
