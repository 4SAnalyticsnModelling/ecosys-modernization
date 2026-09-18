//! `coupled_gas_solver` declarations: misc.
//!
//! Split out of `coupled_gas_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const gas = @import("transport.zig");
const atmosphere = @import("atmosphere_exchange.zig");
const numerics = @import("../../core/numerics.zig");

pub const maximum_krylov_restart: usize = 64;

pub const Inputs = struct {
    faces: []const gas.Face,
    face_conductance_m3_per_step: []const f64,
    atmospheric_boundaries: []const atmosphere.Boundary,
    subsurface_boundaries: []const atmosphere.Boundary = &.{},
    /// Full matrix water volume. NH3 non-band volume is this minus
    /// `band_water_volume_m3`; other gases use the full volume.
    water_volume_m3: []const f64,
    band_water_volume_m3: []const f64,
    /// NH3 non-band and band air-zone volumes (VOLPMA/VOLPMB). Empty retains
    /// the legacy whole-air volume for non-banded callers such as litter.
    nonband_air_volume_m3: []const f64 = &.{},
    band_air_volume_m3: []const f64 = &.{},
    mass_solubility_ratio: []const f64,
    gas_water_exchange_rate_per_step: []const f64,
    band_gas_water_exchange_rate_per_step: []const f64,
    bubbling_enabled: []const bool,
    /// Legacy `ZEROS2(NY,NX) = ZERO2 * DH * DV` from `starts.f:94,270`, one
    /// value per modeled cell in cubic metres. `ZERO2 = 1e-6` is defined under
    /// the source comment "minimum values used for all calculations", and
    /// TRNSFR never divides by, or iterates on, a carrier volume at or below
    /// it: gaseous face transport requires `VOLPM > ZEROS2` on both sides
    /// (`trnsfr.f:5303-5306`), a concentration reads as zero below it
    /// (`trnsfr.f:1283`), and the aqueous carrier is floored identically
    /// (`trnsfr.f:4129-4130`). The same scalar bounds both the air and the
    /// water carrier because the source uses one `ZEROS2` for both.
    ///
    /// An empty slice retains the pre-existing bare positivity test, so
    /// callers that do not own a cell area are unchanged.
    minimum_carrier_volume_m3: []const f64 = &.{},
    /// REDIST `LL=MIN(L,LG)` destination for gas released by bubbling. A
    /// null entry means no gas-phase route exists, so the released mass is a
    /// landscape boundary flux. Omitting the map conservatively releases
    /// bubbles into their source cell.
    bubble_receiver_cell_by_cell: ?[]const ?usize = null,
    /// Optional caller-owned exact accepted atmospheric flux ledger, indexed
    /// cell × species. It is written only at successful state_update.
    atmospheric_flux_g_by_component: ?[]f64 = null,
    /// Separate accepted lateral/lower flux ledger; positive enters soil.
    subsurface_flux_g_by_component: ?[]f64 = null,
    /// Exact accepted internal face ledger, indexed face × gas species.
    /// Positive moves `first_cell -> second_cell`.
    face_flux_g_by_component: ?[]f64 = null,
    /// Exact accepted REDIST bubbling release indexed source cell × gas
    /// species. Values are nonnegative and are populated only when the
    /// source's `bubble_receiver_cell_by_cell` is a different modeled cell;
    /// same-cell phase exchange and null-receiver boundary loss are excluded.
    bubble_transfer_g_by_component: ?[]f64 = null,
};

pub const Options = struct {
    /// Species-specific nonlinear absolute residual floors in the tracked
    /// gram basis documented by `transport.Species`.
    absolute_tolerance_g_by_species: [gas.species_count]f64 = @splat(1e-12),
    /// Deprecated homogeneous-unit input retained for source compatibility.
    /// A finite positive value overrides the vector; production mixed-species
    /// callers leave this unset and provide the vector above.
    absolute_tolerance_g: f64 = std.math.nan(f64),
    relative_tolerance: f64 = 1e-8,
    picard_relaxation: f64 = 0.5,
    directional_probe_fraction: f64 = 0.5,
    minimum_newton_fraction: f64 = 0.05,
    maximum_newton_fraction: f64 = 1.0,
    /// Consecutive tolerance-scaled residual explosions allowed before the
    /// nonlinear solve fails early and enters transactional substep recovery.
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    /// Fraction of the physical hour represented by the residual. ecosys-ng
    /// solves one full-hour equation; NPG expands only the iteration ceiling.
    transport_iteration_fraction: f64 = 1,
    /// Runtime NPH*NPG ceiling derived from the input options.
    max_iterations: u16,
    /// Permit publication of the exact finite, nonnegative conservative map
    /// when its generating iterate already meets the requested nonlinear
    /// tolerance and the independently evaluated map misses by only the
    /// bounded roundoff-scale ceiling in the solver. Disabled by default so
    /// callers opt into this physical-conservation fallback explicitly.
    accept_physically_conserved_ceiling: bool = false,
    /// Emit per-coordinate nonlinear-failure diagnostics. Adaptive transport
    /// retries disable these for unpublished intermediate attempts and enable
    /// them on the terminal attempt that owns the failure snapshot.
    emit_failure_diagnostics: bool = true,
    /// Maximum GMRES restart dimension. Keeping this independent of the
    /// runtime cell count makes the matrix-free Newton workspace O(n).
    krylov_restart_max: usize = 24,
    /// Relative linear residual target for each matrix-free Newton direction.
    krylov_relative_tolerance: f64 = 1.4e-4,
    use_local_krylov_preconditioner: bool = true,
};

/// The area-scaled legacy `ZEROS2` for one modeled cell. Callers without a
/// runtime cell area supply no slice and receive zero, which reduces every
/// guarded site to the bare positivity test it had before.
pub fn minimumCarrierVolumeM3(inputs: Inputs, cell: usize) f64 {
    if (inputs.minimum_carrier_volume_m3.len == 0) return 0;
    return inputs.minimum_carrier_volume_m3[cell];
}

pub fn absoluteToleranceForSpecies(options: Options, species: usize) f64 {
    return if (std.math.isFinite(options.absolute_tolerance_g) and options.absolute_tolerance_g > 0)
        options.absolute_tolerance_g
    else
        options.absolute_tolerance_g_by_species[species];
}

pub fn absoluteToleranceForCoordinate(options: Options, coordinate_index: usize, inventory_count: usize) f64 {
    return absoluteToleranceForSpecies(options, (coordinate_index % inventory_count) % gas.species_count);
}

pub const Result = struct {
    iterations: u16,
    newton_raphson_steps: u16,
    /// Compatibility alias for `anderson_steps`. Vanilla Picard is not an
    /// active production path, so these counters must always agree.
    picard_steps: u16,
    anderson_steps: u16 = 0,
    initial_maximum_scaled_residual: f64 = 0,
    maximum_scaled_residual: f64,
    dense_full_jacobian_assemblies: u16 = 0,
    dense_full_jacobian_reuses: u16 = 0,
    krylov_direction_calls: u16 = 0,
    krylov_iterations: u32 = 0,
};
