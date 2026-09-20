//! `solver` declarations: types.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const grid_module = @import("../../state/grid.zig");
const heat = @import("flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const numerics = @import("../../core/numerics.zig");
const boundary_topology_module = @import("../profile/boundary_topology.zig");
const water_boundary = @import("../water/boundary.zig");
const enthalpy = @import("../water/enthalpy_balance.zig");
const retention = @import("../water/retention.zig");
const group_misc = @import("solver_misc.zig");
const group_solve = @import("solver_solve.zig");

pub const Face = struct {
    active: bool = true,
    source_cell: usize,
    destination_cell: usize,
    source_path_length_m: f64,
    destination_path_length_m: f64,
    face_area_m2: f64,
};

pub const FaceGeometry = struct { source_path_length_m: []const f64, destination_path_length_m: []const f64, face_area_m2: []const f64 };

pub const Properties = struct {
    /// Runtime DLYRM mask. Empty means all layers are active for standalone
    /// manufactured-solution calls.
    active_by_layer: []const bool = &.{},
    heat_capacity_megajoules_per_k: []const f64,
    minimum_heat_capacity_megajoules_per_k: []const f64,
    bulk_density_megagrams_per_m3: []const f64,
    liquid_water_fraction: []const f64,
    ice_fraction: []const f64,
    air_fraction: []const f64,
    fraction_of_pore_volume_air_filled: []const f64,
    solid_conductivity_numerator_m_megajoules_per_h_k: []const f64,
    solid_conductivity_denominator: []const f64,
    is_top_soil_layer: []const bool,
    top_snow_heat_capacity_megajoules_per_k: []const f64,
    maximum_negligible_snow_heat_capacity_megajoules_per_k: []const f64,
    snow_storage_heat_flux_megajoules: []const f64,
    cell_heat_source_megajoules: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    turbulence: heat.TurbulenceParameters,
    /// Physical duration represented by one group_solve.solve. Ordinary model execution
    /// uses one hour; published fine-step validation supplies 10/3600.
    time_step_hours: f64 = 1,
    geothermal_boundary: ?group_misc.GeothermalBoundary = null,
    dirichlet_thermal_boundaries: ?group_misc.DirichletThermalBoundaries = null,
    enthalpy_coupling: ?group_misc.EnthalpyCoupling = null,
};

pub const WaterHeatFluxes = struct {
    liquid_water_m3: []const f64,
    vapor_m3: []const f64,
    macropore_water_m3: []const f64,
};

/// Test-only observability/injection for the speculative recovery scheduler.
/// Production rejects a non-null pointer before evaluating any model state.
pub const RecoveryRoutingTestControl = struct {
    force_speculative_iteration: ?u16 = null,
    reject_speculative_anderson: bool = false,
    speculative_probes: u16 = 0,
    next_slot_newton_fallbacks: u16 = 0,
    iterations_entered: u16 = 0,
    speculative_anderson_iteration: ?u16 = null,
    next_slot_newton_iteration: ?u16 = null,
    invalidated_forecasts: u16 = 0,
};

/// Read-only observability hook for `solveWithWorkspace`. Unlike
/// `RecoveryRoutingTestControl`, this never alters solver state or control
/// flow -- every callback fires after the corresponding decision is already
/// made, purely to report it -- so it is safe to enable in any build mode,
/// not just under `builtin.is_test`. A `null` field, or a `null` trace
/// pointer on `Options`, costs exactly one pointer-null check per call site
/// and is otherwise a no-op.
pub const DiagnosticTrace = struct {
    context: ?*anyopaque = null,
    /// Fires once per outer iteration, immediately after `residualAt` and
    /// the scaled-norm computation, before any direction is generated.
    on_iteration_residual: ?*const fn (
        context: ?*anyopaque,
        iteration: u16,
        current: []const f64,
        residual: []const f64,
        norm: f64,
    ) void = null,
    /// Fires once per call to either pricing/line-search function
    /// (`priceNewtonDirection`/`priceRepresentableNewtonDirection`), after
    /// the full line-search loop completes. `accepted_fraction` is `null`
    /// when every line-search step was rejected.
    on_priced_direction: ?*const fn (
        context: ?*anyopaque,
        direction: []const f64,
        accepted_fraction: ?f64,
        best_norm: f64,
    ) void = null,
    /// Fires once per cell at solve entry, before iteration 0, reporting
    /// whether `properties.liquid_water_fraction[cell] + ice_fraction[cell]`
    /// is consistent with the coupling's own baseline water amounts
    /// (`matrix_liquid_water_m3[cell] + matrix_ice_water_equivalent_m3[cell]`
    /// over `porous_medium_volume_m3[cell]`). A caller-constructed
    /// `Properties`/`enthalpy_coupling` pair that seeds these two
    /// independently (as three separate synthetic-test fixtures in this
    /// investigation did) can silently disagree; this reports the
    /// discrepancy so a badly-seeded fixture is visible immediately rather
    /// than producing a confusing downstream Newton-rejection trace.
    on_ice_fraction_consistency_check: ?*const fn (
        context: ?*anyopaque,
        cell: usize,
        properties_fraction_sum: f64,
        coupling_fraction_sum: f64,
    ) void = null,
    /// Fires once per cell considered by the endpoint/representability
    /// discovery loop's transition-optimized skip check (`solveWithWorkspace`,
    /// the `allow_transition_optimized_scan` branch), reporting the cell's
    /// distance from its own depressed Dall'Amico transition temperature
    /// against the activation radius that decides whether this cell is
    /// skipped from discovery consideration this pass. Added to settle
    /// `SURFACE-HEAT-BRACKET-RUNAWAY-001`'s open question of whether a
    /// failing cell's true root sits just outside this radius.
    on_transition_proximity: ?*const fn (
        context: ?*anyopaque,
        cell: usize,
        temperature_k: f64,
        transition_k: f64,
        kink_radius_k: f64,
        near_domain_transition: bool,
    ) void = null,
    /// Fires once, at `solveWithWorkspace`'s final acceptance decision
    /// (NEWTON-ANDERSON-PRACTICAL-ACCEPTANCE-001), reporting which of the
    /// two disjoint accept paths (if either) admitted the last-permitted
    /// candidate. Added to give tests a safe, permanent way to confirm the
    /// practical-tolerance path actually fired end-to-end, instead of the
    /// unreachable-internal-state problem a black-box `solve()` call alone
    /// has.
    on_final_acceptance: ?*const fn (
        context: ?*anyopaque,
        nonlinear_norm: f64,
        conservation_norm: f64,
        strict_accept: bool,
        practical_accept: bool,
    ) void = null,
};

pub const Options = struct {
    /// Failure-only replay output, owned by the calling execution context.
    failure_report_io: ?std.Io = null,
    /// Runtime NPH ceiling; convergence exits without completing unused cycles.
    max_iterations: u16,
    /// See `DiagnosticTrace`'s own doc comment. Read-only; safe in any build
    /// mode. `null` (the default) costs nothing beyond the null check.
    diagnostic_trace: ?*const DiagnosticTrace = null,
    absolute_tolerance_k: f64 = 1e-10,
    relative_tolerance: f64 = 1e-9,
    picard_relaxation: f64 = 0.5,
    /// Anderson acceleration (depth 2, then depth 1) used only as RECOVERY once
    /// every Newton candidate has been rejected. Enthalpy coupling evaluates
    /// `g(T)` by exact per-cell inversion of the simultaneous-face target;
    /// uncoupled sensible heat retains `g(T) = T + R(T)`. Raw Picard images and
    /// relaxed seeds are never publishable. An Anderson candidate is adopted
    /// only after a strict decrease of the fully recomputed scaled merit.
    anderson_recovery: bool = true,
    /// Divergence/oscillation watch, mirroring `core/numerics.zig`. This solver
    /// is vector-valued over layers and cannot delegate to the shared scalar
    /// solver, so it carries its own detector: consecutive iterations whose
    /// scaled norm exceeds `divergence_growth_factor` times the best norm seen
    /// are counted, and past `divergence_patience` of them the solve is
    /// diverging or oscillating. Reporting that is more useful than spending
    /// the rest of the NPH ceiling to report mere non-convergence.
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    directional_probe_fraction: f64 = 1.0,
    /// Global merit backtracks applied after the bounded component-wise
    /// secant/Newton direction has been assembled.
    directional_newton_max_line_search_steps: u8 = 8,
    minimum_newton_fraction: f64 = 0.05,
    // Aitken/Newton acceleration of the Picard residual may legitimately
    // exceed one. Two is the stable upper bound used here; accepted steps must
    // still reduce the fully recomputed nonlinear residual.
    maximum_newton_fraction: f64 = 1.0,
    /// Global-merit backtracks for the O(n)-memory tridiagonal Newton used by
    /// sequential soil columns. Three one-sided generalized Jacobian choices
    /// use at most nine graph-color residual probes, each followed by this many
    /// merit backtracks. Neither probes nor rejected trials consume the
    /// accepted-update ceiling.
    topology_newton_max_line_search_steps: u8 = 8,
    /// Runtime memory/performance tradeoff. Zero selects only the O(n)
    /// directional Newton/Picard path.
    dense_newton_max_components: usize = 256,
    recovery_routing_test_control: ?*RecoveryRoutingTestControl = null,
    /// issue-068 (2026-09-20, second round): temporary, narrowly-gated
    /// diagnostic mirroring `vapor_solver.Options.diagnostic_trace_layer_index`.
    /// `null` in production; the caller gates this behind an hour window
    /// (2893-2896) and cell 0/layer 0, matching this session's other
    /// TEMP_DIAGNOSTIC instrumentation. When set, every named "commit `current`"
    /// site in `solveWithWorkspace` logs this layer's temperature immediately
    /// after writing it, tagged with the specific branch that wrote it, so a
    /// commit that lands outside the physical domain can be attributed to its
    /// exact caller instead of only surfacing generically at the next
    /// `residualAt` call or at `commitAcceptedState`.
    diagnostic_trace_layer_index: ?usize = null,
};

pub const Result = struct {
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    /// Anderson-accelerated recovery steps. Counted inside `picard_steps` as
    /// well; a relaxed seed is never accepted directly.
    anderson_steps: u16 = 0,
    /// Accepted O(n)-memory tridiagonal Newton promotions.
    topology_newton_steps: u16 = 0,
    /// Residual evaluations used to construct and globally line-search the
    /// topology-local Newton direction. These are probes, not state updates.
    topology_newton_probes: u32 = 0,
    /// Accepted tridiagonal Newton promotions formed from the signed scaled
    /// constitutive enthalpy-defect vector rather than its K equivalent.
    enthalpy_topology_newton_steps: u16 = 0,
    enthalpy_topology_newton_probes: u32 = 0,
    /// Accepted bounded dense Newton promotions formed from the governing
    /// signed scaled enthalpy-defect vector on arbitrary connected topologies.
    enthalpy_dense_newton_steps: u16 = 0,
    enthalpy_dense_newton_probes: u32 = 0,
    /// Accepted analytic diagonal Newton promotions restricted to smooth,
    /// representable coordinates within 99% of the largest MJ merit entry.
    megajoule_active_set_newton_steps: u16 = 0,
    megajoule_active_set_newton_probes: u32 = 0,
    /// Residual evaluations used to globalize the O(n) directional Newton
    /// correction. These probes do not consume accepted updates.
    directional_newton_probes: u32 = 0,
    /// Full coupled residual evaluations used to prove that adjacent f64
    /// temperatures bracket an otherwise unrepresentable enthalpy root.
    enthalpy_representability_probes: u32 = 0,
    /// Bounded Newton active-set promotions onto a crossed matrix or secondary
    /// phase-transition boundary. The destination state must strictly reduce
    /// the unchanged full nonlinear/conservation merit before it is retained.
    phase_transition_newton_steps: u16 = 0,
    /// Newton promotions whose neighbour-changing candidate re-established an
    /// adjacent-f64 enthalpy bracket before publishing either endpoint.
    enthalpy_repriced_neighbor_steps: u16 = 0,
    /// The exhausted-loop acceptance reused a simultaneous endpoint proof
    /// attached to that exact final Newton state instead of re-probing it.
    final_endpoint_proof_reused: bool = false,
    /// Globally accepted analytic diagonal Newton steps for the smooth
    /// constitutive enthalpy equation, after secant/topology Newton fail.
    constitutive_energy_newton_steps: u16 = 0,
    constitutive_energy_newton_probes: u32 = 0,
    /// Component/directional Newton promotions accepted only after their full
    /// step failed the global merit test and bounded damping found a decrease.
    damped_directional_newton_steps: u16 = 0,
    maximum_scaled_residual: f64,
    /// Final nonlinear K/enthalpy merit before any conservation coordinate.
    maximum_scaled_nonlinear_residual: f64 = 0,
    /// Final layer-local energy-closure merit. A proven adjacent-f64 endpoint
    /// includes only its explicit one-ULP constitutive energy width.
    maximum_scaled_conservation_residual: f64 = 0,
    boundary_heat_input_megajoules: f64,
    boundary_heat_output_megajoules: f64,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    face_count: usize,
    base: []f64,
    current: []f64,
    /// Lowest fully evaluated physical merit reached by the current solve.
    /// Terminal recovery audits this snapshot instead of publishing or
    /// rejecting whichever trial happened to be visited last.
    best_state: []f64,
    residual: []f64,
    target: []f64,
    scratch: []f64,
    trial_flux: []f64,
    face_buffer: []Face,
    matrix_liquid_m3: []f64,
    matrix_ice_m3: []f64,
    macropore_liquid_m3: []f64,
    macropore_ice_m3: []f64,
    probe: []f64,
    probe_residual: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    /// Anderson history over consistent `(iterate, g(iterate)-iterate)` pairs
    /// and the accelerated candidate they produce.
    previous_state: []f64,
    previous_residual: []f64,
    previous_previous_state: []f64,
    previous_previous_residual: []f64,
    accelerated: []f64,
    accelerated_residual: []f64,
    /// Per-iteration mask for enthalpy coordinates proven complete between
    /// adjacent floating-point temperatures. Kept separate from the signed
    /// scaled enthalpy defect so one discrete endpoint cannot erase Newton
    /// information for unrelated smooth cells.
    enthalpy_endpoint_mask: []f64,
    /// Snapshot attached to the exact best repriced candidate. Later rejected
    /// line-search probes may overwrite their own masks without corrupting the
    /// certificate eligible for final-state reuse.
    accepted_endpoint_proof_mask: []f64,
    /// Per-cell constitutive energy width attached only to accepted adjacent-
    /// f64 conservation endpoint proofs. The independent post-commit census
    /// consumes this exact certificate from the reusable workspace.
    accepted_conservation_representability_megajoules: []f64,
    topology_lower: []f64,
    topology_diagonal: []f64,
    topology_upper: []f64,
    jacobian: []f64,
    newton_delta: []f64,
    enthalpy_evaluation_cache: ?group_misc.EnthalpyEvaluationCache,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        face_count: usize,
        dense_newton_max_components: usize,
    ) !Workspace {
        if (cell_count == 0) return error.InvalidSoilHeatWorkspaceSize;
        var result: Workspace = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        result.face_count = face_count;
        var allocated: usize = 0;
        errdefer result.freeAllocated(allocated);
        inline for (.{
            "base",
            "current",
            "best_state",
            "residual",
            "target",
            "scratch",
            "matrix_liquid_m3",
            "matrix_ice_m3",
            "macropore_liquid_m3",
            "macropore_ice_m3",
            "probe",
            "probe_residual",
            "candidate",
            "candidate_residual",
            "newton_delta",
            "previous_state",
            "previous_residual",
            "previous_previous_state",
            "previous_previous_residual",
            "accelerated",
            "accelerated_residual",
            "enthalpy_endpoint_mask",
            "accepted_endpoint_proof_mask",
            "accepted_conservation_representability_megajoules",
            "topology_lower",
            "topology_diagonal",
            "topology_upper",
        }) |field_name| {
            @field(result, field_name) = try allocator.alloc(f64, cell_count);
            allocated += 1;
        }
        result.trial_flux = try allocator.alloc(f64, face_count);
        allocated += 1;
        result.face_buffer = try allocator.alloc(Face, face_count);
        allocated += 1;
        result.jacobian = try allocator.alloc(
            f64,
            if (cell_count <= dense_newton_max_components)
                try std.math.mul(usize, cell_count, cell_count)
            else
                0,
        );
        errdefer allocator.free(result.jacobian);
        result.enthalpy_evaluation_cache = try group_misc.EnthalpyEvaluationCache.init(allocator, cell_count);
        return result;
    }

    pub fn deinit(self: *Workspace) void {
        if (self.enthalpy_evaluation_cache) |*cache| cache.deinit(self.allocator);
        self.allocator.free(self.jacobian);
        self.allocator.free(self.face_buffer);
        self.allocator.free(self.trial_flux);
        inline for (.{
            "accelerated_residual",
            "accelerated",
            "enthalpy_endpoint_mask",
            "accepted_endpoint_proof_mask",
            "accepted_conservation_representability_megajoules",
            "topology_upper",
            "topology_diagonal",
            "topology_lower",
            "previous_previous_residual",
            "previous_previous_state",
            "previous_residual",
            "previous_state",
            "newton_delta",
            "candidate_residual",
            "candidate",
            "probe_residual",
            "probe",
            "macropore_ice_m3",
            "macropore_liquid_m3",
            "matrix_ice_m3",
            "matrix_liquid_m3",
            "scratch",
            "target",
            "residual",
            "best_state",
            "current",
            "base",
        }) |field_name| self.allocator.free(@field(self, field_name));
        self.* = undefined;
    }

    fn freeAllocated(self: *Workspace, count: usize) void {
        const field_names = [_][]const u8{
            "base",
            "current",
            "best_state",
            "residual",
            "target",
            "scratch",
            "matrix_liquid_m3",
            "matrix_ice_m3",
            "macropore_liquid_m3",
            "macropore_ice_m3",
            "probe",
            "probe_residual",
            "candidate",
            "candidate_residual",
            "newton_delta",
            "previous_state",
            "previous_residual",
            "previous_previous_state",
            "previous_previous_residual",
            "accelerated",
            "accelerated_residual",
            "enthalpy_endpoint_mask",
            "accepted_endpoint_proof_mask",
            "accepted_conservation_representability_megajoules",
            "topology_lower",
            "topology_diagonal",
            "topology_upper",
            "trial_flux",
            "face_buffer",
        };
        inline for (field_names, 0..) |field_name, index|
            if (index < count) self.allocator.free(@field(self, field_name));
    }
};
