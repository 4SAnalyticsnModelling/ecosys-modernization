//! `plant_harvest_source_order` declarations: harvest.
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
const group_misc = @import("plant_harvest_source_order_misc.zig");
const group_tillage = @import("plant_harvest_source_order_tillage.zig");

pub const harvest_product_component_count = __parent.harvest_product_component_count;
pub const sumHarvestProductComponents = __parent.sumHarvestProductComponents;

pub const SourceOrderStandingDeadHarvestInput = struct {
    harvest_code: i8,
    hour_of_day: u8,
    local_solar_noon_h: f64,
    thinning_fraction_or_specific_consumption_rate: f64,
    standing_dead_removal_fraction: f64,
    grazer_live_mass_g_per_m2: f64,
    animal_accessible_area_m2: f64,
    insect_accessible_area_m2: f64,
    standing_dead_presence_threshold_g_c: f64,
    standing_dead_by_component: [group_misc.source_order_standing_dead_component_count]canopy.ElementalMass,
};

pub const SourceOrderStandingDeadHarvestResult = struct {
    retained_fraction: f64,
    harvested_fraction: f64,
    harvested: canopy.ElementalMass,
    returned_to_litter: canopy.ElementalMass,
    remaining_by_component: [group_misc.source_order_standing_dead_component_count]canopy.ElementalMass,
};

/// Exact GROSUB 10508-10551 standing-dead harvest selection and transaction.
pub fn sourceOrderStandingDeadHarvest(
    input: SourceOrderStandingDeadHarvestInput,
) !SourceOrderStandingDeadHarvestResult {
    if (input.hour_of_day > 23 or
        !std.math.isFinite(input.local_solar_noon_h) or
        input.local_solar_noon_h < 0 or input.local_solar_noon_h >= 24)
        return error.InvalidStandingDeadHarvestInput;
    inline for (.{
        input.thinning_fraction_or_specific_consumption_rate,
        input.standing_dead_removal_fraction,
        input.grazer_live_mass_g_per_m2,
        input.animal_accessible_area_m2,
        input.insect_accessible_area_m2,
        input.standing_dead_presence_threshold_g_c,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidStandingDeadHarvestInput;
    if (input.standing_dead_removal_fraction > 1) return error.InvalidStandingDeadHarvestInput;
    var total_standing_dead_carbon_g_c: f64 = 0;
    for (input.standing_dead_by_component) |mass| {
        inline for (.{ mass.carbon_g, mass.nitrogen_g, mass.phosphorus_g }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidStandingDeadHarvestInput;
        total_standing_dead_carbon_g_c += mass.carbon_g;
    }

    var retained_fraction: f64 = 1;
    var harvested_fraction: f64 = 1;
    const at_solar_noon = input.hour_of_day ==
        @as(u8, @intFromFloat(@floor(input.local_solar_noon_h)));
    const grazing = input.harvest_code == 4 or input.harvest_code == 6;
    if (input.harvest_code >= 0 and at_solar_noon and !grazing) {
        if (input.thinning_fraction_or_specific_consumption_rate == 0) {
            retained_fraction = @max(0, 1 - input.standing_dead_removal_fraction);
            harvested_fraction = retained_fraction;
        } else {
            retained_fraction = @max(0, 1 - input.thinning_fraction_or_specific_consumption_rate);
            harvested_fraction = if (input.harvest_code == 0)
                @max(0, 1 - input.standing_dead_removal_fraction *
                    input.thinning_fraction_or_specific_consumption_rate)
            else
                retained_fraction;
        }
    } else if (grazing and total_standing_dead_carbon_g_c > input.standing_dead_presence_threshold_g_c) {
        const accessible_area_m2 = if (input.harvest_code == 4)
            input.animal_accessible_area_m2
        else
            input.insect_accessible_area_m2;
        const demand_g_c_per_h = input.grazer_live_mass_g_per_m2 *
            input.thinning_fraction_or_specific_consumption_rate * 0.5 / 24 *
            accessible_area_m2 * input.standing_dead_removal_fraction;
        retained_fraction = @max(0, 1 - demand_g_c_per_h / total_standing_dead_carbon_g_c);
        harvested_fraction = retained_fraction;
    }

    var result: SourceOrderStandingDeadHarvestResult = .{
        .retained_fraction = retained_fraction,
        .harvested_fraction = harvested_fraction,
        .harvested = .{},
        .returned_to_litter = .{},
        .remaining_by_component = input.standing_dead_by_component,
    };
    for (&result.remaining_by_component) |*mass| {
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
            const initial = @field(mass, field.name);
            @field(result.harvested, field.name) += (1 - harvested_fraction) * initial;
            @field(result.returned_to_litter, field.name) +=
                (harvested_fraction - retained_fraction) * initial;
            @field(mass, field.name) = retained_fraction * initial;
        }
    }
    return result;
}

pub const SourceOrderHarvestResidueInput = struct {
    harvest_code: i8,
    harvested_by_component: [harvest_product_component_count]canopy.ElementalMass,
    harvested_grain: canopy.ElementalMass,
    ecosystem_export_fraction: [4]f64,
};

/// Exact GROSUB 10585-10677 routing of five harvested-product components to
/// residue before ecosystem export totals are assembled.
pub fn sourceOrderHarvestResidueRouting(
    input: SourceOrderHarvestResidueInput,
) ![harvest_product_component_count]canopy.ElementalMass {
    if (input.harvest_code < 0 or input.harvest_code > 6 or input.harvest_code == 5)
        return error.InvalidHarvestResidueCode;
    for (input.ecosystem_export_fraction) |fraction|
        if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
            return error.InvalidHarvestResidueInput;
    inline for (.{
        input.harvested_grain.carbon_g,
        input.harvested_grain.nitrogen_g,
        input.harvested_grain.phosphorus_g,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidHarvestResidueInput;
    for (input.harvested_by_component) |mass| {
        inline for (.{ mass.carbon_g, mass.nitrogen_g, mass.phosphorus_g }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidHarvestResidueInput;
    }

    var residue = input.harvested_by_component;
    if (input.harvest_code == 1) {
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
            @field(residue[2], field.name) -=
                @field(input.harvested_grain, field.name) * input.ecosystem_export_fraction[1];
            if (!std.math.isFinite(@field(residue[2], field.name)) or
                @field(residue[2], field.name) < 0)
                return error.HarvestResidueOverdraw;
        }
        return residue;
    }

    const fraction_by_component = [harvest_product_component_count]f64{
        input.ecosystem_export_fraction[0],
        input.ecosystem_export_fraction[0],
        input.ecosystem_export_fraction[1],
        input.ecosystem_export_fraction[2],
        input.ecosystem_export_fraction[3],
    };
    for (&residue, fraction_by_component) |*mass, export_fraction| {
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
            @field(mass, field.name) *= 1 - export_fraction;
    }
    return residue;
}

pub const SourceOrderAbovegroundHarvestLitterInput = struct {
    harvest_code: i8,
    biomass_turnover_type: u8,
    root_profile_type: u8,
    residue_by_component: [harvest_product_component_count]canopy.ElementalMass,
    direct_litter_by_component: [harvest_product_component_count]canopy.ElementalMass,
    woody_composition: group_tillage.TillageElementComposition,
    nonstructural_kinetics: litter_partition.ElementFractions,
    foliar_kinetics: litter_partition.ElementFractions,
    nonfoliar_kinetics: litter_partition.ElementFractions,
    stalk_kinetics: litter_partition.ElementFractions,
    coarse_wood_kinetics: litter_partition.ElementFractions,
};

pub const SourceOrderAbovegroundHarvestLitterResult = struct {
    litter: canopy.SenescenceProducts,
    standing_dead_addition: canopy.SenescenceProducts,
};

/// Exact GROSUB 10796-10837 non-grazing above-ground harvest litterfall.
pub fn sourceOrderAbovegroundHarvestLitter(
    input: SourceOrderAbovegroundHarvestLitterInput,
) !SourceOrderAbovegroundHarvestLitterResult {
    if (input.harvest_code < 0 or input.harvest_code > 6 or
        input.harvest_code == 4 or input.harvest_code == 5 or input.harvest_code == 6)
        return error.InvalidAbovegroundHarvestLitterCode;
    _ = try sumHarvestProductComponents(input.residue_by_component);
    _ = try sumHarvestProductComponents(input.direct_litter_by_component);
    try group_tillage.validateTillageComposition(input.woody_composition);
    inline for (.{
        input.nonstructural_kinetics,
        input.foliar_kinetics,
        input.nonfoliar_kinetics,
        input.stalk_kinetics,
        input.coarse_wood_kinetics,
    }) |kinetics| kinetics.validate() catch return error.InvalidAbovegroundHarvestLitterInput;

    var result: SourceOrderAbovegroundHarvestLitterResult = .{
        .litter = .{},
        .standing_dead_addition = .{},
    };
    const residue = input.residue_by_component;
    const direct = input.direct_litter_by_component;
    const herbaceous = input.biomass_turnover_type == 0 or input.root_profile_type <= 1;
    for (0..litter_partition.kinetic_component_count) |kinetic| {
        result.litter.nonwoody_carbon_g[kinetic] =
            input.nonstructural_kinetics.carbon[kinetic] * (residue[0].carbon_g + direct[0].carbon_g) +
            input.foliar_kinetics.carbon[kinetic] * (residue[1].carbon_g + direct[1].carbon_g) +
            input.nonfoliar_kinetics.carbon[kinetic] * (residue[2].carbon_g + direct[2].carbon_g);
        result.litter.nonwoody_nitrogen_g[kinetic] =
            input.nonstructural_kinetics.nitrogen[kinetic] * (residue[0].nitrogen_g + direct[0].nitrogen_g) +
            input.foliar_kinetics.nitrogen[kinetic] * (residue[1].nitrogen_g + direct[1].nitrogen_g) +
            input.nonfoliar_kinetics.nitrogen[kinetic] * (residue[2].nitrogen_g + direct[2].nitrogen_g);
        result.litter.nonwoody_phosphorus_g[kinetic] =
            input.nonstructural_kinetics.phosphorus[kinetic] * (residue[0].phosphorus_g + direct[0].phosphorus_g) +
            input.foliar_kinetics.phosphorus[kinetic] * (residue[1].phosphorus_g + direct[1].phosphorus_g) +
            input.nonfoliar_kinetics.phosphorus[kinetic] * (residue[2].phosphorus_g + direct[2].phosphorus_g);
        if (herbaceous) {
            result.litter.nonwoody_carbon_g[kinetic] += input.stalk_kinetics.carbon[kinetic] *
                (residue[3].carbon_g + direct[3].carbon_g + residue[4].carbon_g + direct[4].carbon_g);
            result.litter.nonwoody_nitrogen_g[kinetic] += input.stalk_kinetics.nitrogen[kinetic] *
                (residue[3].nitrogen_g + direct[3].nitrogen_g + residue[4].nitrogen_g + direct[4].nitrogen_g);
            result.litter.nonwoody_phosphorus_g[kinetic] += input.stalk_kinetics.phosphorus[kinetic] *
                (residue[3].phosphorus_g + direct[3].phosphorus_g + residue[4].phosphorus_g + direct[4].phosphorus_g);
        } else {
            result.standing_dead_addition.woody_carbon_g[kinetic] =
                input.coarse_wood_kinetics.carbon[kinetic] * (direct[3].carbon_g + direct[4].carbon_g);
            result.standing_dead_addition.woody_nitrogen_g[kinetic] =
                input.coarse_wood_kinetics.nitrogen[kinetic] * (direct[3].nitrogen_g + direct[4].nitrogen_g);
            result.standing_dead_addition.woody_phosphorus_g[kinetic] =
                input.coarse_wood_kinetics.phosphorus[kinetic] * (direct[3].phosphorus_g + direct[4].phosphorus_g);
            result.litter.woody_carbon_g[kinetic] = input.coarse_wood_kinetics.carbon[kinetic] *
                (residue[3].carbon_g + residue[4].carbon_g) * input.woody_composition.carbon[0];
            result.litter.woody_nitrogen_g[kinetic] = input.coarse_wood_kinetics.nitrogen[kinetic] *
                (residue[3].nitrogen_g + residue[4].nitrogen_g) * input.woody_composition.nitrogen[0];
            result.litter.woody_phosphorus_g[kinetic] = input.coarse_wood_kinetics.phosphorus[kinetic] *
                (residue[3].phosphorus_g + residue[4].phosphorus_g) * input.woody_composition.phosphorus[0];
            result.litter.nonwoody_carbon_g[kinetic] += input.nonfoliar_kinetics.carbon[kinetic] *
                (residue[3].carbon_g + residue[4].carbon_g) * input.woody_composition.carbon[1];
            result.litter.nonwoody_nitrogen_g[kinetic] += input.nonfoliar_kinetics.nitrogen[kinetic] *
                (residue[3].nitrogen_g + residue[4].nitrogen_g) * input.woody_composition.nitrogen[1];
            result.litter.nonwoody_phosphorus_g[kinetic] += input.nonfoliar_kinetics.phosphorus[kinetic] *
                (residue[3].phosphorus_g + residue[4].phosphorus_g) * input.woody_composition.phosphorus[1];
        }
    }
    return result;
}

pub const SourceOrderStandingDeadGeometryInput = struct {
    components: []const canopy.ElementalMass,
    negligible_mass_g_c: f64,
    standing_dead_population_count: f64,
    previous_height_m: f64,
    canopy_height_m: f64,
    stalk_volume_per_carbon_m3_g_c: f64,
    canopy_layer_edges_m: []const f64,
};

pub const SourceOrderStandingDeadGeometryResult = struct {
    total_mass: canopy.ElementalMass,
    height_m: f64,
    total_surface_area_m2: f64,
    layer_surface_area_m2: []f64,
    projected_surface_area_m2: []f64,

    pub fn deinit(self: SourceOrderStandingDeadGeometryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.layer_surface_area_m2);
        allocator.free(self.projected_surface_area_m2);
    }
};

/// Exact GROSUB 11687-11728 standing-dead totals and layer geometry.
pub fn sourceOrderStandingDeadGeometry(
    allocator: std.mem.Allocator,
    input: SourceOrderStandingDeadGeometryInput,
) !SourceOrderStandingDeadGeometryResult {
    if (input.components.len == 0 or input.canopy_layer_edges_m.len < 2)
        return error.InvalidStandingDeadGeometryDimensions;
    inline for (.{
        input.negligible_mass_g_c,
        input.standing_dead_population_count,
        input.previous_height_m,
        input.canopy_height_m,
        input.stalk_volume_per_carbon_m3_g_c,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidStandingDeadGeometry;
    for (input.components) |mass| inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        const value = @field(mass, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidStandingDeadGeometry;
    };
    for (input.canopy_layer_edges_m, 0..) |edge, index| {
        if (!std.math.isFinite(edge) or edge < 0 or
            (index != 0 and edge <= input.canopy_layer_edges_m[index - 1]))
            return error.InvalidStandingDeadGeometry;
    }
    const layer_count = input.canopy_layer_edges_m.len - 1;
    const layer_area = try allocator.alloc(f64, layer_count);
    errdefer allocator.free(layer_area);
    const projected_area = try allocator.alloc(f64, layer_count);
    errdefer allocator.free(projected_area);
    @memset(layer_area, 0);
    @memset(projected_area, 0);

    var total_mass: canopy.ElementalMass = .{};
    for (input.components) |component| {
        total_mass.carbon_g += component.carbon_g;
        total_mass.nitrogen_g += component.nitrogen_g;
        total_mass.phosphorus_g += component.phosphorus_g;
    }
    if (total_mass.carbon_g <= input.negligible_mass_g_c or
        input.standing_dead_population_count <= input.negligible_mass_g_c)
        return .{
            .total_mass = total_mass,
            .height_m = 0,
            .total_surface_area_m2 = 0,
            .layer_surface_area_m2 = layer_area,
            .projected_surface_area_m2 = projected_area,
        };

    const height_m = @max(
        @as(f64, 1.0e-2),
        @max(input.previous_height_m, input.canopy_height_m),
    );
    const radius_m = @sqrt(input.stalk_volume_per_carbon_m3_g_c *
        (@max(@as(f64, 0), total_mass.carbon_g) /
            input.standing_dead_population_count) /
        (3.1416 * height_m));
    const total_surface_area_m2 = 6.2832 * radius_m * height_m *
        input.standing_dead_population_count;
    const domain_top_m = input.canopy_layer_edges_m[layer_count];
    const occupied_height_m = @min(height_m, domain_top_m);
    for (0..layer_count) |layer| {
        const lower_m = input.canopy_layer_edges_m[layer];
        const upper_m = input.canopy_layer_edges_m[layer + 1];
        if (height_m > 0 and lower_m < height_m and upper_m > lower_m) {
            const occupied_fraction = @min(
                @as(f64, 1),
                (height_m - lower_m) / (upper_m - lower_m),
            );
            layer_area[layer] = occupied_fraction * total_surface_area_m2 *
                (upper_m - lower_m) / occupied_height_m;
        }
        projected_area[layer] = 0.25 * layer_area[layer];
    }
    inline for (.{ height_m, total_surface_area_m2 }) |value|
        if (!std.math.isFinite(value))
            return error.NonFiniteStandingDeadGeometry;
    for (layer_area, projected_area) |area, projected|
        if (!std.math.isFinite(area) or !std.math.isFinite(projected))
            return error.NonFiniteStandingDeadGeometry;
    return .{
        .total_mass = total_mass,
        .height_m = height_m,
        .total_surface_area_m2 = total_surface_area_m2,
        .layer_surface_area_m2 = layer_area,
        .projected_surface_area_m2 = projected_area,
    };
}

/// Exact GROSUB 8603-8625 conversion using authoritative combined-canopy
/// ARLFC rather than recomputing it from ARLFT.
pub fn sourceOrderCuttingHeightFromLeafAreaRemoval(
    requested_fraction: f64,
    total_combined_leaf_area_m2: f64,
    boundary_height_m: []const f64,
    combined_leaf_area_m2: []const f64,
    presence_tolerance_m2: f64,
) !f64 {
    if (!std.math.isFinite(requested_fraction) or requested_fraction < 0 or requested_fraction > 1 or
        !std.math.isFinite(total_combined_leaf_area_m2) or total_combined_leaf_area_m2 < 0 or
        !std.math.isFinite(presence_tolerance_m2) or presence_tolerance_m2 < 0 or
        boundary_height_m.len != combined_leaf_area_m2.len + 1 or combined_leaf_area_m2.len == 0)
        return error.InvalidLeafAreaHarvestGeometry;
    for (combined_leaf_area_m2) |area|
        if (!std.math.isFinite(area) or area < 0) return error.InvalidLeafAreaHarvestGeometry;
    for (boundary_height_m, 0..) |height, index| {
        if (!std.math.isFinite(height) or height < 0 or (index > 0 and height < boundary_height_m[index - 1]))
            return error.InvalidLeafAreaHarvestGeometry;
    }
    const target_remaining_leaf_area_m2 = (1 - requested_fraction) * total_combined_leaf_area_m2;
    if (target_remaining_leaf_area_m2 <= 0) return 0;
    var accumulated_leaf_area_m2: f64 = 0;
    var cutting_height_m: f64 = 0;
    for (combined_leaf_area_m2, 0..) |layer_leaf_area_m2, layer| {
        if (boundary_height_m[layer + 1] > boundary_height_m[layer] and
            layer_leaf_area_m2 > presence_tolerance_m2 and
            accumulated_leaf_area_m2 < target_remaining_leaf_area_m2)
        {
            cutting_height_m = if (accumulated_leaf_area_m2 + layer_leaf_area_m2 > target_remaining_leaf_area_m2)
                boundary_height_m[layer] +
                    (target_remaining_leaf_area_m2 - accumulated_leaf_area_m2) / layer_leaf_area_m2 *
                        (boundary_height_m[layer + 1] - boundary_height_m[layer])
            else
                0;
            accumulated_leaf_area_m2 += layer_leaf_area_m2;
        }
    }
    return cutting_height_m;
}
