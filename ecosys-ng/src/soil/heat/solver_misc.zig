//! `solver` declarations: misc.
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

pub const GeothermalBoundary = struct {
    topology: *const boundary_topology_module.State,
    layer_bottom_depth_m: []const f64,
    lower_face_area_m2: []const f64,
    enabled_by_cell: []const bool,
    mean_annual_temperature_k_by_cell: []const f64,
    minimum_source_depth_m: f64,
    source_depth_below_profile_m: f64,
    conductivity_m_megajoules_per_h_k: f64,
    geothermal_flux_megajoules_per_m2_h: f64,
};

pub const DirichletThermalBoundaries = struct {
    cell_index: []const usize,
    temperature_k: []const f64,
    distance_from_cell_center_m: []const f64,
    face_area_m2: []const f64,
};

pub const EnthalpyCoupling = struct {
    matrix_liquid_water_m3: []const f64,
    matrix_ice_water_equivalent_m3: []const f64,
    porous_medium_volume_m3: []const f64,
    /// Current matrix pore capacity. Dynamic surface/soil geometry can change
    /// this after initialization; when supplied it is authoritative for the
    /// retention-domain volume used by the Dall'Amico closure.
    matrix_pore_capacity_m3: []const f64 = &.{},
    /// Empty derives the head from the accepted matrix liquid content and
    /// the same runtime original-MVG curve used by Richards flow.
    unfrozen_pressure_head_m: []const f64 = &.{},
    mualem_van_genuchten: []const retention.MualemVanGenuchtenParameters,
    gravitational_water_potential_mpa_per_m: f64,
    pure_water_melting_temperature_k: f64,
    ice_water_equivalent_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    /// True/physical ice density (Mg m-3), strictly less than the water
    /// density it is scaled against. `dallAmicoEquilibrium` (GAS-SOLVER
    /// sibling `phase_change.zig`) returns ice in water-equivalent volume by
    /// design -- see that module's doc comment -- so the phase-state update
    /// that publishes `grid.matrix_ice_water_m3`/`grid.macropore_ice_water_m3`
    /// must apply this factor itself when deriving how much physical pore
    /// space the ice actually occupies (`state_updateMatrixPhase`'s
    /// `matrix_air_volume_m3`/`macropore_air_volume_m3`). `starts.f:99`
    /// (`DENSI=0.92-THETPI`) is the source counterpart.
    ice_density_megagrams_per_m3: f64,
    solver_options: enthalpy.SolverOptions,
    /// Optional layer-local conservation gate, kept distinct from nonlinear
    /// convergence. When present, the heat solve must reduce its constitutive
    /// enthalpy defect below the same scaled absolute-plus-relative budget
    /// used by the independent post-commit spatial-heat closure.
    conservation_cell_area_m2: []const f64 = &.{},
    conservation_absolute_tolerance_megajoules_per_m2: f64 = 0,
    conservation_relative_tolerance: f64 = 0,
    macropore_liquid_water_m3: []const f64 = &.{},
    macropore_ice_water_equivalent_m3: []const f64 = &.{},
    macropore_porous_medium_volume_m3: []const f64 = &.{},
    macropore_unfrozen_pressure_head_m: []const f64 = &.{},
    macropore_mualem_van_genuchten: []const retention.MualemVanGenuchtenParameters = &.{},
};

/// Owned, solve-local memoization of deterministic constitutive evaluations.
/// Parameters and solve-entry temperature must remain immutable until reset.
/// In particular this must never survive publication into aliased grid water
/// arrays: solveWithWorkspace resets it on entry and returns after publication.
pub const EnthalpyEvaluationCache = struct {
    pub const Entry = struct {
        parameters_valid: bool = false,
        base_validated: bool = false,
        trial_valid: bool = false,
        derivative_valid: bool = false,
        parameters: enthalpy.Parameters = undefined,
        temperature_k: f64 = undefined,
        state: enthalpy.State = undefined,
        derivative_megajoules_per_k: f64 = undefined,

        pub fn trialState(self: *Entry, temperature_k: f64) !enthalpy.State {
            if (self.trial_valid and self.temperature_k == temperature_k)
                return self.state;
            const state = try enthalpy.stateAtTemperature(self.parameters, temperature_k);
            self.temperature_k = temperature_k;
            self.state = state;
            self.trial_valid = true;
            self.derivative_valid = false;
            return state;
        }

        pub fn derivative(self: *Entry) !f64 {
            std.debug.assert(self.trial_valid);
            if (!self.derivative_valid) {
                self.derivative_megajoules_per_k = try enthalpy.enthalpyDerivativeMjPerK(
                    self.parameters,
                    self.temperature_k,
                    self.state,
                );
                self.derivative_valid = true;
            }
            return self.derivative_megajoules_per_k;
        }
    };

    entries: []Entry,
    /// Test-only accounting; no counter traffic in the production hot loop.
    parameter_misses: usize = 0,
    state_hits: usize = 0,

    pub fn init(allocator: std.mem.Allocator, count: usize) !EnthalpyEvaluationCache {
        var result: EnthalpyEvaluationCache = .{ .entries = try allocator.alloc(Entry, count) };
        result.reset();
        return result;
    }

    pub fn reset(self: *EnthalpyEvaluationCache) void {
        for (self.entries) |*entry| {
            entry.parameters_valid = false;
            entry.base_validated = false;
            entry.trial_valid = false;
            entry.derivative_valid = false;
        }
        self.parameter_misses = 0;
        self.state_hits = 0;
    }

    pub fn deinit(self: *EnthalpyEvaluationCache, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const PhaseBuffers = struct {
    matrix_liquid_m3: []f64,
    matrix_ice_m3: []f64,
    macropore_liquid_m3: []f64,
    macropore_ice_m3: []f64,
    macropore_enabled: bool,
    /// See `EnthalpyCoupling.ice_density_megagrams_per_m3`. Carried
    /// separately here because `state_updateMatrixPhase` receives only the
    /// buffers, not the coupling struct they were solved from.
    ice_density_megagrams_per_m3: f64,
    /// Null retains the uncached residual for independent direct-call checks.
    evaluation_cache: ?*EnthalpyEvaluationCache = null,
};
