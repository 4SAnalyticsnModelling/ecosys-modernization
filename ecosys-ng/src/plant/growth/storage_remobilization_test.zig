//! Tests for `storage_remobilization.zig`.
//!
//! Extracted so the module beside it carries only model code. Tests
//! that reach a private declaration of that module stay there, since a
//! sibling file can only see `pub` declarations.

const std = @import("std");
const LitterPartition = @import("../partition/litter.zig");
const remobilization = @import("storage_remobilization.zig");

test "GROSUB storage activation preserves planting and leafout lifecycle gates" {
    const base: remobilization.ActivationInputs = .{
        .annual_growth_habit = false,
        .lifecycle_initialized = true,
        .current_day_of_year = 100,
        .current_year = 2020,
        .planting_day_of_year = 120,
        .planting_year = 2020,
        .accumulated_leafout_h = 0,
        .required_leafout_h = 100,
        .accumulated_leafoff_h = 0,
        .required_leafoff_h = 100,
        .leafoff_remobilization_start_fraction = 0.5,
    };
    try std.testing.expect(!try remobilization.activationEnabled(base));
    var annual = base;
    annual.annual_growth_habit = true;
    annual.lifecycle_initialized = false;
    try std.testing.expect(try remobilization.activationEnabled(annual));
    var planting = base;
    planting.current_day_of_year = 120;
    try std.testing.expect(try remobilization.activationEnabled(planting));
    var leafout = base;
    leafout.accumulated_leafout_h = 100;
    try std.testing.expect(try remobilization.activationEnabled(leafout));
    leafout.accumulated_leafoff_h = 50;
    try std.testing.expect(!try remobilization.activationEnabled(leafout));
}

test "GROSUB DATRP uses only TFN3 WFNSG and biological timestep" {
    try std.testing.expectEqual(
        @as(f64, 0.25) * @as(f64, 0.4) * @as(f64, 0.5),
        try remobilization.remobilizationTimeIncrementH(0.25, 0.4, 0.5),
    );
    try std.testing.expectEqual(@as(f64, 1.01), try remobilization.remobilizationTimeIncrementH(1, 1.01, 1));
}

test "GROSUB annual seed storage remobilization conserves C N P" {
    const transfers = try remobilization.calculate(remobilization.compatibilityParameters(), .{
        .growth_habit = 0,
        .aboveground_turnover_type = 0,
        .accumulated_remobilization_h = 1,
        .remobilization_time_increment_h = 1,
        .biological_timestep_h = 1,
        .storage_carbon_g_c = 100,
        .storage_nitrogen_g_n = 10,
        .storage_phosphorus_g_p = 1,
        .shoot_mobile_carbon_g_c = 0,
        .shoot_mobile_nitrogen_g_n = 0,
        .shoot_mobile_phosphorus_g_p = 0,
        .root_mobile_carbon_g_c = 0,
        .root_mobile_nitrogen_g_n = 0,
        .root_mobile_phosphorus_g_p = 0,
        .continue_annual_remobilization_after_duration = true,
        .presence_threshold_g_c = 1.0e-12,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), transfers.oxidized_storage_carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.375), transfers.shoot_carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.125), transfers.root_carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(transfers.oxidized_storage_carbon_g_c, transfers.shoot_carbon_g_c + transfers.root_carbon_g_c, 1.0e-12);
}

test "GROSUB sub-threshold seasonal carbon preserves zero CH2OH and partitions all nutrients" {
    const transfers = try remobilization.calculate(remobilization.compatibilityParameters(), .{
        .growth_habit = 1,
        .aboveground_turnover_type = 0,
        .accumulated_remobilization_h = 1,
        .remobilization_time_increment_h = 1,
        .biological_timestep_h = 1,
        .storage_carbon_g_c = 5.0e-13,
        .storage_nitrogen_g_n = 2,
        .storage_phosphorus_g_p = 0.2,
        .shoot_mobile_carbon_g_c = 1,
        .shoot_mobile_nitrogen_g_n = 0,
        .shoot_mobile_phosphorus_g_p = 0,
        .root_mobile_carbon_g_c = 1,
        .root_mobile_nitrogen_g_n = 0,
        .root_mobile_phosphorus_g_p = 0,
        .continue_annual_remobilization_after_duration = false,
        .presence_threshold_g_c = 1.0e-12,
    });
    try std.testing.expectEqual(@as(f64, 0), transfers.oxidized_storage_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), transfers.shoot_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), transfers.root_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0.5), transfers.shoot_nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 1.5), transfers.root_nitrogen_g_n);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), transfers.shoot_phosphorus_g_p, 1.0e-16);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), transfers.root_phosphorus_g_p, 1.0e-16);
}

test "GROSUB perennial storage nutrient gradients use post CH2OH carbon" {
    const transfers = try remobilization.calculate(remobilization.compatibilityParameters(), .{
        .growth_habit = 1,
        .aboveground_turnover_type = 0,
        .accumulated_remobilization_h = 1,
        .remobilization_time_increment_h = 1,
        .biological_timestep_h = 1,
        .storage_carbon_g_c = 100,
        .storage_nitrogen_g_n = 10,
        .storage_phosphorus_g_p = 1,
        .shoot_mobile_carbon_g_c = 10,
        .shoot_mobile_nitrogen_g_n = 1,
        .shoot_mobile_phosphorus_g_p = 0.1,
        .root_mobile_carbon_g_c = 20,
        .root_mobile_nitrogen_g_n = 1,
        .root_mobile_phosphorus_g_p = 0.1,
        .continue_annual_remobilization_after_duration = false,
        .presence_threshold_g_c = 1.0e-12,
    });
    const remaining_storage_c: f64 = 99.5;
    const post_shoot_c: f64 = 10.125;
    const post_root_c: f64 = 20.375;
    try std.testing.expectApproxEqAbs(
        0.1 * (10 * post_shoot_c - 1 * remaining_storage_c) / (remaining_storage_c + post_shoot_c),
        transfers.shoot_nitrogen_g_n,
        1.0e-14,
    );
    try std.testing.expectApproxEqAbs(
        0.1 * (10 * post_root_c - 1 * remaining_storage_c) / (remaining_storage_c + post_root_c),
        transfers.root_nitrogen_g_n,
        1.0e-14,
    );
    // A pre-carbon translation gives different results and must not re-enter.
    const stale_pre_carbon = 0.1 * (10 * 10 - 1 * remaining_storage_c) / (remaining_storage_c + 10);
    try std.testing.expect(@abs(transfers.shoot_nitrogen_g_n - stale_pre_carbon) > 1.0e-6);
}

test "GROSUB storage carbon overdraw fails instead of silently capping CH2OH" {
    var parameters = remobilization.compatibilityParameters();
    parameters.storage_carbon_oxidation_fraction_per_h[0] = 2;
    try std.testing.expectError(error.StorageCarbonRemobilizationWouldOverdraw, remobilization.calculate(parameters, .{
        .growth_habit = 0,
        .aboveground_turnover_type = 0,
        .accumulated_remobilization_h = 1,
        .remobilization_time_increment_h = 1,
        .biological_timestep_h = 1,
        .storage_carbon_g_c = 1,
        .storage_nitrogen_g_n = 0.1,
        .storage_phosphorus_g_p = 0.01,
        .shoot_mobile_carbon_g_c = 0,
        .shoot_mobile_nitrogen_g_n = 0,
        .shoot_mobile_phosphorus_g_p = 0,
        .root_mobile_carbon_g_c = 0,
        .root_mobile_nitrogen_g_n = 0,
        .root_mobile_phosphorus_g_p = 0,
        .continue_annual_remobilization_after_duration = true,
        .presence_threshold_g_c = 1.0e-12,
    }));
}

test "storage remobilization validate rejects shoot/root partition sums below one" {
    // Regression test for STORAGE-REMOB-PARTITION-SUM-001: validate() was
    // tightened from a one-sided `sum > 1 + 1e-12` check to a two-sided
    // `@abs(sum - 1) > 1e-12` check because calculate()/state_update() debit
    // the full oxidized_storage_carbon_g_c but credit only
    // shoot_fraction + root_fraction of it -- a sum below 1 silently leaks
    // carbon with no error. This must stay rejected.
    var below = remobilization.compatibilityParameters();
    below.shoot_carbon_partition_fraction[0] = 0.25;
    below.root_carbon_partition_fraction[0] = 0.65;
    try std.testing.expectError(error.InvalidStorageRemobilizationParameter, below.validate());

    var below_other_habit = remobilization.compatibilityParameters();
    below_other_habit.shoot_carbon_partition_fraction[1] = 0.20;
    below_other_habit.root_carbon_partition_fraction[1] = 0.70;
    try std.testing.expectError(error.InvalidStorageRemobilizationParameter, below_other_habit.validate());

    // Above-one sums must remain rejected too (the pre-existing half of the
    // bound, kept here so a future loosening of either side is caught).
    var above = remobilization.compatibilityParameters();
    above.shoot_carbon_partition_fraction[0] = 0.5;
    above.root_carbon_partition_fraction[0] = 0.75;
    try std.testing.expectError(error.InvalidStorageRemobilizationParameter, above.validate());

    // A sum equal to one (the only value calculate()/state_update() assume)
    // must continue to pass.
    try remobilization.compatibilityParameters().validate();
}

test "GROSUB perennial root transfer applies coupled C N P bounds" {
    const transfer = try remobilization.rootToSeasonalStorage(remobilization.compatibilityParameters(), 10, 0.6, 0.04, 0.1, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), transfer.carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), transfer.nitrogen_g_n, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.004), transfer.phosphorus_g_p, 1.0e-12);
}

test "GROSUB perennial root transfer preserves the exact outer gate" {
    try std.testing.expect(remobilization.sourceOrderRootStorageTransferIsEnabled(true, .perennial));
    try std.testing.expect(!remobilization.sourceOrderRootStorageTransferIsEnabled(false, .perennial));
    try std.testing.expect(!remobilization.sourceOrderRootStorageTransferIsEnabled(true, .annual));
}

test "GROSUB branch mobile reserve exchange uses post-carbon N P gradients" {
    const inputs: remobilization.BranchMobileReserveExchangeInputs = .{
        .growth_habit = .annual,
        .annual_final_seed_number_is_set = true,
        .perennial_stem_elongation_started = false,
        .branch_leaf_and_petiole_carbon_g_c = 10,
        .branch_sapwood_carbon_g_c = 10,
        .branch_mobile = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.08 },
        .branch_reserve = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .maximum_mobile_nitrogen_per_carbon_g_n_per_g_c = 0.2,
        .maximum_mobile_phosphorus_per_carbon_g_p_per_g_c = 0.02,
        .carbon_exchange_fraction_per_h = 0.5,
        .nutrient_exchange_fraction_per_h = 0.25,
        .biological_timestep_h = 1,
        .presence_threshold_g_c = 1.0e-12,
    };
    const result = try remobilization.equilibrateBranchMobileAndReserve(inputs);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), result.mobile_to_reserve.carbon_g_c, 1.0e-15);
    const expected_n = 0.25 * (0.8 * 3.5 - 0.1 * 6.5) / 10.0;
    const expected_p = 0.25 * (0.08 * 3.5 - 0.01 * 6.5) / 10.0;
    try std.testing.expectApproxEqAbs(expected_n, result.mobile_to_reserve.nitrogen_g_n, 1.0e-15);
    try std.testing.expectApproxEqAbs(expected_p, result.mobile_to_reserve.phosphorus_g_p, 1.0e-15);
    inline for (@typeInfo(remobilization.ElementTransfer).@"struct".fields) |field|
        try std.testing.expectApproxEqAbs(@field(inputs.branch_mobile, field.name) + @field(inputs.branch_reserve, field.name), @field(result.next_branch_mobile, field.name) + @field(result.next_branch_reserve, field.name), 1.0e-15);
}

test "GROSUB branch mobile reserve exchange preserves annual perennial gates" {
    const base: remobilization.BranchMobileReserveExchangeInputs = .{
        .growth_habit = .annual,
        .annual_final_seed_number_is_set = false,
        .perennial_stem_elongation_started = true,
        .branch_leaf_and_petiole_carbon_g_c = 10,
        .branch_sapwood_carbon_g_c = 10,
        .branch_mobile = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.08 },
        .branch_reserve = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .maximum_mobile_nitrogen_per_carbon_g_n_per_g_c = 0.2,
        .maximum_mobile_phosphorus_per_carbon_g_p_per_g_c = 0.02,
        .carbon_exchange_fraction_per_h = 0.5,
        .nutrient_exchange_fraction_per_h = 0.25,
        .biological_timestep_h = 1,
        .presence_threshold_g_c = 1.0e-12,
    };
    const annual = try remobilization.equilibrateBranchMobileAndReserve(base);
    try std.testing.expectEqual(@as(f64, 0), annual.mobile_to_reserve.carbon_g_c);
    var perennial = base;
    perennial.growth_habit = .perennial;
    const enabled = try remobilization.equilibrateBranchMobileAndReserve(perennial);
    try std.testing.expect(enabled.mobile_to_reserve.carbon_g_c > 0);
}

test "GROSUB branch mobile reserve exchange rejects signed transfer overdraw" {
    const inputs: remobilization.BranchMobileReserveExchangeInputs = .{
        .growth_habit = .annual,
        .annual_final_seed_number_is_set = true,
        .perennial_stem_elongation_started = false,
        .branch_leaf_and_petiole_carbon_g_c = 10,
        .branch_sapwood_carbon_g_c = 10,
        .branch_mobile = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.08 },
        .branch_reserve = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .maximum_mobile_nitrogen_per_carbon_g_n_per_g_c = 0.2,
        .maximum_mobile_phosphorus_per_carbon_g_p_per_g_c = 0.02,
        .carbon_exchange_fraction_per_h = 20,
        .nutrient_exchange_fraction_per_h = 0.25,
        .biological_timestep_h = 1,
        .presence_threshold_g_c = 1.0e-12,
    };
    try std.testing.expectError(error.BranchMobileReserveExchangeWouldOverdraw, remobilization.equilibrateBranchMobileAndReserve(inputs));
}

test "GROSUB annual root to stalk reserve preserves C N P sequence and conservation" {
    const inputs: remobilization.AnnualRootReserveExchangeInputs = .{
        .growth_habit = .annual,
        .final_seed_number_is_set = true,
        .layer_is_soil = true,
        .active_root_carbon_g_c = 20,
        .root_nonwoody_carbon_fraction = 0.5,
        .branch_sapwood_carbon_g_c = 10,
        .root_mobile = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.08 },
        .branch_reserve = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .carbon_exchange_fraction_per_h = 0.5,
        .nutrient_exchange_fraction_per_h = 0.25,
        .biological_timestep_h = 1,
        .presence_threshold_g_c = 1.0e-12,
    };
    const result = try remobilization.transferAnnualRootMobileToBranchReserve(inputs);
    // WTRTRX=10, WTPLTX=20, CPOOLD=(8*10-2*10)/20=3.
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), result.root_to_reserve.carbon_g_c, 1.0e-15);
    try std.testing.expect(result.root_to_reserve.nitrogen_g_n > 0);
    try std.testing.expect(result.root_to_reserve.phosphorus_g_p > 0);
    inline for (@typeInfo(remobilization.ElementTransfer).@"struct".fields) |field|
        try std.testing.expectApproxEqAbs(@field(inputs.root_mobile, field.name) + @field(inputs.branch_reserve, field.name), @field(result.next_root_mobile, field.name) + @field(result.next_branch_reserve, field.name), 1.0e-15);
}

test "GROSUB annual root reserve exchange preserves lifecycle gates" {
    const base: remobilization.AnnualRootReserveExchangeInputs = .{
        .growth_habit = .perennial,
        .final_seed_number_is_set = true,
        .layer_is_soil = true,
        .active_root_carbon_g_c = 20,
        .root_nonwoody_carbon_fraction = 0.5,
        .branch_sapwood_carbon_g_c = 10,
        .root_mobile = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.08 },
        .branch_reserve = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .carbon_exchange_fraction_per_h = 0.5,
        .nutrient_exchange_fraction_per_h = 0.25,
        .biological_timestep_h = 1,
        .presence_threshold_g_c = 1.0e-12,
    };
    const perennial = try remobilization.transferAnnualRootMobileToBranchReserve(base);
    try std.testing.expectEqual(base.root_mobile, perennial.next_root_mobile);
    var before_seed_set = base;
    before_seed_set.growth_habit = .annual;
    before_seed_set.final_seed_number_is_set = false;
    const result = try remobilization.transferAnnualRootMobileToBranchReserve(before_seed_set);
    try std.testing.expectEqual(@as(f64, 0), result.root_to_reserve.carbon_g_c);
}

test "GROSUB annual root reserve exact phosphorus cap fails unsafe overdraw" {
    const inputs: remobilization.AnnualRootReserveExchangeInputs = .{
        .growth_habit = .annual,
        .final_seed_number_is_set = true,
        .layer_is_soil = true,
        .active_root_carbon_g_c = 10,
        .root_nonwoody_carbon_fraction = 1,
        .branch_sapwood_carbon_g_c = 10,
        .root_mobile = .{ .carbon_g_c = 8, .nitrogen_g_n = 1, .phosphorus_g_p = 0.001 },
        .branch_reserve = .{ .carbon_g_c = 2, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        .carbon_exchange_fraction_per_h = 0,
        .nutrient_exchange_fraction_per_h = 10,
        .biological_timestep_h = 1,
        .presence_threshold_g_c = 1.0e-12,
    };
    try std.testing.expectError(error.AnnualRootReserveExchangeWouldOverdraw, remobilization.transferAnnualRootMobileToBranchReserve(inputs));
}

test "GROSUB branch reserve then mobile remobilization conserves C N P" {
    const inputs: remobilization.BranchStorageRemobilizationInputs = .{
        .shoot_remobilization_enabled = true,
        .growth_habit = .perennial,
        .branch_reserve = .{ .carbon_g_c = 10, .nitrogen_g_n = 0.6, .phosphorus_g_p = 0.04 },
        .branch_mobile = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.05 },
        .seasonal_storage = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 },
        .exchange_fraction_per_h = 0.1,
        .biological_timestep_h = 1,
    };
    const result = try remobilization.remobilizeBranchPoolsToSeasonalStorage(remobilization.compatibilityParameters(), inputs);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), result.reserve_to_storage.carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.mobile_to_storage.carbon_g_c, 1.0e-15);
    inline for (@typeInfo(remobilization.ElementTransfer).@"struct".fields) |field| {
        const before = @field(inputs.branch_reserve, field.name) + @field(inputs.branch_mobile, field.name) + @field(inputs.seasonal_storage, field.name);
        const after = @field(result.next_branch_reserve, field.name) + @field(result.next_branch_mobile, field.name) + @field(result.next_seasonal_storage, field.name);
        try std.testing.expectApproxEqAbs(before, after, 1.0e-14);
    }
}

test "GROSUB branch seasonal remobilization requires enabled perennial branch" {
    const base: remobilization.BranchStorageRemobilizationInputs = .{
        .shoot_remobilization_enabled = false,
        .growth_habit = .perennial,
        .branch_reserve = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.1 },
        .branch_mobile = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.05 },
        .seasonal_storage = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 },
        .exchange_fraction_per_h = 0.1,
        .biological_timestep_h = 1,
    };
    const disabled = try remobilization.remobilizeBranchPoolsToSeasonalStorage(remobilization.compatibilityParameters(), base);
    try std.testing.expectEqual(base.branch_reserve, disabled.next_branch_reserve);
    var annual = base;
    annual.shoot_remobilization_enabled = true;
    annual.growth_habit = .annual;
    const result = try remobilization.remobilizeBranchPoolsToSeasonalStorage(remobilization.compatibilityParameters(), annual);
    try std.testing.expectEqual(annual.branch_mobile, result.next_branch_mobile);
    try std.testing.expectEqual(@as(f64, 0), result.reserve_to_storage.carbon_g_c);
}

test "GROSUB branch seasonal remobilization rejects either donor overdraw" {
    const inputs: remobilization.BranchStorageRemobilizationInputs = .{
        .shoot_remobilization_enabled = true,
        .growth_habit = .perennial,
        .branch_reserve = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .branch_mobile = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 },
        .seasonal_storage = .{},
        .exchange_fraction_per_h = 20,
        .biological_timestep_h = 1,
    };
    try std.testing.expectError(error.BranchStorageRemobilizationWouldOverdraw, remobilization.remobilizeBranchPoolsToSeasonalStorage(remobilization.compatibilityParameters(), inputs));
}

test "GROSUB low branch reserve draws seasonal storage by exact gradient" {
    const inputs: remobilization.LowBranchReserveInputs = .{
        .branch_sapwood_carbon_g_c = 20,
        .plant_total_sapwood_carbon_g_c = 100,
        .plant_total_root_carbon_g_c = 50,
        .branch_reserve_carbon_g_c = 1,
        .seasonal_storage_carbon_g_c = 20,
        .low_reserve_threshold_g_c_per_g_sapwood_c = 0.1,
        .exchange_fraction_per_h = 0.5,
        .biological_timestep_h = 0.25,
        .presence_threshold_g_c = 1.0e-12,
    };
    const result = try remobilization.replenishLowBranchReserve(inputs);
    // FWTBR=0.2, WTRTTX=10, WTRVCX=4, CPOOLD=(4*20-1*10)/30.
    const expected_transfer_g_c = @as(f64, 0.5) * (70.0 / 30.0) * 0.25;
    try std.testing.expectApproxEqAbs(expected_transfer_g_c, result.storage_to_branch_reserve_carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(inputs.branch_reserve_carbon_g_c + expected_transfer_g_c, result.next_branch_reserve_carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(inputs.seasonal_storage_carbon_g_c - expected_transfer_g_c, result.next_seasonal_storage_carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(inputs.branch_reserve_carbon_g_c + inputs.seasonal_storage_carbon_g_c, result.next_branch_reserve_carbon_g_c + result.next_seasonal_storage_carbon_g_c, 1.0e-15);
}

test "GROSUB low branch reserve retains source gates including threshold equality" {
    const base: remobilization.LowBranchReserveInputs = .{
        .branch_sapwood_carbon_g_c = 20,
        .plant_total_sapwood_carbon_g_c = 100,
        .plant_total_root_carbon_g_c = 50,
        .branch_reserve_carbon_g_c = 2,
        .seasonal_storage_carbon_g_c = 20,
        .low_reserve_threshold_g_c_per_g_sapwood_c = 0.1,
        .exchange_fraction_per_h = 0.5,
        .biological_timestep_h = 1,
        .presence_threshold_g_c = 1.0e-12,
    };
    const equality = try remobilization.replenishLowBranchReserve(base);
    try std.testing.expect(equality.storage_to_branch_reserve_carbon_g_c > 0);
    var above = base;
    above.branch_reserve_carbon_g_c = 2.0001;
    const unchanged = try remobilization.replenishLowBranchReserve(above);
    try std.testing.expectEqual(@as(f64, 0), unchanged.storage_to_branch_reserve_carbon_g_c);
    try std.testing.expectEqual(above.seasonal_storage_carbon_g_c, unchanged.next_seasonal_storage_carbon_g_c);
}

test "GROSUB low branch reserve rejects seasonal storage overdraw" {
    const inputs: remobilization.LowBranchReserveInputs = .{
        .branch_sapwood_carbon_g_c = 20,
        .plant_total_sapwood_carbon_g_c = 100,
        .plant_total_root_carbon_g_c = 50,
        .branch_reserve_carbon_g_c = 0,
        .seasonal_storage_carbon_g_c = 1,
        .low_reserve_threshold_g_c_per_g_sapwood_c = 0.1,
        .exchange_fraction_per_h = 100,
        .biological_timestep_h = 1,
        .presence_threshold_g_c = 1.0e-12,
    };
    try std.testing.expectError(error.LowBranchReserveTransferWouldOverdrawStorage, remobilization.replenishLowBranchReserve(inputs));
}

test "GROSUB depleted perennial storage draws root mobile carbon by exact gradient" {
    const inputs: remobilization.DepletedStorageInputs = .{
        .growth_habit = .perennial,
        .layer_is_rooted = true,
        .layer_active_root_carbon_g_c = 20,
        .plant_total_root_carbon_g_c = 100,
        .layer_mobile_carbon_g_c = 4,
        .seasonal_storage_carbon_g_c = 5,
        .storage_deficit_threshold_g_c_per_g_root_c = 0.1,
        .exchange_fraction_per_h = 0.5,
        .biological_timestep_h = 0.25,
        .presence_threshold_g_c = 1.0e-12,
    };
    const result = try remobilization.replenishDepletedSeasonalStorage(inputs);
    // FWTRT=0.2, WTRTTX=20, WTRVCX=1, CPOOLD=(1*20-4*20)/40=-1.5.
    try std.testing.expectApproxEqAbs(@as(f64, 0.1875), result.root_to_storage_carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3.8125), result.next_layer_mobile_carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 5.1875), result.next_seasonal_storage_carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(inputs.layer_mobile_carbon_g_c + inputs.seasonal_storage_carbon_g_c, result.next_layer_mobile_carbon_g_c + result.next_seasonal_storage_carbon_g_c, 1.0e-15);
}

test "GROSUB depleted storage gate leaves annual and sufficient storage unchanged" {
    const base: remobilization.DepletedStorageInputs = .{
        .growth_habit = .annual,
        .layer_is_rooted = true,
        .layer_active_root_carbon_g_c = 20,
        .plant_total_root_carbon_g_c = 100,
        .layer_mobile_carbon_g_c = 4,
        .seasonal_storage_carbon_g_c = 5,
        .storage_deficit_threshold_g_c_per_g_root_c = 0.1,
        .exchange_fraction_per_h = 0.5,
        .biological_timestep_h = 1,
        .presence_threshold_g_c = 1.0e-12,
    };
    const annual = try remobilization.replenishDepletedSeasonalStorage(base);
    try std.testing.expectEqual(@as(f64, 0), annual.root_to_storage_carbon_g_c);
    var sufficient = base;
    sufficient.growth_habit = .perennial;
    sufficient.seasonal_storage_carbon_g_c = 10;
    const result = try remobilization.replenishDepletedSeasonalStorage(sufficient);
    try std.testing.expectEqual(@as(f64, 0), result.root_to_storage_carbon_g_c);
    try std.testing.expectEqual(sufficient.layer_mobile_carbon_g_c, result.next_layer_mobile_carbon_g_c);
}

test "GROSUB depleted storage transfer rejects overdraw atomically" {
    const inputs: remobilization.DepletedStorageInputs = .{
        .growth_habit = .perennial,
        .layer_is_rooted = true,
        .layer_active_root_carbon_g_c = 20,
        .plant_total_root_carbon_g_c = 100,
        .layer_mobile_carbon_g_c = 4,
        .seasonal_storage_carbon_g_c = 5,
        .storage_deficit_threshold_g_c_per_g_root_c = 0.1,
        .exchange_fraction_per_h = 20,
        .biological_timestep_h = 1,
        .presence_threshold_g_c = 1.0e-12,
    };
    try std.testing.expectError(error.DepletedStorageTransferWouldOverdrawRoot, remobilization.replenishDepletedSeasonalStorage(inputs));
}

test "production GROSUB root shoot storage transaction is exact call bound and source ordered" {
    const plant_daily = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/plant_daily.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(plant_daily);
    inline for (.{
        "remobilizeBranchPoolsToSeasonalStorage(",
        "equilibrateBranchMobileAndReserve(",
        "replenishLowBranchReserve(",
        "mainStalkBranch(plant)",
    }) |binding| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plant_daily, binding));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, plant_daily, "mainLivingBranch(plant)"));
    // One dry-run validates the complete layer sequence, one accepted pass
    // commits it and publishes the exact producer sidecar.
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, plant_daily, "transferAnnualRootMobileToBranchReserve("),
    );
    const branch_storage = std.mem.indexOf(u8, plant_daily, "remobilizeBranchPoolsToSeasonalStorage(") orelse return error.MissingBranchStorageBinding;
    const branch_exchange = std.mem.indexOfPos(u8, plant_daily, branch_storage, "equilibrateBranchMobileAndReserve(") orelse return error.MissingBranchReserveBinding;
    const low_reserve = std.mem.indexOfPos(u8, plant_daily, branch_exchange, "replenishLowBranchReserve(") orelse return error.MissingLowReserveBinding;
    const annual_root = std.mem.indexOfPos(u8, plant_daily, low_reserve, "transferAnnualRootMobileToBranchReserve(") orelse return error.MissingAnnualRootReserveBinding;
    try std.testing.expect(branch_storage < branch_exchange and branch_exchange < low_reserve and low_reserve < annual_root);

    const root_metabolism = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/root_processes_metabolism.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(root_metabolism);
    inline for (.{
        "remobilizeBranchPoolsToSeasonalStorage(",
        "equilibrateBranchMobileAndReserve(",
        "replenishLowBranchReserve(",
        "transferAnnualRootMobileToBranchReserve(",
        "plant_dormancy.advanceRemobilization(",
    }) |duplicate| try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, root_metabolism, duplicate));

    const shoot_growth = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/plant/growth/shoot_growth_runtime.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(shoot_growth);
    // GROSUB pre-emergence shoot respiration is canopy carbon whose accepted
    // CO2 recipient is the planting-root layer. It must have exactly one
    // producer and may not be inferred later from cumulative root state.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, shoot_growth, "accepted_internal_activity.recordCanopyToRoot("),
    );

    const hourly = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_vegetation.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(hourly);
    inline for (.{
        "plant_daily.applyPerennialRootSeasonalStorage(",
        "plant_shoot_root_exchange.applyTile",
        "accumulatePlantInternalRootShoot(",
        ".accepted_internal_activity = &plant_internal_activity",
    }) |binding| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, hourly, binding));
    const early_storage = std.mem.indexOf(u8, hourly, "plant_daily.applyPlantStorageRemobilization(") orelse return error.MissingStorageStageBinding;
    const root_processes = std.mem.indexOfPos(u8, hourly, early_storage, "root_processes.applyRootMetabolism(") orelse return error.MissingRootMetabolismBinding;
    const root_mycorrhiza = std.mem.indexOfPos(u8, hourly, root_processes, "plant_root_mycorrhizal_exchange.applyTile") orelse return error.MissingRootMycorrhizalBinding;
    const root_storage = std.mem.indexOfPos(u8, hourly, root_mycorrhiza, "plant_daily.applyPerennialRootSeasonalStorage(") orelse return error.MissingRootSeasonalStorageBinding;
    const shoot_root = std.mem.indexOfPos(u8, hourly, root_storage, "plant_shoot_root_exchange.applyTile") orelse return error.MissingShootRootBinding;
    const publication = std.mem.indexOfPos(u8, hourly, shoot_root, "accumulatePlantInternalRootShoot(") orelse return error.MissingPlantInternalPublication;
    try std.testing.expect(early_storage < root_processes and root_processes < root_mycorrhiza and root_mycorrhiza < root_storage and root_storage < shoot_root and shoot_root < publication);
}
