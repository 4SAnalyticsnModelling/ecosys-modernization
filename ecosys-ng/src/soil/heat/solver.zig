//! `solver`.
//!
//! The declarations live in the `_<group>.zig` files beside this one and
//! are re-exported here, so `module.name` still resolves for every caller
//! and the grouping is a file layout choice rather than an API change.

const group_boundary = @import("solver_boundary.zig");
const group_enthalpy = @import("solver_enthalpy.zig");
const group_fixtures = @import("solver_fixtures.zig");
const group_misc = @import("solver_misc.zig");
const group_residual = @import("solver_residual.zig");
const group_solve = @import("solver_solve.zig");
const group_tests = @import("solver_tests.zig");
const group_types = @import("solver_types.zig");
const group_validation = @import("solver_validation.zig");

// boundary
pub const acceptedBoundaryHeatByHorizontalCell = group_boundary.acceptedBoundaryHeatByHorizontalCell;
pub const acceptedBoundaryHeatByLayer = group_boundary.acceptedBoundaryHeatByLayer;

// enthalpy

// fixtures

// misc
pub const GeothermalBoundary = group_misc.GeothermalBoundary;
pub const DirichletThermalBoundaries = group_misc.DirichletThermalBoundaries;
pub const EnthalpyCoupling = group_misc.EnthalpyCoupling;

// residual

// solve
/// Ready-to-use per-iteration/per-priced-direction tracing. Diagnostic only;
/// no production caller sets `Options.diagnostic_trace`.
pub const debug_print_trace = group_solve.debug_print_trace;
pub const solve = group_solve.solve;
pub const solveWithWorkspace = group_solve.solveWithWorkspace;
pub const solveAndBindTransportFaces = group_solve.solveAndBindTransportFaces;
pub const solveAndBindTransportFacesWithWorkspace = group_solve.solveAndBindTransportFacesWithWorkspace;

// tests

// types
pub const Face = group_types.Face;
pub const FaceGeometry = group_types.FaceGeometry;
pub const Properties = group_types.Properties;
pub const WaterHeatFluxes = group_types.WaterHeatFluxes;
pub const Options = group_types.Options;
pub const Result = group_types.Result;
pub const Workspace = group_types.Workspace;

// validation

test {
    // A bare reference is what makes `zig build test` reach a file.
    _ = @import("solver_tests.zig");
}
