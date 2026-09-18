//! `plant_harvest_source_order` declarations: dead root.
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

const validateDeadNoduleMass = __parent.validateDeadNoduleMass;
const validateDeadRootDepthMass = __parent.validateDeadRootDepthMass;
pub const validateDeadRootResetMass = __parent.validateDeadRootResetMass;

pub const SourceOrderDeadRootAxisPools = struct {
    primary: canopy.ElementalMass,
    secondary: canopy.ElementalMass,
};

pub const SourceOrderDeadRootLitterInput = struct {
    roots_dead: bool,
    root_domain_count: usize,
    soil_layer_count: usize,
    root_axis_count: usize,
    mobile_by_domain_layer: []const canopy.ElementalMass,
    structural_by_domain_layer_axis: []const SourceOrderDeadRootAxisPools,
    root_woody_fraction: group_tillage.TillageElementComposition,
    mobile_kinetics: litter_partition.ElementFractions,
    fine_root_kinetics: litter_partition.ElementFractions,
    coarse_root_kinetics: litter_partition.ElementFractions,
};

pub const SourceOrderDeadRootLayerLitter = struct {
    woody: [4]canopy.ElementalMass,
    nonwoody: [4]canopy.ElementalMass,
};

/// Exact GROSUB 11265-11288 dead-root C/N/P litterfall.
/// Caller owns the returned runtime-layer slice.
pub fn sourceOrderDeadRootLitterfall(
    allocator: std.mem.Allocator,
    input: SourceOrderDeadRootLitterInput,
) ![]SourceOrderDeadRootLayerLitter {
    if (input.root_domain_count == 0 or input.soil_layer_count == 0 or
        input.root_axis_count == 0)
        return error.InvalidDeadRootLitterfallDimensions;
    const domain_layers = std.math.mul(
        usize,
        input.root_domain_count,
        input.soil_layer_count,
    ) catch return error.InvalidDeadRootLitterfallDimensions;
    const structural_count = std.math.mul(
        usize,
        domain_layers,
        input.root_axis_count,
    ) catch return error.InvalidDeadRootLitterfallDimensions;
    if (input.mobile_by_domain_layer.len != domain_layers or
        input.structural_by_domain_layer_axis.len != structural_count)
        return error.InvalidDeadRootLitterfallDimensions;
    inline for (.{ input.mobile_kinetics, input.fine_root_kinetics, input.coarse_root_kinetics }) |kinetics| {
        inline for (@typeInfo(litter_partition.ElementFractions).@"struct".fields) |field| {
            for (@field(kinetics, field.name)) |fraction|
                if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
                    return error.InvalidDeadRootLitterfallInput;
        }
    }
    inline for (@typeInfo(group_tillage.TillageElementComposition).@"struct".fields) |field| {
        for (@field(input.root_woody_fraction, field.name)) |fraction|
            if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
                return error.InvalidDeadRootLitterfallInput;
    }
    for (input.mobile_by_domain_layer) |mass| try group_misc.validateSourceOrderRootMass(mass);
    for (input.structural_by_domain_layer_axis) |axis| {
        try group_misc.validateSourceOrderRootMass(axis.primary);
        try group_misc.validateSourceOrderRootMass(axis.secondary);
    }

    const result = try allocator.alloc(SourceOrderDeadRootLayerLitter, input.soil_layer_count);
    errdefer allocator.free(result);
    @memset(result, .{ .woody = @splat(.{}), .nonwoody = @splat(.{}) });
    if (!input.roots_dead) return result;

    for (0..input.root_domain_count) |domain| {
        for (0..input.soil_layer_count) |layer| {
            const domain_layer = domain * input.soil_layer_count + layer;
            inline for (0..4) |component| {
                inline for (@typeInfo(canopy.ElementalMass).@"struct".fields, 0..) |element, element_index| {
                    const fraction_field =
                        @typeInfo(litter_partition.ElementFractions).@"struct".fields[element_index].name;
                    @field(result[layer].nonwoody[component], element.name) +=
                        @field(input.mobile_kinetics, fraction_field)[component] *
                        @field(input.mobile_by_domain_layer[domain_layer], element.name);
                }
                for (0..input.root_axis_count) |axis| {
                    const pools = input.structural_by_domain_layer_axis[
                        domain_layer * input.root_axis_count + axis
                    ];
                    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields, 0..) |element, element_index| {
                        const fraction_field =
                            @typeInfo(litter_partition.ElementFractions).@"struct".fields[element_index].name;
                        const structural_mass =
                            @field(pools.primary, element.name) +
                            @field(pools.secondary, element.name);
                        const wood = @field(input.root_woody_fraction, fraction_field);
                        @field(result[layer].woody[component], element.name) +=
                            @field(input.coarse_root_kinetics, fraction_field)[component] *
                            structural_mass * wood[0];
                        @field(result[layer].nonwoody[component], element.name) +=
                            @field(input.fine_root_kinetics, fraction_field)[component] *
                            structural_mass * wood[1];
                    }
                }
            }
        }
    }
    for (result) |layer| inline for (.{ layer.woody, layer.nonwoody }) |position| {
        for (position) |mass| inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element|
            if (!std.math.isFinite(@field(mass, element.name)))
                return error.NonFiniteDeadRootLitterfall;
    };
    return result;
}

pub const SourceOrderRootGasInventory = struct {
    carbon_dioxide_carbon_g_c: f64,
    oxygen_g_o: f64,
    methane_carbon_g_c: f64,
    nitrous_oxide_nitrogen_g_n: f64,
    ammonia_nitrogen_g_n: f64,
    hydrogen_g_h: f64,
};

pub const SourceOrderRootGasPhases = struct {
    gaseous: SourceOrderRootGasInventory,
    aqueous: SourceOrderRootGasInventory,
};

/// Exact GROSUB 11292-11315 dead-root gas release and phase clearing.
pub fn sourceOrderReleaseDeadRootGases(
    roots_dead: bool,
    domain_layer_phases: []SourceOrderRootGasPhases,
    current_disturbance_loss: SourceOrderRootGasInventory,
) !SourceOrderRootGasInventory {
    inline for (@typeInfo(SourceOrderRootGasInventory).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(current_disturbance_loss, field.name)))
            return error.InvalidDeadRootGasReleaseInput;
    }
    for (domain_layer_phases) |phases| {
        inline for (.{ phases.gaseous, phases.aqueous }) |phase| {
            inline for (@typeInfo(SourceOrderRootGasInventory).@"struct".fields) |field| {
                const value = @field(phase, field.name);
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidDeadRootGasReleaseInput;
            }
        }
    }
    if (!roots_dead) return current_disturbance_loss;

    var disturbance_loss = current_disturbance_loss;
    // The caller supplies domain-major/layer-minor storage, matching the
    // enclosing source loops. Preserve gaseous-then-aqueous subtraction.
    for (domain_layer_phases) |phases| {
        inline for (@typeInfo(SourceOrderRootGasInventory).@"struct".fields) |field| {
            @field(disturbance_loss, field.name) =
                @field(disturbance_loss, field.name) -
                @field(phases.gaseous, field.name);
            @field(disturbance_loss, field.name) =
                @field(disturbance_loss, field.name) -
                @field(phases.aqueous, field.name);
            if (!std.math.isFinite(@field(disturbance_loss, field.name)))
                return error.NonFiniteDeadRootGasRelease;
        }
    }
    for (domain_layer_phases) |*phases| {
        phases.gaseous = std.mem.zeroes(SourceOrderRootGasInventory);
        phases.aqueous = std.mem.zeroes(SourceOrderRootGasInventory);
    }
    return disturbance_loss;
}

pub const SourceOrderDeadRootAxisLayerState = struct {
    primary: canopy.ElementalMass,
    secondary: canopy.ElementalMass,
    primary_length_m: f64,
    secondary_length_m: f64,
    secondary_axis_count: f64,
};

pub const SourceOrderDeadRootDomainAxisState = struct {
    primary_total: canopy.ElementalMass,
};

pub const SourceOrderDeadRootDomainLayerState = struct {
    mobile: canopy.ElementalMass,
    active_root_carbon_g_c: f64,
    actual_root_carbon_g_c: f64,
    root_protein_g: f64,
    primary_axis_count: f64,
    total_axis_count: f64,
    root_length_per_plant_m: f64,
    root_length_density_m_m3: f64,
    gaseous_volume_m3: f64,
    aqueous_volume_m3: f64,
    root_surface_area_per_plant_m2: f64,
    primary_radius_m: f64,
    secondary_radius_m: f64,
    average_secondary_root_length_m: f64,
};

pub const SourceOrderDeadRootResetState = struct {
    root_domain_count: usize,
    soil_layer_count: usize,
    root_axis_count: usize,
    axis_layer: []SourceOrderDeadRootAxisLayerState,
    domain_axis: []SourceOrderDeadRootDomainAxisState,
    domain_layer: []SourceOrderDeadRootDomainLayerState,
    initial_primary_radius_m_by_domain: []const f64,
    initial_secondary_radius_m_by_domain: []const f64,
    initial_average_secondary_root_length_m: f64,
};

/// Exact GROSUB 11336-11365 root-axis and domain-layer reset.
pub fn sourceOrderResetDeadRootState(
    roots_dead: bool,
    state: SourceOrderDeadRootResetState,
) !void {
    if (state.root_domain_count == 0 or state.soil_layer_count == 0 or
        state.root_axis_count == 0)
        return error.InvalidDeadRootResetDimensions;
    const domain_layers = std.math.mul(
        usize,
        state.root_domain_count,
        state.soil_layer_count,
    ) catch return error.InvalidDeadRootResetDimensions;
    const domain_axes = std.math.mul(
        usize,
        state.root_domain_count,
        state.root_axis_count,
    ) catch return error.InvalidDeadRootResetDimensions;
    const axis_layers = std.math.mul(
        usize,
        domain_layers,
        state.root_axis_count,
    ) catch return error.InvalidDeadRootResetDimensions;
    if (state.axis_layer.len != axis_layers or
        state.domain_axis.len != domain_axes or
        state.domain_layer.len != domain_layers or
        state.initial_primary_radius_m_by_domain.len != state.root_domain_count or
        state.initial_secondary_radius_m_by_domain.len != state.root_domain_count or
        !std.math.isFinite(state.initial_average_secondary_root_length_m) or
        state.initial_average_secondary_root_length_m < 0)
        return error.InvalidDeadRootResetDimensions;

    for (state.initial_primary_radius_m_by_domain, state.initial_secondary_radius_m_by_domain) |primary, secondary| {
        if (!std.math.isFinite(primary) or primary < 0 or
            !std.math.isFinite(secondary) or secondary < 0)
            return error.InvalidDeadRootResetInput;
    }
    for (state.axis_layer) |axis| {
        try validateDeadRootResetMass(axis.primary);
        try validateDeadRootResetMass(axis.secondary);
        inline for (.{ axis.primary_length_m, axis.secondary_length_m, axis.secondary_axis_count }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidDeadRootResetInput;
    }
    for (state.domain_axis) |axis| try validateDeadRootResetMass(axis.primary_total);
    for (state.domain_layer) |layer| {
        try validateDeadRootResetMass(layer.mobile);
        inline for (@typeInfo(SourceOrderDeadRootDomainLayerState).@"struct".fields) |field| {
            if (field.type != f64) continue;
            const value = @field(layer, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidDeadRootResetInput;
        }
    }
    if (!roots_dead) return;

    for (0..state.root_domain_count) |domain| {
        for (0..state.soil_layer_count) |layer| {
            const domain_layer = domain * state.soil_layer_count + layer;
            for (0..state.root_axis_count) |axis| {
                const axis_layer = domain_layer * state.root_axis_count + axis;
                state.axis_layer[axis_layer].primary = .{};
                state.axis_layer[axis_layer].secondary = .{};
                state.domain_axis[domain * state.root_axis_count + axis].primary_total = .{};
                state.axis_layer[axis_layer].primary_length_m = 0;
                state.axis_layer[axis_layer].secondary_length_m = 0;
                state.axis_layer[axis_layer].secondary_axis_count = 0;
            }
            state.domain_layer[domain_layer].mobile = .{};
            state.domain_layer[domain_layer].active_root_carbon_g_c = 0;
            state.domain_layer[domain_layer].actual_root_carbon_g_c = 0;
            state.domain_layer[domain_layer].root_protein_g = 0;
            state.domain_layer[domain_layer].primary_axis_count = 0;
            state.domain_layer[domain_layer].total_axis_count = 0;
            state.domain_layer[domain_layer].root_length_per_plant_m = 0;
            state.domain_layer[domain_layer].root_length_density_m_m3 = 0;
            state.domain_layer[domain_layer].gaseous_volume_m3 = 0;
            state.domain_layer[domain_layer].aqueous_volume_m3 = 0;
            state.domain_layer[domain_layer].primary_radius_m =
                state.initial_primary_radius_m_by_domain[domain];
            state.domain_layer[domain_layer].secondary_radius_m =
                state.initial_secondary_radius_m_by_domain[domain];
            state.domain_layer[domain_layer].root_surface_area_per_plant_m2 = 0;
            state.domain_layer[domain_layer].average_secondary_root_length_m =
                state.initial_average_secondary_root_length_m;
        }
    }
}

pub const SourceOrderDeadNoduleLayerPools = struct {
    structural: canopy.ElementalMass,
    mobile: canopy.ElementalMass,
};

pub const SourceOrderDeadNoduleLitterInput = struct {
    roots_dead: bool,
    nitrogen_fixation_enabled: bool,
    root_domain_count: usize,
    layer_pools: []SourceOrderDeadNoduleLayerPools,
    structural_kinetics: litter_partition.ElementFractions,
    mobile_kinetics: litter_partition.ElementFractions,
};

/// Exact GROSUB 11378-11393 dead-nodule litterfall and clearing.
/// Caller owns the returned runtime-layer slice.
pub fn sourceOrderDeadNoduleLitterfall(
    allocator: std.mem.Allocator,
    input: SourceOrderDeadNoduleLitterInput,
) ![][4]canopy.ElementalMass {
    if (input.root_domain_count == 0 or input.layer_pools.len == 0)
        return error.InvalidDeadNoduleLitterfallDimensions;
    inline for (.{ input.structural_kinetics, input.mobile_kinetics }) |kinetics| {
        inline for (@typeInfo(litter_partition.ElementFractions).@"struct".fields) |field| {
            for (@field(kinetics, field.name)) |fraction|
                if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
                    return error.InvalidDeadNoduleLitterfallInput;
        }
    }
    for (input.layer_pools) |pools| {
        try validateDeadNoduleMass(pools.structural);
        try validateDeadNoduleMass(pools.mobile);
    }

    const litter = try allocator.alloc([4]canopy.ElementalMass, input.layer_pools.len);
    errdefer allocator.free(litter);
    @memset(litter, @splat(.{}));
    if (!input.roots_dead or !input.nitrogen_fixation_enabled) return litter;

    // Preserve the enclosing domain/layer traversal and the source N == 1
    // condition. Nodule pools have layer ownership and are processed once.
    for (0..input.root_domain_count) |domain| {
        if (domain != 0) continue;
        for (input.layer_pools, 0..) |pools, layer| {
            inline for (0..4) |component| {
                inline for (@typeInfo(canopy.ElementalMass).@"struct".fields, 0..) |element, element_index| {
                    const fraction_field =
                        @typeInfo(litter_partition.ElementFractions).@"struct".fields[element_index].name;
                    @field(litter[layer][component], element.name) +=
                        @field(input.structural_kinetics, fraction_field)[component] *
                        @field(pools.structural, element.name) +
                        @field(input.mobile_kinetics, fraction_field)[component] *
                            @field(pools.mobile, element.name);
                    if (!std.math.isFinite(@field(litter[layer][component], element.name)))
                        return error.NonFiniteDeadNoduleLitterfall;
                }
            }
        }
    }
    for (input.layer_pools) |*pools| {
        pools.structural = .{};
        pools.mobile = .{};
    }
    return litter;
}

pub const SourceOrderDeadRootDepthResetState = struct {
    root_domain_count: usize,
    root_axis_count: usize,
    deepest_layer_by_axis: []usize,
    primary_depth_from_surface_m_by_axis_domain: []f64,
    primary_total_by_axis_domain: []canopy.ElementalMass,
    deepest_active_root_layer: *usize,
    active_root_axis_count: *usize,
};

/// Exact GROSUB 11403-11414 dead-root depth and axis-count reset.
pub fn sourceOrderResetDeadRootDepth(
    roots_dead: bool,
    planting_layer_index: usize,
    seed_depth_m: f64,
    state: SourceOrderDeadRootDepthResetState,
) !void {
    if (state.root_domain_count == 0 or
        state.root_axis_count != state.deepest_layer_by_axis.len or
        state.active_root_axis_count.* != state.root_axis_count or
        !std.math.isFinite(seed_depth_m) or seed_depth_m < 0)
        return error.InvalidDeadRootDepthResetDimensions;
    const axis_domains = std.math.mul(
        usize,
        state.root_axis_count,
        state.root_domain_count,
    ) catch return error.InvalidDeadRootDepthResetDimensions;
    if (state.primary_depth_from_surface_m_by_axis_domain.len != axis_domains or
        state.primary_total_by_axis_domain.len != axis_domains)
        return error.InvalidDeadRootDepthResetDimensions;
    for (state.primary_depth_from_surface_m_by_axis_domain) |depth|
        if (!std.math.isFinite(depth) or depth < 0)
            return error.InvalidDeadRootDepthResetInput;
    for (state.primary_total_by_axis_domain) |mass|
        try validateDeadRootDepthMass(mass);
    if (!roots_dead) return;

    for (0..state.root_axis_count) |axis| {
        state.deepest_layer_by_axis[axis] = planting_layer_index;
        for (0..state.root_domain_count) |domain| {
            const axis_domain = axis * state.root_domain_count + domain;
            state.primary_depth_from_surface_m_by_axis_domain[axis_domain] =
                seed_depth_m;
            state.primary_total_by_axis_domain[axis_domain] = .{};
        }
    }
    state.deepest_active_root_layer.* = planting_layer_index;
    state.active_root_axis_count.* = 0;
}
