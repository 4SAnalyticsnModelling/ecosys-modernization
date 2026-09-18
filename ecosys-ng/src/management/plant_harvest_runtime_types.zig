//! `plant_harvest_runtime` declarations: types.
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

pub const ScienceParameters = struct {
    nitrogen_fixation_type: u8 = 0,
    carbon_woody_fraction: [2]f64,
    leaf_nitrogen_woody_fraction: [2]f64,
    sheath_nitrogen_woody_fraction: [2]f64,
    leaf_phosphorus_woody_fraction: [2]f64,
    sheath_phosphorus_woody_fraction: [2]f64,
};

pub const ProductLedger = struct {
    direct_litter: canopy.SenescenceProducts = .{},
    nonstructural: canopy.HarvestProducts = .{},
    foliar: canopy.HarvestProducts = .{},
    nonfoliar: canopy.HarvestProducts = .{},
    woody: canopy.HarvestProducts = .{},
    harvested_grain: canopy.ElementalMass = .{},
    standing_dead_export: canopy.ElementalMass = .{},
    standing_dead_charcoal_litter: canopy.ElementalMass = .{},
    manure: grazing_manure.Products = .{},
};

pub const HourlyDisturbanceReset = struct {
    previous_cumulative_harvest_carbon_g_c: f64,
    manure_organic_carbon_g_c: [4]f64,
    manure_organic_nitrogen_g_n: [4]f64,
    manure_organic_phosphorus_g_p: [4]f64,
    manure_inorganic_nitrogen_g_n: f64,
    manure_inorganic_phosphorus_g_p: f64,
};

pub const TillageElementComposition = struct {
    carbon: [2]f64,
    nitrogen: [2]f64,
    phosphorus: [2]f64,
};

/// Dynamic GROSUB FWOOD/FWOODN/FWOODP and FWODR/FWODRN/FWODRP state at
/// the harvest boundary. Each pair is `{ woody, nonwoody }`.
pub const BelowgroundHarvestComposition = struct {
    root_woody_nonwoody: TillageElementComposition,
    storage_woody_nonwoody: TillageElementComposition,
    perennial: bool,

    pub fn validate(self: BelowgroundHarvestComposition) !void {
        inline for (.{
            self.root_woody_nonwoody.carbon,
            self.root_woody_nonwoody.nitrogen,
            self.root_woody_nonwoody.phosphorus,
            self.storage_woody_nonwoody.carbon,
            self.storage_woody_nonwoody.nitrogen,
            self.storage_woody_nonwoody.phosphorus,
        }) |fractions| {
            for (fractions) |value|
                if (!std.math.isFinite(value) or value < 0 or value > 1)
                    return error.InvalidBelowgroundHarvestComposition;
            if (@abs(fractions[0] + fractions[1] - 1) > 1.0e-12)
                return error.NonConservativeBelowgroundHarvestComposition;
        }
    }
};

pub const source_order_standing_dead_component_count: usize = 5;

pub const PopulationScaledNumericalThresholds = struct {
    plant_mass_presence_g: f64,
    plant_mass_density_g_m2: f64,
    plant_flux_presence_g_per_step: f64,
};
