//! `plant_harvest_runtime` declarations: misc.
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
const group_types = @import("plant_harvest_runtime_types.zig");
const group_validation = @import("plant_harvest_runtime_validation.zig");

pub const Context = struct {
    canopy_state: *canopy.State,
    canopy_structure_state: ?*canopy_structure.State = null,
    canopy_layer_state: ?*canopy_layers.State = null,
    branch_development: *phenology.BranchDevelopmentState,
    science_by_plant: []const group_types.ScienceParameters,
    products_by_plant: []group_types.ProductLedger,
    leaf_area_presence_tolerance_m2: f64,
    plant_structural_presence_threshold_g_per_plant: f64 = 0,
    plant_tissue_presence_threshold_g_per_plant: f64 = 0,
    canopy_biochemistry_parameters_by_plant: ?[]const canopy_biochemistry.Parameters = null,
    plant_phenology: ?*phenology.State = null,
    growth_stages: ?*growth_stages.State = null,
    emerged_by_plant: ?[]bool = null,
    root_state: ?*root_system.State = null,
    root_litter_partition: ?*const litter_partition.State = null,
    root_litter_carbon_ledger: ?*root_litter_ledger.State = null,
    shoot_litter_carbon_g_c_by_plant: ?[]f64 = null,
    shoot_litter_nitrogen_g_n_by_plant: ?[]f64 = null,
    shoot_litter_phosphorus_g_p_by_plant: ?[]f64 = null,
    soil_organic_state: ?*soil_organic.State = null,
    surface_organic_state: ?*soil_organic.State = null,
    surface_nutrient_state: ?*surface_nutrients.State = null,
    daily_manure_carbon_input_g_c: ?[]f64 = null,
    daily_manure_nitrogen_input_g_n: ?[]f64 = null,
    daily_manure_phosphorus_input_g_p: ?[]f64 = null,
    hourly_manure_products_by_plant: ?[]grazing_manure.Products = null,
    grid: ?*const grid_module.GridState = null,
    /// Required by belowground harvest. Unlike the legacy scalar morphology
    /// workspace, this preserves element-specific source composition and the
    /// distinct root-versus-storage FWOOD families.
    belowground_harvest_composition_by_plant: ?[]const group_types.BelowgroundHarvestComposition = null,
    root_woody_fraction_by_plant: ?[]const f64 = null,
    carbon_exchange_state: ?*carbon_exchange.State = null,
    reseed_population_per_m2_by_plant: ?[]const f64 = null,
    cell_area_m2_by_cell: ?[]const f64 = null,
    /// Date assigned to source-generated automatic harvests. This mirrors
    /// IDAYH/IYRH and is distinct from user management schedules.
    automatic_harvest_date_by_plant: ?[]management.PackedDate = null,
    /// Required for the GROSUB 9661--9768 post-cut/reset and coherent
    /// post-harvest aggregation block. Kept optional for dependency-light
    /// unit kernels; the production composition root binds every owner.
    post_harvest: ?PostHarvestBinding = null,
    current_day_of_year: u16 = 0,
};

pub const PostHarvestBinding = struct {
    dormancy_state: *dormancy.RuntimeState,
    dormancy_parameters_by_plant: []const dormancy.Parameters,
    biomass_turnover_type_by_plant: []const u8,
    root_profile_type_by_plant: []const u8,
    winter_phenology_type_by_plant: []const u8,
    initial_maturity_group_by_plant: []const f64,
};

pub const PopulationAfterDisturbance = struct {
    living_population_per_m2: f64,
    living_population_count: f64,
    standing_dead_population_count: f64,
};

/// GROSUB JHVST=2 retains all physically exported harvested material as seed
/// storage for the next establishment instead of removing it from the ecosystem.
pub fn retainReseedProductsInSeedStorage(context: *Context, plant: usize) !void {
    const products = &context.products_by_plant[plant];
    var retained: canopy.ElementalMass = .{};
    addMass(&retained, products.nonstructural.ecosystem_export);
    addMass(&retained, products.foliar.ecosystem_export);
    addMass(&retained, products.nonfoliar.ecosystem_export);
    addMass(&retained, products.woody.ecosystem_export);
    addMass(&retained, products.standing_dead_export);
    const state = context.canopy_state;
    const next_carbon_g = state.plant_seed_storage_carbon_g[plant] + retained.carbon_g;
    const next_nitrogen_g = state.plant_seed_storage_nitrogen_g[plant] + retained.nitrogen_g;
    const next_phosphorus_g = state.plant_seed_storage_phosphorus_g[plant] + retained.phosphorus_g;
    inline for (.{ next_carbon_g, next_nitrogen_g, next_phosphorus_g }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantReseedStorage;
    state.plant_seed_storage_carbon_g[plant] = next_carbon_g;
    state.plant_seed_storage_nitrogen_g[plant] = next_nitrogen_g;
    state.plant_seed_storage_phosphorus_g[plant] = next_phosphorus_g;
    products.nonstructural.ecosystem_export = .{};
    products.foliar.ecosystem_export = .{};
    products.nonfoliar.ecosystem_export = .{};
    products.woody.ecosystem_export = .{};
    products.standing_dead_export = .{};
}

pub fn totalBranchPool(state: *const canopy.State, branches: canopy.Range, comptime field_name: []const u8) f64 {
    var total: f64 = 0;
    // applyGrazingEvent validates authoritative branch pools before calling.
    // Sum exact inventories here so a prohibited negative can never be hidden.
    for (@field(state, field_name)[branches.first..branches.end]) |value| total += value;
    return total;
}

pub fn removalFraction(target: f64, total: f64) f64 {
    return if (total > 0) std.math.clamp(target / total, 0, 1) else 0;
}

pub fn routeGrazedMass(products: *canopy.HarvestProducts, removed: canopy.ElementalMass, export_fraction: f64) void {
    addScaledMass(&products.ecosystem_export, removed, export_fraction);
    addScaledMass(&products.litter, removed, 1 - export_fraction);
}

pub fn productLedgerCarbonG(ledger: group_types.ProductLedger) f64 {
    // harvested_grain is a diagnostic subset of reproductive products, not
    // a second physical pool.
    var total_g_c = ledger.standing_dead_export.carbon_g +
        ledger.standing_dead_charcoal_litter.carbon_g;
    inline for (.{ "nonstructural", "foliar", "nonfoliar", "woody" }) |field_name| {
        total_g_c += @field(ledger, field_name).ecosystem_export.carbon_g;
        total_g_c += @field(ledger, field_name).litter.carbon_g;
    }
    for (ledger.direct_litter.woody_carbon_g, ledger.direct_litter.nonwoody_carbon_g) |woody, nonwoody|
        total_g_c += woody + nonwoody;
    for (ledger.manure.organic_by_biochemical_fraction) |mass| total_g_c += mass.carbon_g;
    return total_g_c;
}

pub fn preflightGrazing(context: *const Context, plant: usize, event: management.HarvestEvent, layers: *const canopy_layers.State) !void {
    const state = context.canopy_state;
    if (!std.math.isFinite(event.cutting_height_m_or_lai_fraction) or event.cutting_height_m_or_lai_fraction < 0 or
        !std.math.isFinite(event.thinning_fraction_or_consumption_rate) or event.thinning_fraction_or_consumption_rate < 0)
        return error.InvalidGrazingEvent;
    inline for (@typeInfo(management.RemovalFractions).@"struct".fields) |field| {
        try group_validation.validateGrazingFraction(@field(event.harvested_fraction, field.name));
        try group_validation.validateGrazingFraction(@field(event.ecosystem_export_fraction, field.name));
    }
    try state.validateFinite();
    inline for (.{
        "plant_standing_dead_carbon_g",
        "plant_standing_dead_nitrogen_g",
        "plant_standing_dead_phosphorus_g",
    }) |field_name| try group_validation.validateNonnegativeFinite(field_name, @field(state, field_name), plant, plant + 1);
    const kinetic_first = try std.math.mul(usize, plant, 4);
    inline for (.{
        "plant_standing_dead_carbon_by_kinetic_g",
        "plant_standing_dead_nitrogen_by_kinetic_g",
        "plant_standing_dead_phosphorus_by_kinetic_g",
    }) |field_name| try group_validation.validateNonnegativeFinite(field_name, @field(state, field_name), kinetic_first, kinetic_first + 4);
    const standing_area_first = try std.math.mul(usize, plant, layers.layer_count);
    try group_validation.validateNonnegativeFinite("plant_standing_dead_area_m2", layers.plant_standing_dead_area_m2, standing_area_first, standing_area_first + layers.layer_count);
    const branches = try state.branchRange(plant);
    inline for (.{
        "branch_leaf_carbon_g",                "branch_leaf_nitrogen_g",                "branch_leaf_phosphorus_g",
        "branch_sheath_carbon_g",              "branch_sheath_nitrogen_g",              "branch_sheath_phosphorus_g",
        "branch_husk_carbon_g",                "branch_husk_nitrogen_g",                "branch_husk_phosphorus_g",
        "branch_ear_carbon_g",                 "branch_ear_nitrogen_g",                 "branch_ear_phosphorus_g",
        "branch_grain_carbon_g",               "branch_grain_nitrogen_g",               "branch_grain_phosphorus_g",
        "branch_stalk_carbon_g",               "branch_stalk_nitrogen_g",               "branch_stalk_phosphorus_g",
        "branch_reserve_carbon_g",             "branch_reserve_nitrogen_g",             "branch_reserve_phosphorus_g",
        "branch_mobile_carbon_g",              "branch_mobile_nitrogen_g",              "branch_mobile_phosphorus_g",
        "branch_symbiont_mobile_carbon_g",     "branch_symbiont_mobile_nitrogen_g",     "branch_symbiont_mobile_phosphorus_g",
        "branch_symbiont_structural_carbon_g", "branch_symbiont_structural_nitrogen_g", "branch_symbiont_structural_phosphorus_g",
    }) |field_name| try group_validation.validateNonnegativeFinite(field_name, @field(state, field_name), branches.first, branches.end);
    const expected_samples_per_node = try std.math.mul(usize, layers.layer_count, try std.math.mul(usize, layers.inclination_count, layers.azimuth_count));
    for (branches.first..branches.end) |branch| {
        const nodes = try state.nodeRange(branch);
        inline for (.{
            "node_leaf_area_m2",         "node_leaf_carbon_g",          "node_leaf_nitrogen_g",     "node_leaf_phosphorus_g",
            "node_sheath_carbon_g",      "node_sheath_nitrogen_g",      "node_sheath_phosphorus_g", "node_internode_carbon_g",
            "node_internode_nitrogen_g", "node_internode_phosphorus_g",
        }) |field_name| try group_validation.validateNonnegativeFinite(field_name, @field(state, field_name), nodes.first, nodes.end);
        for (nodes.first..nodes.end) |node| {
            const samples = try state.sampleRange(node);
            if (samples.end - samples.first != expected_samples_per_node) return error.GrazingSampleTopologyMismatch;
            inline for (.{
                "sample_leaf_area_m2",    "sample_exposed_leaf_area_m2", "sample_leaf_carbon_g",
                "sample_leaf_nitrogen_g", "sample_leaf_phosphorus_g",    "sample_stalk_area_m2",
            }) |field_name| try group_validation.validateNonnegativeFinite(field_name, @field(state, field_name), samples.first, samples.end);
            const layer_first = try std.math.mul(usize, node, layers.layer_count);
            inline for (.{ "node_leaf_area_m2", "node_leaf_carbon_g", "node_leaf_nitrogen_g", "node_leaf_phosphorus_g" }) |field_name|
                try group_validation.validateNonnegativeFinite(field_name, @field(layers, field_name), layer_first, layer_first + layers.layer_count);
        }
    }
}

pub fn addElementPartition(litter: *@import("../plant/root/plant_root_metabolism.zig").RootLitter, mass: canopy.ElementalMass, fractions: litter_partition.ElementFractions, woody: bool, multiplier: f64) void {
    for (0..root_litterfall.kinetic_component_count) |component| {
        if (woody) {
            litter.woody_carbon_g_c[component] += mass.carbon_g * multiplier * fractions.carbon[component];
            litter.woody_nitrogen_g_n[component] += mass.nitrogen_g * multiplier * fractions.nitrogen[component];
            litter.woody_phosphorus_g_p[component] += mass.phosphorus_g * multiplier * fractions.phosphorus[component];
        } else {
            litter.nonwoody_carbon_g_c[component] += mass.carbon_g * multiplier * fractions.carbon[component];
            litter.nonwoody_nitrogen_g_n[component] += mass.nitrogen_g * multiplier * fractions.nitrogen[component];
            litter.nonwoody_phosphorus_g_p[component] += mass.phosphorus_g * multiplier * fractions.phosphorus[component];
        }
    }
}

pub fn unexportedFraction(remaining: f64, ecosystem_export_fraction: f64) f64 {
    return remaining + (1.0 - remaining) * (1.0 - ecosystem_export_fraction);
}

pub fn addProducts(target: *canopy.HarvestProducts, source: canopy.HarvestProducts) void {
    addMass(&target.ecosystem_export, source.ecosystem_export);
    addMass(&target.litter, source.litter);
}

pub fn addMass(target: *canopy.ElementalMass, source: canopy.ElementalMass) void {
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| @field(target, field.name) += @field(source, field.name);
}

pub fn subtractMass(target: *canopy.ElementalMass, source: canopy.ElementalMass) !void {
    var next = target.*;
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        const value = @field(target, field.name) - @field(source, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.HarvestProductSubtractionWouldOverdraw;
        @field(next, field.name) = value;
    }
    target.* = next;
}

pub fn addMassToStorage(state: *canopy.State, plant: usize, mass: canopy.ElementalMass) void {
    state.plant_seed_storage_carbon_g[plant] += mass.carbon_g;
    state.plant_seed_storage_nitrogen_g[plant] += mass.nitrogen_g;
    state.plant_seed_storage_phosphorus_g[plant] += mass.phosphorus_g;
}

pub fn addMassToStandingDead(state: *canopy.State, plant: usize, mass: canopy.ElementalMass, kinetics: litter_partition.ElementFractions) void {
    state.plant_standing_dead_carbon_g[plant] += mass.carbon_g;
    state.plant_standing_dead_nitrogen_g[plant] += mass.nitrogen_g;
    state.plant_standing_dead_phosphorus_g[plant] += mass.phosphorus_g;
    for (0..4) |kinetic| {
        const index = plant * 4 + kinetic;
        state.plant_standing_dead_carbon_by_kinetic_g[index] += mass.carbon_g * kinetics.carbon[kinetic];
        state.plant_standing_dead_nitrogen_by_kinetic_g[index] += mass.nitrogen_g * kinetics.nitrogen[kinetic];
        state.plant_standing_dead_phosphorus_by_kinetic_g[index] += mass.phosphorus_g * kinetics.phosphorus[kinetic];
    }
}

pub fn addScaledMass(target: *canopy.ElementalMass, source: canopy.ElementalMass, fraction: f64) void {
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| @field(target, field.name) += fraction * @field(source, field.name);
}

// Moved to plant_harvest_source_order.zig; re-exported so call sites are unchanged.
pub const __sourceOrder = @import("plant_harvest_source_order.zig");
