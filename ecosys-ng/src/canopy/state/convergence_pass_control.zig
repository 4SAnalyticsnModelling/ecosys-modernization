// **A8a DISPOSITION: BOUND.** `canopy/energy/coupled_convergence.zig` now
// calls `evaluate` around the production STOMATE reset and final coupled
// canopy/root-water pass. `stages/hourly_snow_energy.zig` supplies the
// STOMATE boundary, stages RSMN, and publishes it only after every plant and
// the coupled root-hydraulics update succeed. This is the `uptake.f:1218--
// 1230` ICHK handshake; `canopy/energy/air_exchange.zig` remains a separate
// TKQY/VPQY owner and is deliberately not treated as this module's caller.
const std = @import("std");

pub const Action = enum {
    continue_iteration,
    finish_subproblem,
};

pub const Inputs = struct {
    final_check_pending: bool,
    outer_iteration: usize,
    maximum_outer_iterations: usize,
    inner_iteration: usize,
    maximum_observed_inner_iterations: usize,
};

pub const Result = struct {
    final_check_pending: bool,
    reset_stomatal_minimum_before_final_pass: bool,
    maximum_observed_inner_iterations: usize,
    action: Action,
};

/// UPTAKE.F 1218--1230. Preserves the source's two-pass convergence control
/// while exposing the unresolved STOMATE reset as an explicit caller action.
pub fn evaluate(inputs: Inputs) !Result {
    if (inputs.outer_iteration == 0 or
        inputs.maximum_outer_iterations == 0 or
        inputs.outer_iteration > inputs.maximum_outer_iterations or
        inputs.inner_iteration == 0)
        return error.InvalidCanopyConvergencePassInput;
    if (inputs.final_check_pending) {
        return .{
            .final_check_pending = true,
            .reset_stomatal_minimum_before_final_pass = false,
            .maximum_observed_inner_iterations = @max(
                inputs.inner_iteration,
                inputs.maximum_observed_inner_iterations,
            ),
            .action = .finish_subproblem,
        };
    }
    return .{
        .final_check_pending = true,
        .reset_stomatal_minimum_before_final_pass = inputs.outer_iteration == inputs.maximum_outer_iterations,
        .maximum_observed_inner_iterations = inputs.maximum_observed_inner_iterations,
        .action = .continue_iteration,
    };
}

test "first convergence pass requests another iteration" {
    const result = try evaluate(.{
        .final_check_pending = false,
        .outer_iteration = 2,
        .maximum_outer_iterations = 4,
        .inner_iteration = 5,
        .maximum_observed_inner_iterations = 3,
    });
    try std.testing.expect(result.final_check_pending);
    try std.testing.expect(!result.reset_stomatal_minimum_before_final_pass);
    try std.testing.expectEqual(@as(usize, 3), result.maximum_observed_inner_iterations);
    try std.testing.expectEqual(Action.continue_iteration, result.action);
}

test "last outer pass exposes source STOMATE reset boundary" {
    const result = try evaluate(.{
        .final_check_pending = false,
        .outer_iteration = 4,
        .maximum_outer_iterations = 4,
        .inner_iteration = 5,
        .maximum_observed_inner_iterations = 3,
    });
    try std.testing.expect(result.reset_stomatal_minimum_before_final_pass);
    try std.testing.expectEqual(Action.continue_iteration, result.action);
}

test "second convergence pass records maximum and finishes" {
    const result = try evaluate(.{
        .final_check_pending = true,
        .outer_iteration = 4,
        .maximum_outer_iterations = 4,
        .inner_iteration = 8,
        .maximum_observed_inner_iterations = 6,
    });
    try std.testing.expect(!result.reset_stomatal_minimum_before_final_pass);
    try std.testing.expectEqual(@as(usize, 8), result.maximum_observed_inner_iterations);
    try std.testing.expectEqual(Action.finish_subproblem, result.action);
}
