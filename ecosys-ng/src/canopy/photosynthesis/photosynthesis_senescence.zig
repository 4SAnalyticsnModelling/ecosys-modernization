//! `photosynthesis` declarations: senescence.
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
const group_mobile = @import("photosynthesis_mobile.zig");
const group_node_layer = @import("photosynthesis_node_layer.zig");
const group_organ_growth = @import("photosynthesis_organ_growth.zig");
const group_state = @import("photosynthesis_state.zig");

pub const SenescenceProducts = struct {
    woody_carbon_g: [4]f64 = @splat(0),
    woody_nitrogen_g: [4]f64 = @splat(0),
    woody_phosphorus_g: [4]f64 = @splat(0),
    nonwoody_carbon_g: [4]f64 = @splat(0),
    nonwoody_nitrogen_g: [4]f64 = @splat(0),
    nonwoody_phosphorus_g: [4]f64 = @splat(0),
    recycled_carbon_g: f64 = 0,
    recycled_nitrogen_g: f64 = 0,
    recycled_phosphorus_g: f64 = 0,
    respired_carbon_g: f64 = 0,
};

pub fn addSenescenceProducts(total: *SenescenceProducts, addition: SenescenceProducts) void {
    for (0..4) |kinetic| {
        total.woody_carbon_g[kinetic] += addition.woody_carbon_g[kinetic];
        total.woody_nitrogen_g[kinetic] += addition.woody_nitrogen_g[kinetic];
        total.woody_phosphorus_g[kinetic] += addition.woody_phosphorus_g[kinetic];
        total.nonwoody_carbon_g[kinetic] += addition.nonwoody_carbon_g[kinetic];
        total.nonwoody_nitrogen_g[kinetic] += addition.nonwoody_nitrogen_g[kinetic];
        total.nonwoody_phosphorus_g[kinetic] += addition.nonwoody_phosphorus_g[kinetic];
    }
    total.recycled_carbon_g += addition.recycled_carbon_g;
    total.recycled_nitrogen_g += addition.recycled_nitrogen_g;
    total.recycled_phosphorus_g += addition.recycled_phosphorus_g;
    total.respired_carbon_g += addition.respired_carbon_g;
}

pub fn state_updateResidualStalkSenescenceDemand(state: *group_state.State, branch: usize, respiration_demand_g_c: f64, phenological_senescence_fraction: f64, recycling: group_organ_growth.RecyclingFractions, woody_carbon_fraction: [2]f64, woody_nitrogen_fraction: [2]f64, woody_phosphorus_fraction: [2]f64, woody_kinetics: group_organ_growth.KineticFractions, stalk_kinetics: group_organ_growth.KineticFractions) !group_node_layer.InternodeSenescenceResult {
    inline for (.{ respiration_demand_g_c, phenological_senescence_fraction, recycling.carbon, recycling.nitrogen, recycling.phosphorus }) |value| if (!std.math.isFinite(value)) return error.NonFiniteResidualStalkSenescenceInput;
    if (branch >= state.branch_stalk_carbon_g.len) return error.CanopyBranchIndexOutOfBounds;
    if (respiration_demand_g_c < 0 or phenological_senescence_fraction < 0 or phenological_senescence_fraction > 1) return error.InvalidResidualStalkSenescenceInput;
    inline for (.{ woody_carbon_fraction, woody_nitrogen_fraction, woody_phosphorus_fraction }) |fractions| {
        for (fractions) |fraction_value| if (!std.math.isFinite(fraction_value) or fraction_value < 0 or fraction_value > 1) return error.InvalidWoodyFraction;
        if (@abs(fractions[0] + fractions[1] - 1.0) > 1e-8) return error.InvalidWoodyFraction;
    }
    try woody_kinetics.validate();
    try stalk_kinetics.validate();
    const stalk_c = state.branch_stalk_carbon_g[branch];
    const residual_c = state.branch_senescing_stalk_carbon_g[branch];
    const residual_n = state.branch_senescing_stalk_nitrogen_g[branch];
    const residual_p = state.branch_senescing_stalk_phosphorus_g[branch];
    if (stalk_c <= 0 or residual_c <= 0) return .{ .fraction = 0, .remaining_respiration_demand_g_c = respiration_demand_g_c, .products = .{} };
    const sapwood_fraction = std.math.clamp(state.branch_sapwood_carbon_g[branch] / stalk_c, 0, 1);
    const effective_c = recycling.carbon * sapwood_fraction;
    const effective_n = recycling.nitrogen * sapwood_fraction;
    const effective_p = recycling.phosphorus * sapwood_fraction;
    const recyclable_c = effective_c * residual_c;
    const recyclable_n = residual_n * (effective_n + (1.0 - effective_n) * effective_c);
    const recyclable_p = residual_p * (effective_p + (1.0 - effective_p) * effective_c);
    const fraction = if (recyclable_c > 0) std.math.clamp(respiration_demand_g_c / recyclable_c, 0, 1) else 1;
    const consumed_recyclable_c = fraction * recyclable_c * woody_carbon_fraction[1];
    var products: SenescenceProducts = .{
        .recycled_carbon_g = consumed_recyclable_c * phenological_senescence_fraction,
        .recycled_nitrogen_g = fraction * recyclable_n * woody_nitrogen_fraction[1],
        .recycled_phosphorus_g = fraction * recyclable_p * woody_phosphorus_fraction[1],
        .respired_carbon_g = consumed_recyclable_c * (1.0 - phenological_senescence_fraction),
    };
    for (0..4) |kinetic| {
        products.woody_carbon_g[kinetic] = woody_kinetics.carbon[kinetic] * fraction * residual_c * woody_carbon_fraction[0];
        products.woody_nitrogen_g[kinetic] = woody_kinetics.nitrogen[kinetic] * fraction * residual_n * woody_nitrogen_fraction[0];
        products.woody_phosphorus_g[kinetic] = woody_kinetics.phosphorus[kinetic] * fraction * residual_p * woody_phosphorus_fraction[0];
        products.nonwoody_carbon_g[kinetic] = stalk_kinetics.carbon[kinetic] * fraction * (residual_c - recyclable_c) * woody_carbon_fraction[1];
        products.nonwoody_nitrogen_g[kinetic] = stalk_kinetics.nitrogen[kinetic] * fraction * (residual_n - recyclable_n) * woody_nitrogen_fraction[1];
        products.nonwoody_phosphorus_g[kinetic] = stalk_kinetics.phosphorus[kinetic] * fraction * (residual_p - recyclable_p) * woody_phosphorus_fraction[1];
    }
    state.branch_stalk_carbon_g[branch] = @max(0.0, stalk_c - fraction * residual_c);
    state.branch_stalk_nitrogen_g[branch] = @max(0.0, state.branch_stalk_nitrogen_g[branch] - fraction * residual_n);
    state.branch_stalk_phosphorus_g[branch] = @max(0.0, state.branch_stalk_phosphorus_g[branch] - fraction * residual_p);
    state.branch_senescing_stalk_carbon_g[branch] *= 1.0 - fraction;
    state.branch_senescing_stalk_nitrogen_g[branch] *= 1.0 - fraction;
    state.branch_senescing_stalk_phosphorus_g[branch] *= 1.0 - fraction;
    const nodes = try state.nodeRange(branch);
    var maximum_height_m: f64 = 0;
    for (state.node_height_m[nodes.first..nodes.end]) |height_m| maximum_height_m = @max(maximum_height_m, height_m);
    const reduced_maximum_height_m = maximum_height_m * (1.0 - fraction);
    for (state.node_height_m[nodes.first..nodes.end]) |*height_m| height_m.* = @min(height_m.*, reduced_maximum_height_m);
    state.branch_reserve_carbon_g[branch] += products.recycled_carbon_g;
    state.branch_reserve_nitrogen_g[branch] += products.recycled_nitrogen_g;
    state.branch_reserve_phosphorus_g[branch] += products.recycled_phosphorus_g;
    return .{ .fraction = fraction, .remaining_respiration_demand_g_c = @max(0.0, respiration_demand_g_c - consumed_recyclable_c), .products = products };
}

fn state_updateResidualStalkSenescenceDemandScaled(state: *group_state.State, branch: usize, respiration_demand_g_c: f64, phenological_senescence_fraction: f64, scaled_recycling: perennial_stalk_senescence_setup.RecyclingFractions, presence_threshold_g_c: f64, woody_carbon_fraction: [2]f64, woody_nitrogen_fraction: [2]f64, woody_phosphorus_fraction: [2]f64, woody_kinetics: group_organ_growth.KineticFractions, stalk_kinetics: group_organ_growth.KineticFractions) !group_node_layer.InternodeSenescenceResult {
    const request = try residual_stalk_senescence_request.calculate(.{
        .carbon = state.branch_senescing_stalk_carbon_g[branch],
        .nitrogen = state.branch_senescing_stalk_nitrogen_g[branch],
        .phosphorus = state.branch_senescing_stalk_phosphorus_g[branch],
    }, .{
        .carbon = scaled_recycling.carbon,
        .nitrogen = scaled_recycling.nitrogen,
        .phosphorus = scaled_recycling.phosphorus,
    }, respiration_demand_g_c, presence_threshold_g_c) orelse return .{
        .fraction = 0,
        .remaining_respiration_demand_g_c = respiration_demand_g_c,
        .products = .{},
    };
    const nodes = try state.nodeRange(branch);
    var products: SenescenceProducts = .{};
    const reserve_carbon_before = state.branch_reserve_carbon_g[branch];
    const reserve_nitrogen_before = state.branch_reserve_nitrogen_g[branch];
    const reserve_phosphorus_before = state.branch_reserve_phosphorus_g[branch];
    const result = try residual_stalk_senescence_state_update.publish(.{
        .branch_stalk_carbon_g_c = &state.branch_stalk_carbon_g[branch],
        .branch_stalk_nitrogen_g_n = &state.branch_stalk_nitrogen_g[branch],
        .branch_stalk_phosphorus_g_p = &state.branch_stalk_phosphorus_g[branch],
        .residual_stalk_carbon_g_c = &state.branch_senescing_stalk_carbon_g[branch],
        .residual_stalk_nitrogen_g_n = &state.branch_senescing_stalk_nitrogen_g[branch],
        .residual_stalk_phosphorus_g_p = &state.branch_senescing_stalk_phosphorus_g[branch],
        .node_height_m = state.node_height_m[nodes.first..nodes.end],
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
        .removal_fraction = request.removal_fraction,
        .recyclable = .{ .carbon = request.recyclable.carbon, .nitrogen = request.recyclable.nitrogen, .phosphorus = request.recyclable.phosphorus },
        .respiration_demand_g_c_per_timestep = respiration_demand_g_c,
        .phenological_senescence_fraction = phenological_senescence_fraction,
        .woody_fraction = .{ .carbon = woody_carbon_fraction[0], .nitrogen = woody_nitrogen_fraction[0], .phosphorus = woody_phosphorus_fraction[0] },
        .nonwoody_fraction = .{ .carbon = woody_carbon_fraction[1], .nitrogen = woody_nitrogen_fraction[1], .phosphorus = woody_phosphorus_fraction[1] },
        .woody_kinetics = .{ .carbon = &woody_kinetics.carbon, .nitrogen = &woody_kinetics.nitrogen, .phosphorus = &woody_kinetics.phosphorus },
        .stalk_kinetics = .{ .carbon = &stalk_kinetics.carbon, .nitrogen = &stalk_kinetics.nitrogen, .phosphorus = &stalk_kinetics.phosphorus },
    });
    products.recycled_carbon_g = state.branch_reserve_carbon_g[branch] - reserve_carbon_before;
    products.recycled_nitrogen_g = state.branch_reserve_nitrogen_g[branch] - reserve_nitrogen_before;
    products.recycled_phosphorus_g = state.branch_reserve_phosphorus_g[branch] - reserve_phosphorus_before;
    products.respired_carbon_g = respiration_demand_g_c - result.remaining_respiration_g_c_per_timestep - products.recycled_carbon_g;
    return .{ .fraction = request.removal_fraction, .remaining_respiration_demand_g_c = result.remaining_respiration_g_c_per_timestep, .products = products };
}

pub const SenescenceLitterParameters = struct {
    woody_carbon_fraction: [2]f64,
    leaf_woody_nitrogen_fraction: [2]f64,
    sheath_woody_nitrogen_fraction: [2]f64,
    stalk_woody_nitrogen_fraction: [2]f64,
    leaf_woody_phosphorus_fraction: [2]f64,
    sheath_woody_phosphorus_fraction: [2]f64,
    stalk_woody_phosphorus_fraction: [2]f64,
    woody_kinetics: group_organ_growth.KineticFractions,
    leaf_kinetics: group_organ_growth.KineticFractions,
    sheath_kinetics: group_organ_growth.KineticFractions,
    stalk_kinetics: group_organ_growth.KineticFractions,
};

pub const BranchSenescenceRequest = struct {
    total_respiration_demand_g_c: f64,
    phenological_senescence_fraction: f64,
    first_node_within_branch: usize,
    last_node_within_branch: usize,
    node_group_count: usize,
    perennial: bool,
    reserve_fallback_policy: group_mobile.ReserveFallbackPolicy = .source_compatible,
    leaf_presence_threshold_g_c: f64 = 0,
    demand_tolerance_g_c: f64,
};

pub const BranchSenescenceResult = struct {
    remaining_respiration_demand_g_c: f64,
    reserve_carbon_respired_g_c: f64,
    products: SenescenceProducts,
};

/// Executes the GROSUB senescence cascade from progressively older leaf-node
/// groups through reserve C, internodes, and residual stalk. Runtime node
/// offsets replace the source's modulo-25 storage ring.
pub fn state_updateBranchSenescenceDemand(state: *group_state.State, branch: usize, request: BranchSenescenceRequest, recycling: group_organ_growth.RecyclingFractions, protein_per_nitrogen_g_per_g_n: f64, protein_per_phosphorus_g_per_g_p: f64, litter: SenescenceLitterParameters) !BranchSenescenceResult {
    inline for (.{ request.total_respiration_demand_g_c, request.phenological_senescence_fraction, request.leaf_presence_threshold_g_c, request.demand_tolerance_g_c }) |value| if (!std.math.isFinite(value)) return error.NonFiniteBranchSenescenceInput;
    if (request.total_respiration_demand_g_c < 0 or request.phenological_senescence_fraction < 0 or request.phenological_senescence_fraction > 1 or request.node_group_count == 0 or request.leaf_presence_threshold_g_c < 0 or request.demand_tolerance_g_c < 0) return error.InvalidBranchSenescenceInput;
    const nodes = try state.nodeRange(branch);
    const node_count = nodes.end - nodes.first;
    if (request.first_node_within_branch > request.last_node_within_branch or request.last_node_within_branch >= node_count) return error.CanopyNodeIndexOutOfBounds;
    var result: BranchSenescenceResult = .{ .remaining_respiration_demand_g_c = 0, .reserve_carbon_respired_g_c = 0, .products = .{} };
    const cascade_threshold_g_c = if (request.reserve_fallback_policy == .source_compatible)
        request.leaf_presence_threshold_g_c
    else
        request.demand_tolerance_g_c;
    const group_demand_g_c = try node_senescence_remobilization_request.respirationPerPass(
        request.total_respiration_demand_g_c,
        request.node_group_count,
    );
    for (0..request.node_group_count) |group| {
        var remaining_g_c = group_demand_g_c;
        const group_start = try node_senescence_cascade_progress.firstNodeForPass(request.first_node_within_branch, request.last_node_within_branch, group);
        if (group_start) |first_node| for (first_node..request.last_node_within_branch + 1) |node_within_branch| {
            const node = nodes.first + node_within_branch;
            const allocation = try group_node_layer.allocateNodeSenescenceDemandWithThreshold(remaining_g_c, state.node_leaf_carbon_g[node], state.node_sheath_carbon_g[node], recycling.carbon, request.phenological_senescence_fraction, litter.woody_carbon_fraction[1], request.leaf_presence_threshold_g_c);
            const products = try group_node_layer.state_updateNodeSenescenceDemand(state, branch, node_within_branch, allocation, recycling, protein_per_nitrogen_g_per_g_n, protein_per_phosphorus_g_per_g_p, litter.woody_carbon_fraction, litter.leaf_woody_nitrogen_fraction, litter.sheath_woody_nitrogen_fraction, litter.leaf_woody_phosphorus_fraction, litter.sheath_woody_phosphorus_fraction, litter.woody_kinetics, litter.leaf_kinetics, litter.sheath_kinetics);
            addSenescenceProducts(&result.products, products);
            remaining_g_c = allocation.remaining_respiration_demand_g_c;
            if (remaining_g_c <= cascade_threshold_g_c) break;
        };
        if (remaining_g_c > cascade_threshold_g_c) {
            if (request.reserve_fallback_policy == .consume_available) {
                const reserve_g_c = state.branch_reserve_carbon_g[branch];
                const consumed_g_c = @min(reserve_g_c, remaining_g_c);
                state.branch_reserve_carbon_g[branch] -= consumed_g_c;
                result.reserve_carbon_respired_g_c += consumed_g_c;
                remaining_g_c -= consumed_g_c;
            } else {
                const reserve = try node_senescence_cascade_progress.applyReserveFallback(.{
                    .reserve_carbon_g_c = &state.branch_reserve_carbon_g[branch],
                }, remaining_g_c, request.phenological_senescence_fraction);
                result.reserve_carbon_respired_g_c += reserve.reserve_carbon_respired_g_c_per_timestep;
                remaining_g_c = reserve.excess_maintenance_respiration_g_c_per_timestep;
            }
        }
        if (request.perennial and remaining_g_c > cascade_threshold_g_c) {
            const stalk_setup = try perennial_stalk_senescence_setup.prepare(.{
                .is_perennial = true,
                .excess_maintenance_respiration_g_c_per_timestep = remaining_g_c,
                .stalk_carbon_g_c = state.branch_stalk_carbon_g[branch],
                .sapwood_carbon_g_c = state.branch_sapwood_carbon_g[branch],
                .presence_threshold_g_c = request.leaf_presence_threshold_g_c,
                .first_internode = request.first_node_within_branch,
                .last_internode = request.last_node_within_branch,
                .shoot_recycling = .{ .carbon = recycling.carbon, .nitrogen = recycling.nitrogen, .phosphorus = recycling.phosphorus },
            });
            if (stalk_setup) |setup| for (0..setup.last_internode - setup.first_internode + 1) |iteration| {
                const ordinal = perennial_stalk_senescence_setup.descendingInternode(setup, iteration).?;
                const internode = try group_node_layer.state_updateInternodeSenescenceDemandScaled(state, branch, ordinal, remaining_g_c, setup.phenological_senescence_fraction, setup.sapwood_recycling, request.leaf_presence_threshold_g_c, litter.woody_carbon_fraction, litter.stalk_woody_nitrogen_fraction, litter.stalk_woody_phosphorus_fraction, litter.woody_kinetics, litter.stalk_kinetics);
                addSenescenceProducts(&result.products, internode.products);
                remaining_g_c = internode.remaining_respiration_demand_g_c;
                if (remaining_g_c <= cascade_threshold_g_c) break;
            };
            if (stalk_setup != null and remaining_g_c > cascade_threshold_g_c) {
                const setup = stalk_setup.?;
                const residual = try state_updateResidualStalkSenescenceDemandScaled(state, branch, remaining_g_c, setup.phenological_senescence_fraction, setup.sapwood_recycling, request.leaf_presence_threshold_g_c, litter.woody_carbon_fraction, litter.stalk_woody_nitrogen_fraction, litter.stalk_woody_phosphorus_fraction, litter.woody_kinetics, litter.stalk_kinetics);
                addSenescenceProducts(&result.products, residual.products);
                remaining_g_c = residual.remaining_respiration_demand_g_c;
            }
        }
        result.remaining_respiration_demand_g_c += @max(0.0, remaining_g_c);
    }
    return result;
}

pub const SenescenceDemand = struct {
    phenological_respiration_g_c: f64,
    total_respiration_g_c: f64,
    phenological_fraction: f64,
    node_group_count: usize,
    first_preceding_node: usize,
};

pub fn senescenceDemand(shoot_remobilization_enabled: bool, phenological_remobilization_enabled: bool, perennial: bool, canopy_leaf_area_m2: f64, horizontal_cell_area_m2: f64, leaf_storage_exchange_per_h: f64, branch_leaf_sheath_carbon_g: f64, remobilization_elapsed_h: f64, full_senescence_h: f64, timestep_h: f64, excess_maintenance_respiration_g_c: f64, highest_leaf_ordinal: usize, lowest_leaf_ordinal: usize) !SenescenceDemand {
    const exchange = [1]f64{leaf_storage_exchange_per_h};
    const setup = try shoot_total_senescence_setup.calculate(.{
        .shoot_remobilization = if (shoot_remobilization_enabled) .enabled else .disabled,
        .phenological_remobilization = if (phenological_remobilization_enabled) .enabled else .disabled,
        .perennial_growth_habit = perennial,
        .plant_leaf_area_m2 = canopy_leaf_area_m2,
        .horizontal_cell_area_m2 = horizontal_cell_area_m2,
        .aboveground_turnover_index = 0,
        .leaf_storage_exchange_fraction_per_h_by_turnover = &exchange,
        .branch_leaf_and_sheath_carbon_g_c = branch_leaf_sheath_carbon_g,
        .remobilization_elapsed_h = remobilization_elapsed_h,
        .full_senescence_duration_h = full_senescence_h,
        .timestep_h = timestep_h,
        .excess_maintenance_respiration_g_c_per_timestep = excess_maintenance_respiration_g_c,
        .structural_presence_threshold_g_c = 0,
        .newest_leaf_node = highest_leaf_ordinal,
        .lowest_leaf_node = lowest_leaf_ordinal,
        .runtime_node_count = try std.math.add(usize, highest_leaf_ordinal, 1),
    });
    if (setup == null) return .{
        .phenological_respiration_g_c = 0,
        .total_respiration_g_c = 0,
        .phenological_fraction = 0,
        .node_group_count = (highest_leaf_ordinal - lowest_leaf_ordinal) / 2 + 1,
        .first_preceding_node = lowest_leaf_ordinal -| 1,
    };
    const result = setup.?;
    return .{
        .phenological_respiration_g_c = result.phenological_respiration_g_c_per_timestep,
        .total_respiration_g_c = result.total_senescence_respiration_g_c_per_timestep,
        .phenological_fraction = result.phenological_fraction,
        .node_group_count = result.node_group_count,
        .first_preceding_node = result.first_preceding_node,
    };
}
