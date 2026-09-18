//! `plant_harvest_source_order` declarations: misc.
//!
//! Split out of `plant_harvest_source_order.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const management = @import("plant_management.zig");
const canopy = @import("../canopy/photosynthesis/photosynthesis.zig");
const phenology = @import("../plant/lifecycle/phenology.zig");
const litter_partition = @import("../plant/partition/litter.zig");
const grazing_manure = @import("grazing_manure.zig");
const __parent = @import("plant_harvest_runtime.zig");
const group_combustion = @import("plant_harvest_source_order_combustion.zig");
const group_complete_death = @import("plant_harvest_source_order_complete_death.zig");

const remainingShootPools = __parent.remainingShootPools;
pub const scaleElementalMass = __parent.scaleElementalMass;
pub const scaleSaltInventory = __parent.scaleSaltInventory;
pub const source_order_standing_dead_component_count = __parent.source_order_standing_dead_component_count;
pub const subtractElementalMass = __parent.subtractElementalMass;
pub const subtractSaltInventory = __parent.subtractSaltInventory;
const uncombustedShootTotal = __parent.uncombustedShootTotal;
pub const validateSourceOrderRootMass = __parent.validateSourceOrderRootMass;

pub const SourceOrderShootSaltInventory = struct {
    aluminum_mol: f64,
    iron_mol: f64,
    calcium_mol: f64,
    magnesium_mol: f64,
    sodium_mol: f64,
    potassium_mol: f64,
    sulfate_mol: f64,
    chloride_mol: f64,
};

pub const SourceOrderUncombustedBranchState = struct {
    pools: group_combustion.SourceOrderShootCombustionBranchPools,
    c4_intermediate_carbon_g_c: f64,
    total_shoot: canopy.ElementalMass,
    leaf_area_m2: f64,
    nodes: []group_combustion.SourceOrderShootCombustionNodeState,
    node_layers: []group_combustion.SourceOrderShootCombustionNodeLayerState,
    canopy_layer_count: usize,
};

/// Exact GROSUB 12034-12102 remaining shoot pools and node attributes.
pub fn sourceOrderApplyUncombustedShootState(
    branches: []SourceOrderUncombustedBranchState,
    combusted: []const group_combustion.SourceOrderShootCombustionBranchPools,
    fractions: group_combustion.SourceOrderShootCombustionFractions,
) !void {
    if (branches.len != combusted.len)
        return error.InvalidUncombustedShootDimensions;
    inline for (.{ fractions.leaf, fractions.sheath, fractions.stalk }) |value|
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidUncombustedShootInput;
    for (branches, combusted) |branch, burned| {
        if (branch.canopy_layer_count == 0)
            return error.InvalidUncombustedShootDimensions;
        const node_layer_count = std.math.mul(
            usize,
            branch.nodes.len,
            branch.canopy_layer_count,
        ) catch return error.InvalidUncombustedShootDimensions;
        if (branch.node_layers.len != node_layer_count)
            return error.InvalidUncombustedShootDimensions;
        if (!std.math.isFinite(branch.c4_intermediate_carbon_g_c) or
            branch.c4_intermediate_carbon_g_c < 0 or
            !std.math.isFinite(branch.leaf_area_m2) or branch.leaf_area_m2 < 0)
            return error.InvalidUncombustedShootInput;
        inline for (@typeInfo(group_combustion.SourceOrderShootCombustionBranchPools).@"struct".fields) |field| {
            const pool = @field(branch.pools, field.name);
            const loss = @field(burned, field.name);
            try group_complete_death.validateCompleteDeathMass(pool);
            try group_complete_death.validateCompleteDeathMass(loss);
            inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element| {
                const remaining = @field(pool, element.name) - @field(loss, element.name);
                if (!std.math.isFinite(remaining) or remaining < 0)
                    return error.InvalidUncombustedShootLoss;
            }
        }
        for (branch.nodes) |node| try group_combustion.validateCombustionNode(node);
        for (branch.node_layers) |layer| {
            if (!std.math.isFinite(layer.leaf_area_m2) or layer.leaf_area_m2 < 0)
                return error.InvalidUncombustedShootInput;
            try group_complete_death.validateCompleteDeathMass(layer.green_leaf);
        }
        const remaining = remainingShootPools(branch.pools, burned);
        const total = uncombustedShootTotal(
            remaining,
            branch.c4_intermediate_carbon_g_c,
        );
        try group_complete_death.validateCompleteDeathResultMass(total);
    }

    for (branches, combusted) |*branch, burned| {
        branch.pools = remainingShootPools(branch.pools, burned);
        branch.total_shoot = uncombustedShootTotal(
            branch.pools,
            branch.c4_intermediate_carbon_g_c,
        );
        branch.leaf_area_m2 *= 1 - fractions.leaf;
        for (branch.nodes, 0..) |*node, node_index| {
            node.leaf_area_m2 *= 1 - fractions.leaf;
            node.sheath_height_m *= 1 - fractions.sheath;
            node.green_leaf = scaleElementalMass(node.green_leaf, 1 - fractions.leaf);
            node.senescent_leaf_carbon_g_c *= 1 - fractions.leaf;
            node.green_sheath = scaleElementalMass(node.green_sheath, 1 - fractions.sheath);
            node.senescent_sheath_carbon_g_c *= 1 - fractions.sheath;
            node.node = scaleElementalMass(node.node, 1 - fractions.stalk);
            for (0..branch.canopy_layer_count) |layer| {
                const state = &branch.node_layers[
                    node_index * branch.canopy_layer_count + layer
                ];
                state.leaf_area_m2 *= 1 - fractions.leaf;
                state.green_leaf = scaleElementalMass(
                    state.green_leaf,
                    1 - fractions.leaf,
                );
            }
        }
    }
}
