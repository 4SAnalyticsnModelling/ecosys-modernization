//! `photosynthesis` declarations: harvest.
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
const group_reproductive = @import("photosynthesis_reproductive.zig");
const group_state = @import("photosynthesis_state.zig");

pub const HarvestProducts = struct { ecosystem_export: group_state.ElementalMass = .{}, litter: group_state.ElementalMass = .{} };

const HarvestPartition = struct { remaining: group_state.ElementalMass, products: HarvestProducts };

pub const ReproductiveHarvestResult = struct { products: HarvestProducts, harvested_grain: group_state.ElementalMass };

pub fn harvestReproductiveOrgans(state: *group_state.State, branch: usize, retention: group_reproductive.ReproductiveRetention) !ReproductiveHarvestResult {
    if (branch >= state.branch_husk_carbon_g.len) return error.CanopyBranchIndexOutOfBounds;
    const husk = try partitionHarvest(.{ .carbon_g = state.branch_husk_carbon_g[branch], .nitrogen_g = state.branch_husk_nitrogen_g[branch], .phosphorus_g = state.branch_husk_phosphorus_g[branch] }, retention.husk_remaining, retention.husk_unexported);
    const ear = try partitionHarvest(.{ .carbon_g = state.branch_ear_carbon_g[branch], .nitrogen_g = state.branch_ear_nitrogen_g[branch], .phosphorus_g = state.branch_ear_phosphorus_g[branch] }, retention.ear_remaining, retention.ear_unexported);
    const grain_mass: group_state.ElementalMass = .{ .carbon_g = state.branch_grain_carbon_g[branch], .nitrogen_g = state.branch_grain_nitrogen_g[branch], .phosphorus_g = state.branch_grain_phosphorus_g[branch] };
    const grain = try partitionHarvest(grain_mass, retention.grain_remaining, retention.grain_unexported);
    state.branch_husk_carbon_g[branch] = husk.remaining.carbon_g;
    state.branch_husk_nitrogen_g[branch] = husk.remaining.nitrogen_g;
    state.branch_husk_phosphorus_g[branch] = husk.remaining.phosphorus_g;
    state.branch_ear_carbon_g[branch] = ear.remaining.carbon_g;
    state.branch_ear_nitrogen_g[branch] = ear.remaining.nitrogen_g;
    state.branch_ear_phosphorus_g[branch] = ear.remaining.phosphorus_g;
    state.branch_grain_carbon_g[branch] = grain.remaining.carbon_g;
    state.branch_grain_nitrogen_g[branch] = grain.remaining.nitrogen_g;
    state.branch_grain_phosphorus_g[branch] = grain.remaining.phosphorus_g;
    state.branch_potential_seed_site_count[branch] *= retention.grain_remaining;
    state.branch_seed_count[branch] *= retention.grain_remaining;
    return .{
        .products = .{
            .ecosystem_export = group_state.addElementalMass(group_state.addElementalMass(husk.products.ecosystem_export, ear.products.ecosystem_export), grain.products.ecosystem_export),
            .litter = group_state.addElementalMass(group_state.addElementalMass(husk.products.litter, ear.products.litter), grain.products.litter),
        },
        .harvested_grain = .{ .carbon_g = (1.0 - retention.grain_remaining) * grain_mass.carbon_g, .nitrogen_g = (1.0 - retention.grain_remaining) * grain_mass.nitrogen_g, .phosphorus_g = (1.0 - retention.grain_remaining) * grain_mass.phosphorus_g },
    };
}

pub fn cuttingHeightForLeafAreaRemoval(removal_fraction: f64, layer_boundary_height_m: []const f64, leaf_area_by_layer_m2: []const f64) !f64 {
    if (!std.math.isFinite(removal_fraction) or removal_fraction < 0 or removal_fraction > 1 or layer_boundary_height_m.len != leaf_area_by_layer_m2.len + 1 or leaf_area_by_layer_m2.len == 0) return error.InvalidLeafAreaHarvestGeometry;
    var total_leaf_area: f64 = 0;
    for (leaf_area_by_layer_m2) |area| {
        if (!std.math.isFinite(area) or area < 0) return error.InvalidLeafAreaHarvestGeometry;
        total_leaf_area += area;
    }
    for (1..layer_boundary_height_m.len) |index| if (!std.math.isFinite(layer_boundary_height_m[index - 1]) or !std.math.isFinite(layer_boundary_height_m[index]) or layer_boundary_height_m[index] < layer_boundary_height_m[index - 1]) return error.InvalidLeafAreaHarvestGeometry;
    const target_remaining_leaf_area = (1.0 - removal_fraction) * total_leaf_area;
    var accumulated_leaf_area: f64 = 0;
    var cutting_height_m: f64 = 0;
    for (leaf_area_by_layer_m2, 0..) |layer_area, layer| {
        const lower = layer_boundary_height_m[layer];
        const upper = layer_boundary_height_m[layer + 1];
        if (upper > lower and layer_area > 0 and accumulated_leaf_area < target_remaining_leaf_area) {
            if (accumulated_leaf_area + layer_area > target_remaining_leaf_area)
                cutting_height_m = lower + (target_remaining_leaf_area - accumulated_leaf_area) / layer_area * (upper - lower)
            else
                cutting_height_m = 0;
            accumulated_leaf_area += layer_area;
        }
    }
    return cutting_height_m;
}

fn partitionHarvest(mass: group_state.ElementalMass, remaining_fraction: f64, unexported_fraction: f64) !HarvestPartition {
    if (!std.math.isFinite(remaining_fraction) or !std.math.isFinite(unexported_fraction) or remaining_fraction < 0 or unexported_fraction < remaining_fraction or unexported_fraction > 1) return error.InvalidHarvestRetentionFraction;
    inline for (@typeInfo(group_state.ElementalMass).@"struct".fields) |field| if (!std.math.isFinite(@field(mass, field.name)) or @field(mass, field.name) < 0) return error.InvalidHarvestMass;
    var result: HarvestPartition = .{ .remaining = .{}, .products = .{} };
    inline for (@typeInfo(group_state.ElementalMass).@"struct".fields) |field| {
        const value = @field(mass, field.name);
        @field(result.remaining, field.name) = remaining_fraction * value;
        @field(result.products.ecosystem_export, field.name) = (1.0 - unexported_fraction) * value;
        @field(result.products.litter, field.name) = (unexported_fraction - remaining_fraction) * value;
    }
    return result;
}

pub fn harvestBranchStalkAndReserve(state: *group_state.State, branch: usize, stalk_remaining_fraction: f64, stalk_unexported_fraction: f64, reserve_remaining_fraction: f64, reserve_unexported_fraction: f64) !HarvestProducts {
    if (branch >= state.branch_stalk_carbon_g.len) return error.CanopyBranchIndexOutOfBounds;
    const stalk = try partitionHarvest(.{ .carbon_g = state.branch_stalk_carbon_g[branch], .nitrogen_g = state.branch_stalk_nitrogen_g[branch], .phosphorus_g = state.branch_stalk_phosphorus_g[branch] }, stalk_remaining_fraction, stalk_unexported_fraction);
    const reserve = try partitionHarvest(.{ .carbon_g = state.branch_reserve_carbon_g[branch], .nitrogen_g = state.branch_reserve_nitrogen_g[branch], .phosphorus_g = state.branch_reserve_phosphorus_g[branch] }, reserve_remaining_fraction, reserve_unexported_fraction);
    state.branch_stalk_carbon_g[branch] = stalk.remaining.carbon_g;
    state.branch_stalk_nitrogen_g[branch] = stalk.remaining.nitrogen_g;
    state.branch_stalk_phosphorus_g[branch] = stalk.remaining.phosphorus_g;
    state.branch_sapwood_carbon_g[branch] *= stalk_remaining_fraction;
    state.branch_senescing_stalk_carbon_g[branch] *= stalk_remaining_fraction;
    state.branch_senescing_stalk_nitrogen_g[branch] *= stalk_remaining_fraction;
    state.branch_senescing_stalk_phosphorus_g[branch] *= stalk_remaining_fraction;
    state.branch_reserve_carbon_g[branch] = reserve.remaining.carbon_g;
    state.branch_reserve_nitrogen_g[branch] = reserve.remaining.nitrogen_g;
    state.branch_reserve_phosphorus_g[branch] = reserve.remaining.phosphorus_g;
    return .{
        .ecosystem_export = .{ .carbon_g = stalk.products.ecosystem_export.carbon_g + reserve.products.ecosystem_export.carbon_g, .nitrogen_g = stalk.products.ecosystem_export.nitrogen_g + reserve.products.ecosystem_export.nitrogen_g, .phosphorus_g = stalk.products.ecosystem_export.phosphorus_g + reserve.products.ecosystem_export.phosphorus_g },
        .litter = .{ .carbon_g = stalk.products.litter.carbon_g + reserve.products.litter.carbon_g, .nitrogen_g = stalk.products.litter.nitrogen_g + reserve.products.litter.nitrogen_g, .phosphorus_g = stalk.products.litter.phosphorus_g + reserve.products.litter.phosphorus_g },
    };
}

/// Applies GROSUB's mobile-pool retention ratio and the same ratio to every C4
/// intermediate belonging to the branch.
pub fn harvestBranchMobilePools(state: *group_state.State, branch: usize, remaining_fraction: f64) !group_state.ElementalMass {
    return harvestBranchMobilePoolsWithIntermediateRetention(
        state,
        branch,
        remaining_fraction,
        remaining_fraction,
    );
}

/// Applies independent host-mobile and biochemical-intermediate retention.
/// GROSUB uses the second fraction only for C4 plants with significant
/// pre-harvest host-mobile carbon.
pub fn harvestBranchMobilePoolsWithIntermediateRetention(
    state: *group_state.State,
    branch: usize,
    mobile_remaining_fraction: f64,
    intermediate_remaining_fraction: f64,
) !group_state.ElementalMass {
    inline for (.{ mobile_remaining_fraction, intermediate_remaining_fraction }) |fraction|
        if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
            return error.InvalidHarvestRetentionFraction;
    const nodes = try state.nodeRange(branch);
    inline for (.{ state.branch_mobile_carbon_g[branch], state.branch_mobile_nitrogen_g[branch], state.branch_mobile_phosphorus_g[branch] }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidHarvestMass;
    for (nodes.first..nodes.end) |node| {
        inline for (.{ "node_c3_nonstructural_carbon_g", "node_c4_mesophyll_nonstructural_carbon_g", "node_bundle_sheath_co2_carbon_g", "node_bundle_sheath_bicarbonate_carbon_g" }) |field_name| {
            const value = @field(state, field_name)[node];
            if (!std.math.isFinite(value) or value < 0) return error.InvalidHarvestMass;
        }
    }
    var removed: group_state.ElementalMass = .{
        .carbon_g = (1.0 - mobile_remaining_fraction) * state.branch_mobile_carbon_g[branch],
        .nitrogen_g = (1.0 - mobile_remaining_fraction) * state.branch_mobile_nitrogen_g[branch],
        .phosphorus_g = (1.0 - mobile_remaining_fraction) * state.branch_mobile_phosphorus_g[branch],
    };
    state.branch_mobile_carbon_g[branch] *= mobile_remaining_fraction;
    state.branch_mobile_nitrogen_g[branch] *= mobile_remaining_fraction;
    state.branch_mobile_phosphorus_g[branch] *= mobile_remaining_fraction;
    for (nodes.first..nodes.end) |node| {
        inline for (.{ "node_c3_nonstructural_carbon_g", "node_c4_mesophyll_nonstructural_carbon_g", "node_bundle_sheath_co2_carbon_g", "node_bundle_sheath_bicarbonate_carbon_g" }) |field_name| {
            removed.carbon_g += (1.0 - intermediate_remaining_fraction) * @field(state, field_name)[node];
            @field(state, field_name)[node] *= intermediate_remaining_fraction;
        }
    }
    return removed;
}
