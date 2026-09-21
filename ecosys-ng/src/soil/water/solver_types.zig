//! `solver` declarations: types.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const numerics = @import("../../core/numerics.zig");
const grid_module = @import("../../state/grid.zig");
const retention = @import("retention.zig");
const kirchhoff = @import("kirchhoff.zig");
const richards_face_cache = @import("richards_face_cache.zig");
const water_flux = @import("flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const water_boundary = @import("boundary.zig");
const boundary_topology = @import("../profile/boundary_topology.zig");

pub const Axis = enum(u2) { x = 0, y = 1, z = 2 };

pub const Face = struct {
    active: bool = true,
    source_cell: usize,
    destination_cell: usize,
    axis: Axis = .x,
    direction: water_flux.FaceDirection,
    source_path_length_m: f64,
    destination_path_length_m: f64,
    face_area_m2: f64,
};

pub const FaceGeometry = struct {
    source_path_length_m: []const f64,
    destination_path_length_m: []const f64,
    face_area_m2: []const f64,
};

/// Caller-owned quasi-Newton state for consecutive solves of one physical
/// schedule. A rejected warm direction never changes acceptance: the solver
/// rebuilds the exact finite-difference Jacobian in the same Newton iteration.
pub const DenseJacobianCache = struct {
    values: []f64,
    dimension: usize = 0,
    reuse_age: u8 = 0,
    valid: bool = false,

    pub fn invalidate(self: *DenseJacobianCache) void {
        self.dimension = 0;
        self.reuse_age = 0;
        self.valid = false;
    }
};

/// All arrays are runtime-sized by soil cell. Directional conductivity is
/// cell-major x/y/z. Nothing in this WATSUB state has a compile-time grid cap.
pub const Properties = struct {
    /// Runtime DLYRM mask. Empty preserves the all-active standalone-solver
    /// contract; mapped production calls bind SoilFaces.active_by_layer.
    active_by_layer: []const bool = &.{},
    matrix_bulk_volume_m3: []const f64,
    retention_curve: []const retention.ResolvedCurve,
    /// Original Mualem–van Genuchten parameters used by every Richards
    /// residual. Both domains are mandatory runtime data.
    mualem_van_genuchten_parameters: []const retention.MualemVanGenuchtenParameters = &.{},
    /// `SOIL-HCOND-AXIS-ISOTROPY-001`. Per-cell lateral (x/y) saturated
    /// hydraulic conductivity, `m h-1`, the `SCNH` analog of the vertical
    /// `mualem_van_genuchten_parameters[cell].saturated_hydraulic_conductivity_m_per_h`
    /// (`SCNV`). Selected in place of the vertical scalar whenever a face's
    /// axis is lateral, mirroring `ecosys_f77/hour1.f:2281-2293`'s
    /// direction-specific scaling of the shared relative-conductivity shape.
    /// Empty is a back-compat isotropic default: every axis uses the vertical
    /// scalar, the pre-`SOIL-HCOND-AXIS-ISOTROPY-001` behaviour.
    lateral_saturated_hydraulic_conductivity_m_per_h: []const f64 = &.{},
    macropore_mualem_van_genuchten_parameters: []const retention.MualemVanGenuchtenParameters = &.{},
    macropore_spacing_m: []const f64 = &.{},
    macropore_radius_m: []const f64 = &.{},
    dual_domain_exchange_enabled: []const bool = &.{},
    dual_domain_geometry_factor: f64 = 3,
    dual_domain_scaling_coefficient: f64 = 0.4,
    frozen_hydraulic_impedance_exponent: f64 = 0,
    /// True ice density relative to liquid water. Ice inventories in `GridState`
    /// are water-equivalent volumes; pore occupancy therefore uses
    /// `ice_water_equivalent_m3 / ice_density_megagrams_per_m3` while mass and
    /// enthalpy continue to use the stored water-equivalent carrier.
    ice_density_megagrams_per_m3: f64 = 1,
    gravitational_water_potential_mpa_per_m: f64 = 0.00980665,
    gravitational_potential_megapascal: []const f64,
    osmotic_potential_megapascal: []const f64,
    rainfall_conductivity_multiplier: []const f64 = &.{},
    /// Positive extensive liquid-water source entering the matrix domain
    /// during this physical step (for example depth-routed irrigation).
    matrix_external_source_m3_per_step: []const f64 = &.{},
    vertical_thickness_m: []const f64,
    osmotic_potential_multiplier: f64,
    nonlinear_time_fraction: f64 = 1,
    boundary_topology: ?*const boundary_topology.State = null,
    boundary_face_area_m2: []const f64 = &.{},
    boundary_macropore_hydraulic_conductivity_m2_per_h_megapascal: []const f64 = &.{},
    boundary_layer_volume_m3: []const f64 = &.{},
    boundary_layer_midpoint_depth_m: []const f64 = &.{},
    boundary_layer_bottom_depth_m: []const f64 = &.{},
    /// Solver-owned exact memoization for repeated Kirchhoff quadratures.
    /// Standalone residual consumers leave this null; `solveControlled`
    /// installs a fresh cache whose lifetime encloses every nonlinear trial.
    kirchhoff_cache: ?*kirchhoff.Cache = null,
    /// Solver-owned exact memoization for raw internal-face fluxes. Donor and
    /// receiver limits remain source ordered and are always reevaluated.
    richards_face_flux_cache: ?*richards_face_cache.Cache = null,
    /// Optional schedule-local warm Jacobian. Production binds one only across
    /// consecutive equal-dt substeps and invalidates it before another rung.
    dense_jacobian_cache: ?*DenseJacobianCache = null,
    /// Solver-private scratch. The caller copies it only after convergence.
    artificial_drainage_outflow_m3_per_step: ?[]f64 = null,
    /// Solver-private scratch, cell-indexed. The FULL per-cell boundary water
    /// exchange (natural free-drainage, recharge, and water-table exchange,
    /// plus the artificial-drainage subset already captured above) for every
    /// boundary-connected layer this hour, summed by owning cell. Positive
    /// values are a net gain to the cell (e.g. recharge); negative are a net
    /// loss (e.g. drainage). Unlike `artificial_drainage_outflow_m3_per_step`
    /// (magnitude-only, drainage-signed), this is the true signed boundary
    /// term needed to close a per-cell water balance: for a boundary-
    /// connected cell, `target - base == matrix_external_source +
    /// Σ(signed internal face fluxes) + boundary_water_exchange`. The caller
    /// copies it only after convergence. CONSERVATION-PER-CELL-CLOSURE-001.
    boundary_water_exchange_m3_per_step: ?[]f64 = null,
    /// Solver-private accepted boundary exchange partition, indexed by soil
    /// layer. It is populated from the boundary equations themselves, never
    /// reconstructed from the accepted storage endpoint.
    boundary_water_exchange_m3_per_layer_per_step: ?[]f64 = null,
    /// issue-078 (2026-09-21): global soil-layer index to gate a temporary,
    /// narrowly-scoped diagnostic trace of `residualAt`'s entry-overfill
    /// check and `applyMechanicalFreezingDisplacement`'s (the WATSUB vertical
    /// displacement prepass) per-face relief for that layer. `null` is a
    /// no-op, matching the sibling `diagnostic_trace_layer_index` convention
    /// already used by `vapor_solver.Options`/`heat_solver.Options`/
    /// `phase_solver.Options`. Production leaves this null except for the one
    /// narrow hour window this issue gates its own trace to.
    diagnostic_trace_layer_index: ?usize = null,
};

pub const Options = struct {
    /// Runtime NPH option. It is a convergence ceiling, not a sub-hour loop.
    max_iterations: u16,
    absolute_tolerance_m3: f64 = 1e-12,
    relative_tolerance: f64 = 1e-8,
    /// Independent accepted-balance criterion. It is enabled when one
    /// positive cell area is supplied and must pass in addition to the
    /// componentwise nonlinear criterion.
    conservation_absolute_tolerance_m: f64 = 0,
    conservation_relative_tolerance: f64 = 0,
    cell_area_m2: []const f64 = &.{},
    picard_relaxation: f64 = 0.5,
    /// Required depth-one Anderson acceleration of `g(x) = x + R(x)` after
    /// Newton failure. A relaxed fixed-point sample seeds Anderson but is
    /// never accepted directly; `false` is rejected by input validation.
    anderson_recovery: bool = true,
    /// Divergence/oscillation watch, mirroring `core/numerics.zig` and
    /// `soil/heat/solver_solve.zig`. Consecutive main-loop iterations whose
    /// scaled norm exceeds `divergence_growth_factor` times the best norm
    /// seen so far are counted; past `divergence_patience` of them the solve
    /// is diverging or oscillating, and reporting that is more useful than
    /// spending the rest of the NPH ceiling on a trajectory running away from
    /// its best point.
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    /// Consecutive accepted iterates whose dimensionless scaled-norm decrease
    /// is indistinguishable from floating-point resolution before Newton is
    /// declared stagnant and routed through Anderson recovery.
    stagnation_patience: u16 = 4,
    /// Consecutive significant reversals of the scaled residual direction
    /// before Newton oscillation is routed through Anderson recovery.
    oscillation_patience: u16 = 2,
    directional_probe_fraction: f64 = 0.5,
    minimum_newton_fraction: f64 = 0.05,
    /// Damped Newton never extrapolates beyond its computed direction.
    maximum_newton_fraction: f64 = 1,
    /// Maximum dense Newton block dimension. Whole-domain and local block
    /// Jacobians above this bound are skipped in favor of the O(n)
    /// directional Newton path. Zero disables dense Newton workspaces; values
    /// above `maximum_dense_newton_components` are safety-clamped.
    dense_newton_max_components: usize = 256,
};

pub const maximum_dense_newton_components: usize = 256;

pub const Result = struct {
    iterations: u16,
    newton_raphson_steps: u16,
    /// Compatibility counter retained for callers that historically named
    /// Anderson recovery "Picard". It is always equal to `anderson_steps`.
    picard_steps: u16,
    anderson_steps: u16 = 0,
    maximum_scaled_residual: f64,
    dense_jacobian_assemblies: u16 = 0,
    dense_jacobian_reuses: u16 = 0,
    /// Observability only: distinguish missing wiring, unusable Broyden state,
    /// and deliberate invalidation after conservative publication correction.
    dense_jacobian_cache_supplied: bool = false,
    dense_jacobian_cache_loaded: bool = false,
    dense_jacobian_ready_at_publication: bool = false,
    conservative_map_publication: bool = false,
    dense_jacobian_cache_published: bool = false,
    richards_face_flux_cache_hits: u32 = 0,
    richards_face_flux_cache_misses: u32 = 0,
};
