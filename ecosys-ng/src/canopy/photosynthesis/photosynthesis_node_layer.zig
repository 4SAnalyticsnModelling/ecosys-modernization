//! `photosynthesis` declarations: node layer.
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
const leaf_senescence_snapshot = @import("../leaf/senescence_snapshot.zig");
const leaf_senescence_state_update = @import("../leaf/senescence_state_update.zig");
const sheath_senescence_fraction = @import("../sheath/senescence_fraction.zig");
const sheath_senescence_litter_partition = @import("../sheath/senescence_litter_partition.zig");
const sheath_senescence_snapshot = @import("../sheath/senescence_snapshot_and_stalk_transfer.zig");
const sheath_senescence_state_update = @import("../sheath/senescence_state_update.zig");
const node_senescence_cascade_progress = @import("../../plant/growth/node_senescence_cascade_progress.zig");
const perennial_stalk_senescence_setup = @import("../../plant/growth/perennial_stalk_senescence_setup.zig");
const internode_senescence_state_update = @import("../sheath/internode_senescence_state_update.zig");
const residual_stalk_senescence_request = @import("../../plant/growth/residual_stalk_senescence_request.zig");
const residual_stalk_senescence_state_update = @import("../../plant/growth/residual_stalk_senescence_state_update.zig");
const group_harvest = @import("photosynthesis_harvest.zig");
const group_misc = @import("photosynthesis_misc.zig");
const group_organ_growth = @import("photosynthesis_organ_growth.zig");
const group_senescence = @import("photosynthesis_senescence.zig");
const group_state = @import("photosynthesis_state.zig");

pub const LayerLeafOutputs = struct {
    area_m2: []f64,
    carbon_g: []f64,
    nitrogen_g: []f64,
    phosphorus_g: []f64,
};

/// GROSUB ARLFL/WGLFL/WGLFLN/WGLFLP allocation for one leafed node. Layer
/// boundaries and inclination classes are runtime extents; no 25-node ring or
/// fixed JC/N dimensions are retained.
pub fn allocateLeafAcrossCanopyLayers(leaf_area_m2: f64, leaf_carbon_g: f64, leaf_nitrogen_g: f64, leaf_phosphorus_g: f64, population_per_m2: f64, leaf_length_to_width_ratio: f64, stalk_height_m: f64, sheath_height_m: f64, maximum_canopy_height_m: f64, layer_boundary_height_m: []const f64, inclination_sine: []const f64, inclination_fraction: []const f64, outputs: LayerLeafOutputs) !f64 {
    inline for (.{ leaf_area_m2, leaf_carbon_g, leaf_nitrogen_g, leaf_phosphorus_g, population_per_m2, leaf_length_to_width_ratio, stalk_height_m, sheath_height_m, maximum_canopy_height_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopyLayerAllocationInput;
    if (leaf_area_m2 < 0 or leaf_carbon_g < 0 or leaf_nitrogen_g < 0 or leaf_phosphorus_g < 0 or population_per_m2 <= 0 or leaf_length_to_width_ratio < 0 or stalk_height_m < 0 or sheath_height_m < 0 or maximum_canopy_height_m < 0 or layer_boundary_height_m.len < 2 or inclination_sine.len == 0 or inclination_sine.len != inclination_fraction.len) return error.InvalidCanopyLayerAllocationInput;
    const layer_count = layer_boundary_height_m.len - 1;
    inline for (.{ outputs.area_m2, outputs.carbon_g, outputs.nitrogen_g, outputs.phosphorus_g }) |values| if (values.len != layer_count) return error.CanopyLayerAllocationDimensionMismatch;
    for (1..layer_boundary_height_m.len) |index| if (!std.math.isFinite(layer_boundary_height_m[index - 1]) or !std.math.isFinite(layer_boundary_height_m[index]) or layer_boundary_height_m[index] < layer_boundary_height_m[index - 1]) return error.InvalidCanopyLayerBoundary;
    var inclination_total: f64 = 0;
    for (inclination_sine, inclination_fraction) |sine, fraction| {
        if (!std.math.isFinite(sine) or sine < 0 or sine > 1 or !std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidCanopyInclinationDistribution;
        inclination_total += fraction;
    }
    if (@abs(inclination_total - 1) > 1.0e-4) return error.CanopyInclinationDistributionDoesNotSumToOne;
    @memset(outputs.area_m2, 0);
    @memset(outputs.carbon_g, 0);
    @memset(outputs.nitrogen_g, 0);
    @memset(outputs.phosphorus_g, 0);
    if (leaf_area_m2 == 0) return @min(maximum_canopy_height_m + 0.01, stalk_height_m + sheath_height_m);

    const leaf_length_m = @sqrt(leaf_length_to_width_ratio * leaf_area_m2 / population_per_m2);
    const leaf_base_height_m = stalk_height_m + sheath_height_m;
    const height_cap_m = maximum_canopy_height_m + 0.01;
    var accumulated_leaf_elevation_m: f64 = 0;
    var highest_leaf_height_m: f64 = 0;
    var inclination = inclination_sine.len;
    while (inclination > 0) {
        inclination -= 1;
        const class_fraction = inclination_fraction[inclination];
        if (class_fraction == 0) continue;
        const elevation_m = inclination_sine[inclination] * class_fraction * leaf_length_m;
        const lower_m = @min(height_cap_m - elevation_m, leaf_base_height_m + accumulated_leaf_elevation_m);
        const upper_m = @min(height_cap_m, lower_m + elevation_m);
        if (upper_m <= lower_m) {
            const layer = containingCanopyLayer(layer_boundary_height_m, @max(0.0, lower_m));
            addLeafLayer(outputs, layer, class_fraction, leaf_area_m2, leaf_carbon_g, leaf_nitrogen_g, leaf_phosphorus_g);
        } else {
            var allocated_fraction: f64 = 0;
            for (0..layer_count) |layer| {
                const overlap_m = @max(0.0, @min(upper_m, layer_boundary_height_m[layer + 1]) - @max(lower_m, layer_boundary_height_m[layer]));
                if (overlap_m == 0) continue;
                const fraction = class_fraction * overlap_m / (upper_m - lower_m);
                addLeafLayer(outputs, layer, fraction, leaf_area_m2, leaf_carbon_g, leaf_nitrogen_g, leaf_phosphorus_g);
                allocated_fraction += fraction;
            }
            if (allocated_fraction < class_fraction) {
                const layer = containingCanopyLayer(layer_boundary_height_m, std.math.clamp(lower_m, layer_boundary_height_m[0], layer_boundary_height_m[layer_count]));
                addLeafLayer(outputs, layer, class_fraction - allocated_fraction, leaf_area_m2, leaf_carbon_g, leaf_nitrogen_g, leaf_phosphorus_g);
            }
        }
        accumulated_leaf_elevation_m += elevation_m;
        highest_leaf_height_m = @max(highest_leaf_height_m, upper_m);
    }
    return highest_leaf_height_m;
}

fn containingCanopyLayer(boundaries: []const f64, height_m: f64) usize {
    for (0..boundaries.len - 1) |layer| if (height_m <= boundaries[layer + 1]) return layer;
    return boundaries.len - 2;
}

fn addLeafLayer(outputs: LayerLeafOutputs, layer: usize, fraction: f64, area_m2: f64, carbon_g: f64, nitrogen_g: f64, phosphorus_g: f64) void {
    outputs.area_m2[layer] += fraction * area_m2;
    outputs.carbon_g[layer] += fraction * carbon_g;
    outputs.nitrogen_g[layer] += fraction * nitrogen_g;
    outputs.phosphorus_g[layer] += fraction * phosphorus_g;
}

pub const StalkLayerAllocation = struct {
    radius_m: f64,
    surface_area_m2: f64,
    sapwood_carbon_g: f64,
};

/// GROSUB RSTK/ARSTKB/WVSTKB and ARSTK allocation for one branch.
pub fn allocateStalkAcrossCanopyLayers(stalk_carbon_g: f64, retained_stalk_carbon_g: f64, population_per_m2: f64, stalk_volume_m3_per_g_c: f64, branch_base_height_m: f64, branch_tip_height_m: f64, annual_growth_habit: bool, specific_internode_length_positive: bool, layer_boundary_height_m: []const f64, layer_stalk_area_m2: []f64) !StalkLayerAllocation {
    inline for (.{ stalk_carbon_g, retained_stalk_carbon_g, population_per_m2, stalk_volume_m3_per_g_c, branch_base_height_m, branch_tip_height_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteStalkLayerAllocationInput;
    if (stalk_carbon_g < 0 or retained_stalk_carbon_g < 0 or population_per_m2 <= 0 or stalk_volume_m3_per_g_c <= 0 or branch_base_height_m < 0 or branch_tip_height_m < branch_base_height_m or layer_boundary_height_m.len < 2 or layer_stalk_area_m2.len != layer_boundary_height_m.len - 1) return error.InvalidStalkLayerAllocationInput;
    for (1..layer_boundary_height_m.len) |index| if (!std.math.isFinite(layer_boundary_height_m[index - 1]) or !std.math.isFinite(layer_boundary_height_m[index]) or layer_boundary_height_m[index] < layer_boundary_height_m[index - 1]) return error.InvalidCanopyLayerBoundary;
    @memset(layer_stalk_area_m2, 0);
    const stalk_height_m = branch_tip_height_m - branch_base_height_m;
    if (stalk_height_m == 0) return .{ .radius_m = 0, .surface_area_m2 = 0, .sapwood_carbon_g = if (specific_internode_length_positive) 0 else retained_stalk_carbon_g };
    const radius_m = @sqrt(stalk_volume_m3_per_g_c * (stalk_carbon_g / population_per_m2) / (3.1416 * stalk_height_m));
    const surface_area_m2 = 6.2832 * radius_m * stalk_height_m * population_per_m2;
    const sapwood_carbon_g = if (annual_growth_habit)
        stalk_carbon_g
    else blk: {
        const sapwood_thickness_m = @min(1.0e-3, 0.05 * radius_m);
        const sapwood_cross_section_m2 = 3.1416 * (2 * radius_m * sapwood_thickness_m - sapwood_thickness_m * sapwood_thickness_m);
        break :blk sapwood_cross_section_m2 / stalk_volume_m3_per_g_c * stalk_height_m * population_per_m2;
    };
    for (0..layer_stalk_area_m2.len) |layer| {
        const overlap_m = @max(0.0, @min(branch_tip_height_m, layer_boundary_height_m[layer + 1]) - @max(branch_base_height_m, layer_boundary_height_m[layer]));
        layer_stalk_area_m2[layer] = surface_area_m2 * overlap_m / stalk_height_m;
    }
    return .{ .radius_m = radius_m, .surface_area_m2 = surface_area_m2, .sapwood_carbon_g = sapwood_carbon_g };
}

pub const NodeSenescenceAllocation = struct {
    leaf_present: bool,
    leaf_fraction: f64,
    sheath_fraction: f64,
    leaf_recycled_carbon_g: f64,
    sheath_recycled_carbon_g: f64,
    carbon_recovered_to_mobile_pool_g: f64,
    carbon_respired_g: f64,
    remaining_respiration_demand_g_c: f64,
};

pub fn allocateNodeSenescenceDemand(node_respiration_demand_g_c: f64, leaf_carbon_g: f64, sheath_carbon_g: f64, carbon_recycling_fraction: f64, phenological_senescence_fraction: f64, nonwoody_carbon_fraction: f64) !NodeSenescenceAllocation {
    return allocateNodeSenescenceDemandWithThreshold(node_respiration_demand_g_c, leaf_carbon_g, sheath_carbon_g, carbon_recycling_fraction, phenological_senescence_fraction, nonwoody_carbon_fraction, 0);
}

pub fn allocateNodeSenescenceDemandWithThreshold(node_respiration_demand_g_c: f64, leaf_carbon_g: f64, sheath_carbon_g: f64, carbon_recycling_fraction: f64, phenological_senescence_fraction: f64, nonwoody_carbon_fraction: f64, leaf_presence_threshold_g_c: f64) !NodeSenescenceAllocation {
    inline for (.{ node_respiration_demand_g_c, leaf_carbon_g, sheath_carbon_g, carbon_recycling_fraction, phenological_senescence_fraction, nonwoody_carbon_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteNodeSenescenceInput;
    if (node_respiration_demand_g_c < 0 or leaf_carbon_g < 0 or sheath_carbon_g < 0 or carbon_recycling_fraction < 0 or carbon_recycling_fraction > 1 or phenological_senescence_fraction < 0 or phenological_senescence_fraction > 1 or nonwoody_carbon_fraction < 0 or nonwoody_carbon_fraction > 1) return error.InvalidNodeSenescenceInput;
    const request = try node_senescence_remobilization_request.calculate(.{
        .leaf_carbon_g_c = &.{leaf_carbon_g},
        .sheath_carbon_g_c = &.{sheath_carbon_g},
        .leaf_nitrogen_g_n = &.{0},
        .leaf_phosphorus_g_p = &.{0},
    }, 0, node_respiration_demand_g_c, leaf_presence_threshold_g_c, .{
        .carbon = carbon_recycling_fraction,
        .nitrogen = 0,
        .phosphorus = 0,
    });
    const recyclable_leaf = request.remobilizable_leaf_carbon_g_c;
    const leaf_present = leaf_carbon_g > leaf_presence_threshold_g_c;
    const leaf_fraction = if (leaf_present) request.leaf_mass_removal_fraction else 1;
    const consumed_leaf_recycling = request.leaf_mass_removal_fraction * recyclable_leaf * nonwoody_carbon_fraction;
    var remaining = @max(0.0, node_respiration_demand_g_c - consumed_leaf_recycling);
    const recyclable_sheath = sheath_carbon_g * carbon_recycling_fraction;
    const sheath_fraction = if (request.sheath_senescence_respiration_g_c_per_timestep > 0 and sheath_carbon_g > 0)
        (if (recyclable_sheath > leaf_presence_threshold_g_c) std.math.clamp(request.sheath_senescence_respiration_g_c_per_timestep / recyclable_sheath, 0, 1) else 1)
    else
        0;
    const consumed_sheath_recycling = sheath_fraction * recyclable_sheath * nonwoody_carbon_fraction;
    remaining = @max(0.0, remaining - consumed_sheath_recycling);
    const recycled_carbon = consumed_leaf_recycling + consumed_sheath_recycling;
    return .{
        .leaf_present = leaf_present,
        .leaf_fraction = leaf_fraction,
        .sheath_fraction = sheath_fraction,
        .leaf_recycled_carbon_g = leaf_fraction * recyclable_leaf,
        .sheath_recycled_carbon_g = sheath_fraction * recyclable_sheath,
        .carbon_recovered_to_mobile_pool_g = recycled_carbon * phenological_senescence_fraction,
        .carbon_respired_g = recycled_carbon * (1.0 - phenological_senescence_fraction),
        .remaining_respiration_demand_g_c = remaining,
    };
}

pub fn state_updateNodeSenescenceDemand(state: *group_state.State, branch: usize, node_within_branch: usize, allocation: NodeSenescenceAllocation, recycling: group_organ_growth.RecyclingFractions, protein_per_nitrogen_g_per_g_n: f64, protein_per_phosphorus_g_per_g_p: f64, woody_fraction: [2]f64, leaf_woody_nitrogen_fraction: [2]f64, sheath_woody_nitrogen_fraction: [2]f64, leaf_woody_phosphorus_fraction: [2]f64, sheath_woody_phosphorus_fraction: [2]f64, woody_kinetics: group_organ_growth.KineticFractions, leaf_kinetics: group_organ_growth.KineticFractions, sheath_kinetics: group_organ_growth.KineticFractions) !group_senescence.SenescenceProducts {
    inline for (.{ allocation.leaf_fraction, allocation.sheath_fraction, allocation.carbon_recovered_to_mobile_pool_g, allocation.carbon_respired_g, recycling.carbon, recycling.nitrogen, recycling.phosphorus, protein_per_nitrogen_g_per_g_n, protein_per_phosphorus_g_per_g_p }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSenescenceInput;
    if (allocation.leaf_fraction < 0 or allocation.leaf_fraction > 1 or allocation.sheath_fraction < 0 or allocation.sheath_fraction > 1 or allocation.carbon_recovered_to_mobile_pool_g < 0 or allocation.carbon_respired_g < 0 or recycling.carbon < 0 or recycling.carbon > 1 or recycling.nitrogen < 0 or recycling.nitrogen > 1 or recycling.phosphorus < 0 or recycling.phosphorus > 1 or protein_per_nitrogen_g_per_g_n < 0 or protein_per_phosphorus_g_per_g_p < 0) return error.InvalidSenescenceInput;
    inline for (.{ woody_fraction, leaf_woody_nitrogen_fraction, sheath_woody_nitrogen_fraction, leaf_woody_phosphorus_fraction, sheath_woody_phosphorus_fraction }) |fractions| {
        for (fractions) |fraction| if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidWoodyFraction;
        if (@abs(fractions[0] + fractions[1] - 1.0) > 1e-8) return error.InvalidWoodyFraction;
    }
    try woody_kinetics.validate();
    try leaf_kinetics.validate();
    try sheath_kinetics.validate();
    const nodes = try state.nodeRange(branch);
    if (node_within_branch >= nodes.end - nodes.first) return error.CanopyNodeIndexOutOfBounds;
    const node = nodes.first + node_within_branch;
    const leaf_c = state.node_leaf_carbon_g[node];
    const leaf_n = state.node_leaf_nitrogen_g[node];
    const leaf_p = state.node_leaf_phosphorus_g[node];
    const sheath_c = state.node_sheath_carbon_g[node];
    const sheath_n = state.node_sheath_nitrogen_g[node];
    const sheath_p = state.node_sheath_phosphorus_g[node];
    const recycled_leaf_c = if (allocation.leaf_present) leaf_c * recycling.carbon else 0;
    const recycled_leaf_n = if (allocation.leaf_present) leaf_n * (recycling.nitrogen + (1.0 - recycling.nitrogen) * recycling.carbon) else 0;
    const recycled_leaf_p = if (allocation.leaf_present) leaf_p * (recycling.phosphorus + (1.0 - recycling.phosphorus) * recycling.carbon) else 0;
    const recycled_sheath_c = sheath_c * recycling.carbon;
    const recycled_sheath_n = sheath_n * (recycling.nitrogen + (1.0 - recycling.nitrogen) * recycling.carbon);
    const recycled_sheath_p = sheath_p * (recycling.phosphorus + (1.0 - recycling.phosphorus) * recycling.carbon);
    // GROSUB 2771-2773 explicitly floors derived sheath protein. C/N/P
    // aggregates below are authoritative conserved inventories and may not clip.
    const next_sheath_protein_g = @max(0, state.node_sheath_protein_g[node] - allocation.sheath_fraction * @max(sheath_n * protein_per_nitrogen_g_per_g_n, sheath_p * protein_per_phosphorus_g_per_g_p));
    const next_branch_sheath_c = state.branch_sheath_carbon_g[branch] - allocation.sheath_fraction * sheath_c;
    const next_branch_sheath_n = state.branch_sheath_nitrogen_g[branch] - allocation.sheath_fraction * sheath_n;
    const next_branch_sheath_p = state.branch_sheath_phosphorus_g[branch] - allocation.sheath_fraction * sheath_p;
    inline for (.{ next_sheath_protein_g, next_branch_sheath_c, next_branch_sheath_n, next_branch_sheath_p }) |next|
        if (!std.math.isFinite(next) or next < 0) return error.SenescenceWouldOverdrawSheathAggregate;
    var products: group_senescence.SenescenceProducts = .{
        .recycled_carbon_g = allocation.carbon_recovered_to_mobile_pool_g,
        .recycled_nitrogen_g = allocation.leaf_fraction * recycled_leaf_n * leaf_woody_nitrogen_fraction[1] + allocation.sheath_fraction * recycled_sheath_n * sheath_woody_nitrogen_fraction[1],
        .recycled_phosphorus_g = allocation.leaf_fraction * recycled_leaf_p * leaf_woody_phosphorus_fraction[1] + allocation.sheath_fraction * recycled_sheath_p * sheath_woody_phosphorus_fraction[1],
        .respired_carbon_g = allocation.carbon_respired_g,
    };
    for (0..4) |kinetic| {
        products.woody_carbon_g[kinetic] = woody_kinetics.carbon[kinetic] * woody_fraction[0] * (allocation.leaf_fraction * leaf_c + allocation.sheath_fraction * sheath_c);
        products.woody_nitrogen_g[kinetic] = woody_kinetics.nitrogen[kinetic] * (allocation.leaf_fraction * leaf_n * leaf_woody_nitrogen_fraction[0] + allocation.sheath_fraction * sheath_n * sheath_woody_nitrogen_fraction[0]);
        products.woody_phosphorus_g[kinetic] = woody_kinetics.phosphorus[kinetic] * (allocation.leaf_fraction * leaf_p * leaf_woody_phosphorus_fraction[0] + allocation.sheath_fraction * sheath_p * sheath_woody_phosphorus_fraction[0]);
        products.nonwoody_carbon_g[kinetic] = woody_fraction[1] * (leaf_kinetics.carbon[kinetic] * allocation.leaf_fraction * (leaf_c - recycled_leaf_c) + sheath_kinetics.carbon[kinetic] * allocation.sheath_fraction * (sheath_c - recycled_sheath_c));
        products.nonwoody_nitrogen_g[kinetic] = leaf_woody_nitrogen_fraction[1] * leaf_kinetics.nitrogen[kinetic] * allocation.leaf_fraction * (leaf_n - recycled_leaf_n) + sheath_woody_nitrogen_fraction[1] * sheath_kinetics.nitrogen[kinetic] * allocation.sheath_fraction * (sheath_n - recycled_sheath_n);
        products.nonwoody_phosphorus_g[kinetic] = leaf_woody_phosphorus_fraction[1] * leaf_kinetics.phosphorus[kinetic] * allocation.leaf_fraction * (leaf_p - recycled_leaf_p) + sheath_woody_phosphorus_fraction[1] * sheath_kinetics.phosphorus[kinetic] * allocation.sheath_fraction * (sheath_p - recycled_sheath_p);
    }
    const leaf_state_update = try @import("../leaf/senescence_state_update.zig").calculate(.{
        .branch = .{ .area_m2 = state.branch_leaf_area_m2[branch], .carbon_g_c = state.branch_leaf_carbon_g[branch], .nitrogen_g_n = state.branch_leaf_nitrogen_g[branch], .phosphorus_g_p = state.branch_leaf_phosphorus_g[branch] },
        .node = .{ .area_m2 = state.node_leaf_area_m2[node], .carbon_g_c = leaf_c, .nitrogen_g_n = leaf_n, .phosphorus_g_p = leaf_p },
        .node_protein_g = state.node_leaf_protein_g[node],
        .senescing_snapshot = .{ .area_m2 = state.node_leaf_area_m2[node], .carbon_g_c = leaf_c, .nitrogen_g_n = leaf_n, .phosphorus_g_p = leaf_p },
        .area_removal_fraction = allocation.leaf_fraction,
        .mass_removal_fraction = allocation.leaf_fraction,
        .protein_per_nitrogen_g_per_g_n = protein_per_nitrogen_g_per_g_n,
        .protein_per_phosphorus_g_per_g_p = protein_per_phosphorus_g_per_g_p,
        .branch_mobile_carbon_g_c = state.branch_mobile_carbon_g[branch],
        .branch_mobile_nitrogen_g_n = state.branch_mobile_nitrogen_g[branch],
        .branch_mobile_phosphorus_g_p = state.branch_mobile_phosphorus_g[branch],
        .recycled_carbon_g_c = products.recycled_carbon_g,
        .recycled_nitrogen_g_n = products.recycled_nitrogen_g,
        .recycled_phosphorus_g_p = products.recycled_phosphorus_g,
    });
    const c4_state: c4_leaf_nonstructural_carbon_senescence.State = .{
        .bundle_sheath_carbon_g_c = state.node_c3_nonstructural_carbon_g,
        .mesophyll_carbon_g_c = state.node_c4_mesophyll_nonstructural_carbon_g,
        .foliar_litter_carbon_g_c_by_kinetic_pool = &products.nonwoody_carbon_g,
    };
    const c4_routing: c4_leaf_nonstructural_carbon_senescence.Routing = .{
        .selected_node = node,
        .foliar_litter_kinetic_pool = 1,
    };
    if (allocation.leaf_present)
        try c4_leaf_nonstructural_carbon_senescence.routePartial(c4_state, c4_routing, allocation.leaf_fraction)
    else
        try c4_leaf_nonstructural_carbon_senescence.routeAll(c4_state, c4_routing);

    state.branch_leaf_area_m2[branch] = leaf_state_update.branch.area_m2;
    state.branch_leaf_carbon_g[branch] = leaf_state_update.branch.carbon_g_c;
    state.branch_leaf_nitrogen_g[branch] = leaf_state_update.branch.nitrogen_g_n;
    state.branch_leaf_phosphorus_g[branch] = leaf_state_update.branch.phosphorus_g_p;
    state.node_leaf_area_m2[node] = leaf_state_update.node.area_m2;
    state.node_leaf_carbon_g[node] = leaf_state_update.node.carbon_g_c;
    state.node_leaf_nitrogen_g[node] = leaf_state_update.node.nitrogen_g_n;
    state.node_leaf_phosphorus_g[node] = leaf_state_update.node.phosphorus_g_p;
    state.node_leaf_protein_g[node] = leaf_state_update.node_protein_g;
    state.node_sheath_height_m[node] *= 1.0 - allocation.sheath_fraction;
    state.node_sheath_carbon_g[node] = sheath_c * (1.0 - allocation.sheath_fraction);
    state.node_sheath_nitrogen_g[node] = sheath_n * (1.0 - allocation.sheath_fraction);
    state.node_sheath_phosphorus_g[node] = sheath_p * (1.0 - allocation.sheath_fraction);
    state.node_sheath_protein_g[node] = next_sheath_protein_g;
    state.branch_sheath_carbon_g[branch] = next_branch_sheath_c;
    state.branch_sheath_nitrogen_g[branch] = next_branch_sheath_n;
    state.branch_sheath_phosphorus_g[branch] = next_branch_sheath_p;
    state.branch_mobile_carbon_g[branch] = leaf_state_update.branch_mobile_carbon_g_c;
    state.branch_mobile_nitrogen_g[branch] = leaf_state_update.branch_mobile_nitrogen_g_n;
    state.branch_mobile_phosphorus_g[branch] = leaf_state_update.branch_mobile_phosphorus_g_p;
    return products;
}

pub const InternodeSenescenceResult = struct { fraction: f64, remaining_respiration_demand_g_c: f64, products: group_senescence.SenescenceProducts };

pub fn state_updateInternodeSenescenceDemandScaled(state: *group_state.State, branch: usize, node_within_branch: usize, respiration_demand_g_c: f64, phenological_senescence_fraction: f64, scaled_recycling: perennial_stalk_senescence_setup.RecyclingFractions, presence_threshold_g_c: f64, woody_carbon_fraction: [2]f64, woody_nitrogen_fraction: [2]f64, woody_phosphorus_fraction: [2]f64, woody_kinetics: group_organ_growth.KineticFractions, stalk_kinetics: group_organ_growth.KineticFractions) !InternodeSenescenceResult {
    const nodes = try state.nodeRange(branch);
    if (node_within_branch >= nodes.end - nodes.first) return error.CanopyNodeIndexOutOfBounds;
    const node = nodes.first + node_within_branch;
    var products: group_senescence.SenescenceProducts = .{};
    const reserve_carbon_before = state.branch_reserve_carbon_g[branch];
    const reserve_nitrogen_before = state.branch_reserve_nitrogen_g[branch];
    const reserve_phosphorus_before = state.branch_reserve_phosphorus_g[branch];
    const result = try internode_senescence_state_update.publish(.{
        .branch_stalk_carbon_g_c = &state.branch_stalk_carbon_g[branch],
        .branch_stalk_nitrogen_g_n = &state.branch_stalk_nitrogen_g[branch],
        .branch_stalk_phosphorus_g_p = &state.branch_stalk_phosphorus_g[branch],
        .node_height_m = state.node_height_m,
        .internode_length_m = state.node_internode_length_m,
        .internode_carbon_g_c = state.node_internode_carbon_g,
        .internode_nitrogen_g_n = state.node_internode_nitrogen_g,
        .internode_phosphorus_g_p = state.node_internode_phosphorus_g,
        .reserve_carbon_g_c = &state.branch_reserve_carbon_g[branch],
        .reserve_nitrogen_g_n = &state.branch_reserve_nitrogen_g[branch],
        .reserve_phosphorus_g_p = &state.branch_reserve_phosphorus_g[branch],
        .litter = .{
            .woody_carbon_g_c = &products.woody_carbon_g,
            .woody_nitrogen_g_n = &products.woody_nitrogen_g,
            .woody_phosphorus_g_p = &products.woody_phosphorus_g,
            .stalk_carbon_g_c = &products.nonwoody_carbon_g,
            .stalk_nitrogen_g_n = &products.nonwoody_nitrogen_g,
            .stalk_phosphorus_g_p = &products.nonwoody_phosphorus_g,
        },
    }, .{
        .selected_node = node,
        .respiration_demand_g_c_per_timestep = respiration_demand_g_c,
        .presence_threshold_g_c = presence_threshold_g_c,
        .phenological_senescence_fraction = phenological_senescence_fraction,
        .sapwood_recycling = .{ .carbon = scaled_recycling.carbon, .nitrogen = scaled_recycling.nitrogen, .phosphorus = scaled_recycling.phosphorus },
        .woody_fraction = .{ .carbon = woody_carbon_fraction[0], .nitrogen = woody_nitrogen_fraction[0], .phosphorus = woody_phosphorus_fraction[0] },
        .nonwoody_fraction = .{ .carbon = woody_carbon_fraction[1], .nitrogen = woody_nitrogen_fraction[1], .phosphorus = woody_phosphorus_fraction[1] },
        .woody_kinetics = .{ .carbon = &woody_kinetics.carbon, .nitrogen = &woody_kinetics.nitrogen, .phosphorus = &woody_kinetics.phosphorus },
        .stalk_kinetics = .{ .carbon = &stalk_kinetics.carbon, .nitrogen = &stalk_kinetics.nitrogen, .phosphorus = &stalk_kinetics.phosphorus },
    });
    products.recycled_carbon_g = state.branch_reserve_carbon_g[branch] - reserve_carbon_before;
    products.recycled_nitrogen_g = state.branch_reserve_nitrogen_g[branch] - reserve_nitrogen_before;
    products.recycled_phosphorus_g = state.branch_reserve_phosphorus_g[branch] - reserve_phosphorus_before;
    products.respired_carbon_g = respiration_demand_g_c - result.remaining_respiration_g_c_per_timestep - products.recycled_carbon_g;
    return .{ .fraction = result.removal_fraction, .remaining_respiration_demand_g_c = result.remaining_respiration_g_c_per_timestep, .products = products };
}

pub fn state_updateInternodeSenescenceDemand(state: *group_state.State, branch: usize, node_within_branch: usize, respiration_demand_g_c: f64, phenological_senescence_fraction: f64, recycling: group_organ_growth.RecyclingFractions, woody_carbon_fraction: [2]f64, woody_nitrogen_fraction: [2]f64, woody_phosphorus_fraction: [2]f64, woody_kinetics: group_organ_growth.KineticFractions, stalk_kinetics: group_organ_growth.KineticFractions) !InternodeSenescenceResult {
    inline for (.{ respiration_demand_g_c, phenological_senescence_fraction, recycling.carbon, recycling.nitrogen, recycling.phosphorus }) |value| if (!std.math.isFinite(value)) return error.NonFiniteInternodeSenescenceInput;
    if (respiration_demand_g_c < 0 or phenological_senescence_fraction < 0 or phenological_senescence_fraction > 1 or recycling.carbon < 0 or recycling.carbon > 1 or recycling.nitrogen < 0 or recycling.nitrogen > 1 or recycling.phosphorus < 0 or recycling.phosphorus > 1) return error.InvalidInternodeSenescenceInput;
    inline for (.{ woody_carbon_fraction, woody_nitrogen_fraction, woody_phosphorus_fraction }) |fractions| {
        for (fractions) |fraction| if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidWoodyFraction;
        if (@abs(fractions[0] + fractions[1] - 1.0) > 1e-8) return error.InvalidWoodyFraction;
    }
    try woody_kinetics.validate();
    try stalk_kinetics.validate();
    const nodes = try state.nodeRange(branch);
    if (node_within_branch >= nodes.end - nodes.first) return error.CanopyNodeIndexOutOfBounds;
    const node = nodes.first + node_within_branch;
    const stalk_c = state.branch_stalk_carbon_g[branch];
    if (stalk_c <= 0) return .{ .fraction = 0, .remaining_respiration_demand_g_c = respiration_demand_g_c, .products = .{} };
    const sapwood_fraction = std.math.clamp(state.branch_sapwood_carbon_g[branch] / stalk_c, 0, 1);
    const effective_c_recycling = recycling.carbon * sapwood_fraction;
    const effective_n_recycling = recycling.nitrogen * sapwood_fraction;
    const effective_p_recycling = recycling.phosphorus * sapwood_fraction;
    const node_c = state.node_internode_carbon_g[node];
    const node_n = state.node_internode_nitrogen_g[node];
    const node_p = state.node_internode_phosphorus_g[node];
    if (node_c <= 0) return .{ .fraction = 0, .remaining_respiration_demand_g_c = respiration_demand_g_c, .products = .{} };
    const recycled_c = effective_c_recycling * node_c;
    const recycled_n = node_n * (effective_n_recycling + (1.0 - effective_n_recycling) * effective_c_recycling);
    const recycled_p = node_p * (effective_p_recycling + (1.0 - effective_p_recycling) * effective_c_recycling);
    const fraction = if (recycled_c > 0) std.math.clamp(respiration_demand_g_c / recycled_c, 0, 1) else 1;
    const consumed_recycled_c = fraction * recycled_c * woody_carbon_fraction[1];
    var products: group_senescence.SenescenceProducts = .{
        .recycled_carbon_g = consumed_recycled_c * phenological_senescence_fraction,
        .recycled_nitrogen_g = fraction * recycled_n * woody_nitrogen_fraction[1],
        .recycled_phosphorus_g = fraction * recycled_p * woody_phosphorus_fraction[1],
        .respired_carbon_g = consumed_recycled_c * (1.0 - phenological_senescence_fraction),
    };
    for (0..4) |kinetic| {
        products.woody_carbon_g[kinetic] = woody_kinetics.carbon[kinetic] * fraction * node_c * woody_carbon_fraction[0];
        products.woody_nitrogen_g[kinetic] = woody_kinetics.nitrogen[kinetic] * fraction * node_n * woody_nitrogen_fraction[0];
        products.woody_phosphorus_g[kinetic] = woody_kinetics.phosphorus[kinetic] * fraction * node_p * woody_phosphorus_fraction[0];
        products.nonwoody_carbon_g[kinetic] = stalk_kinetics.carbon[kinetic] * fraction * (node_c - recycled_c) * woody_carbon_fraction[1];
        products.nonwoody_nitrogen_g[kinetic] = stalk_kinetics.nitrogen[kinetic] * fraction * (node_n - recycled_n) * woody_nitrogen_fraction[1];
        products.nonwoody_phosphorus_g[kinetic] = stalk_kinetics.phosphorus[kinetic] * fraction * (node_p - recycled_p) * woody_phosphorus_fraction[1];
    }
    state.branch_stalk_carbon_g[branch] = @max(0.0, state.branch_stalk_carbon_g[branch] - fraction * node_c);
    state.branch_stalk_nitrogen_g[branch] = @max(0.0, state.branch_stalk_nitrogen_g[branch] - fraction * node_n);
    state.branch_stalk_phosphorus_g[branch] = @max(0.0, state.branch_stalk_phosphorus_g[branch] - fraction * node_p);
    state.node_height_m[node] = @max(0.0, state.node_height_m[node] - fraction * state.node_internode_length_m[node]);
    state.node_internode_carbon_g[node] *= 1.0 - fraction;
    state.node_internode_nitrogen_g[node] *= 1.0 - fraction;
    state.node_internode_phosphorus_g[node] *= 1.0 - fraction;
    state.node_internode_length_m[node] *= 1.0 - fraction;
    state.branch_reserve_carbon_g[branch] += products.recycled_carbon_g;
    state.branch_reserve_nitrogen_g[branch] += products.recycled_nitrogen_g;
    state.branch_reserve_phosphorus_g[branch] += products.recycled_phosphorus_g;
    return .{ .fraction = fraction, .remaining_respiration_demand_g_c = @max(0.0, respiration_demand_g_c - consumed_recycled_c), .products = products };
}

/// GROSUB leaf structural nutrient equilibration. The 1e-3 exchange
/// coefficient and coupled 10:1 N:P bounds are retained from the source.
pub fn remobilizeNodeLeafNutrients(state: *group_state.State, branch: usize, node_within_branch: usize, exchange_fraction: f64, minimum_leaf_nutrient_fraction: f64, maximum_leaf_nitrogen_per_carbon_g_n_per_g_c: f64, maximum_leaf_phosphorus_per_carbon_g_p_per_g_c: f64, protein_per_nitrogen_g_per_g_n: f64, protein_per_phosphorus_g_per_g_p: f64) !group_misc.LeafNutrientRemobilization {
    inline for (.{ exchange_fraction, minimum_leaf_nutrient_fraction, maximum_leaf_nitrogen_per_carbon_g_n_per_g_c, maximum_leaf_phosphorus_per_carbon_g_p_per_g_c, protein_per_nitrogen_g_per_g_n, protein_per_phosphorus_g_per_g_p }) |value| if (!std.math.isFinite(value)) return error.NonFiniteLeafNutrientRemobilizationInput;
    if (exchange_fraction < 0 or minimum_leaf_nutrient_fraction < 0 or minimum_leaf_nutrient_fraction > 1 or maximum_leaf_nitrogen_per_carbon_g_n_per_g_c < 0 or maximum_leaf_phosphorus_per_carbon_g_p_per_g_c < 0 or protein_per_nitrogen_g_per_g_n < 0 or protein_per_phosphorus_g_per_g_p < 0) return error.InvalidLeafNutrientRemobilizationInput;
    const nodes = try state.nodeRange(branch);
    if (node_within_branch >= nodes.end - nodes.first) return error.CanopyNodeIndexOutOfBounds;
    const node = nodes.first + node_within_branch;
    const leaf_c = state.node_leaf_carbon_g[node];
    const leaf_n = state.node_leaf_nitrogen_g[node];
    const leaf_p = state.node_leaf_phosphorus_g[node];
    if (leaf_c <= 0) return .{ .nitrogen_g = 0, .phosphorus_g = 0 };
    const total_carbon_g = leaf_c + state.branch_mobile_carbon_g[branch];
    if (total_carbon_g <= 0) return .{ .nitrogen_g = 0, .phosphorus_g = 0 };
    const nitrogen_gradient_g2 = leaf_n * state.branch_mobile_carbon_g[branch] - state.branch_mobile_nitrogen_g[branch] * leaf_c;
    const phosphorus_gradient_g2 = leaf_p * state.branch_mobile_carbon_g[branch] - state.branch_mobile_phosphorus_g[branch] * leaf_c;
    const unconstrained_n = @max(0.0, exchange_fraction * nitrogen_gradient_g2 / total_carbon_g);
    const unconstrained_p = @max(0.0, exchange_fraction * phosphorus_gradient_g2 / total_carbon_g);
    const removable_n = @max(0.0, leaf_n - minimum_leaf_nutrient_fraction * maximum_leaf_nitrogen_per_carbon_g_n_per_g_c * leaf_c);
    const removable_p = @max(0.0, leaf_p - minimum_leaf_nutrient_fraction * maximum_leaf_phosphorus_per_carbon_g_p_per_g_c * leaf_c);
    const base_n = @min(unconstrained_n, removable_n);
    const base_p = @min(unconstrained_p, removable_p);
    const nitrogen_g = @min(leaf_n, @max(base_n, 10.0 * base_p));
    const phosphorus_g = @min(leaf_p, @max(base_p, 0.1 * base_n));
    state.node_leaf_nitrogen_g[node] -= nitrogen_g;
    state.branch_leaf_nitrogen_g[branch] = @max(0.0, state.branch_leaf_nitrogen_g[branch] - nitrogen_g);
    state.branch_mobile_nitrogen_g[branch] += nitrogen_g;
    state.node_leaf_phosphorus_g[node] -= phosphorus_g;
    state.branch_leaf_phosphorus_g[branch] = @max(0.0, state.branch_leaf_phosphorus_g[branch] - phosphorus_g);
    state.branch_mobile_phosphorus_g[branch] += phosphorus_g;
    state.node_leaf_protein_g[node] = @max(0.0, state.node_leaf_protein_g[node] - @max(nitrogen_g * protein_per_nitrogen_g_per_g_n, phosphorus_g * protein_per_phosphorus_g_per_g_p));
    return .{ .nitrogen_g = nitrogen_g, .phosphorus_g = phosphorus_g };
}

pub const SourceOrderGrazingNodeRemoval = struct {
    remaining_fraction: f64,
    remaining_branch_layer_demand_g_c: f64,
};

/// Exact GROSUB 8864-8897 branch-layer demand and node retention selector.
pub fn sourceOrderGrazingNodeRemoval(
    node_layer_carbon_g_c: f64,
    branch_layer_demand_g_c: f64,
) !SourceOrderGrazingNodeRemoval {
    inline for (.{ node_layer_carbon_g_c, branch_layer_demand_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidGrazingPool;
    if (branch_layer_demand_g_c == 0) return .{
        .remaining_fraction = 1,
        .remaining_branch_layer_demand_g_c = 0,
    };
    const remaining_fraction = if (node_layer_carbon_g_c > branch_layer_demand_g_c)
        @max(0, @min(1, (node_layer_carbon_g_c - branch_layer_demand_g_c) / node_layer_carbon_g_c))
    else
        1;
    return .{
        .remaining_fraction = remaining_fraction,
        .remaining_branch_layer_demand_g_c = branch_layer_demand_g_c -
            (1 - remaining_fraction) * node_layer_carbon_g_c,
    };
}

/// Exact GROSUB 8864-8870 plant-to-branch-layer grazing allocation.
pub fn sourceOrderBranchLayerLeafDemand(
    plant_leaf_carbon_g_c: f64,
    plant_structural_leaf_removal_g_c: f64,
    branch_layer_leaf_carbon_g_c: f64,
    plant_leaf_presence_threshold_g_c: f64,
) !f64 {
    inline for (.{
        plant_leaf_carbon_g_c,
        plant_structural_leaf_removal_g_c,
        branch_layer_leaf_carbon_g_c,
        plant_leaf_presence_threshold_g_c,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidGrazingPool;
    if (plant_leaf_carbon_g_c <= plant_leaf_presence_threshold_g_c) return 0;
    const demand = plant_structural_leaf_removal_g_c *
        @max(0, branch_layer_leaf_carbon_g_c) / plant_leaf_carbon_g_c;
    if (!std.math.isFinite(demand)) return error.NonFiniteGrazingAllocationInput;
    return demand;
}

pub const LayerHarvestRetention = struct { remaining_fraction: f64, unexported_fraction: f64, height_below_cut_fraction: f64 };

pub const RemainingNodeLeaf = struct {
    area_m2: f64,
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
    protein_mass_g: f64,
};

/// Exact GROSUB 8962-9051 reconstruction of one node from its runtime layers.
pub fn sourceOrderRemainingNodeLeaf(
    layer_area_m2: []const f64,
    layer_carbon_g_c: []const f64,
    layer_nitrogen_g_n: []const f64,
    layer_phosphorus_g_p: []const f64,
    previous_node_area_m2: f64,
    previous_protein_mass_g: f64,
    plant_presence_threshold: f64,
) !RemainingNodeLeaf {
    const layer_count = layer_area_m2.len;
    if (layer_count == 0 or layer_carbon_g_c.len != layer_count or
        layer_nitrogen_g_n.len != layer_count or layer_phosphorus_g_p.len != layer_count)
        return error.NodeLeafDimensionMismatch;
    inline for (.{ previous_node_area_m2, previous_protein_mass_g, plant_presence_threshold }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidNodeLeafState;
    var result: RemainingNodeLeaf = .{
        .area_m2 = 0,
        .carbon_g_c = 0,
        .nitrogen_g_n = 0,
        .phosphorus_g_p = 0,
        .protein_mass_g = 0,
    };
    for (layer_area_m2, layer_carbon_g_c, layer_nitrogen_g_n, layer_phosphorus_g_p) |area, carbon, nitrogen, phosphorus| {
        inline for (.{ area, carbon, nitrogen, phosphorus }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidNodeLeafState;
        result.area_m2 += area;
        result.carbon_g_c += carbon;
        result.nitrogen_g_n += nitrogen;
        result.phosphorus_g_p += phosphorus;
    }
    result.protein_mass_g = if (previous_node_area_m2 > plant_presence_threshold)
        previous_protein_mass_g * result.area_m2 / previous_node_area_m2
    else
        0;
    return result;
}

/// Exact GROSUB 8999-9022 retained-plant and retained-ecosystem fractions for
/// sheath/petiole and internode processing after leaf reconstruction.
pub fn sourceOrderNodeOrganRetention(
    grazing: bool,
    no_harvest_kind: bool,
    previous_leaf_carbon_g_c: f64,
    remaining_leaf_carbon_g_c: f64,
    leaf_harvest_fraction: f64,
    nonfoliar_harvest_fraction: f64,
    thinning_fraction: f64,
    plant_presence_threshold_g_c: f64,
) !LayerHarvestRetention {
    inline for (.{
        previous_leaf_carbon_g_c,
        remaining_leaf_carbon_g_c,
        leaf_harvest_fraction,
        nonfoliar_harvest_fraction,
        thinning_fraction,
        plant_presence_threshold_g_c,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidLayerHarvestInput;
    if (remaining_leaf_carbon_g_c > previous_leaf_carbon_g_c or leaf_harvest_fraction > 1 or
        nonfoliar_harvest_fraction > 1 or thinning_fraction > 1)
        return error.InvalidLayerHarvestInput;
    if (grazing) return .{ .remaining_fraction = 0, .unexported_fraction = 0, .height_below_cut_fraction = 0 };
    if (previous_leaf_carbon_g_c > plant_presence_threshold_g_c and leaf_harvest_fraction > 0) {
        const retention = @max(0, @min(1, 1 -
            (1 - @max(0, remaining_leaf_carbon_g_c) / previous_leaf_carbon_g_c) *
                nonfoliar_harvest_fraction / leaf_harvest_fraction));
        return .{ .remaining_fraction = retention, .unexported_fraction = retention, .height_below_cut_fraction = 0 };
    }
    if (thinning_fraction == 0) {
        const retention = 1 - nonfoliar_harvest_fraction;
        return .{ .remaining_fraction = retention, .unexported_fraction = retention, .height_below_cut_fraction = 0 };
    }
    const remaining = 1 - thinning_fraction;
    const unexported = if (no_harvest_kind)
        1 - nonfoliar_harvest_fraction * thinning_fraction
    else
        remaining;
    return .{ .remaining_fraction = remaining, .unexported_fraction = unexported, .height_below_cut_fraction = 0 };
}

pub fn layerHarvestRetention(layer_lower_height_m: f64, layer_upper_height_m: f64, cutting_height_m: f64, pruning: bool, no_harvest_kind: bool, thinning_fraction: f64, harvested_fraction: f64) !LayerHarvestRetention {
    inline for (.{ layer_lower_height_m, layer_upper_height_m, cutting_height_m, thinning_fraction, harvested_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteLayerHarvestInput;
    if (layer_upper_height_m < layer_lower_height_m or thinning_fraction < 0 or thinning_fraction > 1 or harvested_fraction < 0 or harvested_fraction > 1) return error.InvalidLayerHarvestInput;
    const height_fraction = if (pruning) 0 else if (layer_upper_height_m > layer_lower_height_m) std.math.clamp(1.0 - (layer_upper_height_m - cutting_height_m) / (layer_upper_height_m - layer_lower_height_m), 0, 1) else 1;
    if (thinning_fraction == 0) {
        const retention = @max(0.0, 1.0 - (1.0 - height_fraction) * harvested_fraction);
        return .{ .remaining_fraction = retention, .unexported_fraction = retention, .height_below_cut_fraction = height_fraction };
    }
    const remaining = @max(0.0, 1.0 - thinning_fraction);
    const unexported = if (no_harvest_kind) 1.0 - (1.0 - height_fraction) * harvested_fraction * thinning_fraction else remaining;
    return .{ .remaining_fraction = remaining, .unexported_fraction = unexported, .height_below_cut_fraction = height_fraction };
}

pub const LayerLeafHarvestProducts = struct {
    foliar: group_harvest.HarvestProducts = .{},
    woody: group_harvest.HarvestProducts = .{},
    removed_leaf_area_m2: f64 = 0,
};

pub const NodeOrganHarvestProducts = struct { nonwoody: group_harvest.HarvestProducts = .{}, woody: group_harvest.HarvestProducts = .{} };

/// StateUpdates GROSUB WGLFL/WGLFLN/WGLFLP/ARLFL removal for one runtime
/// canopy layer sample and reconciles its node and branch aggregates.
pub fn harvestLeafLayerSample(state: *group_state.State, branch: usize, node_within_branch: usize, sample_within_node: usize, retention: LayerHarvestRetention, carbon_woody_fraction: [2]f64, nitrogen_woody_fraction: [2]f64, phosphorus_woody_fraction: [2]f64, scale_stalk_area: bool) !LayerLeafHarvestProducts {
    inline for (.{ carbon_woody_fraction, nitrogen_woody_fraction, phosphorus_woody_fraction }) |fractions| {
        for (fractions) |fraction| if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidWoodyFraction;
        if (@abs(fractions[0] + fractions[1] - 1.0) > 1e-8) return error.InvalidWoodyFraction;
    }
    if (!std.math.isFinite(retention.remaining_fraction) or !std.math.isFinite(retention.unexported_fraction) or retention.remaining_fraction < 0 or retention.unexported_fraction < retention.remaining_fraction or retention.unexported_fraction > 1) return error.InvalidHarvestRetentionFraction;
    const nodes = try state.nodeRange(branch);
    if (node_within_branch >= nodes.end - nodes.first) return error.CanopyNodeIndexOutOfBounds;
    const node = nodes.first + node_within_branch;
    const samples = try state.sampleRange(node);
    if (sample_within_node >= samples.end - samples.first) return error.CanopySampleIndexOutOfBounds;
    const sample = samples.first + sample_within_node;
    const initial_mass: group_state.ElementalMass = .{ .carbon_g = state.sample_leaf_carbon_g[sample], .nitrogen_g = state.sample_leaf_nitrogen_g[sample], .phosphorus_g = state.sample_leaf_phosphorus_g[sample] };
    inline for (@typeInfo(group_state.ElementalMass).@"struct".fields) |field| if (!std.math.isFinite(@field(initial_mass, field.name)) or @field(initial_mass, field.name) < 0) return error.InvalidHarvestMass;
    const initial_area_m2 = state.sample_leaf_area_m2[sample];
    if (!std.math.isFinite(initial_area_m2) or initial_area_m2 < 0) return error.InvalidLeafAreaHarvestGeometry;
    const removed_fraction = 1.0 - retention.remaining_fraction;
    const export_fraction = 1.0 - retention.unexported_fraction;
    const litter_fraction = retention.unexported_fraction - retention.remaining_fraction;
    var result: LayerLeafHarvestProducts = .{ .removed_leaf_area_m2 = removed_fraction * initial_area_m2 };
    inline for (@typeInfo(group_state.ElementalMass).@"struct".fields, .{ carbon_woody_fraction, nitrogen_woody_fraction, phosphorus_woody_fraction }) |field, fractions| {
        const initial = @field(initial_mass, field.name);
        @field(result.woody.ecosystem_export, field.name) = export_fraction * initial * fractions[0];
        @field(result.woody.litter, field.name) = litter_fraction * initial * fractions[0];
        @field(result.foliar.ecosystem_export, field.name) = export_fraction * initial * fractions[1];
        @field(result.foliar.litter, field.name) = litter_fraction * initial * fractions[1];
    }
    const old_node_area_m2 = state.node_leaf_area_m2[node];
    const next_node_area_m2 = old_node_area_m2 - result.removed_leaf_area_m2;
    const next_node_carbon_g = state.node_leaf_carbon_g[node] - removed_fraction * initial_mass.carbon_g;
    const next_node_nitrogen_g = state.node_leaf_nitrogen_g[node] - removed_fraction * initial_mass.nitrogen_g;
    const next_node_phosphorus_g = state.node_leaf_phosphorus_g[node] - removed_fraction * initial_mass.phosphorus_g;
    const next_branch_area_m2 = state.branch_leaf_area_m2[branch] - result.removed_leaf_area_m2;
    const next_branch_carbon_g = state.branch_leaf_carbon_g[branch] - removed_fraction * initial_mass.carbon_g;
    const next_branch_nitrogen_g = state.branch_leaf_nitrogen_g[branch] - removed_fraction * initial_mass.nitrogen_g;
    const next_branch_phosphorus_g = state.branch_leaf_phosphorus_g[branch] - removed_fraction * initial_mass.phosphorus_g;
    inline for (.{
        next_node_area_m2,   next_node_carbon_g,   next_node_nitrogen_g,   next_node_phosphorus_g,
        next_branch_area_m2, next_branch_carbon_g, next_branch_nitrogen_g, next_branch_phosphorus_g,
    }) |next| if (!std.math.isFinite(next) or next < 0) return error.LeafHarvestWouldOverdrawAggregate;
    const next_node_protein_g = state.node_leaf_protein_g[node] * (if (old_node_area_m2 > 0) next_node_area_m2 / old_node_area_m2 else 0);
    if (!std.math.isFinite(next_node_protein_g) or next_node_protein_g < 0) return error.LeafHarvestWouldOverdrawAggregate;
    state.sample_leaf_area_m2[sample] = retention.remaining_fraction * initial_area_m2;
    state.sample_leaf_carbon_g[sample] = retention.remaining_fraction * initial_mass.carbon_g;
    state.sample_leaf_nitrogen_g[sample] = retention.remaining_fraction * initial_mass.nitrogen_g;
    state.sample_leaf_phosphorus_g[sample] = retention.remaining_fraction * initial_mass.phosphorus_g;
    state.sample_exposed_leaf_area_m2[sample] *= retention.remaining_fraction;
    if (scale_stalk_area) state.sample_stalk_area_m2[sample] *= retention.remaining_fraction;
    state.node_leaf_area_m2[node] = next_node_area_m2;
    state.node_leaf_carbon_g[node] = next_node_carbon_g;
    state.node_leaf_nitrogen_g[node] = next_node_nitrogen_g;
    state.node_leaf_phosphorus_g[node] = next_node_phosphorus_g;
    state.node_leaf_protein_g[node] = next_node_protein_g;
    state.branch_leaf_area_m2[branch] = next_branch_area_m2;
    state.branch_leaf_carbon_g[branch] = next_branch_carbon_g;
    state.branch_leaf_nitrogen_g[branch] = next_branch_nitrogen_g;
    state.branch_leaf_phosphorus_g[branch] = next_branch_phosphorus_g;
    return result;
}

/// StateUpdates GROSUB sheath/petiole removal for one node. Direct cutting uses
/// geometric truncation at the cutting plane; pruning, thinning, and grazing
/// scale length with retained biomass as in the source branches.
pub fn harvestNodeSheath(state: *group_state.State, branch: usize, node_within_branch: usize, remaining_fraction: f64, unexported_fraction: f64, carbon_woody_fraction: [2]f64, nitrogen_woody_fraction: [2]f64, phosphorus_woody_fraction: [2]f64, use_cutting_plane: bool, cutting_height_m: f64) !NodeOrganHarvestProducts {
    if (!std.math.isFinite(remaining_fraction) or !std.math.isFinite(unexported_fraction) or !std.math.isFinite(cutting_height_m) or remaining_fraction < 0 or unexported_fraction < remaining_fraction or unexported_fraction > 1 or cutting_height_m < 0) return error.InvalidNodeSheathHarvestInput;
    inline for (.{ carbon_woody_fraction, nitrogen_woody_fraction, phosphorus_woody_fraction }) |fractions| {
        for (fractions) |fraction| if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidWoodyFraction;
        if (@abs(fractions[0] + fractions[1] - 1.0) > 1e-8) return error.InvalidWoodyFraction;
    }
    const nodes = try state.nodeRange(branch);
    if (node_within_branch >= nodes.end - nodes.first) return error.CanopyNodeIndexOutOfBounds;
    const node = nodes.first + node_within_branch;
    const initial_mass: group_state.ElementalMass = .{ .carbon_g = state.node_sheath_carbon_g[node], .nitrogen_g = state.node_sheath_nitrogen_g[node], .phosphorus_g = state.node_sheath_phosphorus_g[node] };
    inline for (@typeInfo(group_state.ElementalMass).@"struct".fields) |field| if (!std.math.isFinite(@field(initial_mass, field.name)) or @field(initial_mass, field.name) < 0) return error.InvalidHarvestMass;
    const export_fraction = 1.0 - unexported_fraction;
    const litter_fraction = unexported_fraction - remaining_fraction;
    var result: NodeOrganHarvestProducts = .{};
    inline for (@typeInfo(group_state.ElementalMass).@"struct".fields, .{ carbon_woody_fraction, nitrogen_woody_fraction, phosphorus_woody_fraction }) |field, fractions| {
        const initial = @field(initial_mass, field.name);
        @field(result.woody.ecosystem_export, field.name) = export_fraction * initial * fractions[0];
        @field(result.woody.litter, field.name) = litter_fraction * initial * fractions[0];
        @field(result.nonwoody.ecosystem_export, field.name) = export_fraction * initial * fractions[1];
        @field(result.nonwoody.litter, field.name) = litter_fraction * initial * fractions[1];
    }
    const removed_fraction = 1.0 - remaining_fraction;
    const next_branch_carbon_g = state.branch_sheath_carbon_g[branch] - removed_fraction * initial_mass.carbon_g;
    const next_branch_nitrogen_g = state.branch_sheath_nitrogen_g[branch] - removed_fraction * initial_mass.nitrogen_g;
    const next_branch_phosphorus_g = state.branch_sheath_phosphorus_g[branch] - removed_fraction * initial_mass.phosphorus_g;
    inline for (.{ next_branch_carbon_g, next_branch_nitrogen_g, next_branch_phosphorus_g }) |next|
        if (!std.math.isFinite(next) or next < 0) return error.SheathHarvestWouldOverdrawAggregate;
    state.node_sheath_carbon_g[node] *= remaining_fraction;
    state.node_sheath_nitrogen_g[node] *= remaining_fraction;
    state.node_sheath_phosphorus_g[node] *= remaining_fraction;
    state.node_sheath_protein_g[node] *= remaining_fraction;
    state.branch_sheath_carbon_g[branch] = next_branch_carbon_g;
    state.branch_sheath_nitrogen_g[branch] = next_branch_nitrogen_g;
    state.branch_sheath_phosphorus_g[branch] = next_branch_phosphorus_g;
    const initial_height_m = state.node_sheath_height_m[node];
    if (use_cutting_plane and initial_height_m > 0) {
        const fraction_above_cut = std.math.clamp((state.node_height_m[node] + initial_height_m - cutting_height_m) / initial_height_m, 0, 1);
        state.node_sheath_height_m[node] = (1.0 - fraction_above_cut) * initial_height_m;
    } else state.node_sheath_height_m[node] *= remaining_fraction;
    return result;
}

pub fn internodeHarvestRetention(node_height_m: f64, internode_length_m: f64, cutting_height_m: f64, pruning: bool, thinning_fraction: f64, woody_harvest_fraction: f64, grazing: bool, grazed_stalk_carbon_g: f64, total_stalk_carbon_g: f64) !f64 {
    inline for (.{ node_height_m, internode_length_m, cutting_height_m, thinning_fraction, woody_harvest_fraction, grazed_stalk_carbon_g, total_stalk_carbon_g }) |value| if (!std.math.isFinite(value)) return error.NonFiniteInternodeHarvestInput;
    if (node_height_m < 0 or internode_length_m < 0 or cutting_height_m < 0 or thinning_fraction < 0 or thinning_fraction > 1 or woody_harvest_fraction < 0 or woody_harvest_fraction > 1 or grazed_stalk_carbon_g < 0 or total_stalk_carbon_g < 0) return error.InvalidInternodeHarvestInput;
    if (grazing) return if (total_stalk_carbon_g > 0) std.math.clamp(1.0 - grazed_stalk_carbon_g / total_stalk_carbon_g, 0, 1) else 1;
    if (internode_length_m <= 0) return 1;
    const fraction_above_cut = if (pruning) 0 else std.math.clamp((node_height_m - cutting_height_m) / internode_length_m, 0, 1);
    return if (thinning_fraction == 0) @max(0.0, 1.0 - fraction_above_cut * woody_harvest_fraction) else @max(0.0, 1.0 - thinning_fraction);
}

/// Applies the source node-stalk retention after branch-level harvested stalk
/// products have been accounted for.
pub fn state_updateInternodeHarvest(state: *group_state.State, branch: usize, node_within_branch: usize, remaining_fraction: f64, direct_cut_without_thinning: bool, cutting_height_m: f64) !void {
    if (!std.math.isFinite(remaining_fraction) or !std.math.isFinite(cutting_height_m) or remaining_fraction < 0 or remaining_fraction > 1 or cutting_height_m < 0) return error.InvalidInternodeHarvestInput;
    const nodes = try state.nodeRange(branch);
    if (node_within_branch >= nodes.end - nodes.first) return error.CanopyNodeIndexOutOfBounds;
    const node = nodes.first + node_within_branch;
    state.node_internode_carbon_g[node] *= remaining_fraction;
    state.node_internode_nitrogen_g[node] *= remaining_fraction;
    state.node_internode_phosphorus_g[node] *= remaining_fraction;
    if (direct_cut_without_thinning) {
        state.node_internode_length_m[node] *= remaining_fraction;
        state.node_height_m[node] = @min(state.node_height_m[node], cutting_height_m);
    }
}

pub const SelectedNodeSenescenceRequest = struct {
    lowest_node_remobilization_enabled: bool,
    refresh_snapshot: bool,
    newest_node_within_branch: usize,
    requested_remobilization_fraction: f64,
    structural_presence_threshold_g_c: f64,
};

/// GROSUB 2542--2779 selected-oldest-node transaction. Runtime ordinals replace
/// the modulo-25 ring: once the 25th retained leaf exists, its oldest node is
/// `newest - 24`. Every projection is validated before any canopy or litter
/// state is committed, so a late C/N/P, protein, or overflow error is atomic.
pub fn state_updateSelectedNodeSenescence(
    state: *group_state.State,
    branch: usize,
    request: SelectedNodeSenescenceRequest,
    recycling: group_organ_growth.RecyclingFractions,
    protein_per_nitrogen_g_per_g_n: f64,
    protein_per_phosphorus_g_per_g_p: f64,
    litter: group_senescence.SenescenceLitterParameters,
    accumulated_products: *group_senescence.SenescenceProducts,
) !bool {
    if (!request.lowest_node_remobilization_enabled or request.newest_node_within_branch < 24)
        return false;
    const nodes = try state.nodeRange(branch);
    const node_count = nodes.end - nodes.first;
    if (request.newest_node_within_branch >= node_count) return error.CanopyNodeIndexOutOfBounds;
    const selected = request.newest_node_within_branch - 24;
    const node = nodes.first + selected;
    inline for (.{
        request.requested_remobilization_fraction,
        request.structural_presence_threshold_g_c,
        protein_per_nitrogen_g_per_g_n,
        protein_per_phosphorus_g_per_g_p,
        recycling.carbon,
        recycling.nitrogen,
        recycling.phosphorus,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSelectedNodeSenescenceInput;
    if (request.requested_remobilization_fraction < 0 or request.structural_presence_threshold_g_c < 0 or
        protein_per_nitrogen_g_per_g_n < 0 or protein_per_phosphorus_g_per_g_p < 0)
        return error.InvalidSelectedNodeSenescenceInput;
    inline for (.{ recycling.carbon, recycling.nitrogen, recycling.phosphorus }) |value|
        if (value < 0 or value > 1) return error.InvalidSelectedNodeSenescenceInput;
    try litter.woody_kinetics.validate();
    try litter.leaf_kinetics.validate();
    try litter.sheath_kinetics.validate();
    inline for (.{
        litter.woody_carbon_fraction,
        litter.leaf_woody_nitrogen_fraction,
        litter.leaf_woody_phosphorus_fraction,
        litter.sheath_woody_nitrogen_fraction,
        litter.sheath_woody_phosphorus_fraction,
    }) |fractions| {
        inline for (fractions) |value| if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidSelectedNodeSenescenceLitterFraction;
        if (@abs(fractions[0] + fractions[1] - 1) > 1.0e-12)
            return error.InvalidSelectedNodeSenescenceLitterFraction;
    }

    const leaf_nodes: leaf_senescence_snapshot.NodeState = .{
        .leaf_carbon_g_c = state.node_leaf_carbon_g[nodes.first..nodes.end],
        .leaf_nitrogen_g_n = state.node_leaf_nitrogen_g[nodes.first..nodes.end],
        .leaf_phosphorus_g_p = state.node_leaf_phosphorus_g[nodes.first..nodes.end],
        .leaf_area_m2 = state.node_leaf_area_m2[nodes.first..nodes.end],
    };
    var fresh_sheath: ?sheath_senescence_snapshot.Prepared = null;
    const leaf_snapshot = if (request.refresh_snapshot)
        (try leaf_senescence_snapshot.prepare(true, leaf_nodes, selected, request.structural_presence_threshold_g_c, request.requested_remobilization_fraction, .{
            .carbon = recycling.carbon,
            .nitrogen = recycling.nitrogen,
            .phosphorus = recycling.phosphorus,
        })).?
    else
        leaf_senescence_snapshot.Snapshot{
            .leaf_carbon_g_c = state.branch_senescing_leaf_carbon_g[branch],
            .leaf_nitrogen_g_n = state.branch_senescing_leaf_nitrogen_g[branch],
            .leaf_phosphorus_g_p = state.branch_senescing_leaf_phosphorus_g[branch],
            .leaf_area_m2 = state.branch_senescing_leaf_area_m2[branch],
            .remobilizable_carbon_g_c = state.branch_senescing_leaf_remobilizable_carbon_g[branch],
            .remobilizable_nitrogen_g_n = state.branch_senescing_leaf_remobilizable_nitrogen_g[branch],
            .remobilizable_phosphorus_g_p = state.branch_senescing_leaf_remobilizable_phosphorus_g[branch],
            .leaf_remobilization_fraction = 0,
            .leaf_area_remobilization_fraction = 0,
        };

    if (request.refresh_snapshot) fresh_sheath = (try sheath_senescence_snapshot.preview(true, .{
        .sheath_carbon_g_c = state.node_sheath_carbon_g[nodes.first..nodes.end],
        .sheath_nitrogen_g_n = state.node_sheath_nitrogen_g[nodes.first..nodes.end],
        .sheath_phosphorus_g_p = state.node_sheath_phosphorus_g[nodes.first..nodes.end],
        .sheath_height_m = state.node_sheath_height_m[nodes.first..nodes.end],
        .internode_carbon_g_c = state.node_internode_carbon_g[nodes.first..nodes.end],
        .internode_nitrogen_g_n = state.node_internode_nitrogen_g[nodes.first..nodes.end],
        .internode_phosphorus_g_p = state.node_internode_phosphorus_g[nodes.first..nodes.end],
        .internode_length_m = state.node_internode_length_m[nodes.first..nodes.end],
        .residual_stalk_carbon_g_c = &state.branch_senescing_stalk_carbon_g[branch],
        .residual_stalk_nitrogen_g_n = &state.branch_senescing_stalk_nitrogen_g[branch],
        .residual_stalk_phosphorus_g_p = &state.branch_senescing_stalk_phosphorus_g[branch],
    }, selected, request.structural_presence_threshold_g_c, .{
        .carbon = recycling.carbon,
        .nitrogen = recycling.nitrogen,
        .phosphorus = recycling.phosphorus,
    })).?;
    const sheath_snapshot = if (fresh_sheath) |fresh| fresh.snapshot else sheath_senescence_snapshot.Snapshot{
        .sheath_carbon_g_c = state.branch_senescing_sheath_carbon_g[branch],
        .sheath_nitrogen_g_n = state.branch_senescing_sheath_nitrogen_g[branch],
        .sheath_phosphorus_g_p = state.branch_senescing_sheath_phosphorus_g[branch],
        .sheath_height_m = state.branch_senescing_sheath_height_m[branch],
        .remobilizable_carbon_g_c = state.branch_senescing_sheath_remobilizable_carbon_g[branch],
        .remobilizable_nitrogen_g_n = state.branch_senescing_sheath_remobilizable_nitrogen_g[branch],
        .remobilizable_phosphorus_g_p = state.branch_senescing_sheath_remobilizable_phosphorus_g[branch],
    };

    const leaf_fraction = try leaf_senescence_snapshot.removalFraction(
        state.node_leaf_carbon_g[node],
        leaf_snapshot.leaf_carbon_g_c,
        request.structural_presence_threshold_g_c,
        request.requested_remobilization_fraction,
    );
    // GROSUB 2975--2981 transfers the same accepted leaf fraction of the
    // selected node's CPOOL3/CPOOL4 into nonwoody foliar kinetic pool 2.
    // Stage these values with the rest of the selected-node transaction so a
    // later litter overflow cannot leave either C4 carrier partially updated.
    const c4_bundle_sheath_before_g_c = state.node_c3_nonstructural_carbon_g[node];
    const c4_mesophyll_before_g_c = state.node_c4_mesophyll_nonstructural_carbon_g[node];
    inline for (.{ c4_bundle_sheath_before_g_c, c4_mesophyll_before_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidC4LeafCarbonState;
    const c4_bundle_sheath_removed_g_c = leaf_fraction * c4_bundle_sheath_before_g_c;
    const c4_mesophyll_removed_g_c = leaf_fraction * c4_mesophyll_before_g_c;
    const c4_bundle_sheath_after_g_c = c4_bundle_sheath_before_g_c - c4_bundle_sheath_removed_g_c;
    const c4_mesophyll_after_g_c = c4_mesophyll_before_g_c - c4_mesophyll_removed_g_c;
    const c4_litter_addition_g_c = c4_bundle_sheath_removed_g_c + c4_mesophyll_removed_g_c;
    inline for (.{ c4_bundle_sheath_after_g_c, c4_mesophyll_after_g_c, c4_litter_addition_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidC4LeafCarbonRoutingResult;
    const sheath_fraction = try sheath_senescence_fraction.calculate(
        state.node_sheath_carbon_g[nodes.first..nodes.end],
        .{
            .selected_node = selected,
            .requested_remobilization_fraction = request.requested_remobilization_fraction,
            .snapshot_sheath_carbon_g_c = sheath_snapshot.sheath_carbon_g_c,
            .structural_presence_threshold_g_c = request.structural_presence_threshold_g_c,
        },
    );
    const leaf_recycled_c = leaf_fraction * leaf_snapshot.remobilizable_carbon_g_c * litter.woody_carbon_fraction[1];
    const leaf_recycled_n = leaf_fraction * leaf_snapshot.remobilizable_nitrogen_g_n * litter.leaf_woody_nitrogen_fraction[1];
    const leaf_recycled_p = leaf_fraction * leaf_snapshot.remobilizable_phosphorus_g_p * litter.leaf_woody_phosphorus_fraction[1];
    const leaf_next = try leaf_senescence_state_update.calculate(.{
        .branch = .{ .area_m2 = state.branch_leaf_area_m2[branch], .carbon_g_c = state.branch_leaf_carbon_g[branch], .nitrogen_g_n = state.branch_leaf_nitrogen_g[branch], .phosphorus_g_p = state.branch_leaf_phosphorus_g[branch] },
        .node = .{ .area_m2 = state.node_leaf_area_m2[node], .carbon_g_c = state.node_leaf_carbon_g[node], .nitrogen_g_n = state.node_leaf_nitrogen_g[node], .phosphorus_g_p = state.node_leaf_phosphorus_g[node] },
        .node_protein_g = state.node_leaf_protein_g[node],
        .senescing_snapshot = .{ .area_m2 = leaf_snapshot.leaf_area_m2, .carbon_g_c = leaf_snapshot.leaf_carbon_g_c, .nitrogen_g_n = leaf_snapshot.leaf_nitrogen_g_n, .phosphorus_g_p = leaf_snapshot.leaf_phosphorus_g_p },
        .area_removal_fraction = leaf_fraction,
        .mass_removal_fraction = leaf_fraction,
        .protein_per_nitrogen_g_per_g_n = protein_per_nitrogen_g_per_g_n,
        .protein_per_phosphorus_g_per_g_p = protein_per_phosphorus_g_per_g_p,
        .branch_mobile_carbon_g_c = state.branch_mobile_carbon_g[branch],
        .branch_mobile_nitrogen_g_n = state.branch_mobile_nitrogen_g[branch],
        .branch_mobile_phosphorus_g_p = state.branch_mobile_phosphorus_g[branch],
        .recycled_carbon_g_c = leaf_recycled_c,
        .recycled_nitrogen_g_n = leaf_recycled_n,
        .recycled_phosphorus_g_p = leaf_recycled_p,
    });
    inline for (.{ leaf_next.branch, leaf_next.node }) |tissue|
        inline for (@typeInfo(leaf_senescence_state_update.Tissue).@"struct".fields) |field|
            if (@field(tissue, field.name) < 0) return error.NegativeSelectedNodeSenescenceState;
    var projected_mobile_c = leaf_next.branch_mobile_carbon_g_c;
    var projected_mobile_n = leaf_next.branch_mobile_nitrogen_g_n;
    var projected_mobile_p = leaf_next.branch_mobile_phosphorus_g_p;
    const sheath_next = try sheath_senescence_state_update.calculate(.{
        .branch_sheath_carbon_g_c = &state.branch_sheath_carbon_g[branch],
        .branch_sheath_nitrogen_g_n = &state.branch_sheath_nitrogen_g[branch],
        .branch_sheath_phosphorus_g_p = &state.branch_sheath_phosphorus_g[branch],
        .node_sheath_height_m = state.node_sheath_height_m[nodes.first..nodes.end],
        .node_sheath_carbon_g_c = state.node_sheath_carbon_g[nodes.first..nodes.end],
        .node_sheath_nitrogen_g_n = state.node_sheath_nitrogen_g[nodes.first..nodes.end],
        .node_sheath_phosphorus_g_p = state.node_sheath_phosphorus_g[nodes.first..nodes.end],
        .node_sheath_protein_g = state.node_sheath_protein_g[nodes.first..nodes.end],
        .branch_mobile_carbon_g_c = &projected_mobile_c,
        .branch_mobile_nitrogen_g_n = &projected_mobile_n,
        .branch_mobile_phosphorus_g_p = &projected_mobile_p,
    }, .{
        .selected_node = selected,
        .remobilization_fraction = sheath_fraction,
        .protein_per_nitrogen_g_per_g_n = protein_per_nitrogen_g_per_g_n,
        .protein_per_phosphorus_g_per_g_p = protein_per_phosphorus_g_per_g_p,
        .nonwoody_carbon_fraction = litter.woody_carbon_fraction[1],
        .nonwoody_nitrogen_fraction = litter.sheath_woody_nitrogen_fraction[1],
        .nonwoody_phosphorus_fraction = litter.sheath_woody_phosphorus_fraction[1],
        .snapshot = .{
            .sheath_height_m = sheath_snapshot.sheath_height_m,
            .sheath_carbon_g_c = sheath_snapshot.sheath_carbon_g_c,
            .sheath_nitrogen_g_n = sheath_snapshot.sheath_nitrogen_g_n,
            .sheath_phosphorus_g_p = sheath_snapshot.sheath_phosphorus_g_p,
            .remobilizable_carbon_g_c = sheath_snapshot.remobilizable_carbon_g_c,
            .remobilizable_nitrogen_g_n = sheath_snapshot.remobilizable_nitrogen_g_n,
            .remobilizable_phosphorus_g_p = sheath_snapshot.remobilizable_phosphorus_g_p,
        },
    });

    var addition: group_senescence.SenescenceProducts = .{
        .recycled_carbon_g = leaf_recycled_c + sheath_fraction * sheath_snapshot.remobilizable_carbon_g_c * litter.woody_carbon_fraction[1],
        .recycled_nitrogen_g = leaf_recycled_n + sheath_fraction * sheath_snapshot.remobilizable_nitrogen_g_n * litter.sheath_woody_nitrogen_fraction[1],
        .recycled_phosphorus_g = leaf_recycled_p + sheath_fraction * sheath_snapshot.remobilizable_phosphorus_g_p * litter.sheath_woody_phosphorus_fraction[1],
    };
    for (0..4) |kinetic| {
        addition.woody_carbon_g[kinetic] = litter.woody_kinetics.carbon[kinetic] * leaf_fraction * leaf_snapshot.leaf_carbon_g_c * litter.woody_carbon_fraction[0];
        addition.woody_nitrogen_g[kinetic] = litter.woody_kinetics.nitrogen[kinetic] * leaf_fraction * leaf_snapshot.leaf_nitrogen_g_n * litter.leaf_woody_nitrogen_fraction[0];
        addition.woody_phosphorus_g[kinetic] = litter.woody_kinetics.phosphorus[kinetic] * leaf_fraction * leaf_snapshot.leaf_phosphorus_g_p * litter.leaf_woody_phosphorus_fraction[0];
        addition.nonwoody_carbon_g[kinetic] = litter.leaf_kinetics.carbon[kinetic] * leaf_fraction * (leaf_snapshot.leaf_carbon_g_c - leaf_snapshot.remobilizable_carbon_g_c) * litter.woody_carbon_fraction[1];
        addition.nonwoody_nitrogen_g[kinetic] = litter.leaf_kinetics.nitrogen[kinetic] * leaf_fraction * (leaf_snapshot.leaf_nitrogen_g_n - leaf_snapshot.remobilizable_nitrogen_g_n) * litter.leaf_woody_nitrogen_fraction[1];
        addition.nonwoody_phosphorus_g[kinetic] = litter.leaf_kinetics.phosphorus[kinetic] * leaf_fraction * (leaf_snapshot.leaf_phosphorus_g_p - leaf_snapshot.remobilizable_phosphorus_g_p) * litter.leaf_woody_phosphorus_fraction[1];
    }
    addition.nonwoody_carbon_g[1] += c4_litter_addition_g_c;
    if (!std.math.isFinite(addition.nonwoody_carbon_g[1]) or addition.nonwoody_carbon_g[1] < 0)
        return error.InvalidC4LeafCarbonRoutingResult;
    var sheath_products: group_senescence.SenescenceProducts = .{};
    try sheath_senescence_litter_partition.publish(.{
        .carbon_g_c = sheath_snapshot.sheath_carbon_g_c,
        .nitrogen_g_n = sheath_snapshot.sheath_nitrogen_g_n,
        .phosphorus_g_p = sheath_snapshot.sheath_phosphorus_g_p,
        .remobilizable_carbon_g_c = sheath_snapshot.remobilizable_carbon_g_c,
        .remobilizable_nitrogen_g_n = sheath_snapshot.remobilizable_nitrogen_g_n,
        .remobilizable_phosphorus_g_p = sheath_snapshot.remobilizable_phosphorus_g_p,
        .remobilization_fraction = sheath_fraction,
    }, .{
        .carbon = litter.woody_carbon_fraction,
        .nitrogen = litter.sheath_woody_nitrogen_fraction,
        .phosphorus = litter.sheath_woody_phosphorus_fraction,
    }, .{
        .woody = .{ .carbon = &litter.woody_kinetics.carbon, .nitrogen = &litter.woody_kinetics.nitrogen, .phosphorus = &litter.woody_kinetics.phosphorus },
        .sheath = .{ .carbon = &litter.sheath_kinetics.carbon, .nitrogen = &litter.sheath_kinetics.nitrogen, .phosphorus = &litter.sheath_kinetics.phosphorus },
    }, .{
        .woody = .{ .carbon_g_c = &sheath_products.woody_carbon_g, .nitrogen_g_n = &sheath_products.woody_nitrogen_g, .phosphorus_g_p = &sheath_products.woody_phosphorus_g },
        .sheath = .{ .carbon_g_c = &sheath_products.nonwoody_carbon_g, .nitrogen_g_n = &sheath_products.nonwoody_nitrogen_g, .phosphorus_g_p = &sheath_products.nonwoody_phosphorus_g },
    });
    var next_products = accumulated_products.*;
    inline for (@typeInfo(group_senescence.SenescenceProducts).@"struct".fields) |field| {
        if (field.type == f64) {
            const value = @field(next_products, field.name) + @field(addition, field.name) + @field(sheath_products, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.NonFiniteSelectedNodeSenescenceProduct;
            @field(next_products, field.name) = value;
        } else {
            for (0..4) |kinetic| {
                const value = @field(next_products, field.name)[kinetic] + @field(addition, field.name)[kinetic] + @field(sheath_products, field.name)[kinetic];
                if (!std.math.isFinite(value) or value < 0) return error.NonFiniteSelectedNodeSenescenceProduct;
                @field(next_products, field.name)[kinetic] = value;
            }
        }
    }

    if (request.refresh_snapshot) {
        state.branch_senescing_leaf_carbon_g[branch] = leaf_snapshot.leaf_carbon_g_c;
        state.branch_senescing_leaf_nitrogen_g[branch] = leaf_snapshot.leaf_nitrogen_g_n;
        state.branch_senescing_leaf_phosphorus_g[branch] = leaf_snapshot.leaf_phosphorus_g_p;
        state.branch_senescing_leaf_area_m2[branch] = leaf_snapshot.leaf_area_m2;
        state.branch_senescing_leaf_remobilizable_carbon_g[branch] = leaf_snapshot.remobilizable_carbon_g_c;
        state.branch_senescing_leaf_remobilizable_nitrogen_g[branch] = leaf_snapshot.remobilizable_nitrogen_g_n;
        state.branch_senescing_leaf_remobilizable_phosphorus_g[branch] = leaf_snapshot.remobilizable_phosphorus_g_p;
        state.branch_senescing_sheath_carbon_g[branch] = sheath_snapshot.sheath_carbon_g_c;
        state.branch_senescing_sheath_nitrogen_g[branch] = sheath_snapshot.sheath_nitrogen_g_n;
        state.branch_senescing_sheath_phosphorus_g[branch] = sheath_snapshot.sheath_phosphorus_g_p;
        state.branch_senescing_sheath_height_m[branch] = sheath_snapshot.sheath_height_m;
        state.branch_senescing_sheath_remobilizable_carbon_g[branch] = sheath_snapshot.remobilizable_carbon_g_c;
        state.branch_senescing_sheath_remobilizable_nitrogen_g[branch] = sheath_snapshot.remobilizable_nitrogen_g_n;
        state.branch_senescing_sheath_remobilizable_phosphorus_g[branch] = sheath_snapshot.remobilizable_phosphorus_g_p;
        const stalk = fresh_sheath.?;
        state.branch_senescing_stalk_carbon_g[branch] = stalk.residual_stalk_carbon_g_c;
        state.branch_senescing_stalk_nitrogen_g[branch] = stalk.residual_stalk_nitrogen_g_n;
        state.branch_senescing_stalk_phosphorus_g[branch] = stalk.residual_stalk_phosphorus_g_p;
        state.node_internode_carbon_g[node] = 0;
        state.node_internode_nitrogen_g[node] = 0;
        state.node_internode_phosphorus_g[node] = 0;
        state.node_internode_length_m[node] = 0;
    }
    state.branch_leaf_area_m2[branch] = leaf_next.branch.area_m2;
    state.branch_leaf_carbon_g[branch] = leaf_next.branch.carbon_g_c;
    state.branch_leaf_nitrogen_g[branch] = leaf_next.branch.nitrogen_g_n;
    state.branch_leaf_phosphorus_g[branch] = leaf_next.branch.phosphorus_g_p;
    state.node_leaf_area_m2[node] = leaf_next.node.area_m2;
    state.node_leaf_carbon_g[node] = leaf_next.node.carbon_g_c;
    state.node_leaf_nitrogen_g[node] = leaf_next.node.nitrogen_g_n;
    state.node_leaf_phosphorus_g[node] = leaf_next.node.phosphorus_g_p;
    state.node_leaf_protein_g[node] = leaf_next.node_protein_g;
    state.branch_sheath_carbon_g[branch] = sheath_next.branch_carbon_g_c;
    state.branch_sheath_nitrogen_g[branch] = sheath_next.branch_nitrogen_g_n;
    state.branch_sheath_phosphorus_g[branch] = sheath_next.branch_phosphorus_g_p;
    state.node_sheath_height_m[node] = sheath_next.node_height_m;
    state.node_sheath_carbon_g[node] = sheath_next.node_carbon_g_c;
    state.node_sheath_nitrogen_g[node] = sheath_next.node_nitrogen_g_n;
    state.node_sheath_phosphorus_g[node] = sheath_next.node_phosphorus_g_p;
    state.node_sheath_protein_g[node] = sheath_next.node_protein_g;
    state.branch_mobile_carbon_g[branch] = sheath_next.mobile_carbon_g_c;
    state.branch_mobile_nitrogen_g[branch] = sheath_next.mobile_nitrogen_g_n;
    state.branch_mobile_phosphorus_g[branch] = sheath_next.mobile_phosphorus_g_p;
    state.node_c3_nonstructural_carbon_g[node] = c4_bundle_sheath_after_g_c;
    state.node_c4_mesophyll_nonstructural_carbon_g[node] = c4_mesophyll_after_g_c;
    accumulated_products.* = next_products;
    return true;
}

pub fn senesceLeafAndSheathNode(state: *group_state.State, branch: usize, node_within_branch: usize, requested_fraction: f64, recycling: group_organ_growth.RecyclingFractions, protein_per_nitrogen_g_per_g_n: f64, protein_per_phosphorus_g_per_g_p: f64, woody_fraction: [2]f64, leaf_woody_nitrogen_fraction: [2]f64, sheath_woody_nitrogen_fraction: [2]f64, leaf_woody_phosphorus_fraction: [2]f64, sheath_woody_phosphorus_fraction: [2]f64, woody_kinetics: group_organ_growth.KineticFractions, leaf_kinetics: group_organ_growth.KineticFractions, sheath_kinetics: group_organ_growth.KineticFractions) !group_senescence.SenescenceProducts {
    inline for (.{ requested_fraction, recycling.carbon, recycling.nitrogen, recycling.phosphorus, protein_per_nitrogen_g_per_g_n, protein_per_phosphorus_g_per_g_p }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSenescenceInput;
    if (requested_fraction < 0 or recycling.carbon < 0 or recycling.carbon > 1 or recycling.nitrogen < 0 or recycling.nitrogen > 1 or recycling.phosphorus < 0 or recycling.phosphorus > 1 or protein_per_nitrogen_g_per_g_n < 0 or protein_per_phosphorus_g_per_g_p < 0) return error.InvalidSenescenceInput;
    inline for (.{ woody_fraction, leaf_woody_nitrogen_fraction, sheath_woody_nitrogen_fraction, leaf_woody_phosphorus_fraction, sheath_woody_phosphorus_fraction }) |fractions| for (fractions) |fraction| if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1 or @abs(fractions[0] + fractions[1] - 1.0) > 1e-8) return error.InvalidWoodyFraction;
    try woody_kinetics.validate();
    try leaf_kinetics.validate();
    try sheath_kinetics.validate();
    const nodes = try state.nodeRange(branch);
    if (node_within_branch >= nodes.end - nodes.first) return error.CanopyNodeIndexOutOfBounds;
    const node = nodes.first + node_within_branch;
    const fraction = @min(1.0, requested_fraction);
    var products: group_senescence.SenescenceProducts = .{};

    const leaf_c = state.node_leaf_carbon_g[node];
    const leaf_n = state.node_leaf_nitrogen_g[node];
    const leaf_p = state.node_leaf_phosphorus_g[node];
    const recycled_leaf_c = leaf_c * recycling.carbon;
    const recycled_leaf_n = leaf_n * (recycling.nitrogen + (1.0 - recycling.nitrogen) * recycling.carbon);
    const recycled_leaf_p = leaf_p * (recycling.phosphorus + (1.0 - recycling.phosphorus) * recycling.carbon);
    const sheath_c = state.node_sheath_carbon_g[node];
    const sheath_n = state.node_sheath_nitrogen_g[node];
    const sheath_p = state.node_sheath_phosphorus_g[node];
    const recycled_sheath_c = sheath_c * recycling.carbon;
    const recycled_sheath_n = if (sheath_c > 0) sheath_n * (recycling.nitrogen + (1.0 - recycling.nitrogen) * recycled_sheath_c / sheath_c) else 0;
    const recycled_sheath_p = if (sheath_c > 0) sheath_p * (recycling.phosphorus + (1.0 - recycling.phosphorus) * recycled_sheath_c / sheath_c) else 0;

    for (0..4) |kinetic| {
        products.woody_carbon_g[kinetic] = woody_kinetics.carbon[kinetic] * fraction * (leaf_c + sheath_c) * woody_fraction[0];
        products.woody_nitrogen_g[kinetic] = woody_kinetics.nitrogen[kinetic] * fraction * (leaf_n * leaf_woody_nitrogen_fraction[0] + sheath_n * sheath_woody_nitrogen_fraction[0]);
        products.woody_phosphorus_g[kinetic] = woody_kinetics.phosphorus[kinetic] * fraction * (leaf_p * leaf_woody_phosphorus_fraction[0] + sheath_p * sheath_woody_phosphorus_fraction[0]);
        products.nonwoody_carbon_g[kinetic] = fraction * woody_fraction[1] * (leaf_kinetics.carbon[kinetic] * (leaf_c - recycled_leaf_c) + sheath_kinetics.carbon[kinetic] * (sheath_c - recycled_sheath_c));
        products.nonwoody_nitrogen_g[kinetic] = fraction * (leaf_woody_nitrogen_fraction[1] * leaf_kinetics.nitrogen[kinetic] * (leaf_n - recycled_leaf_n) + sheath_woody_nitrogen_fraction[1] * sheath_kinetics.nitrogen[kinetic] * (sheath_n - recycled_sheath_n));
        products.nonwoody_phosphorus_g[kinetic] = fraction * (leaf_woody_phosphorus_fraction[1] * leaf_kinetics.phosphorus[kinetic] * (leaf_p - recycled_leaf_p) + sheath_woody_phosphorus_fraction[1] * sheath_kinetics.phosphorus[kinetic] * (sheath_p - recycled_sheath_p));
    }
    products.recycled_carbon_g = fraction * woody_fraction[1] * (recycled_leaf_c + recycled_sheath_c);
    products.recycled_nitrogen_g = fraction * (leaf_woody_nitrogen_fraction[1] * recycled_leaf_n + sheath_woody_nitrogen_fraction[1] * recycled_sheath_n);
    products.recycled_phosphorus_g = fraction * (leaf_woody_phosphorus_fraction[1] * recycled_leaf_p + sheath_woody_phosphorus_fraction[1] * recycled_sheath_p);

    const area_removed = fraction * state.node_leaf_area_m2[node];
    state.node_leaf_area_m2[node] -= area_removed;
    state.branch_leaf_area_m2[branch] = @max(0.0, state.branch_leaf_area_m2[branch] - area_removed);
    state.node_leaf_carbon_g[node] = @max(0.0, leaf_c * (1.0 - fraction));
    state.node_leaf_nitrogen_g[node] = @max(0.0, leaf_n * (1.0 - fraction));
    state.node_leaf_phosphorus_g[node] = @max(0.0, leaf_p * (1.0 - fraction));
    state.node_leaf_protein_g[node] = @max(0.0, state.node_leaf_protein_g[node] - fraction * @max(leaf_n * protein_per_nitrogen_g_per_g_n, leaf_p * protein_per_phosphorus_g_per_g_p));
    state.node_sheath_height_m[node] *= 1.0 - fraction;
    state.node_sheath_carbon_g[node] = @max(0.0, sheath_c * (1.0 - fraction));
    state.node_sheath_nitrogen_g[node] = @max(0.0, sheath_n * (1.0 - fraction));
    state.node_sheath_phosphorus_g[node] = @max(0.0, sheath_p * (1.0 - fraction));
    state.node_sheath_protein_g[node] = @max(0.0, state.node_sheath_protein_g[node] - fraction * @max(sheath_n * protein_per_nitrogen_g_per_g_n, sheath_p * protein_per_phosphorus_g_per_g_p));
    state.branch_leaf_carbon_g[branch] = @max(0.0, state.branch_leaf_carbon_g[branch] - fraction * leaf_c);
    state.branch_leaf_nitrogen_g[branch] = @max(0.0, state.branch_leaf_nitrogen_g[branch] - fraction * leaf_n);
    state.branch_leaf_phosphorus_g[branch] = @max(0.0, state.branch_leaf_phosphorus_g[branch] - fraction * leaf_p);
    state.branch_sheath_carbon_g[branch] = @max(0.0, state.branch_sheath_carbon_g[branch] - fraction * sheath_c);
    state.branch_sheath_nitrogen_g[branch] = @max(0.0, state.branch_sheath_nitrogen_g[branch] - fraction * sheath_n);
    state.branch_sheath_phosphorus_g[branch] = @max(0.0, state.branch_sheath_phosphorus_g[branch] - fraction * sheath_p);
    state.branch_mobile_carbon_g[branch] += products.recycled_carbon_g;
    state.branch_mobile_nitrogen_g[branch] += products.recycled_nitrogen_g;
    state.branch_mobile_phosphorus_g[branch] += products.recycled_phosphorus_g;
    state.branch_senescing_stalk_carbon_g[branch] += state.node_internode_carbon_g[node];
    state.branch_senescing_stalk_nitrogen_g[branch] += state.node_internode_nitrogen_g[node];
    state.branch_senescing_stalk_phosphorus_g[branch] += state.node_internode_phosphorus_g[node];
    state.node_internode_carbon_g[node] = 0;
    state.node_internode_nitrogen_g[node] = 0;
    state.node_internode_phosphorus_g[node] = 0;
    state.node_internode_length_m[node] = 0;
    return products;
}

fn selectedNodeTestLitter() group_senescence.SenescenceLitterParameters {
    const kinetics: group_organ_growth.KineticFractions = .{ .carbon = @splat(0.25), .nitrogen = @splat(0.25), .phosphorus = @splat(0.25) };
    return .{
        .woody_carbon_fraction = .{ 0.2, 0.8 },
        .leaf_woody_nitrogen_fraction = .{ 0.1, 0.9 },
        .sheath_woody_nitrogen_fraction = .{ 0.3, 0.7 },
        .stalk_woody_nitrogen_fraction = .{ 0.2, 0.8 },
        .leaf_woody_phosphorus_fraction = .{ 0.25, 0.75 },
        .sheath_woody_phosphorus_fraction = .{ 0.4, 0.6 },
        .stalk_woody_phosphorus_fraction = .{ 0.2, 0.8 },
        .woody_kinetics = kinetics,
        .leaf_kinetics = kinetics,
        .sheath_kinetics = kinetics,
        .stalk_kinetics = kinetics,
    };
}

fn productElementTotals(products: group_senescence.SenescenceProducts) [3]f64 {
    var totals: [3]f64 = .{ products.recycled_carbon_g, products.recycled_nitrogen_g, products.recycled_phosphorus_g };
    for (0..4) |pool| {
        totals[0] += products.woody_carbon_g[pool] + products.nonwoody_carbon_g[pool];
        totals[1] += products.woody_nitrogen_g[pool] + products.nonwoody_nitrogen_g[pool];
        totals[2] += products.woody_phosphorus_g[pool] + products.nonwoody_phosphorus_g[pool];
    }
    return totals;
}

test "GROSUB selected-node leaf sheath transaction persists snapshots and closes C N P" {
    var state = try group_state.State.init(std.testing.allocator, 1, 1, &.{1}, &.{25}, &([_]usize{0} ** 25));
    defer state.deinit();
    state.node_leaf_area_m2[0] = 4;
    state.node_leaf_carbon_g[0] = 8;
    state.node_leaf_nitrogen_g[0] = 0.8;
    state.node_leaf_phosphorus_g[0] = 0.08;
    state.node_leaf_protein_g[0] = 2;
    state.node_sheath_height_m[0] = 1;
    state.node_sheath_carbon_g[0] = 4;
    state.node_sheath_nitrogen_g[0] = 0.4;
    state.node_sheath_phosphorus_g[0] = 0.04;
    state.node_sheath_protein_g[0] = 1;
    state.node_internode_carbon_g[0] = 3;
    state.node_internode_nitrogen_g[0] = 0.3;
    state.node_internode_phosphorus_g[0] = 0.03;
    state.node_internode_length_m[0] = 0.5;
    state.node_c3_nonstructural_carbon_g[0] = 4;
    state.node_c4_mesophyll_nonstructural_carbon_g[0] = 2;
    state.branch_leaf_area_m2[0] = 4;
    state.branch_leaf_carbon_g[0] = 8;
    state.branch_leaf_nitrogen_g[0] = 0.8;
    state.branch_leaf_phosphorus_g[0] = 0.08;
    state.branch_sheath_carbon_g[0] = 4;
    state.branch_sheath_nitrogen_g[0] = 0.4;
    state.branch_sheath_phosphorus_g[0] = 0.04;
    state.branch_mobile_carbon_g[0] = 1;
    state.branch_mobile_nitrogen_g[0] = 0.1;
    state.branch_mobile_phosphorus_g[0] = 0.01;
    state.branch_senescing_stalk_carbon_g[0] = 0.5;
    state.branch_senescing_stalk_nitrogen_g[0] = 0.05;
    state.branch_senescing_stalk_phosphorus_g[0] = 0.005;
    var products: group_senescence.SenescenceProducts = .{};
    try std.testing.expect(try state_updateSelectedNodeSenescence(&state, 0, .{
        .lowest_node_remobilization_enabled = true,
        .refresh_snapshot = true,
        .newest_node_within_branch = 24,
        .requested_remobilization_fraction = 0.25,
        .structural_presence_threshold_g_c = 1.0e-12,
    }, .{ .carbon = 0.5, .nitrogen = 0.6, .phosphorus = 0.7 }, 2, 20, selectedNodeTestLitter(), &products));
    try std.testing.expectEqual(@as(f64, 8), state.branch_senescing_leaf_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 4), state.branch_senescing_sheath_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.node_internode_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 3.5), state.branch_senescing_stalk_carbon_g[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 2), 8 - state.node_leaf_carbon_g[0], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), 4 - state.node_sheath_carbon_g[0], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 3), state.node_c3_nonstructural_carbon_g[0], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), state.node_c4_mesophyll_nonstructural_carbon_g[0], 1.0e-14);
    const totals = productElementTotals(products);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), totals[0], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), totals[1], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), totals[2], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.2), state.branch_mobile_carbon_g[0], 1.0e-14);

    // No IFLGP refresh: the original snapshots remain the fraction basis, so
    // a request of 0.8 is independently availability-capped to 0.75.
    var second: group_senescence.SenescenceProducts = .{};
    try std.testing.expect(try state_updateSelectedNodeSenescence(&state, 0, .{
        .lowest_node_remobilization_enabled = true,
        .refresh_snapshot = false,
        .newest_node_within_branch = 24,
        .requested_remobilization_fraction = 0.8,
        .structural_presence_threshold_g_c = 1.0e-12,
    }, .{ .carbon = 0.5, .nitrogen = 0.6, .phosphorus = 0.7 }, 2, 20, selectedNodeTestLitter(), &second));
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.node_leaf_carbon_g[0], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.node_sheath_carbon_g[0], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), state.node_c3_nonstructural_carbon_g[0], 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.375), state.node_c4_mesophyll_nonstructural_carbon_g[0], 1.0e-14);
    try std.testing.expectEqual(@as(f64, 8), state.branch_senescing_leaf_carbon_g[0]);
}

test "selected-node transaction rolls back before a late product overflow" {
    var state = try group_state.State.init(std.testing.allocator, 1, 1, &.{1}, &.{25}, &([_]usize{0} ** 25));
    defer state.deinit();
    state.node_leaf_area_m2[0] = 1;
    state.node_leaf_carbon_g[0] = std.math.floatMax(f64);
    state.node_leaf_nitrogen_g[0] = 0.1;
    state.node_leaf_phosphorus_g[0] = 0.01;
    state.node_sheath_height_m[0] = 1;
    state.node_sheath_carbon_g[0] = 1;
    state.node_sheath_nitrogen_g[0] = 0.1;
    state.node_sheath_phosphorus_g[0] = 0.01;
    state.node_internode_carbon_g[0] = 2;
    state.node_internode_length_m[0] = 1;
    state.node_c3_nonstructural_carbon_g[0] = 4;
    state.node_c4_mesophyll_nonstructural_carbon_g[0] = 2;
    state.branch_leaf_area_m2[0] = 1;
    state.branch_leaf_carbon_g[0] = std.math.floatMax(f64);
    state.branch_leaf_nitrogen_g[0] = 0.1;
    state.branch_leaf_phosphorus_g[0] = 0.01;
    state.branch_sheath_carbon_g[0] = 1;
    state.branch_sheath_nitrogen_g[0] = 0.1;
    state.branch_sheath_phosphorus_g[0] = 0.01;
    var products: group_senescence.SenescenceProducts = .{};
    products.woody_carbon_g[0] = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteSelectedNodeSenescenceProduct, state_updateSelectedNodeSenescence(&state, 0, .{
        .lowest_node_remobilization_enabled = true,
        .refresh_snapshot = true,
        .newest_node_within_branch = 24,
        .requested_remobilization_fraction = 0.25,
        .structural_presence_threshold_g_c = 0,
    }, .{ .carbon = 0.5, .nitrogen = 0.6, .phosphorus = 0.7 }, 2, 20, selectedNodeTestLitter(), &products));
    try std.testing.expectEqual(std.math.floatMax(f64), state.node_leaf_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 1), state.node_sheath_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 2), state.node_internode_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 4), state.node_c3_nonstructural_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 2), state.node_c4_mesophyll_nonstructural_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.branch_senescing_stalk_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.branch_senescing_leaf_carbon_g[0]);
}
