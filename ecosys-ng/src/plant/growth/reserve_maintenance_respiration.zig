const std = @import("std");

pub const ShootRemobilizationStatus = enum {
    not_started,
    active,
};

pub const State = struct {
    reserve_carbon_g_c: []f64,
    excess_maintenance_respiration_g_c_per_timestep: []f64,
};

pub const Inputs = struct {
    branch: usize,
    shoot_remobilization_status: ShootRemobilizationStatus,
    maximum_nonstructural_carbon_oxidation_per_h: f64,
    canopy_growth_temperature_response: f64,
    timestep_h: f64,
};

/// grosub.f lines 2795--2801. Consumes branch stalk-reserve carbon against
/// excess maintenance respiration before the later senescence cascade.
/// RCO2V retains exact `MIN(SNCR, VMXC*WTRSVB*TFN3) * XNFH` order.
pub fn apply(state: State, inputs: Inputs) !f64 {
    if (state.reserve_carbon_g_c.len != state.excess_maintenance_respiration_g_c_per_timestep.len)
        return error.ReserveMaintenanceRespirationDimensionMismatch;
    if (inputs.branch >= state.reserve_carbon_g_c.len)
        return error.ReserveMaintenanceRespirationBranchOutOfBounds;
    // IFLGZ must equal zero; when active, source does not evaluate this block.
    if (inputs.shoot_remobilization_status == .active) return 0;

    inline for (.{
        state.reserve_carbon_g_c[inputs.branch],
        state.excess_maintenance_respiration_g_c_per_timestep[inputs.branch],
        inputs.maximum_nonstructural_carbon_oxidation_per_h,
        inputs.canopy_growth_temperature_response,
        inputs.timestep_h,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteReserveMaintenanceRespirationInput;
    if (state.reserve_carbon_g_c[inputs.branch] < 0 or
        state.excess_maintenance_respiration_g_c_per_timestep[inputs.branch] < 0 or
        inputs.maximum_nonstructural_carbon_oxidation_per_h < 0 or
        inputs.canopy_growth_temperature_response < 0 or
        inputs.timestep_h <= 0)
        return error.InvalidReserveMaintenanceRespirationInput;
    const demand_g_c = state.excess_maintenance_respiration_g_c_per_timestep[inputs.branch];
    const reserve_g_c = state.reserve_carbon_g_c[inputs.branch];
    if (demand_g_c == 0 or reserve_g_c == 0) return 0;

    const oxidized_g_c = @min(
        demand_g_c,
        inputs.maximum_nonstructural_carbon_oxidation_per_h * reserve_g_c *
            inputs.canopy_growth_temperature_response,
    ) * inputs.timestep_h;
    const reserve_after_g_c = reserve_g_c - oxidized_g_c;
    const demand_after_g_c = demand_g_c - oxidized_g_c;
    inline for (.{ oxidized_g_c, reserve_after_g_c, demand_after_g_c }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteReserveMaintenanceRespirationResult;
    if (reserve_after_g_c < 0)
        return error.ReserveMaintenanceRespirationExceedsReserve;
    if (demand_after_g_c < 0)
        return error.ReserveMaintenanceRespirationExceedsDemand;

    // WTRSVB precedes SNCR in the source.
    state.reserve_carbon_g_c[inputs.branch] = reserve_after_g_c;
    state.excess_maintenance_respiration_g_c_per_timestep[inputs.branch] = demand_after_g_c;
    return oxidized_g_c;
}

test "GROSUB reserve oxidation preserves source operation order" {
    var reserve = [_]f64{ 1, 10, 20 };
    var demand = [_]f64{ 0, 2, 0 };
    const oxidized = try apply(.{
        .reserve_carbon_g_c = &reserve,
        .excess_maintenance_respiration_g_c_per_timestep = &demand,
    }, .{
        .branch = 1,
        .shoot_remobilization_status = .not_started,
        .maximum_nonstructural_carbon_oxidation_per_h = 0.1,
        .canopy_growth_temperature_response = 0.5,
        .timestep_h = 0.25,
    });
    // min(2,0.1*10*0.5)*0.25 = 0.125.
    try std.testing.expectEqual(@as(f64, 0.125), oxidized);
    try std.testing.expectEqual(@as(f64, 9.875), reserve[1]);
    try std.testing.expectEqual(@as(f64, 1.875), demand[1]);
    try std.testing.expectEqual(@as(f64, 1), reserve[0]);
}

test "active shoot remobilization skips reserve oxidation" {
    var reserve = [_]f64{std.math.nan(f64)};
    var demand = [_]f64{std.math.nan(f64)};
    const oxidized = try apply(.{
        .reserve_carbon_g_c = &reserve,
        .excess_maintenance_respiration_g_c_per_timestep = &demand,
    }, .{
        .branch = 0,
        .shoot_remobilization_status = .active,
        .maximum_nonstructural_carbon_oxidation_per_h = std.math.nan(f64),
        .canopy_growth_temperature_response = std.math.nan(f64),
        .timestep_h = 0,
    });
    try std.testing.expectEqual(@as(f64, 0), oxidized);
}

test "source timestep overdraw fails atomically instead of clamping demand" {
    var reserve = [_]f64{10};
    var demand = [_]f64{1};
    try std.testing.expectError(error.ReserveMaintenanceRespirationExceedsDemand, apply(.{
        .reserve_carbon_g_c = &reserve,
        .excess_maintenance_respiration_g_c_per_timestep = &demand,
    }, .{
        .branch = 0,
        .shoot_remobilization_status = .not_started,
        .maximum_nonstructural_carbon_oxidation_per_h = 1,
        .canopy_growth_temperature_response = 1,
        .timestep_h = 2,
    }));
    try std.testing.expectEqual(@as(f64, 10), reserve[0]);
    try std.testing.expectEqual(@as(f64, 1), demand[0]);
}

test "runtime topology and negative reserve state fail explicitly" {
    var reserve = [_]f64{ -1, 2 };
    var demand = [_]f64{1};
    try std.testing.expectError(error.ReserveMaintenanceRespirationDimensionMismatch, apply(.{
        .reserve_carbon_g_c = &reserve,
        .excess_maintenance_respiration_g_c_per_timestep = &demand,
    }, .{
        .branch = 0,
        .shoot_remobilization_status = .not_started,
        .maximum_nonstructural_carbon_oxidation_per_h = 0.1,
        .canopy_growth_temperature_response = 1,
        .timestep_h = 1,
    }));
    var demand_two = [_]f64{ 1, 1 };
    try std.testing.expectError(error.InvalidReserveMaintenanceRespirationInput, apply(.{
        .reserve_carbon_g_c = &reserve,
        .excess_maintenance_respiration_g_c_per_timestep = &demand_two,
    }, .{
        .branch = 0,
        .shoot_remobilization_status = .not_started,
        .maximum_nonstructural_carbon_oxidation_per_h = 0.1,
        .canopy_growth_temperature_response = 1,
        .timestep_h = 1,
    }));
}
