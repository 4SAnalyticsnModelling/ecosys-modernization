//! `plant_harvest_runtime` declarations: mortality.
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
const group_apply = @import("plant_harvest_runtime_apply.zig");
const group_misc = @import("plant_harvest_runtime_misc.zig");

/// Exact GROSUB PPQ/PCUT monthly forest self-thinning equations.
pub fn forestSelfThinningFraction(stem_diameter_m: f64, living_population_per_m2: f64) !f64 {
    inline for (.{ stem_diameter_m, living_population_per_m2 }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidForestSelfThinningInput;
    if (stem_diameter_m == 0 or living_population_per_m2 == 0) return 0;
    const equilibrium_population_per_m2 = 0.1 * std.math.pow(f64, stem_diameter_m / 0.25, -1.6);
    const fraction = @max(0, 0.1 * (living_population_per_m2 - equilibrium_population_per_m2) / living_population_per_m2);
    if (!std.math.isFinite(fraction) or fraction > 1) return error.NonFiniteForestSelfThinning;
    return fraction;
}

/// Publishes every remaining host-root, mycorrhizal, nodule, and root-gas
/// inventory after whole-plant mortality, before later reconstruction can
/// clear the runtime root topology.
pub fn releaseDeadRootsToLitter(context: *group_misc.Context, plant: usize) !void {
    try group_apply.applyRootSymbiontHarvest(context, plant, 0);
}
