//! `plant_root_metabolism` declarations: state_update.
//!
//! Split out of `plant_root_metabolism.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const RootState = @import("plant_root_system.zig").State;
const NutrientResult = @import("plant_root_nutrient_uptake.zig").Result;
const root_domain_count = @import("plant_root_system.zig").biological_domain_count;
const group_growth = @import("plant_root_metabolism_growth.zig");
const group_litter = @import("plant_root_metabolism_litter.zig");
const group_misc = @import("plant_root_metabolism_misc.zig");
const group_respiration = @import("plant_root_metabolism_respiration.zig");

pub const SecondaryRootStateUpdateInputs = struct {
    metabolism: group_growth.SecondaryRootResult,
    senescence: group_litter.SecondaryRootSenescence,
    root_specific_length_m_per_g_c: f64,
    root_extension_water_response: f64,
    nonwoody_carbon_fraction: f64,
    nonwoody_nitrogen_fraction: f64,
    nonwoody_phosphorus_fraction: f64,
    protein_carbon_per_nitrogen_g_c_per_g_n: f64,
    protein_carbon_per_phosphorus_g_c_per_g_p: f64,
};

pub const PrimaryRootStateUpdateInputs = struct {
    metabolism: group_growth.SecondaryRootResult,
    senescence: group_litter.SecondaryRootSenescence,
    primary_specific_length_m_per_g_c: f64,
    root_extension_water_response: f64,
    nonwoody_carbon_fraction: f64,
    nonwoody_nitrogen_fraction: f64,
    nonwoody_phosphorus_fraction: f64,
    protein_carbon_per_nitrogen_g_c_per_g_n: f64,
    protein_carbon_per_phosphorus_g_c_per_g_p: f64,
};

pub const StagedLayerStateUpdateParameters = struct {
    primary_specific_length_m_per_g_c: f64,
    secondary_specific_length_m_per_g_c: f64,
    plant_population_count: f64,
    seeding_depth_m: f64,
    current_layer_bottom_depth_m: f64,
    /// GROSUB L1 selected by scanning past DLYR<=DLYRM layers. Null only when
    /// the current layer has no lower profile layer.
    next_lower_layer: ?usize = null,
    next_layer_thickness_m: f64,
    extension_presence_threshold_m: f64,
    root_extension_water_response: f64,
    nonwoody_carbon_fraction: f64,
    nonwoody_nitrogen_fraction: f64,
    nonwoody_phosphorus_fraction: f64,
    protein_carbon_per_nitrogen_g_c_per_g_n: f64,
    protein_carbon_per_phosphorus_g_c_per_g_p: f64,
    primary_axis_count_multiplier: f64 = 0,
    secondary_root_branching_per_m: f64 = 0,
    current_layer_thickness_m: f64 = 0,
};

/// GROSUB 6424--6427. `RTN2X` is the first branching order and `RTN2Y`
/// the second; the stored count is the contribution of one primary axis to
/// the layer total (`RTNL`).
pub fn sourceOrderSecondaryAxisCount(
    branching_per_m: f64,
    primary_axis_count_multiplier: f64,
    layer_thickness_m: f64,
) !f64 {
    inline for (.{ branching_per_m, primary_axis_count_multiplier, layer_thickness_m }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSecondaryRootAxisCountInput;
    const first_order = branching_per_m * primary_axis_count_multiplier;
    const second_order = branching_per_m * first_order;
    const count = (first_order + second_order) * layer_thickness_m;
    if (!std.math.isFinite(count)) return error.NonFiniteSecondaryRootAxisCount;
    return count;
}

pub const PrimaryRootExtensionPlacement = struct {
    extension_m: f64,
    crosses_into_next_layer: bool,
};

pub const SecondaryRootDeficitLayer = struct {
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
    length_m: f64,
};

pub const SecondaryRootDeficitAbsorption = struct {
    current: SecondaryRootDeficitLayer,
    upper: SecondaryRootDeficitLayer,
    current_entering_carbon_deficit_g_c: f64,
    upper_entering_carbon_deficit_g_c: f64,
    residual_carbon_deficit_g_c: f64,
    residual_nitrogen_deficit_g_n: f64,
    residual_phosphorus_deficit_g_p: f64,
};

/// GROSUB 5105 precursor to primary-tip withdrawal. Negative primary C/N/P
/// growth is absorbed by secondary roots in the tip layer, then the adjacent
/// upper layer. Carbon removal shortens secondary roots proportionally.
pub fn absorbPrimaryDeficitFromSecondaryRoots(
    carbon_deficit_g_c: f64,
    nitrogen_deficit_g_n: f64,
    phosphorus_deficit_g_p: f64,
    current: SecondaryRootDeficitLayer,
    upper: SecondaryRootDeficitLayer,
) !SecondaryRootDeficitAbsorption {
    inline for (.{ carbon_deficit_g_c, nitrogen_deficit_g_n, phosphorus_deficit_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidPrimaryRootDeficit;
    var result: SecondaryRootDeficitAbsorption = .{
        .current = current,
        .upper = upper,
        .current_entering_carbon_deficit_g_c = carbon_deficit_g_c,
        .upper_entering_carbon_deficit_g_c = 0,
        .residual_carbon_deficit_g_c = carbon_deficit_g_c,
        .residual_nitrogen_deficit_g_n = nitrogen_deficit_g_n,
        .residual_phosphorus_deficit_g_p = phosphorus_deficit_g_p,
    };
    inline for (.{ "current", "upper" }) |field_name| {
        if (std.mem.eql(u8, field_name, "upper"))
            result.upper_entering_carbon_deficit_g_c = result.residual_carbon_deficit_g_c;
        var pool = &@field(result, field_name);
        inline for (@typeInfo(SecondaryRootDeficitLayer).@"struct".fields) |field| {
            const value = @field(pool.*, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSecondaryRootDeficitPool;
        }
        const carbon_removed = @min(result.residual_carbon_deficit_g_c, pool.carbon_g_c);
        if (pool.carbon_g_c > 0) pool.length_m *= 1 - carbon_removed / pool.carbon_g_c;
        pool.carbon_g_c -= carbon_removed;
        result.residual_carbon_deficit_g_c -= carbon_removed;
        const nitrogen_removed = @min(result.residual_nitrogen_deficit_g_n, pool.nitrogen_g_n);
        pool.nitrogen_g_n -= nitrogen_removed;
        result.residual_nitrogen_deficit_g_n -= nitrogen_removed;
        const phosphorus_removed = @min(result.residual_phosphorus_deficit_g_p, pool.phosphorus_g_p);
        pool.phosphorus_g_p -= phosphorus_removed;
        result.residual_phosphorus_deficit_g_p -= phosphorus_removed;
    }
    inline for (@typeInfo(SecondaryRootDeficitAbsorption).@"struct".fields) |field| switch (field.type) {
        f64 => if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFinitePrimaryRootDeficitAbsorption,
        else => {},
    };
    return result;
}

fn stagedSecondaryRootLayer(
    roots: RootState,
    axis_layer: usize,
    active: bool,
    metabolism: group_growth.SecondaryRootResult,
    senescence: group_litter.SecondaryRootSenescence,
    specific_length_m_per_g_c: f64,
    extension_water_response: f64,
) !SecondaryRootDeficitLayer {
    const fraction = if (active) senescence.senesced_fraction else 0;
    const result: SecondaryRootDeficitLayer = .{
        .carbon_g_c = roots.axis_secondary_carbon_g[axis_layer] + (if (active) metabolism.root_growth_actual_g_c_per_h else 0) - fraction * roots.axis_secondary_carbon_g[axis_layer],
        .nitrogen_g_n = roots.axis_secondary_nitrogen_g[axis_layer] + (if (active) metabolism.nitrogen_growth_actual_g_n_per_h else 0) - fraction * roots.axis_secondary_nitrogen_g[axis_layer],
        .phosphorus_g_p = roots.axis_secondary_phosphorus_g[axis_layer] + (if (active) metabolism.phosphorus_growth_actual_g_p_per_h else 0) - fraction * roots.axis_secondary_phosphorus_g[axis_layer],
        .length_m = roots.axis_secondary_length_m[axis_layer] +
            (if (active) metabolism.root_growth_actual_g_c_per_h * specific_length_m_per_g_c * extension_water_response else 0) -
            fraction * roots.axis_secondary_length_m[axis_layer],
    };
    inline for (@typeInfo(SecondaryRootDeficitLayer).@"struct".fields) |field| {
        const value = @field(result, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.StagedRootStateUpdateWouldOverdrawPool;
    }
    return result;
}

/// GROSUB GRTLGL cap and binary FGROL/FGROZ placement. If any part of a
/// positive extension crosses the lower boundary, the source assigns all of
/// that hour's primary-root growth to the next layer.
pub fn primaryRootExtensionPlacement(
    requested_extension_m: f64,
    current_depth_m: f64,
    current_layer_bottom_depth_m: f64,
    next_layer_thickness_m: f64,
) !PrimaryRootExtensionPlacement {
    inline for (.{ requested_extension_m, current_depth_m, current_layer_bottom_depth_m, next_layer_thickness_m }) |value|
        if (!std.math.isFinite(value)) return error.NonFinitePrimaryRootExtensionPlacement;
    if (current_depth_m < 0 or current_layer_bottom_depth_m < 0 or next_layer_thickness_m < 0) return error.InvalidPrimaryRootExtensionPlacement;
    const extension_m = if (next_layer_thickness_m > 0) @min(next_layer_thickness_m, requested_extension_m) else requested_extension_m;
    const crosses = extension_m > 0 and next_layer_thickness_m > 0 and current_depth_m + extension_m > current_layer_bottom_depth_m;
    if (!std.math.isFinite(extension_m)) return error.NonFinitePrimaryRootExtensionPlacement;
    return .{ .extension_m = extension_m, .crosses_into_next_layer = crosses };
}

/// GROSUB 6986--7007 compatibility placement including the strict
/// population-scaled ZEROP gate before binary current/next-layer routing.
pub fn sourceOrderPrimaryRootExtensionPlacement(
    requested_extension_m: f64,
    current_depth_m: f64,
    current_layer_bottom_depth_m: f64,
    next_layer_thickness_m: f64,
    extension_presence_threshold_m: f64,
) !PrimaryRootExtensionPlacement {
    if (!std.math.isFinite(extension_presence_threshold_m) or extension_presence_threshold_m < 0)
        return error.InvalidPrimaryRootExtensionPlacement;
    const placement = try primaryRootExtensionPlacement(
        requested_extension_m,
        current_depth_m,
        current_layer_bottom_depth_m,
        next_layer_thickness_m,
    );
    if (placement.extension_m <= extension_presence_threshold_m)
        return .{ .extension_m = placement.extension_m, .crosses_into_next_layer = false };
    return placement;
}

/// GROSUB GRTLGL for a primary axis. Negative net C growth retracts the
/// existing rooted depth in proportion to total primary-axis C; gross growth
/// can offset that loss in the same hour.
pub fn primaryRootLengthChange(
    gross_growth_g_c: f64,
    net_growth_g_c: f64,
    total_primary_carbon_g_c: f64,
    current_depth_m: f64,
    seeding_depth_m: f64,
    specific_length_m_per_g_c: f64,
    plant_population_count: f64,
    root_extension_water_response: f64,
) !f64 {
    inline for (.{ gross_growth_g_c, net_growth_g_c, total_primary_carbon_g_c, current_depth_m, seeding_depth_m, specific_length_m_per_g_c, plant_population_count, root_extension_water_response }) |value|
        if (!std.math.isFinite(value)) return error.NonFinitePrimaryRootLengthChange;
    if (gross_growth_g_c < 0 or total_primary_carbon_g_c < 0 or current_depth_m < 0 or seeding_depth_m < 0 or specific_length_m_per_g_c < 0 or plant_population_count <= 0 or root_extension_water_response < 0 or root_extension_water_response > 1) return error.InvalidPrimaryRootLengthChange;
    var change_m = gross_growth_g_c * specific_length_m_per_g_c / plant_population_count * root_extension_water_response;
    if (net_growth_g_c < 0 and total_primary_carbon_g_c > 0)
        change_m += net_growth_g_c * (current_depth_m - seeding_depth_m) / total_primary_carbon_g_c;
    if (!std.math.isFinite(change_m)) return error.NonFinitePrimaryRootLengthChange;
    return change_m;
}

fn mobileChanges(metabolism: group_growth.SecondaryRootResult, senescence: group_litter.SecondaryRootSenescence, recovered_c: f64, recovered_n: f64, recovered_p: f64) [3]f64 {
    return .{
        -@min(metabolism.maintenance_respiration_g_c_per_h, metabolism.substrate_respiration_actual_g_c_per_h) -
            metabolism.growth_and_respiration_carbon_actual_g_c_per_h -
            metabolism.nitrogen_assimilation_respiration_actual_g_c_per_h -
            senescence.respiration_actual_g_c_per_h + recovered_c,
        -metabolism.nitrogen_growth_actual_g_n_per_h + recovered_n,
        -metabolism.phosphorus_growth_actual_g_p_per_h + recovered_p,
    };
}

/// Publishes all primary and secondary axes sharing one root-layer mobile
/// pool as one rollback-safe transaction. Every flux must have been staged
/// from the same pre-state_update snapshot in `group_misc.AxisWorkspace`.
pub fn state_updateStagedLayerAxes(
    roots: *RootState,
    plant: usize,
    domain: usize,
    layer: usize,
    workspace: *group_misc.AxisWorkspace,
    active_axis_count: usize,
    parameters: StagedLayerStateUpdateParameters,
) !void {
    if (active_axis_count > workspace.axis_capacity or active_axis_count > roots.root_axis_count) return error.RootMetabolismWorkspaceCapacityExceeded;
    inline for (@typeInfo(StagedLayerStateUpdateParameters).@"struct".fields) |field|
        if (field.type == f64) {
            const value = @field(parameters, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidStagedRootStateUpdateParameter;
        };
    if (parameters.next_lower_layer) |next_lower_layer|
        if (next_lower_layer <= layer or next_lower_layer >= roots.soil_layer_count)
            return error.InvalidStagedRootNextLowerLayer;
    inline for (.{ parameters.root_extension_water_response, parameters.nonwoody_carbon_fraction, parameters.nonwoody_nitrogen_fraction, parameters.nonwoody_phosphorus_fraction }) |value| if (value > 1) return error.InvalidStagedRootStateUpdateParameter;
    @memset(workspace.candidate_primary_deficit_absorption[0..active_axis_count], std.mem.zeroes(SecondaryRootDeficitAbsorption));
    @memset(workspace.candidate_primary_deficit_active[0..active_axis_count], false);
    const root_layer = try roots.layerIndex(plant, domain, layer);
    if (workspace.primary_respiration_actual_delta_by_layer.len < roots.soil_layer_count or
        workspace.primary_respiration_oxygen_unlimited_delta_by_layer.len < roots.soil_layer_count or
        workspace.primary_respiration_carbon_unlimited_delta_by_layer.len < roots.soil_layer_count or
        workspace.primary_respiration_allocation_fractions.len < roots.soil_layer_count or
        workspace.primary_length_m_by_layer.len < roots.soil_layer_count)
        return error.RootMetabolismWorkspaceCapacityExceeded;
    @memset(workspace.primary_respiration_actual_delta_by_layer[0..roots.soil_layer_count], 0);
    @memset(workspace.primary_respiration_oxygen_unlimited_delta_by_layer[0..roots.soil_layer_count], 0);
    @memset(workspace.primary_respiration_carbon_unlimited_delta_by_layer[0..roots.soil_layer_count], 0);
    var mobile_change = [_]f64{0} ** 3;
    var protein_change_current: f64 = 0;
    var protein_change_next: f64 = 0;
    var crossing_transfer_retained_fraction: f64 = 1;
    var any_primary_crossing = false;
    var secondary_respiration = group_respiration.Respiration{ .actual_g_c = 0, .oxygen_unlimited_g_c = 0, .carbon_unlimited_g_c = 0 };
    const secondary_axis_count = try sourceOrderSecondaryAxisCount(
        parameters.secondary_root_branching_per_m,
        parameters.primary_axis_count_multiplier,
        parameters.current_layer_thickness_m,
    );
    var next_secondary_axis_count_total = roots.secondary_axis_count_total[root_layer];
    if (!std.math.isFinite(next_secondary_axis_count_total) or next_secondary_axis_count_total < 0)
        return error.InvalidSecondaryRootAxisCountInput;

    for (0..active_axis_count) |axis| {
        const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
        if (workspace.secondary_active[axis]) {
            next_secondary_axis_count_total += secondary_axis_count;
            if (!std.math.isFinite(next_secondary_axis_count_total))
                return error.NonFiniteSecondaryRootAxisCount;
        }
        if (workspace.primary_active[axis]) {
            const metabolism = workspace.primary_metabolism[axis];
            const senescence = workspace.primary_senescence[axis];
            const fraction = senescence.senesced_fraction;
            const recovered = [3]f64{
                fraction * senescence.recyclable_carbon_g_c * parameters.nonwoody_carbon_fraction,
                fraction * senescence.recyclable_nitrogen_g_n * parameters.nonwoody_nitrogen_fraction,
                fraction * senescence.recyclable_phosphorus_g_p * parameters.nonwoody_phosphorus_fraction,
            };
            const changes = mobileChanges(metabolism, senescence, recovered[0], recovered[1], recovered[2]);
            for (&mobile_change, changes) |*total, change| total.* += change;
            var total_primary_carbon_g_c: f64 = 0;
            var total_primary_nitrogen_g_n: f64 = 0;
            var total_primary_phosphorus_g_p: f64 = 0;
            for (0..roots.soil_layer_count) |axis_carbon_layer| {
                const total_axis_layer = try roots.layerAxisIndex(plant, domain, axis_carbon_layer, axis);
                total_primary_carbon_g_c += roots.axis_primary_carbon_g[total_axis_layer];
                total_primary_nitrogen_g_n += roots.axis_primary_nitrogen_g[total_axis_layer];
                total_primary_phosphorus_g_p += roots.axis_primary_phosphorus_g[total_axis_layer];
            }
            var net_growth_g_c = metabolism.root_growth_actual_g_c_per_h - fraction * total_primary_carbon_g_c;
            var net_growth_g_n = metabolism.nitrogen_growth_actual_g_n_per_h - fraction * total_primary_nitrogen_g_n;
            var net_growth_g_p = metabolism.phosphorus_growth_actual_g_p_per_h - fraction * total_primary_phosphorus_g_p;
            if (net_growth_g_c < 0 or net_growth_g_n < 0 or net_growth_g_p < 0) {
                const current_secondary = try stagedSecondaryRootLayer(
                    roots.*,
                    axis_layer,
                    workspace.secondary_active[axis],
                    workspace.secondary_metabolism[axis],
                    workspace.secondary_senescence[axis],
                    parameters.secondary_specific_length_m_per_g_c,
                    parameters.root_extension_water_response,
                );
                const upper_secondary: SecondaryRootDeficitLayer = if (layer > 0) blk: {
                    const upper_axis_layer = try roots.layerAxisIndex(plant, domain, layer - 1, axis);
                    break :blk .{
                        .carbon_g_c = roots.axis_secondary_carbon_g[upper_axis_layer],
                        .nitrogen_g_n = roots.axis_secondary_nitrogen_g[upper_axis_layer],
                        .phosphorus_g_p = roots.axis_secondary_phosphorus_g[upper_axis_layer],
                        .length_m = roots.axis_secondary_length_m[upper_axis_layer],
                    };
                } else .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0, .length_m = 0 };
                const absorption = try absorbPrimaryDeficitFromSecondaryRoots(
                    @max(0, -net_growth_g_c),
                    @max(0, -net_growth_g_n),
                    @max(0, -net_growth_g_p),
                    current_secondary,
                    upper_secondary,
                );
                workspace.candidate_primary_deficit_absorption[axis] = absorption;
                workspace.candidate_primary_deficit_active[axis] = true;
                if (net_growth_g_c < 0) net_growth_g_c = -absorption.residual_carbon_deficit_g_c;
                if (net_growth_g_n < 0) net_growth_g_n = -absorption.residual_nitrogen_deficit_g_n;
                if (net_growth_g_p < 0) net_growth_g_p = -absorption.residual_phosphorus_deficit_g_p;
            }
            const axis_index = try roots.axisIndex(plant, domain, axis);
            const requested_extension_m = try primaryRootLengthChange(metabolism.root_growth_actual_g_c_per_h, net_growth_g_c, total_primary_carbon_g_c, roots.axis_depth_m[axis_index], parameters.seeding_depth_m, parameters.primary_specific_length_m_per_g_c, parameters.plant_population_count, parameters.root_extension_water_response);
            const placement = try sourceOrderPrimaryRootExtensionPlacement(requested_extension_m, roots.axis_depth_m[axis_index], parameters.current_layer_bottom_depth_m, parameters.next_layer_thickness_m, parameters.extension_presence_threshold_m);
            const target_layer = if (placement.crosses_into_next_layer)
                parameters.next_lower_layer orelse return error.MissingStagedRootNextLowerLayer
            else
                layer;
            if (target_layer >= roots.soil_layer_count) return error.StagedRootStateUpdateLayerOutOfBounds;
            const target_axis_layer = try roots.layerAxisIndex(plant, domain, target_layer, axis);
            const next_c = roots.axis_primary_carbon_g[target_axis_layer] + net_growth_g_c;
            const next_n = roots.axis_primary_nitrogen_g[target_axis_layer] + net_growth_g_n;
            const next_p = roots.axis_primary_phosphorus_g[target_axis_layer] + net_growth_g_p;
            const next_length = roots.axis_primary_length_m[target_axis_layer] + placement.extension_m;
            const next_depth = roots.axis_depth_m[axis_index] + placement.extension_m;
            inline for (.{ next_c, next_n, next_p, next_length, next_depth }) |value| if (!std.math.isFinite(value) or value < 0) return error.StagedRootStateUpdateWouldOverdrawPool;
            const protein = @min(parameters.protein_carbon_per_nitrogen_g_c_per_g_n * next_n, parameters.protein_carbon_per_phosphorus_g_c_per_g_p * next_p);
            if (placement.crosses_into_next_layer) {
                any_primary_crossing = true;
                const transfer_fraction = workspace.primary_sink_fractions[axis];
                if (!std.math.isFinite(transfer_fraction) or transfer_fraction < 0 or transfer_fraction > 1) return error.InvalidStagedRootStateUpdateParameter;
                crossing_transfer_retained_fraction *= 1 - transfer_fraction;
                protein_change_current += @min(
                    parameters.protein_carbon_per_nitrogen_g_c_per_g_n * roots.axis_primary_nitrogen_g[axis_layer],
                    parameters.protein_carbon_per_phosphorus_g_c_per_g_p * roots.axis_primary_phosphorus_g[axis_layer],
                );
                protein_change_next += protein;
            } else {
                protein_change_current += protein;
            }
            const primary_respiration = try assemble(.{
                .maintenance_demand_g_c = metabolism.maintenance_respiration_g_c_per_h,
                .substrate_respiration_actual_g_c = metabolism.substrate_respiration_actual_g_c_per_h,
                .substrate_respiration_oxygen_unlimited_g_c = metabolism.substrate_respiration_oxygen_unlimited_g_c_per_h,
                .growth_respiration_actual_g_c = metabolism.growth_respiration_actual_g_c_per_h,
                .growth_respiration_oxygen_unlimited_g_c = metabolism.growth_respiration_oxygen_unlimited_g_c_per_h,
                .senescence_respiration_actual_g_c = senescence.respiration_actual_g_c_per_h,
                .senescence_respiration_oxygen_unlimited_g_c = senescence.respiration_oxygen_unlimited_g_c_per_h,
                .nitrogen_assimilation_respiration_actual_g_c = metabolism.nitrogen_assimilation_respiration_actual_g_c_per_h,
                .nitrogen_assimilation_respiration_oxygen_unlimited_g_c = metabolism.nitrogen_assimilation_respiration_oxygen_unlimited_g_c_per_h,
            });
            const planting_layer = roots.planting_layer_by_plant[plant];
            const root_axis = try roots.rootAxisIndex(plant, axis);
            const allocation_last_layer = if (layer > planting_layer)
                roots.deepest_rooted_layer_by_axis[root_axis]
            else
                layer;
            if (allocation_last_layer < planting_layer or allocation_last_layer >= roots.soil_layer_count)
                return error.InvalidRootedLayerBounds;
            const allocation_count = allocation_last_layer - planting_layer + 1;
            for (0..allocation_count) |offset| {
                const traversed_layer = planting_layer + offset;
                workspace.primary_length_m_by_layer[offset] = roots.axis_primary_length_m[
                    try roots.layerAxisIndex(plant, domain, traversed_layer, axis)
                ];
            }
            try sourceOrderPrimaryRootRespirationFractions(
                workspace.primary_length_m_by_layer[0..allocation_count],
                workspace.primary_respiration_allocation_fractions[0..allocation_count],
                roots.axis_depth_m[axis_index],
                parameters.seeding_depth_m,
                layer > planting_layer,
            );
            for (workspace.primary_respiration_allocation_fractions[0..allocation_count], 0..) |respiration_fraction, offset| {
                const traversed_layer = planting_layer + offset;
                workspace.primary_respiration_actual_delta_by_layer[traversed_layer] += primary_respiration.actual_g_c * respiration_fraction;
                workspace.primary_respiration_oxygen_unlimited_delta_by_layer[traversed_layer] += primary_respiration.oxygen_unlimited_g_c * respiration_fraction;
                workspace.primary_respiration_carbon_unlimited_delta_by_layer[traversed_layer] += primary_respiration.carbon_unlimited_g_c * respiration_fraction;
            }
        }
        if (workspace.secondary_active[axis]) {
            const metabolism = workspace.secondary_metabolism[axis];
            const senescence = workspace.secondary_senescence[axis];
            const fraction = senescence.senesced_fraction;
            const recovered = [3]f64{
                fraction * senescence.recyclable_carbon_g_c * parameters.nonwoody_carbon_fraction,
                fraction * senescence.recyclable_nitrogen_g_n * parameters.nonwoody_nitrogen_fraction,
                fraction * senescence.recyclable_phosphorus_g_p * parameters.nonwoody_phosphorus_fraction,
            };
            const changes = mobileChanges(metabolism, senescence, recovered[0], recovered[1], recovered[2]);
            for (&mobile_change, changes) |*total, change| total.* += change;
            const next_c = roots.axis_secondary_carbon_g[axis_layer] + metabolism.root_growth_actual_g_c_per_h - fraction * roots.axis_secondary_carbon_g[axis_layer];
            const next_n = roots.axis_secondary_nitrogen_g[axis_layer] + metabolism.nitrogen_growth_actual_g_n_per_h - fraction * roots.axis_secondary_nitrogen_g[axis_layer];
            const next_p = roots.axis_secondary_phosphorus_g[axis_layer] + metabolism.phosphorus_growth_actual_g_p_per_h - fraction * roots.axis_secondary_phosphorus_g[axis_layer];
            const next_length = roots.axis_secondary_length_m[axis_layer] + metabolism.root_growth_actual_g_c_per_h * parameters.secondary_specific_length_m_per_g_c * parameters.root_extension_water_response - fraction * roots.axis_secondary_length_m[axis_layer];
            inline for (.{ next_c, next_n, next_p, next_length }) |value| if (!std.math.isFinite(value) or value < 0) return error.StagedRootStateUpdateWouldOverdrawPool;
            protein_change_current += @min(parameters.protein_carbon_per_nitrogen_g_c_per_g_n * next_n, parameters.protein_carbon_per_phosphorus_g_c_per_g_p * next_p);
            const respiration = try assemble(.{
                .maintenance_demand_g_c = metabolism.maintenance_respiration_g_c_per_h,
                .substrate_respiration_actual_g_c = metabolism.substrate_respiration_actual_g_c_per_h,
                .substrate_respiration_oxygen_unlimited_g_c = metabolism.substrate_respiration_oxygen_unlimited_g_c_per_h,
                .growth_respiration_actual_g_c = metabolism.growth_respiration_actual_g_c_per_h,
                .growth_respiration_oxygen_unlimited_g_c = metabolism.growth_respiration_oxygen_unlimited_g_c_per_h,
                .senescence_respiration_actual_g_c = senescence.respiration_actual_g_c_per_h,
                .senescence_respiration_oxygen_unlimited_g_c = senescence.respiration_oxygen_unlimited_g_c_per_h,
                .nitrogen_assimilation_respiration_actual_g_c = metabolism.nitrogen_assimilation_respiration_actual_g_c_per_h,
                .nitrogen_assimilation_respiration_oxygen_unlimited_g_c = metabolism.nitrogen_assimilation_respiration_oxygen_unlimited_g_c_per_h,
            });
            secondary_respiration.actual_g_c += respiration.actual_g_c;
            secondary_respiration.oxygen_unlimited_g_c += respiration.oxygen_unlimited_g_c;
            secondary_respiration.carbon_unlimited_g_c += respiration.carbon_unlimited_g_c;
        }
    }
    const next_mobile = [3]f64{
        roots.mobile_carbon_g[root_layer] + mobile_change[0],
        roots.mobile_nitrogen_g[root_layer] + mobile_change[1],
        roots.mobile_phosphorus_g[root_layer] + mobile_change[2],
    };
    const crosses_layer = any_primary_crossing;
    const next_root_layer = if (crosses_layer)
        try roots.layerIndex(plant, domain, parameters.next_lower_layer.?)
    else
        root_layer;
    const transfer_fraction = 1 - crossing_transfer_retained_fraction;
    const current_mobile = [3]f64{
        next_mobile[0] * crossing_transfer_retained_fraction,
        next_mobile[1] * crossing_transfer_retained_fraction,
        next_mobile[2] * crossing_transfer_retained_fraction,
    };
    const receiving_mobile = [3]f64{
        roots.mobile_carbon_g[next_root_layer] + next_mobile[0] * transfer_fraction,
        roots.mobile_nitrogen_g[next_root_layer] + next_mobile[1] * transfer_fraction,
        roots.mobile_phosphorus_g[next_root_layer] + next_mobile[2] * transfer_fraction,
    };
    const next_protein = roots.protein_carbon_g[root_layer] + protein_change_current;
    const receiving_protein = roots.protein_carbon_g[next_root_layer] + protein_change_next;
    inline for (.{
        current_mobile[0],
        current_mobile[1],
        current_mobile[2],
        receiving_mobile[0],
        receiving_mobile[1],
        receiving_mobile[2],
        next_protein,
        receiving_protein,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.StagedRootStateUpdateWouldOverdrawPool;
    for (0..roots.soil_layer_count) |respiration_layer| {
        const respiration_root = try roots.layerIndex(plant, domain, respiration_layer);
        const secondary_actual = if (respiration_layer == layer) secondary_respiration.actual_g_c else 0;
        const secondary_oxygen_unlimited = if (respiration_layer == layer) secondary_respiration.oxygen_unlimited_g_c else 0;
        const secondary_carbon_unlimited = if (respiration_layer == layer) secondary_respiration.carbon_unlimited_g_c else 0;
        inline for (.{
            roots.actual_respiration_g_c_per_h[respiration_root] + workspace.primary_respiration_actual_delta_by_layer[respiration_layer] + secondary_actual,
            roots.respiration_unlimited_by_oxygen_g_c_per_h[respiration_root] + workspace.primary_respiration_oxygen_unlimited_delta_by_layer[respiration_layer] + secondary_oxygen_unlimited,
            roots.respiration_unlimited_by_carbon_g_c_per_h[respiration_root] + workspace.primary_respiration_carbon_unlimited_delta_by_layer[respiration_layer] + secondary_carbon_unlimited,
        }) |value| if (!std.math.isFinite(value) or value < 0) return error.StagedRootStateUpdateWouldOverdrawPool;
    }

    // The candidate traversal above is the only fallible phase. Publish both
    // workspace diagnostics and root owners only after the entire shared
    // mobile-pool transaction has been proven admissible.
    @memcpy(workspace.primary_deficit_absorption[0..active_axis_count], workspace.candidate_primary_deficit_absorption[0..active_axis_count]);
    @memcpy(workspace.primary_deficit_active[0..active_axis_count], workspace.candidate_primary_deficit_active[0..active_axis_count]);
    roots.mobile_carbon_g[root_layer] = current_mobile[0];
    roots.mobile_nitrogen_g[root_layer] = current_mobile[1];
    roots.mobile_phosphorus_g[root_layer] = current_mobile[2];
    roots.protein_carbon_g[root_layer] = next_protein;
    if (crosses_layer) {
        roots.mobile_carbon_g[next_root_layer] = receiving_mobile[0];
        roots.mobile_nitrogen_g[next_root_layer] = receiving_mobile[1];
        roots.mobile_phosphorus_g[next_root_layer] = receiving_mobile[2];
        roots.protein_carbon_g[next_root_layer] = receiving_protein;
        roots.total_water_potential_megapascal[next_root_layer] = roots.total_water_potential_megapascal[root_layer];
        roots.osmotic_water_potential_megapascal[next_root_layer] = roots.osmotic_water_potential_megapascal[root_layer];
        roots.turgor_water_potential_megapascal[next_root_layer] = roots.turgor_water_potential_megapascal[root_layer];
        roots.primary_radius_m[next_root_layer] = roots.primary_radius_m[root_layer];
    }
    for (0..roots.soil_layer_count) |respiration_layer| {
        const respiration_root = roots.layerIndex(plant, domain, respiration_layer) catch unreachable;
        roots.actual_respiration_g_c_per_h[respiration_root] += workspace.primary_respiration_actual_delta_by_layer[respiration_layer] + (if (respiration_layer == layer) secondary_respiration.actual_g_c else 0);
        roots.respiration_unlimited_by_oxygen_g_c_per_h[respiration_root] += workspace.primary_respiration_oxygen_unlimited_delta_by_layer[respiration_layer] + (if (respiration_layer == layer) secondary_respiration.oxygen_unlimited_g_c else 0);
        roots.respiration_unlimited_by_carbon_g_c_per_h[respiration_root] += workspace.primary_respiration_carbon_unlimited_delta_by_layer[respiration_layer] + (if (respiration_layer == layer) secondary_respiration.carbon_unlimited_g_c else 0);
    }
    for (0..active_axis_count) |axis| {
        const axis_layer = roots.layerAxisIndex(plant, domain, layer, axis) catch unreachable;
        // GROSUB clears RTN1/RTNL at the start of every plant pass, then
        // rebuilds RTN1 for every primary axis reaching this layer. RTN2 is
        // assigned from the same accepted geometry and branching traits.
        if (workspace.secondary_active[axis]) {
            roots.axis_primary_count[axis_layer] = parameters.primary_axis_count_multiplier;
            roots.axis_secondary_count[axis_layer] = secondary_axis_count;
        }
        if (workspace.primary_active[axis]) {
            const metabolism = workspace.primary_metabolism[axis];
            const fraction = workspace.primary_senescence[axis].senesced_fraction;
            var total_primary_carbon_g_c: f64 = 0;
            var total_primary_nitrogen_g_n: f64 = 0;
            var total_primary_phosphorus_g_p: f64 = 0;
            for (0..roots.soil_layer_count) |axis_carbon_layer| {
                const total_axis_layer = roots.layerAxisIndex(plant, domain, axis_carbon_layer, axis) catch unreachable;
                total_primary_carbon_g_c += roots.axis_primary_carbon_g[total_axis_layer];
                total_primary_nitrogen_g_n += roots.axis_primary_nitrogen_g[total_axis_layer];
                total_primary_phosphorus_g_p += roots.axis_primary_phosphorus_g[total_axis_layer];
            }
            var net_growth_g_c = metabolism.root_growth_actual_g_c_per_h - fraction * total_primary_carbon_g_c;
            var net_growth_g_n = metabolism.nitrogen_growth_actual_g_n_per_h - fraction * total_primary_nitrogen_g_n;
            var net_growth_g_p = metabolism.phosphorus_growth_actual_g_p_per_h - fraction * total_primary_phosphorus_g_p;
            const absorption = workspace.candidate_primary_deficit_absorption[axis];
            if (net_growth_g_c < 0) net_growth_g_c = -absorption.residual_carbon_deficit_g_c;
            if (net_growth_g_n < 0) net_growth_g_n = -absorption.residual_nitrogen_deficit_g_n;
            if (net_growth_g_p < 0) net_growth_g_p = -absorption.residual_phosphorus_deficit_g_p;
            const axis_index = roots.axisIndex(plant, domain, axis) catch unreachable;
            const requested_extension_m = primaryRootLengthChange(metabolism.root_growth_actual_g_c_per_h, net_growth_g_c, total_primary_carbon_g_c, roots.axis_depth_m[axis_index], parameters.seeding_depth_m, parameters.primary_specific_length_m_per_g_c, parameters.plant_population_count, parameters.root_extension_water_response) catch unreachable;
            const placement = sourceOrderPrimaryRootExtensionPlacement(requested_extension_m, roots.axis_depth_m[axis_index], parameters.current_layer_bottom_depth_m, parameters.next_layer_thickness_m, parameters.extension_presence_threshold_m) catch unreachable;
            const target_layer = if (placement.crosses_into_next_layer) parameters.next_lower_layer.? else layer;
            const target_axis_layer = roots.layerAxisIndex(plant, domain, target_layer, axis) catch unreachable;
            roots.axis_primary_carbon_g[target_axis_layer] += net_growth_g_c;
            roots.axis_primary_nitrogen_g[target_axis_layer] += net_growth_g_n;
            roots.axis_primary_phosphorus_g[target_axis_layer] += net_growth_g_p;
            roots.axis_primary_length_m[target_axis_layer] += placement.extension_m;
            roots.axis_depth_m[axis_index] += placement.extension_m;
            // grosub.f:7080/7288/7332 `NIX=MAX(NIX,NINR)`: record that this
            // axis's growth reached `target_layer` so the pending rooted-
            // layer boundary (published by `advanceRootedLayerBoundary`,
            // the `NI=NIX` step in hfunc.f:140) deepens to at least here.
            if (placement.crosses_into_next_layer) {
                const root_axis = roots.rootAxisIndex(plant, axis) catch unreachable;
                roots.deepest_rooted_layer_by_axis[root_axis] =
                    @max(roots.deepest_rooted_layer_by_axis[root_axis], target_layer);
                roots.includeNextDeepestRootedLayer(plant, target_layer) catch unreachable;
            }
        }
        if (workspace.secondary_active[axis]) {
            const metabolism = workspace.secondary_metabolism[axis];
            const fraction = workspace.secondary_senescence[axis].senesced_fraction;
            const extension = metabolism.root_growth_actual_g_c_per_h * parameters.secondary_specific_length_m_per_g_c * parameters.root_extension_water_response;
            roots.axis_secondary_carbon_g[axis_layer] += metabolism.root_growth_actual_g_c_per_h - fraction * roots.axis_secondary_carbon_g[axis_layer];
            roots.axis_secondary_nitrogen_g[axis_layer] += metabolism.nitrogen_growth_actual_g_n_per_h - fraction * roots.axis_secondary_nitrogen_g[axis_layer];
            roots.axis_secondary_phosphorus_g[axis_layer] += metabolism.phosphorus_growth_actual_g_p_per_h - fraction * roots.axis_secondary_phosphorus_g[axis_layer];
            roots.axis_secondary_length_m[axis_layer] += extension - fraction * roots.axis_secondary_length_m[axis_layer];
        }
    }
    roots.secondary_axis_count_total[root_layer] = next_secondary_axis_count_total;
    for (0..active_axis_count) |axis| {
        if (!workspace.primary_deficit_active[axis]) continue;
        const absorption = workspace.primary_deficit_absorption[axis];
        const current_axis_layer = roots.layerAxisIndex(plant, domain, layer, axis) catch unreachable;
        roots.axis_secondary_carbon_g[current_axis_layer] = absorption.current.carbon_g_c;
        roots.axis_secondary_nitrogen_g[current_axis_layer] = absorption.current.nitrogen_g_n;
        roots.axis_secondary_phosphorus_g[current_axis_layer] = absorption.current.phosphorus_g_p;
        roots.axis_secondary_length_m[current_axis_layer] = absorption.current.length_m;
        if (layer > 0) {
            const upper_axis_layer = roots.layerAxisIndex(plant, domain, layer - 1, axis) catch unreachable;
            roots.axis_secondary_carbon_g[upper_axis_layer] = absorption.upper.carbon_g_c;
            roots.axis_secondary_nitrogen_g[upper_axis_layer] = absorption.upper.nitrogen_g_n;
            roots.axis_secondary_phosphorus_g[upper_axis_layer] = absorption.upper.phosphorus_g_p;
            roots.axis_secondary_length_m[upper_axis_layer] = absorption.upper.length_m;
        }
    }
}

/// Atomic GROSUB primary-axis C/N/P, length/depth, mobile pools, protein, and
/// RCO2 transaction. The caller stages all axis calculations before invoking
/// state_updates when several axes share one mobile pool.
pub fn state_updatePrimaryRoot(
    roots: *RootState,
    root_layer: usize,
    root_axis_layer: usize,
    root_axis: usize,
    inputs: PrimaryRootStateUpdateInputs,
) !void {
    if (root_layer >= roots.mobile_carbon_g.len or root_axis_layer >= roots.axis_primary_carbon_g.len or root_axis >= roots.axis_depth_m.len) return error.PlantRootIndexOutOfBounds;
    inline for (.{ inputs.primary_specific_length_m_per_g_c, inputs.root_extension_water_response, inputs.nonwoody_carbon_fraction, inputs.nonwoody_nitrogen_fraction, inputs.nonwoody_phosphorus_fraction, inputs.protein_carbon_per_nitrogen_g_c_per_g_n, inputs.protein_carbon_per_phosphorus_g_c_per_g_p }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPrimaryRootStateUpdateInput;
    inline for (.{ inputs.root_extension_water_response, inputs.nonwoody_carbon_fraction, inputs.nonwoody_nitrogen_fraction, inputs.nonwoody_phosphorus_fraction }) |value| if (value > 1) return error.InvalidPrimaryRootStateUpdateInput;

    const old_c = roots.axis_primary_carbon_g[root_axis_layer];
    const old_n = roots.axis_primary_nitrogen_g[root_axis_layer];
    const old_p = roots.axis_primary_phosphorus_g[root_axis_layer];
    const old_length = roots.axis_primary_length_m[root_axis_layer];
    const old_depth = roots.axis_depth_m[root_axis];
    const fraction = inputs.senescence.senesced_fraction;
    const recovered_c = fraction * inputs.senescence.recyclable_carbon_g_c * inputs.nonwoody_carbon_fraction;
    const recovered_n = fraction * inputs.senescence.recyclable_nitrogen_g_n * inputs.nonwoody_nitrogen_fraction;
    // GROSUB-6771 fix (mass-conservation defect inherited from the Fortran
    // oracle): the source credits the full, unscaled RCPR back to PPOOLR with
    // no FWODRP(1,NZ) multiplier, while its own nonwoody litterfall term
    // (grosub.f:6746) and the parallel secondary-root block (grosub.f:6361)
    // both scale by FWODRP(1,NZ). Without this multiplier, litterfall plus
    // the credit back to the nonstructural pool double-counts
    // FSNC1*RCPR*FWODRP(0,NZ) of phosphorus for any woody-rooted PFT.
    const recovered_p = fraction * inputs.senescence.recyclable_phosphorus_g_p * inputs.nonwoody_phosphorus_fraction;
    const next_mobile_c = roots.mobile_carbon_g[root_layer] -
        @min(inputs.metabolism.maintenance_respiration_g_c_per_h, inputs.metabolism.substrate_respiration_actual_g_c_per_h) -
        inputs.metabolism.growth_and_respiration_carbon_actual_g_c_per_h -
        inputs.metabolism.nitrogen_assimilation_respiration_actual_g_c_per_h -
        inputs.senescence.respiration_actual_g_c_per_h + recovered_c;
    const next_mobile_n = roots.mobile_nitrogen_g[root_layer] - inputs.metabolism.nitrogen_growth_actual_g_n_per_h + recovered_n;
    const next_mobile_p = roots.mobile_phosphorus_g[root_layer] - inputs.metabolism.phosphorus_growth_actual_g_p_per_h + recovered_p;
    const next_c = old_c + inputs.metabolism.root_growth_actual_g_c_per_h - fraction * old_c;
    const next_n = old_n + inputs.metabolism.nitrogen_growth_actual_g_n_per_h - fraction * old_n;
    const next_p = old_p + inputs.metabolism.phosphorus_growth_actual_g_p_per_h - fraction * old_p;
    const extension_m = inputs.metabolism.root_growth_actual_g_c_per_h * inputs.primary_specific_length_m_per_g_c * inputs.root_extension_water_response;
    const next_length = old_length + extension_m - fraction * old_length;
    const next_depth = old_depth + extension_m;
    const next_protein = roots.protein_carbon_g[root_layer] + @min(
        inputs.protein_carbon_per_nitrogen_g_c_per_g_n * next_n,
        inputs.protein_carbon_per_phosphorus_g_c_per_g_p * next_p,
    );
    inline for (.{ next_mobile_c, next_mobile_n, next_mobile_p, next_c, next_n, next_p, next_length, next_depth, next_protein }) |value| {
        if (!std.math.isFinite(value)) return error.NonFinitePrimaryRootStateUpdate;
        if (value < 0) return error.PrimaryRootStateUpdateWouldOverdrawPool;
    }
    roots.mobile_carbon_g[root_layer] = next_mobile_c;
    roots.mobile_nitrogen_g[root_layer] = next_mobile_n;
    roots.mobile_phosphorus_g[root_layer] = next_mobile_p;
    roots.axis_primary_carbon_g[root_axis_layer] = next_c;
    roots.axis_primary_nitrogen_g[root_axis_layer] = next_n;
    roots.axis_primary_phosphorus_g[root_axis_layer] = next_p;
    roots.axis_primary_length_m[root_axis_layer] = next_length;
    roots.axis_depth_m[root_axis] = next_depth;
    roots.protein_carbon_g[root_layer] = next_protein;
}

/// GROSUB FRCO2 allocation of one primary-axis respiration total through all
/// traversed soil layers. Caller-owned fractions avoid per-hour allocation.
pub fn sourceOrderPrimaryRootRespirationFractions(
    primary_length_m_by_layer: []const f64,
    allocation_fractions: []f64,
    primary_depth_m: f64,
    seeding_depth_m: f64,
    traverses_multiple_layers: bool,
) !void {
    if (primary_length_m_by_layer.len == 0 or
        primary_length_m_by_layer.len != allocation_fractions.len)
        return error.PrimaryRootRespirationDimensionMismatch;
    inline for (.{ primary_depth_m, seeding_depth_m }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPrimaryRootRespirationAllocation;
    const denominator = primary_depth_m - seeding_depth_m;
    if (traverses_multiple_layers and denominator <= 0)
        return error.InvalidPrimaryRootRespirationAllocation;
    var allocated: f64 = 0;
    for (primary_length_m_by_layer, 0..) |length, layer| {
        if (!std.math.isFinite(length) or length < 0)
            return error.InvalidPrimaryRootRespirationAllocation;
        if (!traverses_multiple_layers) {
            allocation_fractions[layer] = @floatFromInt(@intFromBool(layer + 1 == primary_length_m_by_layer.len));
        } else if (layer + 1 < primary_length_m_by_layer.len) {
            allocation_fractions[layer] = @min(1, length / denominator);
        } else {
            const remainder = 1 - allocated;
            const roundoff = 64 * std.math.floatEps(f64) * @max(1, @abs(allocated));
            if (remainder < -roundoff) return error.InvalidPrimaryRootRespirationAllocation;
            allocation_fractions[layer] = if (remainder < 0) 0 else remainder;
        }
        allocated += allocation_fractions[layer];
        if (!std.math.isFinite(allocated)) return error.InvalidPrimaryRootRespirationAllocation;
    }
    const closure_tolerance = 64 * std.math.floatEps(f64) * @max(1, @abs(allocated));
    if (@abs(allocated - 1) > closure_tolerance)
        return error.InvalidPrimaryRootRespirationAllocation;
}

pub fn allocatePrimaryRootRespiration(
    roots: *RootState,
    root_layer_indices: []const usize,
    primary_length_m_by_layer: []const f64,
    allocation_fractions: []f64,
    primary_depth_m: f64,
    seeding_depth_m: f64,
    traverses_multiple_layers: bool,
    respiration: group_respiration.Respiration,
) !void {
    if (root_layer_indices.len == 0 or root_layer_indices.len != primary_length_m_by_layer.len or root_layer_indices.len != allocation_fractions.len) return error.PrimaryRootRespirationDimensionMismatch;
    inline for (.{ respiration.actual_g_c, respiration.oxygen_unlimited_g_c, respiration.carbon_unlimited_g_c }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPrimaryRootRespirationAllocation;
    for (root_layer_indices) |root| if (root >= roots.actual_respiration_g_c_per_h.len) return error.InvalidPrimaryRootRespirationAllocation;
    try sourceOrderPrimaryRootRespirationFractions(
        primary_length_m_by_layer,
        allocation_fractions,
        primary_depth_m,
        seeding_depth_m,
        traverses_multiple_layers,
    );
    for (root_layer_indices, allocation_fractions) |root, fraction| inline for (.{
        roots.actual_respiration_g_c_per_h[root] + respiration.actual_g_c * fraction,
        roots.respiration_unlimited_by_oxygen_g_c_per_h[root] + respiration.oxygen_unlimited_g_c * fraction,
        roots.respiration_unlimited_by_carbon_g_c_per_h[root] + respiration.carbon_unlimited_g_c * fraction,
    }) |value| if (!std.math.isFinite(value)) return error.NonFinitePrimaryRootRespirationAllocation;
    for (root_layer_indices, allocation_fractions) |root, fraction| {
        roots.actual_respiration_g_c_per_h[root] += respiration.actual_g_c * fraction;
        roots.respiration_unlimited_by_oxygen_g_c_per_h[root] += respiration.oxygen_unlimited_g_c * fraction;
        roots.respiration_unlimited_by_carbon_g_c_per_h[root] += respiration.carbon_unlimited_g_c * fraction;
    }
}

/// Atomic GROSUB CPOOLR/ZPOOLR/PPOOLR, RTLG2, WTRT2/N/P, WSRTL and
/// RCO2M/RCO2N/RCO2A transaction for one runtime root axis and soil layer.
pub fn state_updateSecondaryRoot(
    roots: *RootState,
    root_layer: usize,
    root_axis_layer: usize,
    inputs: SecondaryRootStateUpdateInputs,
) !void {
    if (root_layer >= roots.mobile_carbon_g.len or root_axis_layer >= roots.axis_secondary_carbon_g.len) return error.PlantRootIndexOutOfBounds;
    inline for (.{ inputs.root_specific_length_m_per_g_c, inputs.root_extension_water_response, inputs.nonwoody_carbon_fraction, inputs.nonwoody_nitrogen_fraction, inputs.nonwoody_phosphorus_fraction, inputs.protein_carbon_per_nitrogen_g_c_per_g_n, inputs.protein_carbon_per_phosphorus_g_c_per_g_p }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSecondaryRootStateUpdateInput;
    inline for (.{ inputs.nonwoody_carbon_fraction, inputs.nonwoody_nitrogen_fraction, inputs.nonwoody_phosphorus_fraction, inputs.root_extension_water_response }) |value| if (value > 1) return error.InvalidSecondaryRootStateUpdateInput;

    const old_c = roots.axis_secondary_carbon_g[root_axis_layer];
    const old_n = roots.axis_secondary_nitrogen_g[root_axis_layer];
    const old_p = roots.axis_secondary_phosphorus_g[root_axis_layer];
    const old_length = roots.axis_secondary_length_m[root_axis_layer];
    const fraction = inputs.senescence.senesced_fraction;
    const recovered_c = fraction * inputs.senescence.recyclable_carbon_g_c * inputs.nonwoody_carbon_fraction;
    const recovered_n = fraction * inputs.senescence.recyclable_nitrogen_g_n * inputs.nonwoody_nitrogen_fraction;
    const recovered_p = fraction * inputs.senescence.recyclable_phosphorus_g_p * inputs.nonwoody_phosphorus_fraction;
    const next_mobile_c = roots.mobile_carbon_g[root_layer] -
        @min(inputs.metabolism.maintenance_respiration_g_c_per_h, inputs.metabolism.substrate_respiration_actual_g_c_per_h) -
        inputs.metabolism.growth_and_respiration_carbon_actual_g_c_per_h -
        inputs.metabolism.nitrogen_assimilation_respiration_actual_g_c_per_h -
        inputs.senescence.respiration_actual_g_c_per_h + recovered_c;
    const next_mobile_n = roots.mobile_nitrogen_g[root_layer] - inputs.metabolism.nitrogen_growth_actual_g_n_per_h + recovered_n;
    const next_mobile_p = roots.mobile_phosphorus_g[root_layer] - inputs.metabolism.phosphorus_growth_actual_g_p_per_h + recovered_p;
    const next_c = old_c + inputs.metabolism.root_growth_actual_g_c_per_h - fraction * old_c;
    const next_n = old_n + inputs.metabolism.nitrogen_growth_actual_g_n_per_h - fraction * old_n;
    const next_p = old_p + inputs.metabolism.phosphorus_growth_actual_g_p_per_h - fraction * old_p;
    const next_length = old_length +
        inputs.metabolism.root_growth_actual_g_c_per_h * inputs.root_specific_length_m_per_g_c * inputs.root_extension_water_response -
        fraction * old_length;
    const next_protein = roots.protein_carbon_g[root_layer] + @min(
        inputs.protein_carbon_per_nitrogen_g_c_per_g_n * next_n,
        inputs.protein_carbon_per_phosphorus_g_c_per_g_p * next_p,
    );
    const respiration = try assemble(.{
        .maintenance_demand_g_c = inputs.metabolism.maintenance_respiration_g_c_per_h,
        .substrate_respiration_actual_g_c = inputs.metabolism.substrate_respiration_actual_g_c_per_h,
        .substrate_respiration_oxygen_unlimited_g_c = inputs.metabolism.substrate_respiration_oxygen_unlimited_g_c_per_h,
        .growth_respiration_actual_g_c = inputs.metabolism.growth_respiration_actual_g_c_per_h,
        .growth_respiration_oxygen_unlimited_g_c = inputs.metabolism.growth_respiration_oxygen_unlimited_g_c_per_h,
        .senescence_respiration_actual_g_c = inputs.senescence.respiration_actual_g_c_per_h,
        .senescence_respiration_oxygen_unlimited_g_c = inputs.senescence.respiration_oxygen_unlimited_g_c_per_h,
        .nitrogen_assimilation_respiration_actual_g_c = inputs.metabolism.nitrogen_assimilation_respiration_actual_g_c_per_h,
        .nitrogen_assimilation_respiration_oxygen_unlimited_g_c = inputs.metabolism.nitrogen_assimilation_respiration_oxygen_unlimited_g_c_per_h,
    });
    const next_actual = roots.actual_respiration_g_c_per_h[root_layer] + respiration.actual_g_c;
    const next_oxygen_unlimited = roots.respiration_unlimited_by_oxygen_g_c_per_h[root_layer] + respiration.oxygen_unlimited_g_c;
    const next_carbon_unlimited = roots.respiration_unlimited_by_carbon_g_c_per_h[root_layer] + respiration.carbon_unlimited_g_c;
    inline for (.{ next_mobile_c, next_mobile_n, next_mobile_p, next_c, next_n, next_p, next_length, next_protein, next_actual, next_oxygen_unlimited, next_carbon_unlimited }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteSecondaryRootStateUpdate;
        if (value < 0) return error.SecondaryRootStateUpdateWouldOverdrawPool;
    }
    roots.mobile_carbon_g[root_layer] = next_mobile_c;
    roots.mobile_nitrogen_g[root_layer] = next_mobile_n;
    roots.mobile_phosphorus_g[root_layer] = next_mobile_p;
    roots.axis_secondary_carbon_g[root_axis_layer] = next_c;
    roots.axis_secondary_nitrogen_g[root_axis_layer] = next_n;
    roots.axis_secondary_phosphorus_g[root_axis_layer] = next_p;
    roots.axis_secondary_length_m[root_axis_layer] = next_length;
    roots.protein_carbon_g[root_layer] = next_protein;
    roots.actual_respiration_g_c_per_h[root_layer] = next_actual;
    roots.respiration_unlimited_by_oxygen_g_c_per_h[root_layer] = next_oxygen_unlimited;
    roots.respiration_unlimited_by_carbon_g_c_per_h[root_layer] = next_carbon_unlimited;
}

/// GROSUB RCO2T/RCO2TM assembly for primary and secondary roots.
pub fn assemble(components: group_growth.Components) !group_respiration.Respiration {
    inline for (@typeInfo(group_growth.Components).@"struct".fields) |field| {
        const value = @field(components, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidRootRespirationComponent;
    }
    const actual =
        @min(components.maintenance_demand_g_c, components.substrate_respiration_actual_g_c) +
        components.growth_respiration_actual_g_c +
        components.senescence_respiration_actual_g_c +
        components.nitrogen_assimilation_respiration_actual_g_c;
    const oxygen_unlimited =
        @min(components.maintenance_demand_g_c, components.substrate_respiration_oxygen_unlimited_g_c) +
        components.growth_respiration_oxygen_unlimited_g_c +
        components.senescence_respiration_oxygen_unlimited_g_c +
        components.nitrogen_assimilation_respiration_oxygen_unlimited_g_c;
    const result: group_respiration.Respiration = .{
        .actual_g_c = actual,
        .oxygen_unlimited_g_c = oxygen_unlimited,
        // GROSUB publishes RCO2T into RCO2N. This is the demand subsequently
        // compared with the mobile-C pool by UPTAKE's FCUP.
        .carbon_unlimited_g_c = actual,
    };
    inline for (@typeInfo(group_respiration.Respiration).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteRootRespiration;
    return result;
}

/// Atomic root respiration state_update. Actual respiration consumes mobile
/// carbon and is recorded as a positive CO2 production rate.
pub fn state_update(roots: *RootState, root_layer: usize, respiration: group_respiration.Respiration) !void {
    if (root_layer >= roots.mobile_carbon_g.len) return error.PlantRootIndexOutOfBounds;
    inline for (@typeInfo(group_respiration.Respiration).@"struct".fields) |field| if (!std.math.isFinite(@field(respiration, field.name)) or @field(respiration, field.name) < 0) return error.InvalidRootRespirationStateUpdate;
    const next_mobile = roots.mobile_carbon_g[root_layer] - respiration.actual_g_c;
    const next_actual = roots.actual_respiration_g_c_per_h[root_layer] + respiration.actual_g_c;
    const next_oxygen_unlimited = roots.respiration_unlimited_by_oxygen_g_c_per_h[root_layer] + respiration.oxygen_unlimited_g_c;
    const next_carbon_unlimited = roots.respiration_unlimited_by_carbon_g_c_per_h[root_layer] + respiration.carbon_unlimited_g_c;
    inline for (.{ next_mobile, next_actual, next_oxygen_unlimited, next_carbon_unlimited }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootRespirationStateUpdate;
    if (next_mobile < 0) return error.InsufficientRootMobileCarbonForRespiration;
    roots.mobile_carbon_g[root_layer] = next_mobile;
    roots.actual_respiration_g_c_per_h[root_layer] = next_actual;
    roots.respiration_unlimited_by_oxygen_g_c_per_h[root_layer] = next_oxygen_unlimited;
    roots.respiration_unlimited_by_carbon_g_c_per_h[root_layer] = next_carbon_unlimited;
}

test "root respiration rejects sub-legacy-tolerance overdraw atomically" {
    var roots = try RootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    const root = try roots.layerIndex(0, 0, 0);
    roots.mobile_carbon_g[root] = 1;
    roots.actual_respiration_g_c_per_h[root] = 2;
    roots.respiration_unlimited_by_oxygen_g_c_per_h[root] = 3;
    roots.respiration_unlimited_by_carbon_g_c_per_h[root] = 4;
    try std.testing.expectError(error.InsufficientRootMobileCarbonForRespiration, state_update(&roots, root, .{
        .actual_g_c = 1.0000000000001,
        .oxygen_unlimited_g_c = 1,
        .carbon_unlimited_g_c = 1,
    }));
    try std.testing.expectEqual(@as(f64, 1), roots.mobile_carbon_g[root]);
    try std.testing.expectEqual(@as(f64, 2), roots.actual_respiration_g_c_per_h[root]);
    try std.testing.expectEqual(@as(f64, 3), roots.respiration_unlimited_by_oxygen_g_c_per_h[root]);
    try std.testing.expectEqual(@as(f64, 4), roots.respiration_unlimited_by_carbon_g_c_per_h[root]);
}
