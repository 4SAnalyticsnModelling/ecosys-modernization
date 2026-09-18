//! `plant_harvest_source_order` declarations: disturbance.
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
const group_harvest = @import("plant_harvest_source_order_harvest.zig");

const HourlyDisturbanceReset = __parent.HourlyDisturbanceReset;
const PopulationAfterDisturbance = __parent.PopulationAfterDisturbance;
const PopulationScaledNumericalThresholds = __parent.PopulationScaledNumericalThresholds;

/// Exact GROSUB 8516-8524 first-substep disturbance reset.
pub fn sourceOrderHourlyDisturbanceReset(
    first_biological_substep: bool,
    cumulative_harvest_carbon_g_c: f64,
    current: HourlyDisturbanceReset,
) !HourlyDisturbanceReset {
    if (!std.math.isFinite(cumulative_harvest_carbon_g_c) or cumulative_harvest_carbon_g_c < 0)
        return error.InvalidHourlyDisturbanceResetInput;
    inline for (@typeInfo(HourlyDisturbanceReset).@"struct".fields) |field| {
        const value = @field(current, field.name);
        if (field.type == f64) {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidHourlyDisturbanceResetInput;
        } else for (value) |item| {
            if (!std.math.isFinite(item) or item < 0) return error.InvalidHourlyDisturbanceResetInput;
        }
    }
    if (!first_biological_substep) return current;
    return .{
        .previous_cumulative_harvest_carbon_g_c = cumulative_harvest_carbon_g_c,
        .manure_organic_carbon_g_c = @splat(0),
        .manure_organic_nitrogen_g_n = @splat(0),
        .manure_organic_phosphorus_g_p = @splat(0),
        .manure_inorganic_nitrogen_g_n = 0,
        .manure_inorganic_phosphorus_g_p = 0,
    };
}

/// Exact GROSUB 8528-8531 calendar, trait, and management selector.
pub fn sourceOrderForestSelfThinningIsEnabled(
    day_of_year: u16,
    hour_of_day: u8,
    local_solar_noon_h: f64,
    biomass_turnover_type: u8,
    root_profile_type: u8,
    harvest_code: i8,
) !bool {
    if (day_of_year == 0 or day_of_year > 366 or hour_of_day > 23 or
        !std.math.isFinite(local_solar_noon_h) or local_solar_noon_h < 0 or local_solar_noon_h >= 24)
        return error.InvalidForestSelfThinningSelector;
    return day_of_year % 30 == 0 and
        hour_of_day == @as(u8, @intFromFloat(@floor(local_solar_noon_h))) and
        biomass_turnover_type != 0 and
        root_profile_type > 1 and
        (harvest_code < 0 or harvest_code == 4 or harvest_code == 6);
}

pub const SourceOrderDisturbanceRemovalInput = struct {
    harvest_code: i8,
    terminate_and_reseed: bool,
    grazer_growth_yield: f64,
    grazer_respiration_fraction: f64,
    harvested_by_component: [group_harvest.harvest_product_component_count]canopy.ElementalMass,
    residue_by_component: [group_harvest.harvest_product_component_count]canopy.ElementalMass,
    direct_litter_by_component: [group_harvest.harvest_product_component_count]canopy.ElementalMass,
};

pub const SourceOrderDisturbanceRemovalResult = struct {
    harvested_total: canopy.ElementalMass,
    residue_total: canopy.ElementalMass,
    direct_litter_total: canopy.ElementalMass,
    plant_ecosystem_removal: canopy.ElementalMass,
    grid_ecosystem_removal: canopy.ElementalMass,
    reseed_storage_addition: canopy.ElementalMass,
    net_biome_production_carbon_change_g_c_per_h: f64,
    plant_total_respiration_change_g_c_per_h: f64,
    plant_actual_respiration_change_g_c_per_h: f64,
    ecosystem_respiration_change_g_c_per_h: f64,
    autotrophic_respiration_change_g_c_per_h: f64,
};

/// Exact GROSUB 10699-10750 five-component disturbance totals and accounting.
pub fn sourceOrderTotalDisturbanceRemoval(
    input: SourceOrderDisturbanceRemovalInput,
) !SourceOrderDisturbanceRemovalResult {
    if (input.harvest_code < 0 or input.harvest_code > 6 or input.harvest_code == 5 or
        !std.math.isFinite(input.grazer_growth_yield) or input.grazer_growth_yield < 0 or
        !std.math.isFinite(input.grazer_respiration_fraction) or input.grazer_respiration_fraction < 0)
        return error.InvalidDisturbanceRemovalInput;
    const harvested = try group_harvest.sumHarvestProductComponents(input.harvested_by_component);
    const residue = try group_harvest.sumHarvestProductComponents(input.residue_by_component);
    const direct_litter = try group_harvest.sumHarvestProductComponents(input.direct_litter_by_component);
    const exported: canopy.ElementalMass = .{
        .carbon_g = harvested.carbon_g - residue.carbon_g,
        .nitrogen_g = harvested.nitrogen_g - residue.nitrogen_g,
        .phosphorus_g = harvested.phosphorus_g - residue.phosphorus_g,
    };
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        const value = @field(exported, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.DisturbanceRemovalResidueOverdraw;
    }
    var result: SourceOrderDisturbanceRemovalResult = .{
        .harvested_total = harvested,
        .residue_total = residue,
        .direct_litter_total = direct_litter,
        .plant_ecosystem_removal = .{},
        .grid_ecosystem_removal = .{},
        .reseed_storage_addition = .{},
        .net_biome_production_carbon_change_g_c_per_h = 0,
        .plant_total_respiration_change_g_c_per_h = 0,
        .plant_actual_respiration_change_g_c_per_h = 0,
        .ecosystem_respiration_change_g_c_per_h = 0,
        .autotrophic_respiration_change_g_c_per_h = 0,
    };
    const grazing = input.harvest_code == 4 or input.harvest_code == 6;
    if (!grazing) {
        if (input.terminate_and_reseed) {
            result.reseed_storage_addition = exported;
        } else {
            result.plant_ecosystem_removal = exported;
            result.grid_ecosystem_removal = exported;
            result.net_biome_production_carbon_change_g_c_per_h = -exported.carbon_g;
        }
        return result;
    }

    result.plant_ecosystem_removal = .{
        .carbon_g = input.grazer_growth_yield * exported.carbon_g,
        .nitrogen_g = exported.nitrogen_g,
        .phosphorus_g = exported.phosphorus_g,
    };
    result.grid_ecosystem_removal = result.plant_ecosystem_removal;
    const respired_carbon_g_c = input.grazer_respiration_fraction * exported.carbon_g;
    result.plant_total_respiration_change_g_c_per_h = -respired_carbon_g_c;
    result.plant_actual_respiration_change_g_c_per_h = -respired_carbon_g_c;
    result.ecosystem_respiration_change_g_c_per_h = -respired_carbon_g_c;
    result.autotrophic_respiration_change_g_c_per_h = -respired_carbon_g_c;
    return result;
}

/// Exact GROSUB 10914-10916 refresh after disturbance changes plant population.
pub fn sourceOrderPopulationScaledNumericalThresholds(
    plant_population_count: f64,
    horizontal_cell_area_m2: f64,
    mass_threshold_g_per_plant: f64,
    flux_threshold_g_per_plant_per_step: f64,
) !PopulationScaledNumericalThresholds {
    inline for (.{
        plant_population_count,
        horizontal_cell_area_m2,
        mass_threshold_g_per_plant,
        flux_threshold_g_per_plant_per_step,
    }) |value| {
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPopulationScaledNumericalThresholdInput;
    }
    if (horizontal_cell_area_m2 == 0)
        return error.InvalidPopulationScaledNumericalThresholdInput;

    // Preserve the source evaluation order: multiply by population first,
    // then divide the mass threshold by horizontal area.
    const plant_mass_presence_g = mass_threshold_g_per_plant * plant_population_count;
    const result: PopulationScaledNumericalThresholds = .{
        .plant_mass_presence_g = plant_mass_presence_g,
        .plant_mass_density_g_m2 = plant_mass_presence_g / horizontal_cell_area_m2,
        .plant_flux_presence_g_per_step = flux_threshold_g_per_plant_per_step * plant_population_count,
    };
    inline for (@typeInfo(PopulationScaledNumericalThresholds).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFinitePopulationScaledNumericalThreshold;
    }
    return result;
}

/// Exact GROSUB 8566-8568 disturbance timing selector.
pub fn sourceOrderAbovegroundDisturbanceIsEnabled(
    harvest_code: i8,
    hour_of_day: u8,
    local_solar_noon_h: f64,
) !bool {
    if (hour_of_day > 23 or !std.math.isFinite(local_solar_noon_h) or local_solar_noon_h < 0 or local_solar_noon_h >= 24)
        return error.InvalidAbovegroundDisturbanceSelector;
    const grazing = harvest_code == 4 or harvest_code == 6;
    return grazing or (harvest_code >= 0 and hour_of_day == @as(u8, @intFromFloat(@floor(local_solar_noon_h))));
}

/// Exact GROSUB 8587-8596 population update for non-grazing disturbance.
pub fn sourceOrderPopulationAfterDisturbance(
    terminate_and_reseed: bool,
    thinning_fraction: f64,
    current: PopulationAfterDisturbance,
    reseed_population_per_m2: f64,
    cell_area_m2: f64,
) !PopulationAfterDisturbance {
    inline for (.{
        thinning_fraction,
        current.living_population_per_m2,
        current.living_population_count,
        current.standing_dead_population_count,
        reseed_population_per_m2,
        cell_area_m2,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidDisturbancePopulationInput;
    if (thinning_fraction > 1 or cell_area_m2 <= 0) return error.InvalidDisturbancePopulationInput;
    if (terminate_and_reseed) {
        const population_count = reseed_population_per_m2 * cell_area_m2;
        if (!std.math.isFinite(population_count)) return error.NonFiniteDisturbancePopulation;
        return .{
            .living_population_per_m2 = reseed_population_per_m2,
            .living_population_count = population_count,
            .standing_dead_population_count = population_count,
        };
    }
    const retention = 1 - thinning_fraction;
    return .{
        .living_population_per_m2 = current.living_population_per_m2 * retention,
        .living_population_count = current.living_population_count * retention,
        .standing_dead_population_count = current.standing_dead_population_count * retention,
    };
}
