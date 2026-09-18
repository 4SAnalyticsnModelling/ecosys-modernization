//! `plant_harvest_runtime` declarations: harvest.
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
const root_metabolism = @import("../plant/root/plant_root_metabolism.zig");
const group_misc = @import("plant_harvest_runtime_misc.zig");
const group_source_order_exports = @import("plant_harvest_runtime_source_order_exports.zig");
const group_types = @import("plant_harvest_runtime_types.zig");

pub const harvest_product_component_count: usize = 5;

/// Current-hour GROSUB 406-464 FWOOD/FWODR composition used by the later
/// belowground harvest blocks. The three element arrays remain distinct in
/// the contract even though the reference currently copies the C fractions
/// into the N/P fractions at lines 455-462.
pub fn sourceOrderBelowgroundHarvestComposition(
    woody_growth_enabled: bool,
    deep_root_profile: bool,
    growth_habit: u8,
    stalk_carbon_g_c: f64,
    sapwood_carbon_g_c: f64,
    stalk_nitrogen_to_carbon_g_n_per_g_c: f64,
    root_nitrogen_to_carbon_g_n_per_g_c: f64,
    stalk_phosphorus_to_carbon_g_p_per_g_c: f64,
    root_phosphorus_to_carbon_g_p_per_g_c: f64,
    structural_presence_threshold_g_c: f64,
    nonwoody_root_fraction_exponent: f64,
) !group_types.BelowgroundHarvestComposition {
    const root = try root_metabolism.rootWoodComposition(
        woody_growth_enabled,
        deep_root_profile,
        stalk_carbon_g_c,
        sapwood_carbon_g_c,
        stalk_nitrogen_to_carbon_g_n_per_g_c,
        root_nitrogen_to_carbon_g_n_per_g_c,
        stalk_phosphorus_to_carbon_g_p_per_g_c,
        root_phosphorus_to_carbon_g_p_per_g_c,
        structural_presence_threshold_g_c,
        nonwoody_root_fraction_exponent,
    );
    const stalk_nonwoody = if (!woody_growth_enabled or !deep_root_profile or
        stalk_carbon_g_c <= structural_presence_threshold_g_c)
        1.0
    else
        std.math.clamp(sapwood_carbon_g_c / stalk_carbon_g_c, 0, 1);
    const stalk_fraction = [2]f64{ 1 - stalk_nonwoody, stalk_nonwoody };
    const result: group_types.BelowgroundHarvestComposition = .{
        .root_woody_nonwoody = .{
            .carbon = root.carbon_fraction,
            .nitrogen = root.nitrogen_fraction,
            .phosphorus = root.phosphorus_fraction,
        },
        .storage_woody_nonwoody = .{
            .carbon = stalk_fraction,
            .nitrogen = stalk_fraction,
            .phosphorus = stalk_fraction,
        },
        .perennial = growth_habit != 0,
    };
    try result.validate();
    return result;
}

pub fn prunedClumpingFactor(current_clumping_factor: f64, pruning_fraction: f64) !f64 {
    inline for (.{ current_clumping_factor, pruning_fraction }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidPruningClumpingFraction;
    const result = current_clumping_factor * pruning_fraction;
    if (!std.math.isFinite(result)) return error.NonFinitePruningClumpingFactor;
    return result;
}

/// Exact GROSUB ARLFY/ARLFR conversion from a negative fractional combined-
/// canopy leaf-area request to a physical cutting height.
pub fn cuttingHeightFromLeafAreaRemoval(
    requested_fraction: f64,
    boundary_height_m: []const f64,
    combined_leaf_area_m2: []const f64,
    presence_tolerance_m2: f64,
) !f64 {
    if (!std.math.isFinite(requested_fraction) or requested_fraction < 0 or requested_fraction > 1 or
        !std.math.isFinite(presence_tolerance_m2) or presence_tolerance_m2 < 0 or
        boundary_height_m.len != combined_leaf_area_m2.len + 1 or combined_leaf_area_m2.len == 0)
        return error.InvalidLeafAreaHarvestGeometry;
    var total_leaf_area_m2: f64 = 0;
    for (combined_leaf_area_m2) |area| {
        if (!std.math.isFinite(area) or area < 0) return error.InvalidLeafAreaHarvestGeometry;
        total_leaf_area_m2 += area;
    }
    return group_source_order_exports.sourceOrderCuttingHeightFromLeafAreaRemoval(
        requested_fraction,
        total_leaf_area_m2,
        boundary_height_m,
        combined_leaf_area_m2,
        presence_tolerance_m2,
    );
}

pub fn addHarvestLitterKinetics(
    destination: *canopy.SenescenceProducts,
    mass: canopy.ElementalMass,
    fractions: litter_partition.ElementFractions,
    woody: bool,
) !void {
    inline for (.{ mass.carbon_g, mass.nitrogen_g, mass.phosphorus_g }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantHarvestProduct;
    for (0..4) |kinetic| {
        if (woody) {
            destination.woody_carbon_g[kinetic] += mass.carbon_g * fractions.carbon[kinetic];
            destination.woody_nitrogen_g[kinetic] += mass.nitrogen_g * fractions.nitrogen[kinetic];
            destination.woody_phosphorus_g[kinetic] += mass.phosphorus_g * fractions.phosphorus[kinetic];
        } else {
            destination.nonwoody_carbon_g[kinetic] += mass.carbon_g * fractions.carbon[kinetic];
            destination.nonwoody_nitrogen_g[kinetic] += mass.nitrogen_g * fractions.nitrogen[kinetic];
            destination.nonwoody_phosphorus_g[kinetic] += mass.phosphorus_g * fractions.phosphorus[kinetic];
        }
    }
}

pub fn harvestLitterToKinetics(
    products: group_types.ProductLedger,
    nonstructural: litter_partition.ElementFractions,
    foliar: litter_partition.ElementFractions,
    nonfoliar: litter_partition.ElementFractions,
    woody: litter_partition.ElementFractions,
) !canopy.SenescenceProducts {
    try nonstructural.validate();
    try foliar.validate();
    try nonfoliar.validate();
    try woody.validate();
    var result: canopy.SenescenceProducts = products.direct_litter;
    try addHarvestLitterKinetics(&result, products.nonstructural.litter, nonstructural, false);
    try addHarvestLitterKinetics(&result, products.foliar.litter, foliar, false);
    try addHarvestLitterKinetics(&result, products.nonfoliar.litter, nonfoliar, false);
    try addHarvestLitterKinetics(&result, products.woody.litter, woody, true);
    return result;
}

/// Publishes all above-ground harvest litter and returns ecosystem exports.
/// The product ledger is cleared only after the surface transaction succeeds.
pub fn publishPlantProducts(context: *group_misc.Context, plant: usize) !canopy.ElementalMass {
    if (plant >= context.products_by_plant.len) return error.PlantHarvestIndexOutOfBounds;
    const partitions = context.root_litter_partition orelse return error.IncompletePlantHarvestLitterContext;
    const surface = context.surface_organic_state orelse return error.IncompletePlantHarvestLitterContext;
    const grid = context.grid orelse return error.IncompletePlantHarvestLitterContext;
    if (plant >= partitions.plant_count or context.canopy_state.species_count == 0) return error.PlantHarvestIndexOutOfBounds;
    const cell = plant / context.canopy_state.species_count;
    if (cell >= grid.cell_count) return error.PlantHarvestIndexOutOfBounds;
    const products = context.products_by_plant[plant];
    const litter = try harvestLitterToKinetics(
        products,
        try partitions.get(plant, .nonstructural),
        try partitions.get(plant, .foliar),
        try partitions.get(plant, .non_foliar),
        try partitions.get(plant, .coarse_wood),
    );
    var shoot_litter: canopy.ElementalMass = .{};
    for (0..litter.woody_carbon_g.len) |kinetic| {
        shoot_litter.carbon_g +=
            litter.woody_carbon_g[kinetic] +
            litter.nonwoody_carbon_g[kinetic];
        shoot_litter.nitrogen_g +=
            litter.woody_nitrogen_g[kinetic] +
            litter.nonwoody_nitrogen_g[kinetic];
        shoot_litter.phosphorus_g +=
            litter.woody_phosphorus_g[kinetic] +
            litter.nonwoody_phosphorus_g[kinetic];
        inline for (.{
            shoot_litter.carbon_g,
            shoot_litter.nitrogen_g,
            shoot_litter.phosphorus_g,
        }) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPlantHarvestProduct;
    }
    group_misc.addMass(&shoot_litter, products.standing_dead_charcoal_litter);
    const has_litter_state_update =
        context.shoot_litter_carbon_g_c_by_plant != null or
        context.shoot_litter_nitrogen_g_n_by_plant != null or
        context.shoot_litter_phosphorus_g_p_by_plant != null;
    const next_shoot_litter: ?canopy.ElementalMass = if (has_litter_state_update) blk: {
        const carbon = context.shoot_litter_carbon_g_c_by_plant orelse
            return error.IncompletePlantHarvestLitterStateUpdate;
        const nitrogen = context.shoot_litter_nitrogen_g_n_by_plant orelse
            return error.IncompletePlantHarvestLitterStateUpdate;
        const phosphorus = context.shoot_litter_phosphorus_g_p_by_plant orelse
            return error.IncompletePlantHarvestLitterStateUpdate;
        if (carbon.len != context.products_by_plant.len or
            nitrogen.len != carbon.len or phosphorus.len != carbon.len)
            return error.PlantHarvestLitterStateUpdateDimensionMismatch;
        const next: canopy.ElementalMass = .{
            .carbon_g = carbon[plant] + shoot_litter.carbon_g,
            .nitrogen_g = nitrogen[plant] + shoot_litter.nitrogen_g,
            .phosphorus_g = phosphorus[plant] + shoot_litter.phosphorus_g,
        };
        inline for (.{ next.carbon_g, next.nitrogen_g, next.phosphorus_g }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidPlantHarvestProduct;
        break :blk next;
    } else null;
    var exported: canopy.ElementalMass = .{};
    group_misc.addMass(&exported, products.nonstructural.ecosystem_export);
    group_misc.addMass(&exported, products.foliar.ecosystem_export);
    group_misc.addMass(&exported, products.nonfoliar.ecosystem_export);
    group_misc.addMass(&exported, products.woody.ecosystem_export);
    group_misc.addMass(&exported, products.standing_dead_export);
    inline for (.{ exported.carbon_g, exported.nitrogen_g, exported.phosphorus_g }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantHarvestProduct;
    var manure_carbon_g_c: f64 = 0;
    for (products.manure.organic_by_biochemical_fraction) |mass| manure_carbon_g_c += mass.carbon_g;
    const has_manure = manure_carbon_g_c > 0 or products.manure.inorganic_nitrogen_g_n > 0 or products.manure.inorganic_phosphorus_g_p > 0;
    const nutrients = if (has_manure)
        context.surface_nutrient_state orelse return error.IncompleteGrazingManureContext
    else
        null;
    var manure_nitrogen_g_n = products.manure.inorganic_nitrogen_g_n;
    var manure_phosphorus_g_p = products.manure.inorganic_phosphorus_g_p;
    for (products.manure.organic_by_biochemical_fraction) |mass| {
        manure_nitrogen_g_n += mass.nitrogen_g;
        manure_phosphorus_g_p += mass.phosphorus_g;
    }
    const daily_manure_next: ?canopy.ElementalMass = if (has_manure) blk: {
        const daily_c = context.daily_manure_carbon_input_g_c orelse return error.IncompleteGrazingManureContext;
        const daily_n = context.daily_manure_nitrogen_input_g_n orelse return error.IncompleteGrazingManureContext;
        const daily_p = context.daily_manure_phosphorus_input_g_p orelse return error.IncompleteGrazingManureContext;
        if (cell >= daily_c.len or cell >= daily_n.len or cell >= daily_p.len) return error.GrazingManureDailyLedgerDimensionMismatch;
        const next: canopy.ElementalMass = .{
            .carbon_g = daily_c[cell] + manure_carbon_g_c,
            .nitrogen_g = daily_n[cell] + manure_nitrogen_g_n,
            .phosphorus_g = daily_p[cell] + manure_phosphorus_g_p,
        };
        inline for (.{ next.carbon_g, next.nitrogen_g, next.phosphorus_g }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.GrazingManureDailyLedgerOverflow;
        break :blk next;
    } else null;
    const hourly_manure_next: ?grazing_manure.Products = if (context.hourly_manure_products_by_plant) |hourly| blk: {
        if (hourly.len != context.products_by_plant.len)
            return error.GrazingManureHourlyLedgerDimensionMismatch;
        var next = hourly[plant];
        try grazing_manure.add(&next, products.manure);
        break :blk next;
    } else null;
    if (has_manure) {
        try grazing_manure.validateOrganicStateUpdate(surface, cell, products.manure);
        try nutrients.?.validateSurfaceNutrients(
            cell,
            products.manure.inorganic_nitrogen_g_n / 14.0,
            products.manure.inorganic_phosphorus_g_p / 31.0,
        );
    }
    try shoot_litter_bridge.validateCharcoalStateUpdate(
        surface,
        cell,
        products.standing_dead_charcoal_litter,
    );
    try shoot_litter_bridge.state_updateCell(surface, cell, litter);
    try shoot_litter_bridge.state_updateCharcoalCell(
        surface,
        cell,
        products.standing_dead_charcoal_litter,
    );
    if (has_manure) {
        try grazing_manure.state_updateOrganic(surface, cell, products.manure);
        try nutrients.?.addSurfaceNutrients(
            cell,
            products.manure.inorganic_nitrogen_g_n / 14.0,
            products.manure.inorganic_phosphorus_g_p / 31.0,
        );
        context.daily_manure_carbon_input_g_c.?[cell] = daily_manure_next.?.carbon_g;
        context.daily_manure_nitrogen_input_g_n.?[cell] = daily_manure_next.?.nitrogen_g;
        context.daily_manure_phosphorus_input_g_p.?[cell] = daily_manure_next.?.phosphorus_g;
    }
    if (next_shoot_litter) |next| {
        context.shoot_litter_carbon_g_c_by_plant.?[plant] = next.carbon_g;
        context.shoot_litter_nitrogen_g_n_by_plant.?[plant] = next.nitrogen_g;
        context.shoot_litter_phosphorus_g_p_by_plant.?[plant] = next.phosphorus_g;
    }
    if (hourly_manure_next) |next|
        context.hourly_manure_products_by_plant.?[plant] = next;
    context.products_by_plant[plant] = .{};
    return exported;
}

pub fn noduleHarvestResult(
    nitrogen_fixation_type: u8,
    structural: symbiotic_fixation.Pool,
    mobile: symbiotic_fixation.Pool,
    remaining_fraction: f64,
    structural_partition: litter_partition.ElementFractions,
    mobile_partition: litter_partition.ElementFractions,
) !root_disturbance.Result {
    if (try root_disturbance.sourceOrderNoduleHarvestIsEnabled(
        nitrogen_fixation_type,
        0,
        root_system.biological_domain_count,
    )) {
        return root_disturbance.retainAndRelease(
            structural,
            mobile,
            root_disturbance.ElementRetention.uniform(remaining_fraction),
            structural_partition,
            mobile_partition,
        );
    }
    return .{
        .structural = structural,
        .mobile = mobile,
        .litterfall = std.mem.zeroes(@import("../plant/root/plant_root_metabolism.zig").RootLitter),
    };
}

const HostLayerHarvest = struct {
    litterfall: @import("../plant/root/plant_root_metabolism.zig").RootLitter,
    removed: symbiotic_fixation.Pool,
};

pub fn hostLayerHarvest(
    roots: *const root_system.State,
    plant: usize,
    layer: usize,
    retention: root_disturbance.ElementRetention,
    woody_fraction: root_disturbance.ElementRetention,
    fine: litter_partition.ElementFractions,
    coarse: litter_partition.ElementFractions,
    mobile: litter_partition.ElementFractions,
) !HostLayerHarvest {
    return hostLayerHarvestRange(
        roots,
        plant,
        0,
        root_system.biological_domain_count,
        layer,
        retention,
        woody_fraction,
        fine,
        coarse,
        mobile,
    );
}

pub fn hostLayerHarvestDomain(
    roots: *const root_system.State,
    plant: usize,
    domain: usize,
    layer: usize,
    retention: root_disturbance.ElementRetention,
    woody_fraction: root_disturbance.ElementRetention,
    fine: litter_partition.ElementFractions,
    coarse: litter_partition.ElementFractions,
    mobile: litter_partition.ElementFractions,
) !HostLayerHarvest {
    if (domain >= root_system.biological_domain_count)
        return error.PlantRootIndexOutOfBounds;
    return hostLayerHarvestRange(
        roots,
        plant,
        domain,
        domain + 1,
        layer,
        retention,
        woody_fraction,
        fine,
        coarse,
        mobile,
    );
}

fn hostLayerHarvestRange(
    roots: *const root_system.State,
    plant: usize,
    first_domain: usize,
    end_domain: usize,
    layer: usize,
    retention: root_disturbance.ElementRetention,
    woody_fraction: root_disturbance.ElementRetention,
    fine: litter_partition.ElementFractions,
    coarse: litter_partition.ElementFractions,
    mobile: litter_partition.ElementFractions,
) !HostLayerHarvest {
    var litter: root_litterfall.LayerInput = .{};
    var removed = std.mem.zeroes(symbiotic_fixation.Pool);
    for (first_domain..end_domain) |domain| {
        const root = try roots.layerIndex(plant, domain, layer);
        const mobile_result = try root_disturbance.sourceOrderHostHarvestLitter(
            .{
                .carbon_g_c = roots.mobile_carbon_g[root],
                .nitrogen_g_n = roots.mobile_nitrogen_g[root],
                .phosphorus_g_p = roots.mobile_phosphorus_g[root],
            },
            &.{},
            retention,
            woody_fraction,
            mobile,
            fine,
            coarse,
        );
        try litter.add(mobile_result.litterfall);
        inline for (@typeInfo(symbiotic_fixation.Pool).@"struct".fields) |field|
            @field(removed, field.name) += @field(mobile_result.removed, field.name);
        for (0..roots.active_root_axis_count[plant]) |axis| {
            const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
            const structural = symbiotic_fixation.Pool{
                .carbon_g_c = roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer],
                .nitrogen_g_n = roots.axis_primary_nitrogen_g[axis_layer] + roots.axis_secondary_nitrogen_g[axis_layer],
                .phosphorus_g_p = roots.axis_primary_phosphorus_g[axis_layer] + roots.axis_secondary_phosphorus_g[axis_layer],
            };
            const structural_result = try root_disturbance.sourceOrderHostHarvestLitter(
                std.mem.zeroes(symbiotic_fixation.Pool),
                &.{structural},
                retention,
                woody_fraction,
                mobile,
                fine,
                coarse,
            );
            try litter.add(structural_result.litterfall);
            inline for (@typeInfo(symbiotic_fixation.Pool).@"struct".fields) |field|
                @field(removed, field.name) += @field(structural_result.removed, field.name);
        }
    }
    return .{ .litterfall = litter.litter, .removed = removed };
}

fn scaleHostLayerHarvestState(
    roots: *root_system.State,
    plant: usize,
    layer: usize,
    retention: root_disturbance.ElementRetention,
    commit: bool,
) !void {
    for (0..root_system.biological_domain_count) |domain| {
        const root = try roots.layerIndex(plant, domain, layer);
        const layer_state: root_disturbance.HostLayerHarvestState = .{
            .mobile = .{ .carbon_g_c = roots.mobile_carbon_g[root], .nitrogen_g_n = roots.mobile_nitrogen_g[root], .phosphorus_g_p = roots.mobile_phosphorus_g[root] },
            .active_root_carbon_g_c = roots.total_carbon_g[root],
            .actual_root_carbon_g_c = roots.primary_root_carbon_g[root],
            .protein_mass_g = roots.protein_carbon_g[root],
            .primary_axis_count = 0,
            .total_root_axis_count = roots.secondary_axis_count_total[root],
            .root_length_m_per_plant = roots.root_length_m_per_plant[root],
            .root_length_density_m_per_m3 = roots.root_length_density_m_per_m3[root],
            .gaseous_volume_m3 = roots.gaseous_volume_m3[root],
            .aqueous_volume_m3 = roots.aqueous_volume_m3[root],
            .root_surface_area_m2_per_plant = roots.root_surface_area_m2_per_plant[root],
            .respiration_unlimited_by_oxygen_g_c_per_h = roots.respiration_unlimited_by_oxygen_g_c_per_h[root],
            .respiration_unlimited_by_carbon_g_c_per_h = roots.respiration_unlimited_by_carbon_g_c_per_h[root],
            .actual_respiration_g_c_per_h = roots.actual_respiration_g_c_per_h[root],
        };
        const scaled_layer = (try root_disturbance.sourceOrderScaleHostHarvestState(
            std.mem.zeroes(root_disturbance.HostAxisHarvestState),
            layer_state,
            retention,
        )).layer;
        for (0..roots.active_root_axis_count[plant]) |axis| {
            const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
            var axis_aux_layer = std.mem.zeroes(root_disturbance.HostLayerHarvestState);
            axis_aux_layer.primary_axis_count = roots.axis_primary_count[axis_layer];
            const scaled = try root_disturbance.sourceOrderScaleHostHarvestState(.{
                .primary = .{ .carbon_g_c = roots.axis_primary_carbon_g[axis_layer], .nitrogen_g_n = roots.axis_primary_nitrogen_g[axis_layer], .phosphorus_g_p = roots.axis_primary_phosphorus_g[axis_layer] },
                .secondary = .{ .carbon_g_c = roots.axis_secondary_carbon_g[axis_layer], .nitrogen_g_n = roots.axis_secondary_nitrogen_g[axis_layer], .phosphorus_g_p = roots.axis_secondary_phosphorus_g[axis_layer] },
                // RTWT1* is derived from the layer-resolved primary pools in
                // runtime state; no duplicate mutable total is stored.
                .total_primary = std.mem.zeroes(symbiotic_fixation.Pool),
                .primary_length_m = roots.axis_primary_length_m[axis_layer],
                .secondary_length_m = roots.axis_secondary_length_m[axis_layer],
                .secondary_axis_count = roots.axis_secondary_count[axis_layer],
            }, axis_aux_layer, retention);
            if (commit) {
                roots.axis_primary_carbon_g[axis_layer] = scaled.axis.primary.carbon_g_c;
                roots.axis_primary_nitrogen_g[axis_layer] = scaled.axis.primary.nitrogen_g_n;
                roots.axis_primary_phosphorus_g[axis_layer] = scaled.axis.primary.phosphorus_g_p;
                roots.axis_secondary_carbon_g[axis_layer] = scaled.axis.secondary.carbon_g_c;
                roots.axis_secondary_nitrogen_g[axis_layer] = scaled.axis.secondary.nitrogen_g_n;
                roots.axis_secondary_phosphorus_g[axis_layer] = scaled.axis.secondary.phosphorus_g_p;
                roots.axis_primary_length_m[axis_layer] = scaled.axis.primary_length_m;
                roots.axis_secondary_length_m[axis_layer] = scaled.axis.secondary_length_m;
                roots.axis_primary_count[axis_layer] = scaled.layer.primary_axis_count;
                roots.axis_secondary_count[axis_layer] = scaled.axis.secondary_axis_count;
            }
        }
        if (commit) {
            roots.mobile_carbon_g[root] = scaled_layer.mobile.carbon_g_c;
            roots.mobile_nitrogen_g[root] = scaled_layer.mobile.nitrogen_g_n;
            roots.mobile_phosphorus_g[root] = scaled_layer.mobile.phosphorus_g_p;
            roots.total_carbon_g[root] = scaled_layer.active_root_carbon_g_c;
            roots.primary_root_carbon_g[root] = scaled_layer.actual_root_carbon_g_c;
            roots.protein_carbon_g[root] = scaled_layer.protein_mass_g;
            roots.secondary_axis_count_total[root] = scaled_layer.total_root_axis_count;
            roots.root_length_m_per_plant[root] = scaled_layer.root_length_m_per_plant;
            roots.root_length_density_m_per_m3[root] = scaled_layer.root_length_density_m_per_m3;
            roots.gaseous_volume_m3[root] = scaled_layer.gaseous_volume_m3;
            roots.aqueous_volume_m3[root] = scaled_layer.aqueous_volume_m3;
            roots.root_surface_area_m2_per_plant[root] = scaled_layer.root_surface_area_m2_per_plant;
            roots.respiration_unlimited_by_oxygen_g_c_per_h[root] = scaled_layer.respiration_unlimited_by_oxygen_g_c_per_h;
            roots.respiration_unlimited_by_carbon_g_c_per_h[root] = scaled_layer.respiration_unlimited_by_carbon_g_c_per_h;
            roots.actual_respiration_g_c_per_h[root] = scaled_layer.actual_respiration_g_c_per_h;
        }
    }
}

pub fn validateHostLayerHarvestState(roots: *root_system.State, plant: usize, layer: usize, retention: root_disturbance.ElementRetention) !void {
    try scaleHostLayerHarvestState(roots, plant, layer, retention, false);
}

pub fn state_updateHostLayerHarvest(roots: *root_system.State, plant: usize, layer: usize, retention: root_disturbance.ElementRetention) void {
    scaleHostLayerHarvestState(roots, plant, layer, retention, true) catch unreachable;
}

pub fn harvestVegetativeBranch(context: *group_misc.Context, plant: usize, branch: usize, event: management.HarvestEvent, science: group_types.ScienceParameters, pruning: bool) !void {
    const state = context.canopy_state;
    const nodes = try state.nodeRange(branch);
    const layer_geometry = if (context.canopy_layer_state) |layers| blk: {
        if (branch >= layers.branch_count or plant >= layers.cell_count * layers.species_count)
            return error.PlantHarvestLayerGeometryDimensionMismatch;
        const angular_count = try std.math.mul(usize, layers.inclination_count, layers.azimuth_count);
        const expected_sample_count = try std.math.mul(usize, layers.layer_count, angular_count);
        for (nodes.first..nodes.end) |node| {
            const samples = try state.sampleRange(node);
            if (samples.end - samples.first != expected_sample_count)
                return error.PlantHarvestLayerGeometryDimensionMismatch;
        }
        break :blk .{ .layers = layers, .angular_count = angular_count };
    } else null;
    const initial_leaf_sheath_c = state.branch_leaf_carbon_g[branch] + state.branch_sheath_carbon_g[branch];
    var maximum_height_m: f64 = 0;
    for (state.node_height_m[nodes.first..nodes.end]) |height_m| maximum_height_m = @max(maximum_height_m, height_m);
    for (nodes.first..nodes.end) |node| {
        const node_within_branch = node - nodes.first;
        const initial_leaf_c = state.node_leaf_carbon_g[node];
        const samples = try state.sampleRange(node);
        for (samples.first..samples.end) |sample| {
            var retention = try canopy.layerHarvestRetention(state.sample_layer_lower_height_m[sample], state.sample_layer_upper_height_m[sample], event.cutting_height_m_or_lai_fraction, pruning, event.kind == .none, event.thinning_fraction_or_consumption_rate, event.harvested_fraction.leaf);
            retention.unexported_fraction = group_misc.unexportedFraction(retention.remaining_fraction, event.ecosystem_export_fraction.leaf);
            const products = try canopy.harvestLeafLayerSample(state, branch, node_within_branch, sample - samples.first, retention, science.carbon_woody_fraction, science.leaf_nitrogen_woody_fraction, science.leaf_phosphorus_woody_fraction, node_within_branch == 1);
            group_misc.addProducts(&context.products_by_plant[plant].foliar, products.foliar);
            group_misc.addProducts(&context.products_by_plant[plant].woody, products.woody);
            if (layer_geometry) |geometry| {
                const sample_within_node = sample - samples.first;
                if (sample_within_node % geometry.angular_count == 0) {
                    const layer = sample_within_node / geometry.angular_count;
                    state_updateLayerHarvestGeometry(
                        geometry.layers,
                        plant,
                        branch,
                        node,
                        layer,
                        retention.remaining_fraction,
                        node_within_branch == 1,
                    );
                }
            }
        }
        var retention = try canopy.sourceOrderNodeOrganRetention(
            false,
            event.kind == .none,
            initial_leaf_c,
            state.node_leaf_carbon_g[node],
            event.harvested_fraction.leaf,
            event.harvested_fraction.nonfoliar,
            event.thinning_fraction_or_consumption_rate,
            context.plant_structural_presence_threshold_g_per_plant *
                state.plant_population_count[plant],
        );
        retention.unexported_fraction = group_misc.unexportedFraction(retention.remaining_fraction, event.ecosystem_export_fraction.nonfoliar);
        const sheath_products = try canopy.harvestNodeSheath(state, branch, node_within_branch, retention.remaining_fraction, retention.unexported_fraction, science.carbon_woody_fraction, science.sheath_nitrogen_woody_fraction, science.sheath_phosphorus_woody_fraction, @intFromEnum(event.kind) <= @intFromEnum(management.HarvestKind.above_ground), event.cutting_height_m_or_lai_fraction);
        group_misc.addProducts(&context.products_by_plant[plant].nonfoliar, sheath_products.nonwoody);
        group_misc.addProducts(&context.products_by_plant[plant].woody, sheath_products.woody);
        const internode_remaining = try canopy.internodeHarvestRetention(state.node_height_m[node], state.node_internode_length_m[node], event.cutting_height_m_or_lai_fraction, pruning, event.thinning_fraction_or_consumption_rate, event.harvested_fraction.woody, false, 0, state.branch_stalk_carbon_g[branch]);
        try canopy.state_updateInternodeHarvest(state, branch, node_within_branch, internode_remaining, @intFromEnum(event.kind) <= @intFromEnum(management.HarvestKind.above_ground) and event.thinning_fraction_or_consumption_rate == 0, event.cutting_height_m_or_lai_fraction);
    }
    var stalk_retention = try canopy.sourceOrderBranchStalkRetention(
        false,
        event.kind == .none,
        pruning,
        maximum_height_m,
        event.cutting_height_m_or_lai_fraction,
        event.thinning_fraction_or_consumption_rate,
        event.harvested_fraction.woody,
        state.branch_stalk_carbon_g[branch],
        0,
        0,
        context.plant_tissue_presence_threshold_g_per_plant *
            state.plant_population_count[plant],
    );
    // GROSUB applies the ecosystem-export/litter split (WTHTR3 =
    // WTHTH3*(1.0-EHVST(2,3))) to the removed stalk mass independently of
    // and after the cutting-height/thinning removal computed above
    // (grosub.f:10595-10597, :10633-10635, :10652-10654, :10671-10673). The
    // deterministic (non-grazing) path previously left `unexported_fraction`
    // equal to `remaining_fraction`, forcing 100% ecosystem export of every
    // removed stalk gram regardless of the deck's configured
    // `ecosystem_export_fraction.woody`. Mirror the leaf/sheath overrides above.
    stalk_retention.unexported_fraction = group_misc.unexportedFraction(stalk_retention.remaining_fraction, event.ecosystem_export_fraction.woody);
    const reserve_retention = try canopy.sourceOrderStalkReserveRetention(
        false,
        state.branch_stalk_carbon_g[branch] * stalk_retention.remaining_fraction,
        stalk_retention,
        state.branch_reserve_carbon_g[branch],
        0,
        context.plant_structural_presence_threshold_g_per_plant *
            state.plant_population_count[plant],
    );
    const stalk_products = try canopy.harvestBranchStalkAndReserve(state, branch, stalk_retention.remaining_fraction, stalk_retention.unexported_fraction, reserve_retention.remaining_fraction, reserve_retention.unexported_fraction);
    group_misc.addProducts(&context.products_by_plant[plant].woody, stalk_products);
    const mobile_remaining = try canopy.sourceOrderNonGrazingMobileRetention(
        initial_leaf_sheath_c,
        state.branch_leaf_carbon_g[branch] + state.branch_sheath_carbon_g[branch],
        context.plant_structural_presence_threshold_g_per_plant *
            state.plant_population_count[plant],
    );
    const initial_mobile_carbon_g_c = state.branch_mobile_carbon_g[branch];
    const is_c4 = if (context.canopy_biochemistry_parameters_by_plant) |parameters|
        parameters[plant].pathway == .c4
    else
        true;
    const intermediate_remaining = try canopy.sourceOrderC4IntermediateRetention(
        is_c4,
        initial_mobile_carbon_g_c,
        initial_mobile_carbon_g_c * mobile_remaining,
        context.plant_structural_presence_threshold_g_per_plant *
            state.plant_population_count[plant],
    );
    const mobile_removed = try canopy.harvestBranchMobilePoolsWithIntermediateRetention(
        state,
        branch,
        mobile_remaining,
        intermediate_remaining,
    );
    // grosub.f:10586/:10589 (and :10624/:10643/:10662 for the other harvest
    // codes) pair the nonstructural pool's export fraction with EHVST(2,1),
    // the same leaf-slot index used for WTHTR1 on the very next line -- not
    // EHVST(2,2) (nonfoliar), which only governs the fine/non-leaf pool
    // (WTHTR2).
    const export_fraction = event.ecosystem_export_fraction.leaf;
    group_misc.addScaledMass(&context.products_by_plant[plant].nonstructural.ecosystem_export, mobile_removed, export_fraction);
    group_misc.addScaledMass(&context.products_by_plant[plant].nonstructural.litter, mobile_removed, 1.0 - export_fraction);
}

/// Mirrors GROSUB ARLFL/WGLFL/ARSTK retention in the live radiation owner.
/// The photosynthesis sample owner is mutated by harvestLeafLayerSample; this
/// companion update prevents the branch/layer state used by the immediate
/// post-harvest ARSTP aggregation (and restart) from retaining pre-cut area.
fn state_updateLayerHarvestGeometry(
    layers: *canopy_layers.State,
    plant: usize,
    branch: usize,
    node: usize,
    layer: usize,
    remaining_fraction: f64,
    scale_stalk_area: bool,
) void {
    const cell = plant / layers.species_count;
    const node_layer = node * layers.layer_count + layer;
    const cell_layer = cell * layers.layer_count + layer;
    const initial_leaf_area_m2 = layers.node_leaf_area_m2[node_layer];
    const initial_leaf_carbon_g_c = layers.node_leaf_carbon_g[node_layer];
    layers.node_leaf_area_m2[node_layer] *= remaining_fraction;
    layers.node_leaf_carbon_g[node_layer] *= remaining_fraction;
    layers.node_leaf_nitrogen_g[node_layer] *= remaining_fraction;
    layers.node_leaf_phosphorus_g[node_layer] *= remaining_fraction;
    layers.cell_leaf_area_m2[cell_layer] = @max(
        0,
        layers.cell_leaf_area_m2[cell_layer] - (1 - remaining_fraction) * initial_leaf_area_m2,
    );
    layers.cell_leaf_carbon_g[cell_layer] = @max(
        0,
        layers.cell_leaf_carbon_g[cell_layer] - (1 - remaining_fraction) * initial_leaf_carbon_g_c,
    );
    for (0..layers.inclination_count) |inclination| {
        const node_surface = (node_layer * layers.inclination_count) + inclination;
        const plant_surface = ((plant * layers.layer_count + layer) * layers.inclination_count) + inclination;
        const removed_leaf_surface_m2 =
            (1 - remaining_fraction) * layers.node_leaf_projected_surface_m2[node_surface];
        layers.node_leaf_projected_surface_m2[node_surface] *= remaining_fraction;
        layers.plant_leaf_projected_surface_m2[plant_surface] = @max(
            0,
            layers.plant_leaf_projected_surface_m2[plant_surface] - removed_leaf_surface_m2,
        );
    }
    if (!scale_stalk_area) return;
    const branch_layer = branch * layers.layer_count + layer;
    const removed_stalk_area_m2 =
        (1 - remaining_fraction) * layers.branch_stalk_area_m2[branch_layer];
    layers.branch_stalk_area_m2[branch_layer] *= remaining_fraction;
    layers.cell_stalk_area_m2[cell_layer] = @max(
        0,
        layers.cell_stalk_area_m2[cell_layer] - removed_stalk_area_m2,
    );
    for (0..layers.inclination_count) |inclination| {
        const branch_surface = (branch_layer * layers.inclination_count) + inclination;
        const plant_surface = ((plant * layers.layer_count + layer) * layers.inclination_count) + inclination;
        const removed_stalk_surface_m2 =
            (1 - remaining_fraction) * layers.branch_stalk_projected_surface_m2[branch_surface];
        layers.branch_stalk_projected_surface_m2[branch_surface] *= remaining_fraction;
        layers.plant_stalk_projected_surface_m2[plant_surface] = @max(
            0,
            layers.plant_stalk_projected_surface_m2[plant_surface] - removed_stalk_surface_m2,
        );
    }
}
