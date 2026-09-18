// **A8a DISPOSITION: SUPERSEDED BY BOUND ANNUAL OWNER.** The unbound kernel is
// retained as an oracle; `daily_flux.closeYearAfterOutput` and its salt sibling
// execute the same carries only at the last day of the year.
//
// **HISTORICAL A8a DISPOSITION: GAP, still unbound, but the cadence defect this module
// documents (PLANT-CADENCE-001) is fixed.** This module is a correct and
// complete runtime-sized translation of the whole of `day.f:152--193`,
// including the `IF(ISALTG.NE.0)` salt arm at `:183--192` as the explicit
// `dynamic_salts_enabled` parameter. It has no caller: it is registered only
// at `module_index.zig:162` as `annual_plant_flux_rollover`.
//
// It is not superseded, and it is still not bound. Production's owner of the
// same equations is `plant/accounting/daily_flux.zig`
// `State.closeYearAfterOutput` (renamed from `closeDayAfterOutput`), called
// from `ecosys_ng.zig` (~line 8360) inside `if (completed_day_of_year ==
// ecosys.climate_change.daysInYear(current_year))`, which applies the
// identical carbon, nitrogen and phosphorus carries and the identical three
// harvest accumulations in the same source order. Its sibling
// `closeYearHarvestSaltAfterOutput` owns DAY's ISALTG-gated ALHVC..CLHVC
// reset. The divergence used to be
// cadence, not arithmetic: legacy runs this loop only inside the annual guard
// at `day.f:84--85` (`I.EQ.1`, `ENDIF` at `:197`); the owner used to run it
// after every simulated day, and now runs it only when the completed day is
// the last day of its year, matching legacy. Binding this module in addition
// to the owner would still double every balance -- do not bind it without
// first retiring the owner's duplicate carry logic.
//
// The mass-balance invariant could not see the divergence while it existed,
// because every field the owner zeroes enters `BALC`
// (`grosub.f:13071--13075`, `io/output/plant_daily_output.zig:71--89`) with
// the sign opposite to its contribution to the `cumulative_*` balance it was
// just folded into, so the daily carry telescoped regardless of cadence.
//
// Keep this module as the specification of the annual cadence now
// implemented at the owner. PLANT-CADENCE-001 of docs/discrepancy_register.md
const std = @import("std");

pub const BalanceInputs = struct {
    net_carbon_g_c: []const f64,
    carbon_uptake_g_c: []const f64,
    carbon_senescence_g_c: []const f64,
    soil_co2_transfer_g_c: []const f64,
    fire_carbon_loss_g_c: []const f64,
    nitrogen_uptake_g_n: []const f64,
    canopy_ammonia_transfer_g_n: []const f64,
    nitrogen_senescence_g_n: []const f64,
    fire_nitrogen_loss_g_n: []const f64,
    nitrogen_fixation_g_n: []const f64,
    phosphorus_uptake_g_p: []const f64,
    phosphorus_senescence_g_p: []const f64,
    fire_phosphorus_loss_g_p: []const f64,
    harvest_carbon_g_c: []const f64,
    harvest_nitrogen_g_n: []const f64,
    harvest_phosphorus_g_p: []const f64,
};

pub const State = struct {
    carbon_reset_balance_g_c: []f64,
    nitrogen_reset_balance_g_n: []f64,
    phosphorus_reset_balance_g_p: []f64,
    cumulative_harvest_carbon_g_c: []f64,
    cumulative_harvest_nitrogen_g_n: []f64,
    cumulative_harvest_phosphorus_g_p: []f64,
    /// Runtime plant × annual-ledger layout. Every translated annual plant
    /// flux named in `day.f` lines 159--182 is bound here by the owner.
    annual_fluxes_to_zero: []f64,
    annual_flux_count_per_plant: usize,
    /// Runtime plant × salt-species layout; no fixed eight-salt extent.
    salt_uptake_to_zero: []f64,
    salt_species_count: usize,
};

/// Atomic annual rollover for arbitrary runtime plants.
pub fn apply(
    state: State,
    inputs: BalanceInputs,
    dynamic_salts_enabled: bool,
) !void {
    const plants = state.carbon_reset_balance_g_c.len;
    if (plants == 0 or state.nitrogen_reset_balance_g_n.len != plants or
        state.phosphorus_reset_balance_g_p.len != plants or
        state.cumulative_harvest_carbon_g_c.len != plants or
        state.cumulative_harvest_nitrogen_g_n.len != plants or
        state.cumulative_harvest_phosphorus_g_p.len != plants or
        state.annual_flux_count_per_plant == 0 or
        state.annual_fluxes_to_zero.len !=
            try std.math.mul(
                usize,
                plants,
                state.annual_flux_count_per_plant,
            ) or
        (dynamic_salts_enabled and
            (state.salt_species_count == 0 or
                state.salt_uptake_to_zero.len !=
                    try std.math.mul(
                        usize,
                        plants,
                        state.salt_species_count,
                    ))))
        return error.AnnualPlantRolloverDimensionMismatch;
    inline for (@typeInfo(BalanceInputs).@"struct".fields) |field|
        if (@field(inputs, field.name).len != plants)
            return error.AnnualPlantRolloverDimensionMismatch;
    inline for (@typeInfo(State).@"struct".fields) |field| {
        if (field.type == []f64) for (@field(state, field.name)) |value|
            if (!std.math.isFinite(value))
                return error.NonFiniteAnnualPlantRolloverState;
    }
    inline for (@typeInfo(BalanceInputs).@"struct".fields) |field|
        for (@field(inputs, field.name)) |value|
            if (!std.math.isFinite(value))
                return error.NonFiniteAnnualPlantRolloverInput;

    for (0..plants) |plant| {
        const carbon = state.carbon_reset_balance_g_c[plant] +
            inputs.net_carbon_g_c[plant] +
            inputs.carbon_uptake_g_c[plant] -
            inputs.carbon_senescence_g_c[plant] +
            inputs.soil_co2_transfer_g_c[plant] +
            inputs.fire_carbon_loss_g_c[plant];
        const nitrogen = state.nitrogen_reset_balance_g_n[plant] +
            inputs.nitrogen_uptake_g_n[plant] +
            inputs.canopy_ammonia_transfer_g_n[plant] -
            inputs.nitrogen_senescence_g_n[plant] +
            inputs.fire_nitrogen_loss_g_n[plant] +
            inputs.nitrogen_fixation_g_n[plant];
        const phosphorus = state.phosphorus_reset_balance_g_p[plant] +
            inputs.phosphorus_uptake_g_p[plant] -
            inputs.phosphorus_senescence_g_p[plant] +
            inputs.fire_phosphorus_loss_g_p[plant];
        inline for (.{ carbon, nitrogen, phosphorus, state.cumulative_harvest_carbon_g_c[plant] +
            inputs.harvest_carbon_g_c[plant], state.cumulative_harvest_nitrogen_g_n[plant] +
            inputs.harvest_nitrogen_g_n[plant], state.cumulative_harvest_phosphorus_g_p[plant] +
            inputs.harvest_phosphorus_g_p[plant] }) |candidate|
            if (!std.math.isFinite(candidate))
                return error.AnnualPlantRolloverOverflow;
    }

    for (0..plants) |plant| {
        state.carbon_reset_balance_g_c[plant] +=
            inputs.net_carbon_g_c[plant] +
            inputs.carbon_uptake_g_c[plant] -
            inputs.carbon_senescence_g_c[plant] +
            inputs.soil_co2_transfer_g_c[plant] +
            inputs.fire_carbon_loss_g_c[plant];
        state.nitrogen_reset_balance_g_n[plant] +=
            inputs.nitrogen_uptake_g_n[plant] +
            inputs.canopy_ammonia_transfer_g_n[plant] -
            inputs.nitrogen_senescence_g_n[plant] +
            inputs.fire_nitrogen_loss_g_n[plant] +
            inputs.nitrogen_fixation_g_n[plant];
        state.phosphorus_reset_balance_g_p[plant] +=
            inputs.phosphorus_uptake_g_p[plant] -
            inputs.phosphorus_senescence_g_p[plant] +
            inputs.fire_phosphorus_loss_g_p[plant];
        state.cumulative_harvest_carbon_g_c[plant] +=
            inputs.harvest_carbon_g_c[plant];
        state.cumulative_harvest_nitrogen_g_n[plant] +=
            inputs.harvest_nitrogen_g_n[plant];
        state.cumulative_harvest_phosphorus_g_p[plant] +=
            inputs.harvest_phosphorus_g_p[plant];
    }
    @memset(state.annual_fluxes_to_zero, 0);
    if (dynamic_salts_enabled) @memset(state.salt_uptake_to_zero, 0);
}

test "DAY annual rollover preserves equations for seven runtime plants" {
    const plants = 7;
    var carbon_reset = [_]f64{1} ** plants;
    var nitrogen_reset = [_]f64{1} ** plants;
    var phosphorus_reset = [_]f64{1} ** plants;
    var harvest_c = [_]f64{10} ** plants;
    var harvest_n = [_]f64{10} ** plants;
    var harvest_p = [_]f64{10} ** plants;
    var fluxes = [_]f64{9} ** (plants * 12);
    var salts = [_]f64{8} ** (plants * 11);
    const one = [_]f64{1} ** plants;
    const two = [_]f64{2} ** plants;
    try apply(.{
        .carbon_reset_balance_g_c = &carbon_reset,
        .nitrogen_reset_balance_g_n = &nitrogen_reset,
        .phosphorus_reset_balance_g_p = &phosphorus_reset,
        .cumulative_harvest_carbon_g_c = &harvest_c,
        .cumulative_harvest_nitrogen_g_n = &harvest_n,
        .cumulative_harvest_phosphorus_g_p = &harvest_p,
        .annual_fluxes_to_zero = &fluxes,
        .annual_flux_count_per_plant = 12,
        .salt_uptake_to_zero = &salts,
        .salt_species_count = 11,
    }, .{
        .net_carbon_g_c = &two,
        .carbon_uptake_g_c = &two,
        .carbon_senescence_g_c = &one,
        .soil_co2_transfer_g_c = &one,
        .fire_carbon_loss_g_c = &one,
        .nitrogen_uptake_g_n = &two,
        .canopy_ammonia_transfer_g_n = &one,
        .nitrogen_senescence_g_n = &one,
        .fire_nitrogen_loss_g_n = &one,
        .nitrogen_fixation_g_n = &two,
        .phosphorus_uptake_g_p = &two,
        .phosphorus_senescence_g_p = &one,
        .fire_phosphorus_loss_g_p = &one,
        .harvest_carbon_g_c = &two,
        .harvest_nitrogen_g_n = &one,
        .harvest_phosphorus_g_p = &one,
    }, true);
    try std.testing.expectEqual(@as(f64, 6), carbon_reset[6]);
    try std.testing.expectEqual(@as(f64, 6), nitrogen_reset[6]);
    try std.testing.expectEqual(@as(f64, 3), phosphorus_reset[6]);
    try std.testing.expectEqual(@as(f64, 12), harvest_c[6]);
    for (fluxes) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (salts) |value| try std.testing.expectEqual(@as(f64, 0), value);
}

test "disabled dynamic salts retain their annual uptake ledgers" {
    var value = [_]f64{1};
    var flux = [_]f64{2};
    var salts = [_]f64{3};
    try apply(.{
        .carbon_reset_balance_g_c = &value,
        .nitrogen_reset_balance_g_n = &value,
        .phosphorus_reset_balance_g_p = &value,
        .cumulative_harvest_carbon_g_c = &value,
        .cumulative_harvest_nitrogen_g_n = &value,
        .cumulative_harvest_phosphorus_g_p = &value,
        .annual_fluxes_to_zero = &flux,
        .annual_flux_count_per_plant = 1,
        .salt_uptake_to_zero = &salts,
        .salt_species_count = 1,
    }, zeroInputs(&[_]f64{0}), false);
    try std.testing.expectEqual(@as(f64, 0), flux[0]);
    try std.testing.expectEqual(@as(f64, 3), salts[0]);
}

fn zeroInputs(zero: []const f64) BalanceInputs {
    return .{
        .net_carbon_g_c = zero,
        .carbon_uptake_g_c = zero,
        .carbon_senescence_g_c = zero,
        .soil_co2_transfer_g_c = zero,
        .fire_carbon_loss_g_c = zero,
        .nitrogen_uptake_g_n = zero,
        .canopy_ammonia_transfer_g_n = zero,
        .nitrogen_senescence_g_n = zero,
        .fire_nitrogen_loss_g_n = zero,
        .nitrogen_fixation_g_n = zero,
        .phosphorus_uptake_g_p = zero,
        .phosphorus_senescence_g_p = zero,
        .fire_phosphorus_loss_g_p = zero,
        .harvest_carbon_g_c = zero,
        .harvest_nitrogen_g_n = zero,
        .harvest_phosphorus_g_p = zero,
    };
}

test "invalid late input rolls back balances harvest flux and salts" {
    var carbon = [_]f64{ 1, 2 };
    var nitrogen = [_]f64{ 1, 2 };
    var phosphorus = [_]f64{ 1, 2 };
    var harvest_c = [_]f64{ 1, 2 };
    var harvest_n = [_]f64{ 1, 2 };
    var harvest_p = [_]f64{ 1, 2 };
    var flux = [_]f64{ 4, 5 };
    var salts = [_]f64{ 6, 7 };
    const carbon_before = carbon;
    const flux_before = flux;
    var input = [_]f64{ 0, std.math.nan(f64) };
    try std.testing.expectError(
        error.NonFiniteAnnualPlantRolloverInput,
        apply(.{
            .carbon_reset_balance_g_c = &carbon,
            .nitrogen_reset_balance_g_n = &nitrogen,
            .phosphorus_reset_balance_g_p = &phosphorus,
            .cumulative_harvest_carbon_g_c = &harvest_c,
            .cumulative_harvest_nitrogen_g_n = &harvest_n,
            .cumulative_harvest_phosphorus_g_p = &harvest_p,
            .annual_fluxes_to_zero = &flux,
            .annual_flux_count_per_plant = 1,
            .salt_uptake_to_zero = &salts,
            .salt_species_count = 1,
        }, .{
            .net_carbon_g_c = &input,
            .carbon_uptake_g_c = &.{ 0, 0 },
            .carbon_senescence_g_c = &.{ 0, 0 },
            .soil_co2_transfer_g_c = &.{ 0, 0 },
            .fire_carbon_loss_g_c = &.{ 0, 0 },
            .nitrogen_uptake_g_n = &.{ 0, 0 },
            .canopy_ammonia_transfer_g_n = &.{ 0, 0 },
            .nitrogen_senescence_g_n = &.{ 0, 0 },
            .fire_nitrogen_loss_g_n = &.{ 0, 0 },
            .nitrogen_fixation_g_n = &.{ 0, 0 },
            .phosphorus_uptake_g_p = &.{ 0, 0 },
            .phosphorus_senescence_g_p = &.{ 0, 0 },
            .fire_phosphorus_loss_g_p = &.{ 0, 0 },
            .harvest_carbon_g_c = &.{ 0, 0 },
            .harvest_nitrogen_g_n = &.{ 0, 0 },
            .harvest_phosphorus_g_p = &.{ 0, 0 },
        }, true),
    );
    try std.testing.expectEqualSlices(f64, &carbon_before, &carbon);
    try std.testing.expectEqualSlices(f64, &flux_before, &flux);
}
