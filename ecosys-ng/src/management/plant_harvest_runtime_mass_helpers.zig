//! `plant_harvest_runtime` declarations: mass helpers.
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
const group_harvest = @import("plant_harvest_runtime_harvest.zig");
const group_source_order_exports = @import("plant_harvest_runtime_source_order_exports.zig");

pub fn sumHarvestProductComponents(
    components: [group_harvest.harvest_product_component_count]canopy.ElementalMass,
) !canopy.ElementalMass {
    var total: canopy.ElementalMass = .{};
    for (components) |mass| {
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
            const value = @field(mass, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidDisturbanceRemovalInput;
            @field(total, field.name) += value;
        }
    }
    return total;
}

pub fn scaleElementalMass(mass: canopy.ElementalMass, fraction: f64) canopy.ElementalMass {
    return .{
        .carbon_g = mass.carbon_g * fraction,
        .nitrogen_g = mass.nitrogen_g * fraction,
        .phosphorus_g = mass.phosphorus_g * fraction,
    };
}

pub fn remainingShootPools(
    pools: group_source_order_exports.SourceOrderShootCombustionBranchPools,
    burned: group_source_order_exports.SourceOrderShootCombustionBranchPools,
) group_source_order_exports.SourceOrderShootCombustionBranchPools {
    var result: group_source_order_exports.SourceOrderShootCombustionBranchPools = undefined;
    inline for (@typeInfo(group_source_order_exports.SourceOrderShootCombustionBranchPools).@"struct".fields) |field| {
        const pool = @field(pools, field.name);
        const loss = @field(burned, field.name);
        @field(result, field.name) = .{
            .carbon_g = pool.carbon_g - loss.carbon_g,
            .nitrogen_g = pool.nitrogen_g - loss.nitrogen_g,
            .phosphorus_g = pool.phosphorus_g - loss.phosphorus_g,
        };
    }
    return result;
}

pub fn uncombustedShootTotal(
    pools: group_source_order_exports.SourceOrderShootCombustionBranchPools,
    c4_intermediate_carbon_g_c: f64,
) canopy.ElementalMass {
    var total = pools.leaf;
    inline for (.{
        pools.sheath,
        pools.stalk,
        pools.reserve,
        pools.husk,
        pools.ear,
        pools.grain,
        pools.canopy_nonstructural,
    }) |pool| {
        total.carbon_g += pool.carbon_g;
        total.nitrogen_g += pool.nitrogen_g;
        total.phosphorus_g += pool.phosphorus_g;
    }
    total.carbon_g += c4_intermediate_carbon_g_c;
    return total;
}

pub fn boundedCombustionFraction(total_g_c: f64, rate_g_c_step: f64, threshold_g_c: f64) f64 {
    return if (total_g_c > threshold_g_c)
        @min(@as(f64, 1), rate_g_c_step / total_g_c)
    else
        0;
}

pub fn subtractElementalMass(
    inventory: canopy.ElementalMass,
    loss: canopy.ElementalMass,
) canopy.ElementalMass {
    return .{
        .carbon_g = inventory.carbon_g - loss.carbon_g,
        .nitrogen_g = inventory.nitrogen_g - loss.nitrogen_g,
        .phosphorus_g = inventory.phosphorus_g - loss.phosphorus_g,
    };
}

pub fn scaleSaltInventory(
    inventory: group_source_order_exports.SourceOrderShootSaltInventory,
    fraction: f64,
) group_source_order_exports.SourceOrderShootSaltInventory {
    var result: group_source_order_exports.SourceOrderShootSaltInventory = undefined;
    inline for (@typeInfo(group_source_order_exports.SourceOrderShootSaltInventory).@"struct".fields) |field|
        @field(result, field.name) = @field(inventory, field.name) * fraction;
    return result;
}

pub fn subtractSaltInventory(
    inventory: group_source_order_exports.SourceOrderShootSaltInventory,
    loss: group_source_order_exports.SourceOrderShootSaltInventory,
) group_source_order_exports.SourceOrderShootSaltInventory {
    var result: group_source_order_exports.SourceOrderShootSaltInventory = undefined;
    inline for (@typeInfo(group_source_order_exports.SourceOrderShootSaltInventory).@"struct".fields) |field|
        @field(result, field.name) = @field(inventory, field.name) - @field(loss, field.name);
    return result;
}
