//! `solver`.
//!
//! The declarations live in the `_<group>.zig` files beside this one and
//! are re-exported here, so `module.name` still resolves for every caller
//! and the grouping is a file layout choice rather than an API change.

const group_conserved = @import("solver_conserved.zig");
const group_fixtures = @import("solver_fixtures.zig");
const group_flux = @import("solver_flux.zig");
const group_hydraulics = @import("solver_hydraulics.zig");
const group_newton = @import("solver_newton.zig");
const group_residual = @import("solver_residual.zig");
const group_solve = @import("solver_solve.zig");
const group_tests = @import("solver_tests.zig");
const group_types = @import("solver_types.zig");

// conserved

// fixtures

// flux
pub const physicalPoreSpaceM3 = group_flux.physicalPoreSpaceM3;
pub const physicalLiquidCapacityM3 = group_flux.physicalLiquidCapacityM3;
pub const derivedPhysicalAirVolumeM3 = group_flux.derivedPhysicalAirVolumeM3;

// hydraulics
pub const conductivityAt = group_hydraulics.conductivityAt;
pub const UnsaturatedConductivityInputs = group_hydraulics.UnsaturatedConductivityInputs;
pub const unsaturatedConductivityM2PerHMpa = group_hydraulics.unsaturatedConductivityM2PerHMpa;

// newton

// residual

// solve
pub const solve = group_solve.solve;
pub const solveAndBindTransportFaces = group_solve.solveAndBindTransportFaces;

// tests

// types
pub const Axis = group_types.Axis;
pub const Face = group_types.Face;
pub const FaceGeometry = group_types.FaceGeometry;
pub const DenseJacobianCache = group_types.DenseJacobianCache;
pub const maximum_dense_newton_components = group_types.maximum_dense_newton_components;
pub const Properties = group_types.Properties;
pub const Options = group_types.Options;
pub const Result = group_types.Result;

test {
    // A bare reference is what makes `zig build test` reach a file.
    _ = @import("solver_conserved.zig");
    _ = @import("solver_newton.zig");
    _ = @import("solver_solve.zig");
    _ = @import("solver_tests.zig");
    _ = @import("kirchhoff.zig");
    _ = @import("kirchhoff_column_tests.zig");
    _ = @import("boundary_dimension_tests.zig");
}
