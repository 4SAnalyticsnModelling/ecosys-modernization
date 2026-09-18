//! `plant_harvest_runtime` declarations: validation.
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
const group_source_order_exports = @import("plant_harvest_runtime_source_order_exports.zig");
const group_types = @import("plant_harvest_runtime_types.zig");

pub fn validateTillageComposition(composition: group_types.TillageElementComposition) !void {
    inline for (.{ composition.carbon, composition.nitrogen, composition.phosphorus }) |fractions| {
        var sum: f64 = 0;
        for (fractions) |fraction| {
            if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
                return error.InvalidTillageBranchLitterInput;
            sum += fraction;
        }
        if (@abs(sum - 1) > 1.0e-12) return error.InvalidTillageBranchLitterInput;
    }
}

pub fn validateTillageSlice(values: []const f64) !void {
    for (values) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidTillageBranchState;
}

pub fn validateSourceOrderRootMass(mass: canopy.ElementalMass) !void {
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        const value = @field(mass, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidDeadRootLitterfallInput;
    }
}

pub fn validateDeadRootResetMass(mass: canopy.ElementalMass) !void {
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        const value = @field(mass, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidDeadRootResetInput;
    }
}

pub fn validateDeadNoduleMass(mass: canopy.ElementalMass) !void {
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        const value = @field(mass, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidDeadNoduleLitterfallInput;
    }
}

pub fn validateDeadRootDepthMass(mass: canopy.ElementalMass) !void {
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        const value = @field(mass, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidDeadRootDepthResetInput;
    }
}

pub fn validateCompleteDeathMass(mass: canopy.ElementalMass) !void {
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        const value = @field(mass, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidCompleteDeathShootLitterfallInput;
    }
}

pub fn validateCompleteDeathResultMass(mass: canopy.ElementalMass) !void {
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(mass, field.name)))
            return error.NonFiniteCompleteDeathShootLitterfall;
}

pub fn validateCombustionNode(node: group_source_order_exports.SourceOrderShootCombustionNodeState) !void {
    inline for (.{
        node.leaf_area_m2,
        node.sheath_height_m,
        node.senescent_leaf_carbon_g_c,
        node.senescent_sheath_carbon_g_c,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidUncombustedShootInput;
    try validateCompleteDeathMass(node.green_leaf);
    try validateCompleteDeathMass(node.green_sheath);
    try validateCompleteDeathMass(node.node);
}

pub fn validateGrazingFraction(value: f64) !void {
    if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidGrazingFraction;
}

pub fn validateNonnegativeFinite(comptime field_name: []const u8, values: []const f64, first: usize, end: usize) !void {
    if (first > end or end > values.len) return error.GrazingStateDimensionMismatch;
    for (values[first..end], first..) |value, index| {
        if (!std.math.isFinite(value) or value < 0) {
            if (!builtin.is_test) std.log.err("invalid grazing state: field={s} index={d} value={e}", .{ field_name, index, value });
            return error.InvalidGrazingState;
        }
    }
}

pub fn validateScience(science: group_types.ScienceParameters) !void {
    inline for (@typeInfo(group_types.ScienceParameters).@"struct".fields) |field| {
        if (field.type != [2]f64) continue;
        const fractions = @field(science, field.name);
        if (!std.math.isFinite(fractions[0]) or !std.math.isFinite(fractions[1]) or fractions[0] < 0 or fractions[1] < 0 or @abs(fractions[0] + fractions[1] - 1) > 1e-8) return error.InvalidPlantHarvestScience;
    }
}
