//! `litter_chemistry`.
//!
//! The declarations live in the `_<group>.zig` files beside this one and
//! are re-exported here, so `module.name` still resolves for every caller
//! and the grouping is a file layout choice rather than an API change.

const group_activity = @import("litter_chemistry_activity.zig");
const group_ammonium = @import("litter_chemistry_ammonium.zig");
const group_fixed_phosphate = @import("litter_chemistry_fixed_phosphate.zig");
const group_fixtures = @import("litter_chemistry_fixtures.zig");
const group_logging = @import("litter_chemistry_logging.zig");
const group_numerics = @import("litter_chemistry_numerics.zig");
const group_phosphate_exchange = @import("litter_chemistry_phosphate_exchange.zig");
const group_phosphate_minerals = @import("litter_chemistry_phosphate_minerals.zig");
const group_solve = @import("litter_chemistry_solve.zig");
const group_struct_arithmetic = @import("litter_chemistry_struct_arithmetic.zig");
const group_tests = @import("litter_chemistry_tests.zig");
const group_types = @import("litter_chemistry_types.zig");

// activity
pub const activityCoefficients = group_activity.activityCoefficients;

// ammonium

// fixed phosphate

// fixtures
pub const Evaluator = group_fixtures.Evaluator;

// logging

// numerics

// phosphate exchange

// phosphate minerals

// solve
pub const applyHourlyCell = group_solve.applyHourlyCell;
pub const solveCell = group_solve.solveCell;

// struct arithmetic

// tests

// types
pub const Cell = group_types.Cell;
pub const State = group_types.State;
pub const Environment = group_types.Environment;
pub const Options = group_types.Options;
pub const Result = group_types.Result;
pub const ProbeCounts = group_types.ProbeCounts;
pub const recordProbe = group_types.recordProbe;

test {
    // A bare reference is what makes `zig build test` reach a file.
    _ = @import("litter_chemistry_solve.zig");
    _ = @import("litter_chemistry_tests.zig");
    _ = @import("../validation/surface_litter_chemistry_test.zig");
}
