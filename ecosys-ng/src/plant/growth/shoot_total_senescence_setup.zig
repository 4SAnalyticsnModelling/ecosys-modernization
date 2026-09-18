const std = @import("std");

pub const Switch = enum { disabled, enabled };

pub const Inputs = struct {
    shoot_remobilization: Switch,
    phenological_remobilization: Switch,
    perennial_growth_habit: bool,
    plant_leaf_area_m2: f64,
    horizontal_cell_area_m2: f64,
    aboveground_turnover_index: usize,
    leaf_storage_exchange_fraction_per_h_by_turnover: []const f64,
    branch_leaf_and_sheath_carbon_g_c: f64,
    remobilization_elapsed_h: f64,
    full_senescence_duration_h: f64,
    timestep_h: f64,
    excess_maintenance_respiration_g_c_per_timestep: f64,
    structural_presence_threshold_g_c: f64,
    newest_leaf_node: usize,
    lowest_leaf_node: usize,
    runtime_node_count: usize,
};

pub const Setup = struct {
    phenological_respiration_g_c_per_timestep: f64,
    total_senescence_respiration_g_c_per_timestep: f64,
    phenological_fraction: f64,
    node_group_count: usize,
    first_preceding_node: usize,
};

/// grosub.f lines 2829--2842. Uses plant-total leaf area (`ARLFP`), branch
/// leaf+sheath carbon, runtime turnover coefficients, and logical node ordinals.
/// Null corresponds to SNCX <= the plant structural-presence threshold.
pub fn calculate(inputs: Inputs) !?Setup {
    inline for (.{
        inputs.plant_leaf_area_m2,
        inputs.horizontal_cell_area_m2,
        inputs.branch_leaf_and_sheath_carbon_g_c,
        inputs.remobilization_elapsed_h,
        inputs.full_senescence_duration_h,
        inputs.timestep_h,
        inputs.excess_maintenance_respiration_g_c_per_timestep,
        inputs.structural_presence_threshold_g_c,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteShootSenescenceSetupInput;
    if (inputs.plant_leaf_area_m2 < 0 or inputs.horizontal_cell_area_m2 <= 0 or
        inputs.branch_leaf_and_sheath_carbon_g_c < 0 or inputs.remobilization_elapsed_h < 0 or
        inputs.full_senescence_duration_h <= 0 or inputs.timestep_h <= 0 or
        inputs.excess_maintenance_respiration_g_c_per_timestep < 0 or
        inputs.structural_presence_threshold_g_c < 0 or inputs.runtime_node_count == 0 or
        inputs.newest_leaf_node < inputs.lowest_leaf_node or inputs.newest_leaf_node >= inputs.runtime_node_count)
        return error.InvalidShootSenescenceSetupInput;

    var phenological_g_c: f64 = 0;
    if (inputs.shoot_remobilization == .enabled and
        inputs.phenological_remobilization == .enabled and
        inputs.perennial_growth_habit)
    {
        if (inputs.aboveground_turnover_index >= inputs.leaf_storage_exchange_fraction_per_h_by_turnover.len)
            return error.ShootSenescenceTurnoverIndexOutOfBounds;
        const exchange_per_h = inputs.leaf_storage_exchange_fraction_per_h_by_turnover[inputs.aboveground_turnover_index];
        if (!std.math.isFinite(exchange_per_h) or exchange_per_h < 0)
            return error.InvalidShootSenescenceTurnoverCoefficient;
        const plant_leaf_area_index = inputs.plant_leaf_area_m2 / inputs.horizontal_cell_area_m2;
        const leaf_area_density_factor = 1.0 + @max(0.0, plant_leaf_area_index - 4.0);
        phenological_g_c = exchange_per_h * leaf_area_density_factor *
            inputs.branch_leaf_and_sheath_carbon_g_c *
            @min(1.0, inputs.remobilization_elapsed_h / inputs.full_senescence_duration_h) *
            inputs.timestep_h;
    }
    const total_g_c = inputs.excess_maintenance_respiration_g_c_per_timestep + phenological_g_c;
    if (!std.math.isFinite(phenological_g_c) or !std.math.isFinite(total_g_c) or
        phenological_g_c < 0 or total_g_c < 0)
        return error.InvalidShootSenescenceSetupResult;
    if (total_g_c <= inputs.structural_presence_threshold_g_c) return null;

    const node_group_count = (inputs.newest_leaf_node - inputs.lowest_leaf_node) / 2 + 1;
    const first_preceding_node = inputs.lowest_leaf_node -| 1;
    return .{
        .phenological_respiration_g_c_per_timestep = phenological_g_c,
        .total_senescence_respiration_g_c_per_timestep = total_g_c,
        .phenological_fraction = phenological_g_c / total_g_c,
        .node_group_count = node_group_count,
        .first_preceding_node = first_preceding_node,
    };
}

fn sampleInputs() Inputs {
    return .{
        .shoot_remobilization = .enabled,
        .phenological_remobilization = .enabled,
        .perennial_growth_habit = true,
        .plant_leaf_area_m2 = 12,
        .horizontal_cell_area_m2 = 2,
        .aboveground_turnover_index = 2,
        .leaf_storage_exchange_fraction_per_h_by_turnover = &.{ 0.01, 0.02, 0.03, 0.04 },
        .branch_leaf_and_sheath_carbon_g_c = 10,
        .remobilization_elapsed_h = 50,
        .full_senescence_duration_h = 100,
        .timestep_h = 0.25,
        .excess_maintenance_respiration_g_c_per_timestep = 0.1,
        .structural_presence_threshold_g_c = 1.0e-12,
        .newest_leaf_node = 30,
        .lowest_leaf_node = 5,
        .runtime_node_count = 40,
    };
}

test "GROSUB total senescence uses plant leaf area density" {
    const result = (try calculate(sampleInputs())).?;
    // LAI=6, FSNCZ=1+max(0,6-4)=3.
    const phenological = 0.03 * 3 * 10 * 0.5 * 0.25;
    try std.testing.expectApproxEqAbs(phenological, result.phenological_respiration_g_c_per_timestep, 1.0e-15);
    try std.testing.expectApproxEqAbs(0.1 + phenological, result.total_senescence_respiration_g_c_per_timestep, 1.0e-15);
    try std.testing.expectApproxEqAbs(phenological / (0.1 + phenological), result.phenological_fraction, 1.0e-15);
    try std.testing.expectEqual(@as(usize, 13), result.node_group_count);
    try std.testing.expectEqual(@as(usize, 4), result.first_preceding_node);
}

test "inactive phenology retains maintenance demand only" {
    var inputs = sampleInputs();
    inputs.phenological_remobilization = .disabled;
    inputs.aboveground_turnover_index = 99;
    inputs.leaf_storage_exchange_fraction_per_h_by_turnover = &.{};
    const result = (try calculate(inputs)).?;
    try std.testing.expectEqual(@as(f64, 0), result.phenological_respiration_g_c_per_timestep);
    try std.testing.expectEqual(@as(f64, 0.1), result.total_senescence_respiration_g_c_per_timestep);
    try std.testing.expectEqual(@as(f64, 0), result.phenological_fraction);
}

test "source presence threshold suppresses node metadata" {
    var inputs = sampleInputs();
    inputs.shoot_remobilization = .disabled;
    inputs.excess_maintenance_respiration_g_c_per_timestep = 1.0e-13;
    try std.testing.expectEqual(@as(?Setup, null), try calculate(inputs));
}

test "runtime turnover and node topology errors fail explicitly" {
    var inputs = sampleInputs();
    inputs.aboveground_turnover_index = 4;
    try std.testing.expectError(error.ShootSenescenceTurnoverIndexOutOfBounds, calculate(inputs));
    inputs = sampleInputs();
    inputs.newest_leaf_node = 40;
    try std.testing.expectError(error.InvalidShootSenescenceSetupInput, calculate(inputs));
}
