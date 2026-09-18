//! `plant_harvest_source_order` declarations: tillage.
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

pub const TillageElementComposition = __parent.TillageElementComposition;
pub const validateTillageComposition = __parent.validateTillageComposition;
const validateTillageSlice = __parent.validateTillageSlice;

pub const SourceOrderTillagePopulationState = struct {
    living_population_per_m2: f64,
    living_population_count: f64,
    standing_dead_population_count: f64,
    canopy_radiation_fraction: f64,
};

pub const SourceOrderTillagePopulationInput = struct {
    hour_of_day: u8,
    local_solar_noon_h: f64,
    biomass_turnover_type: u8,
    root_profile_type: u8,
    current_day_of_year: u16,
    current_year: u32,
    planting_day_of_year: u16,
    planting_year: u32,
    tillage_code: u8,
    is_first_plant_population: bool,
    remaining_fraction: f64,
    zero_population_threshold: f64,
    state: SourceOrderTillagePopulationState,
};

pub const SourceOrderTillagePopulationResult = struct {
    state: SourceOrderTillagePopulationState,
    applied: bool,
    clear_leaf_sheath_and_sapwood_totals: bool,
    terminate_living_branches: bool,
};

/// Exact GROSUB 10031-10052 tillage population selector and scaling.
pub fn sourceOrderTillagePopulationReduction(
    input: SourceOrderTillagePopulationInput,
) !SourceOrderTillagePopulationResult {
    if (input.hour_of_day > 23 or
        !std.math.isFinite(input.local_solar_noon_h) or
        input.local_solar_noon_h < 0 or input.local_solar_noon_h >= 24 or
        input.current_day_of_year == 0 or input.current_day_of_year > 366 or
        input.planting_day_of_year == 0 or input.planting_day_of_year > 366 or
        input.current_year == 0 or input.planting_year == 0 or
        !std.math.isFinite(input.remaining_fraction) or
        input.remaining_fraction < 0 or input.remaining_fraction > 1 or
        !std.math.isFinite(input.zero_population_threshold) or
        input.zero_population_threshold < 0)
        return error.InvalidTillagePopulationInput;
    inline for (@typeInfo(SourceOrderTillagePopulationState).@"struct".fields) |field| {
        const value = @field(input.state, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidTillagePopulationInput;
    }

    const at_solar_noon = input.hour_of_day ==
        @as(u8, @intFromFloat(@floor(input.local_solar_noon_h)));
    const herbaceous = input.biomass_turnover_type == 0 or input.root_profile_type <= 1;
    const not_planting_date = input.current_day_of_year != input.planting_day_of_year or
        input.current_year != input.planting_year;
    const valid_tillage_code = input.tillage_code > 0 and input.tillage_code <= 20;
    const includes_population = input.tillage_code <= 10 or !input.is_first_plant_population;
    // Preserve the source's disjunctive comparison, including its
    // non-chronological behavior when schedule years are out of sequence.
    const after_planting = input.current_day_of_year > input.planting_day_of_year or
        input.current_year > input.planting_year;
    const applied = at_solar_noon and herbaceous and not_planting_date and
        valid_tillage_code and includes_population and after_planting;
    if (!applied) return .{
        .state = input.state,
        .applied = false,
        .clear_leaf_sheath_and_sapwood_totals = false,
        .terminate_living_branches = false,
    };

    var state = input.state;
    inline for (@typeInfo(SourceOrderTillagePopulationState).@"struct".fields) |field|
        @field(state, field.name) *= input.remaining_fraction;
    return .{
        .state = state,
        .applied = true,
        .clear_leaf_sheath_and_sapwood_totals = true,
        .terminate_living_branches = state.living_population_count <= input.zero_population_threshold,
    };
}

pub const SourceOrderTillageBranchPools = struct {
    host_mobile: canopy.ElementalMass,
    symbiont_mobile: canopy.ElementalMass,
    c4_mobile_carbon_g_c: f64,
    stalk_reserve: canopy.ElementalMass,
    leaf: canopy.ElementalMass,
    symbiont_structural: canopy.ElementalMass,
    sheath: canopy.ElementalMass,
    husk: canopy.ElementalMass,
    ear: canopy.ElementalMass,
    grain: canopy.ElementalMass,
    stalk: canopy.ElementalMass,
};

pub const SourceOrderTillageBranchLitterInput = struct {
    remaining_fraction: f64,
    winter_annual: bool,
    pools: SourceOrderTillageBranchPools,
    leaf_composition: TillageElementComposition,
    sheath_composition: TillageElementComposition,
    stalk_composition: TillageElementComposition,
    nonstructural_kinetics: litter_partition.ElementFractions,
    foliar_kinetics: litter_partition.ElementFractions,
    nonfoliar_kinetics: litter_partition.ElementFractions,
    stalk_kinetics: litter_partition.ElementFractions,
    coarse_wood_kinetics: litter_partition.ElementFractions,
};

pub const SourceOrderTillageBranchLitterResult = struct {
    litter: canopy.SenescenceProducts,
    seasonal_storage: canopy.ElementalMass,
};

/// Exact GROSUB 10096-10157 branch litter allocation during tillage.
pub fn sourceOrderTillageBranchLitter(
    input: SourceOrderTillageBranchLitterInput,
) !SourceOrderTillageBranchLitterResult {
    if (!std.math.isFinite(input.remaining_fraction) or
        input.remaining_fraction < 0 or input.remaining_fraction > 1 or
        !std.math.isFinite(input.pools.c4_mobile_carbon_g_c) or
        input.pools.c4_mobile_carbon_g_c < 0)
        return error.InvalidTillageBranchLitterInput;
    inline for (@typeInfo(SourceOrderTillageBranchPools).@"struct".fields) |field| {
        if (field.type == canopy.ElementalMass) {
            const mass = @field(input.pools, field.name);
            inline for (.{ mass.carbon_g, mass.nitrogen_g, mass.phosphorus_g }) |value|
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidTillageBranchLitterInput;
        }
    }
    try validateTillageComposition(input.leaf_composition);
    try validateTillageComposition(input.sheath_composition);
    try validateTillageComposition(input.stalk_composition);
    inline for (.{
        input.nonstructural_kinetics,
        input.foliar_kinetics,
        input.nonfoliar_kinetics,
        input.stalk_kinetics,
        input.coarse_wood_kinetics,
    }) |kinetics| kinetics.validate() catch return error.InvalidTillageBranchLitterInput;

    const removed = 1 - input.remaining_fraction;
    const pools = input.pools;
    var result: SourceOrderTillageBranchLitterResult = .{
        .litter = .{},
        .seasonal_storage = .{},
    };
    for (0..litter_partition.kinetic_component_count) |kinetic| {
        const nonwoody_carbon_g_c = input.nonstructural_kinetics.carbon[kinetic] *
            (pools.host_mobile.carbon_g + pools.symbiont_mobile.carbon_g +
                pools.c4_mobile_carbon_g_c + pools.stalk_reserve.carbon_g) +
            input.foliar_kinetics.carbon[kinetic] *
                (pools.leaf.carbon_g * input.leaf_composition.carbon[1] +
                    pools.symbiont_structural.carbon_g) +
            input.nonfoliar_kinetics.carbon[kinetic] *
                (pools.sheath.carbon_g * input.sheath_composition.carbon[1] +
                    pools.husk.carbon_g + pools.ear.carbon_g) +
            input.stalk_kinetics.carbon[kinetic] *
                pools.stalk.carbon_g * input.stalk_composition.carbon[1];
        const nonwoody_nitrogen_g_n = input.nonstructural_kinetics.nitrogen[kinetic] *
            (pools.host_mobile.nitrogen_g + pools.symbiont_mobile.nitrogen_g +
                pools.stalk_reserve.nitrogen_g) +
            input.foliar_kinetics.nitrogen[kinetic] *
                (pools.leaf.nitrogen_g * input.leaf_composition.nitrogen[1] +
                    pools.symbiont_structural.nitrogen_g) +
            input.nonfoliar_kinetics.nitrogen[kinetic] *
                (pools.sheath.nitrogen_g * input.sheath_composition.nitrogen[1] +
                    pools.husk.nitrogen_g + pools.ear.nitrogen_g) +
            input.stalk_kinetics.nitrogen[kinetic] *
                pools.stalk.nitrogen_g * input.stalk_composition.nitrogen[1];
        const nonwoody_phosphorus_g_p = input.nonstructural_kinetics.phosphorus[kinetic] *
            (pools.host_mobile.phosphorus_g + pools.symbiont_mobile.phosphorus_g +
                pools.stalk_reserve.phosphorus_g) +
            input.foliar_kinetics.phosphorus[kinetic] *
                (pools.leaf.phosphorus_g * input.leaf_composition.phosphorus[1] +
                    pools.symbiont_structural.phosphorus_g) +
            input.nonfoliar_kinetics.phosphorus[kinetic] *
                (pools.sheath.phosphorus_g * input.sheath_composition.phosphorus[1] +
                    pools.husk.phosphorus_g + pools.ear.phosphorus_g) +
            input.stalk_kinetics.phosphorus[kinetic] *
                pools.stalk.phosphorus_g * input.stalk_composition.phosphorus[1];
        result.litter.nonwoody_carbon_g[kinetic] = removed * nonwoody_carbon_g_c;
        result.litter.nonwoody_nitrogen_g[kinetic] = removed * nonwoody_nitrogen_g_n;
        result.litter.nonwoody_phosphorus_g[kinetic] = removed * nonwoody_phosphorus_g_p;
        result.litter.woody_carbon_g[kinetic] = removed * input.coarse_wood_kinetics.carbon[kinetic] *
            (pools.leaf.carbon_g * input.leaf_composition.carbon[0] +
                pools.sheath.carbon_g * input.sheath_composition.carbon[0] +
                pools.stalk.carbon_g * input.stalk_composition.carbon[0]);
        result.litter.woody_nitrogen_g[kinetic] = removed * input.coarse_wood_kinetics.nitrogen[kinetic] *
            (pools.leaf.nitrogen_g * input.leaf_composition.nitrogen[0] +
                pools.sheath.nitrogen_g * input.sheath_composition.nitrogen[0] +
                pools.stalk.nitrogen_g * input.stalk_composition.nitrogen[0]);
        result.litter.woody_phosphorus_g[kinetic] = removed * input.coarse_wood_kinetics.phosphorus[kinetic] *
            (pools.leaf.phosphorus_g * input.leaf_composition.phosphorus[0] +
                pools.sheath.phosphorus_g * input.sheath_composition.phosphorus[0] +
                pools.stalk.phosphorus_g * input.stalk_composition.phosphorus[0]);
        if (input.winter_annual) {
            result.seasonal_storage.carbon_g += removed * input.nonfoliar_kinetics.carbon[kinetic] * pools.grain.carbon_g;
            result.seasonal_storage.nitrogen_g += removed * input.nonfoliar_kinetics.nitrogen[kinetic] * pools.grain.nitrogen_g;
            result.seasonal_storage.phosphorus_g += removed * input.nonfoliar_kinetics.phosphorus[kinetic] * pools.grain.phosphorus_g;
        } else {
            result.litter.nonwoody_carbon_g[kinetic] += removed * input.nonfoliar_kinetics.carbon[kinetic] * pools.grain.carbon_g;
            result.litter.nonwoody_nitrogen_g[kinetic] += removed * input.nonfoliar_kinetics.nitrogen[kinetic] * pools.grain.nitrogen_g;
            result.litter.nonwoody_phosphorus_g[kinetic] += removed * input.nonfoliar_kinetics.phosphorus[kinetic] * pools.grain.phosphorus_g;
        }
    }
    return result;
}

pub const SourceOrderTillageBranchScalarState = struct {
    host_mobile: canopy.ElementalMass,
    c4_mobile_carbon_g_c: f64,
    symbiont_mobile: canopy.ElementalMass,
    total_shoot: canopy.ElementalMass,
    leaf: canopy.ElementalMass,
    symbiont_structural: canopy.ElementalMass,
    sheath: canopy.ElementalMass,
    stalk: canopy.ElementalMass,
    sapwood_carbon_g_c: f64,
    stalk_reserve: canopy.ElementalMass,
    husk: canopy.ElementalMass,
    ear: canopy.ElementalMass,
    grain: canopy.ElementalMass,
    potential_seed_site_count: f64,
    seed_count: f64,
    individual_seed_carbon_g_c: f64,
    leaf_area_m2: f64,
    stalk_total: canopy.ElementalMass,
};

pub const SourceOrderTillageNodeState = struct {
    c3_mobile_carbon_g_c: []f64,
    c4_mobile_carbon_g_c: []f64,
    carbon_dioxide_g_c: []f64,
    bicarbonate_g_c: []f64,
    leaf_area_m2: []f64,
    growing_leaf_carbon_g_c: []f64,
    senescing_leaf_carbon_g_c: []f64,
    growing_sheath_carbon_g_c: []f64,
    senescing_sheath_carbon_g_c: []f64,
    growing_node_carbon_g_c: []f64,
    growing_leaf_nitrogen_g_n: []f64,
    growing_sheath_nitrogen_g_n: []f64,
    growing_node_nitrogen_g_n: []f64,
    growing_leaf_phosphorus_g_p: []f64,
    growing_sheath_phosphorus_g_p: []f64,
    growing_node_phosphorus_g_p: []f64,
};

pub const SourceOrderTillageLayerSampleState = struct {
    leaf_area_m2: []f64,
    growing_leaf_carbon_g_c: []f64,
    growing_leaf_nitrogen_g_n: []f64,
    growing_leaf_phosphorus_g_p: []f64,
};

pub const SourceOrderTillageBranchRetentionResult = struct {
    leaf_sheath_carbon_g_c: f64,
    sapwood_carbon_g_c: f64,
};

/// Exact GROSUB 10161-10235 branch state remaining after tillage.
pub fn sourceOrderRetainTillageBranchState(
    scalar: *SourceOrderTillageBranchScalarState,
    nodes: SourceOrderTillageNodeState,
    layer_samples: SourceOrderTillageLayerSampleState,
    remaining_fraction: f64,
) !SourceOrderTillageBranchRetentionResult {
    if (!std.math.isFinite(remaining_fraction) or remaining_fraction < 0 or remaining_fraction > 1)
        return error.InvalidTillageBranchState;
    inline for (@typeInfo(SourceOrderTillageBranchScalarState).@"struct".fields) |field| {
        if (field.type == canopy.ElementalMass) {
            const mass = @field(scalar.*, field.name);
            inline for (.{ mass.carbon_g, mass.nitrogen_g, mass.phosphorus_g }) |value|
                if (!std.math.isFinite(value) or value < 0) return error.InvalidTillageBranchState;
        } else {
            const value = @field(scalar.*, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidTillageBranchState;
        }
    }
    const node_count = nodes.leaf_area_m2.len;
    inline for (@typeInfo(SourceOrderTillageNodeState).@"struct".fields) |field|
        if (@field(nodes, field.name).len != node_count) return error.TillageBranchNodeDimensionMismatch;
    const sample_count = layer_samples.leaf_area_m2.len;
    inline for (@typeInfo(SourceOrderTillageLayerSampleState).@"struct".fields) |field|
        if (@field(layer_samples, field.name).len != sample_count) return error.TillageBranchSampleDimensionMismatch;
    inline for (@typeInfo(SourceOrderTillageNodeState).@"struct".fields) |field|
        try validateTillageSlice(@field(nodes, field.name));
    inline for (@typeInfo(SourceOrderTillageLayerSampleState).@"struct".fields) |field|
        try validateTillageSlice(@field(layer_samples, field.name));

    const seed_carbon_g_c = scalar.individual_seed_carbon_g_c;
    inline for (@typeInfo(SourceOrderTillageBranchScalarState).@"struct".fields) |field| {
        if (!std.mem.eql(u8, field.name, "individual_seed_carbon_g_c")) {
            if (field.type == canopy.ElementalMass) {
                inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element|
                    @field(@field(scalar.*, field.name), element.name) *= remaining_fraction;
            } else {
                @field(scalar.*, field.name) *= remaining_fraction;
            }
        }
    }
    scalar.individual_seed_carbon_g_c = seed_carbon_g_c;

    inline for (@typeInfo(SourceOrderTillageNodeState).@"struct".fields, 0..) |field, index| {
        const first: usize = if (index < 4) 1 else 0;
        for (@field(nodes, field.name)[first..]) |*value| value.* *= remaining_fraction;
    }
    inline for (@typeInfo(SourceOrderTillageLayerSampleState).@"struct".fields) |field| {
        for (@field(layer_samples, field.name)) |*value| value.* *= remaining_fraction;
    }

    return .{
        .leaf_sheath_carbon_g_c = @max(0, scalar.leaf.carbon_g + scalar.sheath.carbon_g),
        .sapwood_carbon_g_c = scalar.sapwood_carbon_g_c,
    };
}

pub const SourceOrderTillageStandingDeadInput = struct {
    remaining_fraction: f64,
    standing_dead_by_source_component: [litter_partition.kinetic_component_count]canopy.ElementalMass,
    composition: TillageElementComposition,
    stalk_kinetics: litter_partition.ElementFractions,
    coarse_wood_kinetics: litter_partition.ElementFractions,
};

pub const SourceOrderTillageStandingDeadResult = struct {
    litter: canopy.SenescenceProducts,
    remaining_by_source_component: [litter_partition.kinetic_component_count]canopy.ElementalMass,
};

/// Exact GROSUB 10250-10272 standing-dead litter and retention during tillage.
pub fn sourceOrderTillageStandingDead(
    input: SourceOrderTillageStandingDeadInput,
) !SourceOrderTillageStandingDeadResult {
    if (!std.math.isFinite(input.remaining_fraction) or
        input.remaining_fraction < 0 or input.remaining_fraction > 1)
        return error.InvalidTillageStandingDeadInput;
    try validateTillageComposition(input.composition);
    input.stalk_kinetics.validate() catch return error.InvalidTillageStandingDeadInput;
    input.coarse_wood_kinetics.validate() catch return error.InvalidTillageStandingDeadInput;

    var total: canopy.ElementalMass = .{};
    for (input.standing_dead_by_source_component) |mass| {
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
            const value = @field(mass, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidTillageStandingDeadInput;
            @field(total, field.name) += value;
        }
    }
    const removed = 1 - input.remaining_fraction;
    var result: SourceOrderTillageStandingDeadResult = .{
        .litter = .{},
        .remaining_by_source_component = input.standing_dead_by_source_component,
    };
    for (0..litter_partition.kinetic_component_count) |kinetic| {
        result.litter.woody_carbon_g[kinetic] = removed *
            input.coarse_wood_kinetics.carbon[kinetic] * total.carbon_g * input.composition.carbon[0];
        result.litter.woody_nitrogen_g[kinetic] = removed *
            input.coarse_wood_kinetics.nitrogen[kinetic] * total.nitrogen_g * input.composition.nitrogen[0];
        result.litter.woody_phosphorus_g[kinetic] = removed *
            input.coarse_wood_kinetics.phosphorus[kinetic] * total.phosphorus_g * input.composition.phosphorus[0];
        result.litter.nonwoody_carbon_g[kinetic] = removed *
            input.stalk_kinetics.carbon[kinetic] * total.carbon_g * input.composition.carbon[1];
        result.litter.nonwoody_nitrogen_g[kinetic] = removed *
            input.stalk_kinetics.nitrogen[kinetic] * total.nitrogen_g * input.composition.nitrogen[1];
        result.litter.nonwoody_phosphorus_g[kinetic] = removed *
            input.stalk_kinetics.phosphorus[kinetic] * total.phosphorus_g * input.composition.phosphorus[1];
    }
    for (&result.remaining_by_source_component) |*mass| {
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
            @field(mass, field.name) *= input.remaining_fraction;
    }
    return result;
}

pub const SourceOrderTillageTerminationState = struct {
    roots_dead: bool,
    shoots_dead: bool,
    plant_dead: bool,
    harvest_termination_code: u8,
    harvest_day_of_year: u16,
    harvest_year: u32,
};

pub const SourceOrderTillageTerminationInput = struct {
    living_population_count: f64,
    zero_population_threshold: f64,
    current_day_of_year: u16,
    current_year: u32,
    state: SourceOrderTillageTerminationState,
};

pub const SourceOrderTillageTerminationResult = struct {
    state: SourceOrderTillageTerminationState,
    terminated: bool,
};

/// Exact GROSUB 10283-10290 zero-population tillage termination.
pub fn sourceOrderTillageTermination(
    input: SourceOrderTillageTerminationInput,
) !SourceOrderTillageTerminationResult {
    if (!std.math.isFinite(input.living_population_count) or
        input.living_population_count < 0 or
        !std.math.isFinite(input.zero_population_threshold) or
        input.zero_population_threshold < 0 or
        input.current_day_of_year == 0 or input.current_day_of_year > 366 or
        input.current_year == 0 or input.state.harvest_termination_code > 2 or
        input.state.harvest_day_of_year > 366)
        return error.InvalidTillageTerminationInput;
    if (input.living_population_count > input.zero_population_threshold)
        return .{ .state = input.state, .terminated = false };
    return .{
        .state = .{
            .roots_dead = true,
            .shoots_dead = true,
            .plant_dead = true,
            .harvest_termination_code = 1,
            .harvest_day_of_year = input.current_day_of_year,
            .harvest_year = input.current_year,
        },
        .terminated = true,
    };
}
