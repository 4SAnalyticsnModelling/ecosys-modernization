//! `plant_harvest_source_order` declarations: dead branch.
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
const group_tillage = @import("plant_harvest_source_order_tillage.zig");

pub const SourceOrderDeadBranchPhenologyState = struct {
    dead: bool,
    maturity_group_node_count: f64,
    initiated_node_count: f64,
    nodes_at_floral_initiation: f64,
    nodes_at_anthesis: f64,
    appeared_leaf_count: f64,
    leaves_at_floral_initiation: f64,
    current_leaf_ordinal: usize,
    current_growing_leaf_ordinal: usize,
    normalized_vegetative_node_change: f64,
    normalized_reproductive_node_change: f64,
    accumulated_leafout_h: f64,
    accumulated_leafoff_h: f64,
    lengthening_photoperiod_h: f64,
    shortening_photoperiod_h: f64,
    time_since_germination_h: f64,
    hours_without_grain_fill: f64,
    carbon_fixation_feedback: f64,
    carbon_fixation_feedback_previous: f64,
    leafout_initialization_enabled: bool,
    emergence_initialization_disabled: bool,
    leafoff_enabled: bool,
    remobilization_enabled: bool,
    hours_after_maturity_h: f64,
    new_branch_count: usize,
    stage_day_of_year: [10]u16,
};

pub const SourceOrderDeadBranchResetInput = struct {
    first_living_branch_emergence_day_of_year: u16,
    perennial_growth_habit: bool,
    current_day_of_year: u16,
    current_year: u32,
    harvest_day_of_year: u16,
    harvest_year: u32,
    hour_of_day: u8,
    local_solar_noon_h: f64,
    initial_maturity_group_node_count: f64,
    initial_node_count: f64,
};

/// Exact GROSUB 10955-10992 dead-branch phenology reset selector and loop.
pub fn sourceOrderResetDeadBranchPhenology(
    branches: []SourceOrderDeadBranchPhenologyState,
    input: SourceOrderDeadBranchResetInput,
) !bool {
    if (input.current_day_of_year == 0 or input.current_day_of_year > 366 or
        input.harvest_day_of_year == 0 or input.harvest_day_of_year > 366 or
        input.current_year == 0 or input.harvest_year == 0 or input.hour_of_day > 23 or
        !std.math.isFinite(input.local_solar_noon_h) or input.local_solar_noon_h < 0 or
        input.local_solar_noon_h >= 24 or
        !std.math.isFinite(input.initial_maturity_group_node_count) or
        !std.math.isFinite(input.initial_node_count))
        return error.InvalidDeadBranchPhenologyResetInput;
    for (branches) |branch| {
        inline for (@typeInfo(SourceOrderDeadBranchPhenologyState).@"struct".fields) |field| {
            if (field.type == f64 and !std.math.isFinite(@field(branch, field.name)))
                return error.InvalidDeadBranchPhenologyResetInput;
        }
    }

    const at_solar_noon = input.hour_of_day ==
        @as(u8, @intFromFloat(@floor(input.local_solar_noon_h)));
    const annual_harvest_reached =
        input.current_day_of_year >= input.harvest_day_of_year and
        input.current_year >= input.harvest_year and at_solar_noon;
    const selected = input.first_living_branch_emergence_day_of_year != 0 and
        (input.perennial_growth_habit or annual_harvest_reached);
    if (!selected) return false;

    for (branches) |*branch| {
        if (!branch.dead) continue;
        branch.maturity_group_node_count = input.initial_maturity_group_node_count;
        branch.initiated_node_count = input.initial_node_count;
        branch.nodes_at_floral_initiation = input.initial_node_count;
        branch.nodes_at_anthesis = 0;
        branch.appeared_leaf_count = 0;
        branch.leaves_at_floral_initiation = 0;
        branch.current_leaf_ordinal = 1;
        branch.current_growing_leaf_ordinal = 1;
        branch.normalized_vegetative_node_change = 0;
        branch.normalized_reproductive_node_change = 0;
        branch.accumulated_leafout_h = 0;
        branch.accumulated_leafoff_h = 0;
        branch.lengthening_photoperiod_h = 0;
        branch.shortening_photoperiod_h = 0;
        branch.time_since_germination_h = 0;
        branch.hours_without_grain_fill = 0;
        branch.carbon_fixation_feedback = 1;
        branch.carbon_fixation_feedback_previous = 1;
        branch.leafout_initialization_enabled = true;
        branch.emergence_initialization_disabled = true;
        branch.leafoff_enabled = true;
        branch.remobilization_enabled = true;
        branch.hours_after_maturity_h = 0;
        branch.new_branch_count = 0;
        branch.stage_day_of_year = @splat(0);
    }
    return true;
}

pub const SourceOrderDeadBranchLitterPools = struct {
    bacterial_nonstructural: canopy.ElementalMass,
    bacterial_structural: canopy.ElementalMass,
    leaf: canopy.ElementalMass,
    sheath: canopy.ElementalMass,
    husk: canopy.ElementalMass,
    ear: canopy.ElementalMass,
    grain: canopy.ElementalMass,
    stalk: canopy.ElementalMass,
};

pub const SourceOrderDeadBranchLitterInput = struct {
    annual_growth_habit: bool,
    deciduous_phenology: bool,
    pools: SourceOrderDeadBranchLitterPools,
    leaf_woody_fraction: group_tillage.TillageElementComposition,
    sheath_woody_fraction: group_tillage.TillageElementComposition,
    nonstructural_kinetics: litter_partition.ElementFractions,
    foliar_kinetics: litter_partition.ElementFractions,
    nonfoliar_kinetics: litter_partition.ElementFractions,
    stalk_kinetics: litter_partition.ElementFractions,
    coarse_wood_kinetics: litter_partition.ElementFractions,
};

pub const SourceOrderDeadBranchLitterResult = struct {
    nonwoody_litter: [4]canopy.ElementalMass,
    woody_litter: [4]canopy.ElementalMass,
    standing_dead_stalk: [4]canopy.ElementalMass,
    seasonal_storage_addition: canopy.ElementalMass,
};

/// Exact GROSUB 11031-11083 four-component dead-branch litter partition.
pub fn sourceOrderDeadBranchLitterfall(
    input: SourceOrderDeadBranchLitterInput,
) !SourceOrderDeadBranchLitterResult {
    inline for (@typeInfo(SourceOrderDeadBranchLitterPools).@"struct".fields) |field| {
        const mass = @field(input.pools, field.name);
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element| {
            const value = @field(mass, element.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidDeadBranchLitterfallInput;
        }
    }
    inline for (.{ input.leaf_woody_fraction, input.sheath_woody_fraction }) |fractions| {
        inline for (@typeInfo(group_tillage.TillageElementComposition).@"struct".fields) |field| {
            for (@field(fractions, field.name)) |value| {
                if (!std.math.isFinite(value) or value < 0 or value > 1)
                    return error.InvalidDeadBranchLitterfallInput;
            }
        }
    }
    inline for (.{
        input.nonstructural_kinetics,
        input.foliar_kinetics,
        input.nonfoliar_kinetics,
        input.stalk_kinetics,
        input.coarse_wood_kinetics,
    }) |kinetics| {
        inline for (@typeInfo(litter_partition.ElementFractions).@"struct".fields) |field| {
            for (@field(kinetics, field.name)) |value| {
                if (!std.math.isFinite(value) or value < 0 or value > 1)
                    return error.InvalidDeadBranchLitterfallInput;
            }
        }
    }

    var result: SourceOrderDeadBranchLitterResult = .{
        .nonwoody_litter = @splat(.{}),
        .woody_litter = @splat(.{}),
        .standing_dead_stalk = @splat(.{}),
        .seasonal_storage_addition = .{},
    };
    const winter_annual = input.annual_growth_habit and input.deciduous_phenology;
    inline for (0..4) |component| {
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields, 0..) |element, element_index| {
            const bacterial_nonstructural = @field(input.pools.bacterial_nonstructural, element.name);
            const bacterial_structural = @field(input.pools.bacterial_structural, element.name);
            const leaf = @field(input.pools.leaf, element.name);
            const sheath = @field(input.pools.sheath, element.name);
            const husk = @field(input.pools.husk, element.name);
            const ear = @field(input.pools.ear, element.name);
            const grain = @field(input.pools.grain, element.name);
            const stalk = @field(input.pools.stalk, element.name);
            const fraction_field =
                @typeInfo(litter_partition.ElementFractions).@"struct".fields[element_index].name;
            const nonstructural_fraction = @field(input.nonstructural_kinetics, fraction_field)[component];
            const foliar_fraction = @field(input.foliar_kinetics, fraction_field)[component];
            const nonfoliar_fraction = @field(input.nonfoliar_kinetics, fraction_field)[component];
            const stalk_fraction = @field(input.stalk_kinetics, fraction_field)[component];
            const coarse_wood_fraction = @field(input.coarse_wood_kinetics, fraction_field)[component];
            const leaf_wood = @field(input.leaf_woody_fraction, fraction_field);
            const sheath_wood = @field(input.sheath_woody_fraction, fraction_field);

            @field(result.nonwoody_litter[component], element.name) +=
                nonstructural_fraction * bacterial_nonstructural;
            @field(result.nonwoody_litter[component], element.name) +=
                foliar_fraction * (leaf * leaf_wood[1] + bacterial_structural);
            @field(result.nonwoody_litter[component], element.name) +=
                nonfoliar_fraction * (sheath * sheath_wood[1] + husk + ear);
            @field(result.woody_litter[component], element.name) +=
                coarse_wood_fraction * (leaf * leaf_wood[0] + sheath * sheath_wood[0]);
            if (winter_annual) {
                @field(result.seasonal_storage_addition, element.name) +=
                    nonfoliar_fraction * grain;
            } else {
                @field(result.nonwoody_litter[component], element.name) +=
                    nonfoliar_fraction * grain;
            }
            @field(result.standing_dead_stalk[component], element.name) +=
                stalk_fraction * stalk;
        }
    }
    inline for (@typeInfo(SourceOrderDeadBranchLitterResult).@"struct".fields) |field| {
        const value = @field(result, field.name);
        if (field.type == canopy.ElementalMass) {
            inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element|
                if (!std.math.isFinite(@field(value, element.name)))
                    return error.NonFiniteDeadBranchLitterfall;
        } else for (value) |mass| {
            inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element|
                if (!std.math.isFinite(@field(mass, element.name)))
                    return error.NonFiniteDeadBranchLitterfall;
        }
    }
    return result;
}

pub const SourceOrderDeadBranchStorageRecoveryInput = struct {
    current_seasonal_storage: canopy.ElementalMass,
    branch_mobile: canopy.ElementalMass,
    c4_intermediate_carbon_g_c: f64,
    stalk_reserve: canopy.ElementalMass,
};

pub const SourceOrderDeadBranchStorageRecoveryResult = struct {
    seasonal_storage: canopy.ElementalMass,
    recovered: canopy.ElementalMass,
};

/// Exact GROSUB 11100-11106 dead-branch mobile and reserve recovery.
pub fn sourceOrderDeadBranchStorageRecovery(
    input: SourceOrderDeadBranchStorageRecoveryInput,
) !SourceOrderDeadBranchStorageRecoveryResult {
    inline for (.{ input.current_seasonal_storage, input.branch_mobile, input.stalk_reserve }) |mass| {
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
            const value = @field(mass, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidDeadBranchStorageRecoveryInput;
        }
    }
    if (!std.math.isFinite(input.c4_intermediate_carbon_g_c) or
        input.c4_intermediate_carbon_g_c < 0)
        return error.InvalidDeadBranchStorageRecoveryInput;

    // Preserve the six source assignments, including the two sequential
    // additions to storage carbon.
    var seasonal_storage = input.current_seasonal_storage;
    seasonal_storage.carbon_g =
        seasonal_storage.carbon_g +
        input.branch_mobile.carbon_g +
        input.c4_intermediate_carbon_g_c;
    seasonal_storage.nitrogen_g =
        seasonal_storage.nitrogen_g + input.branch_mobile.nitrogen_g;
    seasonal_storage.phosphorus_g =
        seasonal_storage.phosphorus_g + input.branch_mobile.phosphorus_g;
    seasonal_storage.carbon_g =
        seasonal_storage.carbon_g + input.stalk_reserve.carbon_g;
    seasonal_storage.nitrogen_g =
        seasonal_storage.nitrogen_g + input.stalk_reserve.nitrogen_g;
    seasonal_storage.phosphorus_g =
        seasonal_storage.phosphorus_g + input.stalk_reserve.phosphorus_g;

    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(seasonal_storage, field.name)))
            return error.NonFiniteDeadBranchStorageRecovery;
    }
    return .{
        .seasonal_storage = seasonal_storage,
        .recovered = .{
            .carbon_g = input.branch_mobile.carbon_g +
                input.c4_intermediate_carbon_g_c +
                input.stalk_reserve.carbon_g,
            .nitrogen_g = input.branch_mobile.nitrogen_g +
                input.stalk_reserve.nitrogen_g,
            .phosphorus_g = input.branch_mobile.phosphorus_g +
                input.stalk_reserve.phosphorus_g,
        },
    };
}

pub const SourceOrderDeadBranchScalarResetState = struct {
    host_mobile: canopy.ElementalMass,
    c4_intermediate_carbon_g_c: f64,
    symbiont_mobile: canopy.ElementalMass,
    shoot_total: canopy.ElementalMass,
    leaf: canopy.ElementalMass,
    symbiont_structural: canopy.ElementalMass,
    sheath: canopy.ElementalMass,
    stalk: canopy.ElementalMass,
    vascular_stalk_carbon_g_c: f64,
    stalk_reserve: canopy.ElementalMass,
    husk: canopy.ElementalMass,
    ear: canopy.ElementalMass,
    grain: canopy.ElementalMass,
    live_symbiont_carbon_g_c: f64,
    potential_seed_sites: f64,
    seed_count: f64,
    individual_seed_carbon_g_c: f64,
    leaf_area_m2: f64,
    stale_stalk_total: canopy.ElementalMass,
};

pub const SourceOrderDeadBranchNodeResetState = struct {
    bundle_sheath_mobile_carbon_g_c: f64,
    mesophyll_mobile_carbon_g_c: f64,
    bundle_sheath_co2_carbon_g_c: f64,
    bundle_sheath_bicarbonate_carbon_g_c: f64,
    leaf_area_m2: f64,
    node_height_m: f64,
    node_height_previous_m: f64,
    sheath_height_m: f64,
    leaf: canopy.ElementalMass,
    leaf_protein_g: f64,
    sheath: canopy.ElementalMass,
    sheath_protein_g: f64,
    stalk: canopy.ElementalMass,
};

pub const SourceOrderDeadBranchLayerResetState = struct {
    leaf_area_m2: f64,
    leaf: canopy.ElementalMass,
    projected_leaf_surface_m2: [4]f64,
};

pub const SourceOrderDeadBranchCanopyReset = struct {
    scalar: *SourceOrderDeadBranchScalarResetState,
    nodes: []SourceOrderDeadBranchNodeResetState,
    node_layers: []SourceOrderDeadBranchLayerResetState,
    canopy_leaf_area_m2_by_layer: []f64,
    canopy_leaf_carbon_g_c_by_layer: []f64,
    branch_stalk_area_m2_by_layer: []f64,
    branch_projected_stalk_surface_m2: [][4]f64,
};

/// Exact GROSUB 11137-11220 dead-branch scalar, node, and canopy reset.
pub fn sourceOrderResetDeadBranchCanopy(state: SourceOrderDeadBranchCanopyReset) !void {
    const layer_count = state.canopy_leaf_area_m2_by_layer.len;
    const expected_node_layers = std.math.mul(usize, state.nodes.len, layer_count) catch
        return error.InvalidDeadBranchCanopyResetDimensions;
    if (layer_count == 0 or
        state.canopy_leaf_carbon_g_c_by_layer.len != layer_count or
        state.branch_stalk_area_m2_by_layer.len != layer_count or
        state.branch_projected_stalk_surface_m2.len != layer_count or
        state.node_layers.len != expected_node_layers)
        return error.InvalidDeadBranchCanopyResetDimensions;
    inline for (@typeInfo(SourceOrderDeadBranchScalarResetState).@"struct".fields) |field| {
        const value = @field(state.scalar.*, field.name);
        if (field.type == f64) {
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidDeadBranchCanopyResetInput;
        } else inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element| {
            const mass = @field(value, element.name);
            if (!std.math.isFinite(mass) or mass < 0)
                return error.InvalidDeadBranchCanopyResetInput;
        }
    }
    for (state.nodes) |node| inline for (@typeInfo(SourceOrderDeadBranchNodeResetState).@"struct".fields) |field| {
        const value = @field(node, field.name);
        if (field.type == f64) {
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidDeadBranchCanopyResetInput;
        } else inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element| {
            const mass = @field(value, element.name);
            if (!std.math.isFinite(mass) or mass < 0)
                return error.InvalidDeadBranchCanopyResetInput;
        }
    };
    for (0..layer_count) |layer| {
        var branch_area_m2: f64 = 0;
        var branch_carbon_g_c: f64 = 0;
        for (0..state.nodes.len) |node| {
            const contribution = state.node_layers[node * layer_count + layer];
            if (!std.math.isFinite(contribution.leaf_area_m2) or contribution.leaf_area_m2 < 0)
                return error.InvalidDeadBranchCanopyResetInput;
            inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element| {
                const mass = @field(contribution.leaf, element.name);
                if (!std.math.isFinite(mass) or mass < 0)
                    return error.InvalidDeadBranchCanopyResetInput;
            }
            for (contribution.projected_leaf_surface_m2) |surface|
                if (!std.math.isFinite(surface) or surface < 0)
                    return error.InvalidDeadBranchCanopyResetInput;
            branch_area_m2 += contribution.leaf_area_m2;
            branch_carbon_g_c += contribution.leaf.carbon_g;
        }
        if (!std.math.isFinite(state.canopy_leaf_area_m2_by_layer[layer]) or
            !std.math.isFinite(state.canopy_leaf_carbon_g_c_by_layer[layer]) or
            state.canopy_leaf_area_m2_by_layer[layer] < branch_area_m2 or
            state.canopy_leaf_carbon_g_c_by_layer[layer] < branch_carbon_g_c or
            !std.math.isFinite(state.branch_stalk_area_m2_by_layer[layer]) or
            state.branch_stalk_area_m2_by_layer[layer] < 0)
            return error.InvalidDeadBranchCanopyResetInput;
        for (state.branch_projected_stalk_surface_m2[layer]) |surface|
            if (!std.math.isFinite(surface) or surface < 0)
                return error.InvalidDeadBranchCanopyResetInput;
    }

    state.scalar.host_mobile = .{};
    state.scalar.c4_intermediate_carbon_g_c = 0;
    state.scalar.symbiont_mobile = .{};
    state.scalar.shoot_total = .{};
    state.scalar.leaf = .{};
    state.scalar.symbiont_structural = .{};
    state.scalar.sheath = .{};
    state.scalar.stalk = .{};
    state.scalar.vascular_stalk_carbon_g_c = 0;
    state.scalar.stalk_reserve = .{};
    state.scalar.husk = .{};
    state.scalar.ear = .{};
    state.scalar.grain = .{};
    state.scalar.live_symbiont_carbon_g_c = 0;
    state.scalar.potential_seed_sites = 0;
    state.scalar.seed_count = 0;
    state.scalar.individual_seed_carbon_g_c = 0;
    state.scalar.leaf_area_m2 = 0;
    state.scalar.stale_stalk_total = .{};
    for (state.nodes, 0..) |*node, node_index| {
        if (node_index != 0) {
            node.bundle_sheath_mobile_carbon_g_c = 0;
            node.mesophyll_mobile_carbon_g_c = 0;
            node.bundle_sheath_co2_carbon_g_c = 0;
            node.bundle_sheath_bicarbonate_carbon_g_c = 0;
        }
        node.leaf_area_m2 = 0;
        node.node_height_m = 0;
        node.node_height_previous_m = 0;
        node.sheath_height_m = 0;
        node.leaf = .{};
        node.leaf_protein_g = 0;
        node.sheath = .{};
        node.sheath_protein_g = 0;
        node.stalk = .{};
        for (0..layer_count) |layer| {
            const offset = node_index * layer_count + layer;
            const contribution = state.node_layers[offset];
            state.canopy_leaf_area_m2_by_layer[layer] -= contribution.leaf_area_m2;
            state.canopy_leaf_carbon_g_c_by_layer[layer] -= contribution.leaf.carbon_g;
            state.node_layers[offset].leaf_area_m2 = 0;
            state.node_layers[offset].leaf = .{};
            if (node_index != 0)
                state.node_layers[offset].projected_leaf_surface_m2 = @splat(0);
        }
    }
    @memset(state.branch_stalk_area_m2_by_layer, 0);
    @memset(state.branch_projected_stalk_surface_m2, @splat(0));
}
