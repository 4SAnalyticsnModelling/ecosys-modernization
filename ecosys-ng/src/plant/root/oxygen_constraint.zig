// **A8a DISPOSITION: SUPERSEDED BY BOUND OWNER, gap closed.**
//
// `uptake.f` 2819--2831's root oxygen constraint `WFR` is now owned by
// `plant_root_gas_exchange.refreshOxygenProcessConstraint`, called through
// `plant_root_gas_transport.advanceOxygen` from `stages/hourly_vegetation.zig`
// before root metabolism and nutrient uptake. This isolated statement port is
// intentionally not called in parallel. `tools/unwritten_field_guard.ps1`
// reports zero unwritten-but-read model fields and its ratchet is zero.
//
// UPTAKE-RECONCILE-2855-3862 group of docs/traceability/a7b_reconcile_nutrient_uptake_cluster.md
const std = @import("std");

pub const Inputs = struct {
    gas_transfer_active: bool,
    oxygen_from_internal_root_g_o_per_step: f64,
    oxygen_from_soil_g_o_per_step: f64,
    unconstrained_oxygen_demand_g_o_per_step: f64,
    layer_index_1_based: usize,
    surface_layer_count: usize,
    preceding_layer_constraint: ?f64,
};

pub const ProfileTotals = struct {
    oxygen_demand_g_o_per_step: f64,
    oxygen_uptake_g_o_per_step: f64,
};

pub const Result = struct {
    oxygen_uptake_g_o_per_step: f64,
    root_process_constraint: f64,
    profile_totals: ProfileTotals,
};

/// UPTAKE.F 2819--2831. The enclosing legacy condition begins at line 2054:
/// primary root axis, emerged plant, and non-negligible root length.
pub fn computeRuntimeAxes(
    inputs: []const Inputs,
    initial_totals: []const ProfileTotals,
    scratch: []Result,
    destination: []Result,
) !void {
    if (inputs.len != initial_totals.len or
        inputs.len != scratch.len or
        inputs.len != destination.len)
        return error.RootOxygenConstraintDimensionMismatch;
    for (inputs, initial_totals, scratch) |axis_inputs, totals, *candidate|
        candidate.* = try compute(axis_inputs, totals);
    @memcpy(destination, scratch);
}

pub fn compute(inputs: Inputs, initial_totals: ProfileTotals) !Result {
    try validate(inputs, initial_totals);
    var uptake: f64 = 0;
    const constraint = if (inputs.gas_transfer_active) active: {
        uptake = inputs.oxygen_from_internal_root_g_o_per_step +
            inputs.oxygen_from_soil_g_o_per_step;
        break :active @min(
            1,
            @max(0, uptake / inputs.unconstrained_oxygen_demand_g_o_per_step),
        );
    } else if (inputs.layer_index_1_based > inputs.surface_layer_count)
        inputs.preceding_layer_constraint.?
    else
        1;
    const result = Result{
        .oxygen_uptake_g_o_per_step = uptake,
        .root_process_constraint = constraint,
        .profile_totals = .{
            .oxygen_demand_g_o_per_step = initial_totals.oxygen_demand_g_o_per_step +
                inputs.unconstrained_oxygen_demand_g_o_per_step,
            .oxygen_uptake_g_o_per_step = initial_totals.oxygen_uptake_g_o_per_step + uptake,
        },
    };
    if (!std.math.isFinite(result.root_process_constraint) or
        !std.math.isFinite(result.profile_totals.oxygen_demand_g_o_per_step) or
        !std.math.isFinite(result.profile_totals.oxygen_uptake_g_o_per_step))
        return error.NonFiniteRootOxygenConstraintResult;
    return result;
}

fn validate(inputs: Inputs, totals: ProfileTotals) !void {
    inline for (.{
        inputs.unconstrained_oxygen_demand_g_o_per_step,
        totals.oxygen_demand_g_o_per_step,
    }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidRootOxygenConstraintInput;
    inline for (.{
        inputs.oxygen_from_internal_root_g_o_per_step,
        inputs.oxygen_from_soil_g_o_per_step,
        totals.oxygen_uptake_g_o_per_step,
    }) |value|
        if (!std.math.isFinite(value))
            return error.InvalidRootOxygenConstraintInput;
    if (inputs.layer_index_1_based == 0)
        return error.InvalidRootOxygenConstraintInput;
    if (inputs.gas_transfer_active and
        inputs.unconstrained_oxygen_demand_g_o_per_step <= 0)
        return error.InvalidRootOxygenConstraintDemand;
    if (!inputs.gas_transfer_active and
        inputs.layer_index_1_based > inputs.surface_layer_count)
    {
        const preceding = inputs.preceding_layer_constraint orelse
            return error.MissingPrecedingRootOxygenConstraint;
        if (!std.math.isFinite(preceding) or preceding < 0 or preceding > 1)
            return error.InvalidPrecedingRootOxygenConstraint;
    }
}

fn activeInputs() Inputs {
    return .{
        .gas_transfer_active = true,
        .oxygen_from_internal_root_g_o_per_step = 0.2,
        .oxygen_from_soil_g_o_per_step = 0.3,
        .unconstrained_oxygen_demand_g_o_per_step = 1,
        .layer_index_1_based = 2,
        .surface_layer_count = 1,
        .preceding_layer_constraint = 0.9,
    };
}

test "active root constraint uses summed oxygen uptake and updates totals" {
    const result = try compute(activeInputs(), .{
        .oxygen_demand_g_o_per_step = 2,
        .oxygen_uptake_g_o_per_step = 1,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.oxygen_uptake_g_o_per_step, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.root_process_constraint, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), result.profile_totals.oxygen_demand_g_o_per_step, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), result.profile_totals.oxygen_uptake_g_o_per_step, 1e-12);
}

test "active constraint is clamped to one" {
    var inputs = activeInputs();
    inputs.oxygen_from_soil_g_o_per_step = 2;
    const result = try compute(inputs, .{
        .oxygen_demand_g_o_per_step = 0,
        .oxygen_uptake_g_o_per_step = 0,
    });
    try std.testing.expectEqual(@as(f64, 1), result.root_process_constraint);
}

test "active signed oxygen transfer is clamped to zero" {
    var inputs = activeInputs();
    inputs.oxygen_from_internal_root_g_o_per_step = -1;
    const result = try compute(inputs, .{
        .oxygen_demand_g_o_per_step = 0,
        .oxygen_uptake_g_o_per_step = 0,
    });
    try std.testing.expectEqual(@as(f64, 0), result.root_process_constraint);
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.7),
        result.oxygen_uptake_g_o_per_step,
        1e-12,
    );
}

test "inactive deep layer propagates preceding constraint" {
    var inputs = activeInputs();
    inputs.gas_transfer_active = false;
    inputs.preceding_layer_constraint = 0.35;
    const result = try compute(inputs, .{
        .oxygen_demand_g_o_per_step = 0,
        .oxygen_uptake_g_o_per_step = 0,
    });
    try std.testing.expectEqual(@as(f64, 0), result.oxygen_uptake_g_o_per_step);
    try std.testing.expectApproxEqAbs(@as(f64, 0.35), result.root_process_constraint, 1e-12);
}

test "inactive surface layer defaults to unconstrained" {
    var inputs = activeInputs();
    inputs.gas_transfer_active = false;
    inputs.layer_index_1_based = 1;
    inputs.preceding_layer_constraint = null;
    const result = try compute(inputs, .{
        .oxygen_demand_g_o_per_step = 0,
        .oxygen_uptake_g_o_per_step = 0,
    });
    try std.testing.expectEqual(@as(f64, 1), result.root_process_constraint);
}

test "runtime axes fail atomically when a deep layer lacks preceding state" {
    var inputs = [_]Inputs{ activeInputs(), activeInputs() };
    inputs[1].gas_transfer_active = false;
    inputs[1].preceding_layer_constraint = null;
    const totals = [_]ProfileTotals{
        .{ .oxygen_demand_g_o_per_step = 0, .oxygen_uptake_g_o_per_step = 0 },
        .{ .oxygen_demand_g_o_per_step = 0, .oxygen_uptake_g_o_per_step = 0 },
    };
    var scratch: [2]Result = undefined;
    var destination = [_]Result{std.mem.zeroes(Result)} ** 2;
    destination[0].root_process_constraint = 0.41;
    destination[1].root_process_constraint = 0.42;
    try std.testing.expectError(
        error.MissingPrecedingRootOxygenConstraint,
        computeRuntimeAxes(&inputs, &totals, &scratch, &destination),
    );
    try std.testing.expectEqual(@as(f64, 0.41), destination[0].root_process_constraint);
    try std.testing.expectEqual(@as(f64, 0.42), destination[1].root_process_constraint);
}
