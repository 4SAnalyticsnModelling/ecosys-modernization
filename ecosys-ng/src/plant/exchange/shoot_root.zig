const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const Canopy = @import("../../canopy/photosynthesis/photosynthesis.zig");
const Growth = @import("../lifecycle/growth_stages.zig");
const Roots = @import("../root/plant_root_system.zig");
const RootMetabolism = @import("../root/plant_root_metabolism.zig");
const InternalActivity = @import("../accounting/internal_root_shoot_activity.zig");

pub const Parameters = struct {
    minimum_partner_structural_ratio: f64,
    minimum_annual_carbon_exchange_fraction_per_h: f64,
    annual_leaf_partition_exponent: f64,
    salt_exchange_fraction_per_h: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidShootRootExchangeParameter;
        }
        if (self.minimum_partner_structural_ratio > 1) return error.InvalidShootRootExchangeParameter;
    }
};

pub fn compatibilityParameters() Parameters {
    return .{
        .minimum_partner_structural_ratio = 0.05,
        .minimum_annual_carbon_exchange_fraction_per_h = 0.005,
        .annual_leaf_partition_exponent = 0.25,
        .salt_exchange_fraction_per_h = 1,
    };
}

pub const Inputs = struct {
    perennial: bool,
    base_exchange_fraction_per_h: f64,
    leaf_plus_sheath_partition_fraction: f64,
    timestep_h: f64,
    branch_layer_weight: f64,
    root_branch_weight: f64,
    branch_nonwoody_structural_carbon_g_c: f64,
    root_nonwoody_structural_carbon_g_c: f64,
    branch_mobile_carbon_g_c: f64,
    branch_mobile_nitrogen_g_n: f64,
    branch_mobile_phosphorus_g_p: f64,
    root_mobile_carbon_g_c: f64,
    root_mobile_nitrogen_g_n: f64,
    root_mobile_phosphorus_g_p: f64,
};

/// Positive values move from shoot to root; negative values move root to
/// shoot. These are the exact GROSUB CPOOLD/ZPOOLD/PPOOLD equations for one
/// branch-layer pair.
pub const Transfer = struct {
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
};

/// Exact GROSUB 8296-8338 pair calculation, including the source's strict
/// plant-specific CPOOL total threshold for enabling N and P exchange.
pub fn sourceOrderCalculate(
    parameters: Parameters,
    inputs: Inputs,
    mobile_carbon_presence_threshold_g_c: f64,
) !Transfer {
    if (!std.math.isFinite(mobile_carbon_presence_threshold_g_c) or mobile_carbon_presence_threshold_g_c < 0)
        return error.InvalidShootRootExchangeInput;
    return calculateWithThreshold(parameters, inputs, mobile_carbon_presence_threshold_g_c);
}

/// Zero-threshold calculation retained for isolated callers. Production uses
/// `sourceOrderCalculate` with the population-scaled plant threshold.
pub fn calculate(parameters: Parameters, inputs: Inputs) !Transfer {
    return calculateWithThreshold(parameters, inputs, 0);
}

fn calculateWithThreshold(parameters: Parameters, inputs: Inputs, mobile_carbon_presence_threshold_g_c: f64) !Transfer {
    try parameters.validate();
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (field.type == f64) {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidShootRootExchangeInput;
    };
    inline for (.{ inputs.leaf_plus_sheath_partition_fraction, inputs.branch_layer_weight, inputs.root_branch_weight }) |value| if (value > 1) return error.InvalidShootRootExchangeInput;

    const shoot_structural = inputs.branch_nonwoody_structural_carbon_g_c;
    const root_structural = inputs.root_nonwoody_structural_carbon_g_c;
    const weighted_shoot = @max(shoot_structural, parameters.minimum_partner_structural_ratio * root_structural);
    const weighted_root = @max(root_structural, parameters.minimum_partner_structural_ratio * shoot_structural);
    const structural_total = weighted_shoot + weighted_root;
    // GROSUB 8314 uses the population-scaled ZEROP gate for the weighted
    // structural pair, independently of the later CPOOLT nutrient gate.
    if (structural_total <= mobile_carbon_presence_threshold_g_c)
        return .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };

    const branch_c = @max(0, inputs.branch_mobile_carbon_g_c * inputs.branch_layer_weight);
    const root_c = @max(0, inputs.root_mobile_carbon_g_c * inputs.root_branch_weight);
    const carbon_difference = (branch_c * weighted_root - root_c * weighted_shoot) / structural_total;
    const carbon_rate = if (inputs.perennial)
        inputs.base_exchange_fraction_per_h
    else
        @max(parameters.minimum_annual_carbon_exchange_fraction_per_h, inputs.base_exchange_fraction_per_h * std.math.pow(f64, inputs.leaf_plus_sheath_partition_fraction, parameters.annual_leaf_partition_exponent));
    const carbon = carbon_rate * carbon_difference * inputs.timestep_h;

    var nitrogen: f64 = 0;
    var phosphorus: f64 = 0;
    const mobile_carbon_total = branch_c + root_c;
    if (mobile_carbon_total > mobile_carbon_presence_threshold_g_c) {
        const branch_n = @max(0, inputs.branch_mobile_nitrogen_g_n * inputs.branch_layer_weight);
        const root_n = @max(0, inputs.root_mobile_nitrogen_g_n * inputs.root_branch_weight);
        nitrogen = inputs.base_exchange_fraction_per_h * (branch_n * root_c - root_n * branch_c) / mobile_carbon_total * inputs.timestep_h;
        const branch_p = @max(0, inputs.branch_mobile_phosphorus_g_p * inputs.branch_layer_weight);
        const root_p = @max(0, inputs.root_mobile_phosphorus_g_p * inputs.root_branch_weight);
        phosphorus = inputs.base_exchange_fraction_per_h * (branch_p * root_c - root_p * branch_c) / mobile_carbon_total * inputs.timestep_h;
    }
    const result: Transfer = .{ .carbon_g_c = carbon, .nitrogen_g_n = nitrogen, .phosphorus_g_p = phosphorus };
    inline for (@typeInfo(Transfer).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteShootRootExchange;
    return result;
}

pub const SourceOrderSinkWeights = struct {
    canopy_balance: f64,
    root_balance: f64,
    root_layer_weight: f64,
};

/// GROSUB 8241-8257 FWTC/FWTS/FWTR. The third threshold parameter deliberately
/// has no unit suffix: source reuses the plant-mass ZEROP value for a root sink
/// strength measured in metres.
pub fn sourceOrderSinkWeights(
    total_shoot_carbon_g_c: f64,
    total_root_carbon_g_c: f64,
    layer_root_sink_strength_m: f64,
    total_root_sink_strength_m: f64,
    plant_presence_threshold_g_c: f64,
    source_reused_sink_threshold: f64,
) !SourceOrderSinkWeights {
    inline for (.{
        total_shoot_carbon_g_c,
        total_root_carbon_g_c,
        layer_root_sink_strength_m,
        total_root_sink_strength_m,
        plant_presence_threshold_g_c,
        source_reused_sink_threshold,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidShootRootExchangeInput;
    return .{
        .canopy_balance = if (total_shoot_carbon_g_c > plant_presence_threshold_g_c)
            @min(1, 0.667 * total_root_carbon_g_c / total_shoot_carbon_g_c)
        else
            1,
        .root_balance = if (total_root_carbon_g_c > plant_presence_threshold_g_c)
            @min(1, total_shoot_carbon_g_c / (0.667 * total_root_carbon_g_c))
        else
            1,
        .root_layer_weight = if (total_root_sink_strength_m > source_reused_sink_threshold)
            @max(0, layer_root_sink_strength_m / total_root_sink_strength_m)
        else
            1,
    };
}

/// Runtime reconstruction of source plant-level `NIX`: the deepest host-root
/// layer occupied by any active axis, never shallower than planting layer.
fn deepestRootedLayer(roots: *const Roots.State, plant: usize) !usize {
    if (plant >= roots.plant_count) return error.ShootRootExchangeDimensionMismatch;
    var deepest = roots.planting_layer_by_plant[plant];
    if (deepest >= roots.soil_layer_count) return error.ShootRootExchangeDimensionMismatch;
    const axis_count = roots.active_root_axis_count[plant];
    if (axis_count > roots.root_axis_count) return error.ShootRootExchangeDimensionMismatch;
    for (0..axis_count) |axis| for (deepest..roots.soil_layer_count) |layer| {
        const axis_layer = try roots.layerAxisIndex(plant, 0, layer, axis);
        const occupied = roots.axis_primary_carbon_g[axis_layer] > 0 or
            roots.axis_secondary_carbon_g[axis_layer] > 0 or
            roots.axis_primary_length_m[axis_layer] > 0 or
            roots.axis_secondary_length_m[axis_layer] > 0;
        if (occupied) deepest = layer;
    };
    return deepest;
}

pub fn validatePairStateUpdate(inputs: Inputs, transfer: Transfer) !void {
    inline for (.{
        inputs.branch_mobile_carbon_g_c - transfer.carbon_g_c,
        inputs.root_mobile_carbon_g_c + transfer.carbon_g_c,
        inputs.branch_mobile_nitrogen_g_n - transfer.nitrogen_g_n,
        inputs.root_mobile_nitrogen_g_n + transfer.nitrogen_g_n,
        inputs.branch_mobile_phosphorus_g_p - transfer.phosphorus_g_p,
        inputs.root_mobile_phosphorus_g_p + transfer.phosphorus_g_p,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.ShootRootExchangeWouldOverdraw;
}

/// Exact GROSUB 8366-8434 root-shoot salt gradient for one species. Positive
/// transfer is shoot to root.
pub fn sourceOrderSaltTransfer(
    shoot_salt_mol: f64,
    root_salt_mol: f64,
    shoot_structural_carbon_g_c: f64,
    root_structural_carbon_g_c: f64,
    exchange_fraction_per_h: f64,
    timestep_h: f64,
) !f64 {
    inline for (.{
        shoot_salt_mol,
        root_salt_mol,
        shoot_structural_carbon_g_c,
        root_structural_carbon_g_c,
        exchange_fraction_per_h,
        timestep_h,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidShootRootSaltExchangeInput;
    const structural_total_g_c = shoot_structural_carbon_g_c + root_structural_carbon_g_c;
    if (structural_total_g_c == 0) return error.MissingShootRootSaltExchangeStructure;
    const difference_mol =
        (shoot_salt_mol * root_structural_carbon_g_c -
            root_salt_mol * shoot_structural_carbon_g_c) /
        structural_total_g_c;
    const transfer_mol = exchange_fraction_per_h * difference_mol * timestep_h;
    if (!std.math.isFinite(transfer_mol)) return error.NonFiniteShootRootSaltExchange;
    return transfer_mol;
}

pub const ApplyContext = struct {
    canopy: *Canopy.State,
    roots: *Roots.State,
    growth_stages: *const Growth.State,
    active_by_plant: []const bool,
    /// Current-hour GROSUB FWODR(1), published by preceding WATSUB from the
    /// same carried WTSTK/WVSTK snapshot used throughout GROSUB.
    root_nonwoody_fraction_by_plant: []const f64,
    carried_total_root_carbon_g_c_by_plant: []const f64,
    plant_parameters: []const RootMetabolism.RuntimePlantParameters,
    parameters: Parameters,
    structural_presence_threshold_g_per_plant: f64,
    timestep_h: f64,
    salinity_enabled_by_cell: []const bool,
    accepted_activity: *InternalActivity.State,
};

/// Live GROSUB 310/415 branch×root-layer C/N/P equilibration. Cells are
/// disjoint and may execute in parallel; pairs retain source serial order.
pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    try context.parameters.validate();
    const plant_count = context.roots.plant_count;
    inline for (.{
        context.active_by_plant.len,
        context.root_nonwoody_fraction_by_plant.len,
        context.carried_total_root_carbon_g_c_by_plant.len,
        context.plant_parameters.len,
    }) |count| if (count != plant_count) return error.ShootRootExchangeDimensionMismatch;
    if (context.canopy.plant_branch_offsets.len != plant_count + 1 or context.growth_stages.plant_count != plant_count or
        context.canopy.species_count == 0 or range.first > range.end or range.end > context.canopy.cell_count or
        context.salinity_enabled_by_cell.len != context.canopy.cell_count or
        context.accepted_activity.cell_count != context.canopy.cell_count or
        context.accepted_activity.soil_layer_count != context.roots.soil_layer_count)
        return error.ShootRootExchangeDimensionMismatch;
    inline for (.{ context.structural_presence_threshold_g_per_plant, context.timestep_h }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidShootRootExchangeInput;
    if (context.timestep_h == 0) return;

    for (range.first..range.end) |cell| for (0..context.canopy.species_count) |species| {
        const plant = cell * context.canopy.species_count + species;
        if (!context.active_by_plant[plant]) continue;
        const population = context.canopy.plant_population_count[plant];
        if (!std.math.isFinite(population) or population < 0)
            return error.InvalidShootRootExchangeInput;
        const structural_presence_threshold_g_c =
            context.structural_presence_threshold_g_per_plant * population;
        if (!std.math.isFinite(structural_presence_threshold_g_c))
            return error.InvalidShootRootExchangeInput;
        const plant_parameters = context.plant_parameters[plant];
        const deepest_rooted_layer = try deepestRootedLayer(context.roots, plant);
        const branches = try context.canopy.branchRange(plant);
        var total_shoot_structural_carbon_g_c: f64 = 0;
        for (branches.first..branches.end) |branch| {
            total_shoot_structural_carbon_g_c += context.canopy.branch_leaf_carbon_g[branch] + context.canopy.branch_sheath_carbon_g[branch];
        }
        // GROSUB 8210--8227 reconstructs WTRTL immediately before the
        // shoot-root sweep: secondary C stays in-layer and complete primary
        // axes are assigned to their occupied tip layer.
        for (0..plant_parameters.biologicalDomainCount()) |domain|
            try context.roots.refreshActiveCarbonByLayer(plant, domain);
        // GROSUB uses NU..NI, i.e. every soil layer from the top through the
        // current plant-specific rooted boundary. This deliberately includes
        // layers above a deeper sowing/planting layer.
        const carried_shoot_structural_carbon_g_c = context.canopy.plant_leaf_sheath_carbon_g[plant];
        const carried_root_carbon_g_c = context.carried_total_root_carbon_g_c_by_plant[plant];
        inline for (.{ carried_shoot_structural_carbon_g_c, carried_root_carbon_g_c }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidShootRootExchangeInput;
        const canopy_balance = if (carried_shoot_structural_carbon_g_c > structural_presence_threshold_g_c)
            @min(1, 0.667 * carried_root_carbon_g_c / carried_shoot_structural_carbon_g_c)
        else
            1;
        const root_balance = if (carried_root_carbon_g_c > structural_presence_threshold_g_c)
            @min(1, carried_shoot_structural_carbon_g_c / (0.667 * carried_root_carbon_g_c))
        else
            1;
        const root_nonwoody_fraction = context.root_nonwoody_fraction_by_plant[plant];
        if (!std.math.isFinite(root_nonwoody_fraction) or root_nonwoody_fraction < 0 or root_nonwoody_fraction > 1)
            return error.InvalidShootRootExchangeInput;
        var total_root_sink_strength_m: f64 = 0;
        for (0..deepest_rooted_layer + 1) |layer|
            total_root_sink_strength_m += context.roots.sink_strength_m[try context.roots.layerIndex(plant, 0, layer)];

        for (branches.first..branches.end) |branch| {
            if (context.growth_stages.branches[branch].dead) continue;
            const branch_structural = context.canopy.branch_leaf_carbon_g[branch] + context.canopy.branch_sheath_carbon_g[branch];
            const branch_weight = if (total_shoot_structural_carbon_g_c > structural_presence_threshold_g_c)
                @max(0, branch_structural / total_shoot_structural_carbon_g_c)
            else
                1;
            for (0..deepest_rooted_layer + 1) |layer| {
                const root = try context.roots.layerIndex(plant, 0, layer);
                const layer_weight = if (total_root_sink_strength_m > structural_presence_threshold_g_c)
                    @max(0, context.roots.sink_strength_m[root] / total_root_sink_strength_m)
                else
                    1;
                const inputs: Inputs = .{
                    .perennial = plant_parameters.growth_habit != 0,
                    .base_exchange_fraction_per_h = plant_parameters.shoot_root_equilibration_fraction_per_h,
                    .leaf_plus_sheath_partition_fraction = context.canopy.plant_leaf_sheath_partition_fraction[plant],
                    .timestep_h = context.timestep_h,
                    .branch_layer_weight = layer_weight,
                    .root_branch_weight = branch_weight,
                    .branch_nonwoody_structural_carbon_g_c = branch_structural * layer_weight * canopy_balance,
                    .root_nonwoody_structural_carbon_g_c = context.roots.total_carbon_g[root] * root_nonwoody_fraction * branch_weight * root_balance,
                    .branch_mobile_carbon_g_c = context.canopy.branch_mobile_carbon_g[branch],
                    .branch_mobile_nitrogen_g_n = context.canopy.branch_mobile_nitrogen_g[branch],
                    .branch_mobile_phosphorus_g_p = context.canopy.branch_mobile_phosphorus_g[branch],
                    .root_mobile_carbon_g_c = context.roots.mobile_carbon_g[root],
                    .root_mobile_nitrogen_g_n = context.roots.mobile_nitrogen_g[root],
                    .root_mobile_phosphorus_g_p = context.roots.mobile_phosphorus_g[root],
                };
                const transfer = try sourceOrderCalculate(
                    context.parameters,
                    inputs,
                    structural_presence_threshold_g_c,
                );
                try validatePairStateUpdate(inputs, transfer);
                var accepted: InternalActivity.Transfer = .{
                    .carbon_g_c = transfer.carbon_g_c,
                    .nitrogen_g_n = transfer.nitrogen_g_n,
                    .phosphorus_g_p = transfer.phosphorus_g_p,
                };
                if (context.salinity_enabled_by_cell[cell]) {
                    const weighted_shoot = @max(
                        inputs.branch_nonwoody_structural_carbon_g_c,
                        context.parameters.minimum_partner_structural_ratio * inputs.root_nonwoody_structural_carbon_g_c,
                    );
                    const weighted_root = @max(
                        inputs.root_nonwoody_structural_carbon_g_c,
                        context.parameters.minimum_partner_structural_ratio * inputs.branch_nonwoody_structural_carbon_g_c,
                    );
                    // Salt exchange is nested inside the same GROSUB 8314
                    // weighted-structure gate as C/N/P, but uses raw WTLSB
                    // and WTRTL concentrations once admitted.
                    if (weighted_shoot + weighted_root > structural_presence_threshold_g_c) for (0..Roots.salt_species_count) |salt| {
                        const branch_salt = branch * Roots.salt_species_count + salt;
                        const root_salt = root * Roots.salt_species_count + salt;
                        const salt_transfer_mol = try sourceOrderSaltTransfer(
                            context.canopy.branch_salt_content_by_species_mol[branch_salt],
                            context.roots.salt_content_mol[root_salt],
                            branch_structural,
                            context.roots.total_carbon_g[root],
                            context.parameters.salt_exchange_fraction_per_h,
                            context.timestep_h,
                        );
                        const next_branch = context.canopy.branch_salt_content_by_species_mol[branch_salt] - salt_transfer_mol;
                        const next_root = context.roots.salt_content_mol[root_salt] + salt_transfer_mol;
                        if (!std.math.isFinite(next_branch) or !std.math.isFinite(next_root) or next_branch < 0 or next_root < 0)
                            return error.ShootRootSaltExchangeWouldOverdraw;
                        accepted.salt_mol[salt] = salt_transfer_mol;
                    };
                }
                // All paired state and sidecar values are now admissible.
                // Publish the exact source transfer before infallible scalar
                // assignments so a rejected pair leaves neither side changed.
                try context.accepted_activity.recordSignedCanopyToRoot(cell, layer, accepted);
                context.canopy.branch_mobile_carbon_g[branch] -= transfer.carbon_g_c;
                context.canopy.branch_mobile_nitrogen_g[branch] -= transfer.nitrogen_g_n;
                context.canopy.branch_mobile_phosphorus_g[branch] -= transfer.phosphorus_g_p;
                context.roots.mobile_carbon_g[root] += transfer.carbon_g_c;
                context.roots.mobile_nitrogen_g[root] += transfer.nitrogen_g_n;
                context.roots.mobile_phosphorus_g[root] += transfer.phosphorus_g_p;
                if (context.salinity_enabled_by_cell[cell]) for (0..Roots.salt_species_count) |salt| {
                    const salt_transfer_mol = accepted.salt_mol[salt];
                    const branch_salt = branch * Roots.salt_species_count + salt;
                    const root_salt = root * Roots.salt_species_count + salt;
                    context.canopy.branch_salt_content_by_species_mol[branch_salt] -= salt_transfer_mol;
                    context.roots.salt_content_mol[root_salt] += salt_transfer_mol;
                };
            }
        }
    };
}

test "GROSUB shoot-root pair exchange preserves source gradients" {
    const inputs: Inputs = .{
        .perennial = false,
        .base_exchange_fraction_per_h = 0.1,
        .leaf_plus_sheath_partition_fraction = 1,
        .timestep_h = 1,
        .branch_layer_weight = 1,
        .root_branch_weight = 1,
        .branch_nonwoody_structural_carbon_g_c = 4,
        .root_nonwoody_structural_carbon_g_c = 2,
        .branch_mobile_carbon_g_c = 3,
        .branch_mobile_nitrogen_g_n = 0.2,
        .branch_mobile_phosphorus_g_p = 0.03,
        .root_mobile_carbon_g_c = 1,
        .root_mobile_nitrogen_g_n = 0.1,
        .root_mobile_phosphorus_g_p = 0.01,
    };
    const transfer = try calculate(compatibilityParameters(), inputs);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 30.0), transfer.carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.0025), transfer.nitrogen_g_n, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0), transfer.phosphorus_g_p, 1.0e-15);
    try validatePairStateUpdate(inputs, transfer);
}

test "GROSUB shoot-root source threshold suppresses nutrient exchange only" {
    const inputs: Inputs = .{
        .perennial = true,
        .base_exchange_fraction_per_h = 0.1,
        .leaf_plus_sheath_partition_fraction = 1,
        .timestep_h = 1,
        .branch_layer_weight = 1,
        .root_branch_weight = 1,
        .branch_nonwoody_structural_carbon_g_c = 2,
        .root_nonwoody_structural_carbon_g_c = 1,
        .branch_mobile_carbon_g_c = 6.0e-13,
        .branch_mobile_nitrogen_g_n = 0.2,
        .branch_mobile_phosphorus_g_p = 0.03,
        .root_mobile_carbon_g_c = 1.0e-13,
        .root_mobile_nitrogen_g_n = 0.1,
        .root_mobile_phosphorus_g_p = 0.01,
    };
    const exact = try sourceOrderCalculate(compatibilityParameters(), inputs, 1.0e-12);
    try std.testing.expect(exact.carbon_g_c != 0);
    try std.testing.expectEqual(@as(f64, 0), exact.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 0), exact.phosphorus_g_p);
    const zero_only = try calculate(compatibilityParameters(), inputs);
    try std.testing.expect(zero_only.nitrogen_g_n != 0);
}

test "GROSUB weighted structural threshold suppresses all shoot-root exchange" {
    const inputs: Inputs = .{
        .perennial = true,
        .base_exchange_fraction_per_h = 0.1,
        .leaf_plus_sheath_partition_fraction = 1,
        .timestep_h = 1,
        .branch_layer_weight = 1,
        .root_branch_weight = 1,
        .branch_nonwoody_structural_carbon_g_c = 2.0e-13,
        .root_nonwoody_structural_carbon_g_c = 3.0e-13,
        .branch_mobile_carbon_g_c = 3,
        .branch_mobile_nitrogen_g_n = 0.2,
        .branch_mobile_phosphorus_g_p = 0.03,
        .root_mobile_carbon_g_c = 1,
        .root_mobile_nitrogen_g_n = 0.1,
        .root_mobile_phosphorus_g_p = 0.01,
    };
    const transfer = try sourceOrderCalculate(compatibilityParameters(), inputs, 1.0e-12);
    try std.testing.expectEqual(Transfer{
        .carbon_g_c = 0,
        .nitrogen_g_n = 0,
        .phosphorus_g_p = 0,
    }, transfer);
}

test "GROSUB shoot-root sink weights preserve strict source boundaries" {
    const weights = try sourceOrderSinkWeights(4, 2, 1, 4, 1.0e-12, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3335), weights.canopy_balance, 1.0e-15);
    try std.testing.expectEqual(@as(f64, 1), weights.root_balance);
    try std.testing.expectEqual(@as(f64, 0.25), weights.root_layer_weight);
    const equality = try sourceOrderSinkWeights(1.0e-12, 1.0e-12, 1.0e-12, 1.0e-12, 1.0e-12, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 1), equality.canopy_balance);
    try std.testing.expectEqual(@as(f64, 1), equality.root_balance);
    try std.testing.expectEqual(@as(f64, 1), equality.root_layer_weight);
}

test "GROSUB dynamic shoot-root salt gradient is signed and conservative" {
    const shoot_to_root = try sourceOrderSaltTransfer(2, 0.5, 4, 2, 0.25, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 12.0), shoot_to_root, 1.0e-15);
    const root_to_shoot = try sourceOrderSaltTransfer(0.5, 2, 4, 2, 0.25, 1);
    try std.testing.expect(root_to_shoot < 0);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), 0.5 - root_to_shoot + 2 + root_to_shoot, 1.0e-15);
    try std.testing.expectError(
        error.MissingShootRootSaltExchangeStructure,
        sourceOrderSaltTransfer(1, 1, 0, 0, 0.25, 1),
    );
}

test "shoot-root state_update rejects either transfer direction overdraw" {
    var inputs: Inputs = .{
        .perennial = true,
        .base_exchange_fraction_per_h = 1,
        .leaf_plus_sheath_partition_fraction = 1,
        .timestep_h = 1,
        .branch_layer_weight = 1,
        .root_branch_weight = 1,
        .branch_nonwoody_structural_carbon_g_c = 1,
        .root_nonwoody_structural_carbon_g_c = 1,
        .branch_mobile_carbon_g_c = 1,
        .branch_mobile_nitrogen_g_n = 1,
        .branch_mobile_phosphorus_g_p = 1,
        .root_mobile_carbon_g_c = 1,
        .root_mobile_nitrogen_g_n = 1,
        .root_mobile_phosphorus_g_p = 1,
    };
    try std.testing.expectError(error.ShootRootExchangeWouldOverdraw, validatePairStateUpdate(inputs, .{ .carbon_g_c = 2, .nitrogen_g_n = 0, .phosphorus_g_p = 0 }));
    inputs.branch_mobile_carbon_g_c = 3;
    try std.testing.expectError(error.ShootRootExchangeWouldOverdraw, validatePairStateUpdate(inputs, .{ .carbon_g_c = -2, .nitrogen_g_n = 0, .phosphorus_g_p = 0 }));
    inputs.branch_mobile_carbon_g_c = 1;
    try std.testing.expectError(
        error.ShootRootExchangeWouldOverdraw,
        validatePairStateUpdate(inputs, .{ .carbon_g_c = 1.0000000000000002, .nitrogen_g_n = 0, .phosphorus_g_p = 0 }),
    );
}

test "live GROSUB shoot root exchange conserves C N P across runtime layers" {
    var canopy = try Canopy.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var roots = try Roots.State.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    var growth = try Growth.State.init(std.testing.allocator, &.{1});
    defer growth.deinit();
    roots.active_root_axis_count[0] = 1;
    canopy.plant_population_count[0] = 1;
    canopy.branch_leaf_carbon_g[0] = 4;
    canopy.plant_leaf_sheath_carbon_g[0] = 4;
    canopy.branch_mobile_carbon_g[0] = 3;
    canopy.branch_mobile_nitrogen_g[0] = 0.2;
    canopy.branch_mobile_phosphorus_g[0] = 0.03;
    canopy.plant_leaf_sheath_partition_fraction[0] = 1;
    const root_0 = try roots.layerIndex(0, 0, 0);
    const root_1 = try roots.layerIndex(0, 0, 1);
    // Production reconstructs total_carbon_g from source-order axis pools
    // immediately before exchange; seed that authoritative inventory rather
    // than the derived cache which refreshActiveCarbonByLayer overwrites.
    roots.axis_primary_carbon_g[try roots.layerAxisIndex(0, 0, 0, 0)] = 2;
    roots.mobile_carbon_g[root_0] = 1;
    roots.mobile_nitrogen_g[root_0] = 0.1;
    roots.mobile_phosphorus_g[root_0] = 0.01;
    roots.sink_strength_m[root_0] = 1;
    // Layer one is allocated but lies below NIX and must not participate.
    roots.mobile_carbon_g[root_1] = 5;
    roots.mobile_nitrogen_g[root_1] = 0.5;
    roots.mobile_phosphorus_g[root_1] = 0.05;
    roots.sink_strength_m[root_1] = 100;
    for (0..Roots.salt_species_count) |salt| {
        canopy.branch_salt_content_by_species_mol[salt] = @floatFromInt(salt + 1);
    }
    const carbon_before = canopy.branch_mobile_carbon_g[0] + roots.mobile_carbon_g[root_0] + roots.mobile_carbon_g[root_1];
    const nitrogen_before = canopy.branch_mobile_nitrogen_g[0] + roots.mobile_nitrogen_g[root_0] + roots.mobile_nitrogen_g[root_1];
    const phosphorus_before = canopy.branch_mobile_phosphorus_g[0] + roots.mobile_phosphorus_g[root_0] + roots.mobile_phosphorus_g[root_1];
    const plant_parameters = [_]RootMetabolism.RuntimePlantParameters{.{
        .root_profile_type = 1,
        .mycorrhizal_type = 2,
        .growth_habit = 1,
        .leaf_phenology_type = 0,
        .root_growth_yield_g_c_per_g_c = 0.7,
        .root_nitrogen_to_carbon_g_n_per_g_c = 0.03,
        .root_phosphorus_to_carbon_g_p_per_g_c = 0.003,
        .stalk_nitrogen_to_carbon_g_n_per_g_c = 0.01,
        .stalk_phosphorus_to_carbon_g_p_per_g_c = 0.001,
        .primary_root_radius_m = 0.001,
        .secondary_root_radius_m = 0.0002,
        .primary_specific_length_m_per_g_c = 10,
        .secondary_specific_length_m_per_g_c = 100,
        .secondary_root_branching_per_m = 20,
        .shoot_root_equilibration_fraction_per_h = 0.1,
    }};
    var context: ApplyContext = .{
        .canopy = &canopy,
        .roots = &roots,
        .growth_stages = &growth,
        .active_by_plant = &.{true},
        .root_nonwoody_fraction_by_plant = &.{1},
        .carried_total_root_carbon_g_c_by_plant = &.{3},
        .plant_parameters = &plant_parameters,
        .parameters = compatibilityParameters(),
        .structural_presence_threshold_g_per_plant = 1.0e-12,
        .timestep_h = 1,
        .salinity_enabled_by_cell = &.{true},
        .accepted_activity = undefined,
    };
    var accepted_activity = try InternalActivity.State.init(std.testing.allocator, 1, 2);
    defer accepted_activity.deinit();
    context.accepted_activity = &accepted_activity;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(roots.mobile_carbon_g[root_0] > 1);
    try std.testing.expectEqual(@as(f64, 5), roots.mobile_carbon_g[root_1]);
    try std.testing.expectEqual(@as(f64, 0.5), roots.mobile_nitrogen_g[root_1]);
    try std.testing.expectEqual(@as(f64, 0.05), roots.mobile_phosphorus_g[root_1]);
    try std.testing.expectApproxEqAbs(carbon_before, canopy.branch_mobile_carbon_g[0] + roots.mobile_carbon_g[root_0] + roots.mobile_carbon_g[root_1], 1.0e-14);
    try std.testing.expectApproxEqAbs(nitrogen_before, canopy.branch_mobile_nitrogen_g[0] + roots.mobile_nitrogen_g[root_0] + roots.mobile_nitrogen_g[root_1], 1.0e-14);
    try std.testing.expectApproxEqAbs(phosphorus_before, canopy.branch_mobile_phosphorus_g[0] + roots.mobile_phosphorus_g[root_0] + roots.mobile_phosphorus_g[root_1], 1.0e-14);
    try std.testing.expectEqual(@as(f64, 0), accepted_activity.canopy_to_root[1].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), accepted_activity.root_to_canopy[1].carbon_g_c);
    try std.testing.expectApproxEqAbs(
        roots.mobile_carbon_g[root_0] - 1,
        accepted_activity.canopy_to_root[0].carbon_g_c - accepted_activity.root_to_canopy[0].carbon_g_c,
        1.0e-14,
    );
    for (0..Roots.salt_species_count) |salt| {
        const expected_total_mol: f64 = @floatFromInt(salt + 1);
        try std.testing.expect(roots.salt_content_mol[salt] > 0);
        try std.testing.expectApproxEqAbs(expected_total_mol, canopy.branch_salt_content_by_species_mol[salt] + roots.salt_content_mol[salt], 1.0e-14);
        try std.testing.expectApproxEqAbs(
            roots.salt_content_mol[salt],
            accepted_activity.canopy_to_root[0].salt_mol[salt] - accepted_activity.root_to_canopy[0].salt_mol[salt],
            1.0e-14,
        );
    }
}
