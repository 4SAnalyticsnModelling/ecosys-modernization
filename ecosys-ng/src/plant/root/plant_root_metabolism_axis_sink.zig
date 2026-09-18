//! `plant_root_metabolism` declarations: axis sink.
//!
//! Split out of `plant_root_metabolism.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const RootState = @import("plant_root_system.zig").State;
const NutrientResult = @import("plant_root_nutrient_uptake.zig").Result;
const root_domain_count = @import("plant_root_system.zig").biological_domain_count;
const group_growth = @import("plant_root_metabolism_growth.zig");

pub const PrimaryRootAxisScaling = struct {
    retained_root_carbon_g_c_per_plant: f64,
    primary_axis_count_multiplier: f64,
};

/// GROSUB WTRTA/XRTN1 retained root-mass state and primary-axis scaling.
/// The multiplication by the biological timestep preserves the source
/// operation exactly; it is not rewritten as an exponential decay.
pub fn primaryRootAxisScaling(
    previous_retained_root_carbon_g_c_per_plant: f64,
    total_root_carbon_g_c: f64,
    plant_population_count: f64,
    biological_timestep_h: f64,
) !PrimaryRootAxisScaling {
    inline for (.{ previous_retained_root_carbon_g_c_per_plant, total_root_carbon_g_c, plant_population_count, biological_timestep_h }) |value| {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidPrimaryRootAxisScalingInput;
    }
    if (biological_timestep_h <= 0) return error.InvalidPrimaryRootAxisScalingInput;

    const retained = if (plant_population_count > 0)
        @max(
            0.999992087 * previous_retained_root_carbon_g_c_per_plant * biological_timestep_h,
            total_root_carbon_g_c / plant_population_count,
        )
    else
        0.0;
    const axis_multiplier = @max(1.0, std.math.pow(f64, retained, 0.667)) * plant_population_count;
    if (!std.math.isFinite(retained) or !std.math.isFinite(axis_multiplier)) return error.NonFinitePrimaryRootAxisScaling;
    return .{
        .retained_root_carbon_g_c_per_plant = retained,
        .primary_axis_count_multiplier = axis_multiplier,
    };
}

pub const RootAxisSinkInputs = struct {
    root_profile_type: u8,
    primary_axis_count_multiplier: f64,
    primary_root_radius_m: f64,
    primary_root_depth_from_canopy_m: f64,
    secondary_root_depth_from_canopy_m: f64,
    secondary_axis_count: f64,
    secondary_root_radius_m: f64,
    average_secondary_root_length_m: f64,
    primary_biological_domain: bool,
};

pub const SourceOrderRootAxisSinkInputs = struct {
    root_profile_type: u8,
    primary_axis_count_multiplier: f64,
    primary_root_radius_m: f64,
    primary_root_depth_from_surface_m: f64,
    layer_top_depth_m: f64,
    layer_thickness_m: f64,
    secondary_root_origin_offset_m: f64,
    seeding_depth_m: f64,
    hypocotyledon_height_m: f64,
    canopy_height_m: f64,
    secondary_axis_count: f64,
    secondary_root_radius_m: f64,
    average_secondary_root_length_m: f64,
    negligible_sink_m: f64,
    primary_biological_domain: bool,
};

pub const RootAxisSinkStrength = struct {
    primary_m: f64,
    secondary_m: f64,
};

/// GROSUB 6042 secondary-root axis gate. Layer indexes are zero-based in
/// Zig; the source comparison remains inclusive.
pub fn secondaryRootAxisActive(
    current_layer: usize,
    deepest_secondary_root_layer: usize,
    axis_inactive: bool,
) bool {
    return current_layer <= deepest_secondary_root_layer and !axis_inactive;
}

/// GROSUB RTSK1 and RTSK2 for one runtime root axis. Primary-domain
/// secondary roots retain the source harmonic series resistance.
pub fn rootAxisSinkStrength(parameters: group_growth.SecondaryRootParameters, inputs: RootAxisSinkInputs) !RootAxisSinkStrength {
    try parameters.validate();
    if (inputs.root_profile_type > 3) return error.InvalidRootProfileType;
    inline for (@typeInfo(RootAxisSinkInputs).@"struct".fields) |field| {
        if (field.type == bool or field.type == u8) continue;
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidRootAxisSinkInput;
    }
    const profile_multiplier = switch (inputs.root_profile_type) {
        0 => parameters.shallow_primary_root_sink_multiplier,
        1 => parameters.intermediate_primary_root_sink_multiplier,
        2 => parameters.deep_primary_root_sink_multiplier,
        3 => parameters.deeper_primary_root_sink_multiplier,
        else => unreachable,
    };
    const primary = if (inputs.primary_root_depth_from_canopy_m > 0)
        profile_multiplier * inputs.primary_axis_count_multiplier * inputs.primary_root_radius_m * inputs.primary_root_radius_m / inputs.primary_root_depth_from_canopy_m
    else
        0;
    const secondary_parallel = if (inputs.average_secondary_root_length_m > 0)
        inputs.secondary_axis_count * inputs.secondary_root_radius_m * inputs.secondary_root_radius_m / inputs.average_secondary_root_length_m
    else
        0;
    const secondary = if (inputs.primary_biological_domain) blk: {
        if (inputs.secondary_root_depth_from_canopy_m <= 0) break :blk 0;
        const primary_series = inputs.primary_axis_count_multiplier * inputs.primary_root_radius_m * inputs.primary_root_radius_m / inputs.secondary_root_depth_from_canopy_m;
        break :blk if (primary_series + secondary_parallel > 0)
            primary_series * secondary_parallel / (primary_series + secondary_parallel)
        else
            0;
    } else secondary_parallel;
    inline for (.{ primary, secondary }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteRootAxisSinkStrength;
    return .{ .primary_m = primary, .secondary_m = secondary };
}

/// Direct GROSUB 5888--5943 geometry comparator. It retains the primary-tip
/// layer gate and the clipped secondary-root midpoint depth that are not
/// represented by the simplified production operand contract.
pub fn sourceOrderRootAxisSinkStrength(parameters: group_growth.SecondaryRootParameters, inputs: SourceOrderRootAxisSinkInputs) !RootAxisSinkStrength {
    try parameters.validate();
    if (inputs.root_profile_type > 3) return error.InvalidRootProfileType;
    inline for (@typeInfo(SourceOrderRootAxisSinkInputs).@"struct".fields) |field| {
        if (field.type == bool or field.type == u8) continue;
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidRootAxisSinkInput;
    }
    if (inputs.average_secondary_root_length_m <= 0) return error.InvalidRootAxisSinkInput;
    const profile_multiplier = switch (inputs.root_profile_type) {
        0 => parameters.shallow_primary_root_sink_multiplier,
        1 => parameters.intermediate_primary_root_sink_multiplier,
        2 => parameters.deep_primary_root_sink_multiplier,
        3 => parameters.deeper_primary_root_sink_multiplier,
        else => unreachable,
    };
    const layer_bottom_depth_m = inputs.layer_top_depth_m + inputs.layer_thickness_m;
    const primary_depth_from_canopy_m = inputs.primary_root_depth_from_surface_m + inputs.canopy_height_m;
    const tip_in_layer = inputs.primary_root_depth_from_surface_m > inputs.layer_top_depth_m and
        inputs.primary_root_depth_from_surface_m <= layer_bottom_depth_m;
    const primary = if (inputs.primary_biological_domain and tip_in_layer and primary_depth_from_canopy_m > 0)
        profile_multiplier * inputs.primary_axis_count_multiplier *
            inputs.primary_root_radius_m * inputs.primary_root_radius_m / primary_depth_from_canopy_m
    else
        0;
    var rooted_length_m = @max(0, inputs.primary_root_depth_from_surface_m -
        inputs.layer_top_depth_m - inputs.secondary_root_origin_offset_m);
    rooted_length_m = @max(0, @min(inputs.layer_thickness_m, rooted_length_m) -
        @max(0, inputs.seeding_depth_m - inputs.layer_top_depth_m - inputs.hypocotyledon_height_m));
    const secondary_depth_from_canopy_m = @max(inputs.seeding_depth_m, inputs.layer_top_depth_m) +
        0.5 * rooted_length_m + inputs.canopy_height_m;
    const secondary_parallel = inputs.secondary_axis_count *
        inputs.secondary_root_radius_m * inputs.secondary_root_radius_m /
        inputs.average_secondary_root_length_m;
    const secondary = if (inputs.primary_biological_domain) blk: {
        if (secondary_depth_from_canopy_m <= 0) break :blk 0;
        const primary_series = inputs.primary_axis_count_multiplier *
            inputs.primary_root_radius_m * inputs.primary_root_radius_m /
            secondary_depth_from_canopy_m;
        break :blk if (primary_series + secondary_parallel > inputs.negligible_sink_m)
            primary_series * secondary_parallel / (primary_series + secondary_parallel)
        else
            0;
    } else secondary_parallel;
    inline for (.{ primary, secondary }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteRootAxisSinkStrength;
    return .{ .primary_m = primary, .secondary_m = secondary };
}

/// GROSUB FRTN normalization against RLNT. Caller-owned output slices avoid
/// hourly allocation and scale to any runtime axis count.
pub fn normalizeRootAxisSinkFractions(
    strengths: []const RootAxisSinkStrength,
    primary_fractions: []f64,
    secondary_fractions: []f64,
    negligible_sink_m: f64,
) !f64 {
    if (strengths.len != primary_fractions.len or strengths.len != secondary_fractions.len) return error.RootAxisSinkDimensionMismatch;
    if (!std.math.isFinite(negligible_sink_m) or negligible_sink_m < 0) return error.InvalidRootAxisSinkThreshold;
    var total: f64 = 0;
    for (strengths) |strength| {
        inline for (@typeInfo(RootAxisSinkStrength).@"struct".fields) |field| {
            const value = @field(strength, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidRootAxisSinkStrength;
            total += value;
        }
    }
    if (!std.math.isFinite(total)) return error.NonFiniteRootAxisSinkTotal;
    for (strengths, 0..) |strength, axis| {
        // This per-branch fallback of 1.0 is intentionally source-exact.
        primary_fractions[axis] = if (total > negligible_sink_m) strength.primary_m / total else 1;
        secondary_fractions[axis] = if (total > negligible_sink_m) strength.secondary_m / total else 1;
    }
    return total;
}
