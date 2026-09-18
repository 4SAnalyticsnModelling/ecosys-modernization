//! `coupled_gas_solver`.
//!
//! The declarations live in the `_<group>.zig` files beside this one and
//! are re-exported here, so `module.name` still resolves for every caller
//! and the grouping is a file layout choice rather than an API change.

const group_diagnostics = @import("coupled_gas_solver_diagnostics.zig");
const group_directions = @import("coupled_gas_solver_directions.zig");
const group_misc = @import("coupled_gas_solver_misc.zig");
const group_newton_steps = @import("coupled_gas_solver_newton_steps.zig");
const group_residual = @import("coupled_gas_solver_residual.zig");
const group_solve = @import("coupled_gas_solver_solve.zig");
const group_tests = @import("coupled_gas_solver_tests.zig");
const group_validation = @import("coupled_gas_solver_validation.zig");

// diagnostics

// misc
pub const Inputs = group_misc.Inputs;
pub const Options = group_misc.Options;
pub const Result = group_misc.Result;

// newton steps

// residual

// solve
pub const solve = group_solve.solve;

// tests

// validation

test {
    // A bare reference is what makes `zig build test` reach a file.
    _ = @import("coupled_gas_solver_residual.zig");
    _ = @import("coupled_gas_solver_tests.zig");
    _ = @import("../../validation/coupled_gas_solver_test.zig");
}
