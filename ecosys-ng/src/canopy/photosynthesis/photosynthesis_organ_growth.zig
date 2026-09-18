//! `photosynthesis` declarations: organ growth.
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
const group_state = @import("photosynthesis_state.zig");

pub const LeafGrowth = struct { carbon_g: f64, nitrogen_g: f64, phosphorus_g: f64 };

pub const Organ = enum(u8) { leaf, sheath, stalk, reserve, husk, ear, grain };

pub const organ_count = @typeInfo(Organ).@"enum".fields.len;

pub const OrganGrowth = struct {
    carbon_g: [organ_count]f64,
    nitrogen_g: [organ_count]f64,
    phosphorus_g: [organ_count]f64,
    total_shoot_carbon_production_g: f64,

    pub fn value(self: OrganGrowth, organ: Organ) LeafGrowth {
        const index = @intFromEnum(organ);
        return .{ .carbon_g = self.carbon_g[index], .nitrogen_g = self.nitrogen_g[index], .phosphorus_g = self.phosphorus_g[index] };
    }
};

/// GROSUB PART(1:7), organ growth yields, and organ N:C/P:C ratios.
pub fn calculateOrganGrowth(total_growth_carbon_consumption_g: f64, partition_fraction: [organ_count]f64, carbon_growth_yield_g_per_g_consumed: [organ_count]f64, nitrogen_to_carbon_g_per_g: [organ_count]f64, phosphorus_to_carbon_g_per_g: [organ_count]f64, minimum_leaf_nutrient_fraction: f64, nutrient_growth_constraint: f64, shoot_growth_yield_g_per_g_consumed: f64) !OrganGrowth {
    inline for (.{ total_growth_carbon_consumption_g, minimum_leaf_nutrient_fraction, nutrient_growth_constraint, shoot_growth_yield_g_per_g_consumed }) |value| if (!std.math.isFinite(value)) return error.NonFiniteOrganGrowthInput;
    if (total_growth_carbon_consumption_g < 0 or minimum_leaf_nutrient_fraction < 0 or minimum_leaf_nutrient_fraction > 1 or nutrient_growth_constraint < 0 or nutrient_growth_constraint > 1 or shoot_growth_yield_g_per_g_consumed < 0) return error.InvalidOrganGrowthInput;
    var result: OrganGrowth = .{ .carbon_g = @splat(0), .nitrogen_g = @splat(0), .phosphorus_g = @splat(0), .total_shoot_carbon_production_g = total_growth_carbon_consumption_g * shoot_growth_yield_g_per_g_consumed };
    var partition_sum: f64 = 0;
    for (0..organ_count) |index| {
        inline for (.{ partition_fraction[index], carbon_growth_yield_g_per_g_consumed[index], nitrogen_to_carbon_g_per_g[index], phosphorus_to_carbon_g_per_g[index] }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganGrowthInput;
        partition_sum += partition_fraction[index];
        result.carbon_g[index] = partition_fraction[index] * total_growth_carbon_consumption_g * carbon_growth_yield_g_per_g_consumed[index];
        const nutrient_factor = if (index == @intFromEnum(Organ.leaf)) minimum_leaf_nutrient_fraction + (1.0 - minimum_leaf_nutrient_fraction) * nutrient_growth_constraint else 1.0;
        result.nitrogen_g[index] = result.carbon_g[index] * nitrogen_to_carbon_g_per_g[index] * nutrient_factor;
        result.phosphorus_g[index] = result.carbon_g[index] * phosphorus_to_carbon_g_per_g[index] * nutrient_factor;
        inline for (.{ result.carbon_g[index], result.nitrogen_g[index], result.phosphorus_g[index] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteOrganGrowthResult;
    }
    if (!std.math.isFinite(partition_sum) or @abs(partition_sum - 1.0) > 1e-8) return error.OrganPartitionDoesNotSumToOne;
    if (!std.math.isFinite(result.total_shoot_carbon_production_g)) return error.NonFiniteOrganGrowthResult;
    return result;
}

/// StateUpdates the branch totals updated immediately after organ partitioning.
/// Grain allocation remains a later reserve→grain transaction, as in GROSUB.
pub fn applyBranchOrganGrowth(state: *group_state.State, branch: usize, growth: OrganGrowth) !void {
    try validateBranchOrganGrowthTransaction(state, branch, growth);
    try branch_organ_growth_state_update.publish(.{
        .leaf_carbon_g_c = state.branch_leaf_carbon_g,
        .sheath_carbon_g_c = state.branch_sheath_carbon_g,
        .stalk_carbon_g_c = state.branch_stalk_carbon_g,
        .reserve_carbon_g_c = state.branch_reserve_carbon_g,
        .husk_carbon_g_c = state.branch_husk_carbon_g,
        .ear_carbon_g_c = state.branch_ear_carbon_g,
        .leaf_nitrogen_g_n = state.branch_leaf_nitrogen_g,
        .sheath_nitrogen_g_n = state.branch_sheath_nitrogen_g,
        .stalk_nitrogen_g_n = state.branch_stalk_nitrogen_g,
        .reserve_nitrogen_g_n = state.branch_reserve_nitrogen_g,
        .husk_nitrogen_g_n = state.branch_husk_nitrogen_g,
        .ear_nitrogen_g_n = state.branch_ear_nitrogen_g,
        .leaf_phosphorus_g_p = state.branch_leaf_phosphorus_g,
        .sheath_phosphorus_g_p = state.branch_sheath_phosphorus_g,
        .stalk_phosphorus_g_p = state.branch_stalk_phosphorus_g,
        .reserve_phosphorus_g_p = state.branch_reserve_phosphorus_g,
        .husk_phosphorus_g_p = state.branch_husk_phosphorus_g,
        .ear_phosphorus_g_p = state.branch_ear_phosphorus_g,
    }, branch, .{
        .carbon_g_c_per_timestep = organGrowthElement(growth.carbon_g),
        .nitrogen_g_n_per_timestep = organGrowthElement(growth.nitrogen_g),
        .phosphorus_g_p_per_timestep = organGrowthElement(growth.phosphorus_g),
    });
}

fn organGrowthElement(values: [organ_count]f64) branch_organ_growth_state_update.ElementGrowth {
    return .{
        .leaf = values[@intFromEnum(Organ.leaf)],
        .sheath = values[@intFromEnum(Organ.sheath)],
        .stalk = values[@intFromEnum(Organ.stalk)],
        .reserve = values[@intFromEnum(Organ.reserve)],
        .husk = values[@intFromEnum(Organ.husk)],
        .ear = values[@intFromEnum(Organ.ear)],
    };
}

fn organGrowthMappings() @TypeOf(.{
    .{ Organ.leaf, "branch_leaf_carbon_g", "branch_leaf_nitrogen_g", "branch_leaf_phosphorus_g" },
    .{ Organ.sheath, "branch_sheath_carbon_g", "branch_sheath_nitrogen_g", "branch_sheath_phosphorus_g" },
    .{ Organ.stalk, "branch_stalk_carbon_g", "branch_stalk_nitrogen_g", "branch_stalk_phosphorus_g" },
    .{ Organ.reserve, "branch_reserve_carbon_g", "branch_reserve_nitrogen_g", "branch_reserve_phosphorus_g" },
    .{ Organ.husk, "branch_husk_carbon_g", "branch_husk_nitrogen_g", "branch_husk_phosphorus_g" },
    .{ Organ.ear, "branch_ear_carbon_g", "branch_ear_nitrogen_g", "branch_ear_phosphorus_g" },
}) {
    return .{
        .{ Organ.leaf, "branch_leaf_carbon_g", "branch_leaf_nitrogen_g", "branch_leaf_phosphorus_g" },
        .{ Organ.sheath, "branch_sheath_carbon_g", "branch_sheath_nitrogen_g", "branch_sheath_phosphorus_g" },
        .{ Organ.stalk, "branch_stalk_carbon_g", "branch_stalk_nitrogen_g", "branch_stalk_phosphorus_g" },
        .{ Organ.reserve, "branch_reserve_carbon_g", "branch_reserve_nitrogen_g", "branch_reserve_phosphorus_g" },
        .{ Organ.husk, "branch_husk_carbon_g", "branch_husk_nitrogen_g", "branch_husk_phosphorus_g" },
        .{ Organ.ear, "branch_ear_carbon_g", "branch_ear_nitrogen_g", "branch_ear_phosphorus_g" },
    };
}

pub fn validateBranchOrganGrowthTransaction(state: *const group_state.State, branch: usize, growth: OrganGrowth) !void {
    if (branch >= state.branch_leaf_carbon_g.len) return error.CanopyBranchIndexOutOfBounds;
    const mappings = organGrowthMappings();
    // Validate the complete transaction before publishing any organ. This
    // prevents a late overflow from leaving earlier organs state_updateted.
    inline for (mappings) |mapping| {
        const index = @intFromEnum(mapping[0]);
        inline for (.{
            @field(state, mapping[1])[branch] + growth.carbon_g[index],
            @field(state, mapping[2])[branch] + growth.nitrogen_g[index],
            @field(state, mapping[3])[branch] + growth.phosphorus_g[index],
        }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidBranchOrganGrowthTransaction;
    }
}

/// Distributes growth across the latest runtime nodes, replacing the historical
/// modulo-25 ring while retaining its equal allocation and SLA equation.
pub fn distributeLeafGrowth(state: *group_state.State, branch: usize, newest_node_within_branch: usize, first_growing_node_within_branch: usize, maximum_concurrently_growing_nodes: usize, growth: LeafGrowth, protein_per_nitrogen_g_per_g_n: f64, protein_per_phosphorus_g_per_g_p: f64, etoliation_factor: f64, base_specific_leaf_area_m2_per_g_c: f64, minimum_leaf_carbon_per_cell_g: f64, plant_density_per_m2: f64, leaf_area_exponent: f64, turgor_expansion_fraction: f64) !void {
    inline for (.{ growth.carbon_g, growth.nitrogen_g, growth.phosphorus_g, protein_per_nitrogen_g_per_g_n, protein_per_phosphorus_g_per_g_p, etoliation_factor, base_specific_leaf_area_m2_per_g_c, minimum_leaf_carbon_per_cell_g, plant_density_per_m2, leaf_area_exponent, turgor_expansion_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteLeafGrowthInput;
    if (growth.carbon_g < 0 or growth.nitrogen_g < 0 or growth.phosphorus_g < 0 or protein_per_nitrogen_g_per_g_n < 0 or protein_per_phosphorus_g_per_g_p < 0 or etoliation_factor < 0 or base_specific_leaf_area_m2_per_g_c < 0 or minimum_leaf_carbon_per_cell_g < 0 or plant_density_per_m2 <= 0 or turgor_expansion_fraction < 0 or maximum_concurrently_growing_nodes == 0) return error.InvalidLeafGrowthInput;
    const nodes = try state.nodeRange(branch);
    if (newest_node_within_branch >= nodes.end - nodes.first or first_growing_node_within_branch > newest_node_within_branch) return error.CanopyNodeIndexOutOfBounds;
    const first = @max(first_growing_node_within_branch, newest_node_within_branch + 1 -| maximum_concurrently_growing_nodes);
    const count = newest_node_within_branch - first + 1;
    const allocation = 1.0 / @as(f64, @floatFromInt(count));
    try leaf_node_growth_state_update.publish(.{
        .leaf_carbon_g_c = state.node_leaf_carbon_g[nodes.first..nodes.end],
        .leaf_nitrogen_g_n = state.node_leaf_nitrogen_g[nodes.first..nodes.end],
        .leaf_phosphorus_g_p = state.node_leaf_phosphorus_g[nodes.first..nodes.end],
        .leaf_protein_g = state.node_leaf_protein_g[nodes.first..nodes.end],
        .leaf_area_m2 = state.node_leaf_area_m2[nodes.first..nodes.end],
        .branch_leaf_area_m2 = &state.branch_leaf_area_m2[branch],
    }, .{
        .first_node = first,
        .last_node = newest_node_within_branch,
        .carbon_growth_g_c_per_node = allocation * growth.carbon_g,
        .nitrogen_growth_g_n_per_node = allocation * growth.nitrogen_g,
        .phosphorus_growth_g_p_per_node = allocation * growth.phosphorus_g,
        .protein_per_nitrogen_g_per_g_n = protein_per_nitrogen_g_per_g_n,
        .protein_per_phosphorus_g_per_g_p = protein_per_phosphorus_g_per_g_p,
        .etiolation_factor = etoliation_factor,
        .base_specific_leaf_area_m2_per_g_c = base_specific_leaf_area_m2_per_g_c,
        .minimum_leaf_carbon_g_c = minimum_leaf_carbon_per_cell_g,
        .plant_population = plant_density_per_m2,
        .leaf_mass_exponent = leaf_area_exponent,
        .turgor_expansion_fraction = turgor_expansion_fraction,
    });
}

pub fn distributeSheathGrowth(state: *group_state.State, branch: usize, newest_node_within_branch: usize, first_growing_node_within_branch: usize, maximum_concurrently_growing_nodes: usize, growth: LeafGrowth, protein_per_nitrogen_g_per_g_n: f64, protein_per_phosphorus_g_per_g_p: f64, etoliation_factor: f64, base_specific_length_m_per_g_c: f64, minimum_sheath_carbon_per_cell_g: f64, plant_density_per_m2: f64, length_exponent: f64, turgor_expansion_fraction: f64, vertical_projection_fraction: f64) !void {
    inline for (.{ growth.carbon_g, growth.nitrogen_g, growth.phosphorus_g, protein_per_nitrogen_g_per_g_n, protein_per_phosphorus_g_per_g_p, etoliation_factor, base_specific_length_m_per_g_c, minimum_sheath_carbon_per_cell_g, plant_density_per_m2, length_exponent, turgor_expansion_fraction, vertical_projection_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSheathGrowthInput;
    if (growth.carbon_g < 0 or growth.nitrogen_g < 0 or growth.phosphorus_g < 0 or protein_per_nitrogen_g_per_g_n < 0 or protein_per_phosphorus_g_per_g_p < 0 or etoliation_factor < 0 or base_specific_length_m_per_g_c < 0 or minimum_sheath_carbon_per_cell_g < 0 or plant_density_per_m2 <= 0 or turgor_expansion_fraction < 0 or vertical_projection_fraction < 0 or maximum_concurrently_growing_nodes == 0) return error.InvalidSheathGrowthInput;
    const nodes = try state.nodeRange(branch);
    if (newest_node_within_branch >= nodes.end - nodes.first or first_growing_node_within_branch > newest_node_within_branch) return error.CanopyNodeIndexOutOfBounds;
    const first = @max(first_growing_node_within_branch, newest_node_within_branch + 1 -| maximum_concurrently_growing_nodes);
    const count = newest_node_within_branch - first + 1;
    const allocation = 1.0 / @as(f64, @floatFromInt(count));
    for (first..newest_node_within_branch + 1) |local_node| {
        const node = nodes.first + local_node;
        const carbon = allocation * growth.carbon_g;
        const nitrogen = allocation * growth.nitrogen_g;
        const phosphorus = allocation * growth.phosphorus_g;
        const updated_sheath_carbon = state.node_sheath_carbon_g[node] + carbon;
        state.node_sheath_carbon_g[node] = updated_sheath_carbon;
        state.node_sheath_nitrogen_g[node] += nitrogen;
        state.node_sheath_phosphorus_g[node] += phosphorus;
        state.node_sheath_protein_g[node] += @min(nitrogen * protein_per_nitrogen_g_per_g_n, phosphorus * protein_per_phosphorus_g_per_g_p);
        if (state.node_leaf_carbon_g[node] > 0) {
            const specific_length = etoliation_factor * base_specific_length_m_per_g_c * std.math.pow(f64, @max(minimum_sheath_carbon_per_cell_g, updated_sheath_carbon) / plant_density_per_m2, length_exponent) * turgor_expansion_fraction;
            state.node_sheath_height_m[node] += carbon / plant_density_per_m2 * specific_length * vertical_projection_fraction;
        }
    }
}

pub const CanopyWaterGrowthResponse = struct { stomatal_fraction: f64, growth_fraction: f64, turgor_expansion_fraction: f64, water_potential_expansion_fraction: f64 };

pub fn canopyWaterGrowthResponse(shallow_root_profile: bool, canopy_turgor_potential_megapascal: f64, minimum_turgor_potential_megapascal: f64, canopy_total_water_potential_megapascal: f64, stomatal_turgor_shape: f64) !CanopyWaterGrowthResponse {
    const response = try @import("../energy/water_stress_response.zig").calculate(.{
        .root_profile = if (shallow_root_profile) .shallow else .non_shallow,
        .canopy_turgor_potential_megapascal = canopy_turgor_potential_megapascal,
        .minimum_canopy_turgor_potential_megapascal = minimum_turgor_potential_megapascal,
        .canopy_water_potential_megapascal = canopy_total_water_potential_megapascal,
        .stomatal_turgor_shape_per_megapascal = stomatal_turgor_shape,
    });
    return .{
        .stomatal_fraction = response.stomatal_resistance_factor,
        .growth_fraction = response.growth_factor,
        .turgor_expansion_fraction = response.turgor_expansion_factor,
        .water_potential_expansion_fraction = response.water_potential_expansion_factor,
    };
}

pub const RecyclingFractions = struct { carbon: f64, nitrogen: f64, phosphorus: f64 };

pub fn recyclingFractions(emerged: bool, mobile_carbon_g_per_g: f64, mobile_nitrogen_g_per_g: f64, mobile_phosphorus_g_per_g: f64, nitrogen_inhibition_g_n_per_g_c: f64, phosphorus_inhibition_g_p_per_g_c: f64, minimum_carbon_recycling_fraction: f64, responsive_carbon_recycling_fraction: f64, maximum_nitrogen_recycling_fraction: f64, maximum_phosphorus_recycling_fraction: f64) !RecyclingFractions {
    const minimum_carbon = [1]f64{minimum_carbon_recycling_fraction};
    const responsive_carbon = [1]f64{responsive_carbon_recycling_fraction};
    const maximum_nitrogen = [1]f64{maximum_nitrogen_recycling_fraction};
    const maximum_phosphorus = [1]f64{maximum_phosphorus_recycling_fraction};
    const result = try shoot_recycling_fraction.calculate(
        emerged,
        0,
        .{
            .mobile_carbon_g_c_per_g_c = mobile_carbon_g_per_g,
            .mobile_nitrogen_g_n_per_g_c = mobile_nitrogen_g_per_g,
            .mobile_phosphorus_g_p_per_g_c = mobile_phosphorus_g_per_g,
        },
        .{
            .nitrogen_g_n_per_g_c = nitrogen_inhibition_g_n_per_g_c,
            .phosphorus_g_p_per_g_c = phosphorus_inhibition_g_p_per_g_c,
        },
        .{
            .minimum_carbon_fraction = &minimum_carbon,
            .responsive_carbon_fraction = &responsive_carbon,
            .maximum_nitrogen_fraction = &maximum_nitrogen,
            .maximum_phosphorus_fraction = &maximum_phosphorus,
        },
    );
    return .{
        .carbon = result.carbon,
        .nitrogen = result.nitrogen,
        .phosphorus = result.phosphorus,
    };
}

pub const KineticFractions = struct {
    carbon: [4]f64,
    nitrogen: [4]f64,
    phosphorus: [4]f64,

    pub fn validate(self: KineticFractions) !void {
        inline for (.{ self.carbon, self.nitrogen, self.phosphorus }) |fractions| {
            var sum: f64 = 0;
            for (fractions) |fraction| {
                if (!std.math.isFinite(fraction) or fraction < 0) return error.InvalidLitterKineticFraction;
                sum += fraction;
            }
            if (@abs(sum - 1.0) > 1e-8) return error.LitterKineticFractionsDoNotSumToOne;
        }
    }
};
