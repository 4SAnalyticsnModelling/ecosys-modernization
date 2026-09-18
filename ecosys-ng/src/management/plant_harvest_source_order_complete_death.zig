//! `plant_harvest_source_order` declarations: complete death.
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
const group_dead_root = @import("plant_harvest_source_order_dead_root.zig");
const group_misc = @import("plant_harvest_source_order_misc.zig");
const group_tillage = @import("plant_harvest_source_order_tillage.zig");

pub const validateCompleteDeathMass = __parent.validateCompleteDeathMass;
pub const validateCompleteDeathResultMass = __parent.validateCompleteDeathResultMass;

pub const SourceOrderWholePlantTerminationState = struct {
    shoot_alive: bool,
    root_alive: bool,
    total_node_count: usize,
    hours_below_leaf_turgor_threshold_h: f64,
    main_stalk_diameter_m: f64,
    branch_count: usize,
    living_population_per_m2: f64,
    living_population_count: f64,
    hypocotyl_height_m: f64,
};

pub const SourceOrderWholePlantTerminationResult = struct {
    state: SourceOrderWholePlantTerminationState,
    dead_branch_count: usize,
    all_branches_dead: bool,
};

/// Exact GROSUB 11221-11240 all-dead branch count and plant transition.
pub fn sourceOrderWholePlantTermination(
    branch_is_dead: []const bool,
    winter_annual: bool,
    current: SourceOrderWholePlantTerminationState,
) !SourceOrderWholePlantTerminationResult {
    if (current.branch_count != branch_is_dead.len or
        !std.math.isFinite(current.hours_below_leaf_turgor_threshold_h) or
        current.hours_below_leaf_turgor_threshold_h < 0 or
        !std.math.isFinite(current.main_stalk_diameter_m) or
        current.main_stalk_diameter_m < 0 or
        !std.math.isFinite(current.living_population_per_m2) or
        current.living_population_per_m2 < 0 or
        !std.math.isFinite(current.living_population_count) or
        current.living_population_count < 0 or
        !std.math.isFinite(current.hypocotyl_height_m) or
        current.hypocotyl_height_m < 0)
        return error.InvalidWholePlantTerminationInput;

    var dead_branch_count: usize = 0;
    for (branch_is_dead) |is_dead| {
        if (is_dead) dead_branch_count += 1;
    }
    if (dead_branch_count != current.branch_count) return .{
        .state = current,
        .dead_branch_count = dead_branch_count,
        .all_branches_dead = false,
    };

    var state = current;
    state.shoot_alive = false;
    state.root_alive = false;
    state.total_node_count = 0;
    state.hours_below_leaf_turgor_threshold_h = 0;
    state.main_stalk_diameter_m = 0;
    if (winter_annual) {
        state.branch_count = 1;
    } else {
        state.branch_count = 0;
        state.living_population_per_m2 = 0;
        state.living_population_count = 0;
    }
    state.hypocotyl_height_m = 0;
    return .{
        .state = state,
        .dead_branch_count = dead_branch_count,
        .all_branches_dead = true,
    };
}

pub const SourceOrderCompleteDeathBranchPools = struct {
    host_mobile: canopy.ElementalMass,
    symbiont_mobile: canopy.ElementalMass,
    c4_intermediate_carbon_g_c: f64,
    leaf: canopy.ElementalMass,
    symbiont_structural: canopy.ElementalMass,
    sheath: canopy.ElementalMass,
    husk: canopy.ElementalMass,
    ear: canopy.ElementalMass,
    grain: canopy.ElementalMass,
    stalk: canopy.ElementalMass,
    stalk_reserve: canopy.ElementalMass,
};

pub const SourceOrderCompleteDeathShootInput = struct {
    shoot_dead: bool,
    roots_dead: bool,
    perennial_growth_habit: bool,
    deciduous_phenology: bool,
    seasonal_storage: canopy.ElementalMass,
    branches: []const SourceOrderCompleteDeathBranchPools,
    root_woody_fraction: group_tillage.TillageElementComposition,
    leaf_woody_fraction: group_tillage.TillageElementComposition,
    sheath_woody_fraction: group_tillage.TillageElementComposition,
    nonstructural_kinetics: litter_partition.ElementFractions,
    foliar_kinetics: litter_partition.ElementFractions,
    nonfoliar_kinetics: litter_partition.ElementFractions,
    stalk_kinetics: litter_partition.ElementFractions,
    coarse_wood_kinetics: litter_partition.ElementFractions,
};

pub const SourceOrderCompleteDeathShootResult = struct {
    planting_layer_woody_litter: [4]canopy.ElementalMass,
    planting_layer_nonwoody_litter: [4]canopy.ElementalMass,
    surface_woody_litter: [4]canopy.ElementalMass,
    surface_nonwoody_litter: [4]canopy.ElementalMass,
    standing_dead_stalk: [4]canopy.ElementalMass,
    seasonal_storage: canopy.ElementalMass,
    plant_death_initialized: bool,
};

/// Exact GROSUB 11443-11518 complete-death storage and shoot litterfall.
pub fn sourceOrderCompleteDeathShootLitterfall(
    input: SourceOrderCompleteDeathShootInput,
) !SourceOrderCompleteDeathShootResult {
    try validateCompleteDeathMass(input.seasonal_storage);
    for (input.branches) |branch| {
        inline for (@typeInfo(SourceOrderCompleteDeathBranchPools).@"struct".fields) |field| {
            const value = @field(branch, field.name);
            if (field.type == f64) {
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidCompleteDeathShootLitterfallInput;
            } else try validateCompleteDeathMass(value);
        }
    }
    inline for (.{
        input.root_woody_fraction,
        input.leaf_woody_fraction,
        input.sheath_woody_fraction,
    }) |composition| inline for (@typeInfo(group_tillage.TillageElementComposition).@"struct".fields) |field|
        for (@field(composition, field.name)) |fraction|
            if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
                return error.InvalidCompleteDeathShootLitterfallInput;
    inline for (.{
        input.nonstructural_kinetics,
        input.foliar_kinetics,
        input.nonfoliar_kinetics,
        input.stalk_kinetics,
        input.coarse_wood_kinetics,
    }) |kinetics| inline for (@typeInfo(litter_partition.ElementFractions).@"struct".fields) |field|
        for (@field(kinetics, field.name)) |fraction|
            if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
                return error.InvalidCompleteDeathShootLitterfallInput;

    var result: SourceOrderCompleteDeathShootResult = .{
        .planting_layer_woody_litter = @splat(.{}),
        .planting_layer_nonwoody_litter = @splat(.{}),
        .surface_woody_litter = @splat(.{}),
        .surface_nonwoody_litter = @splat(.{}),
        .standing_dead_stalk = @splat(.{}),
        .seasonal_storage = input.seasonal_storage,
        .plant_death_initialized = false,
    };
    if (!input.shoot_dead or !input.roots_dead) return result;

    const winter_annual = !input.perennial_growth_habit and input.deciduous_phenology;
    if (input.perennial_growth_habit or !input.deciduous_phenology) {
        result.plant_death_initialized = true;
        inline for (0..4) |component| {
            inline for (@typeInfo(canopy.ElementalMass).@"struct".fields, 0..) |element, index| {
                const name =
                    @typeInfo(litter_partition.ElementFractions).@"struct".fields[index].name;
                const storage = @field(input.seasonal_storage, element.name);
                const wood = @field(input.root_woody_fraction, name);
                const kinetic = @field(input.nonstructural_kinetics, name)[component];
                @field(result.planting_layer_woody_litter[component], element.name) +=
                    kinetic * storage * wood[0];
                @field(result.planting_layer_nonwoody_litter[component], element.name) +=
                    kinetic * storage * wood[1];
            }
        }
        result.seasonal_storage = .{};
    }

    inline for (0..4) |component| {
        for (input.branches) |branch| {
            inline for (@typeInfo(canopy.ElementalMass).@"struct".fields, 0..) |element, index| {
                const name =
                    @typeInfo(litter_partition.ElementFractions).@"struct".fields[index].name;
                const leaf_wood = @field(input.leaf_woody_fraction, name);
                const sheath_wood = @field(input.sheath_woody_fraction, name);
                var mobile = @field(branch.host_mobile, element.name) +
                    @field(branch.symbiont_mobile, element.name);
                if (index == 0) mobile += branch.c4_intermediate_carbon_g_c;
                @field(result.surface_nonwoody_litter[component], element.name) +=
                    @field(input.nonstructural_kinetics, name)[component] * mobile;
                @field(result.surface_nonwoody_litter[component], element.name) +=
                    @field(input.foliar_kinetics, name)[component] *
                    (@field(branch.leaf, element.name) * leaf_wood[1] +
                        @field(branch.symbiont_structural, element.name));
                @field(result.surface_nonwoody_litter[component], element.name) +=
                    @field(input.nonfoliar_kinetics, name)[component] *
                    (@field(branch.sheath, element.name) * sheath_wood[1] +
                        @field(branch.husk, element.name) +
                        @field(branch.ear, element.name));
                @field(result.surface_woody_litter[component], element.name) +=
                    @field(input.coarse_wood_kinetics, name)[component] *
                    (@field(branch.leaf, element.name) * leaf_wood[0] +
                        @field(branch.sheath, element.name) * sheath_wood[0]);
                const grain = @field(input.nonfoliar_kinetics, name)[component] *
                    @field(branch.grain, element.name);
                if (winter_annual) {
                    @field(result.seasonal_storage, element.name) += grain;
                } else {
                    @field(result.surface_nonwoody_litter[component], element.name) += grain;
                }
                @field(result.standing_dead_stalk[component], element.name) +=
                    @field(input.stalk_kinetics, name)[component] *
                    (@field(branch.stalk, element.name) +
                        @field(branch.stalk_reserve, element.name));
            }
        }
    }
    inline for (@typeInfo(SourceOrderCompleteDeathShootResult).@"struct".fields) |field| {
        if (field.type == bool) continue;
        const value = @field(result, field.name);
        if (field.type == canopy.ElementalMass) {
            try validateCompleteDeathResultMass(value);
        } else for (value) |mass| try validateCompleteDeathResultMass(mass);
    }
    return result;
}

pub const SourceOrderCompleteDeathRootInput = struct {
    shoot_dead: bool,
    roots_dead: bool,
    root_domain_count: usize,
    soil_layer_count: usize,
    root_axis_count: usize,
    mobile_by_domain_layer: []const canopy.ElementalMass,
    structural_by_domain_layer_axis: []const group_dead_root.SourceOrderDeadRootAxisPools,
    root_woody_fraction: group_tillage.TillageElementComposition,
    nonstructural_kinetics: litter_partition.ElementFractions,
    fine_root_kinetics: litter_partition.ElementFractions,
    coarse_root_kinetics: litter_partition.ElementFractions,
};

/// Exact GROSUB 11535-11557 complete-death root litterfall.
/// The caller supplies only the active NU:NJ layer range and owns the result.
pub fn sourceOrderCompleteDeathRootLitterfall(
    allocator: std.mem.Allocator,
    input: SourceOrderCompleteDeathRootInput,
) ![]group_dead_root.SourceOrderDeadRootLayerLitter {
    if (input.root_domain_count == 0 or input.soil_layer_count == 0 or
        input.root_axis_count == 0)
        return error.InvalidCompleteDeathRootLitterfallDimensions;
    const domain_layers = std.math.mul(
        usize,
        input.root_domain_count,
        input.soil_layer_count,
    ) catch return error.InvalidCompleteDeathRootLitterfallDimensions;
    const structural_count = std.math.mul(
        usize,
        domain_layers,
        input.root_axis_count,
    ) catch return error.InvalidCompleteDeathRootLitterfallDimensions;
    if (input.mobile_by_domain_layer.len != domain_layers or
        input.structural_by_domain_layer_axis.len != structural_count)
        return error.InvalidCompleteDeathRootLitterfallDimensions;
    inline for (.{
        input.nonstructural_kinetics,
        input.fine_root_kinetics,
        input.coarse_root_kinetics,
    }) |kinetics| inline for (@typeInfo(litter_partition.ElementFractions).@"struct".fields) |field|
        for (@field(kinetics, field.name)) |fraction|
            if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
                return error.InvalidCompleteDeathRootLitterfallInput;
    inline for (@typeInfo(group_tillage.TillageElementComposition).@"struct".fields) |field|
        for (@field(input.root_woody_fraction, field.name)) |fraction|
            if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
                return error.InvalidCompleteDeathRootLitterfallInput;
    for (input.mobile_by_domain_layer) |mass|
        group_misc.validateSourceOrderRootMass(mass) catch
            return error.InvalidCompleteDeathRootLitterfallInput;
    for (input.structural_by_domain_layer_axis) |pools| {
        group_misc.validateSourceOrderRootMass(pools.primary) catch
            return error.InvalidCompleteDeathRootLitterfallInput;
        group_misc.validateSourceOrderRootMass(pools.secondary) catch
            return error.InvalidCompleteDeathRootLitterfallInput;
    }

    const result = try allocator.alloc(
        group_dead_root.SourceOrderDeadRootLayerLitter,
        input.soil_layer_count,
    );
    errdefer allocator.free(result);
    @memset(result, .{ .woody = @splat(.{}), .nonwoody = @splat(.{}) });
    if (!input.shoot_dead or !input.roots_dead) return result;

    inline for (0..4) |component| {
        for (0..input.soil_layer_count) |layer| {
            for (0..input.root_domain_count) |domain| {
                const domain_layer = domain * input.soil_layer_count + layer;
                inline for (@typeInfo(canopy.ElementalMass).@"struct".fields, 0..) |element, index| {
                    const name =
                        @typeInfo(litter_partition.ElementFractions).@"struct".fields[index].name;
                    @field(result[layer].nonwoody[component], element.name) +=
                        @field(input.nonstructural_kinetics, name)[component] *
                        @field(input.mobile_by_domain_layer[domain_layer], element.name);
                }
                for (0..input.root_axis_count) |axis| {
                    const pools = input.structural_by_domain_layer_axis[
                        domain_layer * input.root_axis_count + axis
                    ];
                    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields, 0..) |element, index| {
                        const name =
                            @typeInfo(litter_partition.ElementFractions).@"struct".fields[index].name;
                        const mass = @field(pools.primary, element.name) +
                            @field(pools.secondary, element.name);
                        const woody_fraction = @field(input.root_woody_fraction, name);
                        @field(result[layer].woody[component], element.name) +=
                            @field(input.coarse_root_kinetics, name)[component] *
                            mass * woody_fraction[0];
                        @field(result[layer].nonwoody[component], element.name) +=
                            @field(input.fine_root_kinetics, name)[component] *
                            mass * woody_fraction[1];
                    }
                }
            }
        }
    }
    for (result) |layer| inline for (.{ layer.woody, layer.nonwoody }) |position|
        for (position) |mass| inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
            if (!std.math.isFinite(@field(mass, field.name)))
                return error.NonFiniteCompleteDeathRootLitterfall;
    return result;
}

pub const SourceOrderCompleteDeathBranchState = struct {
    host_mobile: canopy.ElementalMass,
    c4_intermediate_carbon_g_c: f64,
    symbiont_mobile: canopy.ElementalMass,
    shoot: canopy.ElementalMass,
    leaf: canopy.ElementalMass,
    nodule: canopy.ElementalMass,
    sheath: canopy.ElementalMass,
    stalk: canopy.ElementalMass,
    stalk_volume_m3: f64,
    reserve: canopy.ElementalMass,
    husk: canopy.ElementalMass,
    ear: canopy.ElementalMass,
    grain: canopy.ElementalMass,
    leaf_starch_carbon_g_c: f64,
    stalk_extra: canopy.ElementalMass,
};

/// Exact GROSUB 11561-11601 complete-death branch-state reset.
pub fn sourceOrderResetCompleteDeathBranches(
    shoot_dead: bool,
    roots_dead: bool,
    branches: []SourceOrderCompleteDeathBranchState,
) !void {
    for (branches) |branch| {
        inline for (@typeInfo(SourceOrderCompleteDeathBranchState).@"struct".fields) |field| {
            const value = @field(branch, field.name);
            if (field.type == f64) {
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidCompleteDeathBranchState;
            } else inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element| {
                const mass = @field(value, element.name);
                if (!std.math.isFinite(mass) or mass < 0)
                    return error.InvalidCompleteDeathBranchState;
            }
        }
    }
    if (!shoot_dead or !roots_dead) return;
    for (branches) |*branch| branch.* = std.mem.zeroes(SourceOrderCompleteDeathBranchState);
}

pub const SourceOrderCompleteDeathRootResetState = struct {
    root_domain_count: usize,
    soil_layer_count: usize,
    root_axis_count: usize,
    mobile_by_domain_layer: []canopy.ElementalMass,
    structural_by_domain_layer_axis: []group_dead_root.SourceOrderDeadRootAxisLayerState,
    primary_total_by_domain_axis: []group_dead_root.SourceOrderDeadRootDomainAxisState,
};

/// Exact GROSUB 11605-11623 complete-death root-state reset.
pub fn sourceOrderResetCompleteDeathRoots(
    shoot_dead: bool,
    roots_dead: bool,
    state: SourceOrderCompleteDeathRootResetState,
) !void {
    if (state.root_domain_count == 0 or state.soil_layer_count == 0 or
        state.root_axis_count == 0)
        return error.InvalidCompleteDeathRootResetDimensions;
    const domain_layers = std.math.mul(
        usize,
        state.root_domain_count,
        state.soil_layer_count,
    ) catch return error.InvalidCompleteDeathRootResetDimensions;
    const axis_layers = std.math.mul(
        usize,
        domain_layers,
        state.root_axis_count,
    ) catch return error.InvalidCompleteDeathRootResetDimensions;
    const domain_axes = std.math.mul(
        usize,
        state.root_domain_count,
        state.root_axis_count,
    ) catch return error.InvalidCompleteDeathRootResetDimensions;
    if (state.mobile_by_domain_layer.len != domain_layers or
        state.structural_by_domain_layer_axis.len != axis_layers or
        state.primary_total_by_domain_axis.len != domain_axes)
        return error.InvalidCompleteDeathRootResetDimensions;

    for (state.mobile_by_domain_layer) |mass|
        group_dead_root.validateDeadRootResetMass(mass) catch
            return error.InvalidCompleteDeathRootResetInput;
    for (state.structural_by_domain_layer_axis) |axis| {
        group_dead_root.validateDeadRootResetMass(axis.primary) catch
            return error.InvalidCompleteDeathRootResetInput;
        group_dead_root.validateDeadRootResetMass(axis.secondary) catch
            return error.InvalidCompleteDeathRootResetInput;
        inline for (.{ axis.primary_length_m, axis.secondary_length_m, axis.secondary_axis_count }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidCompleteDeathRootResetInput;
    }
    for (state.primary_total_by_domain_axis) |axis|
        group_dead_root.validateDeadRootResetMass(axis.primary_total) catch
            return error.InvalidCompleteDeathRootResetInput;
    if (!shoot_dead or !roots_dead) return;

    for (0..state.soil_layer_count) |layer| {
        for (0..state.root_domain_count) |domain| {
            const domain_layer = domain * state.soil_layer_count + layer;
            state.mobile_by_domain_layer[domain_layer] = .{};
            for (0..state.root_axis_count) |axis| {
                const axis_layer =
                    domain_layer * state.root_axis_count + axis;
                state.structural_by_domain_layer_axis[axis_layer].primary = .{};
                state.structural_by_domain_layer_axis[axis_layer].secondary = .{};
                state.primary_total_by_domain_axis[
                    domain * state.root_axis_count + axis
                ].primary_total = .{};
                state.structural_by_domain_layer_axis[axis_layer].primary_length_m = 0;
                state.structural_by_domain_layer_axis[axis_layer].secondary_length_m = 0;
                state.structural_by_domain_layer_axis[axis_layer].secondary_axis_count = 0;
            }
        }
    }
}

pub const SourceOrderReseedDate = struct {
    day_of_year: u16,
    year: u32,
};

pub const SourceOrderDeadPerennialReseedResult = struct {
    reseed_date: ?SourceOrderReseedDate,
    plant_death_flag: bool,
};

/// Exact GROSUB 11632-11644 dead-perennial reseeding decision.
pub fn sourceOrderScheduleDeadPerennialReseed(
    perennial_growth_habit: bool,
    terminate_on_death: bool,
    current_day_of_year: u16,
    days_in_current_year: u16,
    current_year: u32,
) !SourceOrderDeadPerennialReseedResult {
    if (current_year == 0 or days_in_current_year == 0 or
        current_day_of_year == 0 or current_day_of_year > days_in_current_year)
        return error.InvalidDeadPerennialReseedDate;
    if (!perennial_growth_habit or terminate_on_death) return .{
        .reseed_date = null,
        .plant_death_flag = false,
    };
    if (current_day_of_year < days_in_current_year) return .{
        .reseed_date = .{
            .day_of_year = current_day_of_year + 1,
            .year = current_year,
        },
        .plant_death_flag = true,
    };
    if (current_year == std.math.maxInt(u32))
        return error.DeadPerennialReseedYearOverflow;
    return .{
        .reseed_date = .{ .day_of_year = 1, .year = current_year + 1 },
        .plant_death_flag = true,
    };
}

pub const SourceOrderDormantSeedBranch = struct {
    leafout_disabled: bool,
    accumulated_leafout_h: f64,
    required_leafout_h: f64,
};

pub const SourceOrderDormantSeedActivation = struct {
    qualifying_branch_index: usize,
    planting_day_of_year: u16,
    planting_year: i32,
    seeding_depth_m: f64,
    initialization_pending: bool = false,
};

/// Exact pure decision/state transition in GROSUB 12559-12572.
///
/// `initialization_pending` deliberately models legacy `IFLGI == 1`; callers
/// must not substitute the oppositely ordered production lifecycle flag.
pub fn sourceOrderDormantSeedActivation(
    first_subhour_iteration: bool,
    initialization_pending: bool,
    branches: []const SourceOrderDormantSeedBranch,
    current_day_of_year: u16,
    current_year: i32,
    soil_surface_boundary_depth_m: f64,
) !?SourceOrderDormantSeedActivation {
    if (current_day_of_year == 0 or current_day_of_year > 366 or current_year <= 0)
        return error.InvalidDormantSeedActivationDate;
    if (!std.math.isFinite(soil_surface_boundary_depth_m))
        return error.InvalidDormantSeedActivationDepth;
    const seeding_depth_m = 0.005 + soil_surface_boundary_depth_m;
    if (!std.math.isFinite(seeding_depth_m) or seeding_depth_m < 0)
        return error.InvalidDormantSeedActivationDepth;
    for (branches) |branch| {
        if (!std.math.isFinite(branch.accumulated_leafout_h) or
            !std.math.isFinite(branch.required_leafout_h) or
            branch.accumulated_leafout_h < 0 or branch.required_leafout_h < 0)
            return error.InvalidDormantSeedLeafoutHours;
    }
    if (!first_subhour_iteration or !initialization_pending) return null;
    for (branches, 0..) |branch, branch_index| {
        if (!branch.leafout_disabled and
            branch.accumulated_leafout_h >= branch.required_leafout_h)
            return .{
                .qualifying_branch_index = branch_index,
                .planting_day_of_year = current_day_of_year,
                .planting_year = current_year,
                .seeding_depth_m = seeding_depth_m,
            };
    }
    return null;
}
