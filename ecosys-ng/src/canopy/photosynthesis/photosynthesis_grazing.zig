//! `photosynthesis` declarations: grazing.
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

/// Exact GROSUB 9194-9217 non-grazing branch mobile retention ratio.
pub fn sourceOrderNonGrazingMobileRetention(
    previous_leaf_sheath_carbon_g_c: f64,
    remaining_leaf_sheath_carbon_g_c: f64,
    plant_presence_threshold_g_c: f64,
) !f64 {
    inline for (.{
        previous_leaf_sheath_carbon_g_c,
        remaining_leaf_sheath_carbon_g_c,
        plant_presence_threshold_g_c,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidHarvestMass;
    if (remaining_leaf_sheath_carbon_g_c > previous_leaf_sheath_carbon_g_c)
        return error.InvalidHarvestMass;
    if (previous_leaf_sheath_carbon_g_c <= plant_presence_threshold_g_c) return 0;
    return @max(0, @min(1, remaining_leaf_sheath_carbon_g_c / previous_leaf_sheath_carbon_g_c));
}

pub const GrazingPools = struct {
    leaf_carbon_g: f64,
    sheath_carbon_g: f64,
    husk_carbon_g: f64,
    ear_carbon_g: f64,
    grain_carbon_g: f64,
    stalk_carbon_g: f64,
    reserve_carbon_g: f64,
};

pub const GrazingAllocation = struct {
    structural_leaf_carbon_g: f64 = 0,
    structural_sheath_carbon_g: f64 = 0,
    husk_carbon_g: f64 = 0,
    ear_carbon_g: f64 = 0,
    grain_carbon_g: f64 = 0,
    stalk_carbon_g: f64 = 0,
    reserve_carbon_g: f64 = 0,
    mobile_carbon_g: f64 = 0,
    symbiont_mobile_carbon_g: f64 = 0,
    unmet_carbon_g: f64 = 0,
};

pub const SourceOrderAdditionalGrazingRemoval = struct {
    next_total_removed_carbon_g_c: f64,
    next_unmet_carbon_g_c: f64,
};

/// Exact GROSUB 8758-8783 redistribution operand for one nonfoliar organ.
/// Source caps the additional removal by the original pool, not its remainder.
pub fn sourceOrderAdditionalGrazingRemoval(
    organ_pool_carbon_g_c: f64,
    already_removed_carbon_g_c: f64,
    requested_additional_carbon_g_c: f64,
) !SourceOrderAdditionalGrazingRemoval {
    inline for (.{ organ_pool_carbon_g_c, already_removed_carbon_g_c, requested_additional_carbon_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidGrazingPool;
    const additional_removed_g_c = @min(organ_pool_carbon_g_c, requested_additional_carbon_g_c);
    return .{
        .next_total_removed_carbon_g_c = already_removed_carbon_g_c + additional_removed_g_c,
        .next_unmet_carbon_g_c = @max(0, requested_additional_carbon_g_c - additional_removed_g_c),
    };
}

pub fn allocateGrazingDemand(total_demand_g_c: f64, harvested_leaf_fraction: f64, harvested_nonfoliar_fraction: f64, harvested_woody_fraction: f64, canopy_mobile_carbon_concentration_g_per_g: f64, symbiont_mobile_carbon_concentration_g_per_g: f64, pools: GrazingPools) !GrazingAllocation {
    inline for (@typeInfo(GrazingPools).@"struct".fields) |field| if (!std.math.isFinite(@field(pools, field.name)) or @field(pools, field.name) < 0) return error.InvalidGrazingPool;
    inline for (.{ total_demand_g_c, harvested_leaf_fraction, harvested_nonfoliar_fraction, harvested_woody_fraction, canopy_mobile_carbon_concentration_g_per_g, symbiont_mobile_carbon_concentration_g_per_g }) |value| if (!std.math.isFinite(value)) return error.NonFiniteGrazingAllocationInput;
    if (total_demand_g_c < 0 or harvested_leaf_fraction < 0 or harvested_leaf_fraction > 1 or harvested_nonfoliar_fraction < 0 or harvested_nonfoliar_fraction > 1 or harvested_woody_fraction < 0 or harvested_woody_fraction > 1 or canopy_mobile_carbon_concentration_g_per_g < 0 or symbiont_mobile_carbon_concentration_g_per_g < 0) return error.InvalidGrazingAllocationInput;
    const mobile_fraction = canopy_mobile_carbon_concentration_g_per_g / (1.0 + canopy_mobile_carbon_concentration_g_per_g);
    const symbiont_fraction = symbiont_mobile_carbon_concentration_g_per_g / (1.0 + symbiont_mobile_carbon_concentration_g_per_g);
    var result: GrazingAllocation = .{};
    const requested_leaf = total_demand_g_c * harvested_leaf_fraction;
    const removed_leaf = @min(pools.leaf_carbon_g, requested_leaf);
    result.structural_leaf_carbon_g = removed_leaf * (1.0 - mobile_fraction);
    result.mobile_carbon_g = removed_leaf * mobile_fraction;
    result.symbiont_mobile_carbon_g = removed_leaf * symbiont_fraction;
    var unmet = @max(0.0, requested_leaf - removed_leaf);
    var removed_sheath_total: f64 = 0;

    const nonfoliar_total = pools.sheath_carbon_g + pools.husk_carbon_g + pools.ear_carbon_g + pools.grain_carbon_g;
    const requested_nonfoliar = total_demand_g_c * harvested_nonfoliar_fraction;
    if (nonfoliar_total > 0) {
        var request = requested_nonfoliar * pools.sheath_carbon_g / nonfoliar_total + unmet;
        const removed = @min(pools.sheath_carbon_g, request);
        removed_sheath_total = removed;
        result.structural_sheath_carbon_g = removed * (1.0 - mobile_fraction);
        result.mobile_carbon_g += removed * mobile_fraction;
        result.symbiont_mobile_carbon_g += removed * symbiont_fraction;
        unmet = @max(0.0, request - removed);
        request = requested_nonfoliar * pools.husk_carbon_g / nonfoliar_total + unmet;
        result.husk_carbon_g = @min(pools.husk_carbon_g, request);
        unmet = @max(0.0, request - result.husk_carbon_g);
        request = requested_nonfoliar * pools.ear_carbon_g / nonfoliar_total + unmet;
        result.ear_carbon_g = @min(pools.ear_carbon_g, request);
        unmet = @max(0.0, request - result.ear_carbon_g);
        request = requested_nonfoliar * pools.grain_carbon_g / nonfoliar_total + unmet;
        result.grain_carbon_g = @min(pools.grain_carbon_g, request);
        unmet = @max(0.0, request - result.grain_carbon_g);
    } else {
        unmet += requested_nonfoliar;
    }

    const woody_total = pools.stalk_carbon_g + pools.reserve_carbon_g;
    const requested_woody = total_demand_g_c * harvested_woody_fraction;
    if (woody_total > requested_woody + unmet) {
        var request = requested_woody * pools.stalk_carbon_g / woody_total + unmet;
        result.stalk_carbon_g = @min(pools.stalk_carbon_g, request);
        unmet = @max(0.0, request - result.stalk_carbon_g);
        request = requested_woody * pools.reserve_carbon_g / woody_total + unmet;
        result.reserve_carbon_g = @min(pools.reserve_carbon_g, request);
        unmet = @max(0.0, request - result.reserve_carbon_g);
    } else {
        result.stalk_carbon_g = 0;
        result.reserve_carbon_g = 0;
        unmet = 0;
    }

    if (unmet > 0) {
        var removed = @min(@max(0.0, pools.leaf_carbon_g - removed_leaf), unmet);
        result.structural_leaf_carbon_g += removed * (1.0 - mobile_fraction);
        result.mobile_carbon_g += removed * mobile_fraction;
        result.symbiont_mobile_carbon_g += removed * symbiont_fraction;
        unmet = @max(0.0, unmet - removed);
        if (nonfoliar_total > 0) {
            var request = unmet * pools.sheath_carbon_g / nonfoliar_total;
            removed = @min(@max(0.0, pools.sheath_carbon_g - removed_sheath_total), request);
            removed_sheath_total += removed;
            result.structural_sheath_carbon_g += removed * (1.0 - mobile_fraction);
            result.mobile_carbon_g += removed * mobile_fraction;
            result.symbiont_mobile_carbon_g += removed * symbiont_fraction;
            unmet = @max(0.0, unmet - removed);
            request = unmet * pools.husk_carbon_g / nonfoliar_total;
            removed = @min(@max(0.0, pools.husk_carbon_g - result.husk_carbon_g), request);
            result.husk_carbon_g += removed;
            unmet = @max(0.0, unmet - removed);
            request = unmet * pools.ear_carbon_g / nonfoliar_total;
            removed = @min(@max(0.0, pools.ear_carbon_g - result.ear_carbon_g), request);
            result.ear_carbon_g += removed;
            unmet = @max(0.0, request - removed);
            request = unmet * pools.grain_carbon_g / nonfoliar_total;
            removed = @min(@max(0.0, pools.grain_carbon_g - result.grain_carbon_g), request);
            result.grain_carbon_g += removed;
            unmet = @max(0.0, request - removed);
        }
    }
    result.unmet_carbon_g = unmet;
    return result;
}

pub fn grazingCarbonDemandGPerH(animal_grazing: bool, grazer_biomass_g_living_mass_per_m2: f64, specific_consumption_g_dry_matter_per_g_living_mass_d: f64, horizontal_cell_area_m2: f64, leaf_plus_stalk_area_m2: f64, canopy_growth_temperature_factor: f64, cell_shoot_carbon_g: f64, landscape_average_shoot_carbon_g: f64) !f64 {
    inline for (.{ grazer_biomass_g_living_mass_per_m2, specific_consumption_g_dry_matter_per_g_living_mass_d, horizontal_cell_area_m2, leaf_plus_stalk_area_m2, canopy_growth_temperature_factor, cell_shoot_carbon_g, landscape_average_shoot_carbon_g }) |value| if (!std.math.isFinite(value)) return error.NonFiniteGrazingDemandInput;
    if (grazer_biomass_g_living_mass_per_m2 < 0 or specific_consumption_g_dry_matter_per_g_living_mass_d < 0 or horizontal_cell_area_m2 <= 0 or leaf_plus_stalk_area_m2 < 0 or canopy_growth_temperature_factor < 0 or cell_shoot_carbon_g < 0 or landscape_average_shoot_carbon_g < 0) return error.InvalidGrazingDemandInput;
    if (landscape_average_shoot_carbon_g == 0) return 0;
    const spatial_share = cell_shoot_carbon_g / landscape_average_shoot_carbon_g;
    return if (animal_grazing)
        grazer_biomass_g_living_mass_per_m2 * specific_consumption_g_dry_matter_per_g_living_mass_d * horizontal_cell_area_m2 * 0.5 / 24.0 * spatial_share
    else
        grazer_biomass_g_living_mass_per_m2 * specific_consumption_g_dry_matter_per_g_living_mass_d * leaf_plus_stalk_area_m2 * 0.5 / 24.0 * canopy_growth_temperature_factor * spatial_share;
}

/// Exact GROSUB 8650-8662 demand gate using plant ZEROP.
pub fn sourceOrderGrazingCarbonDemandGPerH(
    animal_grazing: bool,
    grazer_biomass_g_living_mass_per_m2: f64,
    specific_consumption_g_dry_matter_per_g_living_mass_d: f64,
    horizontal_cell_area_m2: f64,
    leaf_plus_stalk_area_m2: f64,
    canopy_growth_temperature_factor: f64,
    cell_shoot_carbon_g: f64,
    landscape_average_shoot_carbon_g: f64,
    plant_presence_threshold_g_c: f64,
) !f64 {
    if (!std.math.isFinite(plant_presence_threshold_g_c) or plant_presence_threshold_g_c < 0)
        return error.InvalidGrazingDemandInput;
    if (landscape_average_shoot_carbon_g <= plant_presence_threshold_g_c) return 0;
    return grazingCarbonDemandGPerH(
        animal_grazing,
        grazer_biomass_g_living_mass_per_m2,
        specific_consumption_g_dry_matter_per_g_living_mass_d,
        horizontal_cell_area_m2,
        leaf_plus_stalk_area_m2,
        canopy_growth_temperature_factor,
        cell_shoot_carbon_g,
        landscape_average_shoot_carbon_g,
    );
}
