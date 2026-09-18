//! `plant_root_metabolism` declarations: litter.
//!
//! Split out of `plant_root_metabolism.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const RootState = @import("plant_root_system.zig").State;
const NutrientResult = @import("plant_root_nutrient_uptake.zig").Result;
const root_domain_count = @import("plant_root_system.zig").biological_domain_count;
const group_growth = @import("plant_root_metabolism_growth.zig");
const group_misc = @import("plant_root_metabolism_misc.zig");

pub const RecyclingFractions = struct {
    carbon: f64,
    nitrogen: f64,
    phosphorus: f64,
};

pub const RootWoodComposition = struct {
    carbon_fraction: [2]f64,
    nitrogen_fraction: [2]f64,
    phosphorus_fraction: [2]f64,
    growth_nitrogen_to_carbon_g_n_per_g_c: f64,
    growth_phosphorus_to_carbon_g_p_per_g_c: f64,
};

/// GROSUB FWODR/FWODRN/FWODRP and CNRTW/CPRTW. Array index 0 is woody
/// and index 1 is nonwoody, matching the source equations.
pub fn rootWoodComposition(
    woody_growth_enabled: bool,
    deep_root_profile: bool,
    stalk_carbon_g_c: f64,
    sapwood_carbon_g_c: f64,
    stalk_nitrogen_to_carbon_g_n_per_g_c: f64,
    root_nitrogen_to_carbon_g_n_per_g_c: f64,
    stalk_phosphorus_to_carbon_g_p_per_g_c: f64,
    root_phosphorus_to_carbon_g_p_per_g_c: f64,
    structural_presence_threshold_g_c: f64,
    nonwoody_root_fraction_exponent: f64,
) !RootWoodComposition {
    inline for (.{ stalk_carbon_g_c, sapwood_carbon_g_c, stalk_nitrogen_to_carbon_g_n_per_g_c, root_nitrogen_to_carbon_g_n_per_g_c, stalk_phosphorus_to_carbon_g_p_per_g_c, root_phosphorus_to_carbon_g_p_per_g_c, structural_presence_threshold_g_c, nonwoody_root_fraction_exponent }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootWoodCompositionInput;
    if (sapwood_carbon_g_c > stalk_carbon_g_c + 1.0e-12) return error.RootSapwoodExceedsStalkCarbon;
    const nonwoody = if (!woody_growth_enabled or !deep_root_profile or stalk_carbon_g_c <= structural_presence_threshold_g_c)
        1.0
    else
        std.math.pow(f64, sapwood_carbon_g_c / stalk_carbon_g_c, nonwoody_root_fraction_exponent);
    if (!std.math.isFinite(nonwoody) or nonwoody < 0 or nonwoody > 1) return error.NonFiniteRootWoodComposition;
    const fractions = [2]f64{ 1 - nonwoody, nonwoody };
    return .{
        .carbon_fraction = fractions,
        .nitrogen_fraction = fractions,
        .phosphorus_fraction = fractions,
        .growth_nitrogen_to_carbon_g_n_per_g_c = fractions[0] * stalk_nitrogen_to_carbon_g_n_per_g_c + fractions[1] * root_nitrogen_to_carbon_g_n_per_g_c,
        .growth_phosphorus_to_carbon_g_p_per_g_c = fractions[0] * stalk_phosphorus_to_carbon_g_p_per_g_c + fractions[1] * root_phosphorus_to_carbon_g_p_per_g_c,
    };
}

pub fn secondaryRootRecyclingFractions(
    emerged: bool,
    mobile_carbon_concentration_g_c_per_g_c: f64,
    mobile_nitrogen_concentration_g_n_per_g_c: f64,
    mobile_phosphorus_concentration_g_p_per_g_c: f64,
    parameters: group_growth.SecondaryRootParameters,
) !RecyclingFractions {
    try parameters.validate();
    inline for (.{ mobile_carbon_concentration_g_c_per_g_c, mobile_nitrogen_concentration_g_n_per_g_c, mobile_phosphorus_concentration_g_p_per_g_c }) |value| {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSecondaryRootRecyclingInput;
    }
    var carbon_constraint: f64 = 1;
    var nitrogen_constraint: f64 = 0;
    var phosphorus_constraint: f64 = 0;
    if (emerged and mobile_carbon_concentration_g_c_per_g_c > 0) {
        carbon_constraint = std.math.clamp(@min(
            mobile_nitrogen_concentration_g_n_per_g_c / (mobile_nitrogen_concentration_g_n_per_g_c + mobile_carbon_concentration_g_c_per_g_c * parameters.nitrogen_feedback_half_saturation_g_n_per_g_c),
            mobile_phosphorus_concentration_g_p_per_g_c / (mobile_phosphorus_concentration_g_p_per_g_c + mobile_carbon_concentration_g_c_per_g_c * parameters.phosphorus_feedback_half_saturation_g_p_per_g_c),
        ), 0, 1);
        nitrogen_constraint = std.math.clamp(
            mobile_carbon_concentration_g_c_per_g_c / (mobile_carbon_concentration_g_c_per_g_c + mobile_nitrogen_concentration_g_n_per_g_c / parameters.nitrogen_feedback_half_saturation_g_n_per_g_c),
            0,
            1,
        );
        phosphorus_constraint = std.math.clamp(
            mobile_carbon_concentration_g_c_per_g_c / (mobile_carbon_concentration_g_c_per_g_c + mobile_phosphorus_concentration_g_p_per_g_c / parameters.phosphorus_feedback_half_saturation_g_p_per_g_c),
            0,
            1,
        );
    }
    const result: RecyclingFractions = .{
        .carbon = parameters.minimum_carbon_recycling_fraction + carbon_constraint * parameters.responsive_carbon_recycling_fraction,
        .nitrogen = nitrogen_constraint * parameters.maximum_nitrogen_recycling_fraction,
        .phosphorus = phosphorus_constraint * parameters.maximum_phosphorus_recycling_fraction,
    };
    inline for (@typeInfo(RecyclingFractions).@"struct".fields) |field| {
        const value = @field(result, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSecondaryRootRecyclingFraction;
    }
    return result;
}

pub const SecondaryRootSenescenceInputs = struct {
    oxygen_unlimited_substrate_minus_maintenance_g_c_per_h: f64,
    actual_substrate_minus_maintenance_g_c_per_h: f64,
    root_carbon_g_c: f64,
    root_nitrogen_g_n: f64,
    root_phosphorus_g_p: f64,
    oxygen_limitation: f64,
    phenological_remobilization_enabled: bool,
    root_remobilization_enabled: bool,
    storage_exchange_fraction_per_h: f64,
    remobilization_elapsed_h: f64,
    full_senescence_h: f64,
    biological_timestep_h: f64,
    structural_presence_threshold_g_c: f64,
};

pub const SecondaryRootSenescence = struct {
    respiration_oxygen_unlimited_g_c_per_h: f64,
    respiration_actual_g_c_per_h: f64,
    phenological_senescence_g_c_per_h: f64,
    senesced_fraction: f64,
    recyclable_carbon_g_c: f64,
    recyclable_nitrogen_g_n: f64,
    recyclable_phosphorus_g_p: f64,
};

/// Exact GROSUB SNCRM/SNCR/SNCZ and RCCR/RCZR/RCPR/FSNC2 block.
pub fn secondaryRootSenescence(inputs: SecondaryRootSenescenceInputs, recycling: RecyclingFractions) !SecondaryRootSenescence {
    inline for (@typeInfo(SecondaryRootSenescenceInputs).@"struct".fields) |field| {
        if (field.type == bool) continue;
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteSecondaryRootSenescenceInput;
    }
    inline for (.{ inputs.root_carbon_g_c, inputs.root_nitrogen_g_n, inputs.root_phosphorus_g_p, inputs.oxygen_limitation, inputs.storage_exchange_fraction_per_h, inputs.remobilization_elapsed_h, inputs.full_senescence_h, inputs.biological_timestep_h, inputs.structural_presence_threshold_g_c }) |value| if (value < 0) return error.InvalidSecondaryRootSenescenceInput;
    if (inputs.full_senescence_h == 0 or inputs.biological_timestep_h == 0 or inputs.oxygen_limitation > 1) return error.InvalidSecondaryRootSenescenceInput;
    inline for (@typeInfo(RecyclingFractions).@"struct".fields) |field| {
        const value = @field(recycling, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSecondaryRootRecyclingFraction;
    }

    const recyclable_carbon = inputs.root_carbon_g_c * recycling.carbon;
    const recyclable_nitrogen = inputs.root_nitrogen_g_n * (recycling.nitrogen + (1 - recycling.nitrogen) * recycling.carbon);
    const recyclable_phosphorus = inputs.root_phosphorus_g_p * (recycling.phosphorus + (1 - recycling.phosphorus) * recycling.carbon);
    const oxygen_unlimited_deficit = @max(0, -inputs.oxygen_unlimited_substrate_minus_maintenance_g_c_per_h);
    const actual_deficit = @max(0, -inputs.actual_substrate_minus_maintenance_g_c_per_h);
    const oxygen_unlimited_respiration = @min(oxygen_unlimited_deficit, recyclable_carbon);
    var actual_respiration = if (actual_deficit < recyclable_carbon)
        actual_deficit
    else
        recyclable_carbon * inputs.oxygen_limitation;
    const phenological = if (inputs.phenological_remobilization_enabled and inputs.root_remobilization_enabled)
        inputs.storage_exchange_fraction_per_h * inputs.root_carbon_g_c *
            @min(1, inputs.remobilization_elapsed_h / inputs.full_senescence_h) * inputs.biological_timestep_h
    else
        0;
    actual_respiration += phenological;
    const senesced_fraction = if (actual_respiration > 0 and inputs.root_carbon_g_c > inputs.structural_presence_threshold_g_c)
        (if (recyclable_carbon > inputs.structural_presence_threshold_g_c)
            std.math.clamp(actual_respiration / recyclable_carbon, 0, 1)
        else
            1)
    else
        0;
    return .{
        .respiration_oxygen_unlimited_g_c_per_h = oxygen_unlimited_respiration,
        .respiration_actual_g_c_per_h = actual_respiration,
        .phenological_senescence_g_c_per_h = phenological,
        .senesced_fraction = senesced_fraction,
        .recyclable_carbon_g_c = if (senesced_fraction > 0) recyclable_carbon else 0,
        .recyclable_nitrogen_g_n = if (senesced_fraction > 0) recyclable_nitrogen else 0,
        .recyclable_phosphorus_g_p = if (senesced_fraction > 0) recyclable_phosphorus else 0,
    };
}

/// GROSUB 6684--6718 primary-root senescence has no SNCZ phenological term.
/// Keep the shared deficit equations while explicitly disabling the
/// secondary-root-only remobilization branch.
pub fn primaryRootSenescence(inputs: SecondaryRootSenescenceInputs, recycling: RecyclingFractions) !SecondaryRootSenescence {
    var primary_inputs = inputs;
    primary_inputs.phenological_remobilization_enabled = false;
    primary_inputs.root_remobilization_enabled = false;
    return secondaryRootSenescence(primary_inputs, recycling);
}

pub const RootLitterFractions = struct {
    woody_carbon: [4]f64,
    woody_nitrogen: [4]f64,
    woody_phosphorus: [4]f64,
    nonwoody_carbon: [4]f64,
    nonwoody_nitrogen: [4]f64,
    nonwoody_phosphorus: [4]f64,
};

pub const RootLitter = struct {
    woody_carbon_g_c: [4]f64,
    woody_nitrogen_g_n: [4]f64,
    woody_phosphorus_g_p: [4]f64,
    nonwoody_carbon_g_c: [4]f64,
    nonwoody_nitrogen_g_n: [4]f64,
    nonwoody_phosphorus_g_p: [4]f64,
};

pub const MycorrhizalLossState = struct {
    structural_carbon_g_c: f64,
    structural_nitrogen_g_n: f64,
    structural_phosphorus_g_p: f64,
    length_m: f64,
    mobile_carbon_g_c: f64,
    mobile_nitrogen_g_n: f64,
    mobile_phosphorus_g_p: f64,
};

pub const MycorrhizalLossResult = struct {
    remaining: MycorrhizalLossState,
    litter: RootLitter,
    structural_loss_fraction: f64,
    mobile_loss_fraction: f64,
};

/// GROSUB concurrent mycorrhizal loss when negative primary-root growth is
/// absorbed by host secondary roots. Structural and mobile loss fractions use
/// the source model's distinct secondary-root and total-active-root C bases.
pub fn mycorrhizalLossWithSecondaryRoots(
    negative_primary_growth_g_c: f64,
    host_secondary_carbon_g_c: f64,
    host_active_root_carbon_g_c: f64,
    presence_threshold_g_c: f64,
    state: MycorrhizalLossState,
    woody_fraction: [3][2]f64,
    kinetics: RootLitterFractions,
) !MycorrhizalLossResult {
    inline for (.{ negative_primary_growth_g_c, host_secondary_carbon_g_c, host_active_root_carbon_g_c, presence_threshold_g_c }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteMycorrhizalLossInput;
    if (host_secondary_carbon_g_c < 0 or host_active_root_carbon_g_c < 0 or presence_threshold_g_c < 0)
        return error.InvalidMycorrhizalLossInput;
    inline for (@typeInfo(MycorrhizalLossState).@"struct".fields) |field| {
        const value = @field(state, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidMycorrhizalLossInput;
    }
    for (woody_fraction) |fractions| for (fractions) |value|
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidMycorrhizalLossInput;
    inline for (@typeInfo(RootLitterFractions).@"struct".fields) |field| for (@field(kinetics, field.name)) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidMycorrhizalLossInput;

    const deficit_g_c = @max(0, -negative_primary_growth_g_c);
    const structural_fraction = if (deficit_g_c == 0) 0 else if (host_secondary_carbon_g_c > presence_threshold_g_c)
        @min(1, deficit_g_c / host_secondary_carbon_g_c)
    else
        1;
    const mobile_fraction = if (deficit_g_c == 0) 0 else if (host_active_root_carbon_g_c > presence_threshold_g_c)
        @min(1, deficit_g_c / host_active_root_carbon_g_c)
    else
        1;

    var litter = std.mem.zeroes(RootLitter);
    for (0..4) |kinetic| {
        litter.woody_carbon_g_c[kinetic] = kinetics.woody_carbon[kinetic] * structural_fraction * state.structural_carbon_g_c * woody_fraction[0][0];
        litter.woody_nitrogen_g_n[kinetic] = kinetics.woody_nitrogen[kinetic] * structural_fraction * state.structural_nitrogen_g_n * woody_fraction[1][0];
        litter.woody_phosphorus_g_p[kinetic] = kinetics.woody_phosphorus[kinetic] * structural_fraction * state.structural_phosphorus_g_p * woody_fraction[2][0];
        litter.nonwoody_carbon_g_c[kinetic] = kinetics.nonwoody_carbon[kinetic] *
            (structural_fraction * state.structural_carbon_g_c * woody_fraction[0][1] + mobile_fraction * state.mobile_carbon_g_c);
        litter.nonwoody_nitrogen_g_n[kinetic] = kinetics.nonwoody_nitrogen[kinetic] *
            (structural_fraction * state.structural_nitrogen_g_n * woody_fraction[1][1] + mobile_fraction * state.mobile_nitrogen_g_n);
        litter.nonwoody_phosphorus_g_p[kinetic] = kinetics.nonwoody_phosphorus[kinetic] *
            (structural_fraction * state.structural_phosphorus_g_p * woody_fraction[2][1] + mobile_fraction * state.mobile_phosphorus_g_p);
    }
    const structural_retained = 1 - structural_fraction;
    const mobile_retained = 1 - mobile_fraction;
    const remaining: MycorrhizalLossState = .{
        .structural_carbon_g_c = state.structural_carbon_g_c * structural_retained,
        .structural_nitrogen_g_n = state.structural_nitrogen_g_n * structural_retained,
        .structural_phosphorus_g_p = state.structural_phosphorus_g_p * structural_retained,
        .length_m = state.length_m * structural_retained,
        .mobile_carbon_g_c = state.mobile_carbon_g_c * mobile_retained,
        .mobile_nitrogen_g_n = state.mobile_nitrogen_g_n * mobile_retained,
        .mobile_phosphorus_g_p = state.mobile_phosphorus_g_p * mobile_retained,
    };
    return .{
        .remaining = remaining,
        .litter = litter,
        .structural_loss_fraction = structural_fraction,
        .mobile_loss_fraction = mobile_fraction,
    };
}

pub const LayerPairRootLitter = struct {
    current: RootLitter = std.mem.zeroes(RootLitter),
    upper: RootLitter = std.mem.zeroes(RootLitter),
};

fn addRootLitter(total: *RootLitter, addition: RootLitter) !void {
    inline for (@typeInfo(RootLitter).@"struct".fields) |field| {
        for (&@field(total.*, field.name), @field(addition, field.name)) |*destination, value| {
            destination.* += value;
            if (!std.math.isFinite(destination.*) or destination.* < 0) return error.NonFiniteMycorrhizalLoss;
        }
    }
}

/// Applies all source-order GROSUB mycorrhizal losses associated with the
/// staged host-root deficit plans for one primary-root tip layer.
pub fn state_updateMycorrhizalLossWithSecondaryRoots(
    roots: *RootState,
    plant: usize,
    layer: usize,
    workspace: group_misc.AxisWorkspace,
    active_axis_count: usize,
    host_active_root_carbon_g_c_by_layer: [2]f64,
    presence_threshold_g_c: f64,
    woody_fraction: [3][2]f64,
    kinetics: RootLitterFractions,
) !LayerPairRootLitter {
    if (active_axis_count > workspace.axis_capacity or active_axis_count > roots.root_axis_count)
        return error.RootMetabolismWorkspaceCapacityExceeded;
    if (layer >= roots.soil_layer_count) return error.RootMetabolismLayerOutOfBounds;
    var litter: LayerPairRootLitter = .{};
    const current_root = try roots.layerIndex(plant, 1, layer);
    const upper_root = if (layer > 0) try roots.layerIndex(plant, 1, layer - 1) else current_root;
    var virtual_mobile = [2][3]f64{
        .{ roots.mobile_carbon_g[current_root], roots.mobile_nitrogen_g[current_root], roots.mobile_phosphorus_g[current_root] },
        .{ roots.mobile_carbon_g[upper_root], roots.mobile_nitrogen_g[upper_root], roots.mobile_phosphorus_g[upper_root] },
    };

    // Validate and accumulate the complete two-layer transaction before any
    // state is changed. Shared mobile pools are advanced virtually in axis order.
    for (0..active_axis_count) |axis| {
        if (!workspace.primary_deficit_active[axis]) continue;
        const absorption = workspace.primary_deficit_absorption[axis];
        for (0..2) |layer_offset| {
            if (layer_offset == 1 and layer == 0) continue;
            const affected_layer = layer - layer_offset;
            const axis_layer = try roots.layerAxisIndex(plant, 1, affected_layer, axis);
            _ = try roots.layerIndex(plant, 1, affected_layer);
            const entering_deficit = if (layer_offset == 0)
                absorption.current_entering_carbon_deficit_g_c
            else
                absorption.upper_entering_carbon_deficit_g_c;
            const host_remaining = if (layer_offset == 0) absorption.current.carbon_g_c else absorption.upper.carbon_g_c;
            const result = try mycorrhizalLossWithSecondaryRoots(
                -entering_deficit,
                host_remaining,
                host_active_root_carbon_g_c_by_layer[layer_offset],
                presence_threshold_g_c,
                .{
                    .structural_carbon_g_c = roots.axis_secondary_carbon_g[axis_layer],
                    .structural_nitrogen_g_n = roots.axis_secondary_nitrogen_g[axis_layer],
                    .structural_phosphorus_g_p = roots.axis_secondary_phosphorus_g[axis_layer],
                    .length_m = roots.axis_secondary_length_m[axis_layer],
                    .mobile_carbon_g_c = virtual_mobile[layer_offset][0],
                    .mobile_nitrogen_g_n = virtual_mobile[layer_offset][1],
                    .mobile_phosphorus_g_p = virtual_mobile[layer_offset][2],
                },
                woody_fraction,
                kinetics,
            );
            virtual_mobile[layer_offset] = .{
                result.remaining.mobile_carbon_g_c,
                result.remaining.mobile_nitrogen_g_n,
                result.remaining.mobile_phosphorus_g_p,
            };
            try addRootLitter(if (layer_offset == 0) &litter.current else &litter.upper, result.litter);
        }
    }

    for (0..active_axis_count) |axis| {
        if (!workspace.primary_deficit_active[axis]) continue;
        const absorption = workspace.primary_deficit_absorption[axis];
        for (0..2) |layer_offset| {
            if (layer_offset == 1 and layer == 0) continue;
            const affected_layer = layer - layer_offset;
            const axis_layer = roots.layerAxisIndex(plant, 1, affected_layer, axis) catch unreachable;
            const root_layer = roots.layerIndex(plant, 1, affected_layer) catch unreachable;
            const entering_deficit = if (layer_offset == 0)
                absorption.current_entering_carbon_deficit_g_c
            else
                absorption.upper_entering_carbon_deficit_g_c;
            const host_remaining = if (layer_offset == 0) absorption.current.carbon_g_c else absorption.upper.carbon_g_c;
            const result = mycorrhizalLossWithSecondaryRoots(
                -entering_deficit,
                host_remaining,
                host_active_root_carbon_g_c_by_layer[layer_offset],
                presence_threshold_g_c,
                .{
                    .structural_carbon_g_c = roots.axis_secondary_carbon_g[axis_layer],
                    .structural_nitrogen_g_n = roots.axis_secondary_nitrogen_g[axis_layer],
                    .structural_phosphorus_g_p = roots.axis_secondary_phosphorus_g[axis_layer],
                    .length_m = roots.axis_secondary_length_m[axis_layer],
                    .mobile_carbon_g_c = roots.mobile_carbon_g[root_layer],
                    .mobile_nitrogen_g_n = roots.mobile_nitrogen_g[root_layer],
                    .mobile_phosphorus_g_p = roots.mobile_phosphorus_g[root_layer],
                },
                woody_fraction,
                kinetics,
            ) catch unreachable;
            roots.axis_secondary_carbon_g[axis_layer] = result.remaining.structural_carbon_g_c;
            roots.axis_secondary_nitrogen_g[axis_layer] = result.remaining.structural_nitrogen_g_n;
            roots.axis_secondary_phosphorus_g[axis_layer] = result.remaining.structural_phosphorus_g_p;
            roots.axis_secondary_length_m[axis_layer] = result.remaining.length_m;
            roots.mobile_carbon_g[root_layer] = result.remaining.mobile_carbon_g_c;
            roots.mobile_nitrogen_g[root_layer] = result.remaining.mobile_nitrogen_g_n;
            roots.mobile_phosphorus_g[root_layer] = result.remaining.mobile_phosphorus_g_p;
        }
    }
    return litter;
}

/// GROSUB CSNC/ZSNC/PSNC secondary-root allocation across the four kinetic
/// litter fractions. Mg and mg do not appear here: all masses are grams.
pub fn secondaryRootLitter(
    senescence: SecondaryRootSenescence,
    root_carbon_g_c: f64,
    root_nitrogen_g_n: f64,
    root_phosphorus_g_p: f64,
    woody_carbon_fraction: [2]f64,
    woody_nitrogen_fraction: [2]f64,
    woody_phosphorus_fraction: [2]f64,
    kinetics: RootLitterFractions,
) !RootLitter {
    inline for (.{ root_carbon_g_c, root_nitrogen_g_n, root_phosphorus_g_p }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSecondaryRootLitterInput;
    inline for (.{ woody_carbon_fraction, woody_nitrogen_fraction, woody_phosphorus_fraction }) |fractions| for (fractions) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSecondaryRootLitterInput;
    inline for (@typeInfo(RootLitterFractions).@"struct".fields) |field| for (@field(kinetics, field.name)) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSecondaryRootLitterInput;
    inline for (@typeInfo(SecondaryRootSenescence).@"struct".fields) |field| if (!std.math.isFinite(@field(senescence, field.name)) or @field(senescence, field.name) < 0) return error.InvalidSecondaryRootLitterInput;
    if (senescence.senesced_fraction > 1 or
        senescence.recyclable_carbon_g_c > root_carbon_g_c or
        senescence.recyclable_nitrogen_g_n > root_nitrogen_g_n or
        senescence.recyclable_phosphorus_g_p > root_phosphorus_g_p)
        return error.SecondaryRootLitterWouldOverdraw;

    var result: RootLitter = undefined;
    for (0..4) |kinetic| {
        result.woody_carbon_g_c[kinetic] = kinetics.woody_carbon[kinetic] * senescence.senesced_fraction * root_carbon_g_c * woody_carbon_fraction[0];
        result.woody_nitrogen_g_n[kinetic] = kinetics.woody_nitrogen[kinetic] * senescence.senesced_fraction * root_nitrogen_g_n * woody_nitrogen_fraction[0];
        result.woody_phosphorus_g_p[kinetic] = kinetics.woody_phosphorus[kinetic] * senescence.senesced_fraction * root_phosphorus_g_p * woody_phosphorus_fraction[0];
        result.nonwoody_carbon_g_c[kinetic] = kinetics.nonwoody_carbon[kinetic] * senescence.senesced_fraction * (root_carbon_g_c - senescence.recyclable_carbon_g_c) * woody_carbon_fraction[1];
        result.nonwoody_nitrogen_g_n[kinetic] = kinetics.nonwoody_nitrogen[kinetic] * senescence.senesced_fraction * (root_nitrogen_g_n - senescence.recyclable_nitrogen_g_n) * woody_nitrogen_fraction[1];
        result.nonwoody_phosphorus_g_p[kinetic] = kinetics.nonwoody_phosphorus[kinetic] * senescence.senesced_fraction * (root_phosphorus_g_p - senescence.recyclable_phosphorus_g_p) * woody_phosphorus_fraction[1];
    }
    inline for (@typeInfo(RootLitter).@"struct".fields) |field| for (@field(result, field.name)) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteSecondaryRootLitter;
    return result;
}

test "secondary root litter rejects sub-legacy-tolerance recyclable overdraw" {
    const senescence: SecondaryRootSenescence = .{
        .respiration_oxygen_unlimited_g_c_per_h = 0,
        .respiration_actual_g_c_per_h = 0,
        .phenological_senescence_g_c_per_h = 0,
        .senesced_fraction = 1,
        .recyclable_carbon_g_c = 1.0 + 5.0e-13,
        .recyclable_nitrogen_g_n = 0,
        .recyclable_phosphorus_g_p = 0,
    };
    const fractions: RootLitterFractions = .{
        .woody_carbon = .{ 1, 0, 0, 0 },
        .woody_nitrogen = .{ 1, 0, 0, 0 },
        .woody_phosphorus = .{ 1, 0, 0, 0 },
        .nonwoody_carbon = .{ 1, 0, 0, 0 },
        .nonwoody_nitrogen = .{ 1, 0, 0, 0 },
        .nonwoody_phosphorus = .{ 1, 0, 0, 0 },
    };
    try std.testing.expectError(
        error.SecondaryRootLitterWouldOverdraw,
        secondaryRootLitter(senescence, 1, 0.1, 0.01, .{ 0, 1 }, .{ 0, 1 }, .{ 0, 1 }, fractions),
    );
}
